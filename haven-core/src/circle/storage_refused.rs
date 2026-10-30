//! The durable ledger of refused transport objects owed a refetch, on
//! `circles-v2.db` (the `refused_redeliveries` and `refused_ranges` tables in
//! [`CircleStorage::initialize_schema`]).
//!
//! A failure is logged by its storage code alone and never returned: the
//! ledger's callers are the engine-batch observer and the catch-up sweep, and
//! neither can do anything about a write that failed but carry on. A lost row
//! costs one refetch opportunity — exactly what the in-memory ledger it
//! replaces cost on every kill.

#![allow(clippy::significant_drop_tightening)]

use std::collections::HashSet;

use rusqlite::{params, OptionalExtension};

use super::error::Result;
use super::storage::CircleStorage;
use crate::nostr::mls::types::GroupId;
use crate::nostr::mls::{
    refetch_spacing_secs, OwedRange, RangePass, RefusedRedeliveryLedger, MAX_REFUSED_IDS_PER_GROUP,
};

/// Where a range's generation starts when its circle has no row — first use,
/// or after `delete_circle` dropped the tombstone with the circle. Random, not
/// 1, so a pass still holding a read from before a leave and re-join can never
/// match the new range's generation. Below 2^62, so `+ 1` never overflows.
fn fresh_generation() -> i64 {
    use rand::RngCore;
    let mut bytes = [0u8; 8];
    let seed = if rand::rngs::OsRng.try_fill_bytes(&mut bytes).is_ok() {
        u64::from_le_bytes(bytes)
    } else {
        // Failing that, the clock: still not 1, and still unlikely to repeat.
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(1, |elapsed| {
                u64::try_from(elapsed.as_nanos()).unwrap_or(u64::MAX)
            })
    };
    i64::try_from(seed >> 2).unwrap_or(1).max(1)
}

impl CircleStorage {
    fn record_refused(&self, group_id: &GroupId, ids: &[nostr::EventId], now: i64) -> Result<()> {
        let mut conn = self.conn().lock().map_err(|_| {
            super::error::CircleError::Storage("Failed to acquire database lock".into())
        })?;
        let tx = conn.transaction()?;
        let mut owed: usize = tx
            .query_row(
                "SELECT COUNT(*) FROM refused_redeliveries WHERE mls_group_id = ?1",
                params![group_id.as_slice()],
                |row| row.get::<_, i64>(0),
            )?
            .try_into()
            .unwrap_or(usize::MAX);
        let mut overflowed = false;
        for id in ids {
            let known = tx
                .query_row(
                    "SELECT 1 FROM refused_redeliveries WHERE mls_group_id = ?1 AND event_id = ?2",
                    params![group_id.as_slice(), id.as_bytes().as_slice()],
                    |_| Ok(()),
                )
                .optional()?
                .is_some();
            if known {
                continue;
            }
            if owed < MAX_REFUSED_IDS_PER_GROUP {
                tx.execute(
                    "INSERT INTO refused_redeliveries (mls_group_id, event_id, seq)
                     VALUES (?1, ?2, (SELECT COALESCE(MAX(seq), 0) + 1 FROM refused_redeliveries))",
                    params![group_id.as_slice(), id.as_bytes().as_slice()],
                )?;
                owed += 1;
            } else {
                overflowed = true;
            }
        }
        if overflowed {
            owe_refused_range(&tx, group_id, now)?;
        }
        tx.commit()?;
        Ok(())
    }

    fn owe_refused_range_now(&self, group_id: &GroupId, now: i64) -> Result<()> {
        let conn = self.conn().lock().map_err(|_| {
            super::error::CircleError::Storage("Failed to acquire database lock".into())
        })?;
        owe_refused_range(&conn, group_id, now)
    }

    fn all_owed_refused(&self, group_id: &GroupId) -> Result<HashSet<nostr::EventId>> {
        let conn = self.conn().lock().map_err(|_| {
            super::error::CircleError::Storage("Failed to acquire database lock".into())
        })?;
        let mut stmt =
            conn.prepare("SELECT event_id FROM refused_redeliveries WHERE mls_group_id = ?1")?;
        let rows = stmt.query_map(params![group_id.as_slice()], |row| row.get::<_, Vec<u8>>(0))?;
        let mut ids = HashSet::new();
        for row in rows {
            if let Ok(id) = nostr::EventId::from_slice(&row?) {
                ids.insert(id);
            }
        }
        Ok(ids)
    }

    fn owed_refused(
        &self,
        group_id: &GroupId,
        limit: usize,
        now: i64,
    ) -> Result<Vec<nostr::EventId>> {
        let conn = self.conn().lock().map_err(|_| {
            super::error::CircleError::Storage("Failed to acquire database lock".into())
        })?;
        let mut stmt = conn.prepare(
            "SELECT event_id FROM refused_redeliveries
             WHERE mls_group_id = ?1 AND (next_due <= ?3 OR ?3 < last_tried)
             ORDER BY seq LIMIT ?2",
        )?;
        let rows = stmt.query_map(
            params![
                group_id.as_slice(),
                i64::try_from(limit).unwrap_or(i64::MAX),
                now
            ],
            |row| row.get::<_, Vec<u8>>(0),
        )?;
        let mut ids = Vec::new();
        for row in rows {
            if let Ok(id) = nostr::EventId::from_slice(&row?) {
                ids.push(id);
            }
        }
        Ok(ids)
    }

    fn mark_refused_tried(
        &self,
        group_id: &GroupId,
        ids: &[nostr::EventId],
        now: i64,
        wholesale: bool,
    ) -> Result<()> {
        let mut conn = self.conn().lock().map_err(|_| {
            super::error::CircleError::Storage("Failed to acquire database lock".into())
        })?;
        let tx = conn.transaction()?;
        let mut soonest = None;
        for id in ids {
            let attempts: Option<i64> = tx
                .query_row(
                    "SELECT attempts FROM refused_redeliveries
                     WHERE mls_group_id = ?1 AND event_id = ?2",
                    params![group_id.as_slice(), id.as_bytes().as_slice()],
                    |row| row.get(0),
                )
                .optional()?;
            let Some(attempts) = attempts else {
                continue;
            };
            let attempts = attempts.saturating_add(1);
            let due = now.saturating_add(refetch_spacing_secs(
                u32::try_from(attempts).unwrap_or(u32::MAX),
            ));
            tx.execute(
                "UPDATE refused_redeliveries SET last_tried = ?3, attempts = ?4, next_due = ?5,
                     seq = (SELECT COALESCE(MAX(seq), 0) + 1 FROM refused_redeliveries)
                 WHERE mls_group_id = ?1 AND event_id = ?2",
                params![
                    group_id.as_slice(),
                    id.as_bytes().as_slice(),
                    now,
                    attempts,
                    due
                ],
            )?;
            soonest = Some(soonest.map_or(due, |earlier: i64| earlier.min(due)));
        }
        if let Some(soonest) = soonest.filter(|_| wholesale) {
            tx.execute(
                "UPDATE refused_redeliveries SET next_due = MAX(next_due, ?2)
                 WHERE mls_group_id = ?1 AND next_due > 0",
                params![group_id.as_slice(), soonest],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    fn refused_moved(&self, group_id: &GroupId) -> Result<()> {
        let mut conn = self.conn().lock().map_err(|_| {
            super::error::CircleError::Storage("Failed to acquire database lock".into())
        })?;
        let tx = conn.transaction()?;
        tx.execute(
            "UPDATE refused_redeliveries SET next_due = 0 WHERE mls_group_id = ?1",
            params![group_id.as_slice()],
        )?;
        tx.execute(
            "UPDATE refused_ranges SET next_due = 0, attempts = 0 WHERE mls_group_id = ?1",
            params![group_id.as_slice()],
        )?;
        tx.commit()?;
        Ok(())
    }

    fn refused_range_tried(&self, group_id: &GroupId, now: i64) -> Result<()> {
        let mut conn = self.conn().lock().map_err(|_| {
            super::error::CircleError::Storage("Failed to acquire database lock".into())
        })?;
        let tx = conn.transaction()?;
        let attempts: Option<i64> = tx
            .query_row(
                "SELECT attempts FROM refused_ranges
                 WHERE mls_group_id = ?1 AND until_secs IS NOT NULL",
                params![group_id.as_slice()],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(attempts) = attempts {
            let attempts = attempts.saturating_add(1);
            let due = now.saturating_add(refetch_spacing_secs(
                u32::try_from(attempts).unwrap_or(u32::MAX),
            ));
            // A walk that is not under way begins here, at the ceiling, with
            // nothing of it owed yet.
            tx.execute(
                "UPDATE refused_ranges SET last_tried = ?2, attempts = ?3, next_due = ?4,
                     unsettled = CASE WHEN walk_secs IS NULL THEN 0 ELSE unsettled END,
                     walk_secs = COALESCE(walk_secs, until_secs)
                 WHERE mls_group_id = ?1",
                params![group_id.as_slice(), now, attempts, due],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    fn resolve_refused(&self, group_id: &GroupId, ids: &[nostr::EventId]) -> Result<()> {
        let mut conn = self.conn().lock().map_err(|_| {
            super::error::CircleError::Storage("Failed to acquire database lock".into())
        })?;
        let tx = conn.transaction()?;
        for id in ids {
            tx.execute(
                "DELETE FROM refused_redeliveries WHERE mls_group_id = ?1 AND event_id = ?2",
                params![group_id.as_slice(), id.as_bytes().as_slice()],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    fn refused_range(&self, group_id: &GroupId) -> Result<Option<OwedRange>> {
        let conn = self.conn().lock().map_err(|_| {
            super::error::CircleError::Storage("Failed to acquire database lock".into())
        })?;
        Ok(conn
            .query_row(
                "SELECT until_secs, COALESCE(walk_secs, until_secs), generation, last_tried, next_due
                 FROM refused_ranges
                 WHERE mls_group_id = ?1 AND until_secs IS NOT NULL",
                params![group_id.as_slice()],
                |row| {
                    Ok(OwedRange {
                        until_secs: row.get(0)?,
                        walk_secs: row.get(1)?,
                        generation: row.get(2)?,
                        tried_secs: row.get(3)?,
                        due_secs: row.get(4)?,
                    })
                },
            )
            .optional()?)
    }

    fn settle_refused_range(
        &self,
        group_id: &GroupId,
        read: OwedRange,
        pass: RangePass,
    ) -> Result<()> {
        let conn = self.conn().lock().map_err(|_| {
            super::error::CircleError::Storage("Failed to acquire database lock".into())
        })?;
        // Every arm is held to the walk the pass read (`walk_secs = ?2`): a
        // pass that outlived its range, or its walk, records nothing.
        let (group, walk) = (group_id.as_slice(), read.walk_secs);
        match pass {
            // Carried down, the rest is due at once and the pass gives back
            // the attempt it was counted as; no further, its wait stands.
            RangePass::Halted { at_secs, owing } => {
                conn.execute(
                    "UPDATE refused_ranges SET
                         unsettled = unsettled | ?4,
                         next_due = CASE WHEN ?3 < walk_secs THEN 0 ELSE next_due END,
                         attempts = CASE WHEN ?3 < walk_secs THEN MAX(attempts - 1, 0)
                                         ELSE attempts END,
                         walk_secs = MIN(walk_secs, ?3)
                     WHERE mls_group_id = ?1 AND walk_secs = ?2 AND until_secs IS NOT NULL",
                    params![group, walk, at_secs, i64::from(owing)],
                )?;
            }
            RangePass::Whole { owing } => {
                let ended = !owing
                    && conn.execute(
                        "UPDATE refused_ranges SET until_secs = NULL, walk_secs = NULL,
                             next_due = 0, attempts = 0, last_tried = 0
                         WHERE mls_group_id = ?1 AND walk_secs = ?2 AND generation = ?3
                           AND unsettled = 0",
                        params![group, walk, read.generation],
                    )? > 0;
                if !ended {
                    conn.execute(
                        "UPDATE refused_ranges SET walk_secs = NULL
                         WHERE mls_group_id = ?1 AND walk_secs = ?2 AND until_secs IS NOT NULL",
                        params![group, walk],
                    )?;
                }
            }
        }
        Ok(())
    }
}

/// Opens `group_id`'s owed range, or widens it to `now` and bumps its
/// generation.
fn owe_refused_range(conn: &rusqlite::Connection, group_id: &GroupId, now: i64) -> Result<()> {
    conn.execute(
        "INSERT INTO refused_ranges (mls_group_id, until_secs, generation, unsettled)
         VALUES (?1, ?2, ?3, 1)
         ON CONFLICT (mls_group_id) DO UPDATE
         SET until_secs = COALESCE(MAX(until_secs, ?2), ?2), generation = generation + 1,
             unsettled = 1",
        params![group_id.as_slice(), now, fresh_generation()],
    )?;
    Ok(())
}

impl RefusedRedeliveryLedger for CircleStorage {
    fn record(&self, group_id: &GroupId, ids: &[nostr::EventId], now_secs: i64) -> bool {
        self.record_refused(group_id, ids, now_secs)
            .inspect_err(|e| log::warn!("refused object not recorded for refetch: {}", e.code()))
            .is_ok()
    }

    fn owe_range(&self, group_id: &GroupId, now_secs: i64) -> bool {
        self.owe_refused_range_now(group_id, now_secs)
            .inspect_err(|e| log::warn!("refetch range not owed: {}", e.code()))
            .is_ok()
    }

    fn owed(&self, group_id: &GroupId, limit: usize, now_secs: i64) -> Vec<nostr::EventId> {
        self.owed_refused(group_id, limit, now_secs)
            .unwrap_or_else(|e| {
                log::warn!("refused objects not read for refetch: {}", e.code());
                Vec::new()
            })
    }

    fn tried(&self, group_id: &GroupId, ids: &[nostr::EventId], now_secs: i64, wholesale: bool) {
        if let Err(e) = self.mark_refused_tried(group_id, ids, now_secs, wholesale) {
            log::warn!("refetch attempt not recorded: {}", e.code());
        }
    }

    fn moved(&self, group_id: &GroupId) {
        if let Err(e) = self.refused_moved(group_id) {
            log::warn!("refetch waits not ended at a new epoch: {}", e.code());
        }
    }

    fn range_tried(&self, group_id: &GroupId, now_secs: i64) {
        if let Err(e) = self.refused_range_tried(group_id, now_secs) {
            log::warn!("refetch range attempt not recorded: {}", e.code());
        }
    }

    fn resolve(&self, group_id: &GroupId, ids: &[nostr::EventId]) {
        if let Err(e) = self.resolve_refused(group_id, ids) {
            log::warn!("refetched objects not discharged: {}", e.code());
        }
    }

    fn owed_ids(&self, group_id: &GroupId) -> HashSet<nostr::EventId> {
        self.all_owed_refused(group_id).unwrap_or_else(|e| {
            log::warn!("refused objects not read for refetch: {}", e.code());
            HashSet::new()
        })
    }

    fn owed_range(&self, group_id: &GroupId) -> Option<OwedRange> {
        self.refused_range(group_id).unwrap_or_else(|e| {
            log::warn!("refetch range not read: {}", e.code());
            None
        })
    }

    fn settle_owed_range(&self, group_id: &GroupId, read: OwedRange, pass: RangePass) {
        if let Err(e) = self.settle_refused_range(group_id, read, pass) {
            log::warn!("refetch range not recorded: {}", e.code());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nostr::mls::types::GroupIdExt;
    use crate::nostr::mls::REFETCH_SPACING_BASE_SECS;

    const NOW: i64 = 1_759_300_000;

    fn ids(seeds: &[u16]) -> Vec<nostr::EventId> {
        seeds
            .iter()
            .map(|seed| {
                let mut bytes = [0u8; 32];
                bytes[..2].copy_from_slice(&seed.to_be_bytes());
                nostr::EventId::from_byte_array(bytes)
            })
            .collect()
    }

    #[test]
    fn an_owed_id_stays_owed_until_resolved_and_only_in_its_own_circle() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);
        let other = GroupId::from_slice(&[2; 32]);

        storage.record(&circle, &ids(&[7, 8]), NOW);
        storage.record(&circle, &ids(&[7]), NOW);
        assert_eq!(
            storage.owed(&circle, 10, NOW),
            ids(&[7, 8]),
            "a repeat refusal is owed once"
        );
        assert!(storage.owed(&other, 10, NOW).is_empty());

        storage.resolve(&circle, &ids(&[7]));
        assert_eq!(storage.owed(&circle, 10, NOW), ids(&[8]));
    }

    #[test]
    fn the_ids_that_waited_longest_are_asked_for_first() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);
        storage.record(&circle, &ids(&[1, 2, 3]), NOW);

        assert_eq!(storage.owed(&circle, 2, NOW), ids(&[1, 2]));
        storage.tried(&circle, &ids(&[1, 2]), NOW, false);
        assert_eq!(
            storage.owed(&circle, 2, NOW),
            ids(&[3]),
            "an id just asked for is not asked for again in the same breath"
        );
        assert_eq!(
            storage.owed(&circle, 2, NOW + REFETCH_SPACING_BASE_SECS),
            ids(&[3, 1]),
            "a sweep's share rotates instead of re-asking the same ids for ever"
        );
    }

    #[test]
    fn refusals_past_the_cap_are_owed_as_a_range_and_no_owed_id_is_dropped() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);
        let cap = u16::try_from(MAX_REFUSED_IDS_PER_GROUP).unwrap();
        let first: Vec<u16> = (0..cap).collect();
        storage.record(&circle, &ids(&first), NOW);
        assert!(
            storage.owed_range(&circle).is_none(),
            "at the cap, still by id"
        );

        storage.record(&circle, &ids(&[cap, cap + 1]), NOW + 5);
        let owed = storage.owed(&circle, usize::MAX, NOW);
        assert_eq!(
            owed.len(),
            MAX_REFUSED_IDS_PER_GROUP,
            "the ledger stops growing"
        );
        assert_eq!(
            owed,
            ids(&first),
            "every id owed before the cap is still owed"
        );
        assert!(
            storage
                .owed_range(&circle)
                .is_some_and(|range| range.until_secs == NOW + 5),
            "the overflow is not owed as the history up to its refusal",
        );
    }

    #[test]
    fn a_range_ends_only_when_a_whole_walk_owes_nothing() {
        crate::nostr::mls::ledger_test_support::assert_a_range_ends_only_when_a_whole_walk_owes_nothing(
            &CircleStorage::in_memory().unwrap(),
        );
    }

    /// A walk under way outlives the process: where it has got to, and that
    /// one of its passes left an event owed.
    #[test]
    fn a_walk_under_way_survives_a_reopen() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("circles.db");
        let circle = GroupId::from_slice(&[1; 32]);
        let cap = u16::try_from(MAX_REFUSED_IDS_PER_GROUP).unwrap();
        {
            let storage = CircleStorage::new(&path, None).unwrap();
            storage.record(&circle, &ids(&(0..=cap).collect::<Vec<_>>()), NOW);
            storage.range_tried(&circle, NOW);
            let read = storage.owed_range(&circle).expect("owed");
            let halted = RangePass::Halted {
                at_secs: NOW - 50,
                owing: true,
            };
            storage.settle_owed_range(&circle, read, halted);
        }
        let storage = CircleStorage::new(&path, None).unwrap();
        let read = storage.owed_range(&circle).expect("still owed");
        assert!(
            read.until_secs == NOW && read.walk_secs == NOW - 50,
            "a reopened ledger forgot how far its walk had got",
        );
        storage.range_tried(&circle, NOW);
        storage.settle_owed_range(&circle, read, RangePass::Whole { owing: false });
        assert!(
            storage.owed_range(&circle).is_some(),
            "a reopened ledger forgot that a pass of its walk had left an event owed",
        );
    }

    #[test]
    fn a_stale_read_never_settles_a_later_range() {
        crate::nostr::mls::ledger_test_support::assert_a_stale_read_never_settles_a_later_range(
            &CircleStorage::in_memory().unwrap(),
        );
    }

    #[test]
    fn a_refused_id_backs_off_and_is_never_forgotten() {
        crate::nostr::mls::ledger_test_support::assert_a_refused_id_backs_off_and_is_never_forgotten(
            &CircleStorage::in_memory().unwrap(),
        );
    }

    #[test]
    fn a_wholesale_refusal_makes_only_the_asked_wait_and_a_new_epoch_ends_the_wait() {
        crate::nostr::mls::ledger_test_support::assert_a_wholesale_refusal_makes_only_the_asked_wait(
            &CircleStorage::in_memory().unwrap(),
        );
    }

    #[test]
    fn no_id_can_be_minted_to_the_front_of_the_queue() {
        crate::nostr::mls::ledger_test_support::assert_no_id_can_be_minted_to_the_front_of_the_queue(
            &CircleStorage::in_memory().unwrap(),
        );
    }

    #[test]
    fn a_clock_stepped_back_leaves_nothing_waiting() {
        crate::nostr::mls::ledger_test_support::assert_a_clock_stepped_back_leaves_nothing_waiting(
            &CircleStorage::in_memory().unwrap(),
        );
    }

    #[test]
    fn the_owed_range_keeps_its_own_schedule() {
        crate::nostr::mls::ledger_test_support::assert_the_owed_range_keeps_its_own_schedule(
            &CircleStorage::in_memory().unwrap(),
        );
    }

    /// The wait an id has earned is stored with it: a process that dies and
    /// opens again asks no sooner, and has forgotten nothing.
    #[test]
    fn a_refused_ids_wait_survives_a_reopen() {
        let dir = tempfile::TempDir::new().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);
        let path = dir.path().join("circles.db");
        {
            let storage = CircleStorage::new(&path, None).unwrap();
            storage.record(&circle, &ids(&[7]), NOW);
            storage.tried(&circle, &ids(&[7]), NOW, false);
            storage.tried(&circle, &ids(&[7]), NOW + 60, false);
        }
        let storage = CircleStorage::new(&path, None).unwrap();
        assert!(
            storage.owed(&circle, 10, NOW + 60 + 119).is_empty(),
            "the reopened ledger asked sooner than the wait the id had earned"
        );
        assert_eq!(
            storage.owed(&circle, 10, NOW + 60 + 120),
            ids(&[7]),
            "the reopened ledger forgot an owed id, or its wait"
        );
    }

    #[test]
    fn a_read_from_before_a_leave_never_settles_the_range_owed_after_a_rejoin() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);
        let cap = u16::try_from(MAX_REFUSED_IDS_PER_GROUP).unwrap();
        storage.record(&circle, &ids(&(0..=cap).collect::<Vec<_>>()), NOW);
        let stale = storage.owed_range(&circle).expect("owed");

        storage.delete_circle(&circle).unwrap();
        storage.record(&circle, &ids(&(0..=cap).collect::<Vec<_>>()), NOW + 9);
        let next = storage.owed_range(&circle).expect("owed again");
        assert!(
            next.generation != stale.generation,
            "the tombstone went with the circle, so the new row must not restart where the old one began"
        );

        storage.settle_owed_range(&circle, stale, RangePass::Whole { owing: false });
        assert!(storage.owed_range(&circle) == Some(next));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_settled_range_reads_as_not_owed_without_a_failure() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);
        let cap = u16::try_from(MAX_REFUSED_IDS_PER_GROUP).unwrap();
        storage.record(&circle, &ids(&(0..=cap).collect::<Vec<_>>()), NOW);
        storage.range_tried(&circle, NOW);
        let read = storage.owed_range(&circle).expect("owed");
        storage.settle_owed_range(&circle, read, RangePass::Whole { owing: false });

        let lines = crate::test_log::capture_log_lines(async {
            assert!(storage.owed_range(&circle).is_none());
        })
        .await;
        assert!(
            lines.is_empty(),
            "a tombstone is not owed and not a failed read: {lines:?}"
        );
    }

    #[test]
    fn leaving_a_circle_drops_what_it_was_owed() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);
        let cap = u16::try_from(MAX_REFUSED_IDS_PER_GROUP).unwrap();
        storage.record(&circle, &ids(&(0..=cap).collect::<Vec<_>>()), NOW);
        assert!(storage.owed_range(&circle).is_some());

        storage.delete_circle(&circle).unwrap();

        assert!(storage.owed(&circle, 10, NOW).is_empty());
        assert!(storage.owed_range(&circle).is_none());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_ledger_failure_is_reported_without_an_identifier() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch("DROP TABLE refused_redeliveries; DROP TABLE refused_ranges")
            .unwrap();
        let circle = GroupId::from_slice(&[0xa7; 32]);
        let refused = ids(&[0xc4c4]);

        let lines = crate::test_log::capture_log_lines(async {
            assert!(
                !storage.record(&circle, &refused, NOW),
                "a write that failed was answered as on record: whoever holds the event's only \
                 other copy would let it go",
            );
            assert!(storage.owed(&circle, 10, NOW).is_empty());
            storage.tried(&circle, &refused, NOW, false);
            storage.moved(&circle);
            storage.range_tried(&circle, NOW);
            storage.resolve(&circle, &refused);
            assert!(storage.owed_range(&circle).is_none());
            storage.settle_owed_range(
                &circle,
                OwedRange {
                    until_secs: NOW,
                    walk_secs: NOW,
                    generation: 1,
                    tried_secs: 0,
                    due_secs: 0,
                },
                RangePass::Whole { owing: false },
            );
        })
        .await;

        for expected in [
            "refused object not recorded for refetch",
            "refused objects not read for refetch",
            "refetch attempt not recorded",
            "refetch waits not ended at a new epoch",
            "refetch range attempt not recorded",
            "refetched objects not discharged",
            "refetch range not read",
            "refetch range not recorded",
        ] {
            assert!(
                lines.iter().any(|line| line.contains(expected)),
                "a failed ledger write must be reported, not swallowed: {expected}"
            );
        }
        for needle in [hex::encode(circle.as_slice()), refused[0].to_hex()] {
            for prefix in [&needle[..8], &needle[needle.len() - 8..]] {
                assert!(
                    lines.iter().all(|line| !line.contains(prefix)),
                    "a ledger log line carries an identifier"
                );
            }
        }
        assert!(
            lines.iter().all(|line| !line.contains(&NOW.to_string())),
            "nor an absolute instant"
        );
    }
}
