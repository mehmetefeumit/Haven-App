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

use super::error::{CircleError, Result};
use super::types::{
    Circle, CircleMembership, CircleType, CircleUiState, Contact, MembershipStatus,
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
    /// Creates a new storage instance at the given path.
    ///
    /// Creates the database file and tables if they don't exist.
    ///
    /// # Errors
    ///
    /// Returns an error if the database cannot be created or initialized.
    pub fn new(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)?;
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
    pub fn delete_circle(&self, mls_group_id: &GroupId) -> Result<()> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| CircleError::Storage(format!("Failed to acquire database lock: {e}")))?;

        // Delete in order respecting foreign key constraints
        conn.execute(
            "DELETE FROM circle_ui_state WHERE mls_group_id = ?1",
            params![mls_group_id.as_slice()],
        )?;
        conn.execute(
            "DELETE FROM circle_memberships WHERE mls_group_id = ?1",
            params![mls_group_id.as_slice()],
        )?;
        conn.execute(
            "DELETE FROM circles WHERE mls_group_id = ?1",
            params![mls_group_id.as_slice()],
        )?;

        Ok(())
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
            return Err(CircleError::NotFound(format!(
                "Membership not found for group: {}",
                hex::encode(mls_group_id.as_slice())
            )));
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
                "wss://relay.nostr.wine".to_string(),
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
}
