//! High-level circle management API.
//!
//! This module provides the [`CircleManager`] which combines MLS operations
//! (via [`MdkManager`]) with application-level storage ([`CircleStorage`])
//! to provide a unified API for circle management.
//!
//! # Privacy Model
//!
//! Haven uses a privacy-first approach where:
//! - User profiles (kind 0) are never published to relays
//! - Contact info (display names, avatars) is stored locally only
//! - Relays only see pubkeys, never usernames
//!
//! [`MdkManager`]: crate::nostr::mls::MdkManager

use std::path::Path;

use nostr::{Event, EventId, UnsignedEvent};

use super::error::{CircleError, Result};
use super::storage::CircleStorage;
use super::types::{
    Circle, CircleConfig, CircleMember, CircleMembership, CircleType, CircleWithMembers, Contact,
    Invitation, MembershipStatus,
};
use crate::nostr::mls::types::{GroupId, KeyPackageBundle, UpdateGroupResult};
use crate::nostr::mls::MdkManager;

/// High-level API for circle management.
///
/// Combines MLS operations with application-level storage to provide
/// a unified interface for creating and managing circles.
///
/// # Example
///
/// ```ignore
/// use std::path::Path;
/// use haven_core::circle::CircleManager;
///
/// let manager = CircleManager::new(Path::new("/data/haven"))?;
/// let circles = manager.get_visible_circles()?;
/// ```
pub struct CircleManager {
    mdk: MdkManager,
    storage: CircleStorage,
}

impl CircleManager {
    /// Creates a new circle manager.
    ///
    /// Initializes both the MLS manager and circle storage at the given path.
    /// Creates necessary directories and databases if they don't exist.
    ///
    /// # Arguments
    ///
    /// * `data_dir` - Base directory for all Haven data
    ///
    /// # Errors
    ///
    /// Returns an error if initialization fails.
    pub fn new(data_dir: &Path) -> Result<Self> {
        // Create data directory if needed
        std::fs::create_dir_all(data_dir)
            .map_err(|e| CircleError::Storage(format!("Failed to create data directory: {e}")))?;

        // Initialize MdkManager
        let mdk = MdkManager::new(data_dir).map_err(|e| CircleError::Mls(e.to_string()))?;

        // Initialize CircleStorage
        let db_path = data_dir.join("circles.db");
        let storage = CircleStorage::new(&db_path)?;

        Ok(Self { mdk, storage })
    }

    /// Creates a new circle manager with unencrypted MLS storage.
    ///
    /// # Warning
    ///
    /// This creates an unencrypted MLS database. Sensitive state will be stored
    /// in plaintext. Only use this for testing or development purposes.
    ///
    /// # Arguments
    ///
    /// * `data_dir` - Base directory for all Haven data
    ///
    /// # Errors
    ///
    /// Returns an error if initialization fails.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn new_unencrypted(data_dir: &Path) -> Result<Self> {
        // Create data directory if needed
        std::fs::create_dir_all(data_dir)
            .map_err(|e| CircleError::Storage(format!("Failed to create data directory: {e}")))?;

        // Initialize MdkManager with unencrypted storage
        let mdk =
            MdkManager::new_unencrypted(data_dir).map_err(|e| CircleError::Mls(e.to_string()))?;

        // Initialize CircleStorage
        let db_path = data_dir.join("circles.db");
        let storage = CircleStorage::new(&db_path)?;

        Ok(Self { mdk, storage })
    }

    // ==================== Circle Lifecycle ====================

    /// Creates a new circle.
    ///
    /// This creates the underlying MLS group and stores circle metadata.
    /// Returns welcome events that should be gift-wrapped and sent to members.
    ///
    /// # Arguments
    ///
    /// * `creator_pubkey` - Nostr public key (hex) of the circle creator
    /// * `member_key_packages` - Key package events for initial members
    /// * `config` - Circle configuration (name, type, relays)
    ///
    /// # Errors
    ///
    /// Returns an error if circle creation fails.
    pub fn create_circle(
        &self,
        creator_pubkey: &str,
        member_key_packages: Vec<Event>,
        config: &CircleConfig,
    ) -> Result<CircleCreationResult> {
        // Create MLS group via MDK
        let mls_config = crate::nostr::mls::types::LocationGroupConfig::new(&config.name)
            .with_relays(config.relays.iter().map(String::as_str));

        if let Some(ref description) = config.description {
            let mls_config = mls_config.with_description(description);
            return self.create_circle_with_config(
                creator_pubkey,
                member_key_packages,
                mls_config,
                config,
            );
        }

        self.create_circle_with_config(creator_pubkey, member_key_packages, mls_config, config)
    }

    /// Internal helper for circle creation with a configured MLS config.
    fn create_circle_with_config(
        &self,
        creator_pubkey: &str,
        member_key_packages: Vec<Event>,
        mls_config: crate::nostr::mls::types::LocationGroupConfig,
        config: &CircleConfig,
    ) -> Result<CircleCreationResult> {
        let group_result = self
            .mdk
            .create_group(creator_pubkey, member_key_packages, mls_config)
            .map_err(|e| CircleError::Mls(e.to_string()))?;

        let now = chrono::Utc::now().timestamp();

        // Create Circle record using group from result
        let circle = Circle {
            mls_group_id: group_result.group.mls_group_id.clone(),
            nostr_group_id: group_result.group.nostr_group_id,
            display_name: config.name.clone(),
            circle_type: config.circle_type,
            relays: config.relays.clone(),
            created_at: now,
            updated_at: now,
        };

        // Save circle to storage
        self.storage.save_circle(&circle)?;

        // Save membership as accepted (creator is automatically a member)
        let membership = CircleMembership {
            mls_group_id: group_result.group.mls_group_id.clone(),
            status: MembershipStatus::Accepted,
            inviter_pubkey: None, // Creator wasn't invited
            invited_at: now,
            responded_at: Some(now),
        };
        self.storage.save_membership(&membership)?;

        Ok(CircleCreationResult {
            circle,
            welcome_events: group_result.welcome_rumors,
        })
    }

    /// Retrieves a circle with its members.
    ///
    /// Returns `None` if the circle doesn't exist.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn get_circle(&self, mls_group_id: &GroupId) -> Result<Option<CircleWithMembers>> {
        let Some(circle) = self.storage.get_circle(mls_group_id)? else {
            return Ok(None);
        };

        let membership = self.storage.get_membership(mls_group_id)?.ok_or_else(|| {
            CircleError::NotFound(format!(
                "Membership not found for circle: {}",
                hex::encode(mls_group_id.as_slice())
            ))
        })?;

        let members = self.get_members(mls_group_id)?;

        Ok(Some(CircleWithMembers {
            circle,
            membership,
            members,
        }))
    }

    /// Retrieves all circles.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn get_circles(&self) -> Result<Vec<CircleWithMembers>> {
        let circles = self.storage.get_all_circles()?;
        let mut result = Vec::with_capacity(circles.len());

        for circle in circles {
            let membership = self.storage.get_membership(&circle.mls_group_id)?;
            if let Some(membership) = membership {
                let members = self.get_members(&circle.mls_group_id).unwrap_or_default();
                result.push(CircleWithMembers {
                    circle,
                    membership,
                    members,
                });
            }
        }

        Ok(result)
    }

    /// Retrieves visible circles (excludes declined invitations).
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn get_visible_circles(&self) -> Result<Vec<CircleWithMembers>> {
        let circles = self.get_circles()?;
        Ok(circles
            .into_iter()
            .filter(|c| c.membership.status.is_visible())
            .collect())
    }

    /// Leaves a circle.
    ///
    /// Returns the update result containing evolution events that should be published.
    ///
    /// # Errors
    ///
    /// Returns an error if leaving fails.
    pub fn leave_circle(&self, mls_group_id: &GroupId) -> Result<UpdateGroupResult> {
        // Leave the MLS group
        let leave_result = self
            .mdk
            .leave_group(mls_group_id)
            .map_err(|e| CircleError::Mls(e.to_string()))?;

        // Delete circle from local storage
        self.storage.delete_circle(mls_group_id)?;

        Ok(leave_result)
    }

    // ==================== Member Management ====================

    /// Adds members to a circle.
    ///
    /// # Arguments
    ///
    /// * `mls_group_id` - The circle's MLS group ID
    /// * `key_packages` - Key package events for new members
    ///
    /// # Errors
    ///
    /// Returns an error if adding members fails.
    pub fn add_members(
        &self,
        mls_group_id: &GroupId,
        key_packages: &[Event],
    ) -> Result<UpdateGroupResult> {
        // Update the circle's updated_at timestamp
        if let Some(mut circle) = self.storage.get_circle(mls_group_id)? {
            circle.updated_at = chrono::Utc::now().timestamp();
            self.storage.save_circle(&circle)?;
        }

        self.mdk
            .add_members(mls_group_id, key_packages)
            .map_err(|e| CircleError::Mls(e.to_string()))
    }

    /// Removes members from a circle.
    ///
    /// # Arguments
    ///
    /// * `mls_group_id` - The circle's MLS group ID
    /// * `member_pubkeys` - Public keys (hex) of members to remove
    ///
    /// # Errors
    ///
    /// Returns an error if removing members fails.
    pub fn remove_members(
        &self,
        mls_group_id: &GroupId,
        member_pubkeys: &[String],
    ) -> Result<UpdateGroupResult> {
        // Update the circle's updated_at timestamp
        if let Some(mut circle) = self.storage.get_circle(mls_group_id)? {
            circle.updated_at = chrono::Utc::now().timestamp();
            self.storage.save_circle(&circle)?;
        }

        self.mdk
            .remove_members(mls_group_id, member_pubkeys)
            .map_err(|e| CircleError::Mls(e.to_string()))
    }

    /// Gets members of a circle with resolved contact info.
    ///
    /// For each member, this resolves any locally-stored contact information
    /// (display name, avatar) from the contacts database.
    ///
    /// # Errors
    ///
    /// Returns an error if retrieving members fails.
    pub fn get_members(&self, mls_group_id: &GroupId) -> Result<Vec<CircleMember>> {
        let mls_members = self
            .mdk
            .get_members(mls_group_id)
            .map_err(|e| CircleError::Mls(e.to_string()))?;

        // Get the group to check admins
        let group = self
            .mdk
            .get_group(mls_group_id)
            .map_err(|e| CircleError::Mls(e.to_string()))?;

        let admins = group
            .as_ref()
            .map(|g| &g.admin_pubkeys)
            .cloned()
            .unwrap_or_default();

        let mut members = Vec::with_capacity(mls_members.len());

        for member_pubkey in mls_members {
            let pubkey_hex = member_pubkey.to_hex();
            let is_admin = admins.contains(&member_pubkey);

            // Look up local contact info
            let contact = self.storage.get_contact(&pubkey_hex)?;

            members.push(CircleMember {
                pubkey: pubkey_hex,
                display_name: contact.as_ref().and_then(|c| c.display_name.clone()),
                avatar_path: contact.as_ref().and_then(|c| c.avatar_path.clone()),
                is_admin,
            });
        }

        Ok(members)
    }

    // ==================== Contact Management ====================

    /// Sets or updates a contact.
    ///
    /// Contact information is stored locally only and never synced to relays.
    /// This allows users to assign custom display names and avatars to other
    /// users without revealing this information to relays.
    ///
    /// # Arguments
    ///
    /// * `pubkey` - Nostr public key (hex) of the contact
    /// * `display_name` - Optional display name to assign
    /// * `avatar_path` - Optional path to local avatar image
    /// * `notes` - Optional notes about the contact
    ///
    /// # Errors
    ///
    /// Returns an error if saving the contact fails.
    pub fn set_contact(
        &self,
        pubkey: &str,
        display_name: Option<&str>,
        avatar_path: Option<&str>,
        notes: Option<&str>,
    ) -> Result<Contact> {
        let now = chrono::Utc::now().timestamp();

        // Get existing contact or create new one
        let existing = self.storage.get_contact(pubkey)?;
        let created_at = existing.as_ref().map_or(now, |c| c.created_at);

        let contact = Contact {
            pubkey: pubkey.to_string(),
            display_name: display_name.map(ToString::to_string),
            avatar_path: avatar_path.map(ToString::to_string),
            notes: notes.map(ToString::to_string),
            created_at,
            updated_at: now,
        };

        self.storage.save_contact(&contact)?;
        Ok(contact)
    }

    /// Gets a contact by pubkey.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn get_contact(&self, pubkey: &str) -> Result<Option<Contact>> {
        self.storage.get_contact(pubkey)
    }

    /// Gets all contacts.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn get_all_contacts(&self) -> Result<Vec<Contact>> {
        self.storage.get_all_contacts()
    }

    /// Deletes a contact.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn delete_contact(&self, pubkey: &str) -> Result<()> {
        self.storage.delete_contact(pubkey)
    }

    // ==================== Invitation Handling ====================

    /// Processes an incoming invitation.
    ///
    /// This should be called when a Welcome event is received. The welcome
    /// is processed by MDK and the invitation is stored for later accept/decline.
    ///
    /// # Arguments
    ///
    /// * `wrapper_event_id` - ID of the gift-wrapped event
    /// * `rumor_event` - The decrypted rumor event containing the welcome
    /// * `circle_name` - Name of the circle (from invitation metadata)
    /// * `inviter_pubkey` - Public key (hex) of the inviter
    ///
    /// # Errors
    ///
    /// Returns an error if processing fails.
    pub fn process_invitation(
        &self,
        wrapper_event_id: &EventId,
        rumor_event: &UnsignedEvent,
        circle_name: &str,
        inviter_pubkey: &str,
    ) -> Result<Invitation> {
        // Process welcome via MDK
        let welcome_result = self
            .mdk
            .process_welcome(wrapper_event_id, rumor_event)
            .map_err(|e| CircleError::Mls(e.to_string()))?;

        let now = chrono::Utc::now().timestamp();

        // Use default relays for invited circles
        // TODO: Extract relays from the welcome message's NostrGroupData extension
        // when MDK exposes this field in WelcomePreview/JoinedGroupResult
        let relays: Vec<String> = crate::circle::types::DEFAULT_RELAYS
            .iter()
            .map(|s| (*s).to_string())
            .collect();

        // Create Circle record
        let circle = Circle {
            mls_group_id: welcome_result.mls_group_id.clone(),
            nostr_group_id: welcome_result.nostr_group_id,
            display_name: circle_name.to_string(),
            circle_type: CircleType::LocationSharing,
            relays,
            created_at: now,
            updated_at: now,
        };
        self.storage.save_circle(&circle)?;

        // Create pending membership
        let membership = CircleMembership {
            mls_group_id: welcome_result.mls_group_id.clone(),
            status: MembershipStatus::Pending,
            inviter_pubkey: Some(inviter_pubkey.to_string()),
            invited_at: now,
            responded_at: None,
        };
        self.storage.save_membership(&membership)?;

        // Get member count
        let member_count = self
            .mdk
            .get_members(&welcome_result.mls_group_id)
            .map(|m| m.len())
            .unwrap_or(0);

        Ok(Invitation {
            mls_group_id: welcome_result.mls_group_id,
            circle_name: circle_name.to_string(),
            inviter_pubkey: inviter_pubkey.to_string(),
            member_count,
            invited_at: now,
        })
    }

    /// Gets all pending invitations.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn get_pending_invitations(&self) -> Result<Vec<Invitation>> {
        let circles = self.storage.get_all_circles()?;
        let mut invitations = Vec::new();

        for circle in circles {
            if let Some(membership) = self.storage.get_membership(&circle.mls_group_id)? {
                if membership.status == MembershipStatus::Pending {
                    let member_count = self
                        .mdk
                        .get_members(&circle.mls_group_id)
                        .map(|m| m.len())
                        .unwrap_or(0);

                    invitations.push(Invitation {
                        mls_group_id: circle.mls_group_id,
                        circle_name: circle.display_name,
                        inviter_pubkey: membership.inviter_pubkey.unwrap_or_default(),
                        member_count,
                        invited_at: membership.invited_at,
                    });
                }
            }
        }

        Ok(invitations)
    }

    /// Accepts an invitation to join a circle.
    ///
    /// # Errors
    ///
    /// Returns an error if acceptance fails.
    pub fn accept_invitation(&self, mls_group_id: &GroupId) -> Result<CircleWithMembers> {
        // Verify invitation exists and is pending
        let membership = self.storage.get_membership(mls_group_id)?.ok_or_else(|| {
            CircleError::NotFound(format!(
                "Invitation not found: {}",
                hex::encode(mls_group_id.as_slice())
            ))
        })?;

        if membership.status != MembershipStatus::Pending {
            return Err(CircleError::MembershipConflict(format!(
                "Invitation already responded: {:?}",
                membership.status
            )));
        }

        // Update membership status
        let now = chrono::Utc::now().timestamp();
        self.storage.update_membership_status(
            mls_group_id,
            MembershipStatus::Accepted,
            Some(now),
        )?;

        // Return the circle with members
        self.get_circle(mls_group_id)?
            .ok_or_else(|| CircleError::NotFound("Circle not found after acceptance".to_string()))
    }

    /// Declines an invitation to join a circle.
    ///
    /// # Errors
    ///
    /// Returns an error if declining fails.
    pub fn decline_invitation(&self, mls_group_id: &GroupId) -> Result<()> {
        // Verify invitation exists and is pending
        let membership = self.storage.get_membership(mls_group_id)?.ok_or_else(|| {
            CircleError::NotFound(format!(
                "Invitation not found: {}",
                hex::encode(mls_group_id.as_slice())
            ))
        })?;

        if membership.status != MembershipStatus::Pending {
            return Err(CircleError::MembershipConflict(format!(
                "Invitation already responded: {:?}",
                membership.status
            )));
        }

        // Update membership status
        let now = chrono::Utc::now().timestamp();
        self.storage.update_membership_status(
            mls_group_id,
            MembershipStatus::Declined,
            Some(now),
        )?;

        Ok(())
    }

    // ==================== Key Packages ====================

    /// Creates a key package for the given identity.
    ///
    /// The returned bundle contains the unsigned event content and tags
    /// that should be signed by the identity key and published.
    ///
    /// # Arguments
    ///
    /// * `identity_pubkey` - Nostr public key (hex) of the identity
    /// * `relays` - Relay URLs where the key package should be published
    ///
    /// # Errors
    ///
    /// Returns an error if key package creation fails.
    pub fn create_key_package(
        &self,
        identity_pubkey: &str,
        relays: &[String],
    ) -> Result<KeyPackageBundle> {
        self.mdk
            .create_key_package(identity_pubkey, relays)
            .map_err(|e| CircleError::Mls(e.to_string()))
    }

    /// Finalizes a pending commit after publishing evolution events.
    ///
    /// This should be called after the commit event has been successfully
    /// published to relays.
    ///
    /// # Errors
    ///
    /// Returns an error if finalization fails.
    pub fn finalize_pending_commit(&self, mls_group_id: &GroupId) -> Result<()> {
        self.mdk
            .merge_pending_commit(mls_group_id)
            .map_err(|e| CircleError::Mls(e.to_string()))
    }
}

/// Result of circle creation.
#[derive(Debug)]
pub struct CircleCreationResult {
    /// The created circle.
    pub circle: Circle,
    /// Welcome events to gift-wrap and send to invited members.
    pub welcome_events: Vec<UnsignedEvent>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn create_test_manager() -> (CircleManager, TempDir) {
        let temp_dir = TempDir::new().unwrap();
        let manager = CircleManager::new_unencrypted(temp_dir.path()).unwrap();
        (manager, temp_dir)
    }

    #[test]
    fn new_creates_manager() {
        let (manager, _temp_dir) = create_test_manager();
        // Verify manager was created successfully
        assert!(manager.get_circles().unwrap().is_empty());
    }

    #[test]
    fn get_circles_returns_empty_initially() {
        let (manager, _temp_dir) = create_test_manager();
        let circles = manager.get_circles().unwrap();
        assert!(circles.is_empty());
    }

    #[test]
    fn get_visible_circles_returns_empty_initially() {
        let (manager, _temp_dir) = create_test_manager();
        let circles = manager.get_visible_circles().unwrap();
        assert!(circles.is_empty());
    }

    #[test]
    fn get_pending_invitations_returns_empty_initially() {
        let (manager, _temp_dir) = create_test_manager();
        let invitations = manager.get_pending_invitations().unwrap();
        assert!(invitations.is_empty());
    }

    #[test]
    fn get_all_contacts_returns_empty_initially() {
        let (manager, _temp_dir) = create_test_manager();
        let contacts = manager.get_all_contacts().unwrap();
        assert!(contacts.is_empty());
    }

    #[test]
    fn set_and_get_contact() {
        let (manager, _temp_dir) = create_test_manager();

        let contact = manager
            .set_contact(
                "abc123",
                Some("Alice"),
                Some("/path/to/avatar.jpg"),
                Some("Friend from work"),
            )
            .unwrap();

        assert_eq!(contact.pubkey, "abc123");
        assert_eq!(contact.display_name, Some("Alice".to_string()));
        assert_eq!(contact.avatar_path, Some("/path/to/avatar.jpg".to_string()));
        assert_eq!(contact.notes, Some("Friend from work".to_string()));

        let retrieved = manager.get_contact("abc123").unwrap().unwrap();
        assert_eq!(retrieved.pubkey, contact.pubkey);
        assert_eq!(retrieved.display_name, contact.display_name);
    }

    #[test]
    fn set_contact_updates_existing() {
        let (manager, _temp_dir) = create_test_manager();

        let contact1 = manager
            .set_contact("abc123", Some("Alice"), None, None)
            .unwrap();
        let created_at = contact1.created_at;

        // Update the contact
        let contact2 = manager
            .set_contact("abc123", Some("Alice Updated"), Some("/avatar.jpg"), None)
            .unwrap();

        // created_at should be preserved
        assert_eq!(contact2.created_at, created_at);
        assert_eq!(contact2.display_name, Some("Alice Updated".to_string()));
        assert_eq!(contact2.avatar_path, Some("/avatar.jpg".to_string()));
    }

    #[test]
    fn delete_contact() {
        let (manager, _temp_dir) = create_test_manager();

        manager
            .set_contact("abc123", Some("Alice"), None, None)
            .unwrap();
        assert!(manager.get_contact("abc123").unwrap().is_some());

        manager.delete_contact("abc123").unwrap();
        assert!(manager.get_contact("abc123").unwrap().is_none());
    }

    #[test]
    fn get_contact_nonexistent_returns_none() {
        let (manager, _temp_dir) = create_test_manager();
        let contact = manager.get_contact("nonexistent").unwrap();
        assert!(contact.is_none());
    }

    #[test]
    fn get_circle_nonexistent_returns_none() {
        let (manager, _temp_dir) = create_test_manager();
        let circle = manager
            .get_circle(&GroupId::from_slice(&[0u8; 32]))
            .unwrap();
        assert!(circle.is_none());
    }

    #[test]
    fn accept_invitation_nonexistent_fails() {
        let (manager, _temp_dir) = create_test_manager();
        let result = manager.accept_invitation(&GroupId::from_slice(&[0u8; 32]));
        assert!(result.is_err());
    }

    #[test]
    fn decline_invitation_nonexistent_fails() {
        let (manager, _temp_dir) = create_test_manager();
        let result = manager.decline_invitation(&GroupId::from_slice(&[0u8; 32]));
        assert!(result.is_err());
    }

    #[test]
    fn create_key_package_invalid_pubkey_fails() {
        let (manager, _temp_dir) = create_test_manager();
        let result =
            manager.create_key_package("invalid", &["wss://relay.example.com".to_string()]);
        assert!(result.is_err());
    }

    #[test]
    fn finalize_pending_commit_nonexistent_fails() {
        let (manager, _temp_dir) = create_test_manager();
        let result = manager.finalize_pending_commit(&GroupId::from_slice(&[0u8; 32]));
        assert!(result.is_err());
    }
}
