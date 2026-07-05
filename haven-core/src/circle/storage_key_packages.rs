//! Storage methods for the `published_key_packages` table (M8-2).
//!
//! Extends [`CircleStorage`] with CRUD for identity-level tracking of the
//! `KeyPackage` events this device has published. This powers the periodic
//! `KeyPackageMaintenance` task (see [`crate::relay::maintenance`]): the
//! stored NIP-33 `d_tag` of the most-recent canonical (kind 30443) publish
//! lets a rotation REPLACE the same addressable coordinate instead of minting
//! a fresh one every cycle, which keeps the user's `KeyPackage` reachable at a
//! stable address.
//!
//! # Scope
//!
//! The table is **identity-scoped**, not per-circle: `KeyPackages` are
//! pre-group init material that outlives any single circle, so there is
//! deliberately no `delete_circle` cascade into it.
//!
//! # Privacy and security notes
//!
//! * `event_id` is stored as lowercase hex (a public Nostr event id — no
//!   secret material).
//! * `key_package_hash_ref` is the MLS `KeyPackageRef` bytes MDK returns; it
//!   correlates a relay event to local live-material state and never leaves
//!   the device. It is redacted from every `Debug` impl and never logged.
//! * `d_tag` is the public NIP-33 addressable identifier of the canonical
//!   (30443) event; it is `NULL` for the legacy 443 twin, which is not
//!   addressable.

// Single-shot SQLite ops naturally hold the lock to completion; the parent
// module already disables this lint at the file level for storage.rs.
#![allow(clippy::significant_drop_tightening)]

use rusqlite::{params, OptionalExtension};

use super::error::{CircleError, Result};
use super::storage::CircleStorage;

/// The canonical (addressable) `KeyPackage` event kind, NIP-33 replaceable.
pub const KEY_PACKAGE_KIND_CANONICAL: u16 = 30443;

/// The legacy (non-addressable) `KeyPackage` event kind.
pub const KEY_PACKAGE_KIND_LEGACY: u16 = 443;

/// One row of the `published_key_packages` table.
///
/// The `Debug` impl is hand-written to redact `key_package_hash_ref` — the
/// MLS material correlator must never reach a log line (Security Rule 6).
#[derive(Clone, PartialEq, Eq)]
pub struct PublishedKeyPackageRow {
    /// Serialized MLS `KeyPackageRef` bytes (local-only correlator).
    pub key_package_hash_ref: Vec<u8>,
    /// Lowercase-hex Nostr event id of the published `KeyPackage` event.
    pub event_id: String,
    /// Event kind: [`KEY_PACKAGE_KIND_CANONICAL`] (30443) or
    /// [`KEY_PACKAGE_KIND_LEGACY`] (443).
    pub kind: u16,
    /// NIP-33 `d` tag of the canonical event; `None` for the legacy 443 twin.
    pub d_tag: Option<String>,
    /// Unix seconds when the event was published.
    pub created_at: i64,
}

impl std::fmt::Debug for PublishedKeyPackageRow {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PublishedKeyPackageRow")
            .field("key_package_hash_ref", &"<redacted>")
            .field("event_id", &self.event_id)
            .field("kind", &self.kind)
            .field("d_tag", &self.d_tag)
            .field("created_at", &self.created_at)
            .finish()
    }
}

impl CircleStorage {
    /// Records a published `KeyPackage` event (insert-or-ignore).
    ///
    /// De-duplicated on `(event_id, kind)` so a re-publish of the same event
    /// (e.g. a retried relay write) does not create a duplicate row. The
    /// `hash_ref`/`d_tag`/`created_at` of the FIRST insert win; a later
    /// conflicting insert is a no-op.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn record_published_key_package(&self, row: &PublishedKeyPackageRow) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let hash_ref: &[u8] = &row.key_package_hash_ref;
        conn.execute(
            "INSERT OR IGNORE INTO published_key_packages
                 (key_package_hash_ref, event_id, kind, d_tag, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                hash_ref,
                row.event_id,
                i64::from(row.kind),
                row.d_tag,
                row.created_at,
            ],
        )?;
        Ok(())
    }

    /// Returns the NIP-33 `d` tag of the most-recently-published **canonical**
    /// (kind 30443) `KeyPackage`, if any.
    ///
    /// This is the stable slot identifier the maintenance task reuses so a
    /// rotation replaces the same addressable coordinate. Rows whose `d_tag`
    /// is `NULL` (the legacy 443 twins) are ignored. Ordered by `created_at`
    /// then `id` so the newest publish wins deterministically.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn latest_canonical_d_tag(&self) -> Result<Option<String>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.query_row(
            "SELECT d_tag FROM published_key_packages
             WHERE kind = ?1 AND d_tag IS NOT NULL
             ORDER BY created_at DESC, id DESC
             LIMIT 1",
            params![i64::from(KEY_PACKAGE_KIND_CANONICAL)],
            |r| r.get::<_, Option<String>>(0),
        )
        .optional()
        .map(Option::flatten)
        .map_err(Into::into)
    }

    /// Returns the lowercase-hex Nostr event id of the most-recently-published
    /// **legacy** (kind 443) `KeyPackage` twin, if any.
    ///
    /// The legacy 443 event is a NON-replaceable regular event, so each
    /// maintenance republish leaves the previous 443 lingering on relays as a
    /// "twin" (unlike the canonical 30443, which auto-supersedes itself via
    /// NIP-33 same-`d` replacement). The maintenance task reads THIS id BEFORE
    /// recording a fresh republish so it can author a best-effort NIP-09 kind-5
    /// deletion of the immediately-superseded twin — garbage-collecting the dead
    /// event from cooperative relays.
    ///
    /// # Scoping choice
    ///
    /// This intentionally returns the single newest 443 row across ALL tracked
    /// legacy publishes, NOT one scoped to a particular `hash_ref`. That is the
    /// correct scope for the republish GC: a maintenance republish supersedes the
    /// user's current legacy `KeyPackage` discoverability role, so "the latest
    /// 443 we published" is the twin a new one supersedes. This drives a
    /// **best-effort per-target scrub of the most-recently-recorded twin** — it
    /// is NOT a guarantee that only one 443 is live network-wide: different
    /// relays can legitimately hold different-id twins (a heal targets only the
    /// non-live subset, so a relay skipped this cycle may still serve an older
    /// twin), and NIP-09 support varies. Scoping by `hash_ref` would instead
    /// target the twin of a *specific* material bundle, which is not what a
    /// stable-`d` rotation (which rebuilds fresh material each cycle) supersedes.
    ///
    /// Ordered by `created_at` then `id` so the newest publish wins
    /// deterministically. Rows of kind 30443 are ignored (they self-supersede
    /// and are never GC'd here).
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn latest_legacy_event_id(&self) -> Result<Option<String>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.query_row(
            "SELECT event_id FROM published_key_packages
             WHERE kind = ?1
             ORDER BY created_at DESC, id DESC
             LIMIT 1",
            params![i64::from(KEY_PACKAGE_KIND_LEGACY)],
            |r| r.get::<_, String>(0),
        )
        .optional()
        .map_err(Into::into)
    }

    /// Returns `(event_id, key_package_hash_ref)` for every canonical (30443)
    /// row, newest first.
    ///
    /// The maintenance task uses this to correlate a probed on-relay event id
    /// (from `Filter::author(self)` over kind 30443) with the local `hash_ref`
    /// it recorded at publish time, so it can run the live-material gate against
    /// exactly the material that event was built from. A probed event whose id
    /// is not in this map has no tracked material and reads DEAD.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn canonical_published_event_refs(&self) -> Result<Vec<(String, Vec<u8>)>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let mut stmt = conn.prepare(
            "SELECT event_id, key_package_hash_ref FROM published_key_packages
             WHERE kind = ?1
             ORDER BY created_at DESC, id DESC",
        )?;
        let rows = stmt.query_map(params![i64::from(KEY_PACKAGE_KIND_CANONICAL)], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?))
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    /// Returns every stored `key_package_hash_ref` for canonical (30443) rows.
    ///
    /// The maintenance task uses these to run the live-material gate: for each
    /// tracked canonical publish, it asks MDK whether the private init-key
    /// material for that `hash_ref` is still present locally.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn canonical_published_hash_refs(&self) -> Result<Vec<Vec<u8>>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let mut stmt = conn.prepare(
            "SELECT key_package_hash_ref FROM published_key_packages
             WHERE kind = ?1
             ORDER BY created_at DESC, id DESC",
        )?;
        let rows = stmt.query_map(params![i64::from(KEY_PACKAGE_KIND_CANONICAL)], |r| {
            r.get::<_, Vec<u8>>(0)
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
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

    fn row(
        hash_ref: &[u8],
        event_id: &str,
        kind: u16,
        d_tag: Option<&str>,
        at: i64,
    ) -> PublishedKeyPackageRow {
        PublishedKeyPackageRow {
            key_package_hash_ref: hash_ref.to_vec(),
            event_id: event_id.to_string(),
            kind,
            d_tag: d_tag.map(str::to_owned),
            created_at: at,
        }
    }

    #[test]
    fn record_and_latest_canonical_d_tag() {
        let storage = CircleStorage::in_memory().expect("in_memory");
        assert_eq!(storage.latest_canonical_d_tag().expect("latest"), None);

        storage
            .record_published_key_package(&row(
                &[1, 2, 3],
                "aa",
                KEY_PACKAGE_KIND_CANONICAL,
                Some("d-first"),
                100,
            ))
            .expect("record");
        assert_eq!(
            storage.latest_canonical_d_tag().expect("latest"),
            Some("d-first".to_string())
        );
    }

    #[test]
    fn latest_canonical_d_tag_picks_newest_by_created_at() {
        let storage = CircleStorage::in_memory().expect("in_memory");
        storage
            .record_published_key_package(&row(
                &[1],
                "old",
                KEY_PACKAGE_KIND_CANONICAL,
                Some("d-old"),
                100,
            ))
            .expect("record old");
        storage
            .record_published_key_package(&row(
                &[2],
                "new",
                KEY_PACKAGE_KIND_CANONICAL,
                Some("d-new"),
                200,
            ))
            .expect("record new");
        assert_eq!(
            storage.latest_canonical_d_tag().expect("latest"),
            Some("d-new".to_string())
        );
    }

    #[test]
    fn latest_canonical_d_tag_ignores_legacy_twin() {
        let storage = CircleStorage::in_memory().expect("in_memory");
        // Legacy twin has no d_tag and must never be returned.
        storage
            .record_published_key_package(&row(&[9], "legacy", KEY_PACKAGE_KIND_LEGACY, None, 300))
            .expect("record legacy");
        assert_eq!(storage.latest_canonical_d_tag().expect("latest"), None);
    }

    #[test]
    fn record_is_insert_or_ignore_on_event_id_kind() {
        let storage = CircleStorage::in_memory().expect("in_memory");
        storage
            .record_published_key_package(&row(
                &[1],
                "dup",
                KEY_PACKAGE_KIND_CANONICAL,
                Some("d1"),
                100,
            ))
            .expect("first");
        // Same (event_id, kind) — ignored; original d_tag stays.
        storage
            .record_published_key_package(&row(
                &[2],
                "dup",
                KEY_PACKAGE_KIND_CANONICAL,
                Some("d2"),
                200,
            ))
            .expect("second");
        assert_eq!(storage.count_published_key_packages().expect("count"), 1);
        assert_eq!(
            storage.latest_canonical_d_tag().expect("latest"),
            Some("d1".to_string())
        );
    }

    #[test]
    fn latest_legacy_event_id_returns_newest_443() {
        let storage = CircleStorage::in_memory().expect("in_memory");
        // Empty ⇒ None.
        assert_eq!(storage.latest_legacy_event_id().expect("empty"), None);

        // Two legacy twins; the newest (by created_at) wins.
        storage
            .record_published_key_package(&row(
                &[1],
                "legacy-old",
                KEY_PACKAGE_KIND_LEGACY,
                None,
                100,
            ))
            .expect("old");
        storage
            .record_published_key_package(&row(
                &[2],
                "legacy-new",
                KEY_PACKAGE_KIND_LEGACY,
                None,
                200,
            ))
            .expect("new");
        assert_eq!(
            storage.latest_legacy_event_id().expect("latest"),
            Some("legacy-new".to_string())
        );
    }

    #[test]
    fn latest_legacy_event_id_ignores_canonical_rows() {
        let storage = CircleStorage::in_memory().expect("in_memory");
        // Only a canonical (30443) row exists ⇒ no legacy twin to GC ⇒ None.
        storage
            .record_published_key_package(&row(
                &[1],
                "canonical",
                KEY_PACKAGE_KIND_CANONICAL,
                Some("d-canon"),
                300,
            ))
            .expect("canonical");
        assert_eq!(storage.latest_legacy_event_id().expect("latest"), None);
    }

    #[test]
    fn latest_legacy_event_id_picks_443_even_when_a_newer_30443_exists() {
        // A republish records BOTH a fresh 30443 and a fresh 443 at the same
        // instant; the getter must return the 443, never the (newer or equal)
        // canonical — proving the kind filter, not just recency, selects it.
        let storage = CircleStorage::in_memory().expect("in_memory");
        storage
            .record_published_key_package(&row(&[1], "legacy", KEY_PACKAGE_KIND_LEGACY, None, 400))
            .expect("legacy");
        storage
            .record_published_key_package(&row(
                &[1],
                "canonical",
                KEY_PACKAGE_KIND_CANONICAL,
                Some("d-canon"),
                400,
            ))
            .expect("canonical");
        assert_eq!(
            storage.latest_legacy_event_id().expect("latest"),
            Some("legacy".to_string())
        );
    }

    #[test]
    fn canonical_published_hash_refs_returns_only_canonical() {
        let storage = CircleStorage::in_memory().expect("in_memory");
        storage
            .record_published_key_package(&row(
                &[1, 1],
                "c1",
                KEY_PACKAGE_KIND_CANONICAL,
                Some("d1"),
                100,
            ))
            .expect("c1");
        storage
            .record_published_key_package(&row(&[2, 2], "l1", KEY_PACKAGE_KIND_LEGACY, None, 100))
            .expect("l1");
        let refs = storage.canonical_published_hash_refs().expect("refs");
        assert_eq!(refs, vec![vec![1u8, 1]]);
    }

    #[test]
    fn debug_redacts_hash_ref() {
        let r = row(
            &[0xde, 0xad, 0xbe, 0xef],
            "id",
            KEY_PACKAGE_KIND_CANONICAL,
            Some("d"),
            1,
        );
        let dbg = format!("{r:?}");
        assert!(
            dbg.contains("<redacted>"),
            "hash_ref must be redacted: {dbg}"
        );
        assert!(!dbg.contains("adbeef"), "raw hash_ref bytes leaked: {dbg}");
    }
}
