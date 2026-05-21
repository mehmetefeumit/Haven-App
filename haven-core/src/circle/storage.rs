//! `SQLite` storage for circle management.
//!
//! This module provides persistent storage for circles, memberships,
//! contacts, and UI state. All data is stored locally on the device
//! and never synced to Nostr relays.
//!
//! # Privacy
//!
//! The contacts table stores locally-assigned display names and avatars.
//! This data is private to the user's device, supporting Haven's
//! privacy-first model where relays never see usernames.

// SQLite operations need to hold the lock for the duration of the operation.
// Dropping the guard earlier would require restructuring all methods.
#![allow(clippy::significant_drop_tightening)]

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{params, Connection, OptionalExtension};

use nostr::EventId;

use super::error::{CircleError, Result};
use super::types::{
    Circle, CircleMembership, CircleType, CircleUiState, Contact, LastKnownLocation,
    MembershipStatus,
};
use crate::nostr::mls::types::GroupId;

/// `SQLite`-based storage for circle data.
///
/// Thread-safe wrapper around a `SQLite` connection for storing
/// circle metadata, membership state, contacts, and UI preferences.
pub struct CircleStorage {
    conn: Mutex<Connection>,
}

impl CircleStorage {
    /// Crate-private accessor used by sibling modules
    /// (e.g. [`super::storage_relay_prefs`]) to extend `CircleStorage` with
    /// additional methods that share the single `Mutex<Connection>` design.
    /// Marked `pub(crate)` so external callers cannot reach into the lock.
    ///
    /// # Discipline for new methods using this accessor
    ///
    /// Every method built on top of this accessor MUST follow the
    /// established **lock-once-then-transaction** pattern:
    ///
    /// 1. Acquire the lock once at the top: `let conn = self.conn().lock()...`.
    ///    Convert the poison error to [`super::error::CircleError::Storage`]
    ///    so the FFI boundary cannot leak `MutexGuard` internals.
    /// 2. For multi-statement work that must be atomic, take a single
    ///    transaction (`conn.transaction()`) and either `commit()` it or
    ///    let `?` propagate (which drops the tx and rolls back). Do NOT
    ///    open nested transactions and do NOT release the lock between
    ///    statements that depend on each other (e.g. count-then-delete).
    /// 3. Keep operations short. The lock blocks every other SQLite-bound
    ///    method on the same `CircleStorage`, including those used on
    ///    hot paths (location publish, message receive). If a new
    ///    operation needs significant CPU work, do that work *outside*
    ///    the lock.
    /// 4. Never expose `Connection` (or anything derived from it) to
    ///    callers outside the `circle` module — the `pub(crate)`
    ///    visibility is load-bearing.
    pub(crate) const fn conn(&self) -> &Mutex<Connection> {
        &self.conn
    }

    /// Creates a new storage instance at the given path.
    ///
    /// Creates the database file and tables if they don't exist.
    /// If `encryption_hex_key` is provided, enables `SQLCipher` encryption.
    ///
    /// # Arguments
    ///
    /// * `path` - Path to the database file
    /// * `encryption_hex_key` - Optional 64-character hex key for `SQLCipher` encryption.
    ///   When provided, the database is encrypted with a raw 256-bit AES key.
    ///
    /// # Errors
    ///
    /// Returns an error if the database cannot be created or initialized.
    pub fn new(path: &Path, encryption_hex_key: Option<&str>) -> Result<Self> {
        let db_exists = path.exists();

        if let Some(hex_key) = encryption_hex_key {
            // Validate hex key format (defense-in-depth against SQL injection via PRAGMA)
            if hex_key.len() != 64 || !hex_key.bytes().all(|b| b.is_ascii_hexdigit()) {
                return Err(CircleError::InvalidData(
                    "Encryption key must be exactly 64 hex characters".to_string(),
                ));
            }

            // Attempt to open with encryption
            let conn = Connection::open(path)?;
            // hex_key is validated above to contain only hex characters and be exactly
            // 64 chars. Using raw key format avoids PBKDF2 overhead since our key
            // already has 256 bits of entropy from OsRng.
            conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\""))?;

            if db_exists {
                // Verify we can read an existing DB with this key
                if conn
                    .query_row("SELECT count(*) FROM sqlite_master", [], |r| {
                        r.get::<_, i64>(0)
                    })
                    .is_ok()
                {
                    // Key works (DB already encrypted with this key, or new)
                    let storage = Self {
                        conn: Mutex::new(conn),
                    };
                    storage.initialize_schema()?;
                    return Ok(storage);
                }
                // Existing DB is unencrypted — migrate it
                drop(conn);
                return Self::migrate_to_encrypted(path, hex_key);
            }

            // New database — schema will be created encrypted
            let storage = Self {
                conn: Mutex::new(conn),
            };
            storage.initialize_schema()?;
            return Ok(storage);
        }

        // No encryption key — open normally
        let conn = Connection::open(path)?;
        let storage = Self {
            conn: Mutex::new(conn),
        };
        storage.initialize_schema()?;
        Ok(storage)
    }

    /// Migrates an existing unencrypted database to encrypted storage.
    ///
    /// Uses `SQLCipher`'s `ATTACH` + `sqlcipher_export()` to copy all data
    /// from the unencrypted database into a new encrypted database, then
    /// replaces the original file.
    fn migrate_to_encrypted(path: &Path, hex_key: &str) -> Result<Self> {
        // First, verify the existing DB is actually unencrypted by reading without a key.
        // If we can't read it, it's encrypted with a different key — don't corrupt it.
        {
            let verify_conn = Connection::open(path)?;
            verify_conn
                .query_row("SELECT count(*) FROM sqlite_master", [], |r| {
                    r.get::<_, i64>(0)
                })
                .map_err(|_| {
                    CircleError::Storage(
                        "Database appears encrypted with a different key; cannot migrate"
                            .to_string(),
                    )
                })?;
        }

        let temp_path = path.with_extension("db.encrypting");

        // Clean up any leftover temp file from a previous failed migration
        if temp_path.exists() {
            let _ = std::fs::remove_file(&temp_path);
        }

        // Open old unencrypted DB (no PRAGMA key)
        let old_conn = Connection::open(path)?;

        // Attach a new encrypted database
        let temp_str = temp_path.to_string_lossy();
        old_conn.execute_batch(&format!(
            "ATTACH DATABASE '{temp_str}' AS encrypted KEY \"x'{hex_key}'\""
        ))?;

        // Export all data to the encrypted database
        let export_result = old_conn.execute_batch("SELECT sqlcipher_export('encrypted')");

        if let Err(e) = export_result {
            // Clean up temp file on export failure
            old_conn.execute_batch("DETACH DATABASE encrypted").ok();
            drop(old_conn);
            let _ = std::fs::remove_file(&temp_path);
            return Err(CircleError::Storage(format!(
                "Failed to export data during migration: {e}"
            )));
        }

        old_conn.execute_batch("DETACH DATABASE encrypted")?;
        drop(old_conn);

        // Replace old DB with encrypted one
        std::fs::rename(&temp_path, path).map_err(|e| {
            // Clean up temp file if rename fails
            let _ = std::fs::remove_file(&temp_path);
            CircleError::Storage(format!("Failed to replace database during migration: {e}"))
        })?;

        log::info!("circles.db migrated from unencrypted to encrypted storage");

        // Open the new encrypted DB
        let conn = Connection::open(path)?;
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\""))?;

        let storage = Self {
            conn: Mutex::new(conn),
        };
        storage.initialize_schema()?;
        Ok(storage)
    }

    /// Creates an in-memory storage instance for testing.
    ///
    /// # Errors
    ///
    /// Returns an error if the database cannot be initialized.
    #[cfg(test)]
    pub fn in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        let storage = Self {
            conn: Mutex::new(conn),
        };
        storage.initialize_schema()?;
        Ok(storage)
    }

    /// Initializes the database schema.
    #[allow(
        clippy::too_many_lines,
        reason = "single CREATE TABLE block; splitting hides the schema in fragments"
    )]
    fn initialize_schema(&self) -> Result<()> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        conn.execute_batch(
            r"
            -- Circle metadata (app-level, not MLS state)
            CREATE TABLE IF NOT EXISTS circles (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                mls_group_id BLOB NOT NULL UNIQUE,
                nostr_group_id BLOB NOT NULL,
                display_name TEXT NOT NULL,
                circle_type TEXT NOT NULL DEFAULT 'location_sharing',
                relays TEXT NOT NULL DEFAULT '[]',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );

            -- Membership state (pending/accepted/declined invitations)
            CREATE TABLE IF NOT EXISTS circle_memberships (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                mls_group_id BLOB NOT NULL UNIQUE,
                status TEXT NOT NULL DEFAULT 'pending',
                inviter_pubkey TEXT,
                invited_at INTEGER NOT NULL,
                responded_at INTEGER,
                FOREIGN KEY (mls_group_id) REFERENCES circles(mls_group_id)
            );

            -- Local contact storage (privacy-first: never synced to relays)
            CREATE TABLE IF NOT EXISTS contacts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                pubkey TEXT NOT NULL UNIQUE,
                display_name TEXT,
                avatar_path TEXT,
                notes TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );

            -- UI state per circle
            CREATE TABLE IF NOT EXISTS circle_ui_state (
                mls_group_id BLOB PRIMARY KEY,
                last_read_message_id TEXT,
                pin_order INTEGER,
                is_muted INTEGER NOT NULL DEFAULT 0
            );

            -- Persistent last-known location cache (per circle, per sender).
            -- Survives app restarts and relay TTL so members can see each
            -- other's last known position while offline. Rows are deleted
            -- once `purge_after` passes — the receiver computes it on
            -- insert as `timestamp + LOCATION_RETENTION_SECS` (1 day).
            --
            -- `precision_label` is a legacy column kept for backward compat
            -- with databases created before the privacy feature was removed.
            -- New rows write an empty string; readers ignore it.
            CREATE TABLE IF NOT EXISTS last_known_locations (
                nostr_group_id  BLOB NOT NULL,
                sender_pubkey   TEXT NOT NULL,
                latitude        REAL NOT NULL,
                longitude       REAL NOT NULL,
                geohash         TEXT NOT NULL,
                precision_label TEXT NOT NULL DEFAULT '',
                display_name    TEXT,
                timestamp       INTEGER NOT NULL,
                expires_at      INTEGER NOT NULL,
                purge_after     INTEGER NOT NULL,
                updated_at      INTEGER NOT NULL,
                PRIMARY KEY (nostr_group_id, sender_pubkey)
            );
            CREATE INDEX IF NOT EXISTS idx_lkl_purge_after
                ON last_known_locations(purge_after);
            CREATE INDEX IF NOT EXISTS idx_lkl_group
                ON last_known_locations(nostr_group_id);

            -- Idempotency cache for NIP-59 gift-wrap (kind 1059) invitation
            -- processing. The invitation poller uses a 2-day lookback window,
            -- so the same gift wrap is re-fetched on every poll cycle. MDK
            -- consumes the referenced KeyPackage on first `process_welcome`
            -- and errors on every subsequent call with `invalid welcome`.
            -- We dedup at the wrapper-event-id boundary so repeat deliveries
            -- of an already-processed gift wrap short-circuit before MDK.
            CREATE TABLE IF NOT EXISTS processed_gift_wraps (
                wrapper_event_id BLOB PRIMARY KEY,
                mls_group_id     BLOB NOT NULL,
                processed_at     INTEGER NOT NULL
            );

            -- User-configurable relay preferences (kind 10050 inbox + kind
            -- 10051 KeyPackage). Each (url, relay_type) pair is unique. URLs
            -- are stored normalized — see storage_relay_prefs::normalize_url.
            -- Seeded with DEFAULT_RELAYS on first launch via the
            -- `relay_prefs_seeded_v1` sentinel in user_settings; subsequent
            -- launches no-op even if the user removed the defaults.
            CREATE TABLE IF NOT EXISTS user_relays (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                url         TEXT NOT NULL,
                relay_type  TEXT NOT NULL,
                created_at  INTEGER NOT NULL,
                UNIQUE (url, relay_type)
            );
            CREATE INDEX IF NOT EXISTS idx_user_relays_type
                ON user_relays(relay_type);

            -- Generic key/value table for user settings (privacy toggles,
            -- seeding sentinels, UI state). Schema versioning sentinels
            -- live here too if we ever need them.
            CREATE TABLE IF NOT EXISTS user_settings (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            -- Tracks the last published replaceable event id per (kind, d_tag,
            -- pubkey) tuple. Used by `unpublish_relay_list` to construct
            -- best-effort NIP-09 deletions, and by future audit/republish
            -- workflows. Bounded by the small set of replaceable kinds the
            -- user's identity actually publishes.
            CREATE TABLE IF NOT EXISTS published_events (
                kind          INTEGER NOT NULL,
                d_tag         TEXT NOT NULL DEFAULT '',
                event_id      BLOB NOT NULL,
                pubkey        BLOB NOT NULL,
                published_at  INTEGER NOT NULL,
                PRIMARY KEY (kind, d_tag, pubkey)
            );
            ",
        )?;

        Ok(())
    }

    // ==================== Circle Operations ====================

    /// Saves a circle to the database.
    ///
    /// If a circle with the same `mls_group_id` exists, it will be updated.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn save_circle(&self, circle: &Circle) -> Result<()> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        // Serialize relays as JSON array
        let relays_json = serde_json::to_string(&circle.relays)
            .map_err(|e| CircleError::Storage(format!("Failed to serialize relays: {e}")))?;

        conn.execute(
            r"
            INSERT INTO circles (mls_group_id, nostr_group_id, display_name, circle_type, relays, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(mls_group_id) DO UPDATE SET
                nostr_group_id = excluded.nostr_group_id,
                display_name = excluded.display_name,
                circle_type = excluded.circle_type,
                relays = excluded.relays,
                updated_at = excluded.updated_at
            ",
            params![
                circle.mls_group_id.as_slice(),
                &circle.nostr_group_id[..],
                &circle.display_name,
                circle.circle_type.as_str(),
                &relays_json,
                circle.created_at,
                circle.updated_at,
            ],
        )?;

        Ok(())
    }

    /// Retrieves a circle by its MLS group ID.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn get_circle(&self, mls_group_id: &GroupId) -> Result<Option<Circle>> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        let result = conn
            .query_row(
                r"
                SELECT mls_group_id, nostr_group_id, display_name, circle_type, relays, created_at, updated_at
                FROM circles
                WHERE mls_group_id = ?1
                ",
                params![mls_group_id.as_slice()],
                |row| {
                    let mls_group_id: Vec<u8> = row.get(0)?;
                    let nostr_group_id: Vec<u8> = row.get(1)?;
                    let display_name: String = row.get(2)?;
                    let circle_type_str: String = row.get(3)?;
                    let relays_json: String = row.get(4)?;
                    let created_at: i64 = row.get(5)?;
                    let updated_at: i64 = row.get(6)?;

                    Ok((
                        mls_group_id,
                        nostr_group_id,
                        display_name,
                        circle_type_str,
                        relays_json,
                        created_at,
                        updated_at,
                    ))
                },
            )
            .optional()?;

        match result {
            Some((
                mls_group_id,
                nostr_group_id,
                display_name,
                circle_type_str,
                relays_json,
                created_at,
                updated_at,
            )) => {
                let nostr_group_id: [u8; 32] = nostr_group_id.try_into().map_err(|_| {
                    CircleError::InvalidData("Invalid nostr_group_id length".to_string())
                })?;

                let circle_type = CircleType::parse(&circle_type_str).ok_or_else(|| {
                    CircleError::InvalidData(format!("Invalid circle_type: {circle_type_str}"))
                })?;

                let relays: Vec<String> = serde_json::from_str(&relays_json)
                    .map_err(|e| CircleError::InvalidData(format!("Invalid relays JSON: {e}")))?;

                Ok(Some(Circle {
                    mls_group_id: GroupId::from_slice(&mls_group_id),
                    nostr_group_id,
                    display_name,
                    circle_type,
                    relays,
                    created_at,
                    updated_at,
                }))
            }
            None => Ok(None),
        }
    }

    /// Retrieves all circles.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn get_all_circles(&self) -> Result<Vec<Circle>> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        let mut stmt = conn.prepare(
            r"
            SELECT mls_group_id, nostr_group_id, display_name, circle_type, relays, created_at, updated_at
            FROM circles
            ORDER BY updated_at DESC
            ",
        )?;

        let circles = stmt
            .query_map([], |row| {
                let mls_group_id: Vec<u8> = row.get(0)?;
                let nostr_group_id: Vec<u8> = row.get(1)?;
                let display_name: String = row.get(2)?;
                let circle_type_str: String = row.get(3)?;
                let relays_json: String = row.get(4)?;
                let created_at: i64 = row.get(5)?;
                let updated_at: i64 = row.get(6)?;

                Ok((
                    mls_group_id,
                    nostr_group_id,
                    display_name,
                    circle_type_str,
                    relays_json,
                    created_at,
                    updated_at,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        circles
            .into_iter()
            .map(
                |(
                    mls_group_id,
                    nostr_group_id,
                    display_name,
                    circle_type_str,
                    relays_json,
                    created_at,
                    updated_at,
                )| {
                    let nostr_group_id: [u8; 32] = nostr_group_id.try_into().map_err(|_| {
                        CircleError::InvalidData("Invalid nostr_group_id length".to_string())
                    })?;

                    let circle_type = CircleType::parse(&circle_type_str).ok_or_else(|| {
                        CircleError::InvalidData(format!("Invalid circle_type: {circle_type_str}"))
                    })?;

                    let relays: Vec<String> = serde_json::from_str(&relays_json).map_err(|e| {
                        CircleError::InvalidData(format!("Invalid relays JSON: {e}"))
                    })?;

                    Ok(Circle {
                        mls_group_id: GroupId::from_slice(&mls_group_id),
                        nostr_group_id,
                        display_name,
                        circle_type,
                        relays,
                        created_at,
                        updated_at,
                    })
                },
            )
            .collect()
    }

    /// Deletes a circle by its MLS group ID.
    ///
    /// Also deletes associated membership and UI state.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    /// Deletes a circle and every related row (UI state, memberships,
    /// last-known locations) atomically.
    ///
    /// Idempotent: deleting a circle that does not exist is not an error,
    /// it simply logs and returns `Ok(false)`.
    ///
    /// Returns `Ok(true)` if the circle row existed and was removed.
    ///
    /// # Errors
    ///
    /// Returns an error if any step of the cascade fails. The transaction
    /// is rolled back on error so partial state cannot leak.
    pub fn delete_circle(&self, mls_group_id: &GroupId) -> Result<bool> {
        let mut conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        // Wrap the entire cascade in a transaction so a mid-cascade failure
        // cannot leave orphaned rows (e.g. last_known_locations referencing a
        // circle that has already been removed).
        let tx = conn.transaction()?;

        // Resolve nostr_group_id for last-known-location cleanup before we
        // drop the row (last_known_locations is keyed by nostr_group_id, not
        // mls_group_id).
        let nostr_group_id: Option<Vec<u8>> = tx
            .query_row(
                "SELECT nostr_group_id FROM circles WHERE mls_group_id = ?1",
                params![mls_group_id.as_slice()],
                |row| row.get(0),
            )
            .optional()?;

        let existed = nostr_group_id.is_some();

        // Delete in order respecting foreign key constraints
        tx.execute(
            "DELETE FROM circle_ui_state WHERE mls_group_id = ?1",
            params![mls_group_id.as_slice()],
        )?;
        tx.execute(
            "DELETE FROM circle_memberships WHERE mls_group_id = ?1",
            params![mls_group_id.as_slice()],
        )?;
        tx.execute(
            "DELETE FROM circles WHERE mls_group_id = ?1",
            params![mls_group_id.as_slice()],
        )?;
        if let Some(ngid) = nostr_group_id {
            tx.execute(
                "DELETE FROM last_known_locations WHERE nostr_group_id = ?1",
                params![ngid],
            )?;
        }

        tx.commit()?;

        if !existed {
            log::debug!(
                "delete_circle called for non-existent mls_group_id ({} bytes); no-op",
                mls_group_id.as_slice().len()
            );
        }
        Ok(existed)
    }

    // ==================== Membership Operations ====================

    /// Saves a membership to the database.
    ///
    /// If a membership with the same `mls_group_id` exists, it will be updated.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn save_membership(&self, membership: &CircleMembership) -> Result<()> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        conn.execute(
            r"
            INSERT INTO circle_memberships (mls_group_id, status, inviter_pubkey, invited_at, responded_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(mls_group_id) DO UPDATE SET
                status = excluded.status,
                inviter_pubkey = excluded.inviter_pubkey,
                invited_at = excluded.invited_at,
                responded_at = excluded.responded_at
            ",
            params![
                membership.mls_group_id.as_slice(),
                membership.status.as_str(),
                &membership.inviter_pubkey,
                membership.invited_at,
                membership.responded_at,
            ],
        )?;

        Ok(())
    }

    /// Retrieves a membership by its MLS group ID.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn get_membership(&self, mls_group_id: &GroupId) -> Result<Option<CircleMembership>> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        let result = conn
            .query_row(
                r"
                SELECT mls_group_id, status, inviter_pubkey, invited_at, responded_at
                FROM circle_memberships
                WHERE mls_group_id = ?1
                ",
                params![mls_group_id.as_slice()],
                |row| {
                    let mls_group_id: Vec<u8> = row.get(0)?;
                    let status_str: String = row.get(1)?;
                    let inviter_pubkey: Option<String> = row.get(2)?;
                    let invited_at: i64 = row.get(3)?;
                    let responded_at: Option<i64> = row.get(4)?;

                    Ok((
                        mls_group_id,
                        status_str,
                        inviter_pubkey,
                        invited_at,
                        responded_at,
                    ))
                },
            )
            .optional()?;

        match result {
            Some((mls_group_id, status_str, inviter_pubkey, invited_at, responded_at)) => {
                let status = MembershipStatus::parse(&status_str).ok_or_else(|| {
                    CircleError::InvalidData(format!("Invalid status: {status_str}"))
                })?;

                Ok(Some(CircleMembership {
                    mls_group_id: GroupId::from_slice(&mls_group_id),
                    status,
                    inviter_pubkey,
                    invited_at,
                    responded_at,
                }))
            }
            None => Ok(None),
        }
    }

    /// Updates the membership status for a circle.
    ///
    /// Also updates the `responded_at` timestamp if transitioning from pending.
    ///
    /// # Errors
    ///
    /// Returns an error if the membership doesn't exist or the database operation fails.
    pub fn update_membership_status(
        &self,
        mls_group_id: &GroupId,
        status: MembershipStatus,
        responded_at: Option<i64>,
    ) -> Result<()> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        let rows = conn.execute(
            r"
            UPDATE circle_memberships
            SET status = ?1, responded_at = ?2
            WHERE mls_group_id = ?3
            ",
            params![status.as_str(), responded_at, mls_group_id.as_slice()],
        )?;

        if rows == 0 {
            return Err(CircleError::NotFound(
                "Membership not found for group: <redacted>".to_string(),
            ));
        }

        Ok(())
    }

    // ==================== Contact Operations ====================

    /// Saves a contact to the database.
    ///
    /// If a contact with the same pubkey exists, it will be updated.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn save_contact(&self, contact: &Contact) -> Result<()> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        conn.execute(
            r"
            INSERT INTO contacts (pubkey, display_name, avatar_path, notes, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(pubkey) DO UPDATE SET
                display_name = excluded.display_name,
                avatar_path = excluded.avatar_path,
                notes = excluded.notes,
                updated_at = excluded.updated_at
            ",
            params![
                &contact.pubkey,
                &contact.display_name,
                &contact.avatar_path,
                &contact.notes,
                contact.created_at,
                contact.updated_at,
            ],
        )?;

        Ok(())
    }

    /// Retrieves a contact by pubkey.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn get_contact(&self, pubkey: &str) -> Result<Option<Contact>> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        let result = conn
            .query_row(
                r"
                SELECT pubkey, display_name, avatar_path, notes, created_at, updated_at
                FROM contacts
                WHERE pubkey = ?1
                ",
                params![pubkey],
                |row| {
                    Ok(Contact {
                        pubkey: row.get(0)?,
                        display_name: row.get(1)?,
                        avatar_path: row.get(2)?,
                        notes: row.get(3)?,
                        created_at: row.get(4)?,
                        updated_at: row.get(5)?,
                    })
                },
            )
            .optional()?;

        Ok(result)
    }

    /// Retrieves all contacts.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn get_all_contacts(&self) -> Result<Vec<Contact>> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        let mut stmt = conn.prepare(
            r"
            SELECT pubkey, display_name, avatar_path, notes, created_at, updated_at
            FROM contacts
            ORDER BY display_name NULLS LAST, pubkey
            ",
        )?;

        let contacts = stmt
            .query_map([], |row| {
                Ok(Contact {
                    pubkey: row.get(0)?,
                    display_name: row.get(1)?,
                    avatar_path: row.get(2)?,
                    notes: row.get(3)?,
                    created_at: row.get(4)?,
                    updated_at: row.get(5)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        Ok(contacts)
    }

    /// Deletes a contact by pubkey.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn delete_contact(&self, pubkey: &str) -> Result<()> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        conn.execute("DELETE FROM contacts WHERE pubkey = ?1", params![pubkey])?;

        Ok(())
    }

    // ==================== UI State Operations ====================

    /// Saves UI state for a circle.
    ///
    /// If UI state for the circle exists, it will be updated.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn save_ui_state(&self, state: &CircleUiState) -> Result<()> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        conn.execute(
            r"
            INSERT INTO circle_ui_state (mls_group_id, last_read_message_id, pin_order, is_muted)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(mls_group_id) DO UPDATE SET
                last_read_message_id = excluded.last_read_message_id,
                pin_order = excluded.pin_order,
                is_muted = excluded.is_muted
            ",
            params![
                state.mls_group_id.as_slice(),
                &state.last_read_message_id,
                state.pin_order,
                i32::from(state.is_muted),
            ],
        )?;

        Ok(())
    }

    /// Retrieves UI state for a circle.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn get_ui_state(&self, mls_group_id: &GroupId) -> Result<Option<CircleUiState>> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        let result = conn
            .query_row(
                r"
                SELECT mls_group_id, last_read_message_id, pin_order, is_muted
                FROM circle_ui_state
                WHERE mls_group_id = ?1
                ",
                params![mls_group_id.as_slice()],
                |row| {
                    let mls_group_id: Vec<u8> = row.get(0)?;
                    let last_read_message_id: Option<String> = row.get(1)?;
                    let pin_order: Option<i32> = row.get(2)?;
                    let is_muted: i32 = row.get(3)?;

                    Ok((mls_group_id, last_read_message_id, pin_order, is_muted))
                },
            )
            .optional()?;

        match result {
            Some((mls_group_id, last_read_message_id, pin_order, is_muted)) => {
                Ok(Some(CircleUiState {
                    mls_group_id: GroupId::from_slice(&mls_group_id),
                    last_read_message_id,
                    pin_order,
                    is_muted: is_muted != 0,
                }))
            }
            None => Ok(None),
        }
    }

    // ==================== Last-Known Location Operations ====================

    /// Upserts a last-known location row.
    ///
    /// If a row already exists for `(nostr_group_id, sender_pubkey)`, it is
    /// updated **only** when the incoming `timestamp` is strictly newer than
    /// the stored one. Stale / out-of-order events are silently ignored.
    ///
    /// Callers are expected to have already derived
    /// `purge_after = timestamp + LOCATION_RETENTION_SECS` (1 day) — the
    /// caller in `CircleManager` is the authoritative computation point.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn upsert_last_known_location(&self, location: &LastKnownLocation) -> Result<()> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        // `precision_label` is a legacy column (always empty on new writes).
        conn.execute(
            r"
            INSERT INTO last_known_locations (
                nostr_group_id, sender_pubkey, latitude, longitude, geohash,
                precision_label, display_name, timestamp, expires_at,
                purge_after, updated_at
            )
            VALUES (?1, ?2, ?3, ?4, ?5, '', ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(nostr_group_id, sender_pubkey) DO UPDATE SET
                latitude        = excluded.latitude,
                longitude       = excluded.longitude,
                geohash         = excluded.geohash,
                display_name    = excluded.display_name,
                timestamp       = excluded.timestamp,
                expires_at      = excluded.expires_at,
                purge_after     = excluded.purge_after,
                updated_at      = excluded.updated_at
            WHERE excluded.timestamp > last_known_locations.timestamp
            ",
            params![
                &location.nostr_group_id[..],
                &location.sender_pubkey,
                location.latitude,
                location.longitude,
                &location.geohash,
                &location.display_name,
                location.timestamp,
                location.expires_at,
                location.purge_after,
                location.updated_at,
            ],
        )?;

        Ok(())
    }

    /// Returns all non-purged last-known locations for a circle.
    ///
    /// Rows whose `purge_after < now_unix_secs` are filtered out. Callers
    /// should pass the current Unix-seconds clock.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn snapshot_last_known_for_circle(
        &self,
        nostr_group_id: &[u8; 32],
        now_unix_secs: i64,
    ) -> Result<Vec<LastKnownLocation>> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        // `precision_label` column is no longer surfaced — skip it in SELECT.
        let mut stmt = conn.prepare(
            r"
            SELECT nostr_group_id, sender_pubkey, latitude, longitude, geohash,
                   display_name, timestamp, expires_at,
                   purge_after, updated_at
            FROM last_known_locations
            WHERE nostr_group_id = ?1 AND purge_after >= ?2
            ORDER BY timestamp DESC
            ",
        )?;

        let rows = stmt
            .query_map(params![&nostr_group_id[..], now_unix_secs], |row| {
                let ngid: Vec<u8> = row.get(0)?;
                let sender_pubkey: String = row.get(1)?;
                let latitude: f64 = row.get(2)?;
                let longitude: f64 = row.get(3)?;
                let geohash: String = row.get(4)?;
                let display_name: Option<String> = row.get(5)?;
                let timestamp: i64 = row.get(6)?;
                let expires_at: i64 = row.get(7)?;
                let purge_after: i64 = row.get(8)?;
                let updated_at: i64 = row.get(9)?;

                Ok((
                    ngid,
                    sender_pubkey,
                    latitude,
                    longitude,
                    geohash,
                    display_name,
                    timestamp,
                    expires_at,
                    purge_after,
                    updated_at,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        rows.into_iter()
            .map(
                |(
                    ngid,
                    sender_pubkey,
                    latitude,
                    longitude,
                    geohash,
                    display_name,
                    timestamp,
                    expires_at,
                    purge_after,
                    updated_at,
                )| {
                    let nostr_group_id: [u8; 32] = ngid.try_into().map_err(|_| {
                        CircleError::InvalidData("Invalid nostr_group_id length".to_string())
                    })?;
                    Ok(LastKnownLocation {
                        nostr_group_id,
                        sender_pubkey,
                        latitude,
                        longitude,
                        geohash,
                        display_name,
                        timestamp,
                        expires_at,
                        purge_after,
                        updated_at,
                    })
                },
            )
            .collect()
    }

    /// Removes the last-known location for a single sender in a circle.
    ///
    /// Called when a member is removed from a circle.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn remove_last_known_member(
        &self,
        nostr_group_id: &[u8; 32],
        sender_pubkey: &str,
    ) -> Result<()> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        conn.execute(
            "DELETE FROM last_known_locations
             WHERE nostr_group_id = ?1 AND sender_pubkey = ?2",
            params![&nostr_group_id[..], sender_pubkey],
        )?;

        Ok(())
    }

    /// Removes every last-known location row for a circle.
    ///
    /// Called when the user leaves / deletes a circle so that no residual
    /// location data for former co-members remains on disk.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn remove_last_known_circle(&self, nostr_group_id: &[u8; 32]) -> Result<()> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        conn.execute(
            "DELETE FROM last_known_locations WHERE nostr_group_id = ?1",
            params![&nostr_group_id[..]],
        )?;

        Ok(())
    }

    /// Wipes every last-known location row.
    ///
    /// Called from the identity-deletion path so no stale location data
    /// survives a full account wipe.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn wipe_all_last_known_locations(&self) -> Result<()> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        conn.execute("DELETE FROM last_known_locations", [])?;

        Ok(())
    }

    /// Deletes every row whose `purge_after < now_unix_secs`.
    ///
    /// Returns the number of rows removed. Intended to be called from a
    /// periodic sweep (app start, hourly timer, etc.) so the persistent
    /// cache stays bounded.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn prune_expired_last_known(&self, now_unix_secs: i64) -> Result<usize> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        let rows = conn.execute(
            "DELETE FROM last_known_locations WHERE purge_after < ?1",
            params![now_unix_secs],
        )?;

        Ok(rows)
    }

    // ==================== Gift Wrap Idempotency ====================

    /// Checks whether a gift-wrap (kind 1059) wrapper event has already been
    /// processed into an invitation.
    ///
    /// Returns the stored `mls_group_id` if the wrapper ID is known, or
    /// `None` if this is a fresh wrapper the poller has never seen before.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn is_gift_wrap_processed(&self, wrapper_event_id: &EventId) -> Result<Option<Vec<u8>>> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        conn.query_row(
            "SELECT mls_group_id FROM processed_gift_wraps WHERE wrapper_event_id = ?1",
            params![wrapper_event_id.as_bytes()],
            |row| row.get::<_, Vec<u8>>(0),
        )
        .optional()
        .map_err(Into::into)
    }

    /// Records a newly-processed gift-wrapped invitation atomically.
    ///
    /// Writes the circle row, the pending membership row, and the dedup
    /// row (`processed_gift_wraps`) in a single `SQLCipher` transaction so
    /// a crash between `mdk.process_welcome` and the Rust-side bookkeeping
    /// cannot leave orphan rows or poison the dedup cache.
    ///
    /// # Errors
    ///
    /// Returns an error if any insert fails; the transaction is rolled back.
    pub fn record_processed_invitation(
        &self,
        wrapper_event_id: &EventId,
        circle: &Circle,
        membership: &CircleMembership,
        processed_at: i64,
    ) -> Result<()> {
        let mut conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        let relays_json = serde_json::to_string(&circle.relays)
            .map_err(|e| CircleError::Storage(format!("Failed to serialize relays: {e}")))?;

        let tx = conn.transaction()?;

        tx.execute(
            r"
            INSERT INTO circles (mls_group_id, nostr_group_id, display_name, circle_type, relays, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(mls_group_id) DO UPDATE SET
                nostr_group_id = excluded.nostr_group_id,
                display_name = excluded.display_name,
                circle_type = excluded.circle_type,
                relays = excluded.relays,
                updated_at = excluded.updated_at
            ",
            params![
                circle.mls_group_id.as_slice(),
                &circle.nostr_group_id[..],
                &circle.display_name,
                circle.circle_type.as_str(),
                &relays_json,
                circle.created_at,
                circle.updated_at,
            ],
        )?;

        tx.execute(
            r"
            INSERT INTO circle_memberships (mls_group_id, status, inviter_pubkey, invited_at, responded_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(mls_group_id) DO UPDATE SET
                status = excluded.status,
                inviter_pubkey = excluded.inviter_pubkey,
                invited_at = excluded.invited_at,
                responded_at = excluded.responded_at
            ",
            params![
                membership.mls_group_id.as_slice(),
                membership.status.as_str(),
                &membership.inviter_pubkey,
                membership.invited_at,
                membership.responded_at,
            ],
        )?;

        tx.execute(
            "INSERT INTO processed_gift_wraps (wrapper_event_id, mls_group_id, processed_at) \
             VALUES (?1, ?2, ?3)",
            params![
                wrapper_event_id.as_bytes(),
                circle.mls_group_id.as_slice(),
                processed_at,
            ],
        )?;

        tx.commit()?;
        Ok(())
    }

    /// Records a gift-wrap as terminally failed processing.
    ///
    /// `mdk.process_welcome` consumes the referenced `KeyPackage` on success
    /// and has no recovery path: once the KP material is spent, every
    /// subsequent call errors with `invalid welcome message`. This sentinel
    /// insert lets the idempotency guard short-circuit a re-fetched wrapper
    /// that failed MDK once so the poller does not spam the same error on
    /// every 2-minute cycle.
    ///
    /// The row uses an **empty blob** for `mls_group_id` to distinguish it
    /// from a successfully-processed wrapper (real MLS group IDs are 32
    /// bytes). `is_gift_wrap_processed` still returns `Some(_)` so dedup
    /// fires; callers that need to differentiate can inspect the blob
    /// length.
    ///
    /// Uses `INSERT OR IGNORE`: if another code path has already recorded
    /// success for this wrapper, we keep the success row intact.
    ///
    /// # Errors
    ///
    /// Returns an error if the database lock cannot be acquired or the
    /// `INSERT` fails.
    pub fn record_gift_wrap_failure(
        &self,
        wrapper_event_id: &EventId,
        processed_at: i64,
    ) -> Result<()> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        conn.execute(
            "INSERT OR IGNORE INTO processed_gift_wraps \
             (wrapper_event_id, mls_group_id, processed_at) \
             VALUES (?1, ?2, ?3)",
            params![wrapper_event_id.as_bytes(), &[] as &[u8], processed_at],
        )?;
        Ok(())
    }

    /// Deletes the dedup row for a gift-wrap wrapper event ID.
    ///
    /// Only available in tests. Used to simulate the crash-recovery scenario
    /// where the `processed_gift_wraps` row is absent but the membership
    /// (written in the same transaction) survived — e.g., because an external
    /// tool or migration deleted only the dedup row.
    ///
    /// # Errors
    ///
    /// Returns an error if the database lock cannot be acquired or the
    /// `DELETE` statement fails.
    #[cfg(test)]
    pub fn delete_gift_wrap_dedup_row(&self, wrapper_event_id: &EventId) -> Result<()> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;
        conn.execute(
            "DELETE FROM processed_gift_wraps WHERE wrapper_event_id = ?1",
            params![wrapper_event_id.as_bytes()],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_circle(id: u8) -> Circle {
        Circle {
            mls_group_id: GroupId::from_slice(&[id; 32]),
            nostr_group_id: [id; 32],
            display_name: format!("Test Circle {id}"),
            circle_type: CircleType::LocationSharing,
            relays: vec![
                "wss://relay.damus.io".to_string(),
                "wss://relay.primal.net".to_string(),
            ],
            created_at: 1_000_000 + i64::from(id),
            updated_at: 2_000_000 + i64::from(id),
        }
    }

    fn create_test_membership(id: u8) -> CircleMembership {
        CircleMembership {
            mls_group_id: GroupId::from_slice(&[id; 32]),
            status: MembershipStatus::Pending,
            inviter_pubkey: Some(format!("{:064x}", id)),
            invited_at: 1_000_000,
            responded_at: None,
        }
    }

    fn create_test_contact(id: u8) -> Contact {
        Contact {
            pubkey: format!("{:064x}", id),
            display_name: Some(format!("Contact {id}")),
            avatar_path: Some(format!("/path/to/avatar_{id}.jpg")),
            notes: Some(format!("Notes for contact {id}")),
            created_at: 1_000_000,
            updated_at: 2_000_000,
        }
    }

    // ==================== Circle Tests ====================

    #[test]
    fn save_and_get_circle() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = create_test_circle(1);

        storage.save_circle(&circle).unwrap();
        let retrieved = storage.get_circle(&circle.mls_group_id).unwrap().unwrap();

        assert_eq!(
            retrieved.mls_group_id.as_slice(),
            circle.mls_group_id.as_slice()
        );
        assert_eq!(retrieved.nostr_group_id, circle.nostr_group_id);
        assert_eq!(retrieved.display_name, circle.display_name);
        assert_eq!(retrieved.circle_type, circle.circle_type);
        assert_eq!(retrieved.created_at, circle.created_at);
        assert_eq!(retrieved.updated_at, circle.updated_at);
    }

    #[test]
    fn get_nonexistent_circle_returns_none() {
        let storage = CircleStorage::in_memory().unwrap();
        let result = storage.get_circle(&GroupId::from_slice(&[99; 32])).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn save_circle_updates_existing() {
        let storage = CircleStorage::in_memory().unwrap();
        let mut circle = create_test_circle(1);

        storage.save_circle(&circle).unwrap();

        circle.display_name = "Updated Name".to_string();
        circle.updated_at = 3_000_000;
        storage.save_circle(&circle).unwrap();

        let retrieved = storage.get_circle(&circle.mls_group_id).unwrap().unwrap();
        assert_eq!(retrieved.display_name, "Updated Name");
        assert_eq!(retrieved.updated_at, 3_000_000);
    }

    #[test]
    fn get_all_circles_ordered_by_updated_at() {
        let storage = CircleStorage::in_memory().unwrap();

        let circle1 = Circle {
            updated_at: 1_000_000,
            ..create_test_circle(1)
        };
        let circle2 = Circle {
            updated_at: 3_000_000,
            ..create_test_circle(2)
        };
        let circle3 = Circle {
            updated_at: 2_000_000,
            ..create_test_circle(3)
        };

        storage.save_circle(&circle1).unwrap();
        storage.save_circle(&circle2).unwrap();
        storage.save_circle(&circle3).unwrap();

        let circles = storage.get_all_circles().unwrap();
        assert_eq!(circles.len(), 3);
        // Should be ordered by updated_at DESC
        assert_eq!(circles[0].updated_at, 3_000_000);
        assert_eq!(circles[1].updated_at, 2_000_000);
        assert_eq!(circles[2].updated_at, 1_000_000);
    }

    #[test]
    fn delete_circle_removes_all_related_data() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = create_test_circle(1);
        let membership = create_test_membership(1);
        let ui_state = CircleUiState {
            mls_group_id: GroupId::from_slice(&[1; 32]),
            last_read_message_id: Some("msg123".to_string()),
            pin_order: Some(1),
            is_muted: false,
        };

        storage.save_circle(&circle).unwrap();
        storage.save_membership(&membership).unwrap();
        storage.save_ui_state(&ui_state).unwrap();

        storage.delete_circle(&circle.mls_group_id).unwrap();

        assert!(storage.get_circle(&circle.mls_group_id).unwrap().is_none());
        assert!(storage
            .get_membership(&circle.mls_group_id)
            .unwrap()
            .is_none());
        assert!(storage
            .get_ui_state(&circle.mls_group_id)
            .unwrap()
            .is_none());
    }

    #[test]
    fn circle_type_direct_share() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = Circle {
            circle_type: CircleType::DirectShare,
            ..create_test_circle(1)
        };

        storage.save_circle(&circle).unwrap();
        let retrieved = storage.get_circle(&circle.mls_group_id).unwrap().unwrap();
        assert_eq!(retrieved.circle_type, CircleType::DirectShare);
    }

    // ==================== Membership Tests ====================

    #[test]
    fn save_and_get_membership() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = create_test_circle(1);
        let membership = create_test_membership(1);

        storage.save_circle(&circle).unwrap();
        storage.save_membership(&membership).unwrap();

        let retrieved = storage
            .get_membership(&membership.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(retrieved.status, MembershipStatus::Pending);
        assert_eq!(retrieved.inviter_pubkey, membership.inviter_pubkey);
        assert_eq!(retrieved.invited_at, membership.invited_at);
        assert!(retrieved.responded_at.is_none());
    }

    #[test]
    fn update_membership_status() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = create_test_circle(1);
        let membership = create_test_membership(1);

        storage.save_circle(&circle).unwrap();
        storage.save_membership(&membership).unwrap();

        let now = 3_000_000_i64;
        storage
            .update_membership_status(
                &membership.mls_group_id,
                MembershipStatus::Accepted,
                Some(now),
            )
            .unwrap();

        let retrieved = storage
            .get_membership(&membership.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(retrieved.status, MembershipStatus::Accepted);
        assert_eq!(retrieved.responded_at, Some(now));
    }

    #[test]
    fn update_membership_status_nonexistent_fails() {
        let storage = CircleStorage::in_memory().unwrap();
        let result = storage.update_membership_status(
            &GroupId::from_slice(&[99; 32]),
            MembershipStatus::Accepted,
            None,
        );
        assert!(result.is_err());
    }

    #[test]
    fn membership_status_declined() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = create_test_circle(1);
        let mut membership = create_test_membership(1);
        membership.status = MembershipStatus::Declined;
        membership.responded_at = Some(2_000_000);

        storage.save_circle(&circle).unwrap();
        storage.save_membership(&membership).unwrap();

        let retrieved = storage
            .get_membership(&membership.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(retrieved.status, MembershipStatus::Declined);
        assert_eq!(retrieved.responded_at, Some(2_000_000));
    }

    // ==================== Contact Tests ====================

    #[test]
    fn save_and_get_contact() {
        let storage = CircleStorage::in_memory().unwrap();
        let contact = create_test_contact(1);

        storage.save_contact(&contact).unwrap();
        let retrieved = storage.get_contact(&contact.pubkey).unwrap().unwrap();

        assert_eq!(retrieved.pubkey, contact.pubkey);
        assert_eq!(retrieved.display_name, contact.display_name);
        assert_eq!(retrieved.avatar_path, contact.avatar_path);
        assert_eq!(retrieved.notes, contact.notes);
    }

    #[test]
    fn get_nonexistent_contact_returns_none() {
        let storage = CircleStorage::in_memory().unwrap();
        let result = storage.get_contact("nonexistent").unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn save_contact_updates_existing() {
        let storage = CircleStorage::in_memory().unwrap();
        let mut contact = create_test_contact(1);

        storage.save_contact(&contact).unwrap();

        contact.display_name = Some("Updated Name".to_string());
        contact.updated_at = 3_000_000;
        storage.save_contact(&contact).unwrap();

        let retrieved = storage.get_contact(&contact.pubkey).unwrap().unwrap();
        assert_eq!(retrieved.display_name, Some("Updated Name".to_string()));
        assert_eq!(retrieved.updated_at, 3_000_000);
    }

    #[test]
    fn contact_with_no_optional_fields() {
        let storage = CircleStorage::in_memory().unwrap();
        let contact = Contact {
            pubkey: "abc123".to_string(),
            display_name: None,
            avatar_path: None,
            notes: None,
            created_at: 1_000_000,
            updated_at: 2_000_000,
        };

        storage.save_contact(&contact).unwrap();
        let retrieved = storage.get_contact(&contact.pubkey).unwrap().unwrap();

        assert!(retrieved.display_name.is_none());
        assert!(retrieved.avatar_path.is_none());
        assert!(retrieved.notes.is_none());
    }

    #[test]
    fn get_all_contacts_ordered() {
        let storage = CircleStorage::in_memory().unwrap();

        let contact1 = Contact {
            pubkey: "aaa".to_string(),
            display_name: Some("Zoe".to_string()),
            ..create_test_contact(1)
        };
        let contact2 = Contact {
            pubkey: "bbb".to_string(),
            display_name: Some("Alice".to_string()),
            ..create_test_contact(2)
        };
        let contact3 = Contact {
            pubkey: "ccc".to_string(),
            display_name: None,
            ..create_test_contact(3)
        };

        storage.save_contact(&contact1).unwrap();
        storage.save_contact(&contact2).unwrap();
        storage.save_contact(&contact3).unwrap();

        let contacts = storage.get_all_contacts().unwrap();
        assert_eq!(contacts.len(), 3);
        // Should be ordered by display_name (NULLS LAST), then pubkey
        assert_eq!(contacts[0].display_name, Some("Alice".to_string()));
        assert_eq!(contacts[1].display_name, Some("Zoe".to_string()));
        assert!(contacts[2].display_name.is_none());
    }

    #[test]
    fn delete_contact() {
        let storage = CircleStorage::in_memory().unwrap();
        let contact = create_test_contact(1);

        storage.save_contact(&contact).unwrap();
        storage.delete_contact(&contact.pubkey).unwrap();

        assert!(storage.get_contact(&contact.pubkey).unwrap().is_none());
    }

    #[test]
    fn delete_nonexistent_contact_succeeds() {
        let storage = CircleStorage::in_memory().unwrap();
        // Should not error even if contact doesn't exist
        storage.delete_contact("nonexistent").unwrap();
    }

    // ==================== UI State Tests ====================

    #[test]
    fn save_and_get_ui_state() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = create_test_circle(1);
        let ui_state = CircleUiState {
            mls_group_id: GroupId::from_slice(&[1; 32]),
            last_read_message_id: Some("msg123".to_string()),
            pin_order: Some(5),
            is_muted: true,
        };

        storage.save_circle(&circle).unwrap();
        storage.save_ui_state(&ui_state).unwrap();

        let retrieved = storage
            .get_ui_state(&ui_state.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(retrieved.last_read_message_id, Some("msg123".to_string()));
        assert_eq!(retrieved.pin_order, Some(5));
        assert!(retrieved.is_muted);
    }

    #[test]
    fn get_nonexistent_ui_state_returns_none() {
        let storage = CircleStorage::in_memory().unwrap();
        let result = storage
            .get_ui_state(&GroupId::from_slice(&[99; 32]))
            .unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn save_ui_state_updates_existing() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = create_test_circle(1);
        let mut ui_state = CircleUiState {
            mls_group_id: GroupId::from_slice(&[1; 32]),
            last_read_message_id: Some("msg123".to_string()),
            pin_order: Some(5),
            is_muted: false,
        };

        storage.save_circle(&circle).unwrap();
        storage.save_ui_state(&ui_state).unwrap();

        ui_state.last_read_message_id = Some("msg456".to_string());
        ui_state.is_muted = true;
        storage.save_ui_state(&ui_state).unwrap();

        let retrieved = storage
            .get_ui_state(&ui_state.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(retrieved.last_read_message_id, Some("msg456".to_string()));
        assert!(retrieved.is_muted);
    }

    #[test]
    fn ui_state_with_no_optional_fields() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = create_test_circle(1);
        let ui_state = CircleUiState {
            mls_group_id: GroupId::from_slice(&[1; 32]),
            last_read_message_id: None,
            pin_order: None,
            is_muted: false,
        };

        storage.save_circle(&circle).unwrap();
        storage.save_ui_state(&ui_state).unwrap();

        let retrieved = storage
            .get_ui_state(&ui_state.mls_group_id)
            .unwrap()
            .unwrap();
        assert!(retrieved.last_read_message_id.is_none());
        assert!(retrieved.pin_order.is_none());
        assert!(!retrieved.is_muted);
    }

    // ==================== Encryption Tests ====================

    /// Generates a test hex key (64 hex chars = 32 bytes).
    fn test_hex_key() -> String {
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".to_string()
    }

    #[test]
    fn new_encrypted_creates_database() {
        let dir = tempfile::TempDir::new().unwrap();
        let db_path = dir.path().join("encrypted_test.db");

        let storage = CircleStorage::new(&db_path, Some(&test_hex_key()))
            .expect("should create encrypted DB");

        // Verify basic operations work
        let circles = storage.get_all_circles().unwrap();
        assert!(circles.is_empty());
    }

    #[test]
    fn encrypted_db_stores_and_retrieves_data() {
        let dir = tempfile::TempDir::new().unwrap();
        let db_path = dir.path().join("encrypted_data.db");
        let key = test_hex_key();

        // Create encrypted DB and store data
        {
            let storage =
                CircleStorage::new(&db_path, Some(&key)).expect("should create encrypted DB");
            let circle = create_test_circle(1);
            storage.save_circle(&circle).unwrap();
        }

        // Reopen and verify data persists
        {
            let storage =
                CircleStorage::new(&db_path, Some(&key)).expect("should reopen encrypted DB");
            let circles = storage.get_all_circles().unwrap();
            assert_eq!(circles.len(), 1);
            assert_eq!(circles[0].display_name, "Test Circle 1");
        }
    }

    #[test]
    fn encrypted_db_wrong_key_cannot_read() {
        let dir = tempfile::TempDir::new().unwrap();
        let db_path = dir.path().join("encrypted_wrong_key.db");
        let key1 = test_hex_key();
        let key2 = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789".to_string();

        // Create encrypted DB with key1
        {
            let storage =
                CircleStorage::new(&db_path, Some(&key1)).expect("should create encrypted DB");
            let circle = create_test_circle(1);
            storage.save_circle(&circle).unwrap();
        }

        // Attempt to open with key2 — should trigger migration (treats as unencrypted)
        // which will fail because the DB is encrypted, not unencrypted
        let result = CircleStorage::new(&db_path, Some(&key2));
        // The migration attempt should fail (can't read encrypted DB without key)
        assert!(
            result.is_err(),
            "Wrong key should fail to open encrypted DB"
        );
    }

    #[test]
    fn migrate_unencrypted_to_encrypted() {
        let dir = tempfile::TempDir::new().unwrap();
        let db_path = dir.path().join("migrate_test.db");
        let key = test_hex_key();

        // Create unencrypted DB with data
        {
            let storage = CircleStorage::new(&db_path, None).expect("should create unencrypted DB");
            let circle = create_test_circle(1);
            storage.save_circle(&circle).unwrap();
            let contact = create_test_contact(2);
            storage.save_contact(&contact).unwrap();
        }

        // Reopen with encryption — should auto-migrate
        {
            let storage =
                CircleStorage::new(&db_path, Some(&key)).expect("should migrate to encrypted DB");
            let circles = storage.get_all_circles().unwrap();
            assert_eq!(circles.len(), 1, "Circle data should survive migration");
            assert_eq!(circles[0].display_name, "Test Circle 1");

            let contacts = storage.get_all_contacts().unwrap();
            assert_eq!(contacts.len(), 1, "Contact data should survive migration");
        }

        // Verify the DB is now encrypted (can reopen with key)
        {
            let storage = CircleStorage::new(&db_path, Some(&key))
                .expect("should reopen encrypted DB after migration");
            let circles = storage.get_all_circles().unwrap();
            assert_eq!(circles.len(), 1);
        }
    }

    #[test]
    fn unencrypted_db_still_works() {
        let dir = tempfile::TempDir::new().unwrap();
        let db_path = dir.path().join("unencrypted_test.db");

        let storage = CircleStorage::new(&db_path, None).expect("should create unencrypted DB");
        let circle = create_test_circle(1);
        storage.save_circle(&circle).unwrap();

        let retrieved = storage.get_all_circles().unwrap();
        assert_eq!(retrieved.len(), 1);
    }

    #[test]
    fn rejects_invalid_hex_key_too_short() {
        let dir = tempfile::TempDir::new().unwrap();
        let db_path = dir.path().join("bad_key.db");

        let result = CircleStorage::new(&db_path, Some("abcdef"));
        let err = match result {
            Err(e) => e.to_string(),
            Ok(_) => panic!("Should reject key shorter than 64 chars"),
        };
        assert!(
            err.contains("64 hex characters"),
            "Error should mention expected format: {err}"
        );
    }

    #[test]
    fn rejects_invalid_hex_key_non_hex() {
        let dir = tempfile::TempDir::new().unwrap();
        let db_path = dir.path().join("bad_key2.db");

        // 64 chars but contains 'g' which is not a hex digit
        let bad_key = "g123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let result = CircleStorage::new(&db_path, Some(bad_key));
        assert!(result.is_err(), "Should reject non-hex characters");
    }

    #[test]
    fn rejects_invalid_hex_key_too_long() {
        let dir = tempfile::TempDir::new().unwrap();
        let db_path = dir.path().join("bad_key3.db");

        // 65 hex chars (one too many)
        let long_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0";
        let result = CircleStorage::new(&db_path, Some(long_key));
        assert!(result.is_err(), "Should reject key longer than 64 chars");
    }

    #[test]
    fn migration_does_not_corrupt_encrypted_db() {
        let dir = tempfile::TempDir::new().unwrap();
        let db_path = dir.path().join("no_corrupt.db");
        let key1 = test_hex_key();
        let key2 = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789".to_string();

        // Create encrypted DB with key1 and store data
        {
            let storage =
                CircleStorage::new(&db_path, Some(&key1)).expect("should create encrypted DB");
            let circle = create_test_circle(1);
            storage.save_circle(&circle).unwrap();
        }

        // Attempt to open with key2 — should fail with clear error, NOT corrupt the DB
        let result = CircleStorage::new(&db_path, Some(&key2));
        let err = match result {
            Err(e) => e.to_string(),
            Ok(_) => panic!("Wrong key should fail"),
        };
        assert!(
            err.contains("different key"),
            "Error should indicate wrong key: {err}"
        );

        // Verify key1 still works — DB was not corrupted
        {
            let storage =
                CircleStorage::new(&db_path, Some(&key1)).expect("DB should still work with key1");
            let circles = storage.get_all_circles().unwrap();
            assert_eq!(
                circles.len(),
                1,
                "Data should be intact after wrong-key attempt"
            );
        }
    }

    #[test]
    fn no_temp_file_left_after_migration() {
        let dir = tempfile::TempDir::new().unwrap();
        let db_path = dir.path().join("clean_migrate.db");
        let temp_path = db_path.with_extension("db.encrypting");
        let key = test_hex_key();

        // Create unencrypted DB
        {
            let storage = CircleStorage::new(&db_path, None).expect("should create unencrypted DB");
            let circle = create_test_circle(1);
            storage.save_circle(&circle).unwrap();
        }

        // Migrate to encrypted
        CircleStorage::new(&db_path, Some(&key)).expect("should migrate");

        // Verify no temp file left behind
        assert!(
            !temp_path.exists(),
            "Temp file should be cleaned up after successful migration"
        );
    }

    // ==================== Last-Known Location Tests ====================

    fn create_test_last_known(
        group_id_byte: u8,
        sender: &str,
        timestamp: i64,
    ) -> LastKnownLocation {
        LastKnownLocation {
            nostr_group_id: [group_id_byte; 32],
            sender_pubkey: sender.to_string(),
            latitude: 40.7128,
            longitude: -74.0060,
            geohash: "dr5regw".to_string(),
            display_name: Some("Alice".to_string()),
            timestamp,
            expires_at: timestamp + 900,
            purge_after: timestamp + 24 * 60 * 60,
            updated_at: timestamp,
        }
    }

    #[test]
    fn last_known_upsert_and_snapshot() {
        let storage = CircleStorage::in_memory().unwrap();
        let loc = create_test_last_known(1, "alice_pubkey", 1_000_000);

        storage.upsert_last_known_location(&loc).unwrap();

        let snapshot = storage
            .snapshot_last_known_for_circle(&[1; 32], 1_000_000)
            .unwrap();
        assert_eq!(snapshot.len(), 1);
        assert_eq!(snapshot[0], loc);
    }

    #[test]
    fn last_known_upsert_ignores_older_timestamp() {
        let storage = CircleStorage::in_memory().unwrap();
        let newer = create_test_last_known(1, "alice", 2_000_000);
        let older = create_test_last_known(1, "alice", 1_000_000);

        storage.upsert_last_known_location(&newer).unwrap();
        storage.upsert_last_known_location(&older).unwrap();

        let snapshot = storage.snapshot_last_known_for_circle(&[1; 32], 0).unwrap();
        assert_eq!(snapshot.len(), 1);
        assert_eq!(snapshot[0].timestamp, 2_000_000);
    }

    #[test]
    fn last_known_upsert_updates_on_newer_timestamp() {
        let storage = CircleStorage::in_memory().unwrap();
        let mut loc = create_test_last_known(1, "alice", 1_000_000);
        storage.upsert_last_known_location(&loc).unwrap();

        loc.timestamp = 2_000_000;
        loc.latitude = 41.0;
        loc.purge_after = 2_000_000 + 3600;
        storage.upsert_last_known_location(&loc).unwrap();

        let snapshot = storage.snapshot_last_known_for_circle(&[1; 32], 0).unwrap();
        assert_eq!(snapshot.len(), 1);
        assert_eq!(snapshot[0].timestamp, 2_000_000);
        assert!((snapshot[0].latitude - 41.0).abs() < f64::EPSILON);
    }

    #[test]
    fn last_known_snapshot_filters_purged_rows() {
        let storage = CircleStorage::in_memory().unwrap();
        let mut loc = create_test_last_known(1, "alice", 1_000_000);
        loc.purge_after = 1_500_000;
        storage.upsert_last_known_location(&loc).unwrap();

        // now = 1_400_000: still retained
        let snap_live = storage
            .snapshot_last_known_for_circle(&[1; 32], 1_400_000)
            .unwrap();
        assert_eq!(snap_live.len(), 1);

        // now = 1_600_000: past purge_after, filtered out
        let snap_dead = storage
            .snapshot_last_known_for_circle(&[1; 32], 1_600_000)
            .unwrap();
        assert_eq!(snap_dead.len(), 0);
    }

    #[test]
    fn last_known_snapshot_scopes_by_group_id() {
        let storage = CircleStorage::in_memory().unwrap();
        let loc_a = create_test_last_known(1, "alice", 1_000_000);
        let loc_b = create_test_last_known(2, "bob", 1_000_000);
        storage.upsert_last_known_location(&loc_a).unwrap();
        storage.upsert_last_known_location(&loc_b).unwrap();

        let snap_a = storage.snapshot_last_known_for_circle(&[1; 32], 0).unwrap();
        assert_eq!(snap_a.len(), 1);
        assert_eq!(snap_a[0].sender_pubkey, "alice");

        let snap_b = storage.snapshot_last_known_for_circle(&[2; 32], 0).unwrap();
        assert_eq!(snap_b.len(), 1);
        assert_eq!(snap_b[0].sender_pubkey, "bob");
    }

    #[test]
    fn last_known_snapshot_orders_by_timestamp_desc() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_last_known_location(&create_test_last_known(1, "alice", 1_000_000))
            .unwrap();
        storage
            .upsert_last_known_location(&create_test_last_known(1, "bob", 3_000_000))
            .unwrap();
        storage
            .upsert_last_known_location(&create_test_last_known(1, "carol", 2_000_000))
            .unwrap();

        let snap = storage.snapshot_last_known_for_circle(&[1; 32], 0).unwrap();
        assert_eq!(snap.len(), 3);
        assert_eq!(snap[0].sender_pubkey, "bob");
        assert_eq!(snap[1].sender_pubkey, "carol");
        assert_eq!(snap[2].sender_pubkey, "alice");
    }

    #[test]
    fn remove_last_known_member_deletes_only_that_sender() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_last_known_location(&create_test_last_known(1, "alice", 1_000_000))
            .unwrap();
        storage
            .upsert_last_known_location(&create_test_last_known(1, "bob", 1_000_000))
            .unwrap();

        storage.remove_last_known_member(&[1; 32], "alice").unwrap();

        let snap = storage.snapshot_last_known_for_circle(&[1; 32], 0).unwrap();
        assert_eq!(snap.len(), 1);
        assert_eq!(snap[0].sender_pubkey, "bob");
    }

    #[test]
    fn remove_last_known_circle_deletes_all_senders_in_group() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_last_known_location(&create_test_last_known(1, "alice", 1_000_000))
            .unwrap();
        storage
            .upsert_last_known_location(&create_test_last_known(1, "bob", 1_000_000))
            .unwrap();
        storage
            .upsert_last_known_location(&create_test_last_known(2, "carol", 1_000_000))
            .unwrap();

        storage.remove_last_known_circle(&[1; 32]).unwrap();

        assert_eq!(
            storage
                .snapshot_last_known_for_circle(&[1; 32], 0)
                .unwrap()
                .len(),
            0
        );
        assert_eq!(
            storage
                .snapshot_last_known_for_circle(&[2; 32], 0)
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn wipe_all_last_known_locations_empties_table() {
        let storage = CircleStorage::in_memory().unwrap();
        storage
            .upsert_last_known_location(&create_test_last_known(1, "alice", 1_000_000))
            .unwrap();
        storage
            .upsert_last_known_location(&create_test_last_known(2, "bob", 1_000_000))
            .unwrap();

        storage.wipe_all_last_known_locations().unwrap();

        assert_eq!(
            storage
                .snapshot_last_known_for_circle(&[1; 32], 0)
                .unwrap()
                .len(),
            0
        );
        assert_eq!(
            storage
                .snapshot_last_known_for_circle(&[2; 32], 0)
                .unwrap()
                .len(),
            0
        );
    }

    #[test]
    fn prune_expired_last_known_returns_count_and_removes_rows() {
        let storage = CircleStorage::in_memory().unwrap();
        let mut expired = create_test_last_known(1, "alice", 1_000_000);
        expired.purge_after = 1_500_000;
        let mut live = create_test_last_known(1, "bob", 1_000_000);
        live.purge_after = 2_500_000;

        storage.upsert_last_known_location(&expired).unwrap();
        storage.upsert_last_known_location(&live).unwrap();

        let removed = storage.prune_expired_last_known(2_000_000).unwrap();
        assert_eq!(removed, 1);

        // Snapshot with now=0 (no filtering) still shows only the live row.
        let snap = storage.snapshot_last_known_for_circle(&[1; 32], 0).unwrap();
        assert_eq!(snap.len(), 1);
        assert_eq!(snap[0].sender_pubkey, "bob");
    }

    #[test]
    fn delete_circle_cascades_to_last_known_locations() {
        let storage = CircleStorage::in_memory().unwrap();
        let circle = create_test_circle(1);
        storage.save_circle(&circle).unwrap();
        storage
            .upsert_last_known_location(&create_test_last_known(1, "alice", 1_000_000))
            .unwrap();

        storage.delete_circle(&circle.mls_group_id).unwrap();

        let snap = storage.snapshot_last_known_for_circle(&[1; 32], 0).unwrap();
        assert_eq!(snap.len(), 0);
    }

    #[test]
    fn last_known_persists_across_instances_with_sqlcipher() {
        use tempfile::TempDir;
        let tmp = TempDir::new().unwrap();
        let db_path = tmp.path().join("circles.db");
        let key = test_hex_key();

        {
            let storage = CircleStorage::new(&db_path, Some(&key)).unwrap();
            storage
                .upsert_last_known_location(&create_test_last_known(1, "alice", 1_000_000))
                .unwrap();
        }
        {
            let storage = CircleStorage::new(&db_path, Some(&key)).unwrap();
            let snap = storage.snapshot_last_known_for_circle(&[1; 32], 0).unwrap();
            assert_eq!(snap.len(), 1);
            assert_eq!(snap[0].sender_pubkey, "alice");
        }
    }
    // ==================== Gift Wrap Idempotency Tests ====================

    #[test]
    fn is_gift_wrap_processed_returns_none_for_unknown_id() {
        let storage = CircleStorage::in_memory().unwrap();
        let wrapper_id = nostr::EventId::all_zeros();

        let result = storage.is_gift_wrap_processed(&wrapper_id).unwrap();

        assert!(
            result.is_none(),
            "Unknown wrapper event ID should return None"
        );
    }

    #[test]
    fn record_processed_invitation_and_is_gift_wrap_processed_roundtrip() {
        let storage = CircleStorage::in_memory().unwrap();

        // Use a distinct byte pattern so the test doesn't collide with all-zero IDs.
        let wrapper_bytes = [0xCA; 32];
        let wrapper_id = nostr::EventId::from_byte_array(wrapper_bytes);

        let circle = create_test_circle(1);
        let membership = create_test_membership(1);
        let processed_at = 1_700_000_000_i64;

        // Nothing stored yet.
        assert!(
            storage
                .is_gift_wrap_processed(&wrapper_id)
                .unwrap()
                .is_none(),
            "should be None before recording"
        );

        storage
            .record_processed_invitation(&wrapper_id, &circle, &membership, processed_at)
            .unwrap();

        // After recording, the call must return the associated mls_group_id.
        let stored_group_id = storage
            .is_gift_wrap_processed(&wrapper_id)
            .unwrap()
            .expect("should return Some after recording");

        assert_eq!(
            stored_group_id,
            circle.mls_group_id.as_slice(),
            "stored mls_group_id must match the circle's group ID"
        );
    }

    #[test]
    fn record_processed_invitation_also_persists_circle_and_membership() {
        let storage = CircleStorage::in_memory().unwrap();
        let wrapper_id = nostr::EventId::from_byte_array([0xBB; 32]);
        let circle = create_test_circle(2);
        let membership = create_test_membership(2);
        let now = 1_700_000_001_i64;

        storage
            .record_processed_invitation(&wrapper_id, &circle, &membership, now)
            .unwrap();

        // Circle row must be present.
        let got_circle = storage
            .get_circle(&circle.mls_group_id)
            .unwrap()
            .expect("circle row must exist after record_processed_invitation");
        assert_eq!(got_circle.display_name, circle.display_name);

        // Membership row must be present and Pending.
        let got_membership = storage
            .get_membership(&circle.mls_group_id)
            .unwrap()
            .expect("membership row must exist after record_processed_invitation");
        assert_eq!(got_membership.status, MembershipStatus::Pending);
    }

    #[test]
    fn record_processed_invitation_duplicate_wrapper_id_is_rejected() {
        let storage = CircleStorage::in_memory().unwrap();
        let wrapper_id = nostr::EventId::from_byte_array([0xDD; 32]);

        // First call with circle-1 succeeds.
        let circle1 = create_test_circle(1);
        let membership1 = create_test_membership(1);
        storage
            .record_processed_invitation(&wrapper_id, &circle1, &membership1, 1_000_000)
            .unwrap();

        // Second call with the SAME wrapper_id (different circle byte) must fail on
        // the PRIMARY KEY constraint for processed_gift_wraps.
        let circle2 = create_test_circle(2);
        let membership2 = create_test_membership(2);
        let result =
            storage.record_processed_invitation(&wrapper_id, &circle2, &membership2, 2_000_000);

        assert!(
            result.is_err(),
            "Duplicate wrapper_event_id must be rejected (PRIMARY KEY violation)"
        );

        // The first call's rows must be intact after the failed second call.
        let stored_group_id = storage
            .is_gift_wrap_processed(&wrapper_id)
            .unwrap()
            .expect("first call's dedup row must survive the failed second call");
        assert_eq!(
            stored_group_id,
            circle1.mls_group_id.as_slice(),
            "dedup row must still point to circle1 after failed second call"
        );

        // circle1 still present, circle2 absent (transaction was rolled back).
        assert!(
            storage.get_circle(&circle1.mls_group_id).unwrap().is_some(),
            "circle1 row must survive the rolled-back second call"
        );
        assert!(
            storage.get_circle(&circle2.mls_group_id).unwrap().is_none(),
            "circle2 must not exist — second transaction was rolled back"
        );

        // membership1 still present.
        assert!(
            storage
                .get_membership(&circle1.mls_group_id)
                .unwrap()
                .is_some(),
            "membership1 must survive the rolled-back second call"
        );
    }

    #[test]
    fn record_gift_wrap_failure_stores_empty_group_id_sentinel() {
        let storage = CircleStorage::in_memory().unwrap();
        let wrapper_id = nostr::EventId::from_byte_array([0xEE; 32]);

        storage
            .record_gift_wrap_failure(&wrapper_id, 1_700_000_000)
            .unwrap();

        // After recording, is_gift_wrap_processed must return Some(empty_blob)
        // so the dedup guard fires, but the empty blob lets callers distinguish
        // a terminal-failure row from a real success row.
        let stored = storage
            .is_gift_wrap_processed(&wrapper_id)
            .unwrap()
            .expect("failure sentinel must be readable as processed");
        assert!(
            stored.is_empty(),
            "failure sentinel must store an empty blob for mls_group_id, got {} bytes",
            stored.len(),
        );

        // The associated circle + membership must NOT exist — the sentinel is
        // purely a dedup marker, not a circle record.
        // (We can't check by mls_group_id since we have no real one; instead
        // verify the caller-visible invariant: the dedup row exists.)
    }

    #[test]
    fn record_gift_wrap_failure_does_not_overwrite_success_row() {
        let storage = CircleStorage::in_memory().unwrap();
        let wrapper_id = nostr::EventId::from_byte_array([0xAB; 32]);
        let circle = create_test_circle(7);
        let membership = create_test_membership(7);

        // Record a successful invitation first.
        storage
            .record_processed_invitation(&wrapper_id, &circle, &membership, 1_000)
            .unwrap();

        // Now call record_gift_wrap_failure with the SAME wrapper_id — this
        // simulates a second, separate invitation path erroring on MDK for
        // the same wrapper (e.g., concurrent pollers). INSERT OR IGNORE must
        // preserve the success row.
        storage
            .record_gift_wrap_failure(&wrapper_id, 2_000)
            .unwrap();

        let stored = storage
            .is_gift_wrap_processed(&wrapper_id)
            .unwrap()
            .expect("dedup row must still exist");
        assert_eq!(
            stored,
            circle.mls_group_id.as_slice(),
            "success row's mls_group_id must survive a later failure sentinel attempt"
        );
    }

    #[test]
    fn record_gift_wrap_failure_is_idempotent() {
        let storage = CircleStorage::in_memory().unwrap();
        let wrapper_id = nostr::EventId::from_byte_array([0x77; 32]);

        // Two consecutive failure sentinels for the same wrapper must both
        // succeed (INSERT OR IGNORE) — e.g., poller may retry across sessions
        // if the app crashes between MDK failure and the sentinel insert.
        storage
            .record_gift_wrap_failure(&wrapper_id, 1_000)
            .unwrap();
        storage
            .record_gift_wrap_failure(&wrapper_id, 2_000)
            .unwrap();

        let stored = storage
            .is_gift_wrap_processed(&wrapper_id)
            .unwrap()
            .expect("sentinel row must exist");
        assert!(stored.is_empty());
    }
}

// ==================== Proptest: Gift Wrap Idempotency ====================
// These live outside the `mod tests` block so they can import proptest
// without bumping into the `#[cfg(test)]` attribute.

#[cfg(test)]
mod proptest_gift_wrap {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #![proptest_config(proptest::test_runner::Config::with_cases(50))]

        /// For any 32-byte wrapper event ID and any 32-byte group ID, round-
        /// tripping through `record_processed_invitation` →
        /// `is_gift_wrap_processed` returns exactly the bytes stored as the
        /// circle's `mls_group_id`. This guards against byte-layout bugs
        /// (endianness, truncation, off-by-one) in the BLOB column handling.
        #[test]
        fn roundtrip_preserves_mls_group_id(
            wrapper_bytes in prop::array::uniform32(0u8..),
            group_id_bytes in prop::array::uniform32(0u8..),
        ) {
            let storage = CircleStorage::in_memory().unwrap();
            let wrapper_id = nostr::EventId::from_byte_array(wrapper_bytes);

            // Build a circle whose mls_group_id is exactly `group_id_bytes`.
            let circle = Circle {
                mls_group_id: GroupId::from_slice(&group_id_bytes),
                nostr_group_id: [0x42; 32],
                display_name: "Proptest Circle".to_string(),
                circle_type: CircleType::LocationSharing,
                relays: vec![],
                created_at: 1_000_000,
                updated_at: 1_000_000,
            };
            let membership = CircleMembership {
                mls_group_id: GroupId::from_slice(&group_id_bytes),
                status: MembershipStatus::Pending,
                inviter_pubkey: None,
                invited_at: 1_000_000,
                responded_at: None,
            };

            storage
                .record_processed_invitation(&wrapper_id, &circle, &membership, 1_000_000)
                .unwrap();

            let stored = storage
                .is_gift_wrap_processed(&wrapper_id)
                .unwrap()
                .expect("must return Some after recording");

            prop_assert_eq!(
                stored,
                group_id_bytes.to_vec(),
                "stored mls_group_id must match the original group_id_bytes exactly"
            );
        }
    }
}
