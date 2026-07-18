//! Storage methods for the `published_key_packages` table (Dark Matter DM-2b).
//!
//! Extends [`CircleStorage`] with tracking of the CURRENT `KeyPackage` event
//! this device has published. This powers the periodic `KeyPackageMaintenance`
//! task (see [`crate::relay::maintenance::key_package`]): the stored NIP-33
//! `d_tag` lets a heal/rotation REPLACE the same addressable coordinate (so the
//! user stays reachable at a stable address), and the stored public
//! `key_package` wire bytes let a heal re-publish the SAME last-resort package
//! verbatim (no re-mint) and let a rotation feed the superseded bundle to
//! `session.delete_key_package` (mdk#160).
//!
//! # What changed at the Dark Matter cutover
//!
//! The pre-migration model tracked an MLS `hash_ref` (to run the deleted M8-2
//! live-material gate) and a `kind` column (30443 canonical + 443 legacy twin).
//! Both are gone: last-resort `KeyPackages` never die on join (so there is no
//! "dead material" to detect), and the 443 twin is RETIRED (single kind 30443).
//! The legacy rows are cleared at cutover by
//! `CircleStorage::migrate_reset_published_key_packages`.
//!
//! # Scope
//!
//! The table is **identity-scoped**, not per-circle: `KeyPackages` are pre-group
//! init material that outlives any single circle, so there is deliberately no
//! `delete_circle` cascade into it.
//!
//! # Privacy and security notes
//!
//! * `event_id` and `d_tag` are public Nostr identifiers — no secret material.
//! * `key_package` is the PUBLIC MLS `KeyPackage` wire bytes (the same bytes
//!   published to relays as the event's base64 content); the private HPKE init
//!   key lives only in the engine's encrypted storage. Even so, these bytes are
//!   redacted from [`PublishedKeyPackageRow`]'s `Debug` (Security Rule 6,
//!   defence in depth) and never logged.

// Single-shot SQLite ops naturally hold the lock to completion; the parent
// module already disables this lint at the file level for storage.rs.
#![allow(clippy::significant_drop_tightening)]

use rusqlite::{params, OptionalExtension};

use super::error::{CircleError, Result};
use super::storage::CircleStorage;

/// The Marmot `KeyPackage` event kind (NIP-33 addressable, single kind).
pub const KEY_PACKAGE_KIND: u16 = 30443;

/// `user_settings` key recording that the one-time legacy (443 / kind-10051)
/// retraction has been published, so the non-optional cutover retraction runs
/// at most once (migration plan §6 step 5).
pub const LEGACY_KP_RETRACTION_DONE_KEY: &str = "legacy_kp_retraction_done_v1";

/// One row of the `published_key_packages` table: the current published KP.
///
/// The `Debug` impl is hand-written to redact `key_package` — the MLS wire
/// bytes must never reach a log line (Security Rule 6, defence in depth).
#[derive(Clone, PartialEq, Eq)]
pub struct PublishedKeyPackageRow {
    /// Lowercase-hex Nostr event id of the published kind-30443 event.
    pub event_id: String,
    /// Stable NIP-33 `d` tag (the addressable slot) of the published event.
    pub d_tag: String,
    /// Public MLS `KeyPackage` wire bytes (re-published verbatim on a heal; fed
    /// to `delete_key_package` on rotation).
    pub key_package: Vec<u8>,
    /// Unix seconds when the event was published.
    pub created_at: i64,
}

impl std::fmt::Debug for PublishedKeyPackageRow {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PublishedKeyPackageRow")
            .field("event_id", &self.event_id)
            .field("d_tag", &self.d_tag)
            .field("key_package", &"<redacted>")
            .field("created_at", &self.created_at)
            .finish()
    }
}

impl CircleStorage {
    /// Records the CURRENT published `KeyPackage` event for its stable slot.
    ///
    /// Single-row-per-slot: any prior tracking row for the same `d_tag` is
    /// removed first, so the table holds exactly the latest publication into
    /// each addressable coordinate. A heal (re-publish of the same bytes into
    /// the same slot) and a rotation (new bytes into the same slot) therefore
    /// both leave one authoritative row.
    ///
    /// The FFI orchestration MUST read [`Self::latest_published_key_package`]
    /// (to capture the superseded bytes for `delete_key_package`) BEFORE calling
    /// this, since recording drops the prior row for the slot.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn record_published_key_package(&self, row: &PublishedKeyPackageRow) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let kp: &[u8] = &row.key_package;
        conn.execute(
            "DELETE FROM published_key_packages WHERE d_tag = ?1",
            params![row.d_tag],
        )?;
        conn.execute(
            "INSERT OR IGNORE INTO published_key_packages
                 (event_id, d_tag, key_package, created_at)
             VALUES (?1, ?2, ?3, ?4)",
            params![row.event_id, row.d_tag, kp, row.created_at],
        )?;
        Ok(())
    }

    /// Returns the most-recently-published tracking row, if any.
    ///
    /// This is the current `KeyPackage` the maintenance task reuses: its `d_tag`
    /// is the stable slot to re-publish into, and its `key_package` bytes are
    /// the last-resort package to re-publish verbatim (heal) or to hand to
    /// `delete_key_package` (rotation). Newest wins by `created_at` then `id`.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn latest_published_key_package(&self) -> Result<Option<PublishedKeyPackageRow>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.query_row(
            "SELECT event_id, d_tag, key_package, created_at
             FROM published_key_packages
             ORDER BY created_at DESC, id DESC
             LIMIT 1",
            [],
            |r| {
                Ok(PublishedKeyPackageRow {
                    event_id: r.get(0)?,
                    d_tag: r.get(1)?,
                    key_package: r.get(2)?,
                    created_at: r.get(3)?,
                })
            },
        )
        .optional()
        .map_err(Into::into)
    }

    /// Returns the NIP-33 `d` tag of the most-recently-published `KeyPackage`.
    ///
    /// The stable slot identifier the maintenance task reuses so a heal/rotation
    /// replaces the same addressable coordinate instead of minting a fresh one.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn latest_canonical_d_tag(&self) -> Result<Option<String>> {
        Ok(self.latest_published_key_package()?.map(|r| r.d_tag))
    }

    /// Clears all published-`KeyPackage` tracking (cutover / logout wipe).
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn wipe_published_key_packages(&self) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.execute("DELETE FROM published_key_packages", [])?;
        Ok(())
    }

    /// Returns whether the one-time legacy (443 / kind-10051) retraction has run.
    ///
    /// Defaults to `false` (not yet run) when the sentinel has never been
    /// written, so the non-optional cutover retraction (migration plan §6 step
    /// 5) fires exactly once on the first new-stack maintenance run.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn legacy_kp_retraction_done(&self) -> Result<bool> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let raw: Option<String> = conn
            .query_row(
                "SELECT value FROM user_settings WHERE key = ?1",
                params![LEGACY_KP_RETRACTION_DONE_KEY],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        Ok(raw.as_deref() == Some("1"))
    }

    /// Marks the one-time legacy (443 / kind-10051) retraction as complete.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn mark_legacy_kp_retraction_done(&self) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.execute(
            "INSERT OR REPLACE INTO user_settings (key, value) VALUES (?1, '1')",
            params![LEGACY_KP_RETRACTION_DONE_KEY],
        )?;
        Ok(())
    }

    /// Test-only: returns the number of rows in `published_key_packages`.
    #[cfg(test)]
    pub fn count_published_key_packages(&self) -> Result<i64> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.query_row("SELECT COUNT(*) FROM published_key_packages", [], |r| {
            r.get::<_, i64>(0)
        })
        .map_err(Into::into)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(event_id: &str, d_tag: &str, kp: &[u8], at: i64) -> PublishedKeyPackageRow {
        PublishedKeyPackageRow {
            event_id: event_id.to_string(),
            d_tag: d_tag.to_string(),
            key_package: kp.to_vec(),
            created_at: at,
        }
    }

    #[test]
    fn record_and_latest_round_trip() {
        let storage = CircleStorage::in_memory().expect("in_memory");
        assert!(storage
            .latest_published_key_package()
            .expect("latest")
            .is_none());

        storage
            .record_published_key_package(&row("aa", "d-first", &[1, 2, 3], 100))
            .expect("record");
        let latest = storage
            .latest_published_key_package()
            .expect("latest")
            .expect("some");
        assert_eq!(latest.event_id, "aa");
        assert_eq!(latest.d_tag, "d-first");
        assert_eq!(latest.key_package, vec![1, 2, 3]);
        assert_eq!(
            storage.latest_canonical_d_tag().expect("d"),
            Some("d-first".to_string())
        );
    }

    #[test]
    fn record_is_single_row_per_slot() {
        // A heal re-publishes the SAME slot; only the latest row survives.
        let storage = CircleStorage::in_memory().expect("in_memory");
        storage
            .record_published_key_package(&row("old", "d-slot", &[1], 100))
            .expect("old");
        storage
            .record_published_key_package(&row("new", "d-slot", &[2], 200))
            .expect("new");
        assert_eq!(storage.count_published_key_packages().expect("count"), 1);
        let latest = storage
            .latest_published_key_package()
            .expect("latest")
            .expect("some");
        assert_eq!(latest.event_id, "new");
        assert_eq!(latest.key_package, vec![2]);
    }

    #[test]
    fn latest_picks_newest_across_slots() {
        let storage = CircleStorage::in_memory().expect("in_memory");
        storage
            .record_published_key_package(&row("a", "d-a", &[1], 100))
            .expect("a");
        storage
            .record_published_key_package(&row("b", "d-b", &[2], 200))
            .expect("b");
        assert_eq!(
            storage.latest_canonical_d_tag().expect("d"),
            Some("d-b".to_string())
        );
    }

    #[test]
    fn wipe_clears_all_tracking() {
        let storage = CircleStorage::in_memory().expect("in_memory");
        storage
            .record_published_key_package(&row("a", "d-a", &[1], 100))
            .expect("a");
        storage.wipe_published_key_packages().expect("wipe");
        assert_eq!(storage.count_published_key_packages().expect("count"), 0);
    }

    #[test]
    fn retraction_marker_defaults_false_then_sticks() {
        let storage = CircleStorage::in_memory().expect("in_memory");
        assert!(!storage.legacy_kp_retraction_done().expect("default"));
        storage.mark_legacy_kp_retraction_done().expect("mark");
        assert!(storage.legacy_kp_retraction_done().expect("after mark"));
    }

    #[test]
    fn debug_redacts_key_package_bytes() {
        let r = row("id", "d", &[0xde, 0xad, 0xbe, 0xef], 1);
        let dbg = format!("{r:?}");
        assert!(
            dbg.contains("<redacted>"),
            "kp bytes must be redacted: {dbg}"
        );
        assert!(!dbg.contains("adbeef"), "raw kp bytes leaked: {dbg}");
        // Public identifiers are fine to surface.
        assert!(dbg.contains("event_id"));
        assert!(dbg.contains('d'));
    }
}
