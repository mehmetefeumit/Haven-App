//! The durable half of [`KeptInput`], on `circles-v2.db` (the `kept_input`
//! table in [`CircleStorage::initialize_schema`]).
//!
//! One row per event Haven took over from the engine: the signed event as a
//! relay served it, until the engine has been handed it back and answered. A
//! failure is logged by its storage code alone; what it costs is said at
//! each method of the trait.

#![allow(clippy::significant_drop_tightening)]

use rusqlite::{params, OptionalExtension};

use super::error::{CircleError, Result};
use super::storage::CircleStorage;
use crate::nostr::mls::types::{GroupId, MessageId};
use crate::nostr::mls::{KeptEvent, KeptInput};

impl CircleStorage {
    fn read_kept_input(&self, group_id: &GroupId) -> Result<Vec<KeptEvent>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let mut stmt = conn.prepare(
            "SELECT event_id, change, asked, event FROM kept_input
             WHERE mls_group_id = ?1 ORDER BY seq",
        )?;
        let rows = stmt.query_map(params![group_id.as_slice()], |row| {
            Ok(KeptEvent {
                id: MessageId::new(row.get::<_, Vec<u8>>(0)?),
                change: row.get(1)?,
                asked: row.get(2)?,
                event: row.get(3)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
    }

    fn write_kept_input(
        &self,
        group_id: &GroupId,
        id: &MessageId,
        change: bool,
        event: &str,
    ) -> Result<bool> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        conn.execute(
            "INSERT OR IGNORE INTO kept_input
                 (event_id, mls_group_id, seq, change, event)
             VALUES (?1, ?2, (SELECT COALESCE(MAX(seq), 0) + 1 FROM kept_input), ?3, ?4)",
            params![id.as_slice(), group_id.as_slice(), change, event],
        )?;
        Ok(conn
            .query_row(
                "SELECT 1 FROM kept_input WHERE event_id = ?1",
                params![id.as_slice()],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }

    fn change_kept_input(&self, sql: &str, id: &MessageId) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        conn.execute(sql, params![id.as_slice()])?;
        Ok(())
    }
}

impl KeptInput for CircleStorage {
    fn kept(&self, group_id: &GroupId) -> Option<Vec<KeptEvent>> {
        self.read_kept_input(group_id)
            .inspect_err(|e| log::warn!("a circle's kept input was not read: {}", e.code()))
            .ok()
    }

    fn durable(&self) -> bool {
        true
    }

    fn keep(&self, group_id: &GroupId, id: &MessageId, change: bool, event: &str) -> bool {
        self.write_kept_input(group_id, id, change, event)
            .unwrap_or_else(|e| {
                log::warn!("an event was not kept: {}", e.code());
                false
            })
    }

    fn end(&self, id: &MessageId) -> bool {
        self.change_kept_input("DELETE FROM kept_input WHERE event_id = ?1", id)
            .inspect_err(|e| log::warn!("a kept event was not ended: {}", e.code()))
            .is_ok()
    }

    fn unanswered(&self, id: &MessageId) {
        if let Err(e) =
            self.change_kept_input("UPDATE kept_input SET asked = 1 WHERE event_id = ?1", id)
        {
            log::warn!("a kept event was not marked as asked for: {}", e.code());
        }
    }

    fn forget(&self, group_id: &GroupId) {
        let forgotten = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))
            .and_then(|conn| {
                conn.execute(
                    "DELETE FROM kept_input WHERE mls_group_id = ?1",
                    params![group_id.as_slice()],
                )
                .map_err(CircleError::from)
            });
        if let Err(e) = forgotten {
            log::warn!("a circle's kept input was not destroyed: {}", e.code());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nostr::mls::types::GroupIdExt;

    fn id(byte: u8) -> MessageId {
        MessageId::new(vec![byte; 32])
    }

    fn standings(storage: &CircleStorage, circle: &GroupId) -> Vec<(MessageId, bool)> {
        storage
            .kept(circle)
            .expect("read")
            .into_iter()
            .map(|kept| (kept.id, kept.asked))
            .collect()
    }

    // Entries are compared with `assert!`, never `assert_eq!`: an id is never
    // formatted, a test's included (Security Rule 15).
    #[test]
    fn what_is_kept_is_per_circle_in_the_order_kept_and_once_per_event() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);
        let other = GroupId::from_slice(&[2; 32]);

        assert!(storage.keep(&circle, &id(9), true, "first"));
        assert!(storage.keep(&other, &id(5), false, "theirs"));
        assert!(storage.keep(&circle, &id(3), false, "second"));
        assert!(
            storage.keep(&circle, &id(9), false, "again"),
            "an event already kept is durably there"
        );
        let kept = storage.kept(&circle).expect("read");
        assert!(
            kept.iter()
                .map(|kept| (kept.id.clone(), kept.change, kept.event.as_str()))
                .collect::<Vec<_>>()
                == [(id(9), true, "first"), (id(3), false, "second")],
            "kept out of order, twice, or over the entry that stood",
        );
        assert_eq!(storage.kept(&other).expect("read").len(), 1);
    }

    /// An event the engine would not take is marked, and kept with its
    /// bytes however often that is: no count of refusals or errors ends it.
    /// Its end is the engine's answer, or its circle's.
    #[test]
    fn an_unanswered_event_is_marked_and_kept_however_often_and_an_ended_one_is_gone() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);
        assert!(storage.keep(&circle, &id(9), true, "event"));
        assert!(storage.keep(&circle, &id(3), false, "event"));
        assert!(
            standings(&storage, &circle) == [(id(9), false), (id(3), false)],
            "premise: both are kept, and the engine was asked for neither",
        );
        for _ in 0..64 {
            storage.unanswered(&id(9));
        }
        let kept = storage.kept(&circle).expect("read");
        assert!(
            standings(&storage, &circle) == [(id(9), true), (id(3), false)]
                && kept[0].event == "event",
            "an event the engine would not take lost its bytes, or was not marked",
        );
        assert!(storage.end(&id(9)));
        assert!(
            standings(&storage, &circle) == [(id(3), false)],
            "an ended entry left something behind",
        );
    }

    /// A store that cannot be written or read fails towards keeping the
    /// engine's row — nothing is reported kept, read or ended — and says so
    /// in a line that names no circle and no event and quotes neither the
    /// statement nor what was to be kept.
    #[tokio::test]
    async fn a_failing_store_keeps_nothing_and_names_no_circle_and_no_event() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[0xc7; 32]);
        assert!(storage.keep(&circle, &id(0xe5), true, "served-by-a-relay"));
        storage
            .conn()
            .lock()
            .unwrap()
            .execute_batch("ALTER TABLE kept_input RENAME TO elsewhere;")
            .unwrap();

        let lines = crate::test_log::capture_log_lines(async {
            assert!(
                storage.kept(&circle).is_none(),
                "kept input that cannot be read was read as none kept",
            );
            assert!(
                !storage.keep(&circle, &id(0xe6), false, "served-by-a-relay"),
                "an event that was not kept was reported kept",
            );
            assert!(
                !storage.end(&id(0xe5)),
                "an entry that was not ended was reported ended",
            );
            storage.unanswered(&id(0xe5));
            storage.forget(&circle);
        })
        .await;

        for said in [
            "a circle's kept input was not read",
            "an event was not kept",
            "a kept event was not ended",
            "a kept event was not marked as asked for",
            "a circle's kept input was not destroyed",
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
                && !all.contains("e5e5")
                && !all.contains("229, 229")
                && !all.contains("e6e6")
                && !all.contains("elsewhere")
                && !all.contains("served-by-a-relay"),
            "a storage failure's line names the circle or the event, or quotes the statement \
             or the event kept",
        );
    }

    #[test]
    fn forgetting_a_circle_destroys_its_kept_input_and_no_other() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);
        let other = GroupId::from_slice(&[2; 32]);
        assert!(storage.keep(&circle, &id(9), true, "event"));
        assert!(storage.keep(&other, &id(5), true, "event"));
        storage.forget(&circle);
        assert!(storage.kept(&circle).expect("read").is_empty());
        assert_eq!(storage.kept(&other).expect("read").len(), 1);
    }
}
