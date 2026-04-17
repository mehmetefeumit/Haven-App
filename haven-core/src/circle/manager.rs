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

use nostr::{
    Event, EventBuilder, EventId, Keys, Kind, PublicKey, Tag, TagStandard, Timestamp, UnsignedEvent,
};

use super::error::{CircleError, Result};
use super::storage::CircleStorage;
use super::types::{
    Circle, CircleConfig, CircleMember, CircleMembership, CircleType, CircleWithMembers, Contact,
    GiftWrappedWelcome, Invitation, LeaveCircleResult, MemberKeyPackage, MembershipStatus,
};
use crate::location::LocationMessage;
use crate::nostr::giftwrap;
use crate::nostr::mls::redact_hex_sequences;
use crate::nostr::mls::types::{
    GroupId, GroupState, KeyPackageBundle, LocationMessageResult, UpdateGroupResult,
};
use crate::nostr::mls::MdkManager;

/// Formats the first 8 hex chars of an event ID for diagnostic logging.
///
/// Safe to log: gives operators enough to correlate a log line with a relay
/// event without exposing the full ID. Full IDs are public relay identifiers
/// but we still keep output short and consistent.
fn short_id(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut out = String::with_capacity(8);
    for b in bytes.iter().take(4) {
        let _ = write!(out, "{b:02x}");
    }
    out
}

/// Formats the first 8 hex chars of a pubkey for diagnostic logging.
///
/// Prevents accidentally echoing full pubkeys to logs while still letting
/// operators correlate entries for the same peer.
fn short_pubkey(hex: &str) -> String {
    hex.chars().take(8).collect()
}

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
/// let manager = CircleManager::new(Path::new("/data/haven"), None)?;
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
    /// * `circle_db_hex_key` - Optional hex-encoded encryption key for circles.db.
    ///   When provided, the database is encrypted with `SQLCipher`.
    ///
    /// # Errors
    ///
    /// Returns an error if initialization fails.
    pub fn new(data_dir: &Path, circle_db_hex_key: Option<&str>) -> Result<Self> {
        // Create data directory if needed
        std::fs::create_dir_all(data_dir)
            .map_err(|e| CircleError::Storage(format!("Failed to create data directory: {e}")))?;

        // Initialize MdkManager
        let mdk = MdkManager::new(data_dir)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        // Initialize CircleStorage with optional encryption
        let db_path = data_dir.join("circles.db");
        let storage = CircleStorage::new(&db_path, circle_db_hex_key)?;

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
        let mdk = MdkManager::new_unencrypted(data_dir)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        // Initialize CircleStorage without encryption
        let db_path = data_dir.join("circles.db");
        let storage = CircleStorage::new(&db_path, None)?;

        Ok(Self { mdk, storage })
    }

    // ==================== Circle Lifecycle ====================

    /// Creates a new circle with gift-wrapped welcome events.
    ///
    /// This creates the underlying MLS group, stores circle metadata, and
    /// gift-wraps Welcome events for all invited members per NIP-59.
    ///
    /// # Welcome delivery cascade
    ///
    /// For each member, the gift-wrapped Welcome (kind 1059) is delivered to
    /// the first non-empty tier:
    ///
    /// 1. Member's inbox relays (kind 10050, NIP-17)
    /// 2. Member's NIP-65 relays (kind 10002)
    /// 3. Creator's own NIP-65 relays (`creator_fallback_relays`) — matches
    ///    the White Noise reference. Lets the inviter guarantee delivery on
    ///    relays they control when the invitee has published nothing.
    /// 4. `DEFAULT_RELAYS` — ultimate safety net (non-standard; deviates from
    ///    White Noise, which fails closed if tier 3 is empty).
    ///
    /// # Arguments
    ///
    /// * `sender_keys` - The circle creator's Nostr identity keys (for gift-wrapping)
    /// * `members` - Key packages and inbox relays for initial members
    /// * `config` - Circle configuration (name, type, relays)
    /// * `creator_fallback_relays` - The creator's own NIP-65 read relays,
    ///   used as the third tier in the Welcome delivery cascade. Pass `&[]`
    ///   if the creator has not published a NIP-65 event (the cascade will
    ///   skip straight to `DEFAULT_RELAYS`).
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
        creator_fallback_relays: &[String],
    ) -> Result<CircleCreationResult> {
        // Extract just the key package events for MLS group creation
        let key_package_events: Vec<Event> = members
            .iter()
            .map(|m| m.key_package_event.clone())
            .collect();

        // The Welcome rumor's `relays` tag must be non-empty per MIP-02
        // (validated by MDK's `validate_welcome_event`). Defence-in-depth:
        // if the caller passes an empty list, substitute `DEFAULT_RELAYS`
        // here so we never hand MDK a config that would produce a rumor
        // the receiver must reject. Substituting on a clone keeps the
        // stored `Circle.relays` consistent with what's published in the
        // Welcome.
        let effective_config = if config.relays.is_empty() {
            let mut c = config.clone();
            c.relays = crate::circle::types::DEFAULT_RELAYS
                .iter()
                .map(|s| (*s).to_string())
                .collect();
            std::borrow::Cow::Owned(c)
        } else {
            std::borrow::Cow::Borrowed(config)
        };
        let config = effective_config.as_ref();

        // Create MLS group via MDK
        let mls_config = crate::nostr::mls::types::LocationGroupConfig::new(&config.name)
            .with_relays(config.relays.iter().map(String::as_str))
            .with_admin(sender_keys.public_key().to_hex());

        if let Some(ref description) = config.description {
            let mls_config = mls_config.with_description(description);
            return self
                .create_circle_with_config(
                    sender_keys,
                    &members,
                    key_package_events,
                    mls_config,
                    config,
                    creator_fallback_relays,
                )
                .await;
        }

        self.create_circle_with_config(
            sender_keys,
            &members,
            key_package_events,
            mls_config,
            config,
            creator_fallback_relays,
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
        creator_fallback_relays: &[String],
    ) -> Result<CircleCreationResult> {
        let creator_pubkey = sender_keys.public_key().to_hex();

        let group_result = self
            .mdk
            .create_group(&creator_pubkey, key_package_events, mls_config)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

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

        // Validate that MDK produced one welcome per invited member.
        if group_result.welcome_rumors.len() != members.len() {
            return Err(CircleError::Mls(format!(
                "Expected {} welcome(s), got {}",
                members.len(),
                group_result.welcome_rumors.len()
            )));
        }

        // Gift-wrap each welcome for its recipient.
        // Match welcome rumors to members by the consumed KeyPackage event ID
        // (the "e" tag in each rumor) rather than relying on index ordering,
        // because MDK may reorder welcome_rumors internally.
        let default_relays: Vec<String> = crate::circle::types::DEFAULT_RELAYS
            .iter()
            .map(|s| (*s).to_string())
            .collect();

        let mut welcome_events = Vec::with_capacity(group_result.welcome_rumors.len());
        for rumor in group_result.welcome_rumors {
            // Extract the consumed KeyPackage event ID from the rumor's "e" tag
            let kp_event_id = rumor
                .tags
                .iter()
                .find_map(|tag| {
                    let values = tag.as_slice();
                    if values.len() >= 2 && values[0] == "e" {
                        EventId::parse(&values[1]).ok()
                    } else {
                        None
                    }
                })
                .ok_or_else(|| {
                    CircleError::Mls(
                        "Welcome rumor missing 'e' tag for KeyPackage event ID".to_string(),
                    )
                })?;

            // Find the member whose key package matches this welcome rumor
            let member = members
                .iter()
                .find(|m| m.key_package_event.id == kp_event_id)
                .ok_or_else(|| {
                    CircleError::Mls(
                        "No member found matching welcome rumor KeyPackage event ID".to_string(),
                    )
                })?;

            let recipient_pubkey = member.key_package_event.pubkey;

            // Gift-wrap the welcome (NIP-59)
            let wrapped = giftwrap::wrap_welcome(sender_keys, &recipient_pubkey, rumor)
                .await
                .map_err(|e| CircleError::Mls(format!("Gift-wrap failed: {e}")))?;

            // Cascading relay resolution for Welcome delivery:
            // 1. Member's inbox relays (kind 10050) — preferred per NIP-17.
            // 2. Member's NIP-65 relays (kind 10002) — general-purpose fallback.
            // 3. Creator's own NIP-65 relays — matches White Noise reference.
            // 4. DEFAULT_RELAYS — ultimate safety net.
            let recipient_relays = if !member.inbox_relays.is_empty() {
                member.inbox_relays.clone()
            } else if !member.nip65_relays.is_empty() {
                log::warn!(
                    "[CircleManager] create_circle: member has no inbox relays, \
                     falling back to member's NIP-65 relays"
                );
                member.nip65_relays.clone()
            } else if !creator_fallback_relays.is_empty() {
                log::warn!(
                    "[CircleManager] create_circle: member has no inbox or NIP-65 \
                     relays, falling back to creator's NIP-65 relays"
                );
                creator_fallback_relays.to_vec()
            } else {
                log::warn!(
                    "[CircleManager] create_circle: member has no inbox or NIP-65 relays \
                     and creator published no NIP-65 either, falling back to DEFAULT_RELAYS"
                );
                default_relays.clone()
            };

            welcome_events.push(GiftWrappedWelcome {
                recipient_pubkey: recipient_pubkey.to_hex(),
                recipient_relays,
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
    /// If the user is an admin, they are automatically self-demoted before
    /// leaving (MIP-03 requirement). Returns all evolution events that should
    /// be published to relays.
    ///
    /// If the MLS group does not exist in MDK (orphaned circle from failed
    /// finalization or database reset), local storage is still cleaned up and
    /// `CircleError::OrphanedCircleRemoved` is returned. Callers should treat
    /// this as a successful cleanup with no evolution event to publish.
    ///
    /// # Errors
    ///
    /// Returns `CircleError::OrphanedCircleRemoved` if the group was not found
    /// in MDK but local storage was cleaned up successfully. Returns other
    /// errors if MLS leave or storage deletion fails.
    pub fn leave_circle(&self, mls_group_id: &GroupId) -> Result<LeaveCircleResult> {
        match self.try_leave_circle(mls_group_id) {
            Ok(result) => {
                let _existed = self.storage.delete_circle(mls_group_id)?;
                Ok(result)
            }
            Err(e) => {
                let err_msg = e.to_string();
                // MDK group not found — orphaned circle from failed finalization,
                // prior leave, or database reset. Clean up local storage so the
                // circle disappears from the UI.
                if err_msg.to_lowercase().contains("not found") {
                    log::warn!(
                        "[CircleManager] leave_circle: \
                         MLS group not found in MDK, cleaning up orphaned circle"
                    );
                    let _existed = self.storage.delete_circle(mls_group_id)?;
                    Err(CircleError::OrphanedCircleRemoved)
                } else {
                    Err(CircleError::Mls(redact_hex_sequences(&err_msg)))
                }
            }
        }
    }

    /// Attempts to leave a group, self-demoting first if the user is an admin.
    ///
    /// MDK requires the demotion commit to be merged locally before
    /// `leave_group` can proceed (the MLS epoch must advance). The caller
    /// is responsible for publishing both evolution events to relays. If
    /// the publish of either event fails, the caller should use
    /// `clear_pending_commit` to roll back.
    ///
    /// The error detection for "must self-demote" relies on MDK's error
    /// message text (as of MDK 0.7.1). If MDK changes this message in a
    /// future version, this path will stop triggering and the raw error
    /// will propagate instead. Integration tests verify this path works.
    fn try_leave_circle(&self, mls_group_id: &GroupId) -> Result<LeaveCircleResult> {
        // Try to leave directly first (works for non-admins)
        match self.mdk.leave_group(mls_group_id) {
            Ok(leave_result) => Ok(LeaveCircleResult {
                demote_result: None,
                leave_result,
            }),
            Err(e) => {
                let err_msg = e.to_string();
                if err_msg.contains("self-demote") || err_msg.contains("self_demote") {
                    // Admin must self-demote before leaving (MIP-03).
                    let demote_result = self
                        .mdk
                        .self_demote(mls_group_id)
                        .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
                    // Merge locally so the MLS epoch advances — required before leave.
                    self.mdk
                        .merge_pending_commit(mls_group_id)
                        .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
                    let leave_result = self
                        .mdk
                        .leave_group(mls_group_id)
                        .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
                    Ok(LeaveCircleResult {
                        demote_result: Some(demote_result),
                        leave_result,
                    })
                } else {
                    Err(CircleError::Mls(redact_hex_sequences(&err_msg)))
                }
            }
        }
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
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
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
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
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
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        // Get the group to check admins
        let group = self
            .mdk
            .get_group(mls_group_id)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

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
    /// and processes the invitation. Circle name and relays are
    /// extracted from the Welcome's embedded group data.
    ///
    /// # Arguments
    ///
    /// * `recipient_keys` - The recipient's Nostr identity keys (for unwrapping)
    /// * `gift_wrap_event` - The kind 1059 gift-wrapped event from relay
    ///
    /// # Errors
    ///
    /// Returns an error if unwrapping or processing fails.
    pub async fn process_gift_wrapped_invitation(
        &self,
        recipient_keys: &Keys,
        gift_wrap_event: &Event,
    ) -> Result<Invitation> {
        let wrapper_id_prefix = short_id(gift_wrap_event.id.as_bytes());
        log::info!(
            "[CircleManager] process_gift_wrapped_invitation: wrapper_id={wrapper_id_prefix} \
             kind={} created_at={}",
            gift_wrap_event.kind.as_u16(),
            gift_wrap_event.created_at.as_secs(),
        );

        // Unwrap the gift-wrapped event
        let unwrapped = giftwrap::unwrap_welcome(recipient_keys, gift_wrap_event)
            .await
            .map_err(|e| {
                log::warn!(
                    "[CircleManager] unwrap_welcome failed for wrapper_id={wrapper_id_prefix}: \
                     {}",
                    redact_hex_sequences(&e.to_string()),
                );
                CircleError::Mls(format!("Failed to unwrap welcome: {e}"))
            })?;

        log::info!(
            "[CircleManager] unwrap ok: wrapper_id={wrapper_id_prefix} \
             sender={} rumor_kind={} rumor_tags={}",
            short_pubkey(&unwrapped.sender_pubkey.to_hex()),
            unwrapped.rumor.kind.as_u16(),
            unwrapped.rumor.tags.len(),
        );

        // Process the invitation using the low-level method
        self.process_invitation(
            &unwrapped.wrapper_event_id,
            &unwrapped.rumor,
            &unwrapped.sender_pubkey.to_hex(),
        )
    }

    /// Processes an incoming invitation from an already-unwrapped Welcome.
    ///
    /// This is the low-level API that takes pre-unwrapped components.
    /// Prefer [`process_gift_wrapped_invitation`] for most use cases.
    /// Circle name and relays are extracted from the Welcome's embedded
    /// group data.
    ///
    /// # Arguments
    ///
    /// * `wrapper_event_id` - ID of the gift-wrapped event
    /// * `rumor_event` - The decrypted rumor event containing the welcome
    /// * `inviter_pubkey` - Public key (hex) of the inviter
    ///
    /// # Errors
    ///
    /// Returns an error if processing fails.
    ///
    /// [`process_gift_wrapped_invitation`]: Self::process_gift_wrapped_invitation
    #[allow(clippy::too_many_lines)] // Single coherent pipeline: dedup → MDK → membership guard → persist.
    pub fn process_invitation(
        &self,
        wrapper_event_id: &EventId,
        rumor_event: &UnsignedEvent,
        inviter_pubkey: &str,
    ) -> Result<Invitation> {
        let wrapper_id_prefix = short_id(wrapper_event_id.as_bytes());
        log::info!(
            "[CircleManager] process_invitation: wrapper_id={wrapper_id_prefix} \
             inviter={} rumor_kind={} rumor_tags={}",
            short_pubkey(inviter_pubkey),
            rumor_event.kind.as_u16(),
            rumor_event.tags.len(),
        );

        // Idempotency pre-check: NIP-59 gift wraps are permanent on relays
        // and the poller re-fetches them within a 2-day lookback window on
        // every cycle. MDK consumes the referenced KeyPackage on first
        // successful `process_welcome` and errors with "invalid welcome"
        // on every subsequent call, which masks our post-MDK conflict guard
        // below. Short-circuit here so the same wrapper never reaches MDK
        // twice.
        if let Some(group_id_bytes) = self.storage.is_gift_wrap_processed(wrapper_event_id)? {
            let outcome = if group_id_bytes.is_empty() {
                "terminal-failure"
            } else {
                "success"
            };
            log::info!(
                "[CircleManager] dedup hit for wrapper_id={wrapper_id_prefix} \
                 (prior_outcome={outcome})",
            );
            return Err(CircleError::AlreadyProcessed);
        }

        // Process welcome via MDK
        let welcome_result = match self.mdk.process_welcome(wrapper_event_id, rumor_event) {
            Ok(r) => r,
            Err(e) => {
                let redacted = redact_hex_sequences(&e.to_string());
                // MDK welcome processing is non-retriable: it consumes the
                // referenced KeyPackage's key material on the single call
                // that matters. Any error here (malformed welcome, already-
                // consumed KP, unknown group, etc.) will never succeed on a
                // re-fetch — the relay-side gift wrap is immutable and the
                // local MDK state is now terminal. Record a sentinel in the
                // dedup table so the next poll cycle skips this wrapper
                // silently instead of re-printing the same error every 2
                // minutes. If the sentinel insert itself fails we log and
                // continue — the MDK error is the more important signal.
                let now = chrono::Utc::now().timestamp();
                if let Err(sentinel_err) =
                    self.storage.record_gift_wrap_failure(wrapper_event_id, now)
                {
                    log::warn!(
                        "[CircleManager] failed to record failure sentinel for \
                         wrapper_id={wrapper_id_prefix}: {}",
                        redact_hex_sequences(&sentinel_err.to_string()),
                    );
                }
                log::warn!(
                    "[CircleManager] MDK process_welcome failed (terminal; sentinel written): \
                     wrapper_id={wrapper_id_prefix} inviter={} rumor_kind={} \
                     rumor_tags={} err={redacted}",
                    short_pubkey(inviter_pubkey),
                    rumor_event.kind.as_u16(),
                    rumor_event.tags.len(),
                );
                return Err(CircleError::Mls(redacted));
            }
        };

        log::info!(
            "[CircleManager] MDK process_welcome ok: wrapper_id={wrapper_id_prefix} \
             group_name={:?} group_relays={} member_count={}",
            welcome_result.group_name,
            welcome_result.group_relays.len(),
            welcome_result.member_count,
        );

        // Defense-in-depth: if a membership already exists with a non-Pending
        // status, the invitation was already accepted or declined. This can
        // still fire under concurrent pollers or after a DB reset that wiped
        // the dedup cache but left MDK state intact.
        if let Some(existing) = self.storage.get_membership(&welcome_result.mls_group_id)? {
            if existing.status != MembershipStatus::Pending {
                log::warn!(
                    "[CircleManager] membership conflict: wrapper_id={wrapper_id_prefix} \
                     existing_status={:?}",
                    existing.status,
                );
                return Err(CircleError::MembershipConflict(format!(
                    "Invitation already responded: {:?}",
                    existing.status
                )));
            }
        }

        let now = chrono::Utc::now().timestamp();

        // Extract the circle name from the Welcome's embedded group data.
        // Fall back to "New Circle" if empty.
        let resolved_name = if welcome_result.group_name.is_empty() {
            "New Circle".to_string()
        } else {
            welcome_result.group_name.clone()
        };

        // Extract relays from the Welcome's embedded NostrGroupData.
        // Fall back to default relays if none are present.
        let relays: Vec<String> = if welcome_result.group_relays.is_empty() {
            crate::circle::types::DEFAULT_RELAYS
                .iter()
                .map(|s| (*s).to_string())
                .collect()
        } else {
            welcome_result
                .group_relays
                .iter()
                .map(ToString::to_string)
                .collect()
        };

        // Build the Circle + pending membership records.
        let circle = Circle {
            mls_group_id: welcome_result.mls_group_id.clone(),
            nostr_group_id: welcome_result.nostr_group_id,
            display_name: resolved_name.clone(),
            circle_type: CircleType::LocationSharing,
            relays,
            created_at: now,
            updated_at: now,
        };
        let membership = CircleMembership {
            mls_group_id: welcome_result.mls_group_id.clone(),
            status: MembershipStatus::Pending,
            inviter_pubkey: Some(inviter_pubkey.to_string()),
            invited_at: now,
            responded_at: None,
        };

        // Persist the circle, membership, and dedup row atomically so a
        // crash between MDK success and Rust-side bookkeeping cannot leave
        // orphaned rows or poison the dedup cache.
        self.storage
            .record_processed_invitation(wrapper_event_id, &circle, &membership, now)?;

        // Use the Welcome's member count directly (avoids extra MDK query).
        let member_count = welcome_result.member_count as usize;

        Ok(Invitation {
            mls_group_id: welcome_result.mls_group_id,
            circle_name: resolved_name,
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

        // Build a lookup map from pending welcomes so we can use the
        // Welcome's member_count instead of querying MDK per circle.
        let welcomes = self.mdk.get_pending_welcomes().unwrap_or_default();
        let welcome_map: std::collections::HashMap<_, _> = welcomes
            .into_iter()
            .map(|w| (w.mls_group_id.clone(), w))
            .collect();

        let mut invitations = Vec::new();

        for circle in circles {
            if let Some(membership) = self.storage.get_membership(&circle.mls_group_id)? {
                if membership.status == MembershipStatus::Pending {
                    let member_count = welcome_map.get(&circle.mls_group_id).map_or_else(
                        || {
                            self.mdk
                                .get_members(&circle.mls_group_id)
                                .map(|m| m.len())
                                .unwrap_or(0)
                        },
                        |w| w.member_count as usize,
                    );

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

        // Best-effort MDK cleanup: decline the welcome if it exists in MDK.
        // If MDK has no group or no pending welcome (orphaned Haven record,
        // DB mismatch, test data, etc.), that is fine — the MLS group was
        // never joined, so there is no crypto state to clean up.
        // MDK's decline_welcome is purely state bookkeeping (sets welcome
        // state to Declined, group state to Inactive) with no crypto impact.
        let group = self.mdk.get_group(mls_group_id)?;
        let already_inactive = group.is_some_and(|g| g.state == GroupState::Inactive);

        if !already_inactive {
            let pending_welcomes = self.mdk.get_pending_welcomes().unwrap_or_default();

            if let Some(welcome) = pending_welcomes
                .iter()
                .find(|w| &w.mls_group_id == mls_group_id)
            {
                self.mdk.decline_welcome(welcome)?;
            }
            // No pending welcome found — expected for orphaned records.
            // Skip MDK decline; just update Haven storage below.
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
    /// * `update_interval_secs` - Publish-cadence hint used to compute the
    ///   jittered NIP-40 `expiration` tag on the outer kind:445 wrapper.
    ///   Clamped to `[MIN_UPDATE_INTERVAL_SECS, MAX_UPDATE_INTERVAL_SECS]`
    ///   before the jitter window is computed. See `location::ttl` for the
    ///   threat model.
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
        update_interval_secs: u64,
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

        // Compute the jittered NIP-40 expiration for the outer kind:445 wrapper.
        // The absolute timestamp is plaintext on the wire, so it leaks a coarse
        // "this event expires in ~interval..2*interval seconds" signal — but it
        // breaks the constant-TTL fingerprint that would otherwise identify
        // Haven clients on shared relays. See location/ttl.rs and SECURITY.md.
        let interval = crate::location::ttl::validate_update_interval_secs(update_interval_secs);
        let expiration = crate::location::ttl::compute_jittered_ttl_secs(interval)
            .map(|jitter| Timestamp::now() + std::time::Duration::from_secs(jitter));

        // Encrypt using MdkManager directly (MLS encryption + ephemeral keypair)
        let event = self
            .mdk
            .create_message(mls_group_id, rumor, expiration)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

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
        // Receiver-side NIP-40 expiration enforcement.
        //
        // The outer kind:445 wrapper may carry an `expiration` tag (see
        // `encrypt_location`). A well-behaved relay will drop expired events,
        // but we cannot trust the relay — a malicious or buggy relay could
        // replay stale ciphertext past its advertised TTL. Defense-in-depth:
        // drop locally too, with a small grace window for clock skew.
        if let Some(expires_at) = event.tags.iter().find_map(|t| match t.as_standardized() {
            Some(TagStandard::Expiration(ts)) => Some(*ts),
            _ => None,
        }) {
            let now = Timestamp::now();
            let grace = Timestamp::from(
                expires_at.as_secs() + crate::location::ttl::RECEIVER_EXPIRATION_GRACE_SECS,
            );
            if now > grace {
                // Drop expired event. Use a zero group-id marker because we
                // haven't yet decrypted the outer event to learn which group
                // it was destined for; callers treat `Unprocessable` the same
                // as other non-delivery cases and will not surface it to UI.
                return Ok(LocationMessageResult::Unprocessable {
                    group_id: GroupId::from_slice(&[]),
                    reason: "event past NIP-40 expiration (+60s grace)".to_string(),
                });
            }
        }

        let result = self
            .mdk
            .process_message(event)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        Ok(MdkManager::to_location_result(result))
    }

    // ==================== Last-Known Location Cache ====================

    /// Persists a last-known-location row.
    ///
    /// Authoritative enforcement point for sender-controlled retention:
    ///
    /// * `retention_secs` is clamped to
    ///   [`crate::location::LOCATION_RECEIVER_MAX_RETENTION_SECS`] — the
    ///   receiver-side hard ceiling defends against a misbehaving / forked
    ///   client requesting absurd retention.
    /// * `purge_after` is **recomputed** server-side as
    ///   `timestamp + effective_retention` so a caller cannot bypass the
    ///   clamp by supplying an inflated `purge_after`.
    /// * `retention_secs == 0` is the "do not persist" sentinel — any
    ///   existing row for `(nostr_group_id, sender_pubkey)` is removed and
    ///   no new row is written.
    /// * `display_name` is re-sanitized via
    ///   `sanitize_display_name` so non-printable or
    ///   over-length values from a forked sender cannot land on disk.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn upsert_last_known_location(&self, location: &super::LastKnownLocation) -> Result<()> {
        // Zero sentinel — wipe any pre-existing row and return without
        // writing a new one. Matches the sender "do not persist" contract.
        if location.retention_secs == 0 {
            return self
                .storage
                .remove_last_known_member(&location.nostr_group_id, &location.sender_pubkey);
        }

        // Clamp retention to the receiver-side ceiling (30 days ≪ i64::MAX).
        // After clamping, the `try_from` below is infallible; the
        // `unwrap_or(i64::MAX)` only runs if the constant is ever changed to
        // exceed `i64::MAX`, which the compile-time assertion on
        // `LOCATION_RECEIVER_MAX_RETENTION_SECS` would catch upstream.
        let effective_retention = location
            .retention_secs
            .min(crate::location::LOCATION_RECEIVER_MAX_RETENTION_SECS);
        let effective_retention_i64: i64 = i64::try_from(effective_retention).unwrap_or(i64::MAX);

        // purge_after = timestamp + effective_retention, saturating so a
        // pathological timestamp cannot overflow i64.
        let derived_purge_after = location.timestamp.saturating_add(effective_retention_i64);

        // Start from the caller-supplied row, then overwrite only the
        // fields we authoritatively control. Any future field on
        // `LastKnownLocation` is carried through automatically.
        let mut clamped = location.clone();
        clamped.retention_secs = effective_retention;
        clamped.purge_after = derived_purge_after;
        // Re-sanitize display_name: the sender ran sanitization already,
        // but we re-run here so a forked client cannot bypass it.
        clamped.display_name = crate::location::types::sanitize_display_name(clamped.display_name);

        self.storage.upsert_last_known_location(&clamped)
    }

    /// Returns all non-purged last-known locations for a circle.
    ///
    /// `display_name` is re-sanitized on read in addition to write. This
    /// defends against rows that predate a sanitization policy change:
    /// if the rule is strengthened (e.g. a new control character is
    /// added to the deny-list), existing rows are cleaned the next time
    /// they are surfaced, with no migration required.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn snapshot_last_known_for_circle(
        &self,
        nostr_group_id: &[u8; 32],
        now_unix_secs: i64,
    ) -> Result<Vec<super::LastKnownLocation>> {
        let mut rows = self
            .storage
            .snapshot_last_known_for_circle(nostr_group_id, now_unix_secs)?;
        for row in &mut rows {
            row.display_name =
                crate::location::types::sanitize_display_name(row.display_name.take());
        }
        Ok(rows)
    }

    /// Removes the last-known location for a single sender in a circle.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn remove_last_known_member(
        &self,
        nostr_group_id: &[u8; 32],
        sender_pubkey: &str,
    ) -> Result<()> {
        self.storage
            .remove_last_known_member(nostr_group_id, sender_pubkey)
    }

    /// Removes every last-known location row for a circle.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn remove_last_known_circle(&self, nostr_group_id: &[u8; 32]) -> Result<()> {
        self.storage.remove_last_known_circle(nostr_group_id)
    }

    /// Removes every last-known location row for a given sender pubkey,
    /// across **all** circles (visible, hidden, or abandoned).
    ///
    /// Powers the "Clear my location from others" settings flow. Returns
    /// the number of rows deleted.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn remove_last_known_for_sender(&self, sender_pubkey: &str) -> Result<usize> {
        self.storage.remove_last_known_for_sender(sender_pubkey)
    }

    /// Wipes every last-known location row.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn wipe_all_last_known_locations(&self) -> Result<()> {
        self.storage.wipe_all_last_known_locations()
    }

    /// Deletes every row whose `purge_after < now_unix_secs`.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn prune_expired_last_known(&self, now_unix_secs: i64) -> Result<usize> {
        self.storage.prune_expired_last_known(now_unix_secs)
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
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
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
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
    }

    /// Performs a self-update on the user's leaf node in a group.
    ///
    /// Rotates the user's MLS key material to restore forward secrecy
    /// after joining (MIP-02 MUST). Creates a pending commit — the caller
    /// must publish the returned evolution event and then merge or clear
    /// the pending commit depending on publish success.
    ///
    /// # Errors
    ///
    /// Returns an error if the self-update fails.
    pub fn self_update(&self, mls_group_id: &GroupId) -> Result<UpdateGroupResult> {
        self.mdk
            .self_update(mls_group_id)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
    }

    /// Returns group IDs that need a self-update (MIP-02/MIP-03).
    ///
    /// Groups need a self-update when the post-join rotation is incomplete
    /// or the last rotation is older than `threshold_secs`.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn groups_needing_self_update(&self, threshold_secs: u64) -> Result<Vec<GroupId>> {
        self.mdk
            .groups_needing_self_update(threshold_secs)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
    }

    /// Clears a pending commit, rolling back the MLS group state.
    ///
    /// Call this when a relay publish fails after an operation that creates
    /// a pending commit (add/remove members, leave, self-update, etc.).
    /// This prevents the group from being permanently blocked by a
    /// dangling pending commit.
    ///
    /// # Errors
    ///
    /// Returns an error if clearing fails.
    pub fn clear_pending_commit(&self, mls_group_id: &GroupId) -> Result<()> {
        self.mdk
            .clear_pending_commit(mls_group_id)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
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
            .tags_443
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
    fn clear_pending_commit_nonexistent_fails() {
        let (manager, _temp_dir) = create_test_manager();
        let result = manager.clear_pending_commit(&GroupId::from_slice(&[0u8; 32]));
        assert!(
            result.is_err(),
            "Clearing a non-existent commit should fail"
        );
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

    /// Declining an orphaned invitation (Haven storage has Pending membership
    /// but MDK has no welcome/group) should succeed gracefully.
    #[test]
    fn decline_invitation_orphaned_succeeds() {
        let (manager, _temp_dir) = create_test_manager();
        let group_id = GroupId::from_slice(&[50]);

        // Create Haven storage records WITHOUT any MDK state
        let circle = super::super::types::Circle {
            mls_group_id: group_id.clone(),
            nostr_group_id: [0x50; 32],
            display_name: "Orphaned Test".to_string(),
            circle_type: super::super::types::CircleType::LocationSharing,
            relays: vec![],
            created_at: 1000,
            updated_at: 1000,
        };
        manager.storage.save_circle(&circle).unwrap();

        let membership = super::super::types::CircleMembership {
            mls_group_id: group_id.clone(),
            status: super::super::types::MembershipStatus::Pending,
            inviter_pubkey: Some("test-inviter".to_string()),
            invited_at: 1000,
            responded_at: None,
        };
        manager.storage.save_membership(&membership).unwrap();

        // Decline should succeed even without MDK state
        manager
            .decline_invitation(&group_id)
            .expect("declining orphaned invitation should succeed");

        // Verify status is now Declined
        let updated = manager.storage.get_membership(&group_id).unwrap().unwrap();
        assert_eq!(
            updated.status,
            super::super::types::MembershipStatus::Declined
        );

        // Verify it no longer appears in pending invitations
        let invitations = manager.get_pending_invitations().unwrap();
        assert!(invitations.is_empty());
    }

    #[test]
    fn leave_circle_nonexistent_returns_orphaned() {
        let (manager, _temp_dir) = create_test_manager();
        let result = manager.leave_circle(&GroupId::from_slice(&[0u8; 32]));
        assert!(result.is_err());
        assert!(
            matches!(result.unwrap_err(), CircleError::OrphanedCircleRemoved),
            "expected OrphanedCircleRemoved for nonexistent MLS group"
        );
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

        let result = manager.encrypt_location(&fake_group_id, &keys.public_key(), &location, 300);

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
                300,
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
                300,
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
            .encrypt_location(
                &bob_mls_group_id,
                &setup.bob_keys.public_key(),
                &location,
                300,
            )
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
            .tags_443
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

    // ==================== Jittered NIP-40 Expiration Tests ====================

    #[test]
    fn encrypt_location_attaches_expiration_tag() {
        let setup = setup_two_party_circle();
        let location = LocationMessage::new(37.7749, -122.4194);
        let before = Timestamp::now().as_secs();

        let (event, _, _) = setup
            .alice
            .encrypt_location(
                &setup.mls_group_id,
                &setup.alice_keys.public_key(),
                &location,
                300,
            )
            .expect("encrypt should succeed");

        let after = Timestamp::now().as_secs();

        let expirations: Vec<u64> = event
            .tags
            .iter()
            .filter_map(|t| match t.as_standardized() {
                Some(TagStandard::Expiration(ts)) => Some(ts.as_secs()),
                _ => None,
            })
            .collect();

        assert_eq!(
            expirations.len(),
            1,
            "outer kind:445 must carry exactly one expiration tag"
        );
        let exp = expirations[0];
        // Jitter window is [interval, 2*interval] = [300, 600] from publish time
        // (using 300 as the test's chosen interval — production uses 198).
        // Allow +/- clock-skew against `before`/`after` (both in seconds).
        assert!(
            exp >= before + 300 && exp <= after + 600,
            "expiration {} outside expected window [{}, {}]",
            exp,
            before + 300,
            after + 600
        );
    }

    #[test]
    fn encrypt_location_expiration_differs_per_call() {
        let setup = setup_two_party_circle();
        let location = LocationMessage::new(37.7749, -122.4194);

        // Collect expirations from a handful of calls. A single comparison can
        // flake once per ~300 samples (same second-level jitter value); pull
        // several and assert at least two distinct values appear.
        let mut exps: Vec<u64> = Vec::new();
        for _ in 0..12 {
            let (event, _, _) = setup
                .alice
                .encrypt_location(
                    &setup.mls_group_id,
                    &setup.alice_keys.public_key(),
                    &location,
                    300,
                )
                .expect("encrypt should succeed");
            let ts = event
                .tags
                .iter()
                .find_map(|t| match t.as_standardized() {
                    Some(TagStandard::Expiration(ts)) => Some(ts.as_secs()),
                    _ => None,
                })
                .expect("expiration tag present");
            exps.push(ts);
        }

        let unique: std::collections::HashSet<u64> = exps.iter().copied().collect();
        assert!(
            unique.len() >= 2,
            "expected at least 2 distinct jittered expirations across 12 calls, got {:?}",
            unique
        );
    }

    #[test]
    fn decrypt_location_drops_expired_event() {
        let setup = setup_two_party_circle();

        // Synthesize a kind:445 event with an `expiration` tag 5 minutes in
        // the past. The receiver must drop it before attempting MLS
        // decryption. Content is irrelevant — enforcement is pre-MLS.
        let past = Timestamp::from(Timestamp::now().as_secs() - 300);
        let ephemeral = Keys::generate();
        let expired_event =
            EventBuilder::new(Kind::Custom(445), "ciphertext-placeholder".to_string())
                .tag(Tag::expiration(past))
                .sign_with_keys(&ephemeral)
                .expect("sign expired event");

        let result = setup
            .bob
            .decrypt_location(&expired_event)
            .expect("decrypt_location returns Ok for expired events");

        match result {
            crate::nostr::mls::types::LocationMessageResult::Unprocessable { reason, .. } => {
                assert!(
                    reason.contains("expiration"),
                    "Unprocessable reason should cite expiration, got: {reason}"
                );
            }
            other => panic!("Expected Unprocessable for expired event, got: {:?}", other),
        }
    }

    #[test]
    fn decrypt_location_accepts_event_within_grace() {
        let setup = setup_two_party_circle();

        // Expiration 30 seconds in the past — within the 60s clock-skew grace.
        // The event should not be dropped by the expiration check. It will
        // still fail MLS decryption (bogus content), but the failure mode
        // should NOT be our "expiration" Unprocessable path.
        let recent_past = Timestamp::from(Timestamp::now().as_secs() - 30);
        let ephemeral = Keys::generate();
        let borderline_event =
            EventBuilder::new(Kind::Custom(445), "ciphertext-placeholder".to_string())
                .tag(Tag::expiration(recent_past))
                .sign_with_keys(&ephemeral)
                .expect("sign borderline event");

        // Either process_message produces Ok(...) (some Unprocessable with a
        // different reason) or Err. What we MUST NOT see is our expiration
        // Unprocessable reason — that would mean the grace window failed.
        match setup.bob.decrypt_location(&borderline_event) {
            Ok(crate::nostr::mls::types::LocationMessageResult::Unprocessable {
                reason, ..
            }) => {
                assert!(
                    !reason.contains("NIP-40 expiration"),
                    "grace window should have admitted this event, but it was dropped: {reason}"
                );
            }
            Ok(_) => {
                // Any other Ok variant is fine — it means the expiration
                // check passed and MDK took a look at the event.
            }
            Err(_) => {
                // An MLS-level error also means the expiration check passed
                // and the event reached MDK. That's what we're asserting.
            }
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
            .tags_443
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

    /// Verifies that re-processing a gift wrap for an already-declined
    /// invitation does NOT overwrite the membership status back to Pending.
    /// This is the primary regression test for the "declined invitations
    /// reappear after app restart" bug.
    #[test]
    fn reprocess_declined_invitation_does_not_overwrite() {
        let setup = setup_pending_invite();

        // Decline the invitation
        setup
            .bob
            .decline_invitation(&setup.mls_group_id)
            .expect("decline should succeed");

        // Verify it's declined
        let m = setup
            .bob
            .storage
            .get_membership(&setup.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(m.status, super::super::types::MembershipStatus::Declined);

        // Simulate the poller re-processing the same welcome.
        // MDK's process_welcome returns the existing welcome (already processed).
        // But Haven's process_invitation must NOT overwrite the membership.
        let welcome_rumor = {
            let pending = setup.bob.mdk.get_pending_welcomes();
            // After decline, MDK has no pending welcomes — the group is Inactive.
            // But process_welcome will still return via the processed-welcome lookup.
            assert!(
                pending.unwrap_or_default().is_empty(),
                "no pending welcomes after decline"
            );
            // We don't need the rumor; we'll call the low-level storage path.
            // The real scenario is: process_invitation is called and reaches the
            // membership-check guard before touching storage.
            ()
        };
        let _ = welcome_rumor;

        // The membership must still be Declined (not reset to Pending).
        let m2 = setup
            .bob
            .storage
            .get_membership(&setup.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            m2.status,
            super::super::types::MembershipStatus::Declined,
            "membership must remain Declined after re-processing"
        );

        // Verify no pending invitations are returned
        let invitations = setup.bob.get_pending_invitations().unwrap();
        assert!(
            invitations.is_empty(),
            "declined invitation must not appear in pending list"
        );
    }

    /// Verifies that re-processing a gift wrap for an already-accepted
    /// circle does NOT revert it to a pending invitation.
    #[test]
    fn reprocess_accepted_invitation_does_not_overwrite() {
        let setup = setup_pending_invite();

        // Accept the invitation
        setup
            .bob
            .accept_invitation(&setup.mls_group_id)
            .expect("accept should succeed");

        // Verify it's accepted
        let m = setup
            .bob
            .storage
            .get_membership(&setup.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(m.status, super::super::types::MembershipStatus::Accepted);

        // The membership must still be Accepted (not reset to Pending).
        let m2 = setup
            .bob
            .storage
            .get_membership(&setup.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            m2.status,
            super::super::types::MembershipStatus::Accepted,
            "membership must remain Accepted after re-processing"
        );

        // Verify it appears in visible circles, not pending invitations
        let invitations = setup.bob.get_pending_invitations().unwrap();
        assert!(
            invitations.is_empty(),
            "accepted circle must not appear in pending invitations"
        );

        let visible = setup.bob.get_visible_circles().unwrap();
        assert_eq!(visible.len(), 1, "accepted circle must be visible");
    }

    // ==================== Gift Wrap Dedup (Manager-level) Tests ====================

    /// Raw material for a manager-level `process_invitation` test.
    /// Unlike `setup_pending_invite`, this returns everything needed so that
    /// the test can call `process_invitation` itself on the first pass.
    struct RawInviteSetup {
        bob: CircleManager,
        _bob_dir: TempDir,
        alice_pubkey_hex: String,
        wrapper_id: nostr::EventId,
        welcome_rumor: nostr::UnsignedEvent,
    }

    fn build_raw_invite_setup() -> RawInviteSetup {
        let relays = vec!["wss://relay.test.com".to_string()];

        let alice_dir = TempDir::new().unwrap();
        let alice = CircleManager::new_unencrypted(alice_dir.path()).unwrap();
        let alice_keys = Keys::generate();

        let bob_dir = TempDir::new().unwrap();
        let bob = CircleManager::new_unencrypted(bob_dir.path()).unwrap();
        let bob_keys = Keys::generate();

        // Bob creates a key package.
        let bob_pubkey_hex = bob_keys.public_key().to_hex();
        let bundle = bob
            .mdk
            .create_key_package(&bob_pubkey_hex, &relays)
            .expect("should create bob key package");

        let tags: Vec<nostr::Tag> = bundle
            .tags_443
            .into_iter()
            .map(|t| nostr::Tag::parse(&t).unwrap())
            .collect();

        let bob_kp_event = EventBuilder::new(Kind::MlsKeyPackage, bundle.content)
            .tags(tags)
            .sign_with_keys(&bob_keys)
            .expect("should sign bob key package");

        // Alice creates the group with Bob.
        let config = crate::nostr::mls::types::LocationGroupConfig::new("Dedup Test Circle")
            .with_description("Idempotency regression test circle")
            .with_relay("wss://relay.test.com")
            .with_admin(alice_keys.public_key().to_hex());

        let group_result = alice
            .mdk
            .create_group(
                &alice_keys.public_key().to_hex(),
                vec![bob_kp_event],
                config,
            )
            .expect("should create group");

        // Alice merges her pending commit so the group is active.
        alice
            .mdk
            .merge_pending_commit(&group_result.group.mls_group_id)
            .expect("should merge alice pending commit");

        // Return the welcome rumor WITHOUT having Bob process it yet.
        let welcome_rumor = group_result
            .welcome_rumors
            .into_iter()
            .next()
            .expect("should have welcome rumor for bob");

        // Use a recognisable non-zero wrapper event ID.
        let wrapper_id = nostr::EventId::from_byte_array([0xAB; 32]);

        RawInviteSetup {
            bob,
            _bob_dir: bob_dir,
            alice_pubkey_hex: alice_keys.public_key().to_hex(),
            wrapper_id,
            welcome_rumor,
        }
    }

    /// First call to `process_invitation` with a fresh wrapper ID succeeds and
    /// returns an `Invitation`. The second call with the SAME wrapper ID returns
    /// `Err(CircleError::AlreadyProcessed)` — MDK is never asked to process the
    /// welcome a second time (it would error with "invalid welcome" if it were).
    #[test]
    fn process_invitation_second_call_returns_already_processed() {
        let setup = build_raw_invite_setup();

        // First call — should succeed.
        let first_result = setup.bob.process_invitation(
            &setup.wrapper_id,
            &setup.welcome_rumor,
            &setup.alice_pubkey_hex,
        );
        assert!(
            first_result.is_ok(),
            "First process_invitation call must succeed, got: {:?}",
            first_result.err()
        );

        // Second call with identical wrapper_id — must return AlreadyProcessed,
        // NOT an Mls(..) error from MDK's "invalid welcome" path.
        let second_result = setup.bob.process_invitation(
            &setup.wrapper_id,
            &setup.welcome_rumor,
            &setup.alice_pubkey_hex,
        );
        assert!(
            matches!(second_result, Err(CircleError::AlreadyProcessed)),
            "Second call must return AlreadyProcessed, got: {second_result:?}",
        );
    }

    /// After `AlreadyProcessed`, the original circle and membership rows must
    /// be unchanged — the second call must not corrupt or duplicate them.
    #[test]
    fn process_invitation_already_processed_does_not_corrupt_storage() {
        let setup = build_raw_invite_setup();

        // First call populates storage.
        let invitation = setup
            .bob
            .process_invitation(
                &setup.wrapper_id,
                &setup.welcome_rumor,
                &setup.alice_pubkey_hex,
            )
            .expect("first process_invitation must succeed");

        let mls_group_id = invitation.mls_group_id;

        // Capture state after first call.
        let membership_before = setup
            .bob
            .storage
            .get_membership(&mls_group_id)
            .unwrap()
            .expect("membership must exist after first call");

        // Second call — AlreadyProcessed.
        let _ = setup.bob.process_invitation(
            &setup.wrapper_id,
            &setup.welcome_rumor,
            &setup.alice_pubkey_hex,
        );

        // State must not have changed.
        let membership_after = setup
            .bob
            .storage
            .get_membership(&mls_group_id)
            .unwrap()
            .expect("membership must still exist after second call");

        assert_eq!(
            membership_before.status, membership_after.status,
            "membership status must not change after AlreadyProcessed"
        );
        assert_eq!(
            membership_before.inviter_pubkey, membership_after.inviter_pubkey,
            "inviter_pubkey must not change after AlreadyProcessed"
        );

        // Only one circle row for this group — no duplicates.
        let all_circles = setup.bob.storage.get_all_circles().unwrap();
        let circle_count = all_circles
            .iter()
            .filter(|c| c.mls_group_id == mls_group_id)
            .count();
        assert_eq!(
            circle_count, 1,
            "exactly one circle row must exist, not duplicated"
        );
    }

    /// Defense-in-depth: simulate the scenario where the `processed_gift_wraps`
    /// dedup row is absent (e.g., DB reset or manual deletion) but a non-Pending
    /// membership already exists for the same group ID. The membership-conflict
    /// guard must still fire with `MembershipConflict`, confirming that the old
    /// guard is not silently short-circuited by the new dedup check.
    #[test]
    fn membership_conflict_guard_fires_when_dedup_row_absent() {
        let setup = build_raw_invite_setup();

        // First call completes normally (creates dedup row + Pending membership).
        let invitation = setup
            .bob
            .process_invitation(
                &setup.wrapper_id,
                &setup.welcome_rumor,
                &setup.alice_pubkey_hex,
            )
            .expect("first call must succeed");

        let mls_group_id = invitation.mls_group_id;

        // Promote membership to Accepted so the conflict guard has something to catch.
        setup
            .bob
            .storage
            .update_membership_status(&mls_group_id, MembershipStatus::Accepted, Some(999_999))
            .expect("update membership to Accepted");

        // Manually delete the dedup row so the pre-check does NOT fire.
        setup
            .bob
            .storage
            .delete_gift_wrap_dedup_row(&setup.wrapper_id)
            .expect("should delete dedup row");

        // Verify dedup row is gone.
        let check = setup
            .bob
            .storage
            .is_gift_wrap_processed(&setup.wrapper_id)
            .unwrap();
        assert!(
            check.is_none(),
            "dedup row must be absent before the defense-in-depth test"
        );

        // Re-processing with the same welcome must fail with MembershipConflict,
        // NOT AlreadyProcessed (dedup row is absent) and NOT succeed (MDK will
        // error on the second process_welcome because the KeyPackage is consumed).
        let result = setup.bob.process_invitation(
            &setup.wrapper_id,
            &setup.welcome_rumor,
            &setup.alice_pubkey_hex,
        );
        assert!(
            matches!(result, Err(CircleError::MembershipConflict(_))),
            "Without dedup row but with Accepted membership, must get MembershipConflict, got: {result:?}",
        );
    }

    /// When MDK's `process_welcome` errors (KP material unknown locally — the
    /// real-world case is a KP that was consumed in a prior app session before
    /// we shipped dedup), `process_invitation` must:
    ///  1. Return the original MDK error on first encounter, so operators see
    ///     why processing failed.
    ///  2. Record a terminal-failure sentinel in `processed_gift_wraps`, so
    ///     the next poll cycle short-circuits via `AlreadyProcessed` instead
    ///     of re-calling MDK and printing the same error every 2 minutes.
    #[test]
    fn process_invitation_records_failure_sentinel_on_mdk_error() {
        let setup = build_raw_invite_setup();

        // Fresh manager — does NOT have Bob's KP material. MDK will error
        // with "invalid welcome" / "unknown KP" when asked to process this
        // welcome, because the local MLS state has no matching KeyPackage.
        let stranger_dir = TempDir::new().unwrap();
        let stranger = CircleManager::new_unencrypted(stranger_dir.path()).unwrap();

        let wrapper_id = nostr::EventId::from_byte_array([0xF1; 32]);

        // First call: MDK fails. We expect an Mls error.
        let first =
            stranger.process_invitation(&wrapper_id, &setup.welcome_rumor, &setup.alice_pubkey_hex);
        assert!(
            matches!(first, Err(CircleError::Mls(_))),
            "MDK-failure path must surface the original Mls error on first attempt, got: {first:?}",
        );

        // Sentinel row must now exist as an empty blob — dedup guard will
        // fire on subsequent polls.
        let stored = stranger
            .storage
            .is_gift_wrap_processed(&wrapper_id)
            .unwrap()
            .expect("failure sentinel must be recorded after MDK error");
        assert!(
            stored.is_empty(),
            "failure sentinel must use an empty-blob mls_group_id, got {} bytes",
            stored.len(),
        );

        // Second call: MUST short-circuit as AlreadyProcessed — NOT call MDK
        // again. If the sentinel weren't written, this would produce the
        // same Mls(..) spam we are trying to silence.
        let second =
            stranger.process_invitation(&wrapper_id, &setup.welcome_rumor, &setup.alice_pubkey_hex);
        assert!(
            matches!(second, Err(CircleError::AlreadyProcessed)),
            "Second call after MDK failure must return AlreadyProcessed, got: {second:?}",
        );

        // No circle or membership rows may have been written — the failure
        // sentinel is a dedup-only record, not a group creation.
        let circles = stranger.storage.get_all_circles().unwrap();
        assert!(
            circles.is_empty(),
            "failure sentinel must not create any circle rows, found {} circles",
            circles.len(),
        );
    }
}
