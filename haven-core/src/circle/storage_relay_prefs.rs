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
//! * The seeding sentinel ([`SEEDED_KEY`]) is checked by *presence*, not by
//!   the row count of `user_relays` — a user who legitimately removes a
//!   default relay must not have it re-added by the next defensive seed.

// Single-shot SQLite ops naturally hold the lock to completion; the parent
// module already disables this lint at the file level for storage.rs.
#![allow(clippy::significant_drop_tightening)]

use chrono::Utc;
use nostr::{EventId, PublicKey, RelayUrl};
use rusqlite::{params, OptionalExtension};

use super::error::{CircleError, Result};
use super::relay_prefs::RelayType;
use super::storage::CircleStorage;
use super::types::default_relays;

/// Sentinel key in `user_settings` that records whether seeding has run.
///
/// The `_v1` suffix leaves room for a future "rotate the default set" pass
/// (`_v2` would be set after a one-shot upgrade-time re-seed if we ever
/// change the relay defaults returned by [`default_relays`]).
pub const SEEDED_KEY: &str = "relay_prefs_seeded_v1";

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
    let lower = lowercase_scheme_and_host(&canonical);
    // Strip a sole trailing slash on the root (no path/query/fragment).
    // "wss://x.example.com/" and "wss://x.example.com" must collide.
    // We do NOT strip the trailing slash of a path like
    // "wss://x.example.com/foo/" because that path *is* the path.
    let stripped = strip_root_trailing_slash(&lower);
    Ok(stripped)
}

/// Lowercases the scheme and host portion of a URL while preserving the
/// path/query/fragment case. Used by [`normalize_url`] so equivalent URLs
/// collide on the storage `UNIQUE` constraint regardless of input case.
///
/// Operates on parsed canonical form from `RelayUrl::parse`, so there is
/// always a `://` separator and a host segment.
fn lowercase_scheme_and_host(canonical: &str) -> String {
    canonical.find("://").map_or_else(
        || canonical.to_ascii_lowercase(),
        |scheme_end| {
            let scheme = &canonical[..scheme_end];
            let after = &canonical[scheme_end + 3..];
            // Host runs until the first '/', '?', or '#'.
            let host_end = after.find(['/', '?', '#']).unwrap_or(after.len());
            let host = &after[..host_end];
            let rest = &after[host_end..];
            format!(
                "{}://{}{}",
                scheme.to_ascii_lowercase(),
                host.to_ascii_lowercase(),
                rest
            )
        },
    )
}

/// Strips a single trailing slash after the host when the URL has no
/// real path (i.e., the canonical form is `<scheme>://<host>[:port]/`).
/// Leaves paths like `/foo/` alone.
fn strip_root_trailing_slash(canonical: &str) -> String {
    if let Some(scheme_end) = canonical.find("://") {
        let after = &canonical[scheme_end + 3..];
        // Find the start of the path (first '/' after authority).
        if let Some(path_start) = after.find('/') {
            let path = &after[path_start..];
            if path == "/" {
                return canonical[..scheme_end + 3 + path_start].to_string();
            }
        }
    }
    canonical.to_string()
}

impl CircleStorage {
    /// Seeds default relays on first launch.
    ///
    /// Idempotent: subsequent calls observe the [`SEEDED_KEY`] sentinel in
    /// `user_settings` and short-circuit. Crucially, the sentinel is the
    /// signal — never row presence in `user_relays`. A user who removes a
    /// default relay must not have it re-added by the next defensive seed.
    ///
    /// All inserts and the sentinel write happen in a single transaction so
    /// a partial failure cannot leave the user "half seeded."
    ///
    /// # Returns
    ///
    /// `true` if seeding actually wrote rows on this call; `false` if the
    /// sentinel was already set.
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

        let already: Option<String> = conn
            .query_row(
                "SELECT value FROM user_settings WHERE key = ?1",
                params![SEEDED_KEY],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        if already.is_some() {
            return Ok(false);
        }

        let now = Utc::now().timestamp();
        let tx = conn.transaction()?;
        for relay in default_relays() {
            // Use INSERT OR IGNORE so a partially-completed prior attempt
            // (where the sentinel never made it but rows did) doesn't error.
            tx.execute(
                "INSERT OR IGNORE INTO user_relays (url, relay_type, created_at) VALUES (?1, ?2, ?3)",
                params![relay, RelayType::Inbox.as_str(), now],
            )?;
            tx.execute(
                "INSERT OR IGNORE INTO user_relays (url, relay_type, created_at) VALUES (?1, ?2, ?3)",
                params![relay, RelayType::KeyPackage.as_str(), now],
            )?;
        }
        tx.execute(
            "INSERT INTO user_settings (key, value) VALUES (?1, '1')",
            params![SEEDED_KEY],
        )?;
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
    /// # Errors
    ///
    /// Returns [`CircleError::InvalidData`] for invalid URLs and database
    /// errors otherwise.
    pub fn add_user_relay(&self, url: &str, relay_type: RelayType) -> Result<()> {
        let normalized = normalize_url(url)?;
        let conn = self
            .conn()
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        let now = Utc::now().timestamp();
        conn.execute(
            "INSERT OR IGNORE INTO user_relays (url, relay_type, created_at) VALUES (?1, ?2, ?3)",
            params![normalized, relay_type.as_str(), now],
        )?;
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
    /// Adds any missing default relays via `INSERT OR IGNORE`. Existing
    /// user-added custom relays are preserved. Use
    /// [`Self::wipe_and_reset_defaults_for`] for the destructive variant
    /// (always behind a UI confirmation dialog).
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
        for relay in default_relays() {
            tx.execute(
                "INSERT OR IGNORE INTO user_relays (url, relay_type, created_at) VALUES (?1, ?2, ?3)",
                params![relay, relay_type.as_str(), now],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Destructively resets a category to exactly the current default relay
    /// list returned by [`default_relays`].
    ///
    /// Wipes all rows for the category and re-inserts defaults in one
    /// transaction. The caller MUST gate this behind a confirmation dialog;
    /// the function name is deliberately verbose to prevent accidental use.
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
        for relay in default_relays() {
            tx.execute(
                "INSERT INTO user_relays (url, relay_type, created_at) VALUES (?1, ?2, ?3)",
                params![relay, relay_type.as_str(), now],
            )?;
        }
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
        // Second call — sentinel set, no-op.
        assert!(!storage.seed_defaults_if_unseeded().unwrap());
        // Both categories populated with the production defaults.
        let inbox = storage.list_user_relays(RelayType::Inbox).unwrap();
        let kp = storage.list_user_relays(RelayType::KeyPackage).unwrap();
        assert_eq!(inbox.len(), crate::circle::PRODUCTION_DEFAULT_RELAYS.len());
        assert_eq!(kp.len(), crate::circle::PRODUCTION_DEFAULT_RELAYS.len());
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
