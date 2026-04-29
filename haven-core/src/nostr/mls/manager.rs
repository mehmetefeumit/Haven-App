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
use super::types::{
    KeyPackageBundle, LocationGroupConfig, LocationMessageResult, MlsGroup, MlsMessage, MlsWelcome,
};
use crate::nostr::error::{NostrError, Result};

/// Redacts long hex sequences from error messages to prevent MLS group ID leakage.
///
/// Replaces any contiguous hex sequence of 16+ characters with `[REDACTED]`.
/// MDK errors may include raw MLS group IDs which must not reach the UI.
#[must_use]
pub fn redact_hex_sequences(msg: &str) -> String {
    let bytes = msg.as_bytes();
    let mut result = String::with_capacity(msg.len());
    let mut i = 0;

    while i < bytes.len() {
        if bytes[i].is_ascii_hexdigit() {
            let start = i;
            while i < bytes.len() && bytes[i].is_ascii_hexdigit() {
                i += 1;
            }
            if i - start >= 16 {
                result.push_str("[REDACTED]");
            } else {
                result.push_str(&msg[start..i]);
            }
        } else {
            result.push(bytes[i] as char);
            i += 1;
        }
    }

    result
}

/// Extension trait for converting MDK errors to `NostrError`.
///
/// Redacts potential MLS group IDs from error messages before propagation.
trait MdkResultExt<T> {
    /// Converts the error to a `NostrError::MdkError` with redacted hex sequences.
    fn map_mdk_err(self) -> Result<T>;
}

impl<T, E: std::fmt::Display> MdkResultExt<T> for std::result::Result<T, E> {
    fn map_mdk_err(self) -> Result<T> {
        self.map_err(|e| NostrError::MdkError(redact_hex_sequences(&e.to_string())))
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

    /// Creates a new `MdkManager` with unencrypted storage.
    ///
    /// # Warning
    ///
    /// This creates an unencrypted database. Sensitive MLS state will be stored
    /// in plaintext. Only use this for testing or development purposes.
    ///
    /// # Arguments
    ///
    /// * `data_dir` - Path to the directory where MDK data will be stored
    ///
    /// # Errors
    ///
    /// Returns an error if the storage cannot be initialized.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn new_unencrypted(data_dir: &Path) -> Result<Self> {
        let storage_config = StorageConfig::new(data_dir);
        let storage = storage_config.create_storage_unencrypted()?;
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

    /// Declines a welcome message, marking the group as inactive.
    ///
    /// # Errors
    ///
    /// Returns an error if the welcome cannot be declined.
    pub fn decline_welcome(&self, welcome: &MlsWelcome) -> Result<()> {
        self.mdk.decline_welcome(welcome).map_mdk_err()
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
        self.mdk.get_pending_welcomes(None).map_mdk_err()
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
    /// * `expiration` - Optional NIP-40 absolute timestamp attached to the
    ///   outer kind:445 wrapper. When `Some`, relays honoring NIP-40 will
    ///   drop the event after that time. This wrapper builds the MDK
    ///   `EventTag::expiration` internally so that `mdk_core` types do not
    ///   leak into haven-core's surface. Only kind:445 location messages
    ///   set this today — welcomes, commits, and proposals pass `None` to
    ///   avoid breaking late joiners.
    ///
    /// # Returns
    ///
    /// Returns a signed, encrypted Nostr event (kind 445) ready for publishing.
    ///
    /// # Errors
    ///
    /// Returns an error if encryption fails.
    pub fn create_message(
        &self,
        group_id: &GroupId,
        rumor: UnsignedEvent,
        expiration: Option<Timestamp>,
    ) -> Result<Event> {
        let tags = expiration.map(|ts| vec![EventTag::expiration(ts)]);
        self.mdk.create_message(group_id, rumor, tags).map_mdk_err()
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

    /// Returns the ratchet tree info for a group (test/feature-only).
    ///
    /// Exposes MDK's `get_ratchet_tree_info` so integration tests can assert
    /// MLS-level properties (e.g. MIP-00 Rule 1: MLS signing keys must differ
    /// from Nostr identity keys).
    ///
    /// # Errors
    ///
    /// Returns an error if the group is not found.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn get_ratchet_tree_info(
        &self,
        group_id: &GroupId,
    ) -> Result<mdk_core::prelude::RatchetTreeInfo> {
        self.mdk.get_ratchet_tree_info(group_id).map_mdk_err()
    }

    /// Reports whether a stored group-event exporter secret exists for a
    /// specific epoch (test/feature-only).
    ///
    /// Returns `Ok(true)` when the exporter secret is still retained for the
    /// given epoch, `Ok(false)` when it has been pruned (or was never stored).
    /// After pruning (see `max_past_epochs` in MDK config), old epoch
    /// secrets must no longer be retrievable — this accessor lets
    /// integration tests verify MIP-03 Rule 5 (exporter-secret lifecycle)
    /// without crossing the FFI boundary with raw secret bytes.
    ///
    /// # Errors
    ///
    /// Returns an error if the underlying storage query fails.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn get_stored_exporter_secret(&self, group_id: &GroupId, epoch: u64) -> Result<bool> {
        use mdk_storage_traits::groups::GroupStorage;
        use openmls_traits::OpenMlsProvider;

        // Pull the storage provider out through the OpenMlsProvider trait
        // (the concrete `storage` field on MdkProvider is private; MDK's own
        // `storage()` helper is pub(crate), so the trait method is the only
        // stable way in from a downstream crate).
        self.mdk
            .provider
            .storage()
            .get_group_exporter_secret(group_id, epoch)
            .map(|opt| opt.is_some())
            .map_mdk_err()
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

    /// Self-demotes the current user from admin status in a group.
    ///
    /// Admins must call this before leaving a group (MIP-03 requirement).
    /// After self-demotion, the pending commit must be merged before leaving.
    ///
    /// # Errors
    ///
    /// Returns an error if the user is not an admin or demotion fails.
    pub fn self_demote(&self, group_id: &GroupId) -> Result<UpdateGroupResult> {
        self.mdk.self_demote(group_id).map_mdk_err()
    }

    /// Performs a self-update on the user's leaf node in a group.
    ///
    /// This rotates the user's key material in the MLS tree, restoring
    /// forward secrecy after joining (MIP-02 MUST). The consumed
    /// `KeyPackage`'s `init_key` was published to relays — rotating it ensures
    /// that anyone who cached the `init_key` can no longer derive group secrets.
    ///
    /// Creates a pending commit that must be merged (on publish success)
    /// or cleared (on publish failure).
    ///
    /// # Errors
    ///
    /// Returns an error if the self-update proposal or commit fails.
    pub fn self_update(&self, group_id: &GroupId) -> Result<UpdateGroupResult> {
        self.mdk.self_update(group_id).map_mdk_err()
    }

    /// Returns group IDs that need a self-update.
    ///
    /// A group needs a self-update when:
    /// - `SelfUpdateState::Required` — post-join self-update not yet completed
    /// - `SelfUpdateState::CompletedAt(t)` — last rotation older than `threshold_secs`
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn groups_needing_self_update(&self, threshold_secs: u64) -> Result<Vec<GroupId>> {
        self.mdk
            .groups_needing_self_update(threshold_secs)
            .map_mdk_err()
    }

    /// Clears a pending MLS commit, rolling back a failed publish attempt.
    ///
    /// Call this when a relay publish fails after an operation that creates
    /// a pending commit (add/remove members, leave, self-update, etc.).
    ///
    /// # Errors
    ///
    /// Returns an error if there is no pending commit or clearing fails.
    pub fn clear_pending_commit(&self, group_id: &GroupId) -> Result<()> {
        self.mdk.clear_pending_commit(group_id).map_mdk_err()
    }

    /// Wipes all local MDK state for a group (tree, epoch secrets, keys,
    /// proposals, messages, processed messages, snapshots, relays, welcomes).
    ///
    /// Idempotent: deleting a nonexistent group is a no-op. Local-only — no
    /// MLS proposals or Nostr events are published. Used by the leave flow
    /// to purge forward-secrecy–sensitive material immediately after the
    /// `SelfRemove` proposal reaches relays, since the leaver's remaining
    /// secrets are only useful for decrypting past ciphertext.
    ///
    /// # Errors
    ///
    /// Returns an error if the underlying storage deletion fails.
    pub fn delete_group(&self, group_id: &GroupId) -> Result<()> {
        self.mdk.delete_group(group_id).map_mdk_err()
    }

    /// Default limit for message retrieval to prevent memory exhaustion.
    pub const DEFAULT_MESSAGE_LIMIT: usize = 500;

    /// Gets messages for a group with default pagination limits.
    ///
    /// This method retrieves up to [`DEFAULT_MESSAGE_LIMIT`] most recent messages
    /// to prevent memory exhaustion from groups with many messages.
    /// Use [`get_messages_paginated`] for custom pagination.
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
        self.get_messages_paginated(group_id, Some(Self::DEFAULT_MESSAGE_LIMIT), None)
    }

    /// Gets messages for a group with custom pagination.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID
    /// * `limit` - Maximum number of messages to return (None for no limit)
    /// * `offset` - Number of messages to skip (None for no offset)
    ///
    /// # Returns
    ///
    /// Returns a list of decrypted messages for the group.
    ///
    /// # Errors
    ///
    /// Returns an error if messages cannot be retrieved.
    pub fn get_messages_paginated(
        &self,
        group_id: &GroupId,
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> Result<Vec<MlsMessage>> {
        use mdk_storage_traits::groups::Pagination;

        let pagination = if limit.is_some() || offset.is_some() {
            Some(Pagination::new(limit, offset))
        } else {
            None
        };

        self.mdk.get_messages(group_id, pagination).map_mdk_err()
    }

    /// Adds members to an existing group.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID
    /// * `key_packages` - Key package events (kind 30443 or 443) for the members to add
    ///
    /// # Returns
    ///
    /// Returns `UpdateGroupResult` containing evolution events and welcome messages.
    /// The evolution event should be published to group relays, and welcome messages
    /// should be gift-wrapped and sent to new members.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is not found or member addition fails.
    pub fn add_members(
        &self,
        group_id: &GroupId,
        key_packages: &[Event],
    ) -> Result<UpdateGroupResult> {
        self.mdk.add_members(group_id, key_packages).map_mdk_err()
    }

    /// Removes members from an existing group.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID
    /// * `member_pubkeys` - Public keys (hex) of members to remove
    ///
    /// # Returns
    ///
    /// Returns `UpdateGroupResult` containing the evolution event to publish.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is not found, any member is not in the group,
    /// or removal fails.
    pub fn remove_members(
        &self,
        group_id: &GroupId,
        member_pubkeys: &[String],
    ) -> Result<UpdateGroupResult> {
        // Parse pubkeys
        let pubkeys: Vec<PublicKey> = member_pubkeys
            .iter()
            .filter_map(|pk| PublicKey::from_hex(pk).ok())
            .collect();

        if pubkeys.is_empty() && !member_pubkeys.is_empty() {
            return Err(NostrError::InvalidEvent(
                "No valid public keys provided".to_string(),
            ));
        }

        self.mdk.remove_members(group_id, &pubkeys).map_mdk_err()
    }

    /// Merges a pending MLS commit after publishing.
    ///
    /// Call this after successfully publishing an evolution event to finalize
    /// the group state change. This completes add/remove member operations.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID with a pending commit
    ///
    /// # Errors
    ///
    /// Returns an error if there is no pending commit or merge fails.
    pub fn merge_pending_commit(&self, group_id: &GroupId) -> Result<()> {
        self.mdk.merge_pending_commit(group_id).map_mdk_err()
    }

    /// Replaces the group's admin list with `admins` via a
    /// `GroupContextExtensions` commit.
    ///
    /// Creates a pending commit — caller must publish the evolution event and
    /// then merge (on ACK) or clear (on failure).
    ///
    /// # Errors
    ///
    /// Returns an error if a pubkey is invalid, the caller is not authorized,
    /// or MDK rejects the update.
    pub fn update_admins(
        &self,
        group_id: &GroupId,
        admins: &[PublicKey],
    ) -> Result<UpdateGroupResult> {
        let update = mdk_core::prelude::NostrGroupDataUpdate::new().admins(admins.to_vec());
        self.mdk.update_group_data(group_id, update).map_mdk_err()
    }

    /// Finds a group by its Nostr group ID.
    ///
    /// This is useful for routing incoming messages that contain the Nostr group ID
    /// in their h-tag.
    ///
    /// # Arguments
    ///
    /// * `nostr_group_id` - The 32-byte Nostr group ID from an h-tag
    ///
    /// # Returns
    ///
    /// Returns `Some(Group)` if found, `None` otherwise.
    ///
    /// # Errors
    ///
    /// Returns an error if storage cannot be accessed.
    pub fn get_group_by_nostr_id(&self, nostr_group_id: &[u8; 32]) -> Result<Option<MlsGroup>> {
        // MDK doesn't have a direct lookup by nostr_group_id, so we iterate
        let groups = self.get_groups()?;
        Ok(groups
            .into_iter()
            .find(|g| &g.nostr_group_id == nostr_group_id))
    }

    /// Creates a key package for publishing to relays.
    ///
    /// This generates MLS key material and returns the data needed to build
    /// a Nostr key package event. Includes tags for both addressable kind 30443
    /// (preferred) and legacy kind 443. The caller must sign the event with
    /// their Nostr identity key and publish it to the specified relays.
    ///
    /// # Arguments
    ///
    /// * `identity_pubkey` - The user's Nostr public key (hex)
    /// * `relays` - Relay URLs where the key package will be published
    ///
    /// # Returns
    ///
    /// Returns a `KeyPackageBundle` containing the event content and tags
    /// for both kind 30443 and kind 443.
    ///
    /// # Errors
    ///
    /// Returns an error if key package generation fails.
    pub fn create_key_package(
        &self,
        identity_pubkey: &str,
        relays: &[String],
    ) -> Result<KeyPackageBundle> {
        // Parse pubkey
        let pubkey = PublicKey::from_hex(identity_pubkey)
            .map_err(|e| NostrError::InvalidEvent(format!("Invalid pubkey: {e}")))?;

        // Parse relay URLs
        let relay_urls: Vec<RelayUrl> = relays
            .iter()
            .filter_map(|r| RelayUrl::parse(r).ok())
            .collect();

        if relay_urls.is_empty() && !relays.is_empty() {
            return Err(NostrError::InvalidEvent(
                "No valid relay URLs provided".to_string(),
            ));
        }

        // Create key package via MDK (returns KeyPackageEventData)
        let kp_data = self
            .mdk
            .create_key_package_for_event(&pubkey, relay_urls)
            .map_mdk_err()?;

        // Convert nostr::Tag to Vec<Vec<String>>, stripping the NIP-70
        // protected tag (["-"]). MIP-00 specifies this tag as optional and
        // recommends omitting it unless publishing to relays that support
        // NIP-42 AUTH + NIP-70. Most popular relays reject protected events.
        let filter_tags = |tags: Vec<Tag>| -> Vec<Vec<String>> {
            tags.into_iter()
                .filter(|tag| tag.kind() != TagKind::Protected)
                .map(|tag| tag.to_vec().into_iter().collect())
                .collect()
        };

        Ok(KeyPackageBundle {
            content: kp_data.content,
            tags_30443: filter_tags(kp_data.tags_30443),
            tags_443: filter_tags(kp_data.tags_443),
            hash_ref: kp_data.hash_ref,
            d_tag: kp_data.d_tag,
            relays: relays.to_vec(),
        })
    }

    /// Converts a `MessageProcessingResult` to a simpler `LocationMessageResult`.
    ///
    /// This is a helper for processing location-specific messages.
    ///
    /// # Auto-committed proposal handling
    ///
    /// MDK's `auto_commit_proposal` path (see
    /// `mdk_core/src/messages/proposal.rs`) stages a pending commit and
    /// returns `MessageProcessingResult::Proposal(UpdateGroupResult)` when
    /// a peer's `SelfRemove` proposal is auto-committed. The caller owes
    /// a publish-then-merge cycle on the `evolution_event`; without it
    /// the local MLS epoch never advances and the departed member keeps
    /// appearing in `get_members`. We surface the event on
    /// [`LocationMessageResult::GroupUpdate::evolution_event`] so the
    /// FFI/Flutter layer can carry it out.
    ///
    /// The `PendingProposal` variant deliberately maps with
    /// `evolution_event = None`: MDK stores the proposal locally but
    /// does **not** create a commit, so there is nothing for the
    /// receiver to publish. Pending proposals are committed later by an
    /// admin via a normal add/remove flow.
    ///
    /// # Ignored proposals (admin-gate / validation drops)
    ///
    /// `MessageProcessingResult::IgnoredProposal` is routed to
    /// [`LocationMessageResult::Ignored`] rather than `GroupUpdate`.
    /// This is load-bearing: the most common source is MDK's admin-gate
    /// dropping a departing admin's `SelfRemove` (see
    /// `mdk-core/src/messages/proposal.rs`). Mapping it to
    /// `GroupUpdate` would invite the Flutter layer's post-success
    /// dedup to mark the event id as seen, which permanently locks the
    /// circle into a ghost-admin state (see
    /// `docs/ADMIN_LEAVE_GHOST_BUG.md`). Keeping it as a distinct
    /// variant lets the caller skip the dedup set and surface a UI
    /// affordance (`Leaving…` badge + admin remove-member action).
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
                evolution_event: Some(r.evolution_event),
            },
            MessageProcessingResult::Commit { mls_group_id }
            | MessageProcessingResult::ExternalJoinProposal { mls_group_id }
            | MessageProcessingResult::PendingProposal { mls_group_id, .. } => {
                LocationMessageResult::GroupUpdate {
                    group_id: mls_group_id,
                    evolution_event: None,
                }
            }
            MessageProcessingResult::IgnoredProposal {
                mls_group_id,
                reason,
            } => LocationMessageResult::Ignored {
                group_id: mls_group_id,
                reason: redact_hex_sequences(&reason),
            },
            MessageProcessingResult::Unprocessable { mls_group_id } => {
                LocationMessageResult::Unprocessable {
                    group_id: mls_group_id,
                    reason: "Message could not be processed".to_string(),
                }
            }
            MessageProcessingResult::PreviouslyFailed => LocationMessageResult::PreviouslyFailed,
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
    fn manager_new_unencrypted_creates_instance() {
        let dir = temp_dir();
        let result = MdkManager::new_unencrypted(&dir);
        assert!(result.is_ok());

        // Cleanup
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn manager_debug_does_not_leak() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();
        let debug_output = format!("{:?}", manager);

        assert!(debug_output.contains("MdkManager"));
        assert!(!debug_output.contains("secret"));

        // Cleanup
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_groups_returns_empty_initially() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let groups = manager.get_groups().unwrap();
        assert!(groups.is_empty());

        // Cleanup
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_pending_welcomes_returns_empty_initially() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let welcomes = manager.get_pending_welcomes().unwrap();
        assert!(welcomes.is_empty());

        // Cleanup
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_group_nonexistent_returns_none() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[1, 2, 3]);
        let result = manager.get_group(&fake_id);

        assert!(result.is_ok());
        assert!(result.unwrap().is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_members_nonexistent_group_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

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
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[7, 8, 9]);
        let result = manager.get_messages(&fake_id);

        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn leave_group_nonexistent_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[10, 11, 12]);
        let result = manager.leave_group(&fake_id);

        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_group_invalid_pubkey_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

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
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let config = LocationGroupConfig::new("Test");
        // Valid hex but too short
        let result = manager.create_group("abcd1234", vec![], config);

        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_group_filters_invalid_relay_urls() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

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
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

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

        if let LocationMessageResult::GroupUpdate {
            group_id: gid,
            evolution_event,
        } = location_result
        {
            assert_eq!(gid.as_slice(), &[7, 8, 9]);
            assert!(
                evolution_event.is_none(),
                "Commit variant should not carry an evolution event"
            );
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

        if let LocationMessageResult::GroupUpdate {
            group_id: gid,
            evolution_event,
        } = location_result
        {
            assert_eq!(gid.as_slice(), &[10, 11, 12]);
            assert!(
                evolution_event.is_none(),
                "ExternalJoinProposal should not carry an evolution event"
            );
        } else {
            panic!("Expected GroupUpdate variant from ExternalJoinProposal");
        }
    }

    #[test]
    fn to_location_result_pending_proposal_has_no_evolution_event() {
        // PendingProposal is stored by MDK without creating a commit.
        // `to_location_result` must map it to GroupUpdate with no
        // evolution_event — there is nothing for the receiver to publish.
        // This is the contract the Flutter layer depends on to avoid
        // publishing a phantom event for Add/Remove proposals pending
        // admin approval.
        let group_id = super::super::types::GroupId::from_slice(&[33, 34, 35]);

        let processing_result = MessageProcessingResult::PendingProposal {
            mls_group_id: group_id.clone(),
        };
        let location_result = MdkManager::to_location_result(processing_result);

        if let LocationMessageResult::GroupUpdate {
            group_id: gid,
            evolution_event,
        } = location_result
        {
            assert_eq!(gid.as_slice(), &[33, 34, 35]);
            assert!(
                evolution_event.is_none(),
                "PendingProposal must not carry an evolution event — MDK has \
                 not created a commit, so there is nothing to publish"
            );
        } else {
            panic!("Expected GroupUpdate variant from PendingProposal");
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

    #[test]
    fn to_location_result_ignored_proposal_maps_to_ignored() {
        // IgnoredProposal is emitted by MDK's admin-gate (and analogous
        // drops) — e.g. an admin's SelfRemove that MDK refuses to
        // auto-commit. The FFI contract routes it to a dedicated
        // `Ignored` variant so the Flutter layer can skip its
        // post-success dedup and surface a UI affordance. Mapping it
        // back to `GroupUpdate` would reintroduce the ghost-admin bug
        // documented in docs/ADMIN_LEAVE_GHOST_BUG.md.
        let group_id = super::super::types::GroupId::from_slice(&[16, 17, 18]);
        let reason = "SelfRemove rejected: sender is an admin".to_string();

        let processing_result = MessageProcessingResult::IgnoredProposal {
            mls_group_id: group_id.clone(),
            reason: reason.clone(),
        };
        let location_result = MdkManager::to_location_result(processing_result);

        match location_result {
            LocationMessageResult::Ignored {
                group_id: gid,
                reason: r,
            } => {
                assert_eq!(gid.as_slice(), &[16, 17, 18]);
                assert_eq!(r, reason);
            }
            other => panic!(
                "IgnoredProposal must map to Ignored, got {:?} — mapping \
                 to GroupUpdate would reintroduce the ghost-admin bug",
                other
            ),
        }
    }

    /// Defence-in-depth: MDK's `IgnoredProposal.reason` is a free-form
    /// string that MDK can change freely across revs. If a future rev
    /// starts interpolating an identifier (pubkey, MLS group id fragment)
    /// into the reason, Haven must not leak it to the UI or logs. The
    /// mapping layer must pipe the reason through `redact_hex_sequences`.
    #[test]
    fn to_location_result_ignored_proposal_reason_is_redacted() {
        let group_id = super::super::types::GroupId::from_slice(&[19, 20, 21]);
        let secret_hex = "0123456789abcdef0123456789abcdef";
        let reason_with_secret = format!("SelfRemove rejected: group {secret_hex} failed");

        let processing_result = MessageProcessingResult::IgnoredProposal {
            mls_group_id: group_id,
            reason: reason_with_secret,
        };
        let location_result = MdkManager::to_location_result(processing_result);

        let LocationMessageResult::Ignored { reason, .. } = location_result else {
            panic!("Expected Ignored variant");
        };

        assert!(
            !reason.contains(secret_hex),
            "reason must not leak hex identifier: {reason}"
        );
        assert!(
            reason.contains("[REDACTED]"),
            "reason should carry redaction marker: {reason}"
        );
    }

    /// The exact admin-gate reason MDK emits today ("SelfRemove rejected:
    /// sender is an admin") contains no long hex sequences and must survive
    /// `redact_hex_sequences` intact. If `to_location_result` ever strips
    /// content from this well-known string, debug messages and the UI
    /// affordance (the "Leaving..." badge and admin remove-member button)
    /// lose the diagnostic value they are designed to convey.
    ///
    /// This test is deliberately coupled to MDK's current reason string so
    /// that any change to the format triggers a reviewer to verify the new
    /// string still satisfies the privacy contract before updating the
    /// assertion. See `docs/ADMIN_LEAVE_GHOST_BUG.md` §6 for context.
    #[test]
    fn to_location_result_ignored_proposal_admin_gate_reason_preserved() {
        let mdk_admin_gate_reason = "SelfRemove rejected: sender is an admin";
        let group_id = super::super::types::GroupId::from_slice(&[22, 23, 24]);

        let processing_result = MessageProcessingResult::IgnoredProposal {
            mls_group_id: group_id,
            reason: mdk_admin_gate_reason.to_string(),
        };
        let location_result = MdkManager::to_location_result(processing_result);

        let LocationMessageResult::Ignored { reason, .. } = location_result else {
            panic!("Expected Ignored variant");
        };

        assert_eq!(
            reason, mdk_admin_gate_reason,
            "MDK admin-gate reason must pass through to_location_result unchanged; \
             redact_hex_sequences must not alter hex-free strings. \
             If MDK changed its reason format, review the new value for privacy \
             before updating this assertion."
        );
        assert!(
            !reason.contains("[REDACTED]"),
            "reason must not acquire a REDACTED marker when no long hex sequence is present"
        );
    }

    #[test]
    fn add_members_nonexistent_group_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[20, 21, 22]);
        let result = manager.add_members(&fake_id, &[]);

        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn remove_members_empty_pubkeys_with_invalid_input_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[23, 24, 25]);
        // Provide invalid pubkeys that will all fail parsing
        let invalid_pubkeys = ["not-valid".to_string(), "also-invalid".to_string()];
        let result = manager.remove_members(&fake_id, &invalid_pubkeys);

        assert!(result.is_err());
        if let Err(NostrError::InvalidEvent(msg)) = result {
            assert!(msg.contains("No valid public keys"));
        } else {
            panic!("Expected InvalidEvent error");
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn remove_members_nonexistent_group_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[26, 27, 28]);
        // Use a valid pubkey format but group doesn't exist
        let valid_pubkey =
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".to_string();
        let result = manager.remove_members(&fake_id, &[valid_pubkey]);

        // Should fail because group doesn't exist (not because of invalid pubkey)
        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn merge_pending_commit_nonexistent_group_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[29, 30, 31]);
        let result = manager.merge_pending_commit(&fake_id);

        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_group_by_nostr_id_nonexistent_returns_none() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_nostr_id = [0u8; 32];
        let result = manager.get_group_by_nostr_id(&fake_nostr_id);

        assert!(result.is_ok());
        assert!(result.unwrap().is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_key_package_invalid_pubkey_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let result =
            manager.create_key_package("invalid-hex!!", &["wss://relay.example.com".to_string()]);

        assert!(result.is_err());
        if let Err(NostrError::InvalidEvent(msg)) = result {
            assert!(msg.contains("Invalid pubkey"));
        } else {
            panic!("Expected InvalidEvent error");
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_key_package_invalid_relay_urls_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        // Valid pubkey format
        let valid_pubkey = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

        // All invalid relay URLs
        let result = manager.create_key_package(
            valid_pubkey,
            &["not-a-url".to_string(), "also-not-valid".to_string()],
        );

        assert!(result.is_err());
        if let Err(NostrError::InvalidEvent(msg)) = result {
            assert!(msg.contains("No valid relay URLs"));
        } else {
            panic!("Expected InvalidEvent error");
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_key_package_with_valid_inputs_succeeds() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        // Use a real valid pubkey (generated from secp256k1)
        // This is just a test pubkey, not a real identity
        let valid_pubkey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

        let result =
            manager.create_key_package(valid_pubkey, &["wss://relay.example.com".to_string()]);

        assert!(result.is_ok());
        let bundle = result.unwrap();

        // Verify the bundle has content
        assert!(!bundle.content.is_empty());

        // Verify tags were generated for both event kinds
        assert!(!bundle.tags_30443.is_empty());
        assert!(!bundle.tags_443.is_empty());
        // Verify hash_ref and d_tag are present
        assert!(!bundle.hash_ref.is_empty());
        assert!(!bundle.d_tag.is_empty());

        // Verify relays are preserved
        assert_eq!(bundle.relays.len(), 1);
        assert_eq!(bundle.relays[0], "wss://relay.example.com");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Verify that the NIP-70 protected tag (`["-"]`) is stripped from the
    /// `KeyPackageBundle` returned by `create_key_package`.
    ///
    /// MDK's `create_key_package_for_event` adds `Tag::protected()` (NIP-70)
    /// to its output. Most production relays reject protected events, so
    /// `create_key_package` must filter that tag out before returning the
    /// bundle. This test confirms the filter is applied at the bundle level,
    /// before the caller ever touches the tags.
    #[test]
    fn create_key_package_strips_nip70_protected_tag_from_bundle() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let valid_pubkey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
        let relays = vec!["wss://relay.example.com".to_string()];

        let bundle = manager
            .create_key_package(valid_pubkey, &relays)
            .expect("create_key_package should succeed with valid inputs");

        // The NIP-70 protected tag serialises as ["-"]. Assert that no tag
        // in either tag set has "-" as its first (and only) element.
        let has_protected = |tags: &[Vec<String>]| {
            tags.iter()
                .any(|tag_vec| tag_vec.first().is_some_and(|k| k == "-"))
        };
        let has_protected_tag =
            has_protected(&bundle.tags_30443) || has_protected(&bundle.tags_443);

        assert!(
            !has_protected_tag,
            "KeyPackageBundle must not contain the NIP-70 protected tag [\"-\"]; \
             most production relays reject protected events"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn redact_hex_sequences_preserves_short_hex() {
        assert_eq!(
            redact_hex_sequences("error code abcd1234"),
            "error code abcd1234"
        );
    }

    #[test]
    fn redact_hex_sequences_redacts_long_hex() {
        let msg = "group 0123456789abcdef0123456789abcdef not found";
        let redacted = redact_hex_sequences(msg);
        assert_eq!(redacted, "group [REDACTED] not found");
        assert!(!redacted.contains("0123456789"));
    }

    #[test]
    fn redact_hex_sequences_handles_no_hex() {
        assert_eq!(
            redact_hex_sequences("plain error message"),
            "plain error message"
        );
    }

    #[test]
    fn redact_hex_sequences_redacts_trailing_hex() {
        let msg = "error: 0123456789abcdef0123456789abcdef";
        assert_eq!(redact_hex_sequences(msg), "error: [REDACTED]");
    }

    #[test]
    fn redact_hex_sequences_preserves_15_char_hex() {
        // 15 hex chars should NOT be redacted (threshold is 16)
        assert_eq!(
            redact_hex_sequences("id=0123456789abcde end"),
            "id=0123456789abcde end"
        );
    }

    #[test]
    fn redact_hex_sequences_redacts_16_char_hex() {
        // Exactly 16 hex chars SHOULD be redacted
        assert_eq!(
            redact_hex_sequences("id=0123456789abcdef end"),
            "id=[REDACTED] end"
        );
    }
}
