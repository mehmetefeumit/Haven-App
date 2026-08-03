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
//!   retraction no-op gate ([`CircleStorage::has_published_profile`]).
//! * The per-install profile-relay salt lives in `user_settings` and is wiped
//!   together with the cache — see
//!   [`CircleStorage::get_or_create_profile_relay_salt`].

// Mirror `storage.rs`: each method acquires the connection lock once at the top
// and holds it for the whole (single-statement or transactional) operation.
#![allow(clippy::significant_drop_tightening)]

use nostr::{JsonUtil, Metadata, PublicKey};
use rusqlite::{params, Connection, OptionalExtension};
use zeroize::Zeroizing;

use super::error::{CircleError, Result};
use super::storage::CircleStorage;
use crate::profile::picture_is_current;
use crate::profile::types::{CachedProfile, ProfileMetadata, ProfileState};
use crate::profile::ProfileRelaySalt;

/// `user_settings` key holding the per-install profile-relay salt as 64
/// lowercase hex characters.
const PROFILE_RELAY_SALT_KEY: &str = "profile_relay_salt_v1";

/// Retry ladder (seconds) for an author whose kind-0 MISSED on its assigned
/// relay: `30s → 2min → 8min → 30min → 6h`, then 6h forever.
///
/// Indexed by the author's `miss_count` **before** the miss being recorded is
/// counted (equivalently `new_miss_count - 1`), saturating at the last rung, so
/// the first miss schedules the first entry.
///
/// # Why the first rung is only 30 seconds
///
/// Under one-relay-per-member assignment a miss means "*that* relay did not
/// have it", not "nobody has it" — the member very likely exists and is simply
/// not mirrored there. The retry walks to the next-ranked relay
/// (`assigned_relay_for_attempt`), so a short first rung is what turns a
/// transient `Unknown` into a resolved name inside one UI session instead of
/// pinning the member as `Unknown` for a staleness tier. The ladder then grows
/// quickly, so an author whose kind-0 genuinely does not exist costs at most a
/// handful of REQs per day (and, per `PROFILE_MAX_RELAY_RANK`, is disclosed to
/// a bounded number of relays no matter how long the ladder runs).
pub const PROFILE_MISS_BACKOFF_SECS: &[i64] = &[30, 120, 480, 1_800, 21_600];

/// The backoff to apply after a miss, given the author's `miss_count` *before*
/// the increment. Saturates on the last rung of [`PROFILE_MISS_BACKOFF_SECS`].
fn miss_backoff_secs(prior_miss_count: i64) -> i64 {
    // The ladder is a non-empty compile-time constant, so `len() - 1` and the
    // subsequent index are both in range.
    let last = PROFILE_MISS_BACKOFF_SECS.len().saturating_sub(1);
    let index = usize::try_from(prior_miss_count.max(0))
        .unwrap_or(last)
        .min(last);
    PROFILE_MISS_BACKOFF_SECS.get(index).copied().unwrap_or(0)
}

impl CircleStorage {
    // ==================== kind-0 metadata cache ====================

    /// Inserts or replaces a cached profile row (keyed by pubkey hex).
    ///
    /// This write is unconditional; callers gate freshness with
    /// [`Self::newer_than_cached`] before invoking it. A miss (no kind-0 for a
    /// pubkey) is recorded via [`Self::record_profile_misses`], not here, so a
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

    // NOTE: there is deliberately no blanket "stamp every ATTEMPTED author"
    // method. `touch_profiles_fetched_at` was exactly that, and it was DELETED
    // rather than deprecated: it stamped hits and misses alike, which was
    // correct only while one filter fanned out to the whole read set (a miss
    // then really did mean "nobody has it"). Under one-relay-per-member
    // assignment a miss means "*that* relay lacked it", and stamping it resets
    // the staleness clock and pins the member `Unknown` for a whole tier. Use
    // the split below — `touch_profiles_hit` for authors the relay answered
    // for, `record_profile_misses` for the rest — and stamp an author the cycle
    // never reached in NEITHER (see `profile_stamp_lists` in the FFI crate).

    /// Records a profile fetch **HIT** for each pubkey at `now_unix_secs`:
    /// advances the staleness clock and clears the miss state.
    ///
    /// Call this for every author whose kind-0 the assigned relay actually
    /// returned — including one whose content did not change. kind-0 is
    /// replaceable, so an unchanged profile comes back with the same
    /// `created_at`, [`Self::upsert_profile_if_newer`] correctly declines to
    /// rewrite the row, and `fetched_at` would otherwise stay pinned to the
    /// first-ever fetch, permanently defeating every staleness tier.
    ///
    /// Authors the relay did NOT answer for go to [`Self::record_profile_misses`]
    /// instead. Splitting the two is the whole point: stamping a miss as if it
    /// were a hit is what pins a member `Unknown` for a full staleness tier.
    ///
    /// The `ON CONFLICT` clause updates only `fetched_at`, `miss_count` and
    /// `next_retry_at` — never `state` or `metadata_json` — so recording a hit
    /// can never downgrade cached content.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn touch_profiles_hit(&self, pubkeys_hex: &[String], now_unix_secs: i64) -> Result<()> {
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
                "INSERT INTO profiles
                     (pubkey, metadata_json, state, event_created_at, fetched_at,
                      miss_count, next_retry_at)
                 VALUES (?1, '{}', 0, 0, ?2, 0, 0)
                 ON CONFLICT(pubkey) DO UPDATE SET
                     fetched_at    = excluded.fetched_at,
                     miss_count    = 0,
                     next_retry_at = 0",
            )?;
            for pubkey_hex in pubkeys_hex {
                stmt.execute(params![pubkey_hex, now_unix_secs])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Records a **MISS** on the assigned relay for each pubkey: bumps
    /// `miss_count` and schedules the next retry from
    /// [`PROFILE_MISS_BACKOFF_SECS`].
    ///
    /// This deliberately does **not** touch `fetched_at`, `state` or
    /// `metadata_json`. Under one-relay-per-member assignment a miss carries far
    /// less information than it did when the filter fanned out to the whole
    /// read set: it means "the relay this author hashes to did not have it", not
    /// "no relay has it". Stamping it like a hit would (a) reset the staleness
    /// clock of an already-`Known` row, suppressing the retry that would have
    /// resolved it, and (b) leave a never-resolved author displayed as
    /// `Unknown` until a full staleness tier elapsed. The retry schedule lives
    /// in `next_retry_at` precisely so the miss does not have to lie about
    /// `fetched_at` to be remembered.
    ///
    /// A pubkey with no row yet gets an `Unknown` row seeded with
    /// `miss_count = 1`; its `fetched_at` is set to `now_unix_secs` because a
    /// brand-new row has no prior value to preserve (and seeding `0` would make
    /// any staleness-based caller treat it as infinitely stale, defeating the
    /// backoff it is being given).
    ///
    /// Duplicate entries in `pubkeys_hex` are counted once per occurrence;
    /// callers pass the normalized, de-duplicated list they queried.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn record_profile_misses(&self, pubkeys_hex: &[String], now_unix_secs: i64) -> Result<()> {
        if pubkeys_hex.is_empty() {
            return Ok(());
        }
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        {
            // Read-then-write (rather than computing the schedule in SQL) keeps
            // the backoff ladder in Rust as the single source of truth instead
            // of duplicating it as a CASE expression. It is atomic: one lock,
            // one transaction. The write is a single UPSERT whose `fetched_at`
            // therefore applies to the INSERT path ONLY — the `DO UPDATE` arm
            // deliberately leaves an existing row's `fetched_at` / `state` /
            // `metadata_json` untouched.
            let mut read = tx.prepare("SELECT miss_count FROM profiles WHERE pubkey = ?1")?;
            let mut write = tx.prepare(
                "INSERT INTO profiles
                     (pubkey, metadata_json, state, event_created_at, fetched_at,
                      miss_count, next_retry_at)
                 VALUES (?1, '{}', 0, 0, ?2, ?3, ?4)
                 ON CONFLICT(pubkey) DO UPDATE SET
                     miss_count    = excluded.miss_count,
                     next_retry_at = excluded.next_retry_at",
            )?;
            for pubkey_hex in pubkeys_hex {
                // Absent row → prior count 0, so both paths schedule the first
                // ladder rung and land on `miss_count = 1`.
                let prior_miss_count: i64 = read
                    .query_row(params![pubkey_hex], |r| r.get(0))
                    .optional()?
                    .unwrap_or(0)
                    .max(0);
                let retry_at = now_unix_secs.saturating_add(miss_backoff_secs(prior_miss_count));
                write.execute(params![
                    pubkey_hex,
                    now_unix_secs,
                    prior_miss_count.saturating_add(1),
                    retry_at
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// The subset of `pubkeys_hex` that is due a kind-0 fetch, paired with the
    /// **attempt index** to fetch it at.
    ///
    /// The attempt index feeds
    /// [`assigned_relay_for_attempt`](crate::profile::assigned_relay_for_attempt),
    /// which walks the author's rendezvous ranking so a repeated miss retries on
    /// the next-ranked relay instead of hammering the one that already answered
    /// "no" (capped at
    /// [`PROFILE_MAX_RELAY_RANK`](crate::profile::PROFILE_MAX_RELAY_RANK), so
    /// per-author disclosure stays bounded).
    ///
    /// The predicate, in order:
    ///
    /// | row state | condition | attempt |
    /// |---|---|---|
    /// | any (`max_age_secs == 0`, forced) | always due | `miss_count` |
    /// | no row | always due | `0` |
    /// | `Known` | `now - fetched_at >= max_age_secs` | `0` |
    /// | `Unknown` | `now >= next_retry_at` | `miss_count` |
    /// | otherwise | not due | — |
    ///
    /// A `Known` row is retried at attempt `0` because its assigned relay
    /// demonstrably serves that author; only an unresolved author walks the
    /// ladder. Output preserves input order, one entry per due input element;
    /// callers pass the normalized, de-duplicated list.
    ///
    /// # Errors
    ///
    /// As [`Self::upsert_profile`].
    pub fn profiles_due(
        &self,
        pubkeys_hex: &[String],
        now_unix_secs: i64,
        max_age_secs: i64,
    ) -> Result<Vec<(String, u8)>> {
        if pubkeys_hex.is_empty() {
            return Ok(Vec::new());
        }
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let mut stmt = conn.prepare(
            "SELECT state, fetched_at, miss_count, next_retry_at
             FROM profiles WHERE pubkey = ?1",
        )?;
        let mut due = Vec::new();
        for pubkey_hex in pubkeys_hex {
            let row = stmt
                .query_row(params![pubkey_hex], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
                })
                .optional()?;
            if let Some(attempt) = Self::due_attempt(row, now_unix_secs, max_age_secs) {
                due.push((pubkey_hex.clone(), attempt));
            }
        }
        Ok(due)
    }

    // ==================== profile-relay salt ====================

    /// Reads the per-install profile-relay salt, minting one on first use.
    ///
    /// The salt keys the rendezvous hash that assigns each author's kind-0 to
    /// exactly one pool relay (`crate::profile::assignment`). It must be
    /// **stable for the life of the install**: every change re-assigns authors
    /// and therefore discloses them to an ADDITIONAL relay, so repeated
    /// rotation converges on "every pool relay has seen every contact". This
    /// method is consequently the only mint site, and it never rotates an
    /// existing, well-formed salt.
    ///
    /// The read and the conditional insert happen under a single acquisition of
    /// the connection lock, and the insert is `INSERT OR IGNORE` followed by a
    /// re-read, so two concurrent first-uses converge on ONE salt (the loser
    /// adopts the winner's) rather than each minting their own and silently
    /// re-assigning half the contact set.
    ///
    /// An unparseable stored value (only reachable through corruption or
    /// tampering — nothing else writes this key) is replaced with a fresh salt
    /// and logged without echoing the value: the previous mapping is
    /// unrecoverable either way, and failing closed here would permanently
    /// disable profile resolution.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Storage`] on lock poisoning or if the just-written
    /// row cannot be read back, [`CircleError::Database`] on `SQLite` failure,
    /// and [`CircleError::InvalidData`] if the re-read value is malformed. No
    /// error ever carries the salt or any part of it.
    pub fn get_or_create_profile_relay_salt(&self) -> Result<ProfileRelaySalt> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        // Fast path: a well-formed salt is already stored — never rotate it.
        let stored = Self::read_salt_hex(&conn)?;
        if let Some(salt) = stored
            .as_ref()
            .and_then(|hex| ProfileRelaySalt::from_hex(hex).ok())
        {
            return Ok(salt);
        }

        let fresh = ProfileRelaySalt::generate();
        let fresh_hex = fresh.to_hex();

        if stored.is_some() {
            // A row exists but is unusable: overwrite it. The message never
            // includes the stored value (it is an install fingerprint).
            conn.execute(
                "INSERT INTO user_settings (key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![PROFILE_RELAY_SALT_KEY, fresh_hex.as_str()],
            )?;
            log::warn!("profile relay salt was unreadable; minted a replacement");
            return Ok(fresh);
        }

        // First use. `OR IGNORE` + re-read makes a concurrent first-use
        // converge on a single salt instead of clobbering one another.
        conn.execute(
            "INSERT OR IGNORE INTO user_settings (key, value) VALUES (?1, ?2)",
            params![PROFILE_RELAY_SALT_KEY, fresh_hex.as_str()],
        )?;
        let winner = Self::read_salt_hex(&conn)?.ok_or_else(|| {
            CircleError::Storage("profile relay salt missing immediately after insert".to_string())
        })?;
        ProfileRelaySalt::from_hex(&winner)
            .map_err(|_| CircleError::InvalidData("profile relay salt is malformed".to_string()))
    }

    // NOTE: there is deliberately no standalone `clear_profile_relay_salt`.
    // Only two things ever destroy the salt, and neither needs one:
    //
    // * profile DELETE — [`Self::wipe_all_profiles`], which drops the row inside
    //   its own transaction;
    // * LOGOUT — the `circles.db` file (and its sidecars) are deleted wholesale
    //   by the FFI wipe, which takes the salt with them because `user_settings`
    //   is the salt's ONLY persistence (no keyring entry, no sidecar file).
    //   Pinned by `profile_relay_salt_does_not_outlive_the_circles_db_file`.
    //
    // A public "clear the salt" method with no caller previously documented
    // itself as the logout path, which was wrong in a way that mattered:
    // it made the logout guarantee look tested when nothing tested it.

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

    /// Wipes all cached profiles and pictures **and the profile-relay salt**.
    ///
    /// # Which path reaches this — and which does not
    ///
    /// This is the PROFILE-DELETE path (the FFI `delete_my_public_profile`
    /// retraction), not the logout path. Logout deletes the whole `circles.db`
    /// file instead, so it destroys the same rows without calling anything here.
    /// Do not describe this method as "the account wipe": a reader who believes
    /// that will also believe logout's salt destruction is covered by
    /// `profile_relay_salt_is_cleared_by_wipe_all_profiles`, and it is not — see
    /// `profile_relay_salt_does_not_outlive_the_circles_db_file` for the test
    /// that actually pins logout.
    ///
    /// # Why the salt goes too
    ///
    /// Dropping the salt is not housekeeping, it is a linkability fix: a
    /// surviving salt gives the next identity on this device the previous
    /// identity's per-author relay assignment, so a pool relay that served both
    /// would see one install's stable assignment fingerprint span two pubkeys
    /// and could link them.
    ///
    /// The delete is issued inside this method's transaction, via the shared
    /// [`Self::delete_salt_row`] statement, so it cannot drift from the salt
    /// key the reader/minter uses.
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
        Self::delete_salt_row(&tx)?;
        tx.commit()?;
        Ok(())
    }

    // ---- private helpers ----

    /// Deletes the stored profile-relay salt on an already-locked connection.
    ///
    /// Takes the connection rather than re-locking so [`Self::wipe_all_profiles`]
    /// can issue it inside its own transaction (the connection mutex is not
    /// reentrant), and keeps the `DELETE` in one place so it cannot drift from
    /// the key [`Self::read_salt_hex`] reads.
    fn delete_salt_row(conn: &Connection) -> rusqlite::Result<()> {
        conn.execute(
            "DELETE FROM user_settings WHERE key = ?1",
            params![PROFILE_RELAY_SALT_KEY],
        )?;
        Ok(())
    }

    /// Reads the raw salt hex, wrapped in [`Zeroizing`] so the plaintext
    /// encoding does not linger after parsing.
    fn read_salt_hex(conn: &Connection) -> rusqlite::Result<Option<Zeroizing<String>>> {
        let raw: Option<String> = conn
            .query_row(
                "SELECT value FROM user_settings WHERE key = ?1",
                params![PROFILE_RELAY_SALT_KEY],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        Ok(raw.map(Zeroizing::new))
    }

    /// The pure due-predicate behind [`Self::profiles_due`], split out so every
    /// branch is unit-testable without a database.
    ///
    /// `row` is `(state, fetched_at, miss_count, next_retry_at)`, or `None` when
    /// the author has no cached row at all.
    fn due_attempt(row: Option<(i64, i64, i64, i64)>, now: i64, max_age_secs: i64) -> Option<u8> {
        let Some((state, fetched_at, miss_count, next_retry_at)) = row else {
            // Never attempted: due now, at the top-ranked relay.
            return Some(0);
        };
        if max_age_secs == 0 {
            // Forced refresh (user-initiated). Resume the ladder where the
            // recorded misses left off rather than re-asking the relay that
            // already answered "no".
            return Some(Self::attempt_index(miss_count));
        }
        if state == ProfileState::Known.as_db_value() {
            // Resolved content: plain staleness, and its assigned relay
            // demonstrably serves this author, so stay at rank 0.
            return (now.saturating_sub(fetched_at) >= max_age_secs).then_some(0);
        }
        // Unresolved: the backoff schedule is authoritative, NOT `fetched_at`.
        (now >= next_retry_at).then(|| Self::attempt_index(miss_count))
    }

    /// Clamps a stored `miss_count` into the `u8` attempt index. A negative
    /// value (only reachable by hand-editing the database) reads as zero; a
    /// huge one saturates, and is capped again by `PROFILE_MAX_RELAY_RANK`
    /// when it reaches the assignment ladder.
    fn attempt_index(miss_count: i64) -> u8 {
        u8::try_from(miss_count.max(0)).unwrap_or(u8::MAX)
    }

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

    /// Reads the raw miss-cache columns for a pubkey (`None` when no row).
    fn miss_state(storage: &CircleStorage, pubkey_hex: &str) -> Option<(i64, i64)> {
        let conn = storage.conn().lock().unwrap();
        conn.query_row(
            "SELECT miss_count, next_retry_at FROM profiles WHERE pubkey = ?1",
            params![pubkey_hex],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .unwrap()
    }

    /// The `profiles` column names, in declaration order.
    fn profile_columns(storage: &CircleStorage) -> Vec<String> {
        let conn = storage.conn().lock().unwrap();
        let mut stmt = conn.prepare("PRAGMA table_info(profiles)").unwrap();
        let cols = stmt
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap();
        cols
    }

    /// The raw stored salt hex, or `None`.
    fn stored_salt_hex(storage: &CircleStorage) -> Option<String> {
        let conn = storage.conn().lock().unwrap();
        conn.query_row(
            "SELECT value FROM user_settings WHERE key = ?1",
            params![PROFILE_RELAY_SALT_KEY],
            |r| r.get::<_, String>(0),
        )
        .optional()
        .unwrap()
    }

    fn one(pubkey_hex: &str) -> Vec<String> {
        vec![pubkey_hex.to_string()]
    }

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
    fn hit_does_not_downgrade_known() {
        // A hit on an unchanged profile must not clobber the cached content —
        // only its fetched_at (staleness clock) moves.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile(&known_profile("aa", "alice", 1_000, 5_000))
            .unwrap();
        storage
            .touch_profiles_hit(&["aa".to_string()], 9_000)
            .unwrap();
        let got = storage.get_profile("aa").unwrap().unwrap();
        assert_eq!(got.state, ProfileState::Known, "must stay Known");
        assert_eq!(got.metadata.name(), Some("alice"));
        assert_eq!(got.event_created_at, 1_000);
        assert_eq!(got.fetched_at, 9_000, "staleness clock refreshed");
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

        // Recording the HIT is what keeps the tier gate alive.
        storage
            .touch_profiles_hit(std::slice::from_ref(&hex), 1000)
            .unwrap();
        let row = storage.get_profile(&hex).unwrap().unwrap();
        assert_eq!(row.fetched_at, 1000, "the answered fetch must be recorded");
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
        // A hit is normally accompanied by an `upsert_profile*` that lands the
        // content; the row this statement inserts on its own is the placeholder
        // that carries the staleness clock, so it must be `Unknown` with an
        // empty metadata blob rather than a fabricated "known-but-blank" row.
        let storage = CircleStorage::in_memory().unwrap();
        let hex = "cd".repeat(32);
        storage
            .touch_profiles_hit(std::slice::from_ref(&hex), 700)
            .unwrap();
        let row = storage.get_profile(&hex).unwrap().unwrap();
        assert_eq!(row.state, ProfileState::Unknown);
        assert_eq!(row.fetched_at, 700);
        assert_eq!(row.event_created_at, 0, "no newer-wins base is invented");
        assert_eq!(row.metadata, ProfileMetadata::default());
        assert_eq!(
            miss_state(&storage, &hex),
            Some((0, 0)),
            "a hit seeds no backoff"
        );
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

    // ---- miss-aware negative cache -----------------------------------------

    #[test]
    fn miss_schedules_second_relay_retry() {
        // A miss on the assigned relay must (a) be counted and (b) schedule the
        // retry on the NEXT-ranked relay after the first ladder rung — not
        // re-ask the relay that already answered "no", and not wait a full
        // staleness tier.
        let storage = CircleStorage::in_memory().unwrap();
        let now = 1_000;

        storage.record_profile_misses(&one("aa"), now).unwrap();

        let (miss_count, next_retry_at) = miss_state(&storage, "aa").expect("miss row inserted");
        assert_eq!(miss_count, 1, "the miss must be counted");
        assert_eq!(
            next_retry_at,
            now + PROFILE_MISS_BACKOFF_SECS[0],
            "first miss schedules the 30s rung"
        );
        assert_eq!(
            next_retry_at,
            now + 30,
            "the 30s rung is what keeps UX sane"
        );

        // One second early: still backed off.
        assert!(
            storage
                .profiles_due(&one("aa"), now + 29, 900)
                .unwrap()
                .is_empty(),
            "must not be due before next_retry_at"
        );

        // At the scheduled instant: due, and at attempt 1 → the SECOND-ranked
        // relay in the author's rendezvous ranking.
        assert_eq!(
            storage.profiles_due(&one("aa"), now + 30, 900).unwrap(),
            vec![("aa".to_string(), 1)],
        );
    }

    #[test]
    fn miss_does_not_stamp_fetched_at_like_a_hit() {
        // THE bug this split fixes. The old `touch_profiles_fetched_at` stamped
        // every attempted author, so a miss on the one assigned relay reset the
        // staleness clock of a Known row and suppressed the retry that would
        // have resolved it.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile(&known_profile("aa", "alice", 1_000, 5_000))
            .unwrap();

        storage.record_profile_misses(&one("aa"), 9_000).unwrap();

        let got = storage.get_profile("aa").unwrap().unwrap();
        assert_eq!(got.fetched_at, 5_000, "a miss must NOT advance fetched_at");
        assert_eq!(got.state, ProfileState::Known, "a miss must not downgrade");
        assert_eq!(
            got.metadata.name(),
            Some("alice"),
            "a miss must not clobber cached metadata"
        );
        assert_eq!(got.event_created_at, 1_000, "newer-wins base must survive");

        // The miss WAS recorded — just in the backoff columns, not by lying
        // about `fetched_at`.
        assert_eq!(miss_state(&storage, "aa"), Some((1, 9_030)));
    }

    #[test]
    fn hit_clears_miss_backoff() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile(&known_profile("aa", "alice", 1_000, 5_000))
            .unwrap();

        // Two misses put the author deep in the ladder.
        storage.record_profile_misses(&one("aa"), 6_000).unwrap();
        storage.record_profile_misses(&one("aa"), 6_030).unwrap();
        assert_eq!(miss_state(&storage, "aa"), Some((2, 6_030 + 120)));

        // A hit resets both the counter and the schedule, and advances the
        // staleness clock.
        storage.touch_profiles_hit(&one("aa"), 7_000).unwrap();
        assert_eq!(miss_state(&storage, "aa"), Some((0, 0)));
        let got = storage.get_profile("aa").unwrap().unwrap();
        assert_eq!(got.fetched_at, 7_000, "a hit advances the staleness clock");
        assert_eq!(got.state, ProfileState::Known, "a hit never downgrades");
        assert_eq!(got.metadata.name(), Some("alice"));

        // Back to plain staleness: not due again until the tier elapses, and
        // then at attempt 0 (its assigned relay demonstrably serves it).
        assert!(storage
            .profiles_due(&one("aa"), 7_899, 900)
            .unwrap()
            .is_empty());
        assert_eq!(
            storage.profiles_due(&one("aa"), 7_900, 900).unwrap(),
            vec![("aa".to_string(), 0)],
        );
    }

    #[test]
    fn repeated_misses_walk_the_backoff_ladder_then_saturate() {
        let storage = CircleStorage::in_memory().unwrap();
        let mut now = 0;
        for (i, rung) in PROFILE_MISS_BACKOFF_SECS.iter().enumerate() {
            storage.record_profile_misses(&one("aa"), now).unwrap();
            let (miss_count, next_retry_at) = miss_state(&storage, "aa").unwrap();
            assert_eq!(miss_count, i64::try_from(i).unwrap() + 1);
            assert_eq!(next_retry_at, now + rung, "rung {i} mismatch");
            now = next_retry_at;
        }
        // Past the end of the ladder it saturates on the last rung forever.
        let last = *PROFILE_MISS_BACKOFF_SECS.last().unwrap();
        for _ in 0..3 {
            storage.record_profile_misses(&one("aa"), now).unwrap();
            let (_, next_retry_at) = miss_state(&storage, "aa").unwrap();
            assert_eq!(next_retry_at, now + last, "ladder must saturate, not panic");
            now = next_retry_at;
        }
    }

    #[test]
    fn miss_on_an_unseen_pubkey_seeds_an_unknown_row() {
        let storage = CircleStorage::in_memory().unwrap();
        storage.record_profile_misses(&one("zz"), 700).unwrap();
        let got = storage.get_profile("zz").unwrap().expect("row seeded");
        assert_eq!(got.state, ProfileState::Unknown);
        assert_eq!(got.event_created_at, 0);
        assert_eq!(got.metadata, ProfileMetadata::default());
        assert_eq!(miss_state(&storage, "zz"), Some((1, 730)));
    }

    #[test]
    fn empty_batches_are_no_ops() {
        let storage = CircleStorage::in_memory().unwrap();
        storage.touch_profiles_hit(&[], 1).unwrap();
        storage.record_profile_misses(&[], 1).unwrap();
        assert!(storage.profiles_due(&[], 1, 900).unwrap().is_empty());
    }

    #[test]
    fn hit_on_an_unseen_pubkey_inserts_a_clean_row() {
        let storage = CircleStorage::in_memory().unwrap();
        storage.touch_profiles_hit(&one("aa"), 700).unwrap();
        let got = storage.get_profile("aa").unwrap().expect("row inserted");
        assert_eq!(got.fetched_at, 700);
        assert_eq!(miss_state(&storage, "aa"), Some((0, 0)));
    }

    // ---- profiles_due: every branch of the predicate ------------------------

    #[test]
    fn profiles_due_returns_attempt_zero_for_an_unseen_pubkey() {
        let storage = CircleStorage::in_memory().unwrap();
        assert_eq!(
            storage.profiles_due(&one("aa"), 1_000, 900).unwrap(),
            vec![("aa".to_string(), 0)],
            "never attempted → due now at the top-ranked relay"
        );
    }

    #[test]
    fn profiles_due_uses_staleness_for_known_rows() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile(&known_profile("aa", "alice", 1, 1_000))
            .unwrap();
        // Inside the tier → not due.
        assert!(storage
            .profiles_due(&one("aa"), 1_899, 900)
            .unwrap()
            .is_empty());
        // Exactly at the tier boundary → due (the predicate is `>=`).
        assert_eq!(
            storage.profiles_due(&one("aa"), 1_900, 900).unwrap(),
            vec![("aa".to_string(), 0)],
        );
    }

    #[test]
    fn profiles_due_uses_the_retry_schedule_for_unknown_rows() {
        let storage = CircleStorage::in_memory().unwrap();
        // Unknown row with a pending backoff.
        storage.record_profile_misses(&one("aa"), 1_000).unwrap();
        // `fetched_at` is irrelevant here — only next_retry_at gates it.
        assert!(storage
            .profiles_due(&one("aa"), 1_029, 900)
            .unwrap()
            .is_empty());
        assert_eq!(
            storage.profiles_due(&one("aa"), 1_030, 900).unwrap(),
            vec![("aa".to_string(), 1)],
        );
    }

    #[test]
    fn profiles_due_forced_refresh_bypasses_every_gate() {
        let storage = CircleStorage::in_memory().unwrap();
        // A brand-new Known row that no staleness tier would refetch...
        storage
            .upsert_profile(&known_profile("aa", "alice", 1, 1_000))
            .unwrap();
        // ...and an Unknown row deep in backoff.
        storage.record_profile_misses(&one("bb"), 1_000).unwrap();
        storage.record_profile_misses(&one("bb"), 1_000).unwrap();

        let due = storage
            .profiles_due(&[String::from("aa"), String::from("bb")], 1_001, 0)
            .unwrap();
        assert_eq!(
            due,
            vec![("aa".to_string(), 0), ("bb".to_string(), 2)],
            "forced: both due, each resuming the ladder at its own miss_count"
        );
    }

    #[test]
    fn profiles_due_preserves_input_order_and_filters() {
        let storage = CircleStorage::in_memory().unwrap();
        // `aa` fresh (not due), `bb` never seen (due), `cc` stale (due).
        storage
            .upsert_profile(&known_profile("aa", "alice", 1, 1_000))
            .unwrap();
        storage
            .upsert_profile(&known_profile("cc", "carol", 1, 10))
            .unwrap();
        let due = storage
            .profiles_due(
                &[String::from("aa"), String::from("bb"), String::from("cc")],
                1_500,
                900,
            )
            .unwrap();
        assert_eq!(
            due,
            vec![("bb".to_string(), 0), ("cc".to_string(), 0)],
            "due subset, in input order"
        );
    }

    #[test]
    fn due_attempt_clamps_a_corrupt_miss_count() {
        // Hand-edited/corrupt values must not panic or overflow the u8 attempt.
        assert_eq!(
            CircleStorage::due_attempt(Some((0, 0, -5, 0)), 10, 900),
            Some(0)
        );
        assert_eq!(
            CircleStorage::due_attempt(Some((0, 0, i64::MAX, 0)), 10, 900),
            Some(u8::MAX)
        );
    }

    // ---- profile-relay salt -------------------------------------------------

    #[test]
    fn profile_relay_salt_is_stable_across_reads() {
        // Rotation is not privacy-preserving: every change re-assigns authors
        // and discloses them to an ADDITIONAL relay. So a minted salt must come
        // back byte-identical forever.
        let storage = CircleStorage::in_memory().unwrap();
        let first = storage
            .get_or_create_profile_relay_salt()
            .unwrap()
            .to_hex()
            .as_str()
            .to_owned();
        assert_eq!(first.len(), 64, "64 lowercase hex characters");
        assert!(first.bytes().all(|b| b.is_ascii_hexdigit()));
        assert_eq!(first, first.to_lowercase());

        for _ in 0..3 {
            let again = storage
                .get_or_create_profile_relay_salt()
                .unwrap()
                .to_hex()
                .as_str()
                .to_owned();
            assert_eq!(again, first, "the salt must never rotate on read");
        }
        assert_eq!(
            stored_salt_hex(&storage).as_deref(),
            Some(first.as_str()),
            "and it is persisted under the documented key"
        );
    }

    #[test]
    // `needless_collect` is WRONG here, and following it would hang the suite:
    // collecting the `JoinHandle`s is what starts all 8 threads before the first
    // `join`. Fusing the spawn into the join iterator makes the spawns lazy —
    // thread N+1 would not exist until thread N had been joined — so the
    // `Barrier::new(8)` every thread waits on could never be released. The
    // collect IS the concurrency this test is named for.
    #[allow(clippy::needless_collect)]
    fn concurrent_first_use_mints_exactly_one_salt() {
        // The read-then-conditional-insert happens under ONE acquisition of the
        // connection lock (and the insert is OR IGNORE + re-read), so racing
        // first-uses converge instead of each minting a salt and silently
        // re-assigning half the contact set.
        use std::sync::{Arc, Barrier};

        let storage = Arc::new(CircleStorage::in_memory().unwrap());
        let threads = 8;
        let barrier = Arc::new(Barrier::new(threads));
        let handles: Vec<_> = (0..threads)
            .map(|_| {
                let storage = Arc::clone(&storage);
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    barrier.wait();
                    storage
                        .get_or_create_profile_relay_salt()
                        .unwrap()
                        .to_hex()
                        .as_str()
                        .to_owned()
                })
            })
            .collect();
        let minted: Vec<String> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        let first = minted.first().expect("threads ran").clone();
        assert!(
            minted.iter().all(|hex| *hex == first),
            "every concurrent first-use must observe the SAME salt"
        );
        assert_eq!(stored_salt_hex(&storage).as_deref(), Some(first.as_str()));
    }

    #[test]
    fn profile_relay_salt_is_cleared_by_wipe_all_profiles() {
        // Scope: this is the PROFILE-DELETE path (`delete_my_public_profile`),
        // the only caller of `wipe_all_profiles`. Logout does NOT come through
        // here — it deletes circles.db wholesale — so this test does not, and
        // must not be read to, prove anything about logout. That guarantee is
        // pinned separately by
        // `profile_relay_salt_does_not_outlive_the_circles_db_file`.
        //
        // Either way the stake is the same: a surviving salt would hand the
        // NEXT identity on this device the previous identity's relay
        // assignment, letting any pool relay that served both link them to one
        // install.
        let storage = CircleStorage::in_memory().unwrap();

        // Wiping with nothing stored is a harmless no-op (the retraction path
        // can run on a never-published, never-fetched install).
        storage.wipe_all_profiles().unwrap();
        assert_eq!(stored_salt_hex(&storage), None);

        let before = storage
            .get_or_create_profile_relay_salt()
            .unwrap()
            .to_hex()
            .as_str()
            .to_owned();

        storage.wipe_all_profiles().unwrap();

        assert_eq!(
            stored_salt_hex(&storage),
            None,
            "wipe_all_profiles must drop the salt row"
        );
        let after = storage
            .get_or_create_profile_relay_salt()
            .unwrap()
            .to_hex()
            .as_str()
            .to_owned();
        assert_ne!(
            after, before,
            "the next identity must get a freshly minted salt"
        );
    }

    #[test]
    fn profile_relay_salt_does_not_outlive_the_circles_db_file() {
        // Logout's salt destruction rests ENTIRELY on "the circles.db file is
        // deleted" (the FFI wipe removes the base file plus every WAL/SHM/
        // journal sidecar). Nothing calls `wipe_all_profiles` on that path, so
        // the only thing that can betray the guarantee is the salt acquiring a
        // second home — a keyring entry, a sidecar, a settings file. Pin it by
        // reproducing the real mechanism against a file-backed database: mint,
        // delete the files, reopen, and require a DIFFERENT salt.
        let dir = tempfile::TempDir::new().expect("temp dir");
        let db_path = dir.path().join("circles.db");

        let before = {
            let storage = CircleStorage::new(&db_path, None).expect("open");
            storage
                .get_or_create_profile_relay_salt()
                .unwrap()
                .to_hex()
                .as_str()
                .to_owned()
        }; // dropped: the connection closes and any WAL is checkpointed.

        assert!(
            db_path.exists(),
            "the salt must have been persisted on disk"
        );
        // Exactly what `delete_circles_db_files` removes on logout.
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = if suffix.is_empty() {
                db_path.clone()
            } else {
                std::path::PathBuf::from(format!("{}{suffix}", db_path.display()))
            };
            let _ = std::fs::remove_file(path);
        }
        assert!(!db_path.exists());

        let storage = CircleStorage::new(&db_path, None).expect("reopen a fresh database");
        assert_eq!(
            stored_salt_hex(&storage),
            None,
            "the salt must not survive deletion of circles.db — if this fails, it \
             is being persisted somewhere the logout wipe does not reach, and the \
             next identity on this device inherits the previous one's relay \
             assignment"
        );
        let after = storage
            .get_or_create_profile_relay_salt()
            .unwrap()
            .to_hex()
            .as_str()
            .to_owned();
        assert_ne!(
            after, before,
            "a post-logout install must mint an independent salt"
        );
    }

    #[test]
    fn a_corrupt_salt_row_is_replaced_rather_than_bricking_the_plane() {
        let storage = CircleStorage::in_memory().unwrap();
        {
            let conn = storage.conn().lock().unwrap();
            conn.execute(
                "INSERT INTO user_settings (key, value) VALUES (?1, 'not-hex')",
                params![PROFILE_RELAY_SALT_KEY],
            )
            .unwrap();
        }
        let salt = storage
            .get_or_create_profile_relay_salt()
            .unwrap()
            .to_hex()
            .as_str()
            .to_owned();
        assert_eq!(salt.len(), 64);
        assert_eq!(
            stored_salt_hex(&storage).as_deref(),
            Some(salt.as_str()),
            "the unusable row is replaced in place"
        );
        // And it is stable from then on.
        assert_eq!(
            storage
                .get_or_create_profile_relay_salt()
                .unwrap()
                .to_hex()
                .as_str(),
            salt
        );
    }

    // ---- schema shape / migration ------------------------------------------

    #[test]
    fn contaminated_relays_table_has_no_circle_or_group_column() {
        // The contamination ledger is a FLAT URL SET on purpose: a per-circle
        // ledger would record which relays carry which group, i.e. exactly the
        // co-membership routing metadata the profile plane exists to avoid —
        // even locally.
        let storage = CircleStorage::in_memory().unwrap();
        let conn = storage.conn().lock().unwrap();
        let mut stmt = conn
            .prepare("PRAGMA table_info(contaminated_relays)")
            .unwrap();
        let cols: Vec<String> = stmt
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap();

        assert_eq!(
            cols,
            vec![
                "url".to_string(),
                "source".to_string(),
                "first_seen".to_string()
            ],
            "the ledger must stay exactly (url, source, first_seen)"
        );
        for col in &cols {
            let lower = col.to_ascii_lowercase();
            assert!(
                !lower.contains("circle") && !lower.contains("group") && !lower.contains("mls"),
                "contaminated_relays must not carry a circle/group column, found `{col}`"
            );
        }
    }

    #[test]
    fn profile_miss_columns_migration_preserves_existing_rows() {
        // `CREATE TABLE IF NOT EXISTS` does not alter an existing table, so the
        // columns arrive by ALTER. Dropping and recreating `profiles` instead
        // would blank every cached display name on upgrade and trigger a
        // refetch storm on first launch.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_profile(&known_profile("aa", "alice", 1_000, 5_000))
            .unwrap();

        // Rewind to a database written by a build that predates the columns.
        storage
            .downgrade_profiles_to_pre_miss_columns_for_test()
            .unwrap();
        let before = profile_columns(&storage);
        assert!(!before.contains(&"miss_count".to_string()));
        assert!(!before.contains(&"next_retry_at".to_string()));

        // Upgrade.
        storage.reinitialize_for_test().unwrap();

        let after = profile_columns(&storage);
        assert!(after.contains(&"miss_count".to_string()));
        assert!(after.contains(&"next_retry_at".to_string()));

        // Every pre-existing row survived, content intact...
        let got = storage.get_profile("aa").unwrap().expect("row survived");
        assert_eq!(got.metadata.name(), Some("alice"), "no cache blanking");
        assert_eq!(got.state, ProfileState::Known);
        assert_eq!(got.event_created_at, 1_000);
        assert_eq!(got.fetched_at, 5_000);

        // ...with the defaults that make it behave exactly as before: no
        // recorded miss, no pending backoff, so it is due purely on staleness.
        assert_eq!(miss_state(&storage, "aa"), Some((0, 0)));
        assert!(storage
            .profiles_due(&one("aa"), 5_899, 900)
            .unwrap()
            .is_empty());
        assert_eq!(
            storage.profiles_due(&one("aa"), 5_900, 900).unwrap(),
            vec![("aa".to_string(), 0)],
        );

        // Re-running schema init is a no-op (sentinel), not a duplicate-column
        // error.
        storage.reinitialize_for_test().unwrap();
        assert_eq!(miss_state(&storage, "aa"), Some((0, 0)));
    }

    #[test]
    fn upsert_if_newer_always_allows_unknown_to_known() {
        // An Unknown row (a recorded miss, event_created_at = 0) must be
        // superseded by any resolved Known — even one whose created_at is 0.
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .record_profile_misses(&["aa".to_string()], 5_000)
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
