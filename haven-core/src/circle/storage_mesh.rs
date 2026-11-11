//! The mesh key ring at rest, on `circles-v2.db`: the `mesh_keys` table in
//! [`CircleStorage::initialize_schema`] and the deadline `mesh_on_until` in
//! `user_settings` (`docs/BLUETOOTH_MESH_PLAN.md` §4.2); and the mesh's four
//! counts, in `user_settings` too (§7.5).
//!
//! A row is a circle's group-event exporter secret at one epoch. Rows exist
//! only while mesh is on, are replaced a circle at a time as the ring changes,
//! go with their circle, and all go with the deadline. Nothing here logs: a
//! failure is answered, not described, and a count is exact (Security Rules 6
//! and 15).

#![allow(clippy::significant_drop_tightening)]

use rusqlite::{params, OptionalExtension};
use zeroize::Zeroizing;

use super::error::{CircleError, Result};
use super::storage::CircleStorage;
use crate::nostr::mls::types::GroupId;
use crate::nostr::mls::{MeshKeyStore, StoredMeshKey};

/// The `user_settings` key of the instant mesh goes off at.
const MESH_ON_UNTIL_KEY: &str = "mesh_on_until";

/// The `user_settings` keys of the two lifetime totals, each beside the key
/// of what that total read when mesh was last turned on.
const FROM_CIRCLES: [&str; 2] = ["mesh_from_circles_total", "mesh_from_circles_at_on"];
const PASSED_ON: [&str; 2] = ["mesh_passed_on_total", "mesh_passed_on_at_on"];

/// The mesh's statistics (plan §7.5): updates from this device's circles
/// read off the mesh, and packets it could not read and passed on. No
/// timestamp and no breakdown by circle or peer is kept.
///
/// **No `Debug`**: the counts are exact, and are shown, never logged
/// (Security Rule 15).
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub struct MeshCounts {
    /// Updates from this device's circles, ever.
    pub from_circles_total: u64,
    /// Packets passed on, ever.
    pub passed_on_total: u64,
    /// Updates from this device's circles since mesh was last turned on.
    pub from_circles_since_on: u64,
    /// Packets passed on since mesh was last turned on.
    pub passed_on_since_on: u64,
}

/// The count stored under `key`: zero when none is, or it is no number.
fn count(conn: &rusqlite::Connection, key: &str) -> Result<u64> {
    let stored: Option<String> = conn
        .query_row(
            "SELECT value FROM user_settings WHERE key = ?1",
            params![key],
            |row| row.get(0),
        )
        .optional()?;
    Ok(stored.and_then(|count| count.parse().ok()).unwrap_or(0))
}

fn set_count(conn: &rusqlite::Connection, key: &str, count: u64) -> Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO user_settings (key, value) VALUES (?1, ?2)",
        params![key, count.to_string()],
    )?;
    Ok(())
}

impl CircleStorage {
    fn read_mesh_on_until(&self) -> Result<Option<u64>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let stored: Option<String> = conn
            .query_row(
                "SELECT value FROM user_settings WHERE key = ?1",
                params![MESH_ON_UNTIL_KEY],
                |row| row.get(0),
            )
            .optional()?;
        Ok(stored.and_then(|until| until.parse().ok()))
    }

    fn write_mesh_on_until(&self, until_ms: Option<u64>) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let tx = conn.transaction()?;
        if let Some(until_ms) = until_ms {
            // No deadline stood: mesh is being turned on, and what is
            // counted "since turned on" starts from here.
            let on: bool = tx.query_row(
                "SELECT EXISTS (SELECT 1 FROM user_settings WHERE key = ?1)",
                params![MESH_ON_UNTIL_KEY],
                |row| row.get(0),
            )?;
            if !on {
                for [total, at_on] in [FROM_CIRCLES, PASSED_ON] {
                    set_count(&tx, at_on, count(&tx, total)?)?;
                }
            }
            tx.execute(
                "INSERT OR REPLACE INTO user_settings (key, value) VALUES (?1, ?2)",
                params![MESH_ON_UNTIL_KEY, until_ms.to_string()],
            )?;
        } else {
            tx.execute(
                "DELETE FROM user_settings WHERE key = ?1",
                params![MESH_ON_UNTIL_KEY],
            )?;
            tx.execute("DELETE FROM mesh_keys", [])?;
        }
        tx.commit()?;
        Ok(())
    }

    fn read_mesh_keys(&self) -> Result<Vec<(GroupId, StoredMeshKey)>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        // A row this code did not write is no key.
        conn.execute(
            "DELETE FROM mesh_keys
             WHERE epoch < 0 OR typeof(routing_id) != 'blob' OR length(routing_id) != 32
                OR typeof(secret) != 'blob' OR length(secret) != 32",
            [],
        )?;
        let mut stmt =
            conn.prepare("SELECT mls_group_id, epoch, routing_id, secret FROM mesh_keys")?;
        let mut rows = stmt.query([])?;
        let mut keys = Vec::new();
        while let Some(row) = rows.next()? {
            // Copied out of SQLite's own buffer into ones that are wiped: a
            // `Vec<u8>` read would leave the secret in freed heap.
            let (mut routing, mut exporter) = ([0; 32], Zeroizing::new([0; 32]));
            blob32(row, 2, &mut routing)?;
            blob32(row, 3, &mut exporter)?;
            keys.push((
                GroupId::new(row.get::<_, Vec<u8>>(0)?),
                StoredMeshKey {
                    epoch: u64::try_from(row.get::<_, i64>(1)?).unwrap_or(0),
                    routing,
                    exporter,
                },
            ));
        }
        Ok(keys)
    }

    fn replace_mesh_keys(&self, group: &GroupId, keys: &[StoredMeshKey]) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let tx = conn.transaction()?;
        tx.execute(
            "DELETE FROM mesh_keys WHERE mls_group_id = ?1",
            params![group.as_slice()],
        )?;
        for key in keys {
            let epoch = i64::try_from(key.epoch)
                .map_err(|_| CircleError::InvalidData("an epoch out of range".into()))?;
            tx.execute(
                "INSERT INTO mesh_keys (mls_group_id, epoch, routing_id, secret)
                 VALUES (?1, ?2, ?3, ?4)",
                params![
                    group.as_slice(),
                    epoch,
                    key.routing.as_slice(),
                    key.exporter.as_slice()
                ],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Adds to the two lifetime totals, in one transaction. A total never
    /// decreases: it stops at the largest number it can hold.
    pub(crate) fn add_mesh_counts(&self, from_circles: u64, passed_on: u64) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let tx = conn.transaction()?;
        for ([total, _], more) in [(FROM_CIRCLES, from_circles), (PASSED_ON, passed_on)] {
            set_count(&tx, total, count(&tx, total)?.saturating_add(more))?;
        }
        tx.commit()?;
        Ok(())
    }

    /// The mesh's counts as stored.
    pub(crate) fn mesh_counts(&self) -> Result<MeshCounts> {
        let conn = self
            .conn()
            .lock()
            .map_err(|_| CircleError::Storage("Failed to acquire database lock".into()))?;
        let (from_circles, passed_on) =
            (count(&conn, FROM_CIRCLES[0])?, count(&conn, PASSED_ON[0])?);
        Ok(MeshCounts {
            from_circles_total: from_circles,
            passed_on_total: passed_on,
            from_circles_since_on: from_circles.saturating_sub(count(&conn, FROM_CIRCLES[1])?),
            passed_on_since_on: passed_on.saturating_sub(count(&conn, PASSED_ON[1])?),
        })
    }
}

/// Copies the 32-byte blob in `column` into `into`.
fn blob32(row: &rusqlite::Row<'_>, column: usize, into: &mut [u8; 32]) -> Result<()> {
    match row.get_ref(column)?.as_blob() {
        Ok(blob) if blob.len() == into.len() => {
            into.copy_from_slice(blob);
            Ok(())
        }
        _ => Err(CircleError::InvalidData("a malformed mesh key row".into())),
    }
}

impl MeshKeyStore for CircleStorage {
    fn mesh_on_until(&self) -> Option<u64> {
        self.read_mesh_on_until().ok().flatten()
    }

    fn set_mesh_on_until(&self, until_ms: Option<u64>) -> bool {
        self.write_mesh_on_until(until_ms).is_ok()
    }

    fn mesh_keys(&self) -> Vec<(GroupId, StoredMeshKey)> {
        self.read_mesh_keys().unwrap_or_default()
    }

    fn save_mesh_keys(&self, group: &GroupId, keys: &[StoredMeshKey]) -> bool {
        self.replace_mesh_keys(group, keys).is_ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::circle::types::{Circle, CircleType};
    use crate::nostr::mls::GroupIdExt as _;

    fn key(epoch: u64, fill: u8) -> StoredMeshKey {
        StoredMeshKey {
            epoch,
            routing: [fill ^ 0xff; 32],
            exporter: Zeroizing::new([fill; 32]),
        }
    }

    /// One stored key: its group, epoch, routing id and secret.
    type Stored = (Vec<u8>, u64, [u8; 32], [u8; 32]);

    /// Every stored key, sorted.
    fn stored(storage: &CircleStorage) -> Vec<Stored> {
        let mut keys: Vec<_> = storage
            .mesh_keys()
            .into_iter()
            .map(|(group, key)| {
                (
                    group.as_slice().to_vec(),
                    key.epoch,
                    key.routing,
                    *key.exporter,
                )
            })
            .collect();
        keys.sort();
        keys
    }

    fn rows(storage: &CircleStorage) -> i64 {
        let conn = storage.conn().lock().unwrap();
        conn.query_row("SELECT COUNT(*) FROM mesh_keys", [], |row| row.get(0))
            .unwrap()
    }

    /// A deleted key is gone from the file, not only from the table: the
    /// store overwrites what it frees. Read off an unkeyed file, where the
    /// bytes a keyed one would hold encrypted are there to be searched for.
    #[test]
    fn a_deleted_key_leaves_no_bytes_in_the_file() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("circles.db");
        let storage = CircleStorage::new(&path, None).unwrap();
        // Thirty-two different bytes: a run no empty page holds by chance.
        let bytes = |fill: u8| {
            let mut bytes = [fill; 32];
            for (at, byte) in (0_u8..).zip(&mut bytes) {
                *byte ^= at;
            }
            bytes
        };
        let holds = |fill: u8| {
            (std::fs::read(&path).unwrap())
                .windows(32)
                .any(|window| window == bytes(fill))
        };
        let secret = |epoch, fill: u8| StoredMeshKey {
            epoch,
            routing: [0x77; 32],
            exporter: Zeroizing::new(bytes(fill)),
        };
        let (one, two) = (GroupId::from_slice(&[1; 32]), GroupId::from_slice(&[2; 32]));

        assert!(storage.save_mesh_keys(&one, &[secret(4, 0xa4), secret(3, 0xa3)]));
        assert!(storage.save_mesh_keys(&two, &[secret(9, 0xb9)]));
        assert!(
            holds(0xa3) && holds(0xa4) && holds(0xb9),
            "the search does not find a key the file holds"
        );

        assert!(storage.save_mesh_keys(&one, &[secret(4, 0xa4)]));
        assert!(!holds(0xa3), "a pruned key is still in the file");
        assert!(storage.save_mesh_keys(&one, &[]));
        assert!(
            !holds(0xa4),
            "a forgotten circle's key is still in the file"
        );
        assert!(storage.set_mesh_on_until(None));
        assert!(!holds(0xb9), "a key is still in the file with mesh off");
    }

    #[test]
    fn a_circles_keys_are_replaced_as_a_whole() {
        let storage = CircleStorage::in_memory().unwrap();
        let (one, two) = (GroupId::from_slice(&[1; 32]), GroupId::from_slice(&[2; 32]));
        assert!(storage.save_mesh_keys(&one, &[key(4, 0xa4), key(3, 0xa3)]));
        assert!(storage.save_mesh_keys(&two, &[key(9, 0xb9)]));
        assert!(
            stored(&storage)
                == [
                    (vec![1; 32], 3, [0x5c; 32], [0xa3; 32]),
                    (vec![1; 32], 4, [0x5b; 32], [0xa4; 32]),
                    (vec![2; 32], 9, [0x46; 32], [0xb9; 32]),
                ],
            "the store holds other keys than the ones saved",
        );

        // Epoch 3 pruned, epoch 4 replaced by another branch's, 5 added: one
        // key an epoch number, and the other circle's untouched.
        assert!(storage.save_mesh_keys(&one, &[key(5, 0xa5), key(4, 0xc4)]));
        assert!(
            stored(&storage)
                == [
                    (vec![1; 32], 4, [0x3b; 32], [0xc4; 32]),
                    (vec![1; 32], 5, [0x5a; 32], [0xa5; 32]),
                    (vec![2; 32], 9, [0x46; 32], [0xb9; 32]),
                ],
            "a save did not replace its circle's keys as a whole, or touched another circle's",
        );

        assert!(storage.save_mesh_keys(&one, &[]));
        assert!(
            stored(&storage) == [(vec![2; 32], 9, [0x46; 32], [0xb9; 32])],
            "saving no key did not delete the circle's keys alone"
        );
    }

    #[test]
    fn a_save_that_fails_leaves_the_circles_keys_as_they_were() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);
        assert!(storage.save_mesh_keys(&circle, &[key(4, 0xa4)]));
        // Two keys under one epoch number cannot both be stored.
        assert!(!storage.save_mesh_keys(&circle, &[key(5, 0xa5), key(5, 0xc5)]));
        assert!(!storage.save_mesh_keys(&circle, &[key(u64::MAX, 0xa6)]));
        assert!(
            stored(&storage) == [(vec![1; 32], 4, [0x5b; 32], [0xa4; 32])],
            "a save that failed changed what was stored"
        );
    }

    #[test]
    fn the_deadline_is_kept_and_takes_every_key_with_it() {
        let storage = CircleStorage::in_memory().unwrap();
        assert!(storage.mesh_on_until().is_none());
        assert!(storage.set_mesh_on_until(Some(1_800_000_000_000)));
        assert!(storage.set_mesh_on_until(Some(u64::MAX)));
        assert!(
            storage.mesh_on_until() == Some(u64::MAX),
            "the deadline last stored is not the one read"
        );

        storage.save_mesh_keys(&GroupId::from_slice(&[1; 32]), &[key(4, 0xa4)]);
        storage.save_mesh_keys(&GroupId::from_slice(&[2; 32]), &[key(9, 0xb9)]);
        assert!(storage.set_mesh_on_until(None));
        assert!(storage.mesh_on_until().is_none() && rows(&storage) == 0);
    }

    #[test]
    fn a_deadline_that_is_not_a_number_is_no_deadline() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .conn()
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO user_settings (key, value) VALUES ('mesh_on_until', 'soon')",
                [],
            )
            .unwrap();
        assert!(storage.mesh_on_until().is_none());
    }

    #[test]
    fn a_row_that_is_no_key_is_deleted_at_the_read() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = GroupId::from_slice(&[1; 32]);
        storage.save_mesh_keys(&circle, &[key(4, 0xa4)]);
        let conn = storage.conn().lock().unwrap();
        for (epoch, routing, secret) in [(5, 31, 32), (6, 32, 33), (-1, 32, 32)] {
            conn.execute(
                "INSERT INTO mesh_keys (mls_group_id, epoch, routing_id, secret)
                 VALUES (?1, ?2, zeroblob(?3), zeroblob(?4))",
                params![circle.as_slice(), epoch, routing, secret],
            )
            .unwrap();
        }
        // Thirty-two characters of text are no thirty-two bytes of key.
        conn.execute(
            "INSERT INTO mesh_keys (mls_group_id, epoch, routing_id, secret)
             VALUES (?1, 7, zeroblob(32), ?2)",
            params![circle.as_slice(), "a".repeat(32)],
        )
        .unwrap();
        drop(conn);
        assert!(
            stored(&storage) == [(vec![1; 32], 4, [0x5b; 32], [0xa4; 32])],
            "a row that is no key was read as one, or a key was lost with it"
        );
        assert!(
            rows(&storage) == 1,
            "a row that is no key was left in the table"
        );
    }

    #[test]
    fn deleting_a_circle_deletes_its_keys_and_no_other_circles() {
        let storage = CircleStorage::in_memory().unwrap();
        let (gone, kept) = (GroupId::from_slice(&[1; 32]), GroupId::from_slice(&[2; 32]));
        for (group, routing) in [(&gone, [0x11; 32]), (&kept, [0x22; 32])] {
            storage
                .save_circle(&Circle {
                    mls_group_id: group.clone(),
                    nostr_group_id: routing,
                    display_name: "Test".to_string(),
                    circle_type: CircleType::LocationSharing,
                    relays: Vec::new(),
                    created_at: 1,
                    updated_at: 1,
                })
                .unwrap();
        }
        storage.save_mesh_keys(&gone, &[key(4, 0xa4), key(3, 0xa3)]);
        storage.save_mesh_keys(&kept, &[key(9, 0xb9)]);

        assert!(storage.delete_circle(&gone).unwrap());
        assert!(
            stored(&storage) == [(vec![2; 32], 9, [0x46; 32], [0xb9; 32])],
            "deleting a circle left its keys, or took another circle's"
        );
        // A left circle whose MLS group is kept keeps no key either.
        assert!(storage.delete_left_circle(&kept, true).unwrap());
        assert!(
            rows(&storage) == 0,
            "a left circle whose MLS group is kept kept its keys"
        );
    }

    fn counts(storage: &CircleStorage) -> [u64; 4] {
        let counts = storage.mesh_counts().unwrap();
        [
            counts.from_circles_total,
            counts.passed_on_total,
            counts.from_circles_since_on,
            counts.passed_on_since_on,
        ]
    }

    /// The two lifetime totals only grow; what is counted since mesh was
    /// turned on starts again each time it is turned on, and at no other
    /// time: not when the deadline moves, and not when mesh goes off.
    #[test]
    fn turning_mesh_on_starts_the_since_on_counts_and_nothing_else_does() {
        let storage = CircleStorage::in_memory().unwrap();
        assert_eq!(counts(&storage), [0; 4]);
        // Counted before mesh was ever on: in the totals, and since-on too,
        // there being no turn-on to count from.
        storage.add_mesh_counts(2, 5).unwrap();
        assert_eq!(counts(&storage), [2, 5, 2, 5]);

        assert!(storage.set_mesh_on_until(Some(1_800_000_000_000)));
        assert!(
            counts(&storage) == [2, 5, 0, 0],
            "turning mesh on did not start the since-on counts, or touched a total"
        );
        storage.add_mesh_counts(3, 0).unwrap();
        storage.add_mesh_counts(0, 7).unwrap();
        assert_eq!(counts(&storage), [5, 12, 3, 7]);

        // The deadline moves: mesh stayed on.
        assert!(storage.set_mesh_on_until(Some(1_800_000_600_000)));
        assert!(
            counts(&storage) == [5, 12, 3, 7],
            "moving the deadline started the since-on counts again"
        );
        // Off keeps what was counted while it was on, to show.
        assert!(storage.set_mesh_on_until(None));
        assert_eq!(counts(&storage), [5, 12, 3, 7]);
        // On again: from here.
        assert!(storage.set_mesh_on_until(Some(1_800_001_000_000)));
        storage.add_mesh_counts(1, 1).unwrap();
        assert_eq!(counts(&storage), [6, 13, 1, 1]);
    }

    /// A total stops at the largest number it can hold, and one that is no
    /// number counts from zero: neither is an error, and neither is a
    /// decrease of a total that could be read.
    #[test]
    fn a_total_saturates_and_one_that_is_no_number_counts_from_zero() {
        let storage = CircleStorage::in_memory().unwrap();
        storage.add_mesh_counts(u64::MAX - 1, 4).unwrap();
        storage.add_mesh_counts(9, 0).unwrap();
        assert_eq!(counts(&storage)[..2], [u64::MAX, 4]);

        storage
            .conn()
            .lock()
            .unwrap()
            .execute(
                "UPDATE user_settings SET value = 'many' WHERE key = 'mesh_passed_on_total'",
                [],
            )
            .unwrap();
        assert_eq!(counts(&storage)[1], 0);
        storage.add_mesh_counts(0, 2).unwrap();
        assert_eq!(counts(&storage)[..2], [u64::MAX, 2]);
    }
}
