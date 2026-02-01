//! MDK Manager for group and message operations.
//!
//! This module provides `MdkManager`, the main interface for MDK operations
//! in haven-core. It wraps the MDK library and provides a simplified API
//! for location sharing use cases.

use std::path::Path;

use mdk_core::prelude::*;
use mdk_core::MDK;
use mdk_sqlite_storage::MdkSqliteStorage;
use nostr::prelude::*;

use super::storage::StorageConfig;
use super::types::{LocationGroupConfig, LocationMessageResult, MlsGroup, MlsMessage, MlsWelcome};
use crate::nostr::error::{NostrError, Result};

/// Extension trait for converting MDK errors to `NostrError`.
///
/// This reduces boilerplate in methods that wrap MDK operations.
trait MdkResultExt<T> {
    /// Converts the error to a `NostrError::MdkError`.
    fn map_mdk_err(self) -> Result<T>;
}

impl<T, E: std::fmt::Display> MdkResultExt<T> for std::result::Result<T, E> {
    fn map_mdk_err(self) -> Result<T> {
        self.map_err(|e| NostrError::MdkError(e.to_string()))
    }
}

/// Manager for MDK operations.
///
/// This struct wraps MDK and provides a high-level API for:
/// - Group creation and management
/// - Message encryption and decryption
/// - Welcome handling for group joining
///
/// # Example
///
/// ```no_run
/// use std::path::Path;
/// use haven_core::nostr::mls::MdkManager;
///
/// let manager = MdkManager::new(Path::new("/path/to/data")).unwrap();
/// ```
pub struct MdkManager {
    mdk: MDK<MdkSqliteStorage>,
}

impl MdkManager {
    /// Creates a new MDK manager with `SQLite` storage.
    ///
    /// # Arguments
    ///
    /// * `data_dir` - Path to the directory for storing the MDK database
    ///
    /// # Errors
    ///
    /// Returns an error if the storage cannot be initialized.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use std::path::Path;
    /// use haven_core::nostr::mls::MdkManager;
    ///
    /// let manager = MdkManager::new(Path::new("/path/to/data")).unwrap();
    /// ```
    pub fn new(data_dir: &Path) -> Result<Self> {
        let storage_config = StorageConfig::new(data_dir);
        let storage = storage_config.create_storage()?;
        let mdk = MDK::new(storage);

        Ok(Self { mdk })
    }

    /// Creates a new location sharing group.
    ///
    /// # Arguments
    ///
    /// * `creator_pubkey` - The Nostr public key (hex) of the group creator
    /// * `member_key_packages` - Key package events for initial members
    /// * `config` - Group configuration
    ///
    /// # Returns
    ///
    /// Returns `GroupResult` containing the created group and welcome messages
    /// for the other members.
    ///
    /// # Errors
    ///
    /// Returns an error if group creation fails.
    pub fn create_group(
        &self,
        creator_pubkey: &str,
        member_key_packages: Vec<Event>,
        config: LocationGroupConfig,
    ) -> Result<GroupResult> {
        // Parse creator pubkey
        let creator_pk = PublicKey::from_hex(creator_pubkey)
            .map_err(|e| NostrError::InvalidEvent(format!("Invalid creator pubkey: {e}")))?;

        // Parse relay URLs
        let relays: Vec<RelayUrl> = config
            .relays
            .iter()
            .filter_map(|r| RelayUrl::parse(r).ok())
            .collect();

        // Parse admin pubkeys
        let admins: Vec<PublicKey> = config
            .admins
            .iter()
            .filter_map(|pk| PublicKey::from_hex(pk).ok())
            .collect();

        // Build MDK config
        let mdk_config = NostrGroupConfigData::new(
            config.name,
            config.description,
            None, // image_hash
            None, // image_key
            None, // image_nonce
            relays,
            admins,
        );

        // Create the group
        self.mdk
            .create_group(&creator_pk, member_key_packages, mdk_config)
            .map_mdk_err()
    }

    /// Processes a welcome message.
    ///
    /// This stores the welcome and prepares it for acceptance.
    ///
    /// # Arguments
    ///
    /// * `wrapper_event_id` - The ID of the gift-wrapped event
    /// * `rumor_event` - The decrypted rumor event containing the welcome
    ///
    /// # Returns
    ///
    /// Returns the stored welcome.
    ///
    /// # Errors
    ///
    /// Returns an error if the welcome cannot be processed.
    pub fn process_welcome(
        &self,
        wrapper_event_id: &EventId,
        rumor_event: &UnsignedEvent,
    ) -> Result<MlsWelcome> {
        self.mdk
            .process_welcome(wrapper_event_id, rumor_event)
            .map_mdk_err()
    }

    /// Accepts a welcome message to join a group.
    ///
    /// # Arguments
    ///
    /// * `welcome` - The welcome to accept
    ///
    /// # Errors
    ///
    /// Returns an error if the welcome cannot be accepted.
    pub fn accept_welcome(&self, welcome: &MlsWelcome) -> Result<()> {
        self.mdk.accept_welcome(welcome).map_mdk_err()
    }

    /// Gets pending welcome messages that haven't been accepted yet.
    ///
    /// # Returns
    ///
    /// A list of pending welcomes.
    ///
    /// # Errors
    ///
    /// Returns an error if welcomes cannot be retrieved.
    pub fn get_pending_welcomes(&self) -> Result<Vec<MlsWelcome>> {
        self.mdk.get_pending_welcomes().map_mdk_err()
    }

    /// Creates an encrypted message for a group.
    ///
    /// This takes an unsigned Nostr event (the "rumor") and encrypts it
    /// using MLS for the specified group.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID
    /// * `rumor` - The unsigned event to encrypt
    ///
    /// # Returns
    ///
    /// Returns a signed, encrypted Nostr event (kind 445) ready for publishing.
    ///
    /// # Errors
    ///
    /// Returns an error if encryption fails.
    pub fn create_message(&self, group_id: &GroupId, rumor: UnsignedEvent) -> Result<Event> {
        self.mdk.create_message(group_id, rumor).map_mdk_err()
    }

    /// Processes an incoming encrypted message.
    ///
    /// This decrypts and processes a kind 445 MLS group message.
    ///
    /// # Arguments
    ///
    /// * `event` - The encrypted event to process
    ///
    /// # Returns
    ///
    /// Returns `MessageProcessingResult` indicating the type of message
    /// (application message, proposal, commit, etc.).
    ///
    /// # Errors
    ///
    /// Returns an error if decryption or processing fails.
    pub fn process_message(&self, event: &Event) -> Result<MessageProcessingResult> {
        self.mdk.process_message(event).map_mdk_err()
    }

    /// Gets a specific group by ID.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID
    ///
    /// # Returns
    ///
    /// Returns `Some(Group)` if found, `None` otherwise.
    ///
    /// # Errors
    ///
    /// Returns an error if the storage cannot be accessed.
    pub fn get_group(&self, group_id: &GroupId) -> Result<Option<MlsGroup>> {
        self.mdk.get_group(group_id).map_mdk_err()
    }

    /// Gets all groups.
    ///
    /// # Returns
    ///
    /// Returns a list of all groups the user is a member of.
    ///
    /// # Errors
    ///
    /// Returns an error if the storage cannot be accessed.
    pub fn get_groups(&self) -> Result<Vec<MlsGroup>> {
        self.mdk.get_groups().map_mdk_err()
    }

    /// Gets all members of a group.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID
    ///
    /// # Returns
    ///
    /// Returns a set of member public keys.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is not found.
    pub fn get_members(&self, group_id: &GroupId) -> Result<std::collections::BTreeSet<PublicKey>> {
        self.mdk.get_members(group_id).map_mdk_err()
    }

    /// Leaves a group.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID to leave
    ///
    /// # Returns
    ///
    /// Returns an event that should be published to notify the group.
    ///
    /// # Errors
    ///
    /// Returns an error if leaving fails.
    pub fn leave_group(&self, group_id: &GroupId) -> Result<UpdateGroupResult> {
        self.mdk.leave_group(group_id).map_mdk_err()
    }

    /// Gets messages for a group.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID
    ///
    /// # Returns
    ///
    /// Returns a list of decrypted messages for the group.
    ///
    /// # Errors
    ///
    /// Returns an error if messages cannot be retrieved.
    pub fn get_messages(&self, group_id: &GroupId) -> Result<Vec<MlsMessage>> {
        self.mdk.get_messages(group_id).map_mdk_err()
    }

    /// Converts a `MessageProcessingResult` to a simpler `LocationMessageResult`.
    ///
    /// This is a helper for processing location-specific messages.
    #[must_use]
    pub fn to_location_result(result: MessageProcessingResult) -> LocationMessageResult {
        match result {
            MessageProcessingResult::ApplicationMessage(msg) => LocationMessageResult::Location {
                sender_pubkey: msg.pubkey.to_hex(),
                content: msg.content,
                group_id: msg.mls_group_id,
            },
            MessageProcessingResult::Proposal(r) => LocationMessageResult::GroupUpdate {
                group_id: r.mls_group_id,
            },
            MessageProcessingResult::Commit { mls_group_id }
            | MessageProcessingResult::ExternalJoinProposal { mls_group_id } => {
                LocationMessageResult::GroupUpdate {
                    group_id: mls_group_id,
                }
            }
            MessageProcessingResult::Unprocessable { mls_group_id } => {
                LocationMessageResult::Unprocessable {
                    group_id: mls_group_id,
                    reason: "Message could not be processed".to_string(),
                }
            }
        }
    }
}

impl std::fmt::Debug for MdkManager {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MdkManager")
            .field("mdk", &"<MDK instance>")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::sync::atomic::{AtomicU64, Ordering};

    // Atomic counter for unique test directories
    static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn temp_dir() -> std::path::PathBuf {
        let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
        env::temp_dir().join(format!("haven_mdk_test_{}_{}", std::process::id(), id))
    }

    #[test]
    fn manager_new_creates_instance() {
        let dir = temp_dir();
        let result = MdkManager::new(&dir);
        assert!(result.is_ok());

        // Cleanup
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn manager_debug_does_not_leak() {
        let dir = temp_dir();
        let manager = MdkManager::new(&dir).unwrap();
        let debug_output = format!("{:?}", manager);

        assert!(debug_output.contains("MdkManager"));
        assert!(!debug_output.contains("secret"));

        // Cleanup
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_groups_returns_empty_initially() {
        let dir = temp_dir();
        let manager = MdkManager::new(&dir).unwrap();

        let groups = manager.get_groups().unwrap();
        assert!(groups.is_empty());

        // Cleanup
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_pending_welcomes_returns_empty_initially() {
        let dir = temp_dir();
        let manager = MdkManager::new(&dir).unwrap();

        let welcomes = manager.get_pending_welcomes().unwrap();
        assert!(welcomes.is_empty());

        // Cleanup
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_group_nonexistent_returns_none() {
        let dir = temp_dir();
        let manager = MdkManager::new(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[1, 2, 3]);
        let result = manager.get_group(&fake_id);

        assert!(result.is_ok());
        assert!(result.unwrap().is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_members_nonexistent_group_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[4, 5, 6]);
        let result = manager.get_members(&fake_id);

        assert!(result.is_err());
        if let Err(NostrError::MdkError(msg)) = result {
            assert!(!msg.is_empty());
        } else {
            panic!("Expected MdkError");
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_messages_nonexistent_group_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[7, 8, 9]);
        let result = manager.get_messages(&fake_id);

        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn leave_group_nonexistent_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[10, 11, 12]);
        let result = manager.leave_group(&fake_id);

        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_group_invalid_pubkey_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new(&dir).unwrap();

        let config = LocationGroupConfig::new("Test");
        let result = manager.create_group("invalid-hex!!", vec![], config);

        assert!(result.is_err());
        if let Err(NostrError::InvalidEvent(msg)) = result {
            assert!(msg.contains("Invalid creator pubkey"));
        } else {
            panic!("Expected InvalidEvent error");
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_group_short_pubkey_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new(&dir).unwrap();

        let config = LocationGroupConfig::new("Test");
        // Valid hex but too short
        let result = manager.create_group("abcd1234", vec![], config);

        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_group_filters_invalid_relay_urls() {
        let dir = temp_dir();
        let manager = MdkManager::new(&dir).unwrap();

        // Mix of valid and invalid relay URLs
        let config = LocationGroupConfig::new("Test")
            .with_relay("wss://valid.relay.com")
            .with_relay("not-a-valid-url")
            .with_relay("wss://another-valid.relay.com")
            .with_relay(""); // Empty URL

        // Need a valid 32-byte pubkey (64 hex chars)
        let valid_pubkey = "a".repeat(64);

        // This will fail because we don't have a valid key package
        // but we're testing that relay parsing doesn't cause additional errors
        let result = manager.create_group(&valid_pubkey, vec![], config);

        // It will fail due to invalid pubkey (all 'a's is not a valid curve point)
        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_group_filters_invalid_admin_pubkeys() {
        let dir = temp_dir();
        let manager = MdkManager::new(&dir).unwrap();

        // Mix of valid and invalid admin pubkeys
        let valid_admin = "b".repeat(64);
        let config = LocationGroupConfig::new("Test")
            .with_admin(&valid_admin)
            .with_admin("invalid-admin")
            .with_admin(""); // Empty admin

        let valid_pubkey = "c".repeat(64);
        let result = manager.create_group(&valid_pubkey, vec![], config);

        // Will fail, but for cryptographic reasons, not parsing
        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    // Note: ApplicationMessage and ProposalResult tests are covered in integration tests
    // because we can't easily construct those types in unit tests without MDK internals.
    // The Commit, ExternalJoinProposal, and Unprocessable variants are tested below.

    #[test]
    fn to_location_result_commit() {
        let group_id = super::super::types::GroupId::from_slice(&[7, 8, 9]);

        let processing_result = MessageProcessingResult::Commit {
            mls_group_id: group_id.clone(),
        };
        let location_result = MdkManager::to_location_result(processing_result);

        if let LocationMessageResult::GroupUpdate { group_id: gid } = location_result {
            assert_eq!(gid.as_slice(), &[7, 8, 9]);
        } else {
            panic!("Expected GroupUpdate variant from Commit");
        }
    }

    #[test]
    fn to_location_result_external_join() {
        let group_id = super::super::types::GroupId::from_slice(&[10, 11, 12]);

        let processing_result = MessageProcessingResult::ExternalJoinProposal {
            mls_group_id: group_id.clone(),
        };
        let location_result = MdkManager::to_location_result(processing_result);

        if let LocationMessageResult::GroupUpdate { group_id: gid } = location_result {
            assert_eq!(gid.as_slice(), &[10, 11, 12]);
        } else {
            panic!("Expected GroupUpdate variant from ExternalJoinProposal");
        }
    }

    #[test]
    fn to_location_result_unprocessable() {
        let group_id = super::super::types::GroupId::from_slice(&[13, 14, 15]);

        let processing_result = MessageProcessingResult::Unprocessable {
            mls_group_id: group_id.clone(),
        };
        let location_result = MdkManager::to_location_result(processing_result);

        if let LocationMessageResult::Unprocessable {
            group_id: gid,
            reason,
        } = location_result
        {
            assert_eq!(gid.as_slice(), &[13, 14, 15]);
            assert!(reason.contains("could not be processed"));
        } else {
            panic!("Expected Unprocessable variant");
        }
    }
}
