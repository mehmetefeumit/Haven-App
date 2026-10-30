//! The durable half of [`CommitNotes`], on `circles-v2.db` (the `commit_notes`
//! and `restage_waits` tables in [`CircleStorage::initialize_schema`]).
//!
//! One row per circle in each, keyed as the circle rows are: a flag and a
//! small set of fieldless notes in the first; in the second, while a circle
//! waits before the engine's own commit is staged again, a count and the
//! instant the wait ends — no commit, no member, no relay. And
//! `removal_targets`: the member ids a removal set aside unmade named, one
//! row each, for as long as its note stands. A failure is logged by its
//! storage code alone; what it costs is said at each method of the trait.

#![allow(clippy::significant_drop_tightening)]

use rusqlite::{params, OptionalExtension};

use super::error::{CircleError, Result};
use super::storage::CircleStorage;
use crate::nostr::mls::types::{GroupId, MemberId, MessageId};
use crate::nostr::mls::{
    ChangeNote, ChangeNotice, CommitNotes, EpochStallEvidence, KeptTarget, RestageWait,
    StallEvidence,
};

/// Counts a write of a held member for `group_id`'s notice
/// ([`ChangeNotice`]): a notice read before it acknowledges nothing.
fn count_a_write(tx: &rusqlite::Transaction<'_>, group_id: &GroupId) -> rusqlite::Result<()> {
    tx.execute(
        "INSERT INTO commit_notes (mls_group_id, writes) VALUES (?1, 1)
         ON CONFLICT (mls_group_id) DO UPDATE SET writes = writes + 1",
        params![group_id.as_slice()],
    )?;
    Ok(())
}

impl CircleStorage {
    fn write_removes_nobody(&self, group_id: &GroupId, known: bool) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        conn.execute(
            "INSERT INTO commit_notes (mls_group_id, removes_nobody) VALUES (?1, ?2)
             ON CONFLICT (mls_group_id) DO UPDATE SET removes_nobody = ?2",
            params![group_id.as_slice(), known],
        )?;
        Ok(())
    }

    fn write_repair_mark(&self, group_id: &GroupId, staging: bool) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        if staging {
            conn.execute(
                "INSERT OR IGNORE INTO repair_marks (mls_group_id) VALUES (?1)",
                params![group_id.as_slice()],
            )?;
        } else {
            conn.execute(
                "DELETE FROM repair_marks WHERE mls_group_id = ?1",
                params![group_id.as_slice()],
            )?;
        }
        Ok(())
    }

    fn write_dropped_removal(&self, group_id: &GroupId, commit: &MessageId) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        conn.execute(
            "INSERT OR IGNORE INTO dropped_removals (mls_group_id, commit_id) VALUES (?1, ?2)",
            params![group_id.as_slice(), commit.as_slice()],
        )?;
        Ok(())
    }

    fn delete_dropped_removal(&self, group_id: &GroupId, commit: &MessageId) -> Result<bool> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        Ok(conn.execute(
            "DELETE FROM dropped_removals WHERE mls_group_id = ?1 AND commit_id = ?2",
            params![group_id.as_slice(), commit.as_slice()],
        )? > 0)
    }

    fn read_repair_mark(&self, group_id: &GroupId) -> Result<bool> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        Ok(conn
            .query_row(
                "SELECT 1 FROM repair_marks WHERE mls_group_id = ?1",
                params![group_id.as_slice()],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }

    fn read_removes_nobody(&self, group_id: &GroupId) -> Result<bool> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        Ok(conn
            .query_row(
                "SELECT removes_nobody FROM commit_notes WHERE mls_group_id = ?1",
                params![group_id.as_slice()],
                |row| row.get::<_, bool>(0),
            )
            .optional()?
            .unwrap_or(false))
    }

    fn add_change_note(&self, group_id: &GroupId, note: ChangeNote) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        conn.execute(
            "INSERT INTO commit_notes (mls_group_id, untold, writes) VALUES (?1, ?2, 1)
             ON CONFLICT (mls_group_id) DO UPDATE
             SET untold = untold | ?2, writes = writes + ((untold & ?2) = 0)",
            params![group_id.as_slice(), note.bit()],
        )?;
        Ok(())
    }

    fn add_change_note_to_all(&self, groups: &[&GroupId], note: ChangeNote) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let tx = conn.transaction()?;
        for group_id in groups {
            tx.execute(
                "INSERT INTO commit_notes (mls_group_id, untold, writes) VALUES (?1, ?2, 1)
                 ON CONFLICT (mls_group_id) DO UPDATE
                 SET untold = untold | ?2, writes = writes + ((untold & ?2) = 0)",
                params![group_id.as_slice(), note.bit()],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    fn read_notice(&self, group_id: &GroupId) -> Result<ChangeNotice> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let (untold, writes) = conn
            .query_row(
                "SELECT untold, writes FROM commit_notes WHERE mls_group_id = ?1",
                params![group_id.as_slice()],
                |row| Ok((row.get::<_, u16>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()?
            .unwrap_or((0, 0));
        Ok(ChangeNotice::read(untold, u64::try_from(writes).ok()))
    }

    fn write_acknowledgement(&self, group_id: &GroupId, notice: &ChangeNotice) -> Result<bool> {
        let Some(seen) = notice.seen().and_then(|seen| i64::try_from(seen).ok()) else {
            return Ok(false);
        };
        let mut conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let tx = conn.transaction()?;
        let writes: i64 = tx
            .query_row(
                "SELECT writes FROM commit_notes WHERE mls_group_id = ?1",
                params![group_id.as_slice()],
                |row| row.get(0),
            )
            .optional()?
            .unwrap_or(0);
        if writes != seen {
            return Ok(false);
        }
        let bits = notice.dropped_bits();
        tx.execute(
            "UPDATE commit_notes SET untold = untold & ~?2 WHERE mls_group_id = ?1",
            params![group_id.as_slice(), bits],
        )?;
        // Nothing was written since the read, so the targets are the ones it
        // saw.
        if bits & ChangeNote::QueuedRemovalDropped.bit() != 0 {
            tx.execute(
                "DELETE FROM removal_targets WHERE mls_group_id = ?1",
                params![group_id.as_slice()],
            )?;
        }
        tx.commit()?;
        Ok(true)
    }

    fn clear_change_note(&self, group_id: &GroupId, note: ChangeNote) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let tx = conn.transaction()?;
        tx.execute(
            "UPDATE commit_notes SET untold = untold & ~?2 WHERE mls_group_id = ?1",
            params![group_id.as_slice(), note.bit()],
        )?;
        // The targets are the note's: neither outlives the other.
        if note == ChangeNote::QueuedRemovalDropped {
            tx.execute(
                "DELETE FROM removal_targets WHERE mls_group_id = ?1",
                params![group_id.as_slice()],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    fn write_removal_targets(
        &self,
        group_id: &GroupId,
        targets: &[MemberId],
        set_aside_epoch: u64,
        asks: u32,
    ) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let tx = conn.transaction()?;
        count_a_write(&tx, group_id)?;
        for target in targets {
            // A removal set aside again is a new one: its count and its epoch
            // start over.
            tx.execute(
                "INSERT OR REPLACE INTO removal_targets
                 (mls_group_id, member, set_aside_epoch, asks, gone_epoch, gone_by)
                 VALUES (?1, ?2, ?3, ?4, NULL, NULL)",
                params![
                    group_id.as_slice(),
                    target.as_slice(),
                    i64::try_from(set_aside_epoch).unwrap_or(i64::MAX),
                    asks
                ],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    fn read_kept_removals(&self, group_id: &GroupId) -> Result<Vec<KeptTarget>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let mut statement = conn.prepare(
            "SELECT member, set_aside_epoch, asks FROM removal_targets
             WHERE mls_group_id = ?1 AND gone_epoch IS NULL",
        )?;
        let targets = statement
            .query_map(params![group_id.as_slice()], |row| {
                Ok(KeptTarget {
                    member: MemberId::new(row.get::<_, Vec<u8>>(0)?),
                    set_aside_epoch: u64::try_from(row.get::<_, i64>(1)?).unwrap_or(0),
                    asks: row.get::<_, u32>(2)?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?;
        Ok(targets)
    }

    fn write_removal_targets_out(
        &self,
        group_id: &GroupId,
        members: &[MemberId],
        epoch: u64,
        by: Option<&MessageId>,
    ) -> Result<bool> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let mut changed = 0;
        for member in members {
            changed += conn.execute(
                "UPDATE removal_targets SET gone_epoch = ?3, gone_by = ?4
                 WHERE mls_group_id = ?1 AND member = ?2 AND gone_epoch IS NULL",
                params![
                    group_id.as_slice(),
                    member.as_slice(),
                    i64::try_from(epoch).unwrap_or(i64::MAX),
                    by.map(MessageId::as_slice)
                ],
            )?;
        }
        Ok(changed > 0)
    }

    fn write_removal_targets_back(
        &self,
        group_id: &GroupId,
        by: &MessageId,
        unkeyed_asks: u32,
    ) -> Result<bool> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let tx = conn.transaction()?;
        let back = tx.execute(
            "UPDATE removal_targets
             SET asks = CASE WHEN gone_by IS ?2 THEN asks ELSE MAX(asks, ?3) END,
                 gone_epoch = NULL, gone_by = NULL
             WHERE mls_group_id = ?1 AND gone_epoch IS NOT NULL",
            params![group_id.as_slice(), by.as_slice(), unkeyed_asks],
        )? > 0;
        if back {
            count_a_write(&tx, group_id)?;
        }
        tx.commit()?;
        Ok(back)
    }

    fn write_spent_removal_asks(&self, group_id: &GroupId, asks: u32) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        conn.execute(
            "UPDATE removal_targets SET asks = MAX(asks, ?2)
             WHERE mls_group_id = ?1 AND gone_epoch IS NULL",
            params![group_id.as_slice(), asks],
        )?;
        Ok(())
    }

    fn read_taken_out_by(
        &self,
        group_id: &GroupId,
        member: &MemberId,
    ) -> Result<Option<MessageId>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let by: Option<Option<Vec<u8>>> = conn
            .query_row(
                "SELECT gone_by FROM removal_targets
                 WHERE mls_group_id = ?1 AND member = ?2 AND gone_epoch IS NOT NULL",
                params![group_id.as_slice(), member.as_slice()],
                |row| row.get(0),
            )
            .optional()?;
        Ok(by.flatten().map(MessageId::new))
    }

    fn write_spent_target_asks(
        &self,
        group_id: &GroupId,
        members: &[MemberId],
        asks: u32,
    ) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let tx = conn.transaction()?;
        for member in members {
            tx.execute(
                "UPDATE removal_targets SET asks = MAX(asks, ?3)
                 WHERE mls_group_id = ?1 AND member = ?2",
                params![group_id.as_slice(), member.as_slice(), asks],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    fn delete_gone_removal_targets(&self, group_id: &GroupId, before_epoch: u64) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        conn.execute(
            "DELETE FROM removal_targets WHERE mls_group_id = ?1 AND gone_epoch < ?2",
            params![
                group_id.as_slice(),
                i64::try_from(before_epoch).unwrap_or(i64::MAX)
            ],
        )?;
        Ok(())
    }

    fn write_removal_asks(
        &self,
        group_id: &GroupId,
        members: &[MemberId],
    ) -> Result<Vec<(MemberId, u32)>> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let tx = conn.transaction()?;
        let mut counted = Vec::new();
        for member in members {
            let written: Option<u32> = tx
                .query_row(
                    "UPDATE removal_targets SET asks = asks + 1
                     WHERE mls_group_id = ?1 AND member = ?2 RETURNING asks",
                    params![group_id.as_slice(), member.as_slice()],
                    |row| row.get(0),
                )
                .optional()?;
            if let Some(asks) = written {
                counted.push((member.clone(), asks));
            }
        }
        tx.commit()?;
        Ok(counted)
    }

    fn write_refunded_removal_asks(
        &self,
        group_id: &GroupId,
        counted: &[(MemberId, u32)],
    ) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let tx = conn.transaction()?;
        for (member, asks) in counted {
            tx.execute(
                "UPDATE removal_targets SET asks = ?3 - 1
                 WHERE mls_group_id = ?1 AND member = ?2 AND asks = ?3",
                params![group_id.as_slice(), member.as_slice(), asks],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    fn settle_removal_note(&self, group_id: &GroupId) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        conn.execute(
            "UPDATE commit_notes SET untold = untold & ~?2 WHERE mls_group_id = ?1",
            params![group_id.as_slice(), ChangeNote::QueuedRemovalDropped.bit()],
        )?;
        Ok(())
    }

    fn write_welcome_route(
        &self,
        group_id: &GroupId,
        recipient: &str,
        relays: &[String],
        not_after: Option<u64>,
    ) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        conn.execute(
            "INSERT OR REPLACE INTO welcome_routes (mls_group_id, recipient, relays, not_after)
             VALUES (?1, ?2, ?3, ?4)",
            params![
                group_id.as_slice(),
                recipient,
                relays.join("\n"),
                not_after.map(|secs| i64::try_from(secs).unwrap_or(i64::MAX)),
            ],
        )?;
        Ok(())
    }

    fn read_welcome_route(
        &self,
        group_id: &GroupId,
        recipient: &str,
    ) -> Result<Option<crate::nostr::mls::KeptWelcomeRoute>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        Ok(conn
            .query_row(
                "SELECT relays, not_after FROM welcome_routes
                 WHERE mls_group_id = ?1 AND recipient = ?2",
                params![group_id.as_slice(), recipient],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
            )
            .optional()?
            .map(|(relays, not_after)| {
                (
                    relays.lines().map(str::to_owned).collect(),
                    not_after.map(|secs| u64::try_from(secs).unwrap_or(0)),
                )
            }))
    }

    /// Forgets every Welcome route kept for `group_id`.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub(crate) fn forget_welcome_routes(&self, group_id: &GroupId) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        conn.execute(
            "DELETE FROM welcome_routes WHERE mls_group_id = ?1",
            params![group_id.as_slice()],
        )?;
        Ok(())
    }

    fn delete_welcome_route(&self, group_id: &GroupId, recipient: &str) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        conn.execute(
            "DELETE FROM welcome_routes WHERE mls_group_id = ?1 AND recipient = ?2",
            params![group_id.as_slice(), recipient],
        )?;
        Ok(())
    }

    fn read_change_notes(&self, group_id: &GroupId) -> Result<Vec<ChangeNote>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        Ok(ChangeNote::of(
            conn.query_row(
                "SELECT untold FROM commit_notes WHERE mls_group_id = ?1",
                params![group_id.as_slice()],
                |row| row.get::<_, u16>(0),
            )
            .optional()?
            .unwrap_or(0),
        ))
    }

    fn read_restage_wait(&self, group_id: &GroupId) -> Result<Option<RestageWait>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        Ok(conn
            .query_row(
                "SELECT rollbacks, not_before_ms FROM restage_waits WHERE mls_group_id = ?1",
                params![group_id.as_slice()],
                |row| Ok((row.get::<_, u32>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()?
            .map(|(rollbacks, not_before)| RestageWait {
                rollbacks,
                not_before_ms: u64::try_from(not_before).unwrap_or(0),
            }))
    }

    fn write_restage_wait(&self, group_id: &GroupId, wait: Option<RestageWait>) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        match wait {
            Some(wait) => conn.execute(
                "INSERT INTO restage_waits (mls_group_id, rollbacks, not_before_ms)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT (mls_group_id) DO UPDATE SET rollbacks = ?2, not_before_ms = ?3",
                params![
                    group_id.as_slice(),
                    wait.rollbacks,
                    i64::try_from(wait.not_before_ms).unwrap_or(i64::MAX)
                ],
            )?,
            None => conn.execute(
                "DELETE FROM restage_waits WHERE mls_group_id = ?1",
                params![group_id.as_slice()],
            )?,
        };
        Ok(())
    }
}

impl CircleStorage {
    fn read_stall_evidence(&self) -> Result<Vec<(GroupId, EpochStallEvidence)>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let mut stmt = conn.prepare(
            "SELECT mls_group_id, stalled_epoch, fruitless_completions, fruitless_reported,
                    last_arm_at_ms
             FROM epoch_stall_evidence",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((
                GroupId::new(row.get::<_, Vec<u8>>(0)?),
                EpochStallEvidence::from_parts(
                    u64::try_from(row.get::<_, i64>(1)?).unwrap_or(0),
                    u32::try_from(row.get::<_, i64>(2)?).unwrap_or(u32::MAX),
                    row.get::<_, bool>(3)?,
                    u64::try_from(row.get::<_, i64>(4)?).unwrap_or(0),
                ),
            ))
        })?;
        Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
    }

    fn write_stall_evidence(&self, group_id: &GroupId, evidence: EpochStallEvidence) -> Result<()> {
        let (epoch, completions, reported, last_arm_at_ms) = evidence.parts();
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        conn.execute(
            "INSERT INTO epoch_stall_evidence (mls_group_id, stalled_epoch,
                 fruitless_completions, fruitless_reported, last_arm_at_ms)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT (mls_group_id) DO UPDATE SET stalled_epoch = ?2,
                 fruitless_completions = ?3, fruitless_reported = ?4, last_arm_at_ms = ?5",
            params![
                group_id.as_slice(),
                i64::try_from(epoch).unwrap_or(i64::MAX),
                i64::from(completions),
                reported,
                i64::try_from(last_arm_at_ms).unwrap_or(i64::MAX)
            ],
        )?;
        Ok(())
    }

    fn delete_stall_evidence(&self, group_id: &GroupId) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        conn.execute(
            "DELETE FROM epoch_stall_evidence WHERE mls_group_id = ?1",
            params![group_id.as_slice()],
        )?;
        Ok(())
    }
}

impl StallEvidence for CircleStorage {
    fn stall_evidence(&self) -> Vec<(GroupId, EpochStallEvidence)> {
        self.read_stall_evidence().unwrap_or_else(|e| {
            log::warn!("a circle's stall evidence was not read: {}", e.code());
            Vec::new()
        })
    }

    fn keep_stall_evidence(&self, group_id: &GroupId, evidence: EpochStallEvidence) -> bool {
        self.write_stall_evidence(group_id, evidence)
            .inspect_err(|e| log::warn!("a circle's stall evidence was not kept: {}", e.code()))
            .is_ok()
    }

    fn forget_stall_evidence(&self, group_id: &GroupId) {
        if let Err(e) = self.delete_stall_evidence(group_id) {
            log::warn!("a circle's stall evidence was not forgotten: {}", e.code());
        }
    }
}

impl CommitNotes for CircleStorage {
    fn set_removes_nobody(&self, group_id: &GroupId, known: bool) -> bool {
        self.write_removes_nobody(group_id, known)
            .inspect_err(|e| log::warn!("a commit's removal mark was not written: {}", e.code()))
            .is_ok()
    }

    fn removes_nobody(&self, group_id: &GroupId) -> bool {
        self.read_removes_nobody(group_id).unwrap_or_else(|e| {
            log::warn!("a commit's removal mark was not read: {}", e.code());
            false
        })
    }

    fn mark_repair(&self, group_id: &GroupId, staging: bool) -> bool {
        self.write_repair_mark(group_id, staging)
            .inspect_err(|e| log::warn!("a repair's mark was not written: {}", e.code()))
            .is_ok()
    }

    fn repair_marked(&self, group_id: &GroupId) -> Option<bool> {
        self.read_repair_mark(group_id)
            .inspect_err(|e| log::warn!("a repair's mark was not read: {}", e.code()))
            .ok()
    }

    fn keep_dropped_removal(&self, group_id: &GroupId, commit: &MessageId) -> bool {
        self.write_dropped_removal(group_id, commit)
            .inspect_err(|e| log::warn!("a dropped removal was not recorded: {}", e.code()))
            .is_ok()
    }

    fn take_dropped_removal(&self, group_id: &GroupId, commit: &MessageId) -> Option<bool> {
        self.delete_dropped_removal(group_id, commit)
            .inspect_err(|e| log::warn!("a dropped removal was not read: {}", e.code()))
            .ok()
    }

    fn note(&self, group_id: &GroupId, note: ChangeNote) -> bool {
        self.add_change_note(group_id, note)
            .inspect_err(|e| log::warn!("a change's outcome was not recorded: {}", e.code()))
            .is_ok()
    }

    fn note_all(&self, groups: &[&GroupId], note: ChangeNote) -> bool {
        self.add_change_note_to_all(groups, note)
            .inspect_err(|e| log::warn!("a change's outcome was not recorded: {}", e.code()))
            .is_ok()
    }

    fn peek(&self, group_id: &GroupId) -> Vec<ChangeNote> {
        self.read_change_notes(group_id).unwrap_or_else(|e| {
            log::warn!("a circle's change outcomes were not read: {}", e.code());
            Vec::new()
        })
    }

    fn notice(&self, group_id: &GroupId) -> ChangeNotice {
        self.read_notice(group_id).unwrap_or_else(|e| {
            log::warn!("a circle's change outcomes were not read: {}", e.code());
            ChangeNotice::read(0, None)
        })
    }

    fn acknowledge(&self, group_id: &GroupId, notice: &ChangeNotice) -> bool {
        self.write_acknowledgement(group_id, notice)
            .unwrap_or_else(|e| {
                log::warn!("a change's outcome was not cleared: {}", e.code());
                false
            })
    }

    fn stands(&self, group_id: &GroupId, note: ChangeNote) -> Option<bool> {
        self.read_change_notes(group_id)
            .inspect_err(|e| log::warn!("a circle's change outcomes were not read: {}", e.code()))
            .ok()
            .map(|told| told.contains(&note))
    }

    fn clear(&self, group_id: &GroupId, note: ChangeNote) {
        if let Err(e) = self.clear_change_note(group_id, note) {
            log::warn!("a change's outcome was not cleared: {}", e.code());
        }
    }

    fn keep_removal_targets(
        &self,
        group_id: &GroupId,
        targets: &[MemberId],
        set_aside_epoch: u64,
        asks: u32,
    ) -> bool {
        self.write_removal_targets(group_id, targets, set_aside_epoch, asks)
            .inspect_err(|e| log::warn!("a removal's targets were not kept: {}", e.code()))
            .is_ok()
    }

    fn take_out_removal_targets(
        &self,
        group_id: &GroupId,
        members: &[MemberId],
        epoch: u64,
        by: Option<&MessageId>,
    ) -> bool {
        self.write_removal_targets_out(group_id, members, epoch, by)
            .unwrap_or_else(|e| {
                log::warn!("a removal's targets were not marked: {}", e.code());
                false
            })
    }

    fn bring_back_removal_targets(
        &self,
        group_id: &GroupId,
        by: &MessageId,
        unkeyed_asks: u32,
    ) -> bool {
        self.write_removal_targets_back(group_id, by, unkeyed_asks)
            .unwrap_or_else(|e| {
                log::warn!("a removal's targets were not brought back: {}", e.code());
                false
            })
    }

    fn spend_removal_asks(&self, group_id: &GroupId, asks: u32) -> bool {
        self.write_spent_removal_asks(group_id, asks)
            .inspect_err(|e| log::warn!("a removal's asks were not spent: {}", e.code()))
            .is_ok()
    }

    fn taken_out_by(&self, group_id: &GroupId, member: &MemberId) -> Option<MessageId> {
        self.read_taken_out_by(group_id, member)
            .inspect_err(|e| log::warn!("a removal's targets were not read: {}", e.code()))
            .ok()
            .flatten()
    }

    fn spend_target_asks(&self, group_id: &GroupId, members: &[MemberId], asks: u32) -> bool {
        self.write_spent_target_asks(group_id, members, asks)
            .inspect_err(|e| log::warn!("a removal's asks were not spent: {}", e.code()))
            .is_ok()
    }

    fn forget_gone_removal_targets(&self, group_id: &GroupId, before_epoch: u64) {
        if let Err(e) = self.delete_gone_removal_targets(group_id, before_epoch) {
            log::warn!("a removal's targets were not forgotten: {}", e.code());
        }
    }

    fn count_removal_asks(
        &self,
        group_id: &GroupId,
        members: &[MemberId],
    ) -> Option<Vec<(MemberId, u32)>> {
        self.write_removal_asks(group_id, members)
            .inspect_err(|e| log::warn!("a removal's asks were not counted: {}", e.code()))
            .ok()
    }

    fn refund_removal_asks(&self, group_id: &GroupId, counted: &[(MemberId, u32)]) {
        if let Err(e) = self.write_refunded_removal_asks(group_id, counted) {
            log::warn!("a removal's ask was not given back: {}", e.code());
        }
    }

    fn settle_removal(&self, group_id: &GroupId) {
        if let Err(e) = self.settle_removal_note(group_id) {
            log::warn!("a change's outcome was not cleared: {}", e.code());
        }
    }

    fn leaving(&self, group_id: &GroupId) -> Option<bool> {
        self.has_leave_intent(group_id)
            .inspect_err(|e| log::warn!("a leave intent was not read: {}", e.code()))
            .ok()
    }

    fn circle_stands(&self, group_id: &GroupId) -> Option<bool> {
        self.get_circle(group_id)
            .inspect_err(|e| log::warn!("a circle's row was not read: {}", e.code()))
            .ok()
            .map(|circle| circle.is_some())
    }

    fn keep_welcome_route(
        &self,
        group_id: &GroupId,
        recipient: &str,
        relays: &[String],
        not_after: Option<u64>,
    ) -> bool {
        self.write_welcome_route(group_id, recipient, relays, not_after)
            .inspect_err(|e| log::warn!("a Welcome's route was not kept: {}", e.code()))
            .is_ok()
    }

    fn welcome_route(
        &self,
        group_id: &GroupId,
        recipient: &str,
    ) -> std::result::Result<
        Option<crate::nostr::mls::KeptWelcomeRoute>,
        crate::nostr::mls::RouteUnread,
    > {
        self.read_welcome_route(group_id, recipient).map_err(|e| {
            log::warn!("a Welcome's route was not read: {}", e.code());
            crate::nostr::mls::RouteUnread
        })
    }

    fn forget_welcome_route(&self, group_id: &GroupId, recipient: &str) {
        if let Err(e) = self.delete_welcome_route(group_id, recipient) {
            log::warn!("a Welcome's route was not forgotten: {}", e.code());
        }
    }

    fn removal_targets(&self, group_id: &GroupId) -> Option<Vec<MemberId>> {
        self.kept_removals(group_id)
            .map(|kept| kept.into_iter().map(|target| target.member).collect())
    }

    fn kept_removals(&self, group_id: &GroupId) -> Option<Vec<KeptTarget>> {
        self.read_kept_removals(group_id)
            .inspect_err(|e| log::warn!("a removal's targets were not read: {}", e.code()))
            .ok()
    }

    fn restage_wait(&self, group_id: &GroupId) -> Option<RestageWait> {
        self.read_restage_wait(group_id).unwrap_or_else(|e| {
            log::warn!("a circle's re-staging wait was not read: {}", e.code());
            None
        })
    }

    fn set_restage_wait(&self, group_id: &GroupId, wait: Option<RestageWait>) {
        if let Err(e) = self.write_restage_wait(group_id, wait) {
            log::warn!("a circle's re-staging wait was not written: {}", e.code());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nostr::mls::types::GroupIdExt;

    #[test]
    fn a_stored_notice_drops_only_what_it_read() {
        crate::nostr::mls::a_notice_drops_only_what_it_read(&CircleStorage::in_memory().unwrap());
    }

    /// A note written to two circles at once lands on both or on neither: a
    /// routing collision noted on one of its two circles alone would leave
    /// the other sharing. The line a refused note writes names neither
    /// circle, though the store's own refusal names both.
    #[tokio::test(flavor = "current_thread")]
    async fn a_note_for_two_circles_lands_on_both_or_neither() {
        let storage = CircleStorage::in_memory().unwrap();
        let (first, second) = (
            GroupId::from_slice(&[0x31; 16]),
            GroupId::from_slice(&[0x32; 16]),
        );
        let planted = [
            hex::encode(first.as_slice()),
            hex::encode(second.as_slice()),
        ];
        storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch(&format!(
                "CREATE TRIGGER refuse_second BEFORE INSERT ON commit_notes
                 WHEN NEW.mls_group_id = X'{}'
                 BEGIN SELECT RAISE(ABORT, 'refused {} {}'); END;",
                planted[1], planted[0], planted[1],
            ))
            .unwrap();
        let mut noted = true;
        let lines = crate::test_log::capture_log_lines(async {
            noted = storage.note_all(&[&first, &second], ChangeNote::RoutingCollision);
        })
        .await;
        assert!(!noted, "premise: the store refused the note");
        assert!(
            lines
                .iter()
                .any(|line| line.contains("a change's outcome was not recorded")),
            "premise: the refusal is logged",
        );
        assert!(
            lines
                .iter()
                .all(|line| planted.iter().all(|id| !line.contains(id.as_str()))),
            "a refused note's line named a circle",
        );
        assert_eq!(
            storage.stands(&first, ChangeNote::RoutingCollision),
            Some(false),
            "the note landed on one circle of the two",
        );
        storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch("DROP TRIGGER refuse_second;")
            .unwrap();
        assert!(storage.note_all(&[&first, &second], ChangeNote::RoutingCollision));
        assert!(
            [&first, &second]
                .iter()
                .all(|group| storage.stands(group, ChangeNote::RoutingCollision) == Some(true)),
            "the note did not land on both",
        );
    }

    /// Who a removal set aside unmade named is kept per circle, once each,
    /// with its epoch and count, across a reopen; a member an applied commit
    /// took out stops holding, comes back when that commit is withdrawn, and
    /// is forgotten past the horizon; the note can be taken back with the targets kept;
    /// and the user's acknowledgement takes both — and no other note does.
    #[test]
    fn a_removals_targets_are_kept_with_its_note_and_end_with_it() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("circles.db");
        let circle = GroupId::from_slice(&[1; 32]);
        let other = GroupId::from_slice(&[2; 32]);
        let member = |seed: u8| MemberId::new(vec![seed; 32]);
        let held = |storage: &CircleStorage, group: &GroupId| {
            let mut held = storage.removal_targets(group).expect("read");
            held.sort_by(|a, b| a.as_slice().cmp(b.as_slice()));
            held
        };
        {
            let storage = CircleStorage::new(&path, None).unwrap();
            assert_eq!(storage.removal_targets(&circle), Some(Vec::new()));
            assert!(storage.note(&circle, ChangeNote::QueuedRemovalDropped));
            assert!(storage.keep_removal_targets(&circle, &[member(3), member(4)], 7, 0));
            assert!(storage.count_removal_asks(&circle, &[member(4)]).is_some());
            assert!(storage.keep_removal_targets(&circle, &[member(4), member(5)], 9, 0));
            assert!(storage.count_removal_asks(&circle, &[member(5)]).is_some());
            assert!(storage.keep_removal_targets(&other, &[member(9)], 1, 2));
        }
        let storage = CircleStorage::new(&path, None).unwrap();
        assert!(
            held(&storage, &circle) == [member(3), member(4), member(5)]
                && storage
                    .kept_removals(&circle)
                    .expect("read")
                    .iter()
                    .all(|kept| {
                        (kept.set_aside_epoch == 7) == (kept.member == member(3))
                            && (kept.asks == 1) == (kept.member == member(5))
                    }),
            "a removal's targets were lost at a reopen, kept twice, or did not start over",
        );
        let commit = MessageId::new(vec![0xc0; 32]);
        let other_commit = MessageId::new(vec![0xc1; 32]);
        let asks = |storage: &CircleStorage, seed: u8| {
            storage
                .kept_removals(&circle)
                .expect("read")
                .into_iter()
                .find(|kept| kept.member == member(seed))
                .map(|kept| kept.asks)
        };
        assert!(
            storage.take_out_removal_targets(&circle, &[member(4)], 12, Some(&commit))
                && !storage.take_out_removal_targets(&circle, &[member(4)], 13, None)
                && storage.take_out_removal_targets(&circle, &[member(5)], 12, None)
                && held(&storage, &circle) == [member(3)]
                && storage.bring_back_removal_targets(&circle, &other_commit, 2)
                && held(&storage, &circle).len() == 3
                && asks(&storage, 4) == Some(2)
                && asks(&storage, 5) == Some(2),
            "a member a commit took out still holds, or a withdrawal of another commit did not \
             bring every one back with its asks spent",
        );
        assert!(
            storage.take_out_removal_targets(&circle, &[member(5)], 12, Some(&commit))
                && storage.spend_removal_asks(&circle, 2)
                && asks(&storage, 3) == Some(2)
                && storage.bring_back_removal_targets(&circle, &commit, 2)
                && held(&storage, &circle).len() == 3,
            "a pass of several commits did not spend every held target's asks, or the \
             withdrawal of the commit a target is keyed to did not bring it back",
        );
        assert!(storage.take_out_removal_targets(&circle, &[member(4)], 12, Some(&commit)));
        storage.forget_gone_removal_targets(&circle, 12);
        assert!(
            storage.bring_back_removal_targets(&circle, &commit, 2)
                && storage.take_out_removal_targets(&circle, &[member(4)], 12, Some(&commit)),
            "a member taken out at the horizon's edge was forgotten",
        );
        storage.forget_gone_removal_targets(&circle, 13);
        assert!(
            !storage.bring_back_removal_targets(&circle, &commit, 2)
                && held(&storage, &circle) == [member(3), member(5)],
            "a member taken out past the horizon was not forgotten",
        );
        storage.settle_removal(&circle);
        assert!(
            !storage
                .peek(&circle)
                .contains(&ChangeNote::QueuedRemovalDropped)
                && held(&storage, &circle).len() == 2,
            "taking the note back took the targets, or left the note",
        );
        storage.clear(&circle, ChangeNote::ChangeUndone);
        assert!(
            held(&storage, &circle).len() == 2,
            "clearing another note took a removal's targets",
        );
        storage.clear(&circle, ChangeNote::QueuedRemovalDropped);
        assert!(
            storage.removal_targets(&circle) == Some(Vec::new())
                && storage.removal_targets(&other) == Some(vec![member(9)]),
            "a removal's targets outlived its note, or another circle's went with them",
        );
    }

    /// A store that fails says so by its storage code alone: no circle and
    /// no member.
    #[tokio::test(flavor = "current_thread")]
    async fn a_failure_to_keep_or_read_a_removals_targets_names_nobody() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch("DROP TABLE removal_targets; DROP TABLE commit_notes;")
            .unwrap();
        let circle = GroupId::from_slice(&[0xa7; 32]);
        let named = MemberId::new(vec![0xc4; 32]);
        let commit = MessageId::new(vec![0xd9; 32]);
        let lines = crate::test_log::capture_log_lines(async {
            let named = std::slice::from_ref(&named);
            assert!(!storage.keep_removal_targets(&circle, named, 0x5e17, 0));
            assert!(storage.removal_targets(&circle).is_none());
            assert!(storage.kept_removals(&circle).is_none());
            assert!(!storage.take_out_removal_targets(&circle, named, 0x5e17, Some(&commit)));
            assert!(!storage.bring_back_removal_targets(&circle, &commit, 2));
            assert!(!storage.spend_removal_asks(&circle, 2));
            assert!(storage.taken_out_by(&circle, &named[0]).is_none());
            assert!(!storage.spend_target_asks(&circle, named, 2));
            storage.forget_gone_removal_targets(&circle, 0x5e17);
            assert!(storage.count_removal_asks(&circle, named).is_none());
            storage.refund_removal_asks(&circle, &[(named[0].clone(), 1)]);
            storage.settle_removal(&circle);
            assert!(storage.notice(&circle).notes.is_empty());
            assert!(!storage.acknowledge(
                &circle,
                &ChangeNotice::read(ChangeNote::ChangeWithdrawn.bit(), Some(0)),
            ));
        })
        .await;
        for expected in [
            "a removal's targets were not kept",
            "a removal's targets were not read",
            "a removal's targets were not marked",
            "a removal's targets were not brought back",
            "a removal's asks were not spent",
            "a removal's targets were not forgotten",
            "a removal's asks were not counted",
            "a removal's ask was not given back",
            "a change's outcome was not cleared",
            "a circle's change outcomes were not read",
        ] {
            assert!(
                lines.iter().any(|line| line.contains(expected)),
                "a failed write or read of a removal's targets must be reported: {expected}"
            );
        }
        for needle in [
            hex::encode(circle.as_slice()),
            hex::encode(named.as_slice()),
            hex::encode(commit.as_slice()),
        ] {
            for prefix in [&needle[..8], &needle[needle.len() - 8..]] {
                assert!(
                    lines.iter().all(|line| !line.contains(prefix)),
                    "a line about a removal's targets carries an identifier"
                );
            }
        }
        assert!(
            lines
                .iter()
                .all(|line| !line.contains("5e17") && !line.contains("24087")),
            "a line about a removal's targets carries its epoch",
        );
    }

    /// An ask given back is given back only while its count reads what the
    /// spend wrote: one spent to the bound meanwhile — a pass of several
    /// commits, a re-invite (decision 230) — stays spent.
    #[test]
    fn an_ask_given_back_never_undoes_a_spend_made_since() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[0xa7; 32]);
        let (spent, refunded) = (MemberId::new(vec![1; 32]), MemberId::new(vec![2; 32]));
        assert!(storage.keep_removal_targets(&circle, &[spent.clone(), refunded.clone()], 3, 0));
        let counted = storage
            .count_removal_asks(&circle, &[spent.clone(), refunded.clone()])
            .expect("counted");
        assert!(storage.spend_target_asks(&circle, std::slice::from_ref(&spent), 2));
        storage.refund_removal_asks(&circle, &counted);
        let asks = |member: &MemberId| {
            storage
                .kept_removals(&circle)
                .expect("read")
                .into_iter()
                .find(|kept| &kept.member == member)
                .map(|kept| kept.asks)
        };
        assert_eq!(
            asks(&spent),
            Some(2),
            "a refund undid a spend made since the ask"
        );
        assert_eq!(
            asks(&refunded),
            Some(0),
            "an ask nothing spent since was not given back"
        );
    }

    /// A Welcome's route is kept per circle and per invitee, read back as it
    /// was kept, survives a reopen of the store, and is forgotten alone.
    #[test]
    fn a_welcomes_route_is_kept_per_circle_and_invitee_until_forgotten() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("circles.db");
        let circle = GroupId::from_slice(&[0xa7; 32]);
        let other = GroupId::from_slice(&[0xa8; 32]);
        let relays = vec![
            "wss://one.route.example.com".to_string(),
            "wss://two.route.example.com".to_string(),
        ];
        {
            let storage = CircleStorage::new(&path, None).unwrap();
            assert!(storage.keep_welcome_route(&circle, "aa", &relays, Some(1_900_000_000)));
            assert!(storage.keep_welcome_route(&other, "aa", &relays[..1], None));
        }
        let storage = CircleStorage::new(&path, None).unwrap();
        assert_eq!(
            storage.welcome_route(&circle, "aa"),
            Ok(Some((relays.clone(), Some(1_900_000_000))))
        );
        assert_eq!(
            storage.welcome_route(&other, "aa"),
            Ok(Some((relays[..1].to_vec(), None)))
        );
        assert_eq!(storage.welcome_route(&circle, "bb"), Ok(None));
        storage.forget_welcome_route(&circle, "aa");
        assert_eq!(storage.welcome_route(&circle, "aa"), Ok(None));
        assert_eq!(
            storage.welcome_route(&other, "aa"),
            Ok(Some((relays[..1].to_vec(), None))),
            "forgetting one circle's route took another's",
        );
    }

    /// A store that fails to keep, read or forget a Welcome's route says so
    /// by its storage code alone: no circle, no invitee, no relay.
    #[tokio::test(flavor = "current_thread")]
    async fn a_failure_to_keep_or_read_a_welcomes_route_names_nobody() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch("DROP TABLE welcome_routes;")
            .unwrap();
        let circle = GroupId::from_slice(&[0xa7; 32]);
        let invitee = hex::encode([0xc4; 32]);
        let relay = "wss://route-canary9e2b.example.com";
        let lines = crate::test_log::capture_log_lines(async {
            assert!(!storage.keep_welcome_route(&circle, &invitee, &[relay.to_string()], None));
            assert!(storage.welcome_route(&circle, &invitee).is_err());
            storage.forget_welcome_route(&circle, &invitee);
        })
        .await;
        for expected in [
            "a Welcome's route was not kept",
            "a Welcome's route was not read",
            "a Welcome's route was not forgotten",
        ] {
            assert!(
                lines.iter().any(|line| line.contains(expected)),
                "a failed write or read of a Welcome's route must be reported: {expected}"
            );
        }
        for needle in [hex::encode(circle.as_slice()), invitee] {
            for prefix in [&needle[..8], &needle[needle.len() - 8..]] {
                assert!(
                    lines.iter().all(|line| !line.contains(prefix)),
                    "a line about a Welcome's route carries an identifier"
                );
            }
        }
        assert!(
            lines.iter().all(|line| !line.contains("route-canary9e2b")),
            "a line about a Welcome's route carries a relay",
        );
    }

    #[test]
    fn a_circles_removal_mark_is_unknown_until_set_and_after_it_is_cleared() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);
        let other = GroupId::from_slice(&[2; 32]);

        assert!(
            !storage.removes_nobody(&circle),
            "a missing mark is a removal"
        );
        assert!(storage.set_removes_nobody(&circle, true));
        assert!(storage.removes_nobody(&circle));
        assert!(
            !storage.removes_nobody(&other),
            "the mark is the circle's own"
        );
        assert!(storage.set_removes_nobody(&circle, false));
        assert!(!storage.removes_nobody(&circle));
    }

    #[test]
    fn a_note_is_kept_until_it_is_cleared_and_reading_it_takes_nothing() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);
        let other = GroupId::from_slice(&[2; 32]);

        assert!(storage.note(&circle, ChangeNote::RemovalUndone));
        assert!(storage.note(&circle, ChangeNote::MayBeOutOfStep));
        assert!(storage.note(&circle, ChangeNote::RemovalUndone));
        assert!(storage.peek(&other).is_empty());
        assert_eq!(
            storage.peek(&circle),
            [ChangeNote::RemovalUndone, ChangeNote::MayBeOutOfStep]
        );
        assert_eq!(
            storage.peek(&circle),
            [ChangeNote::RemovalUndone, ChangeNote::MayBeOutOfStep],
            "reading a note took it",
        );
        storage.clear(&circle, ChangeNote::RemovalUndone);
        storage.clear(&circle, ChangeNote::MayBeOutOfStep);
        assert!(storage.peek(&circle).is_empty());

        assert!(storage.note(&circle, ChangeNote::ChangeUndone));
        assert!(storage.note(&circle, ChangeNote::QueuedChangesHeld));
        storage.clear(&circle, ChangeNote::ChangeUndone);
        storage.clear(&other, ChangeNote::QueuedChangesHeld);
        assert_eq!(
            storage.peek(&circle),
            [ChangeNote::QueuedChangesHeld],
            "telling a circle one thing forgot another, or told another circle",
        );
    }

    /// A store that cannot be written or read fails towards the careful
    /// answer — the commit may remove a member, nothing is known to be
    /// untold — and says so in a line that names no circle.
    #[tokio::test]
    async fn a_failing_store_answers_carefully_and_names_no_circle() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[0xc7; 32]);
        assert!(storage.set_removes_nobody(&circle, true));
        assert!(storage.note(&circle, ChangeNote::RemovalUndone));
        storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch(
                "ALTER TABLE commit_notes RENAME TO elsewhere;
                 ALTER TABLE restage_waits RENAME TO elsewhere_too;",
            )
            .unwrap();

        let lines = crate::test_log::capture_log_lines(async {
            assert!(!storage.set_removes_nobody(&circle, true));
            assert!(
                !storage.removes_nobody(&circle),
                "a mark that cannot be read was read as removing nobody",
            );
            assert!(
                !storage.note(&circle, ChangeNote::ChangeUndone),
                "a note that was not written was reported as written",
            );
            storage.clear(&circle, ChangeNote::RemovalUndone);
            assert!(storage.peek(&circle).is_empty());
            assert_eq!(
                storage.stands(&circle, ChangeNote::RemovalUndone),
                None,
                "a note that cannot be read was read as not standing",
            );
            storage.set_restage_wait(
                &circle,
                Some(RestageWait {
                    rollbacks: 1,
                    not_before_ms: 1_700_000_123_456,
                }),
            );
            assert_eq!(
                storage.restage_wait(&circle),
                None,
                "a wait that cannot be read was made up",
            );
        })
        .await;

        for said in [
            "a commit's removal mark was not written",
            "a commit's removal mark was not read",
            "a change's outcome was not recorded",
            "a change's outcome was not cleared",
            "a circle's change outcomes were not read",
            "a circle's re-staging wait was not written",
            "a circle's re-staging wait was not read",
        ] {
            assert!(
                lines.iter().any(|line| line.starts_with(said)),
                "no line says: {said}",
            );
        }
        let all = lines.concat().to_lowercase();
        assert!(
            !all.contains("c7c7")
                && !all.contains("199, 199")
                && !all.contains("elsewhere")
                && !all.contains("1700000123456"),
            "a storage failure's line names the circle, quotes the statement or tells an instant",
        );
    }

    #[test]
    fn a_circles_restage_wait_is_kept_until_it_is_ended_and_touches_nothing_else() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);
        let other = GroupId::from_slice(&[2; 32]);
        let wait = RestageWait {
            rollbacks: 2,
            not_before_ms: 1_700_000_120_000,
        };

        assert_eq!(storage.restage_wait(&circle), None);
        assert!(storage.set_removes_nobody(&circle, true));
        assert!(storage.note(&circle, ChangeNote::RemovalUndone));
        storage.set_restage_wait(&circle, Some(wait));
        assert_eq!(storage.restage_wait(&circle), Some(wait));
        assert_eq!(
            storage.restage_wait(&other),
            None,
            "the wait is the circle's own"
        );
        assert!(
            storage.removes_nobody(&circle) && storage.peek(&circle) == [ChangeNote::RemovalUndone],
            "recording a wait changed the circle's mark or its notes",
        );
        storage.set_restage_wait(&circle, None);
        assert_eq!(storage.restage_wait(&circle), None);
        assert_eq!(storage.peek(&circle), [ChangeNote::RemovalUndone]);
    }

    #[test]
    fn a_note_does_not_touch_the_removal_mark_and_the_mark_does_not_touch_a_note() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);

        assert!(storage.set_removes_nobody(&circle, true));
        assert!(storage.note(&circle, ChangeNote::ChangeUndone));
        assert!(storage.removes_nobody(&circle));
        assert!(storage.set_removes_nobody(&circle, false));
        assert_eq!(storage.peek(&circle), [ChangeNote::ChangeUndone]);
    }
}
