//! Public-profile cache storage methods for [`CircleStorage`].
//!
//! These methods extend `CircleStorage` (sharing its single
//! `Mutex<Connection>` via the `pub(crate) conn()` accessor) with the kind-0
//! metadata cache (`profiles`), the re-encoded picture store
//! (`profile_pictures`), and the retraction no-op gate. They live here — as a
//! sibling `impl` block mirroring [`super::storage_relay_prefs`] — rather than
//! inside `crate::profile`, because a `ProfileStore` in `profile/` would import
//! `CircleStorage` and violate that module's hard import boundary. `profile/`
//! defines the row *types* ([`CachedProfile`], [`ProfileState`]); this module
//! does the `SQLite` I/O.
//!
//! # Privacy / security
//!
//! * Every row is keyed by **pubkey hex only** — there is deliberately no
//!   circle / group column (a `PRAGMA table_info` test pins this). Profile data
//!   is never partitioned by circle, so the cache cannot leak co-membership.
//! * Picture bytes are encrypted at rest by `SQLCipher`; the plaintext buffers
//!   returned to callers are `Zeroizing`.
//! * Publishing a public profile is unconditional (public-by-default); there is
//!   no persisted consent flag. The only publish-side invariant kept here is the
//!   retraction no-op gate ([`Self::has_published_profile`]).

// Mirror `storage.rs`: each method acquires the connection lock once at the top
// and holds it for the whole (single-statement or transactional) operation.
#![allow(clippy::significant_drop_tightening)]

use nostr::{JsonUtil, Metadata, PublicKey};
use rusqlite::{params, OptionalExtension};
use zeroize::Zeroizing;

use super::error::{CircleError, Result};
use super::storage::CircleStorage;
use crate::profile::picture_is_current;
use crate::profile::types::{CachedProfile, ProfileMetadata, ProfileState};

impl CircleStorage {
    // ==================== kind-0 metadata cache ====================

    /// Inserts or replaces a cached profile row (keyed by pubkey hex).
    ///
    /// This write is unconditional; callers gate freshness with
    /// [`Self::newer_than_cached`] before invoking it. A miss (no kind-0 for a
    /// pubkey) is recorded via [`Self::touch_profiles_fetched_at`], not here, so a
    /// transient empty fetch cannot downgrade a `Known` row.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Storage`] on lock poisoning and
    /// [`CircleError::Database`] on `SQLite` failure.
    pub fn upsert_profile(&self, cached: &CachedProfile) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        Self::write_profile_row(&conn, cached)?;
        Ok(())
    }

    /// Upserts a **fetched** profile only when it should supersede the cached
    /// row — the newer-wins gate for the fetch path. Returns whether a write
    /// occurred.
    ///
    /// Writes when any of the following holds (read + conditional write under a
    /// single lock, so the decision cannot race a concurrent writer):
    ///
    /// * there is no cached row; or
    /// * the cached row is `Unknown` (any resolved kind-0 supersedes a recorded
    ///   miss — always allow the `Unknown → Known` transition); or
    /// * the fetched `event_created_at` is **strictly newer** than the cached
    ///   one.
    ///
    /// Unlike [`Self::upsert_profile`] (used by the optimistic publish path,
    /// which is authoritative and always writes), this prevents a lagging relay
    /// from downgrading a newer cached profile, and a forced refetch from
    /// reverting a just-published optimistic edit (bug MEDIUM-3).
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn upsert_profile_if_newer(&self, cached: &CachedProfile) -> Result<bool> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let existing: Option<(i64, i64)> = conn
            .query_row(
                "SELECT event_created_at, state FROM profiles WHERE pubkey = ?1",
                params![cached.pubkey_hex],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let should_write = match existing {
            None => true,
            Some((stored_created_at, stored_state)) => {
                stored_state != ProfileState::Known.as_db_value()
                    || cached.event_created_at > stored_created_at
            }
        };
        if should_write {
            Self::write_profile_row(&conn, cached)?;
        }
        Ok(should_write)
    }

    /// Returns the cached profile for a pubkey hex, or `None`.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn get_profile(&self, pubkey_hex: &str) -> Result<Option<CachedProfile>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.query_row(
            "SELECT pubkey, metadata_json, state, event_created_at, fetched_at
             FROM profiles WHERE pubkey = ?1",
            params![pubkey_hex],
            Self::map_profile_row,
        )
        .optional()
        .map_err(Into::into)
    }

    /// Returns cached profiles for a batch of pubkey hexes (present rows only).
    ///
    /// Missing pubkeys are simply absent from the result — the caller decides
    /// whether to refetch.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn get_profiles(&self, pubkeys_hex: &[String]) -> Result<Vec<CachedProfile>> {
        if pubkeys_hex.is_empty() {
            return Ok(Vec::new());
        }
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let mut stmt = conn.prepare(
            "SELECT pubkey, metadata_json, state, event_created_at, fetched_at
             FROM profiles WHERE pubkey = ?1",
        )?;
        let mut out = Vec::with_capacity(pubkeys_hex.len());
        for pubkey_hex in pubkeys_hex {
            let row = stmt
                .query_row(params![pubkey_hex], Self::map_profile_row)
                .optional()?;
            if let Some(cached) = row {
                out.push(cached);
            }
        }
        Ok(out)
    }

    /// Records that a fetch was ATTEMPTED for each pubkey at `now_unix_secs`,
    /// inserting an `Unknown` row for a pubkey that has never resolved.
    ///
    /// The `ON CONFLICT` clause updates **only** `fetched_at`, never `state` or
    /// `metadata_json`, so this resets the staleness clock without downgrading a
    /// previously-`Known` profile.
    ///
    /// This MUST be called for every queried author, not only the ones that
    /// returned nothing. kind-0 is replaceable, so an unchanged profile comes
    /// back with the same `created_at`, [`Self::upsert_profile_if_newer`]
    /// correctly declines to rewrite the row, and `fetched_at` would otherwise
    /// stay pinned to the first-ever fetch — permanently defeating every
    /// staleness tier and turning each refresh trigger into a real relay `REQ`.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn touch_profiles_fetched_at(
        &self,
        pubkeys_hex: &[String],
        now_unix_secs: i64,
    ) -> Result<()> {
        if pubkeys_hex.is_empty() {
            return Ok(());
        }
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        {
            let mut stmt = tx.prepare(
                "INSERT INTO profiles (pubkey, metadata_json, state, event_created_at, fetched_at)
                 VALUES (?1, '{}', 0, 0, ?2)
                 ON CONFLICT(pubkey) DO UPDATE SET fetched_at = excluded.fetched_at",
            )?;
            for pubkey_hex in pubkeys_hex {
                stmt.execute(params![pubkey_hex, now_unix_secs])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Whether an incoming kind-0 with `event_created_at` is newer than the
    /// cached row — the newer-wins gate.
    ///
    /// Returns `true` when there is no cached row (first fetch always writes) or
    /// when the incoming `created_at` is strictly greater than the stored one.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn newer_than_cached(&self, pubkey_hex: &str, event_created_at: i64) -> Result<bool> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let existing: Option<i64> = conn
            .query_row(
                "SELECT event_created_at FROM profiles WHERE pubkey = ?1",
                params![pubkey_hex],
                |r| r.get(0),
            )
            .optional()?;
        Ok(existing.is_none_or(|cached| event_created_at > cached))
    }

    // ==================== picture cache ====================

    /// Inserts or replaces the cached, re-encoded picture for a pubkey hex.
    ///
    /// `sha256` is the raw-download content hash (Blossom commitment);
    /// `canonical` / `thumbnail` are the re-encoded render tiers.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn upsert_profile_picture(
        &self,
        pubkey_hex: &str,
        url: &str,
        sha256: &[u8],
        canonical: &[u8],
        thumbnail: &[u8],
        updated_at: i64,
    ) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.execute(
            "INSERT INTO profile_pictures (pubkey, url, sha256, canonical, thumbnail, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(pubkey) DO UPDATE SET
                url        = excluded.url,
                sha256     = excluded.sha256,
                canonical  = excluded.canonical,
                thumbnail  = excluded.thumbnail,
                updated_at = excluded.updated_at",
            params![pubkey_hex, url, sha256, canonical, thumbnail, updated_at],
        )?;
        Ok(())
    }

    /// Returns the cached thumbnail bytes for a pubkey hex, or `None`.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn get_profile_thumbnail(&self, pubkey_hex: &str) -> Result<Option<Zeroizing<Vec<u8>>>> {
        self.get_picture_column(pubkey_hex, "thumbnail")
    }

    /// Returns the cached canonical (full-res) bytes for a pubkey hex, or
    /// `None`.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn get_profile_picture(&self, pubkey_hex: &str) -> Result<Option<Zeroizing<Vec<u8>>>> {
        self.get_picture_column(pubkey_hex, "canonical")
    }

    /// Returns the URL the cached picture bytes were downloaded from, or `None`
    /// when no bytes are cached for this pubkey.
    ///
    /// Used to detect a stale byte cache: when a member changes or removes their
    /// kind-0 `picture`, the current URL diverges from the one recorded here, so
    /// the bytes must be re-downloaded or cleared (bug HIGH-2).
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn get_profile_picture_url(&self, pubkey_hex: &str) -> Result<Option<String>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.query_row(
            "SELECT url FROM profile_pictures WHERE pubkey = ?1",
            params![pubkey_hex],
            |r| r.get::<_, String>(0),
        )
        .optional()
        .map_err(Into::into)
    }

    /// Returns the hex SHA-256 content hash of the cached picture bytes, or
    /// `None` when no bytes are cached for this pubkey.
    ///
    /// This is the decode-cache key Flutter's marker avatar layer keys off
    /// (`Profile.pictureHash`). Blossom URLs are content-addressed, so the hash
    /// changes exactly when the picture does — making it a correct cache key
    /// AND a correct invalidation signal.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn get_profile_picture_sha256_hex(&self, pubkey_hex: &str) -> Result<Option<String>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let sha256 = conn
            .query_row(
                "SELECT sha256 FROM profile_pictures WHERE pubkey = ?1",
                params![pubkey_hex],
                |r| r.get::<_, Vec<u8>>(0),
            )
            .optional()?;
        Ok(sha256.map(|bytes| {
            use std::fmt::Write as _;
            bytes.iter().fold(String::new(), |mut acc, b| {
                let _ = write!(acc, "{b:02x}");
                acc
            })
        }))
    }

    /// Whether cached picture bytes exist AND their recorded URL still equals the
    /// member's current kind-0 `picture` URL (`current_url`).
    ///
    /// This is the source of truth for the FFI `has_picture` flag: a changed or
    /// cleared `picture` URL (or absent bytes) makes cached bytes stale, so this
    /// returns `false` and the Dart gate re-downloads/clears (bug HIGH-2).
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn has_current_picture(&self, pubkey_hex: &str, current_url: Option<&str>) -> Result<bool> {
        let cached_url = self.get_profile_picture_url(pubkey_hex)?;
        Ok(picture_is_current(current_url, cached_url.as_deref()))
    }

    /// Deletes the cached picture row for a single pubkey hex (per-pubkey, unlike
    /// the wholesale [`Self::wipe_all_profiles`]).
    ///
    /// Called when a member removes their `picture` (so the stale bytes stop
    /// rendering) and when the local user removes their own picture — without
    /// this the removed avatar reappears from the byte cache and persists across
    /// restart (bugs HIGH-1 / HIGH-2). Deleting an absent row is a harmless
    /// no-op.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn delete_profile_picture(&self, pubkey_hex: &str) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.execute(
            "DELETE FROM profile_pictures WHERE pubkey = ?1",
            params![pubkey_hex],
        )?;
        Ok(())
    }

    // ==================== retraction gate ====================

    /// Whether this pubkey has an existing public footprint worth retracting —
    /// the no-op gate for the ungated "delete/remove" actions.
    ///
    /// `true` iff a kind-0 row exists in `published_events` for this pubkey **or**
    /// a picture is cached in `profile_pictures`. Retraction callers become a
    /// no-op when this is `false`, so they can never mint a first public event
    /// for a pubkey that never published (Security review F2).
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn has_published_profile(&self, pubkey: &PublicKey) -> Result<bool> {
        // kind-0 is a plain replaceable event: empty `d` tag.
        let published_kind0 = self.last_published_event(0, "", pubkey)?.is_some();
        let has_known_picture = {
            let pubkey_hex = pubkey.to_hex();
            let conn = self.conn().lock().map_err(|e| {
                CircleError::Storage(format!("Failed to acquire database lock: {e}"))
            })?;
            conn.query_row(
                "SELECT 1 FROM profile_pictures WHERE pubkey = ?1",
                params![pubkey_hex],
                |_| Ok(()),
            )
            .optional()?
            .is_some()
        };
        // Delegates to the pure gate in `crate::profile::consent` so the module
        // that owns the invariant defines it.
        Ok(crate::profile::consent::has_published_profile(
            published_kind0,
            has_known_picture,
        ))
    }

    /// Wipes all cached profiles and pictures (account wipe / logout). Mirrors
    /// [`Self::wipe_all_avatars`].
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn wipe_all_profiles(&self) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM profiles", [])?;
        tx.execute("DELETE FROM profile_pictures", [])?;
        tx.commit()?;
        Ok(())
    }

    // ---- private helpers ----

    /// Writes (insert-or-replace) a profile row on an already-locked connection.
    ///
    /// Shared by [`Self::upsert_profile`] (unconditional) and
    /// [`Self::upsert_profile_if_newer`] (which first reads the existing row
    /// under the same lock), keeping the `INSERT … ON CONFLICT` SQL in one place.
    fn write_profile_row(
        conn: &rusqlite::Connection,
        cached: &CachedProfile,
    ) -> rusqlite::Result<()> {
        let metadata_json = cached.metadata.as_metadata().as_json();
        conn.execute(
            "INSERT INTO profiles (pubkey, metadata_json, state, event_created_at, fetched_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(pubkey) DO UPDATE SET
                metadata_json    = excluded.metadata_json,
                state            = excluded.state,
                event_created_at = excluded.event_created_at,
                fetched_at       = excluded.fetched_at",
            params![
                cached.pubkey_hex,
                metadata_json,
                cached.state.as_db_value(),
                cached.event_created_at,
                cached.fetched_at,
            ],
        )?;
        Ok(())
    }

    /// Maps a `profiles` row to a [`CachedProfile`].
    fn map_profile_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CachedProfile> {
        let pubkey_hex: String = row.get(0)?;
        let metadata_json: String = row.get(1)?;
        let state: i64 = row.get(2)?;
        let event_created_at: i64 = row.get(3)?;
        let fetched_at: i64 = row.get(4)?;
        // A stored row is always valid JSON (we write via `Metadata::as_json`);
        // fall back to the empty default rather than failing the whole read.
        let metadata = Metadata::from_json(&metadata_json).unwrap_or_default();
        Ok(CachedProfile {
            pubkey_hex,
            metadata: ProfileMetadata::from_metadata(metadata),
            state: ProfileState::from_db_value(state),
            event_created_at,
            fetched_at,
        })
    }

    /// Shared body for thumbnail / canonical picture reads.
    fn get_picture_column(
        &self,
        pubkey_hex: &str,
        column: &str,
    ) -> Result<Option<Zeroizing<Vec<u8>>>> {
        // `column` is a fixed internal literal ("thumbnail" / "canonical"),
        // never user input — no injection surface.
        let sql = format!("SELECT {column} FROM profile_pictures WHERE pubkey = ?1");
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let bytes: Option<Vec<u8>> = conn
            .query_row(&sql, params![pubkey_hex], |r| r.get(0))
            .optional()?;
        Ok(bytes.map(Zeroizing::new))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{EventBuilder, Keys, Kind};

    fn known_profile(
        pubkey_hex: &str,
        name: &str,
        created_at: i64,
        fetched_at: i64,
    ) -> CachedProfile {
        let md = Metadata::new().name(name);
        CachedProfile {
            pubkey_hex: pubkey_hex.to_string(),
            metadata: ProfileMetadata::from_metadata(md),
            state: ProfileState::Known,
            event_created_at: created_at,
            fetched_at,
        }
    }

    #[test]
    fn upsert_and_get() {
        let storage = CircleStorage::in_memory().unwrap();
        let cached = known_profile("aa", "alice", 1_000, 5_000);
        storage.upsert_profile(&cached).unwrap();

        let got = storage.get_profile("aa").unwrap().expect("row present");
        assert_eq!(got.pubkey_hex, "aa");
        assert_eq!(got.state, ProfileState::Known);
        assert_eq!(got.event_created_at, 1_000);
        assert_eq!(got.fetched_at, 5_000);
        assert_eq!(got.metadata.name(), Some("alice"));

        // Missing pubkey → None.
        assert!(storage.get_profile("bb").unwrap().is_none());
    }

    #[test]
    fn upsert_replaces_on_conflict() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile(&known_profile("aa", "old", 1_000, 5_000))
            .unwrap();
        storage
            .upsert_profile(&known_profile("aa", "new", 2_000, 6_000))
            .unwrap();
        let got = storage.get_profile("aa").unwrap().unwrap();
        assert_eq!(got.metadata.name(), Some("new"));
        assert_eq!(got.event_created_at, 2_000);
    }

    #[test]
    fn get_profiles_returns_present_rows_only() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile(&known_profile("aa", "alice", 1, 1))
            .unwrap();
        storage
            .upsert_profile(&known_profile("cc", "carol", 1, 1))
            .unwrap();
        let got = storage
            .get_profiles(&["aa".to_string(), "bb".to_string(), "cc".to_string()])
            .unwrap();
        assert_eq!(got.len(), 2);
        assert!(got.iter().any(|p| p.pubkey_hex == "aa"));
        assert!(got.iter().any(|p| p.pubkey_hex == "cc"));
        // Empty input short-circuits.
        assert!(storage.get_profiles(&[]).unwrap().is_empty());
    }

    #[test]
    fn newer_than_cached_gate() {
        let storage = CircleStorage::in_memory().unwrap();
        // No row yet → always newer (first fetch writes).
        assert!(storage.newer_than_cached("aa", 0).unwrap());

        storage
            .upsert_profile(&known_profile("aa", "alice", 1_000, 5_000))
            .unwrap();
        // Strictly greater → newer.
        assert!(storage.newer_than_cached("aa", 1_001).unwrap());
        // Equal → not newer (idempotent / TTL suppresses).
        assert!(!storage.newer_than_cached("aa", 1_000).unwrap());
        // Older → not newer.
        assert!(!storage.newer_than_cached("aa", 999).unwrap());
    }

    #[test]
    fn mark_unknown() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .touch_profiles_fetched_at(&["zz".to_string()], 7_000)
            .unwrap();
        let got = storage
            .get_profile("zz")
            .unwrap()
            .expect("unknown row present");
        assert_eq!(got.state, ProfileState::Unknown);
        assert_eq!(got.event_created_at, 0);
        assert_eq!(got.fetched_at, 7_000);
        assert_eq!(got.metadata, ProfileMetadata::default());
    }

    #[test]
    fn mark_unknown_does_not_downgrade_known() {
        // A transient empty fetch must not clobber a previously-Known profile —
        // only its fetched_at (TTL clock) is refreshed.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile(&known_profile("aa", "alice", 1_000, 5_000))
            .unwrap();
        storage
            .touch_profiles_fetched_at(&["aa".to_string()], 9_000)
            .unwrap();
        let got = storage.get_profile("aa").unwrap().unwrap();
        assert_eq!(got.state, ProfileState::Known, "must stay Known");
        assert_eq!(got.metadata.name(), Some("alice"));
        assert_eq!(got.event_created_at, 1_000);
        assert_eq!(got.fetched_at, 9_000, "TTL clock refreshed");
    }

    #[test]
    fn picture_roundtrip() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile_picture(
                "aa",
                "https://blossom.example/abc",
                &[0xAB; 32],
                b"canonical-bytes",
                b"thumb-bytes",
                4_000,
            )
            .unwrap();
        assert_eq!(
            &*storage.get_profile_picture("aa").unwrap().unwrap(),
            b"canonical-bytes"
        );
        assert_eq!(
            &*storage.get_profile_thumbnail("aa").unwrap().unwrap(),
            b"thumb-bytes"
        );
        // Replace.
        storage
            .upsert_profile_picture(
                "aa",
                "https://blossom.example/def",
                &[0xCD; 32],
                b"new-canonical",
                b"new-thumb",
                5_000,
            )
            .unwrap();
        assert_eq!(
            &*storage.get_profile_picture("aa").unwrap().unwrap(),
            b"new-canonical"
        );
        // Missing → None.
        assert!(storage.get_profile_picture("bb").unwrap().is_none());
        assert!(storage.get_profile_thumbnail("bb").unwrap().is_none());
    }

    #[test]
    fn keyed_by_pubkey_not_group() {
        // The SAME pubkey resolves to ONE profile / picture row regardless of
        // any circle context — there is no per-group partition.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile(&known_profile("aa", "alice", 1, 1))
            .unwrap();
        storage
            .upsert_profile(&known_profile("aa", "alice2", 2, 2))
            .unwrap();
        // Second upsert replaced the first (single row keyed by pubkey), it did
        // not create a second per-group row.
        let count: i64 = {
            let conn = storage.conn().lock().unwrap();
            conn.query_row(
                "SELECT COUNT(*) FROM profiles WHERE pubkey = 'aa'",
                [],
                |r| r.get(0),
            )
            .unwrap()
        };
        assert_eq!(count, 1, "one row per pubkey, never per (pubkey, group)");
    }

    #[test]
    fn profiles_table_has_no_circle_or_group_column() {
        // PRAGMA table_info structural assertion: the cache MUST NOT carry any
        // circle / group identifier (Rule 4 / Security review).
        let storage = CircleStorage::in_memory().unwrap();
        for table in ["profiles", "profile_pictures"] {
            let conn = storage.conn().lock().unwrap();
            let mut stmt = conn
                .prepare(&format!("PRAGMA table_info({table})"))
                .unwrap();
            let cols: Vec<String> = stmt
                .query_map([], |row| row.get::<_, String>(1))
                .unwrap()
                .collect::<std::result::Result<Vec<_>, _>>()
                .unwrap();
            for col in &cols {
                let lower = col.to_ascii_lowercase();
                assert!(
                    !lower.contains("circle") && !lower.contains("group") && !lower.contains("mls"),
                    "{table} must not carry a circle/group column, found `{col}`"
                );
            }
        }
    }

    #[test]
    fn has_published_profile_false_on_fresh_state() {
        // Retraction no-op gate: nothing published, no picture → false.
        let storage = CircleStorage::in_memory().unwrap();
        let keys = Keys::generate();
        assert!(!storage.has_published_profile(&keys.public_key()).unwrap());
    }

    #[test]
    fn has_published_profile_true_after_kind0_record() {
        let storage = CircleStorage::in_memory().unwrap();
        let keys = Keys::generate();
        // Throwaway event used ONLY as an `.id` source; its kind is irrelevant
        // (the recorded kind-0-ness comes from the `0` arg below), so a non-kind-0
        // builder keeps kind-0 construction confined to profile/ per the CI guard.
        let event = EventBuilder::new(Kind::TextNote, "x")
            .sign_with_keys(&keys)
            .unwrap();
        storage
            .record_published_event(0, "", &event.id, &keys.public_key(), 1_000)
            .unwrap();
        assert!(storage.has_published_profile(&keys.public_key()).unwrap());
    }

    #[test]
    fn has_published_profile_true_when_picture_cached() {
        let storage = CircleStorage::in_memory().unwrap();
        let keys = Keys::generate();
        storage
            .upsert_profile_picture(
                &keys.public_key().to_hex(),
                "https://blossom.example/x",
                &[0x11; 32],
                b"c",
                b"t",
                1_000,
            )
            .unwrap();
        assert!(storage.has_published_profile(&keys.public_key()).unwrap());
    }

    #[test]
    fn wipe_all_profiles_clears_both_tables() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile(&known_profile("aa", "alice", 1, 1))
            .unwrap();
        storage
            .upsert_profile_picture("aa", "https://x/y", &[0x22; 32], b"c", b"t", 1)
            .unwrap();
        storage.wipe_all_profiles().unwrap();
        assert!(storage.get_profile("aa").unwrap().is_none());
        assert!(storage.get_profile_picture("aa").unwrap().is_none());
    }

    // ---- per-pubkey picture deletion (HIGH-1 / HIGH-2) ---------------------

    #[test]
    fn remove_own_picture_deletes_cached_bytes() {
        // The per-pubkey delete removes ONLY the target row's bytes; without it
        // a removed avatar reappears from the cache and survives restart.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile_picture("aa", "https://x/a", &[0x22; 32], b"c", b"t", 1)
            .unwrap();
        storage
            .upsert_profile_picture("bb", "https://x/b", &[0x33; 32], b"c", b"t", 1)
            .unwrap();
        storage.delete_profile_picture("aa").unwrap();
        assert!(
            storage.get_profile_picture("aa").unwrap().is_none(),
            "target bytes deleted"
        );
        assert!(storage.get_profile_thumbnail("aa").unwrap().is_none());
        assert!(storage.get_profile_picture_url("aa").unwrap().is_none());
        assert!(
            storage.get_profile_picture("bb").unwrap().is_some(),
            "other pubkeys untouched"
        );
        // Deleting an absent row is a harmless no-op.
        storage.delete_profile_picture("zz").unwrap();
    }

    // ---- has_current_picture semantics (HIGH-2) ----------------------------

    #[test]
    fn has_current_picture_true_when_url_matches() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile_picture("aa", "https://x/cur", &[0x22; 32], b"c", b"t", 1)
            .unwrap();
        assert!(storage
            .has_current_picture("aa", Some("https://x/cur"))
            .unwrap());
    }

    #[test]
    fn has_picture_false_when_url_changed() {
        // Bytes cached under an OLD url; the kind-0 now points elsewhere → the
        // cached bytes are stale (has_picture must report false).
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile_picture("aa", "https://x/old", &[0x22; 32], b"c", b"t", 1)
            .unwrap();
        assert!(!storage
            .has_current_picture("aa", Some("https://x/new"))
            .unwrap());
    }

    #[test]
    fn has_picture_false_when_picture_cleared() {
        // Bytes still cached but the kind-0 has no picture → stale.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile_picture("aa", "https://x/old", &[0x22; 32], b"c", b"t", 1)
            .unwrap();
        assert!(!storage.has_current_picture("aa", None).unwrap());
    }

    #[test]
    fn has_current_picture_false_when_no_bytes() {
        let storage = CircleStorage::in_memory().unwrap();
        assert!(!storage
            .has_current_picture("aa", Some("https://x/cur"))
            .unwrap());
    }

    #[test]
    fn get_profile_picture_url_returns_stored_url() {
        let storage = CircleStorage::in_memory().unwrap();
        assert!(storage.get_profile_picture_url("aa").unwrap().is_none());
        storage
            .upsert_profile_picture("aa", "https://x/cur", &[0x22; 32], b"c", b"t", 1)
            .unwrap();
        assert_eq!(
            storage.get_profile_picture_url("aa").unwrap().as_deref(),
            Some("https://x/cur")
        );
    }

    #[test]
    fn touch_advances_fetched_at_for_an_unchanged_profile() {
        // The staleness gate reads `fetched_at`, but `upsert_profile_if_newer`
        // only writes when the event is STRICTLY newer — so for the common case
        // (member has not changed their kind-0) the relay returns the same
        // event, no row is written, and `fetched_at` would freeze at the first
        // fetch forever. That silently kills every staleness tier: each trigger
        // would issue a real relay REQ no matter how recently one ran.
        let storage = CircleStorage::in_memory().unwrap();
        let hex = "ab".repeat(32);

        // First fetch at t=100.
        storage
            .upsert_profile(&known_profile(&hex, "alice", 5, 100))
            .unwrap();
        assert_eq!(storage.get_profile(&hex).unwrap().unwrap().fetched_at, 100);

        // Refetch at t=1000 returns the SAME event (created_at unchanged).
        let same_event = known_profile(&hex, "alice", 5, 1000);
        assert!(
            !storage.upsert_profile_if_newer(&same_event).unwrap(),
            "an equal-timestamp event must not rewrite the content row"
        );
        assert_eq!(
            storage.get_profile(&hex).unwrap().unwrap().fetched_at,
            100,
            "content write is correctly skipped, leaving fetched_at stale"
        );

        // Touching the attempt is what keeps the tier gate alive.
        storage
            .touch_profiles_fetched_at(&[hex.clone()], 1000)
            .unwrap();
        let row = storage.get_profile(&hex).unwrap().unwrap();
        assert_eq!(row.fetched_at, 1000, "the fetch attempt must be recorded");
        assert_eq!(row.state, ProfileState::Known, "state must not downgrade");
        assert_eq!(
            row.metadata.name().map(ToString::to_string),
            Some("alice".to_string()),
            "content must survive a touch"
        );
        assert_eq!(row.event_created_at, 5, "newer-wins base must survive");
    }

    #[test]
    fn touch_inserts_an_unknown_row_for_a_never_seen_pubkey() {
        // Same statement also covers authors that returned nothing, so one call
        // records the attempt for the whole batch.
        let storage = CircleStorage::in_memory().unwrap();
        let hex = "cd".repeat(32);
        storage
            .touch_profiles_fetched_at(&[hex.clone()], 700)
            .unwrap();
        let row = storage.get_profile(&hex).unwrap().unwrap();
        assert_eq!(row.state, ProfileState::Unknown);
        assert_eq!(row.fetched_at, 700);
    }

    #[test]
    fn get_profile_picture_sha256_hex_returns_lowercase_hex() {
        let storage = CircleStorage::in_memory().unwrap();
        assert!(storage
            .get_profile_picture_sha256_hex("aa")
            .unwrap()
            .is_none());
        let mut sha = [0x00_u8; 32];
        sha[0] = 0x0a;
        sha[31] = 0xff;
        storage
            .upsert_profile_picture("aa", "https://x/cur", &sha, b"c", b"t", 1)
            .unwrap();
        let hex = storage
            .get_profile_picture_sha256_hex("aa")
            .unwrap()
            .expect("hash present once bytes are cached");
        // 32 bytes → 64 hex chars, zero-padded per byte, lowercase.
        assert_eq!(hex.len(), 64);
        assert!(hex.starts_with("0a00"));
        assert!(hex.ends_with("ff"));
        assert_eq!(hex, hex.to_lowercase());
    }

    #[test]
    fn picture_sha256_hex_changes_when_picture_changes() {
        // The whole point of surfacing this hash: it is the avatar decode-cache
        // key, so a member swapping their photo MUST produce a different value
        // or the old avatar keeps rendering from cache.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile_picture("aa", "https://x/one", &[0x11; 32], b"c", b"t", 1)
            .unwrap();
        let first = storage.get_profile_picture_sha256_hex("aa").unwrap();
        storage
            .upsert_profile_picture("aa", "https://x/two", &[0x22; 32], b"c2", b"t2", 2)
            .unwrap();
        let second = storage.get_profile_picture_sha256_hex("aa").unwrap();
        assert_ne!(first, second);
    }

    #[test]
    fn picture_sha256_hex_is_none_after_delete() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile_picture("aa", "https://x/cur", &[0x33; 32], b"c", b"t", 1)
            .unwrap();
        storage.delete_profile_picture("aa").unwrap();
        assert!(storage
            .get_profile_picture_sha256_hex("aa")
            .unwrap()
            .is_none());
    }

    #[test]
    fn profile_rows_are_keyed_by_lowercase_hex() {
        // LOW-6 contract: rows are keyed by canonical lowercase `to_hex()`, so a
        // raw uppercase query MISSES its row — hence the FFI must normalize the
        // caller's hex before dedup/query.
        let storage = CircleStorage::in_memory().unwrap();
        let hex_lower = "ab".repeat(32);
        storage
            .upsert_profile(&known_profile(&hex_lower, "alice", 1, 1))
            .unwrap();
        let hex_upper = hex_lower.to_ascii_uppercase();
        assert!(
            storage.get_profiles(&[hex_upper]).unwrap().is_empty(),
            "uppercase key must miss the lowercase-keyed row (why the FFI normalizes)"
        );
        assert_eq!(
            storage.get_profiles(&[hex_lower]).unwrap().len(),
            1,
            "the normalized lowercase key hits"
        );
    }

    // ---- upsert_profile_if_newer: newer-wins fetch gate (MEDIUM-3) ----------

    #[test]
    fn stale_relay_refetch_does_not_downgrade_newer_cached_profile() {
        // A newer profile is cached; a lagging relay returns an OLDER revision on
        // a forced refetch. The gate must reject the older write.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile(&known_profile("aa", "new-name", 2_000, 5_000))
            .unwrap();
        let wrote = storage
            .upsert_profile_if_newer(&known_profile("aa", "old-name", 1_000, 9_000))
            .unwrap();
        assert!(!wrote, "older revision must be skipped");
        let got = storage.get_profile("aa").unwrap().unwrap();
        assert_eq!(got.metadata.name(), Some("new-name"), "no downgrade");
        assert_eq!(got.event_created_at, 2_000);
    }

    #[test]
    fn forced_refresh_after_publish_keeps_optimistic_edit() {
        // publish_my_profile optimistically caches the just-built edit at
        // created_at = now. A forced refresh that pulls a PRE-edit external copy
        // (older created_at) must not revert the saved edit.
        let storage = CircleStorage::in_memory().unwrap();
        let now = 10_000;
        storage
            .upsert_profile(&known_profile("aa", "edited", now, now))
            .unwrap();
        // Pre-edit copy fetched from a relay that hasn't seen the new revision.
        let wrote = storage
            .upsert_profile_if_newer(&known_profile("aa", "pre-edit", now - 500, now + 1))
            .unwrap();
        assert!(!wrote, "pre-edit external copy must not overwrite the edit");
        assert_eq!(
            storage.get_profile("aa").unwrap().unwrap().metadata.name(),
            Some("edited")
        );
    }

    #[test]
    fn upsert_if_newer_writes_first_row_and_strictly_newer() {
        let storage = CircleStorage::in_memory().unwrap();
        // No row yet → first write always lands.
        assert!(storage
            .upsert_profile_if_newer(&known_profile("aa", "v1", 1_000, 1_000))
            .unwrap());
        // Strictly newer → writes.
        assert!(storage
            .upsert_profile_if_newer(&known_profile("aa", "v2", 2_000, 2_000))
            .unwrap());
        assert_eq!(
            storage.get_profile("aa").unwrap().unwrap().metadata.name(),
            Some("v2")
        );
        // Equal created_at → not newer → skipped.
        assert!(!storage
            .upsert_profile_if_newer(&known_profile("aa", "v2-dup", 2_000, 3_000))
            .unwrap());
    }

    #[test]
    fn upsert_if_newer_always_allows_unknown_to_known() {
        // An Unknown row (a recorded miss, event_created_at = 0) must be
        // superseded by any resolved Known — even one whose created_at is 0.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .touch_profiles_fetched_at(&["aa".to_string()], 5_000)
            .unwrap();
        let mut resolved = known_profile("aa", "resolved", 0, 6_000);
        resolved.state = ProfileState::Known;
        assert!(
            storage.upsert_profile_if_newer(&resolved).unwrap(),
            "Unknown → Known transition is always allowed"
        );
        let got = storage.get_profile("aa").unwrap().unwrap();
        assert_eq!(got.state, ProfileState::Known);
        assert_eq!(got.metadata.name(), Some("resolved"));
    }
}
