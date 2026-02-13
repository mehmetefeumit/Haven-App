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

use nostr::{Event, EventBuilder, EventId, Keys, Kind, PublicKey, Tag, UnsignedEvent};

use super::error::{CircleError, Result};
use super::storage::CircleStorage;
use super::types::{
    Circle, CircleConfig, CircleMember, CircleMembership, CircleType, CircleWithMembers, Contact,
    GiftWrappedWelcome, Invitation, MemberKeyPackage, MembershipStatus,
};
use crate::location::LocationMessage;
use crate::nostr::giftwrap;
use crate::nostr::mls::types::{
    GroupId, GroupState, KeyPackageBundle, LocationMessageResult, UpdateGroupResult,
};
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
    pub(crate) storage: CircleStorage,
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

    /// Creates a new circle with gift-wrapped welcome events.
    ///
    /// This creates the underlying MLS group, stores circle metadata, and
    /// gift-wraps Welcome events for all invited members per NIP-59.
    ///
    /// # Arguments
    ///
    /// * `sender_keys` - The circle creator's Nostr identity keys (for gift-wrapping)
    /// * `members` - Key packages and inbox relays for initial members
    /// * `config` - Circle configuration (name, type, relays)
    ///
    /// # Returns
    ///
    /// Returns the created circle and gift-wrapped Welcome events ready to publish.
    ///
    /// # Errors
    ///
    /// Returns an error if circle creation or gift-wrapping fails.
    pub async fn create_circle(
        &self,
        sender_keys: &Keys,
        members: Vec<MemberKeyPackage>,
        config: &CircleConfig,
    ) -> Result<CircleCreationResult> {
        // Extract just the key package events for MLS group creation
        let key_package_events: Vec<Event> = members
            .iter()
            .map(|m| m.key_package_event.clone())
            .collect();

        // Create MLS group via MDK
        let mls_config = crate::nostr::mls::types::LocationGroupConfig::new(&config.name)
            .with_relays(config.relays.iter().map(String::as_str));

        if let Some(ref description) = config.description {
            let mls_config = mls_config.with_description(description);
            return self
                .create_circle_with_config(
                    sender_keys,
                    &members,
                    key_package_events,
                    mls_config,
                    config,
                )
                .await;
        }

        self.create_circle_with_config(
            sender_keys,
            &members,
            key_package_events,
            mls_config,
            config,
        )
        .await
    }

    /// Internal helper for circle creation with a configured MLS config.
    async fn create_circle_with_config(
        &self,
        sender_keys: &Keys,
        members: &[MemberKeyPackage],
        key_package_events: Vec<Event>,
        mls_config: crate::nostr::mls::types::LocationGroupConfig,
        config: &CircleConfig,
    ) -> Result<CircleCreationResult> {
        let creator_pubkey = sender_keys.public_key().to_hex();

        let group_result = self
            .mdk
            .create_group(&creator_pubkey, key_package_events, mls_config)
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

        // Gift-wrap each welcome for its recipient
        let mut welcome_events = Vec::with_capacity(group_result.welcome_rumors.len());
        for (rumor, member) in group_result.welcome_rumors.into_iter().zip(members.iter()) {
            // Extract recipient pubkey from the key package event
            let recipient_pubkey = member.key_package_event.pubkey;

            // Gift-wrap the welcome (NIP-59)
            let wrapped = giftwrap::wrap_welcome(sender_keys, &recipient_pubkey, rumor)
                .await
                .map_err(|e| CircleError::Mls(format!("Gift-wrap failed: {e}")))?;

            welcome_events.push(GiftWrappedWelcome {
                recipient_pubkey: recipient_pubkey.to_hex(),
                recipient_relays: member.inbox_relays.clone(),
                event: wrapped,
            });
        }

        Ok(CircleCreationResult {
            circle,
            welcome_events,
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
            CircleError::NotFound("Membership not found for circle: <redacted>".to_string())
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

    /// Processes a gift-wrapped Welcome event (kind 1059).
    ///
    /// This is the high-level API for processing incoming invitations.
    /// It unwraps the gift-wrapped event, extracts the sender info,
    /// and processes the invitation.
    ///
    /// # Arguments
    ///
    /// * `recipient_keys` - The recipient's Nostr identity keys (for unwrapping)
    /// * `gift_wrap_event` - The kind 1059 gift-wrapped event from relay
    /// * `circle_name` - Name of the circle (from invitation metadata)
    ///
    /// # Errors
    ///
    /// Returns an error if unwrapping or processing fails.
    pub async fn process_gift_wrapped_invitation(
        &self,
        recipient_keys: &Keys,
        gift_wrap_event: &Event,
        circle_name: &str,
    ) -> Result<Invitation> {
        // Unwrap the gift-wrapped event
        let unwrapped = giftwrap::unwrap_welcome(recipient_keys, gift_wrap_event)
            .await
            .map_err(|e| CircleError::Mls(format!("Failed to unwrap welcome: {e}")))?;

        // Process the invitation using the low-level method
        self.process_invitation(
            &unwrapped.wrapper_event_id,
            &unwrapped.rumor,
            circle_name,
            &unwrapped.sender_pubkey.to_hex(),
        )
    }

    /// Processes an incoming invitation from an already-unwrapped Welcome.
    ///
    /// This is the low-level API that takes pre-unwrapped components.
    /// Prefer [`process_gift_wrapped_invitation`] for most use cases.
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
    ///
    /// [`process_gift_wrapped_invitation`]: Self::process_gift_wrapped_invitation
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
        let membership = self
            .storage
            .get_membership(mls_group_id)?
            .ok_or_else(|| CircleError::NotFound("Invitation not found: <redacted>".to_string()))?;

        if membership.status != MembershipStatus::Pending {
            return Err(CircleError::MembershipConflict(format!(
                "Invitation already responded: {:?}",
                membership.status
            )));
        }

        // Accept the welcome in MDK to activate the MLS group.
        // First check if already active (recovery from partial failure where MDK
        // accepted but Haven storage update failed on a previous attempt).
        let group = self.mdk.get_group(mls_group_id)?;
        let already_active = group.is_some_and(|g| g.state == GroupState::Active);

        if !already_active {
            let pending_welcomes = self.mdk.get_pending_welcomes()?;

            let welcome = pending_welcomes
                .iter()
                .find(|w| &w.mls_group_id == mls_group_id)
                .ok_or_else(|| {
                    CircleError::NotFound(
                        "No pending MDK welcome found for invitation: <redacted>".to_string(),
                    )
                })?;

            self.mdk.accept_welcome(welcome)?;
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
        let membership = self
            .storage
            .get_membership(mls_group_id)?
            .ok_or_else(|| CircleError::NotFound("Invitation not found: <redacted>".to_string()))?;

        if membership.status != MembershipStatus::Pending {
            return Err(CircleError::MembershipConflict(format!(
                "Invitation already responded: {:?}",
                membership.status
            )));
        }

        // Decline the welcome in MDK to clean up MLS state.
        // Check if already inactive (recovery from partial failure).
        let group = self.mdk.get_group(mls_group_id)?;
        let already_inactive = group.is_some_and(|g| g.state == GroupState::Inactive);

        if !already_inactive {
            let pending_welcomes = self.mdk.get_pending_welcomes()?;

            let welcome = pending_welcomes
                .iter()
                .find(|w| &w.mls_group_id == mls_group_id)
                .ok_or_else(|| {
                    CircleError::NotFound(
                        "No pending MDK welcome found for invitation: <redacted>".to_string(),
                    )
                })?;

            self.mdk.decline_welcome(welcome)?;
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

    // ==================== Location Sharing ====================

    /// Encrypts a location for a circle, producing a kind 445 event.
    ///
    /// Looks up the circle's MLS group, builds an inner rumor event (kind 9
    /// with `["t", "location"]` tag per MIP-03), and encrypts it via MDK.
    /// MDK handles MLS encryption and ephemeral keypair generation.
    ///
    /// # Arguments
    ///
    /// * `mls_group_id` - The circle's MLS group ID
    /// * `sender_pubkey` - The sender's Nostr public key (for the inner rumor)
    /// * `location` - The obfuscated location message to encrypt
    ///
    /// # Returns
    ///
    /// A tuple of `(kind_445_event, nostr_group_id, relay_urls)` ready for
    /// publishing via [`RelayManager`].
    ///
    /// # Errors
    ///
    /// Returns an error if the circle is not found, serialization fails,
    /// or MLS encryption fails.
    pub fn encrypt_location(
        &self,
        mls_group_id: &GroupId,
        sender_pubkey: &PublicKey,
        location: &LocationMessage,
    ) -> Result<(Event, [u8; 32], Vec<String>)> {
        // Look up circle to get nostr_group_id and relays
        let circle = self
            .storage
            .get_circle(mls_group_id)?
            .ok_or_else(|| CircleError::NotFound("Circle not found: <redacted>".to_string()))?;

        // Build the inner rumor event (kind 9 with location tag per MIP-03)
        let content = location
            .to_string()
            .map_err(|e| CircleError::Mls(format!("Failed to serialize location: {e}")))?;

        let location_tag = Tag::parse(["t", "location"])
            .map_err(|e| CircleError::Mls(format!("Failed to create location tag: {e}")))?;

        let rumor = EventBuilder::new(Kind::Custom(9), content)
            .tag(location_tag)
            .build(*sender_pubkey);

        // Encrypt using MdkManager directly (MLS encryption + ephemeral keypair)
        let event = self
            .mdk
            .create_message(mls_group_id, rumor)
            .map_err(|e| CircleError::Mls(e.to_string()))?;

        Ok((event, circle.nostr_group_id, circle.relays))
    }

    /// Decrypts a kind 445 event, returning the location result.
    ///
    /// Delegates to MDK for MLS decryption, signature verification, and epoch
    /// management. The result indicates whether the message is a location
    /// update, a group evolution event, or unprocessable.
    ///
    /// # Arguments
    ///
    /// * `event` - The received kind 445 event to decrypt
    ///
    /// # Returns
    ///
    /// A [`LocationMessageResult`] indicating the message type:
    /// - `Location`: Decrypted location with sender pubkey and content JSON
    /// - `GroupUpdate`: Member addition/removal (commit or proposal)
    /// - `Unprocessable`: Could not decrypt (epoch mismatch, etc.)
    /// - `PreviouslyFailed`: Previously attempted and failed
    ///
    /// # Errors
    ///
    /// Returns an error if MLS processing fails entirely.
    pub fn decrypt_location(&self, event: &Event) -> Result<LocationMessageResult> {
        let result = self
            .mdk
            .process_message(event)
            .map_err(|e| CircleError::Mls(e.to_string()))?;

        Ok(MdkManager::to_location_result(result))
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
    /// Gift-wrapped Welcome events ready to publish to recipients.
    pub welcome_events: Vec<GiftWrappedWelcome>,
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

    /// Result of setting up a two-party MLS group between two CircleManagers.
    struct TwoPartyCircle {
        alice: CircleManager,
        _alice_dir: TempDir,
        alice_keys: Keys,
        bob: CircleManager,
        _bob_dir: TempDir,
        bob_keys: Keys,
        mls_group_id: GroupId,
        nostr_group_id: [u8; 32],
        relays: Vec<String>,
    }

    /// Creates two CircleManagers with an established MLS group and matching
    /// Circle records in both managers' storage.
    fn setup_two_party_circle() -> TwoPartyCircle {
        let relays = vec!["wss://relay.test.com".to_string()];

        let alice_dir = TempDir::new().unwrap();
        let alice = CircleManager::new_unencrypted(alice_dir.path()).unwrap();
        let alice_keys = Keys::generate();

        let bob_dir = TempDir::new().unwrap();
        let bob = CircleManager::new_unencrypted(bob_dir.path()).unwrap();
        let bob_keys = Keys::generate();

        // Bob creates a key package (signed event)
        let bob_pubkey_hex = bob_keys.public_key().to_hex();
        let bundle = bob
            .mdk
            .create_key_package(&bob_pubkey_hex, &relays)
            .expect("should create bob key package");

        let tags: Vec<nostr::Tag> = bundle
            .tags
            .into_iter()
            .map(|t| nostr::Tag::parse(&t).unwrap())
            .collect();

        let bob_kp_event = EventBuilder::new(Kind::MlsKeyPackage, bundle.content)
            .tags(tags)
            .sign_with_keys(&bob_keys)
            .expect("should sign bob key package");

        // Alice creates the group
        let config = crate::nostr::mls::types::LocationGroupConfig::new("Test Circle")
            .with_description("Integration test circle")
            .with_relay("wss://relay.test.com")
            .with_admin(&alice_keys.public_key().to_hex());

        let group_result = alice
            .mdk
            .create_group(
                &alice_keys.public_key().to_hex(),
                vec![bob_kp_event],
                config,
            )
            .expect("should create group");

        let mls_group_id = group_result.group.mls_group_id.clone();
        let nostr_group_id = group_result.group.nostr_group_id;

        // Alice merges the pending commit
        alice
            .mdk
            .merge_pending_commit(&mls_group_id)
            .expect("should merge alice pending commit");

        // Bob processes the welcome
        let welcome_rumor = group_result
            .welcome_rumors
            .first()
            .expect("should have welcome for bob");

        bob.mdk
            .process_welcome(&nostr::EventId::all_zeros(), welcome_rumor)
            .expect("should process welcome");

        let pending = bob
            .mdk
            .get_pending_welcomes()
            .expect("should get pending welcomes");
        let welcome = pending.first().expect("should have one pending welcome");

        bob.mdk
            .accept_welcome(welcome)
            .expect("should accept welcome");

        // Save Circle records to both managers' storage
        let now = chrono::Utc::now().timestamp();
        let circle = super::super::types::Circle {
            mls_group_id: mls_group_id.clone(),
            nostr_group_id,
            display_name: "Test Circle".to_string(),
            circle_type: super::super::types::CircleType::LocationSharing,
            relays: relays.clone(),
            created_at: now,
            updated_at: now,
        };

        alice.storage.save_circle(&circle).unwrap();
        bob.storage.save_circle(&circle).unwrap();

        // Save accepted memberships for both
        let alice_membership = super::super::types::CircleMembership {
            mls_group_id: mls_group_id.clone(),
            status: super::super::types::MembershipStatus::Accepted,
            inviter_pubkey: None,
            invited_at: now,
            responded_at: Some(now),
        };
        alice.storage.save_membership(&alice_membership).unwrap();

        let bob_membership = super::super::types::CircleMembership {
            mls_group_id: mls_group_id.clone(),
            status: super::super::types::MembershipStatus::Accepted,
            inviter_pubkey: Some(alice_keys.public_key().to_hex()),
            invited_at: now,
            responded_at: Some(now),
        };
        bob.storage.save_membership(&bob_membership).unwrap();

        TwoPartyCircle {
            alice,
            _alice_dir: alice_dir,
            alice_keys,
            bob,
            _bob_dir: bob_dir,
            bob_keys,
            mls_group_id,
            nostr_group_id,
            relays,
        }
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

    #[test]
    fn get_circles_with_stored_data() {
        let (manager, _temp_dir) = create_test_manager();

        // Store circle and membership directly
        let circle = super::super::types::Circle {
            mls_group_id: GroupId::from_slice(&[1, 2, 3, 4, 5]),
            nostr_group_id: [0xAB; 32],
            display_name: "Storage Test Circle".to_string(),
            circle_type: super::super::types::CircleType::LocationSharing,
            relays: vec!["wss://relay.example.com".to_string()],
            created_at: 1000,
            updated_at: 2000,
        };
        manager.storage.save_circle(&circle).unwrap();

        let membership = super::super::types::CircleMembership {
            mls_group_id: GroupId::from_slice(&[1, 2, 3, 4, 5]),
            status: super::super::types::MembershipStatus::Accepted,
            inviter_pubkey: Some("inviter123".to_string()),
            invited_at: 1000,
            responded_at: Some(1001),
        };
        manager.storage.save_membership(&membership).unwrap();

        // get_circles should work because get_members uses unwrap_or_default
        let circles = manager.get_circles().unwrap();
        assert_eq!(circles.len(), 1);
        assert_eq!(circles[0].circle.display_name, "Storage Test Circle");
        assert!(circles[0].members.is_empty()); // MLS group doesn't exist, so empty
    }

    #[test]
    fn get_visible_circles_filters_declined() {
        let (manager, _temp_dir) = create_test_manager();

        // Store two circles: one accepted, one declined
        let circle1 = super::super::types::Circle {
            mls_group_id: GroupId::from_slice(&[1]),
            nostr_group_id: [0x01; 32],
            display_name: "Accepted Circle".to_string(),
            circle_type: super::super::types::CircleType::LocationSharing,
            relays: vec![],
            created_at: 1000,
            updated_at: 2000,
        };
        manager.storage.save_circle(&circle1).unwrap();
        manager
            .storage
            .save_membership(&super::super::types::CircleMembership {
                mls_group_id: GroupId::from_slice(&[1]),
                status: super::super::types::MembershipStatus::Accepted,
                inviter_pubkey: None,
                invited_at: 1000,
                responded_at: Some(1001),
            })
            .unwrap();

        let circle2 = super::super::types::Circle {
            mls_group_id: GroupId::from_slice(&[2]),
            nostr_group_id: [0x02; 32],
            display_name: "Declined Circle".to_string(),
            circle_type: super::super::types::CircleType::LocationSharing,
            relays: vec![],
            created_at: 1000,
            updated_at: 2000,
        };
        manager.storage.save_circle(&circle2).unwrap();
        manager
            .storage
            .save_membership(&super::super::types::CircleMembership {
                mls_group_id: GroupId::from_slice(&[2]),
                status: super::super::types::MembershipStatus::Declined,
                inviter_pubkey: None,
                invited_at: 1000,
                responded_at: Some(1001),
            })
            .unwrap();

        let visible = manager.get_visible_circles().unwrap();
        assert_eq!(visible.len(), 1);
        assert_eq!(visible[0].circle.display_name, "Accepted Circle");
    }

    #[test]
    fn get_pending_invitations_with_stored_data() {
        let (manager, _temp_dir) = create_test_manager();

        let circle = super::super::types::Circle {
            mls_group_id: GroupId::from_slice(&[10]),
            nostr_group_id: [0x10; 32],
            display_name: "Pending Circle".to_string(),
            circle_type: super::super::types::CircleType::LocationSharing,
            relays: vec![],
            created_at: 5000,
            updated_at: 5000,
        };
        manager.storage.save_circle(&circle).unwrap();

        let membership = super::super::types::CircleMembership {
            mls_group_id: GroupId::from_slice(&[10]),
            status: super::super::types::MembershipStatus::Pending,
            inviter_pubkey: Some("inviter-pubkey".to_string()),
            invited_at: 5000,
            responded_at: None,
        };
        manager.storage.save_membership(&membership).unwrap();

        let invitations = manager.get_pending_invitations().unwrap();
        assert_eq!(invitations.len(), 1);
        assert_eq!(invitations[0].circle_name, "Pending Circle");
        assert_eq!(invitations[0].inviter_pubkey, "inviter-pubkey");
        assert_eq!(invitations[0].member_count, 0); // MLS group doesn't exist
    }

    #[test]
    fn decline_invitation_success() {
        let setup = setup_pending_invite();

        // Decline should succeed
        setup.bob.decline_invitation(&setup.mls_group_id).unwrap();

        // Verify it's now declined
        let invitations = setup.bob.get_pending_invitations().unwrap();
        assert!(invitations.is_empty());
    }

    #[test]
    fn accept_invitation_already_accepted_fails() {
        let (manager, _temp_dir) = create_test_manager();

        let circle = super::super::types::Circle {
            mls_group_id: GroupId::from_slice(&[30]),
            nostr_group_id: [0x30; 32],
            display_name: "Already Accepted".to_string(),
            circle_type: super::super::types::CircleType::LocationSharing,
            relays: vec![],
            created_at: 1000,
            updated_at: 1000,
        };
        manager.storage.save_circle(&circle).unwrap();

        let membership = super::super::types::CircleMembership {
            mls_group_id: GroupId::from_slice(&[30]),
            status: super::super::types::MembershipStatus::Accepted,
            inviter_pubkey: None,
            invited_at: 1000,
            responded_at: Some(1001),
        };
        manager.storage.save_membership(&membership).unwrap();

        // Should fail because status is not Pending
        let result = manager.accept_invitation(&GroupId::from_slice(&[30]));
        assert!(result.is_err());
    }

    #[test]
    fn decline_invitation_already_declined_fails() {
        let (manager, _temp_dir) = create_test_manager();

        let circle = super::super::types::Circle {
            mls_group_id: GroupId::from_slice(&[40]),
            nostr_group_id: [0x40; 32],
            display_name: "Already Declined".to_string(),
            circle_type: super::super::types::CircleType::LocationSharing,
            relays: vec![],
            created_at: 1000,
            updated_at: 1000,
        };
        manager.storage.save_circle(&circle).unwrap();

        let membership = super::super::types::CircleMembership {
            mls_group_id: GroupId::from_slice(&[40]),
            status: super::super::types::MembershipStatus::Declined,
            inviter_pubkey: None,
            invited_at: 1000,
            responded_at: Some(1001),
        };
        manager.storage.save_membership(&membership).unwrap();

        let result = manager.decline_invitation(&GroupId::from_slice(&[40]));
        assert!(result.is_err());
    }

    #[test]
    fn leave_circle_nonexistent_fails() {
        let (manager, _temp_dir) = create_test_manager();
        let result = manager.leave_circle(&GroupId::from_slice(&[0u8; 32]));
        assert!(result.is_err());
    }

    #[test]
    fn add_members_nonexistent_group_fails() {
        let (manager, _temp_dir) = create_test_manager();
        let result = manager.add_members(&GroupId::from_slice(&[0u8; 32]), &[]);
        assert!(result.is_err());
    }

    #[test]
    fn remove_members_nonexistent_group_fails() {
        let (manager, _temp_dir) = create_test_manager();
        let result =
            manager.remove_members(&GroupId::from_slice(&[0u8; 32]), &["pubkey1".to_string()]);
        assert!(result.is_err());
    }

    #[test]
    fn get_members_nonexistent_group_fails() {
        let (manager, _temp_dir) = create_test_manager();
        let result = manager.get_members(&GroupId::from_slice(&[0u8; 32]));
        assert!(result.is_err());
    }

    // ==================== Location Encryption Tests ====================

    #[test]
    fn encrypt_location_nonexistent_circle_fails() {
        let (manager, _temp_dir) = create_test_manager();
        let keys = Keys::generate();
        let location = LocationMessage::new(37.7749, -122.4194);
        let fake_group_id = GroupId::from_slice(&[0xDE, 0xAD, 0xBE, 0xEF]);

        let result = manager.encrypt_location(&fake_group_id, &keys.public_key(), &location);

        assert!(result.is_err());
        let err_msg = format!("{}", result.unwrap_err());
        assert!(
            err_msg.contains("not found") || err_msg.contains("Not found"),
            "Error should indicate circle not found, got: {err_msg}"
        );
    }

    #[test]
    fn encrypt_location_returns_correct_metadata() {
        let setup = setup_two_party_circle();
        let location = LocationMessage::new(40.7128, -74.0060);

        let (event, returned_nostr_group_id, returned_relays) = setup
            .alice
            .encrypt_location(
                &setup.mls_group_id,
                &setup.alice_keys.public_key(),
                &location,
            )
            .expect("encrypt_location should succeed");

        // Verify the returned nostr_group_id matches the stored circle
        assert_eq!(
            returned_nostr_group_id, setup.nostr_group_id,
            "Returned nostr_group_id must match the stored circle"
        );

        // Verify the returned relays match the stored circle
        assert_eq!(
            returned_relays, setup.relays,
            "Returned relays must match the stored circle"
        );

        // Verify the event is kind 445
        assert_eq!(
            event.kind,
            Kind::Custom(445),
            "Encrypted event should be kind 445"
        );

        // Verify the outer event does NOT contain plaintext location data
        assert!(
            !event.content.contains("37.7128") && !event.content.contains("40.7128"),
            "Encrypted event must not contain plaintext latitude"
        );
        assert!(
            !event.content.contains("-74.006"),
            "Encrypted event must not contain plaintext longitude"
        );

        // Verify the outer event uses an ephemeral pubkey (not Alice's real key)
        assert_ne!(
            event.pubkey,
            setup.alice_keys.public_key(),
            "Kind 445 outer event must use an ephemeral pubkey, not the sender's real key"
        );
    }

    #[test]
    fn encrypt_location_and_decrypt_roundtrip() {
        let setup = setup_two_party_circle();
        let location = LocationMessage::new(37.7749, -122.4194);

        // Alice encrypts a location for the circle
        let (encrypted_event, _, _) = setup
            .alice
            .encrypt_location(
                &setup.mls_group_id,
                &setup.alice_keys.public_key(),
                &location,
            )
            .expect("alice should encrypt location");

        // Bob decrypts the location
        let result = setup
            .bob
            .decrypt_location(&encrypted_event)
            .expect("bob should decrypt location");

        // Verify it's a Location variant with correct data
        if let crate::nostr::mls::types::LocationMessageResult::Location {
            sender_pubkey,
            content,
            ..
        } = result
        {
            // Verify sender is Alice
            assert_eq!(
                sender_pubkey,
                setup.alice_keys.public_key().to_hex(),
                "Decrypted sender should be Alice"
            );

            // Verify the content can be deserialized back to a LocationMessage
            let recovered = LocationMessage::from_string(&content)
                .expect("should deserialize decrypted location");

            assert_eq!(
                recovered.latitude, location.latitude,
                "Recovered latitude should match original"
            );
            assert_eq!(
                recovered.longitude, location.longitude,
                "Recovered longitude should match original"
            );
            assert_eq!(
                recovered.geohash, location.geohash,
                "Recovered geohash should match original"
            );
        } else {
            panic!("Expected Location variant, got: {:?}", result);
        }
    }

    #[test]
    fn decrypt_location_bidirectional() {
        let setup = setup_two_party_circle();

        // Find Bob's MLS group ID (may differ from Alice's internal representation)
        let bob_groups = setup.bob.mdk.get_groups().expect("bob should get groups");
        let bob_group = bob_groups.first().expect("bob should have one group");
        let bob_mls_group_id = bob_group.mls_group_id.clone();

        // Bob encrypts a location
        let location = LocationMessage::new(48.8566, 2.3522);
        let (encrypted_event, _, _) = setup
            .bob
            .encrypt_location(&bob_mls_group_id, &setup.bob_keys.public_key(), &location)
            .expect("bob should encrypt location");

        // Alice decrypts it
        let result = setup
            .alice
            .decrypt_location(&encrypted_event)
            .expect("alice should decrypt bob's location");

        if let crate::nostr::mls::types::LocationMessageResult::Location {
            sender_pubkey,
            content,
            ..
        } = result
        {
            assert_eq!(
                sender_pubkey,
                setup.bob_keys.public_key().to_hex(),
                "Decrypted sender should be Bob"
            );

            let recovered =
                LocationMessage::from_string(&content).expect("should deserialize bob's location");
            assert_eq!(recovered.latitude, location.latitude);
            assert_eq!(recovered.longitude, location.longitude);
        } else {
            panic!("Expected Location variant from Bob, got: {:?}", result);
        }
    }

    #[test]
    fn decrypt_location_group_update() {
        let setup = setup_two_party_circle();

        // Create a third party (Carol) and add her to the group to produce
        // a commit event. Adding a member produces an UpdateGroupResult whose
        // evolution_event is a kind 445 commit. When Bob processes that commit
        // via decrypt_location, it should return GroupUpdate.

        let carol_dir = TempDir::new().unwrap();
        let carol_mdk =
            MdkManager::new_unencrypted(carol_dir.path()).expect("should create carol manager");
        let carol_keys = Keys::generate();

        // Carol creates a key package
        let carol_bundle = carol_mdk
            .create_key_package(
                &carol_keys.public_key().to_hex(),
                &["wss://relay.test.com".to_string()],
            )
            .expect("should create carol key package");

        let tags: Vec<nostr::Tag> = carol_bundle
            .tags
            .into_iter()
            .map(|t| nostr::Tag::parse(&t).unwrap())
            .collect();

        let carol_kp_event = EventBuilder::new(Kind::MlsKeyPackage, carol_bundle.content)
            .tags(tags)
            .sign_with_keys(&carol_keys)
            .expect("should sign carol key package");

        // Alice adds Carol to the group (produces a commit event)
        let add_result = setup
            .alice
            .add_members(&setup.mls_group_id, &[carol_kp_event])
            .expect("alice should add carol");

        // Alice merges the pending commit for the add operation
        setup
            .alice
            .finalize_pending_commit(&setup.mls_group_id)
            .expect("alice should finalize pending commit");

        // Bob processes the commit event via decrypt_location
        let result = setup
            .bob
            .decrypt_location(&add_result.evolution_event)
            .expect("bob should process commit");

        // The commit should produce a GroupUpdate variant
        if let crate::nostr::mls::types::LocationMessageResult::GroupUpdate { .. } = result {
            // Success -- commit was recognized as a group update
        } else {
            panic!(
                "Expected GroupUpdate variant from commit, got: {:?}",
                result
            );
        }
    }

    /// Sets up two parties where Bob has a processed welcome but has NOT yet
    /// called `accept_welcome()` — the MLS group is still `Pending` in MDK.
    /// Bob's Haven storage has a `Pending` membership.
    struct PendingInviteSetup {
        bob: CircleManager,
        _bob_dir: TempDir,
        mls_group_id: GroupId,
    }

    fn setup_pending_invite() -> PendingInviteSetup {
        let relays = vec!["wss://relay.test.com".to_string()];

        let alice_dir = TempDir::new().unwrap();
        let alice = CircleManager::new_unencrypted(alice_dir.path()).unwrap();
        let alice_keys = Keys::generate();

        let bob_dir = TempDir::new().unwrap();
        let bob = CircleManager::new_unencrypted(bob_dir.path()).unwrap();
        let bob_keys = Keys::generate();

        // Bob creates a key package
        let bob_pubkey_hex = bob_keys.public_key().to_hex();
        let bundle = bob
            .mdk
            .create_key_package(&bob_pubkey_hex, &relays)
            .expect("should create bob key package");

        let tags: Vec<nostr::Tag> = bundle
            .tags
            .into_iter()
            .map(|t| nostr::Tag::parse(&t).unwrap())
            .collect();

        let bob_kp_event = EventBuilder::new(Kind::MlsKeyPackage, bundle.content)
            .tags(tags)
            .sign_with_keys(&bob_keys)
            .expect("should sign bob key package");

        // Alice creates the group with Bob
        let config = crate::nostr::mls::types::LocationGroupConfig::new("Test Circle")
            .with_description("Invitation test circle")
            .with_relay("wss://relay.test.com")
            .with_admin(&alice_keys.public_key().to_hex());

        let group_result = alice
            .mdk
            .create_group(
                &alice_keys.public_key().to_hex(),
                vec![bob_kp_event],
                config,
            )
            .expect("should create group");

        let mls_group_id = group_result.group.mls_group_id.clone();
        let nostr_group_id = group_result.group.nostr_group_id;

        // Alice merges the pending commit
        alice
            .mdk
            .merge_pending_commit(&mls_group_id)
            .expect("should merge alice pending commit");

        // Bob processes the welcome (creates pending welcome in MDK)
        let welcome_rumor = group_result
            .welcome_rumors
            .first()
            .expect("should have welcome for bob");

        bob.mdk
            .process_welcome(&nostr::EventId::all_zeros(), welcome_rumor)
            .expect("should process welcome");

        // Bob does NOT call accept_welcome — the group stays Pending in MDK.

        // Save Circle record and Pending membership to Bob's storage
        let now = chrono::Utc::now().timestamp();
        let circle = super::super::types::Circle {
            mls_group_id: mls_group_id.clone(),
            nostr_group_id,
            display_name: "Test Circle".to_string(),
            circle_type: super::super::types::CircleType::LocationSharing,
            relays,
            created_at: now,
            updated_at: now,
        };
        bob.storage.save_circle(&circle).unwrap();

        let bob_membership = super::super::types::CircleMembership {
            mls_group_id: mls_group_id.clone(),
            status: super::super::types::MembershipStatus::Pending,
            inviter_pubkey: Some(alice_keys.public_key().to_hex()),
            invited_at: now,
            responded_at: None,
        };
        bob.storage.save_membership(&bob_membership).unwrap();

        PendingInviteSetup {
            bob,
            _bob_dir: bob_dir,
            mls_group_id,
        }
    }

    #[test]
    fn accept_invitation_activates_mls_group() {
        let setup = setup_pending_invite();

        // Verify the MDK group is still pending before acceptance
        let group_before = setup
            .bob
            .mdk
            .get_group(&setup.mls_group_id)
            .expect("should get group");
        assert!(
            group_before.is_some_and(|g| g.state == crate::nostr::mls::types::GroupState::Pending),
            "group should be Pending before accept_invitation"
        );

        // Accept via the high-level API
        let circle_with_members = setup
            .bob
            .accept_invitation(&setup.mls_group_id)
            .expect("accept_invitation should succeed");

        // Verify returned circle data
        assert_eq!(circle_with_members.circle.display_name, "Test Circle");
        assert_eq!(
            circle_with_members.membership.status,
            super::super::types::MembershipStatus::Accepted
        );
        assert!(circle_with_members.membership.responded_at.is_some());

        // Verify MDK group is now active
        let group_after = setup
            .bob
            .mdk
            .get_group(&setup.mls_group_id)
            .expect("should get group after acceptance");
        assert!(
            group_after.is_some_and(|g| g.state == crate::nostr::mls::types::GroupState::Active),
            "group should be Active after accept_invitation"
        );

        // Verify no more pending welcomes for this group
        let pending = setup
            .bob
            .mdk
            .get_pending_welcomes()
            .expect("should get pending welcomes");
        assert!(
            !pending.iter().any(|w| w.mls_group_id == setup.mls_group_id),
            "no pending welcomes should remain for this group"
        );
    }

    #[test]
    fn accept_invitation_idempotent_after_partial_failure() {
        let setup = setup_pending_invite();

        // Simulate a prior partial success: accept the welcome at MDK level
        // but leave Haven storage status as Pending.
        let pending = setup
            .bob
            .mdk
            .get_pending_welcomes()
            .expect("should get pending welcomes");
        let welcome = pending
            .iter()
            .find(|w| w.mls_group_id == setup.mls_group_id)
            .expect("should find pending welcome");
        setup
            .bob
            .mdk
            .accept_welcome(welcome)
            .expect("manual accept_welcome should succeed");

        // MDK group is now Active, but Haven storage still says Pending.
        let group = setup
            .bob
            .mdk
            .get_group(&setup.mls_group_id)
            .expect("should get group");
        assert!(
            group.is_some_and(|g| g.state == crate::nostr::mls::types::GroupState::Active),
            "group should be Active after manual accept"
        );

        // Calling accept_invitation should succeed (idempotency path).
        let circle_with_members = setup
            .bob
            .accept_invitation(&setup.mls_group_id)
            .expect("accept_invitation should succeed on recovery path");

        assert_eq!(
            circle_with_members.membership.status,
            super::super::types::MembershipStatus::Accepted
        );
    }

    #[test]
    fn decline_invitation_deactivates_mls_group() {
        let setup = setup_pending_invite();

        // Decline via the high-level API
        setup
            .bob
            .decline_invitation(&setup.mls_group_id)
            .expect("decline_invitation should succeed");

        // Verify MDK group is now inactive
        let group_after = setup
            .bob
            .mdk
            .get_group(&setup.mls_group_id)
            .expect("should get group after decline");
        assert!(
            group_after.is_some_and(|g| g.state == crate::nostr::mls::types::GroupState::Inactive),
            "group should be Inactive after decline_invitation"
        );

        // Verify Haven storage status is Declined
        let membership = setup
            .bob
            .storage
            .get_membership(&setup.mls_group_id)
            .expect("should get membership")
            .expect("membership should exist");
        assert_eq!(
            membership.status,
            super::super::types::MembershipStatus::Declined
        );
    }
}
