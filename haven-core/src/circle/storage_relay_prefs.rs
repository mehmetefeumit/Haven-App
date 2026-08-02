//! Storage methods for user-configurable relay preferences.
//!
//! Extends [`CircleStorage`] with CRUD operations for the `user_relays`,
//! `user_settings`, and `published_events` tables defined in
//! [`CircleStorage::initialize_schema`]. These methods power Haven's
//! customizable relay list feature; see also [`crate::circle::relay_prefs`].
//!
//! # Privacy and security notes
//!
//! * URLs are normalized through [`nostr::RelayUrl::parse`] before insertion,
//!   so duplicate-with-trailing-slash inserts collide on the `UNIQUE
//!   (url, relay_type)` constraint instead of producing two rows.
//! * `ws://` is rejected at the storage boundary as defense-in-depth — the
//!   relay manager also rejects it, but storing one would surface in the UI.
//!   The sole exception is the debug-only hermetic-test path: a `ws://`
//!   loopback / emulator-host relay is accepted IFF the install-once
//!   [`crate::relay::allow_ws_loopback_for_test`] opt-in is armed (the same
//!   flag + host allowlist the relay manager consults). In release builds
//!   the opt-in is unreachable and every `ws://` is rejected unconditionally.
//! * URLs containing `user:pass@` are rejected to prevent credential leakage
//!   into logs, error messages, or relay-side observability.
//! * The seeding sentinels ([`SEEDED_KEY`], [`PROFILE_SEEDED_KEY`]) are
//!   checked by *presence*, not by the row count of `user_relays` — a user who
//!   legitimately removes a default relay must not have it re-added by the
//!   next defensive seed.
//! * Each category seeds from its OWN default pool
//!   ([`default_relays_for`]). The profile category must never be seeded from
//!   the account seed: those relays already carry the user's encrypted
//!   location traffic, and pointing profile lookups at them would collapse the
//!   two planes into one observer's view.

// Single-shot SQLite ops naturally hold the lock to completion; the parent
// module already disables this lint at the file level for storage.rs.
#![allow(clippy::significant_drop_tightening)]

use chrono::Utc;
use nostr::{EventId, PublicKey, RelayUrl};
use rusqlite::{params, OptionalExtension};

use super::error::{CircleError, Result};
use super::relay_prefs::RelayType;
use super::storage::CircleStorage;
use super::storage_contamination::record_relay_category_on;
use super::types::default_relays;

/// Sentinel key in `user_settings` that records whether seeding of the
/// **account-seed categories** ([`RelayType::Inbox`], [`RelayType::KeyPackage`])
/// has run.
///
/// The `_v1` suffix leaves room for a future "rotate the default set" pass
/// (`_v2` would be set after a one-shot upgrade-time re-seed if we ever
/// change the relay defaults returned by [`default_relays`]).
pub const SEEDED_KEY: &str = "relay_prefs_seeded_v1";

/// Sentinel key in `user_settings` that records whether the
/// [`RelayType::Profile`] category has been seeded.
///
/// # Why a second sentinel instead of bumping [`SEEDED_KEY`] to `_v2`
///
/// [`SEEDED_KEY`] is checked by presence, so every install that predates the
/// profile category already has it set — a single sentinel would skip profile
/// seeding forever for exactly the users who have never had profile relays.
///
/// The alternative, bumping to `_v2` with a one-shot upgrade, is strictly more
/// dangerous. The `_v2` path re-enters the seeding routine for an install whose
/// account-seed rows are already *user-edited*, so its correctness depends
/// entirely on the routine remembering to insert profile rows ONLY. Any later
/// maintainer who "simplifies" it back into one loop over every category
/// silently re-adds a default the user deliberately removed, and the
/// `seed_does_not_reapply_after_user_remove_and_restart` invariant dies quietly
/// — no compile error, no failing assertion on a fresh install.
///
/// Two independent, monotonic, presence-checked sentinels make each category
/// group's seed self-contained: a group is seeded at most once, ever, and an
/// upgrade cannot touch rows belonging to a group whose sentinel is already
/// set. That property holds structurally rather than by careful coding.
pub const PROFILE_SEEDED_KEY: &str = "relay_prefs_profile_seeded_v1";

/// `user_settings` key that toggles publishing of kind 10051.
pub const PUBLISH_KP_RELAY_LIST_KEY: &str = "publish_keypackage_relay_list";

/// `user_settings` key that toggles publishing of kind 10050.
pub const PUBLISH_INBOX_RELAY_LIST_KEY: &str = "publish_inbox_relay_list";

/// One row of the `user_relays` table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserRelayRow {
    /// Normalized relay URL (always `wss://` in production; a `ws://`
    /// loopback host may be stored only in debug builds with the
    /// [`crate::relay::allow_ws_loopback_for_test`] opt-in armed).
    pub url: String,
    /// Category this relay belongs to.
    pub relay_type: RelayType,
    /// Insertion timestamp (Unix seconds).
    pub created_at: i64,
}

/// One row of the `published_events` table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublishedEventRecord {
    /// Nostr event kind.
    pub kind: u16,
    /// `d` tag (empty for non-addressable replaceable events).
    pub d_tag: String,
    /// Event id (32 bytes).
    pub event_id: EventId,
    /// Author pubkey (32 bytes, x-only).
    pub pubkey: PublicKey,
    /// When the event was published (Unix seconds).
    pub published_at: i64,
}

/// Normalizes a user-supplied relay URL.
///
/// Performs the following steps:
///
/// 1. Trims surrounding whitespace.
/// 2. Rejects empty input with [`CircleError::InvalidData`].
/// 3. Rejects plaintext `ws://` (defense-in-depth — `nostr::RelayUrl` would
///    accept it but the relay manager rejects it at publish time). The
///    debug-only [`crate::relay::allow_ws_loopback_for_test`] opt-in relaxes
///    this for loopback / emulator hosts only; release builds always reject.
/// 4. Rejects URLs containing `user:pass@` to avoid credential leakage.
/// 5. Delegates to [`nostr::RelayUrl::parse`] for canonical handling of IDN,
///    case, ports, and trailing slashes on the root.
///
/// The returned string is the canonical form returned by `RelayUrl::parse`.
///
/// # Errors
///
/// Returns [`CircleError::InvalidData`] for any rejected input. The error
/// message is short and user-presentable; it never includes secret material.
pub fn normalize_url(input: &str) -> Result<String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err(CircleError::InvalidData(
            "Relay URL must not be empty".to_string(),
        ));
    }
    // Reject ws:// (case-insensitive) before parsing — RelayUrl::parse
    // accepts both schemes.
    //
    // The sole exception is the debug-only hermetic-test path: a `ws://`
    // loopback / emulator-host URL is accepted IFF the install-once
    // `allow_ws_loopback_for_test` opt-in is armed. This consults the SAME
    // flag and the SAME host allowlist that the relay manager's
    // `validate_relay_urls` uses at publish/connect time, so the storage
    // add path and the publish path relax `ws://` together, never
    // independently. In release builds `ws_loopback_allowed_for_test` is a
    // `const fn` returning `false`, so this collapses to the unconditional
    // rejection — byte-for-byte identical to production: no plaintext
    // `ws://` relay can ever be stored.
    let lower_prefix = trimmed
        .chars()
        .take(5)
        .collect::<String>()
        .to_ascii_lowercase();
    if lower_prefix.starts_with("ws://") && !crate::relay::ws_loopback_allowed_for_test(trimmed) {
        return Err(CircleError::InvalidData(
            "Use wss:// for security".to_string(),
        ));
    }
    if trimmed.contains('@') {
        // RelayUrl::parse accepts `user:pass@host` — reject up front so
        // credentials never reach storage, logs, or error messages.
        return Err(CircleError::InvalidData(
            "Relay URL must not contain credentials".to_string(),
        ));
    }
    // Defense in depth — lowercase the scheme + authority ourselves so
    // case-only differing URLs deduplicate on the UNIQUE (url, relay_type)
    // index. `nostr::RelayUrl::parse` does some canonicalization but does
    // not always lowercase the host on every nostr-sdk version, and may
    // preserve a trailing slash on the root path which would also defeat
    // the UNIQUE constraint.
    let canonical = RelayUrl::parse(trimmed)
        .map_err(|_| CircleError::InvalidData("Invalid relay URL".to_string()))?
        .to_string();
    // Delegate the final form to the SINGLE shared implementation. Relay URLs
    // are compared as set members both here (the `UNIQUE (url, relay_type)`
    // index) and in the profile plane's contamination exclusion; a second
    // normalizer that drifted from this one would let a contaminated relay
    // survive exclusion and start receiving profile traffic.
    Ok(crate::relay::url_norm::canonicalize(&canonical))
}

/// Returns the default relay pool for one category.
///
/// This dispatch is load-bearing for the profile/location plane separation, so
/// it is a single named function rather than an inline `default_relays()` call
/// repeated at each seed/restore/reset site:
///
/// * [`RelayType::Inbox`] and [`RelayType::KeyPackage`] — the account seed
///   ([`default_relays`]). These relays carry the user's gift-wrapped welcomes
///   and, through the circles built on them, their encrypted kind-445 location
///   traffic.
/// * [`RelayType::Profile`] — the curated profile pool
///   ([`crate::profile::profile_relay_pool_default`] — the EFFECTIVE set, so a
///   hermetic test override is honoured), which is
///   disjoint from the account seed AND the discovery plane by construction
///   (pinned by `tests/profile_plane_separation.rs`).
///
/// Seeding the profile category from [`default_relays`] would be the quiet
/// failure mode of this whole feature: the UI would show an editable "Profile
/// relays" list, the plane-separation code would run, and every profile query
/// would still go to the same three relays that see the user's location
/// traffic. The `match` is exhaustive so a new category cannot default into the
/// wrong pool by omission — it fails to compile instead.
#[must_use]
pub fn default_relays_for(relay_type: RelayType) -> Vec<String> {
    match relay_type {
        RelayType::Inbox | RelayType::KeyPackage => default_relays(),
        RelayType::Profile => crate::profile::profile_relay_pool_default(),
    }
}

impl CircleStorage {
    /// Seeds default relays on first launch, per category group.
    ///
    /// Two independent sentinel keys gate two independent groups:
    ///
    /// * [`SEEDED_KEY`] gates [`RelayType::Inbox`] + [`RelayType::KeyPackage`],
    ///   seeded from the account seed.
    /// * [`PROFILE_SEEDED_KEY`] gates [`RelayType::Profile`], seeded from the
    ///   curated profile pool.
    ///
    /// Splitting them is what lets an install that predates the profile
    /// category still receive profile relays on upgrade: its [`SEEDED_KEY`] is
    /// already set, but [`PROFILE_SEEDED_KEY`] is not. See that constant's docs
    /// for why this is preferred over a `_v2` sentinel bump.
    ///
    /// Idempotent per group: subsequent calls observe the sentinels and
    /// short-circuit. Crucially, the sentinels are the signal — never row
    /// presence in `user_relays`. A user who removes a default relay must not
    /// have it re-added by the next defensive seed, in ANY category.
    ///
    /// All inserts and both sentinel writes happen in a single transaction so
    /// a partial failure cannot leave the user "half seeded."
    ///
    /// # Returns
    ///
    /// `true` if seeding wrote rows for at least one group on this call;
    /// `false` if both sentinels were already set.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Storage`] if the lock cannot be acquired and
    /// [`CircleError::Database`] for `SQLite` errors.
    pub fn seed_defaults_if_unseeded(&self) -> Result<bool> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        let account_seeded = conn
            .query_row(
                "SELECT value FROM user_settings WHERE key = ?1",
                params![SEEDED_KEY],
                |r| r.get::<_, String>(0),
            )
            .optional()?
            .is_some();
        let profile_seeded = conn
            .query_row(
                "SELECT value FROM user_settings WHERE key = ?1",
                params![PROFILE_SEEDED_KEY],
                |r| r.get::<_, String>(0),
            )
            .optional()?
            .is_some();
        if account_seeded && profile_seeded {
            return Ok(false);
        }

        let now = Utc::now().timestamp();
        let tx = conn.transaction()?;
        // Use INSERT OR IGNORE throughout so a partially-completed prior
        // attempt (where a sentinel never made it but rows did) doesn't error.
        if !account_seeded {
            let inbox = default_relays_for(RelayType::Inbox);
            for relay in &inbox {
                tx.execute(
                    "INSERT OR IGNORE INTO user_relays (url, relay_type, created_at) VALUES (?1, ?2, ?3)",
                    params![relay, RelayType::Inbox.as_str(), now],
                )?;
            }
            let key_package = default_relays_for(RelayType::KeyPackage);
            for relay in &key_package {
                tx.execute(
                    "INSERT OR IGNORE INTO user_relays (url, relay_type, created_at) VALUES (?1, ?2, ?3)",
                    params![relay, RelayType::KeyPackage.as_str(), now],
                )?;
            }
            // Contamination ledger (append-only): seeding an account-seed
            // category IS the moment those relays are committed to carrying this
            // account's gift wraps and KeyPackages, so they are permanently
            // excluded from the profile pool from here on. Recorded inside the
            // SAME transaction as the rows themselves, so the ledger can never
            // lag the configuration it describes.
            record_relay_category_on(&tx, &inbox, RelayType::Inbox, now)?;
            record_relay_category_on(&tx, &key_package, RelayType::KeyPackage, now)?;
            tx.execute(
                "INSERT OR IGNORE INTO user_settings (key, value) VALUES (?1, '1')",
                params![SEEDED_KEY],
            )?;
        }
        if !profile_seeded {
            // Profile rows ONLY. This branch runs on upgrade for installs whose
            // account-seed rows are already user-edited; touching them here
            // would resurrect relays the user deliberately removed.
            //
            // And deliberately NO contamination record: this category IS the
            // profile pool. `ContaminationSource::for_relay_type` gives a caller
            // no source value for it, so the omission is structural rather than
            // a rule someone has to remember here.
            for relay in default_relays_for(RelayType::Profile) {
                tx.execute(
                    "INSERT OR IGNORE INTO user_relays (url, relay_type, created_at) VALUES (?1, ?2, ?3)",
                    params![relay, RelayType::Profile.as_str(), now],
                )?;
            }
            tx.execute(
                "INSERT OR IGNORE INTO user_settings (key, value) VALUES (?1, '1')",
                params![PROFILE_SEEDED_KEY],
            )?;
        }
        tx.commit()?;
        Ok(true)
    }

    /// Returns the user's relays for one category, ordered by insertion time.
    ///
    /// # Errors
    ///
    /// Returns a database error if the lookup fails.
    pub fn list_user_relays(&self, relay_type: RelayType) -> Result<Vec<String>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let mut stmt = conn.prepare(
            "SELECT url FROM user_relays WHERE relay_type = ?1 ORDER BY created_at ASC, id ASC",
        )?;
        let rows = stmt
            .query_map(params![relay_type.as_str()], |row| row.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Adds a relay to one category.
    ///
    /// Normalizes the URL via [`normalize_url`] and uses `INSERT OR IGNORE`
    /// so a duplicate add is a silent no-op. URLs that fail normalization
    /// surface as [`CircleError::InvalidData`].
    ///
    /// # Contamination
    ///
    /// Adding an [`RelayType::Inbox`] or [`RelayType::KeyPackage`] relay hands
    /// it this account's location-plane traffic, so the same transaction appends
    /// it to the contamination ledger and it is excluded from the profile pool
    /// forever after. [`RelayType::Profile`] adds are NOT recorded — that
    /// category is the pool itself.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::InvalidData`] for invalid URLs and database
    /// errors otherwise.
    pub fn add_user_relay(&self, url: &str, relay_type: RelayType) -> Result<()> {
        let normalized = normalize_url(url)?;
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let now = Utc::now().timestamp();
        // One transaction: the relay row and its ledger entry land together, so
        // no crash window can leave a configured location-plane relay that the
        // profile pool still considers clean.
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT OR IGNORE INTO user_relays (url, relay_type, created_at) VALUES (?1, ?2, ?3)",
            params![normalized, relay_type.as_str(), now],
        )?;
        record_relay_category_on(&tx, std::slice::from_ref(&normalized), relay_type, now)?;
        tx.commit()?;
        Ok(())
    }

    /// Removes a relay from one category.
    ///
    /// Refuses to delete the last remaining relay for a category, returning
    /// [`CircleError::InvalidData`] in that case so the caller can surface
    /// a friendly UI message. The check and delete happen inside a single
    /// transaction so a concurrent insert cannot create a TOCTOU window.
    ///
    /// # Returns
    ///
    /// `true` when a row was removed; `false` if no row matched.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::InvalidData`] when the URL is invalid or the
    /// removal would leave the category empty. Returns a database error
    /// otherwise.
    pub fn remove_user_relay(&self, url: &str, relay_type: RelayType) -> Result<bool> {
        let normalized = normalize_url(url)?;
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let tx = conn.transaction()?;
        let count: i64 = tx.query_row(
            "SELECT COUNT(*) FROM user_relays WHERE relay_type = ?1",
            params![relay_type.as_str()],
            |r| r.get(0),
        )?;
        if count <= 1 {
            // Tx auto-rolls back on drop.
            return Err(CircleError::InvalidData(
                "At least one relay is required per category".to_string(),
            ));
        }
        let removed = tx.execute(
            "DELETE FROM user_relays WHERE url = ?1 AND relay_type = ?2",
            params![normalized, relay_type.as_str()],
        )?;
        tx.commit()?;
        Ok(removed > 0)
    }

    /// Restores defaults for a category **non-destructively**.
    ///
    /// Adds any missing default relays — from THIS category's pool, per
    /// [`default_relays_for`] — via `INSERT OR IGNORE`. Existing user-added
    /// custom relays are preserved. Use [`Self::wipe_and_reset_defaults_for`]
    /// for the destructive variant (always behind a UI confirmation dialog).
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn restore_defaults_for(&self, relay_type: RelayType) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let now = Utc::now().timestamp();
        let tx = conn.transaction()?;
        let defaults = default_relays_for(relay_type);
        for relay in &defaults {
            tx.execute(
                "INSERT OR IGNORE INTO user_relays (url, relay_type, created_at) VALUES (?1, ?2, ?3)",
                params![relay, relay_type.as_str(), now],
            )?;
        }
        // Same transaction, same reasoning as `add_user_relay`; a structural
        // no-op for `RelayType::Profile`.
        record_relay_category_on(&tx, &defaults, relay_type, now)?;
        tx.commit()?;
        Ok(())
    }

    /// Destructively resets a category to exactly its own default relay list,
    /// as returned by [`default_relays_for`].
    ///
    /// Wipes all rows for the category and re-inserts that category's defaults
    /// in one transaction. The caller MUST gate this behind a confirmation
    /// dialog; the function name is deliberately verbose to prevent accidental
    /// use.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn wipe_and_reset_defaults_for(&self, relay_type: RelayType) -> Result<()> {
        let mut conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let now = Utc::now().timestamp();
        let tx = conn.transaction()?;
        tx.execute(
            "DELETE FROM user_relays WHERE relay_type = ?1",
            params![relay_type.as_str()],
        )?;
        // `OR IGNORE` (rather than a bare INSERT) so a pool that ever contains
        // two spellings collapsing to one canonical URL cannot abort the reset
        // and leave the category empty — the DELETE has already run.
        let defaults = default_relays_for(relay_type);
        for relay in &defaults {
            tx.execute(
                "INSERT OR IGNORE INTO user_relays (url, relay_type, created_at) VALUES (?1, ?2, ?3)",
                params![relay, relay_type.as_str(), now],
            )?;
        }
        // The DELETE above removes CONFIGURATION, never contamination: the
        // relays it drops have already carried this account's traffic, and the
        // ledger keeps their rows (append-only). The re-inserted defaults are
        // recorded here for the same reason as every other write site.
        record_relay_category_on(&tx, &defaults, relay_type, now)?;
        tx.commit()?;
        Ok(())
    }

    /// Returns whether this user wants to publish kind 10051.
    ///
    /// Defaults to `true` (publish) when the setting has never been written.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn get_publish_kp_relay_list(&self) -> Result<bool> {
        self.get_bool_setting(PUBLISH_KP_RELAY_LIST_KEY)
    }

    /// Sets whether this user wants to publish kind 10051.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn set_publish_kp_relay_list(&self, value: bool) -> Result<()> {
        self.set_bool_setting(PUBLISH_KP_RELAY_LIST_KEY, value)
    }

    /// Returns whether this user wants to publish kind 10050.
    ///
    /// Defaults to `true` (publish) when the setting has never been written.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn get_publish_inbox_relay_list(&self) -> Result<bool> {
        self.get_bool_setting(PUBLISH_INBOX_RELAY_LIST_KEY)
    }

    /// Sets whether this user wants to publish kind 10050.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn set_publish_inbox_relay_list(&self, value: bool) -> Result<()> {
        self.set_bool_setting(PUBLISH_INBOX_RELAY_LIST_KEY, value)
    }

    /// Records a published replaceable event for later NIP-09 deletion.
    ///
    /// Overwrites any prior record for the same `(kind, d_tag, pubkey)`
    /// triple — only the most recent publication is tracked.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure.
    pub fn record_published_event(
        &self,
        kind: u16,
        d_tag: &str,
        event_id: &EventId,
        pubkey: &PublicKey,
        published_at: i64,
    ) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        // Bind bytes explicitly so they live for the params! lifetime.
        let event_id_bytes: &[u8] = event_id.as_bytes();
        let pubkey_bytes = pubkey.to_bytes();
        let pubkey_slice: &[u8] = &pubkey_bytes;
        // The `WHERE excluded.published_at >= published_events.published_at`
        // guard prevents an out-of-order publish callback from clobbering
        // a newer record. Without it, a delayed acknowledgement for an
        // older publish would overwrite the more-recent event_id and
        // cause a future NIP-09 deletion to reference the older event,
        // leaving the newer one unretracted on cooperative relays.
        conn.execute(
            "INSERT INTO published_events (kind, d_tag, event_id, pubkey, published_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(kind, d_tag, pubkey) DO UPDATE SET
                event_id = excluded.event_id,
                published_at = excluded.published_at
             WHERE excluded.published_at >= published_events.published_at",
            params![
                i64::from(kind),
                d_tag,
                event_id_bytes,
                pubkey_slice,
                published_at,
            ],
        )?;
        Ok(())
    }

    /// Looks up the last published event id for a `(kind, d_tag, pubkey)` triple.
    ///
    /// # Errors
    ///
    /// Returns a database error on failure. A missing row is `Ok(None)`.
    pub fn last_published_event(
        &self,
        kind: u16,
        d_tag: &str,
        pubkey: &PublicKey,
    ) -> Result<Option<PublishedEventRecord>> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let pubkey_bytes = pubkey.to_bytes();
        let pubkey_slice: &[u8] = &pubkey_bytes;
        let row = conn
            .query_row(
                "SELECT event_id, published_at FROM published_events
                 WHERE kind = ?1 AND d_tag = ?2 AND pubkey = ?3",
                params![i64::from(kind), d_tag, pubkey_slice],
                |r| {
                    let event_id: Vec<u8> = r.get(0)?;
                    let published_at: i64 = r.get(1)?;
                    Ok((event_id, published_at))
                },
            )
            .optional()?;
        match row {
            None => Ok(None),
            Some((event_id_bytes, published_at)) => {
                let event_id = EventId::from_slice(&event_id_bytes).map_err(|_| {
                    CircleError::InvalidData("stored event_id has wrong length".to_string())
                })?;
                Ok(Some(PublishedEventRecord {
                    kind,
                    d_tag: d_tag.to_string(),
                    event_id,
                    pubkey: *pubkey,
                    published_at,
                }))
            }
        }
    }

    /// Reads a boolean setting; defaults to `true` when missing.
    fn get_bool_setting(&self, key: &str) -> Result<bool> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let raw: Option<String> = conn
            .query_row(
                "SELECT value FROM user_settings WHERE key = ?1",
                params![key],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        Ok(raw.as_deref().is_none_or(|v| v == "true"))
    }

    /// Writes a boolean setting.
    fn set_bool_setting(&self, key: &str, value: bool) -> Result<()> {
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let v = if value { "true" } else { "false" };
        conn.execute(
            "INSERT INTO user_settings (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, v],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_storage() -> CircleStorage {
        CircleStorage::in_memory().expect("in-memory storage must initialize")
    }

    /// The curated profile pool, as the seeder would insert it.
    ///
    /// Deliberately the shipped CONSTANT, even though the seeder itself calls
    /// the effective accessor ([`crate::profile::profile_relay_pool_default`]).
    /// The two agree unconditionally in this binary because NO lib unit test
    /// installs the debug pool override — that install lives only in the
    /// `tests/profile_relay_override_*.rs` integration binaries, each of which
    /// gets its own process (see the NOTE in `profile::relay_pool`'s test
    /// module; CI-enforced by `check_profile_privacy_boundaries.sh` Check 12).
    ///
    /// Do NOT "fix" a failure here by switching to the effective accessor: that
    /// would make `profile_category_seeds_from_the_profile_pool_not_the_account_seed`
    /// compare the seeded rows against whatever was seeded from, i.e. assert
    /// nothing at all — while still passing, and while the profile plane could
    /// be seeding from the account-seed relays. A red assertion here means
    /// something installed an override in the lib binary; remove that instead.
    fn profile_pool() -> Vec<String> {
        crate::profile::relay_pool::production_profile_relays()
    }

    /// Asserts no entry of `rows` is an account-seed relay.
    ///
    /// Checks both the runtime seed ([`default_relays`], which a debug E2E
    /// override can redirect) and the compiled-in production list, so the
    /// assertion is meaningful whichever one a given process is using.
    fn assert_no_account_seed_relay(rows: &[String]) {
        for seed in default_relays() {
            assert!(
                !rows.contains(&seed),
                "account-seed relay {seed} leaked into the profile plane: {rows:?}"
            );
        }
        for seed in crate::circle::PRODUCTION_DEFAULT_RELAYS {
            assert!(
                !rows.iter().any(|u| u == seed),
                "production account-seed relay {seed} leaked into the profile plane: {rows:?}"
            );
        }
    }

    #[test]
    fn normalize_strips_trailing_slash_on_root() {
        let out = normalize_url("wss://relay.example.com/").expect("must parse");
        // RelayUrl::parse canonicalizes the trailing slash.
        assert!(out.starts_with("wss://relay.example.com"));
        assert!(!out.ends_with("//"));
    }

    #[test]
    fn normalize_lowercases_scheme_and_host() {
        let out = normalize_url("WSS://Relay.Example.com").expect("must parse");
        assert!(out.starts_with("wss://relay.example.com"));
    }

    #[test]
    fn normalize_rejects_ws_scheme() {
        let err = normalize_url("ws://relay.example.com").unwrap_err();
        match err {
            CircleError::InvalidData(msg) => assert!(msg.to_lowercase().contains("wss")),
            other => panic!("expected InvalidData, got {other:?}"),
        }
    }

    #[test]
    fn normalize_ws_loopback_accepts_when_optin_armed() {
        // Proves the seam wiring: `normalize_url` consults the SAME
        // install-once opt-in + host allowlist as the relay manager's
        // publish-time validator (`crate::relay::ws_loopback_allowed_for_test`).
        //
        // We arm the opt-in here (idempotent `let _ =`; the same global flag
        // a sibling manager test already arms unconditionally, so the rest of
        // the lib-test binary is robust to it). Arming first makes this test
        // race-free: the flag is monotonic (unset -> set, never set -> unset),
        // so once armed, `normalize_url` of a loopback host is deterministically
        // accepted. The flag-unset rejection posture is covered robustly by
        // `normalize_rejects_ws_nonloopback_even_with_optin` (a non-loopback
        // host is rejected regardless of flag state).
        let _ = crate::relay::allow_ws_loopback_for_test();
        let url = "ws://10.0.2.2:7778";
        assert!(
            crate::relay::ws_loopback_allowed_for_test(url),
            "opt-in must be armed for this assertion"
        );
        let out = normalize_url(url).expect("armed opt-in must accept ws:// loopback");
        assert_eq!(
            out, url,
            "loopback ws:// must round-trip verbatim (no trailing slash)"
        );
    }

    #[test]
    fn normalize_rejects_ws_nonloopback_even_with_optin() {
        // A non-loopback ws:// host is rejected regardless of the opt-in: the
        // host allowlist is AND-ed with the flag, so the seam never relaxes
        // ws:// for arbitrary hosts. Robust to flag state.
        for url in ["ws://relay.example.com", "ws://192.168.1.10:7777"] {
            match normalize_url(url) {
                Err(CircleError::InvalidData(msg)) => assert!(msg.to_lowercase().contains("wss")),
                other => {
                    panic!("non-loopback ws:// {url} must always be rejected, got {other:?}")
                }
            }
        }
    }

    #[test]
    fn normalize_rejects_credentials() {
        let err = normalize_url("wss://user:pass@relay.example.com").unwrap_err();
        match err {
            CircleError::InvalidData(msg) => assert!(msg.to_lowercase().contains("credential")),
            other => panic!("expected InvalidData, got {other:?}"),
        }
    }

    #[test]
    fn normalize_rejects_empty() {
        assert!(matches!(
            normalize_url(""),
            Err(CircleError::InvalidData(_))
        ));
        assert!(matches!(
            normalize_url("   "),
            Err(CircleError::InvalidData(_))
        ));
    }

    #[test]
    fn normalize_rejects_malformed() {
        assert!(matches!(
            normalize_url("not-a-url"),
            Err(CircleError::InvalidData(_))
        ));
    }

    #[test]
    fn normalize_accepts_port_and_path() {
        let out = normalize_url("wss://relay.example.com:7777/v1").expect("must parse");
        assert!(out.contains("relay.example.com"));
        assert!(out.contains("7777"));
    }

    #[test]
    fn seed_defaults_runs_once() {
        let storage = make_storage();
        assert!(storage.seed_defaults_if_unseeded().unwrap());
        // Second call — sentinels set, no-op.
        assert!(!storage.seed_defaults_if_unseeded().unwrap());
        // Both account categories populated with the production defaults.
        let inbox = storage.list_user_relays(RelayType::Inbox).unwrap();
        let kp = storage.list_user_relays(RelayType::KeyPackage).unwrap();
        assert_eq!(inbox.len(), crate::circle::PRODUCTION_DEFAULT_RELAYS.len());
        assert_eq!(kp.len(), crate::circle::PRODUCTION_DEFAULT_RELAYS.len());
        // ...and the profile category from its own, separate pool.
        let profile = storage.list_user_relays(RelayType::Profile).unwrap();
        assert_eq!(profile, profile_pool());
    }

    #[test]
    fn default_relays_for_dispatches_per_category() {
        // The dispatch itself, independent of storage: the account categories
        // share the account seed, the profile category does not draw from it
        // at all. `default_relays_for(Profile)` resolves through the EFFECTIVE
        // accessor, so comparing it to the shipped constant is sound only
        // because no lib test installs the pool override — see `profile_pool`.
        assert_eq!(default_relays_for(RelayType::Inbox), default_relays());
        assert_eq!(default_relays_for(RelayType::KeyPackage), default_relays());

        let profile = default_relays_for(RelayType::Profile);
        assert_eq!(profile, profile_pool());
        assert!(!profile.is_empty(), "profile pool must not be empty");
        assert_no_account_seed_relay(&profile);
    }

    #[test]
    fn profile_category_seeds_from_the_profile_pool_not_the_account_seed() {
        // THE trap this feature can ship with: seeding the profile category
        // from `default_relays()` produces an editable "Profile relays" list
        // pre-filled with the exact relays already carrying this user's
        // encrypted kind-445 traffic. Everything would look correct and the
        // plane separation would be worth nothing.
        let storage = make_storage();
        assert!(storage.seed_defaults_if_unseeded().unwrap());

        let profile = storage.list_user_relays(RelayType::Profile).unwrap();
        assert_eq!(
            profile,
            profile_pool(),
            "profile category must seed from the curated profile pool"
        );
        assert_no_account_seed_relay(&profile);

        // Symmetrically: no profile-pool relay may end up on the location
        // plane through seeding.
        for account_category in [RelayType::Inbox, RelayType::KeyPackage] {
            let rows = storage.list_user_relays(account_category).unwrap();
            for pool_relay in profile_pool() {
                assert!(
                    !rows.contains(&pool_relay),
                    "profile-pool relay {pool_relay} was seeded onto {}",
                    account_category.as_str()
                );
            }
        }
    }

    #[test]
    fn restore_defaults_for_profile_uses_the_profile_pool() {
        let storage = make_storage();
        storage.seed_defaults_if_unseeded().unwrap();
        // Remove one pool entry, then restore.
        let removed = profile_pool()[0].clone();
        assert!(storage
            .remove_user_relay(&removed, RelayType::Profile)
            .unwrap());
        assert!(!storage
            .list_user_relays(RelayType::Profile)
            .unwrap()
            .contains(&removed));

        storage.restore_defaults_for(RelayType::Profile).unwrap();
        let profile = storage.list_user_relays(RelayType::Profile).unwrap();
        for entry in profile_pool() {
            assert!(
                profile.contains(&entry),
                "restore must re-add missing profile default {entry}"
            );
        }
        // `restore_defaults_for` ignored its parameter before this change and
        // always used the account seed — that would show up right here.
        assert_no_account_seed_relay(&profile);
    }

    #[test]
    fn wipe_and_reset_defaults_for_profile_uses_the_profile_pool() {
        let storage = make_storage();
        storage
            .add_user_relay("wss://custom-profile.example.com", RelayType::Profile)
            .unwrap();
        storage
            .wipe_and_reset_defaults_for(RelayType::Profile)
            .unwrap();
        let profile = storage.list_user_relays(RelayType::Profile).unwrap();
        assert_eq!(profile, profile_pool());
        assert_no_account_seed_relay(&profile);
    }

    #[test]
    fn existing_install_still_seeds_profile_relays_on_upgrade() {
        // An install predating the profile category already has SEEDED_KEY set
        // by presence. With a single sentinel it would never receive profile
        // relays — the category would ship empty for every existing user.
        let storage = make_storage();
        storage.set_bool_setting(SEEDED_KEY, true).unwrap();
        // Simulate the account rows that install already has, including a
        // user-added custom relay and WITHOUT one default the user removed.
        storage
            .add_user_relay(
                crate::circle::PRODUCTION_DEFAULT_RELAYS[1],
                RelayType::Inbox,
            )
            .unwrap();
        storage
            .add_user_relay("wss://user-added.example.com", RelayType::Inbox)
            .unwrap();
        assert!(storage
            .list_user_relays(RelayType::Profile)
            .unwrap()
            .is_empty());

        // Upgrade-time seed: profile rows appear...
        assert!(
            storage.seed_defaults_if_unseeded().unwrap(),
            "upgrade must report that it wrote rows"
        );
        let profile = storage.list_user_relays(RelayType::Profile).unwrap();
        assert_eq!(profile, profile_pool());

        // ...and the already-seeded account category is left exactly as the
        // user left it. Re-adding PRODUCTION_DEFAULT_RELAYS[0] here would be
        // the `_v2`-bump failure mode.
        let inbox = storage.list_user_relays(RelayType::Inbox).unwrap();
        assert_eq!(
            inbox,
            vec![
                crate::circle::PRODUCTION_DEFAULT_RELAYS[1].to_string(),
                "wss://user-added.example.com".to_string(),
            ],
            "upgrade seeding must not touch the account categories"
        );

        // And the upgrade is itself once-only.
        assert!(!storage.seed_defaults_if_unseeded().unwrap());
    }

    #[test]
    fn seeding_is_idempotent_across_all_three_categories() {
        let storage = make_storage();
        assert!(storage.seed_defaults_if_unseeded().unwrap());
        let snapshot: Vec<Vec<String>> =
            [RelayType::Inbox, RelayType::KeyPackage, RelayType::Profile]
                .iter()
                .map(|t| storage.list_user_relays(*t).unwrap())
                .collect();

        for _ in 0..3 {
            assert!(
                !storage.seed_defaults_if_unseeded().unwrap(),
                "repeat seeding must be a no-op once both sentinels are set"
            );
        }

        let after: Vec<Vec<String>> = [RelayType::Inbox, RelayType::KeyPackage, RelayType::Profile]
            .iter()
            .map(|t| storage.list_user_relays(*t).unwrap())
            .collect();
        assert_eq!(snapshot, after, "repeat seeding changed stored rows");
        // Each category is non-empty and holds no duplicates.
        for rows in &after {
            assert!(!rows.is_empty());
            let unique: std::collections::HashSet<&String> = rows.iter().collect();
            assert_eq!(unique.len(), rows.len(), "duplicate row after re-seeding");
        }
    }

    #[test]
    fn seed_does_not_reapply_after_user_removes_a_profile_default() {
        // The sentinel invariant, extended to the new category: a profile relay
        // the user deliberately removed must stay removed. This matters more
        // here than for the account categories — a resurrected profile relay is
        // one the user may have dropped precisely because they learned it also
        // sees their location traffic.
        let storage = make_storage();
        storage.seed_defaults_if_unseeded().unwrap();
        let removed = profile_pool()[0].clone();
        assert!(storage
            .remove_user_relay(&removed, RelayType::Profile)
            .unwrap());

        // Assert the ROWS before the return value: the stored state is the
        // invariant that matters, and asserting the bool first would let a
        // resurrection regression be reported only as a wrong return code.
        let reseeded = storage.seed_defaults_if_unseeded().unwrap();
        let profile = storage.list_user_relays(RelayType::Profile).unwrap();
        assert!(
            !profile.contains(&removed),
            "defensive seed resurrected a user-removed profile relay"
        );
        assert_eq!(profile.len(), profile_pool().len() - 1);
        assert!(!reseeded, "a fully-seeded install must report no work done");
    }

    #[test]
    fn profile_rows_are_stored_under_their_own_slug() {
        // Categories share one table; a slug collision would merge the profile
        // plane into an account category.
        let storage = make_storage();
        storage
            .add_user_relay("wss://profile-only.example.com", RelayType::Profile)
            .unwrap();
        for other in [RelayType::Inbox, RelayType::KeyPackage] {
            assert!(
                !storage
                    .list_user_relays(other)
                    .unwrap()
                    .iter()
                    .any(|u| u.contains("profile-only.example.com")),
                "profile row surfaced under {}",
                other.as_str()
            );
        }
        assert_eq!(
            storage.list_user_relays(RelayType::Profile).unwrap(),
            vec!["wss://profile-only.example.com".to_string()]
        );
    }

    #[test]
    fn seed_does_not_reapply_after_user_remove_and_restart() {
        // Regression: the sentinel is the signal, not row presence.
        let storage = make_storage();
        storage.seed_defaults_if_unseeded().unwrap();
        // User removes ONE default but keeps two — remove_user_relay refuses
        // to leave the category empty. Removing one is fine because two
        // others remain.
        storage
            .remove_user_relay(
                crate::circle::PRODUCTION_DEFAULT_RELAYS[0],
                RelayType::Inbox,
            )
            .unwrap();
        let after_remove = storage.list_user_relays(RelayType::Inbox).unwrap();
        assert_eq!(
            after_remove.len(),
            crate::circle::PRODUCTION_DEFAULT_RELAYS.len() - 1
        );
        // Defensive seed call must NOT re-add the removed default.
        assert!(!storage.seed_defaults_if_unseeded().unwrap());
        let after_seed = storage.list_user_relays(RelayType::Inbox).unwrap();
        assert_eq!(
            after_seed.len(),
            crate::circle::PRODUCTION_DEFAULT_RELAYS.len() - 1
        );
    }

    #[test]
    fn add_user_relay_is_idempotent() {
        let storage = make_storage();
        storage
            .add_user_relay("wss://custom.example.com", RelayType::Inbox)
            .unwrap();
        storage
            .add_user_relay("wss://custom.example.com", RelayType::Inbox)
            .unwrap();
        let list = storage.list_user_relays(RelayType::Inbox).unwrap();
        assert_eq!(
            list.iter()
                .filter(|u| u.contains("custom.example.com"))
                .count(),
            1,
            "duplicate add must not create duplicate row"
        );
    }

    #[test]
    fn add_user_relay_normalizes_before_insert() {
        let storage = make_storage();
        storage
            .add_user_relay("WSS://Custom.Example.com/", RelayType::Inbox)
            .unwrap();
        // Adding the lowercase canonical form must collide on UNIQUE.
        storage
            .add_user_relay("wss://custom.example.com", RelayType::Inbox)
            .unwrap();
        let list = storage.list_user_relays(RelayType::Inbox).unwrap();
        let matches: Vec<_> = list
            .iter()
            .filter(|u| u.contains("custom.example.com"))
            .collect();
        assert_eq!(matches.len(), 1, "case-only differing URLs must collide");
    }

    #[test]
    fn add_user_relay_rejects_invalid() {
        let storage = make_storage();
        let err = storage
            .add_user_relay("ws://insecure.example.com", RelayType::Inbox)
            .unwrap_err();
        assert!(matches!(err, CircleError::InvalidData(_)));
    }

    #[test]
    fn remove_user_relay_returns_false_on_missing() {
        let storage = make_storage();
        storage
            .add_user_relay("wss://a.example.com", RelayType::Inbox)
            .unwrap();
        storage
            .add_user_relay("wss://b.example.com", RelayType::Inbox)
            .unwrap();
        let removed = storage
            .remove_user_relay("wss://nonexistent.example.com", RelayType::Inbox)
            .unwrap();
        assert!(!removed);
    }

    #[test]
    fn remove_user_relay_blocks_last_in_category() {
        let storage = make_storage();
        storage
            .add_user_relay("wss://only.example.com", RelayType::Inbox)
            .unwrap();
        let err = storage
            .remove_user_relay("wss://only.example.com", RelayType::Inbox)
            .unwrap_err();
        match err {
            CircleError::InvalidData(msg) => {
                assert!(msg.to_lowercase().contains("at least one relay"));
            }
            other => panic!("expected InvalidData, got {other:?}"),
        }
        // Row must still exist.
        let list = storage.list_user_relays(RelayType::Inbox).unwrap();
        assert_eq!(list.len(), 1);
    }

    #[test]
    fn restore_defaults_for_is_non_destructive() {
        let storage = make_storage();
        storage.seed_defaults_if_unseeded().unwrap();
        // Add a custom relay.
        storage
            .add_user_relay("wss://custom.example.com", RelayType::Inbox)
            .unwrap();
        // Remove one default to verify restore re-adds it.
        storage
            .remove_user_relay(
                crate::circle::PRODUCTION_DEFAULT_RELAYS[0],
                RelayType::Inbox,
            )
            .unwrap();
        // Restore.
        storage.restore_defaults_for(RelayType::Inbox).unwrap();
        let list = storage.list_user_relays(RelayType::Inbox).unwrap();
        // Both defaults AND the custom must be present.
        assert!(list.iter().any(|u| u.contains("custom.example.com")));
        for default in crate::circle::PRODUCTION_DEFAULT_RELAYS {
            assert!(
                list.iter().any(|u| u.starts_with(default)),
                "restore must re-add missing default {default}"
            );
        }
    }

    #[test]
    fn restore_defaults_for_does_not_touch_other_category() {
        let storage = make_storage();
        storage
            .add_user_relay("wss://kp-only.example.com", RelayType::KeyPackage)
            .unwrap();
        storage.restore_defaults_for(RelayType::Inbox).unwrap();
        let kp = storage.list_user_relays(RelayType::KeyPackage).unwrap();
        assert!(
            kp.iter().any(|u| u.contains("kp-only.example.com")),
            "restore on Inbox must not touch KeyPackage rows"
        );
    }

    #[test]
    fn wipe_and_reset_is_destructive() {
        let storage = make_storage();
        storage
            .add_user_relay("wss://custom.example.com", RelayType::Inbox)
            .unwrap();
        storage
            .add_user_relay("wss://custom2.example.com", RelayType::Inbox)
            .unwrap();
        storage
            .wipe_and_reset_defaults_for(RelayType::Inbox)
            .unwrap();
        let list = storage.list_user_relays(RelayType::Inbox).unwrap();
        // Custom must be gone; defaults present.
        assert!(!list.iter().any(|u| u.contains("custom.example.com")));
        for default in crate::circle::PRODUCTION_DEFAULT_RELAYS {
            assert!(list.iter().any(|u| u.starts_with(default)));
        }
    }

    #[test]
    fn publish_toggles_default_true() {
        let storage = make_storage();
        assert!(storage.get_publish_kp_relay_list().unwrap());
        assert!(storage.get_publish_inbox_relay_list().unwrap());
    }

    #[test]
    fn publish_toggles_round_trip_both_values() {
        let storage = make_storage();
        storage.set_publish_kp_relay_list(false).unwrap();
        assert!(!storage.get_publish_kp_relay_list().unwrap());
        storage.set_publish_kp_relay_list(true).unwrap();
        assert!(storage.get_publish_kp_relay_list().unwrap());

        storage.set_publish_inbox_relay_list(false).unwrap();
        assert!(!storage.get_publish_inbox_relay_list().unwrap());
        storage.set_publish_inbox_relay_list(true).unwrap();
        assert!(storage.get_publish_inbox_relay_list().unwrap());
    }

    #[test]
    fn published_event_round_trip() {
        use nostr::Keys;
        let storage = make_storage();
        let keys = Keys::generate();
        let event = nostr::EventBuilder::new(nostr::Kind::InboxRelays, "")
            .sign_with_keys(&keys)
            .unwrap();
        storage
            .record_published_event(10050, "", &event.id, &keys.public_key(), 1_000)
            .unwrap();
        let got = storage
            .last_published_event(10050, "", &keys.public_key())
            .unwrap()
            .expect("row must exist");
        assert_eq!(got.event_id, event.id);
        assert_eq!(got.published_at, 1_000);

        // Re-record with newer timestamp must overwrite, not duplicate.
        let event2 = nostr::EventBuilder::new(nostr::Kind::InboxRelays, "")
            .sign_with_keys(&keys)
            .unwrap();
        storage
            .record_published_event(10050, "", &event2.id, &keys.public_key(), 2_000)
            .unwrap();
        let got2 = storage
            .last_published_event(10050, "", &keys.public_key())
            .unwrap()
            .expect("row must exist after overwrite");
        assert_eq!(got2.event_id, event2.id);
        assert_eq!(got2.published_at, 2_000);
    }

    #[test]
    fn last_published_event_returns_none_when_missing() {
        use nostr::Keys;
        let storage = make_storage();
        let keys = Keys::generate();
        let res = storage
            .last_published_event(10050, "", &keys.public_key())
            .unwrap();
        assert!(res.is_none());
    }

    #[test]
    fn record_published_event_does_not_clobber_newer_with_older() {
        // Regression: out-of-order publish callbacks (e.g., a delayed
        // ack for an older publish landing after a newer one has been
        // recorded) must not regress the stored event_id. Otherwise a
        // future NIP-09 deletion would reference the older event_id and
        // fail to retract the newer one from cooperative relays.
        use nostr::Keys;
        let storage = make_storage();
        let keys = Keys::generate();

        // First record: newer publication.
        let newer = nostr::EventBuilder::new(nostr::Kind::InboxRelays, "")
            .sign_with_keys(&keys)
            .unwrap();
        storage
            .record_published_event(10050, "", &newer.id, &keys.public_key(), 2_000)
            .unwrap();

        // Late callback for an older publication tries to overwrite.
        let older = nostr::EventBuilder::new(nostr::Kind::InboxRelays, "")
            .sign_with_keys(&keys)
            .unwrap();
        storage
            .record_published_event(10050, "", &older.id, &keys.public_key(), 500)
            .unwrap();

        // Stored row must still reflect the newer publication.
        let got = storage
            .last_published_event(10050, "", &keys.public_key())
            .unwrap()
            .expect("row must exist");
        assert_eq!(got.event_id, newer.id, "newer event_id must be preserved");
        assert_eq!(
            got.published_at, 2_000,
            "newer published_at must be preserved"
        );
    }
}
