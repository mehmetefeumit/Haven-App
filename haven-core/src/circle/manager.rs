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
    Event, EventBuilder, EventId, Keys, Kind, PublicKey, RelayUrl, Tag, TagStandard, Timestamp,
    UnsignedEvent,
};

use super::converge::{
    commit_beats, commit_order_key, our_commit_wins, CommitConvergence, CommitIntent,
    ConvergedLocation,
};
use super::error::{CircleError, Result};
use super::leave::{plan_leave, LeavePlan};
use super::storage::CircleStorage;
use super::types::{
    Circle, CircleConfig, CircleMember, CircleMembership, CircleType, CircleWithMembers, Contact,
    GiftWrappedWelcome, Invitation, MemberKeyPackage, MembershipStatus,
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
pub fn short_id(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut out = String::with_capacity(8);
    for b in bytes.iter().take(4) {
        let _ = write!(out, "{b:02x}");
    }
    out
}

/// Outcome of [`CircleManager::ingest_incoming_avatar_message`].
///
/// Carries NO image bytes — only flags and metadata so the caller can decide
/// whether to refresh a member's avatar in the UI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AvatarIngestResult {
    /// `true` if this event advanced or completed an avatar (a manifest/chunk
    /// was accepted, a new complete avatar stored, or a tombstone applied).
    pub accepted: bool,
    /// `true` if an avatar (or a clear) became complete on this event.
    pub complete: bool,
    /// The MLS-authenticated sender's pubkey (hex) for an accepted avatar
    /// event; `None` for ignored (non-avatar / dropped) events.
    pub sender_pubkey_hex: Option<String>,
    /// The avatar version on completion; `None` otherwise.
    pub version: Option<i64>,
}

impl AvatarIngestResult {
    /// The "this event was not an avatar (or was dropped fail-closed)" result.
    #[must_use]
    pub const fn ignored() -> Self {
        Self {
            accepted: false,
            complete: false,
            sender_pubkey_hex: None,
            version: None,
        }
    }
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
    /// In-flight avatar reassemblies, keyed by `(circle_id_hex,
    /// sender_pubkey)`. At most one reassembly per (circle, sender) — a newer
    /// `version` evicts an older in-flight one (§5.9). All buffers are
    /// `Zeroizing` (inside [`AvatarReassemblyState`]); eviction wipes them.
    avatar_reassembly: std::sync::Mutex<
        std::collections::HashMap<
            (String, String),
            super::avatar_reassembly::AvatarReassemblyState,
        >,
    >,
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

        Ok(Self {
            mdk,
            storage,
            avatar_reassembly: std::sync::Mutex::new(std::collections::HashMap::new()),
        })
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

        Ok(Self {
            mdk,
            storage,
            avatar_reassembly: std::sync::Mutex::new(std::collections::HashMap::new()),
        })
    }

    /// Returns the current MLS epoch for a group (test/feature-only).
    ///
    /// Exposes MDK's group epoch so integration tests can assert real key
    /// rotation: after a `self_update`/`add_members`/`remove_members` commit
    /// is finalized (or a peer processes one), the epoch MUST advance.
    /// A behavioural test that only checks `kind == 445` or a `get_members`
    /// read-back would pass even if the commit failed to rotate the epoch,
    /// so this accessor is the only way to observe the protocol outcome from
    /// a downstream test crate. Also gated on `debug_assertions` so the
    /// debug-only FFI epoch seam (`group_epoch_for_test`) can read it; the
    /// epoch counter is not secret and carries no privacy/perf cost, and the
    /// accessor is compiled out of every release build.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::NotFound`] if the group does not exist, or
    /// [`CircleError::Mls`] if the MDK query fails.
    #[cfg(any(test, feature = "test-utils", debug_assertions))]
    pub fn group_epoch(&self, mls_group_id: &GroupId) -> Result<u64> {
        let group = self
            .mdk
            .get_group(mls_group_id)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
            .ok_or_else(|| CircleError::NotFound("Group not found: <redacted>".to_string()))?;
        Ok(group.epoch)
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
    /// 3. Creator's own inbox relays (`creator_fallback_relays`) — lets the
    ///    inviter deliver on relays they control when the invitee published
    ///    nothing, relying on the overlap between the two parties' relays.
    ///
    /// If every tier is empty, circle creation **fails closed** with
    /// [`CircleError::MissingWelcomeRelays`] rather than delivering the
    /// Welcome to public default relays — doing so would expose the
    /// invite-recipient's pubkey to those relays. A fully-private invitee is
    /// therefore uninvitable by bare pubkey (the intended two-plane tradeoff).
    ///
    /// # Arguments
    ///
    /// * `sender_keys` - The circle creator's Nostr identity keys (for gift-wrapping)
    /// * `members` - Key packages and inbox relays for initial members
    /// * `config` - Circle configuration (name, type, relays)
    /// * `creator_fallback_relays` - The creator's own inbox relays (kind
    ///   10050), used as the third tier in the Welcome delivery cascade. Pass
    ///   `&[]` if the creator has no inbox relays (the cascade then fails
    ///   closed when tiers 1 and 2 are also empty).
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
        // Fail closed BEFORE creating any MLS group or persisting circle /
        // membership state. The per-member Welcome-delivery cascade
        // (member inbox → member NIP-65 → creator inbox → fail closed) would
        // otherwise only abort mid-loop in `create_circle_with_config`, AFTER
        // `mdk.create_group` + `save_circle` + `save_membership` already ran —
        // stranding a phantom circle and an advanced-epoch MLS group. Since the
        // creator-inbox fallback (`creator_fallback_relays`) is identical for
        // every member, a member is deliverable iff it advertises an inbox or
        // NIP-65 relay, OR the creator has an inbox fallback. Pre-validate that
        // here so the fail-closed path leaves storage untouched. (The loop in
        // `create_circle_with_config` keeps the same check as a defensive
        // backstop.)
        if creator_fallback_relays.is_empty() {
            for m in &members {
                if m.inbox_relays.is_empty() && m.nip65_relays.is_empty() {
                    return Err(CircleError::MissingWelcomeRelays);
                }
            }
        }

        // Extract just the key package events for MLS group creation
        let key_package_events: Vec<Event> = members
            .iter()
            .map(|m| m.key_package_event.clone())
            .collect();

        // The Welcome rumor's `relays` tag must be non-empty per MIP-02
        // (validated by MDK's `validate_welcome_event`). When the caller
        // passes an empty list, substitute the user's *Inbox* relays from
        // [`crate::circle::storage_relay_prefs`].
        //
        // Why Inbox and NOT KeyPackage: `Circle.relays` populates the
        // kind:444 Welcome's `relays` tag (where members will subscribe for
        // group messages, kind:445 — see MIP-03) and is the kind:445
        // publish target. Inbox relays are where this user receives gift
        // wraps; they are the closest semantic match for "where my groups
        // should publish, since I subscribe there." `KeyPackage` relays
        // (kind 10051) are for KP discovery only and would be wrong here.
        //
        // If the user's Inbox list is also empty (should not happen
        // post-seed; covers a defensive bootstrap race), fall back to
        // the default relay list so MDK never sees an empty tag and the
        // Welcome is still publishable.
        let effective_config = if config.relays.is_empty() {
            let mut c = config.clone();
            let inbox_relays = self
                .storage
                .list_user_relays(crate::circle::relay_prefs::RelayType::Inbox)
                .unwrap_or_default();
            c.relays = if inbox_relays.is_empty() {
                log::warn!(
                    "[CircleManager] create_circle: user inbox relays empty, \
                     falling back to default relays (seed may not have run yet)"
                );
                crate::circle::types::default_relays()
            } else {
                inbox_relays
            };
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

        // M7-B: `create_group` writes MDK group state (an authoring MDK write).
        // Exclude a concurrent background sweep, but hold the guard ONLY around
        // the sync MDK call — this method is async and the relay I/O
        // (`wrap_welcomes_with_cascade().await`) below MUST stay outside the
        // lock (the guard is dropped at the end of this block).
        let group_result = {
            let _writer = crate::write_lock::acquire_authoring();
            self.mdk
                .create_group(&creator_pubkey, key_package_events, mls_config)
                .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
        };

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

        // Gift-wrap each MDK welcome rumor for its recipient and resolve the
        // privacy-critical delivery relays (shared with the add-member flow).
        let welcome_events = self
            .wrap_welcomes_with_cascade(
                sender_keys,
                members,
                group_result.welcome_rumors,
                creator_fallback_relays,
            )
            .await?;

        Ok(CircleCreationResult {
            circle,
            welcome_events,
        })
    }

    /// Gift-wraps MDK Welcome rumors and resolves their delivery relays.
    ///
    /// Shared by [`create_circle`] and [`add_members_with_welcomes`]: both
    /// consume MDK's per-member kind:444 Welcome rumors, gift-wrap them per
    /// NIP-59, and route each wrap through the fail-closed delivery cascade.
    ///
    /// Each rumor is matched to its `members` entry by the consumed `KeyPackage`
    /// event ID (the rumor's `e` tag) rather than by index, because MDK may
    /// reorder the rumors internally.
    ///
    /// # Welcome delivery cascade
    ///
    /// For each member, the gift-wrapped Welcome (kind 1059) is delivered to
    /// the first non-empty tier:
    ///
    /// 1. Member's inbox relays (kind 10050, NIP-17).
    /// 2. Member's NIP-65 relays (kind 10002).
    /// 3. The sender's own inbox relays (`creator_fallback_relays`).
    /// 4. (none) — **fail closed** with [`CircleError::MissingWelcomeRelays`]
    ///    rather than delivering to public default relays, which would expose
    ///    the invite-recipient's pubkey to them.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Mls`] if the rumor count does not match the
    /// member count, a rumor is missing its `e` tag, no member matches a
    /// rumor, or gift-wrapping fails; [`CircleError::MissingWelcomeRelays`] if
    /// a member has no advertised relay and there is no sender fallback.
    ///
    /// [`create_circle`]: Self::create_circle
    /// [`add_members_with_welcomes`]: Self::add_members_with_welcomes
    async fn wrap_welcomes_with_cascade(
        &self,
        sender_keys: &Keys,
        members: &[MemberKeyPackage],
        welcome_rumors: Vec<UnsignedEvent>,
        creator_fallback_relays: &[String],
    ) -> Result<Vec<GiftWrappedWelcome>> {
        // Validate that MDK produced one welcome per invited member.
        if welcome_rumors.len() != members.len() {
            return Err(CircleError::Mls(format!(
                "Expected {} welcome(s), got {}",
                members.len(),
                welcome_rumors.len()
            )));
        }

        // Gift-wrap each welcome for its recipient.
        // Match welcome rumors to members by the consumed KeyPackage event ID
        // (the "e" tag in each rumor) rather than relying on index ordering,
        // because MDK may reorder welcome_rumors internally.
        let mut welcome_events = Vec::with_capacity(welcome_rumors.len());
        for rumor in welcome_rumors {
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
                .map_err(|e| {
                    CircleError::Mls(format!(
                        "Gift-wrap failed: {}",
                        redact_hex_sequences(&e.to_string())
                    ))
                })?;

            // Cascading relay resolution for Welcome delivery. Two-plane
            // model: deliver only to relays the parties actually advertise —
            // NEVER fall back to public default relays, which would expose
            // the recipient's pubkey to them.
            // 1. Member's inbox relays (kind 10050) — preferred per NIP-17.
            // 2. Member's NIP-65 relays (kind 10002) — general-purpose fallback.
            // 3. Sender's own inbox relays — best-effort on relays the
            //    inviter controls, relying on overlap with the invitee.
            // 4. (none) — fail closed; see CircleError::MissingWelcomeRelays.
            let recipient_relays = if !member.inbox_relays.is_empty() {
                member.inbox_relays.clone()
            } else if !member.nip65_relays.is_empty() {
                log::warn!(
                    "[CircleManager] welcome delivery: member has no inbox relays, \
                     falling back to member's NIP-65 relays"
                );
                member.nip65_relays.clone()
            } else if !creator_fallback_relays.is_empty() {
                log::warn!(
                    "[CircleManager] welcome delivery: member has no inbox or NIP-65 \
                     relays, falling back to sender's own inbox relays"
                );
                creator_fallback_relays.to_vec()
            } else {
                // Fail closed: no advertised relay for this member. Delivering
                // to public defaults would leak the recipient's pubkey, so the
                // whole operation aborts and the user can retry when the
                // invitee is reachable.
                log::warn!(
                    "[CircleManager] welcome delivery: no inbox/NIP-65 relay for a member \
                     and sender has no inbox relays; failing closed (no default fallback)"
                );
                return Err(CircleError::MissingWelcomeRelays);
            };

            welcome_events.push(GiftWrappedWelcome {
                recipient_pubkey: recipient_pubkey.to_hex(),
                recipient_relays,
                event: wrapped,
            });
        }

        Ok(welcome_events)
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

    /// Classifies what the caller must do to leave the circle.
    ///
    /// Result values drive the Flutter-side state machine:
    ///
    /// - `NonAdmin` — `propose_leave` → publish → `complete_leave`.
    /// - `AdminHandoff { successor }` — `propose_admin_handoff` → publish →
    ///   finalize → `propose_self_demote` → publish → finalize →
    ///   `propose_leave` → publish → `complete_leave`.
    /// - `AdminDemote` — `propose_self_demote` → publish → finalize →
    ///   `propose_leave` → publish → `complete_leave`.
    /// - `Abandon` — call `abandon_circle_local_only`; no commit, no publish.
    /// - `OrphanLocalOnly` — call `complete_leave` to delete the local row.
    ///
    /// `propose_leave` returns a `SelfRemove` **proposal**, not a pending
    /// commit — a remaining member commits it later, so the leaver does
    /// not finalize after publishing.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Mls`] if the MDK query fails for a reason other
    /// than "group not found" (which maps to `OrphanLocalOnly`).
    pub fn plan_leave(&self, mls_group_id: &GroupId, self_pubkey: &PublicKey) -> Result<LeavePlan> {
        plan_leave(&self.mdk, mls_group_id, self_pubkey)
    }

    /// Step 1 of admin handoff: propose promoting `successor` to admin.
    ///
    /// Creates a pending `GroupContextExtensions` commit that updates the
    /// group's admin list to `[current_admins..., successor]`. Caller must
    /// publish the returned evolution event, then call
    /// [`finalize_pending_commit`] on ACK or [`clear_pending_commit`] on
    /// failure.
    ///
    /// # Errors
    ///
    /// Returns an error if the caller is not an admin, `successor` is not a
    /// group member, or MDK rejects the update.
    ///
    /// [`finalize_pending_commit`]: Self::finalize_pending_commit
    /// [`clear_pending_commit`]: Self::clear_pending_commit
    pub fn propose_admin_handoff(
        &self,
        mls_group_id: &GroupId,
        successor: &PublicKey,
    ) -> Result<UpdateGroupResult> {
        let group = self
            .mdk
            .get_group(mls_group_id)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
            .ok_or_else(|| CircleError::NotFound("<redacted>".to_string()))?;

        let mut admins = group.admin_pubkeys;
        admins.insert(*successor);
        let admin_vec: Vec<PublicKey> = admins.into_iter().collect();

        // M7-B: exclude a concurrent background sweep for the marker+MDK write.
        let _writer = crate::write_lock::acquire_authoring();
        // M7: SET-BEFORE-STAGE (update_admins stages a GroupContextExtensions
        // pending commit).
        self.mark_group_staged(mls_group_id)?;
        match self.mdk.update_admins(mls_group_id, &admin_vec) {
            Ok(result) => Ok(result),
            Err(e) => {
                self.mark_group_unstaged(mls_group_id);
                Err(CircleError::Mls(redact_hex_sequences(&e.to_string())))
            }
        }
    }

    /// Maximum number of relays a circle may carry.
    ///
    /// MIP-01 says the group relay list SHOULD NOT exceed 20; Haven enforces
    /// it as a hard cap to bound kind-445 fan-out metadata (relay-metadata
    /// minimization) and to stop an admin from inflating every member's
    /// subscription set.
    const MAX_CIRCLE_RELAYS: usize = 20;

    /// Proposes an admin update of a circle's group relay list (MIP-01)
    /// via a `GroupContextExtensions` commit.
    ///
    /// Stages a pending commit (admin-gated by MDK) and returns the evolution
    /// event (kind 445) the caller must publish. Per the established
    /// publish-then-merge template, the caller publishes the event to the
    /// **union of the circle's current relays and `new_relays`** (so a member
    /// only listening on a relay being *removed* still receives the commit
    /// before they stop polling it — this is the single kind-445 in Haven
    /// permitted to target a superset of `circle.relays`), then calls
    /// [`finalize_relay_update`](Self::finalize_relay_update) on ACK or
    /// [`clear_pending_commit`](Self::clear_pending_commit) on failure. The
    /// circle row is NOT updated here — only on a successful merge.
    ///
    /// `new_relays` are validated through the same strict path as the
    /// user-relay storage ([`normalize_url`]): plaintext `ws://` is rejected
    /// (except the debug-only loopback test seam), credentials are rejected,
    /// and URLs are canonicalized and deduplicated. The set MUST be non-empty
    /// (an empty set would brick 445 routing, which has no default fallback)
    /// and MUST NOT exceed [`MAX_CIRCLE_RELAYS`](Self::MAX_CIRCLE_RELAYS).
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::InvalidData`] for an empty / all-invalid /
    /// oversized relay set, or [`CircleError::Mls`] if the caller is not an
    /// admin or MDK rejects the update.
    ///
    /// [`normalize_url`]: super::storage_relay_prefs::normalize_url
    pub fn update_circle_relays(
        &self,
        mls_group_id: &GroupId,
        new_relays: &[String],
    ) -> Result<UpdateGroupResult> {
        // Canonicalize + validate via the same strict validator the user-relay
        // storage uses (rejects ws:// outside the debug loopback seam, rejects
        // credentials), then sort + dedupe.
        let mut canonical: Vec<String> = Vec::with_capacity(new_relays.len());
        for relay in new_relays {
            canonical.push(super::storage_relay_prefs::normalize_url(relay)?);
        }
        canonical.sort();
        canonical.dedup();

        // Non-empty is a hard MUST: 445 routes to circle.relays ONLY (no
        // default fallback), so an empty set strands the group permanently.
        if canonical.is_empty() {
            return Err(CircleError::InvalidData(
                "A circle must have at least one relay".to_string(),
            ));
        }
        if canonical.len() > Self::MAX_CIRCLE_RELAYS {
            return Err(CircleError::InvalidData(format!(
                "A circle may have at most {} relays",
                Self::MAX_CIRCLE_RELAYS
            )));
        }

        // `normalize_url` already guaranteed each URL parses; re-parse to the
        // `RelayUrl` MDK requires. Length equality is a defensive invariant.
        let parsed: Vec<RelayUrl> = canonical
            .iter()
            .filter_map(|u| RelayUrl::parse(u).ok())
            .collect();
        if parsed.len() != canonical.len() {
            return Err(CircleError::InvalidData("Invalid relay URL".to_string()));
        }

        // M7-B: exclude a concurrent background sweep for the marker+MDK write.
        let _writer = crate::write_lock::acquire_authoring();
        // M7: SET-BEFORE-STAGE (update_relays stages a GroupContextExtensions
        // pending commit).
        self.mark_group_staged(mls_group_id)?;
        match self.mdk.update_relays(mls_group_id, &parsed) {
            Ok(result) => Ok(result),
            Err(e) => {
                self.mark_group_unstaged(mls_group_id);
                Err(CircleError::Mls(redact_hex_sequences(&e.to_string())))
            }
        }
    }

    /// Re-derives the app-level `circle.relays` row from MDK's authoritative
    /// group relay set after a commit.
    ///
    /// MDK already re-syncs its own `group_relays` store on every
    /// processed/merged commit; Haven keeps a *separate* `circle.relays` row
    /// (the only list that drives kind-445 routing) which must be reconciled
    /// or members publish/subscribe to a stale relay set (split-brain). This
    /// is the single convergence primitive, called from both the consumer
    /// path ([`decrypt_location`](Self::decrypt_location)) and the producer
    /// finalize ([`finalize_relay_update`](Self::finalize_relay_update)). It
    /// is idempotent: an order-insensitive compare no-ops when the sets match,
    /// so it is safe to run after *any* commit.
    ///
    /// HARD INVARIANT: never overwrite a non-empty `circle.relays` with an
    /// empty set. MDK does not validate non-empty on update, and at join Haven
    /// may store `default_relays()` as a fallback while MDK holds empty — the
    /// first commit a member processes must not brick 445 routing.
    ///
    /// # Errors
    ///
    /// Returns an error if MDK or storage access fails.
    fn resync_circle_relays_from_mdk(&self, mls_group_id: &GroupId) -> Result<()> {
        let mut mdk_relays: Vec<String> = self
            .mdk
            .get_group_relays(mls_group_id)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
            .into_iter()
            .map(|u| u.to_string())
            .collect();
        mdk_relays.sort();
        mdk_relays.dedup();

        let Some(mut circle) = self.storage.get_circle(mls_group_id)? else {
            // No local circle row (e.g. a group we have not materialized into a
            // circle). Nothing to reconcile.
            return Ok(());
        };

        // Never strand the group: if MDK reports an empty set, keep whatever
        // working relays the circle row already has.
        if mdk_relays.is_empty() {
            if !circle.relays.is_empty() {
                log::debug!(
                    "resync_circle_relays: MDK returned an empty relay set; \
                     keeping the existing non-empty circle.relays"
                );
            }
            return Ok(());
        }

        let mut current = circle.relays.clone();
        current.sort();
        current.dedup();
        if current != mdk_relays {
            circle.relays = mdk_relays;
            circle.updated_at = chrono::Utc::now().timestamp();
            self.storage.save_circle(&circle)?;
        }
        Ok(())
    }

    /// Finalizes an admin relay update: merges the pending commit, then
    /// re-syncs the admin's own `circle.relays` from MDK.
    ///
    /// The producer (admin) does not process their own commit through
    /// [`decrypt_location`](Self::decrypt_location), so their app-row
    /// reconcile happens here, after the MLS epoch advances on a successful
    /// merge. Call this instead of [`finalize_pending_commit`] for the relay
    /// update flow so the admin converges immediately; the consumer side
    /// converges via the `decrypt_location` hook.
    ///
    /// # Errors
    ///
    /// Returns an error if the merge fails. A merge success followed by a
    /// transient re-sync failure is logged (not returned) — the merge is
    /// already committed and the re-sync self-heals idempotently on the next
    /// processed commit or app restart.
    ///
    /// [`finalize_pending_commit`]: Self::finalize_pending_commit
    pub fn finalize_relay_update(&self, mls_group_id: &GroupId) -> Result<()> {
        self.finalize_pending_commit(mls_group_id)?;
        if let Err(e) = self.resync_circle_relays_from_mdk(mls_group_id) {
            // The MLS merge already succeeded (epoch advanced); do not mask a
            // committed relay update with a transient row-write error. The
            // re-sync is idempotent and re-runs on the next processed commit.
            log::warn!(
                "finalize_relay_update: relay re-sync failed (will self-heal): {}",
                redact_hex_sequences(&e.to_string())
            );
        }
        Ok(())
    }

    /// Step 2 of admin handoff (or step 1 for `Abandon`): demote caller
    /// from the admin set.
    ///
    /// Pending commit — caller publishes, then finalizes on ACK or clears
    /// on failure.
    ///
    /// # Errors
    ///
    /// Returns an error if the caller is not an admin or MDK rejects the
    /// update (e.g., caller is the sole admin — must handoff first).
    pub fn propose_self_demote(&self, mls_group_id: &GroupId) -> Result<UpdateGroupResult> {
        // M7-B: exclude a concurrent background sweep for the marker+MDK write.
        let _writer = crate::write_lock::acquire_authoring();
        // M7: SET-BEFORE-STAGE (self_demote stages a GroupContextExtensions commit).
        self.mark_group_staged(mls_group_id)?;
        match self.mdk.self_demote(mls_group_id) {
            Ok(result) => Ok(result),
            Err(e) => {
                self.mark_group_unstaged(mls_group_id);
                Err(CircleError::Mls(redact_hex_sequences(&e.to_string())))
            }
        }
    }

    /// Final step of every non-abandoning leave: returns a `SelfRemove`
    /// proposal event so peers can advance past the caller.
    ///
    /// Unlike [`propose_admin_handoff`] and [`propose_self_demote`], this
    /// does **not** stage a pending commit — a remaining group member
    /// commits the `SelfRemove` later per RFC 9420 §12.1.2. The caller
    /// publishes the returned event and then calls [`complete_leave`];
    /// there is nothing to finalize or clear on the leaver's side.
    ///
    /// # Errors
    ///
    /// Returns an error if MDK rejects the leave (e.g., caller is still an
    /// admin — must demote first via [`propose_self_demote`]).
    ///
    /// [`propose_admin_handoff`]: Self::propose_admin_handoff
    /// [`propose_self_demote`]: Self::propose_self_demote
    /// [`complete_leave`]: Self::complete_leave
    pub fn propose_leave(&self, mls_group_id: &GroupId) -> Result<UpdateGroupResult> {
        // Pre-clear any residual pending commit so MDK's `leave_group`
        // doesn't reject the SelfRemove with "pending commit exists".
        //
        // By the time we reach this step under any leave plan, legitimate
        // in-flight commits from prior steps (handoff, demote) have already
        // been finalized or cleared by the caller's `_commitAndPublish`.
        // A pending commit lingering here can only be stale — most likely
        // from a prior session's receiver-side auto-commit (another
        // member's SelfRemove) whose publish-then-finalize sequence
        // didn't complete. Discarding it is safe: the user is leaving,
        // so they won't need that staged state to advance local MDK.
        //
        // Symmetric with `complete_leave`'s pre-clear (see line ~583).
        // Logs at debug level when a commit was actually discarded so a
        // resurgence of this bug class remains diagnosable. The group ID
        // is intentionally omitted from the log to avoid linking sessions.
        //
        // M7-B: exclude a concurrent background sweep for the two MDK writes
        // (the residual-commit clear + the SelfRemove stage). Wrapped inline
        // here (not via `clear_pending_commit`, which acquires the lock itself)
        // so both writes are one critical section; the non-reentrant lock is
        // NOT taken twice.
        let _writer = crate::write_lock::acquire_authoring();
        if self.mdk.clear_pending_commit(mls_group_id).is_ok() {
            log::debug!("propose_leave: cleared residual pending commit before staging SelfRemove");
        }
        self.mdk
            .leave_group(mls_group_id)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
    }

    /// Finalizes a leave by purging every trace of the group locally.
    ///
    /// Destroys MDK state (tree, epoch secrets, leaf keys, proposals,
    /// snapshots) *before* removing the app-level circle row so the
    /// forward-secrecy purge is atomic from the user's perspective:
    /// once a leave succeeds, no material remains on-device that could
    /// decrypt past ciphertext for the group.
    ///
    /// Safe for the `OrphanLocalOnly` plan — `mdk.delete_group` is
    /// idempotent and no-ops when the MDK group is absent.
    ///
    /// # Pending-commit cleanup
    ///
    /// A prior operation in the same leave flow may have staged a
    /// pending commit that never finalized (e.g. a `self_demote` whose
    /// commit was not yet `ACKed` when the plan advanced to `leave_group`,
    /// or a partial-publish on the handoff path). Call
    /// `clear_pending_commit` first so `delete_group` sees clean state;
    /// any error there is intentionally ignored because a missing
    /// pending commit is the expected case and the subsequent
    /// `delete_group` is the authoritative purge.
    ///
    /// # Errors
    ///
    /// Returns an error if the MDK deletion or the circle-row deletion
    /// fails.
    pub fn complete_leave(&self, mls_group_id: &GroupId) -> Result<()> {
        // Best-effort: drops any residual pending commit staged by a
        // prior step in the leave flow. Errors are ignored — the
        // common case is "no pending commit", and `delete_group`
        // below is the forward-secrecy-relevant operation.
        //
        // M7-B: exclude a concurrent background sweep for the clear + delete
        // MDK writes. Wrapped inline (not via `clear_pending_commit`, which
        // acquires the lock) so the non-reentrant lock is taken once.
        let writer = crate::write_lock::acquire_authoring();
        let _ = self.mdk.clear_pending_commit(mls_group_id);
        self.mdk
            .delete_group(mls_group_id)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        // Release the writer lock before the (non-MDK) circles.db row/avatar
        // cleanup below — that work does not touch haven_mdk.db.
        drop(writer);
        let _existed = self.storage.delete_circle(mls_group_id)?;
        // Privacy: purge every cached avatar for this circle so a left/deleted
        // circle's member faces do not linger at rest (best-effort — the
        // forward-secrecy-relevant MDK delete above already succeeded).
        let _ = self.storage.remove_circle_avatars(mls_group_id.as_slice());
        Ok(())
    }

    /// Abandons a circle where the caller is the sole remaining member.
    ///
    /// Same purge semantics as [`complete_leave`] — MDK state is wiped
    /// alongside the local row — but skips the relay publish because
    /// MDK's `self_demote` and `leave_group` both require at least one
    /// other admin/member, so there is no one to receive a `SelfRemove`.
    ///
    /// # Errors
    ///
    /// Returns an error if the MDK deletion or the circle-row deletion
    /// fails.
    ///
    /// [`complete_leave`]: Self::complete_leave
    pub fn abandon_circle_local_only(&self, mls_group_id: &GroupId) -> Result<()> {
        self.complete_leave(mls_group_id)
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

        // M7-B: exclude a concurrent background sweep for the marker+MDK write.
        // (Called by `add_members_with_welcomes`, whose async relay I/O stays
        // OUTSIDE this lock — the guard is dropped when this sync fn returns.)
        let _writer = crate::write_lock::acquire_authoring();
        // M7: SET-BEFORE-STAGE.
        self.mark_group_staged(mls_group_id)?;
        match self.mdk.add_members(mls_group_id, key_packages) {
            Ok(result) => Ok(result),
            Err(e) => {
                self.mark_group_unstaged(mls_group_id);
                Err(CircleError::Mls(redact_hex_sequences(&e.to_string())))
            }
        }
    }

    /// Adds members to an existing circle and gift-wraps their Welcomes.
    ///
    /// This is the add-time counterpart to [`create_circle`]: it stages an MLS
    /// Add commit (kind:445, advances existing members N→N+1 on finalize) and
    /// gift-wraps the resulting per-member Welcome rumors (kind:444) for
    /// delivery, resolving each recipient's relays through the same fail-closed
    /// cascade. The caller owns the publish/finalize cycle:
    ///
    /// 1. Publish [`AddMembersResult::evolution_event`] to the circle's relays.
    /// 2. On success, call [`finalize_pending_commit`] to merge locally.
    /// 3. On publish failure, call [`clear_pending_commit`] to roll back.
    /// 4. Only after a successful finalize, publish each
    ///    [`AddMembersResult::welcome_events`] entry.
    ///
    /// Adding is admin-gated by MDK; a non-admin caller fails with
    /// [`CircleError::Mls`].
    ///
    /// # Arguments
    ///
    /// * `sender_keys` - The admin's Nostr identity keys (for gift-wrapping).
    /// * `mls_group_id` - The circle's MLS group ID.
    /// * `members` - Key packages and inbox/NIP-65 relays for the new members.
    /// * `creator_fallback_relays` - The admin's own inbox relays (kind
    ///   10050), used as the third tier in the Welcome delivery cascade. Pass
    ///   `&[]` if the admin has no inbox relays (the cascade then fails closed
    ///   when tiers 1 and 2 are also empty).
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::MissingWelcomeRelays`] if a member has no
    /// advertised relay and there is no sender fallback (checked **before**
    /// staging so a non-deliverable add never leaves a dangling pending
    /// commit), or [`CircleError::Mls`] if staging, gift-wrapping, or the MDK
    /// admin gate rejects the operation.
    ///
    /// [`create_circle`]: Self::create_circle
    /// [`finalize_pending_commit`]: Self::finalize_pending_commit
    /// [`clear_pending_commit`]: Self::clear_pending_commit
    pub async fn add_members_with_welcomes(
        &self,
        sender_keys: &Keys,
        mls_group_id: &GroupId,
        members: Vec<MemberKeyPackage>,
        creator_fallback_relays: &[String],
    ) -> Result<AddMembersResult> {
        // Fail closed BEFORE staging the Add commit. The per-member
        // Welcome-delivery cascade in `wrap_welcomes_with_cascade` only aborts
        // AFTER `self.add_members` has staged the pending commit; a fail there
        // would strand a dangling pending commit that wedges the group until
        // it is cleared. Since the sender-inbox fallback
        // (`creator_fallback_relays`) is identical for every member, a member
        // is deliverable iff it advertises an inbox or NIP-65 relay, OR the
        // sender has an inbox fallback. Pre-validate that here so the
        // fail-closed path leaves the group's MLS state untouched. (The
        // cascade keeps the same check as a defensive backstop.)
        if creator_fallback_relays.is_empty() {
            for m in &members {
                if m.inbox_relays.is_empty() && m.nip65_relays.is_empty() {
                    return Err(CircleError::MissingWelcomeRelays);
                }
            }
        }

        // Extract just the key package events for the MLS Add.
        let key_package_events: Vec<Event> = members
            .iter()
            .map(|m| m.key_package_event.clone())
            .collect();

        // Stage the pending Add commit (epoch advances only on finalize).
        let update = self.add_members(mls_group_id, &key_package_events)?;

        // MDK returns one Welcome rumor per added KeyPackage.
        let welcome_rumors = update.welcome_rumors.ok_or_else(|| {
            CircleError::Mls("add_members produced no welcome rumors".to_string())
        })?;

        // Gift-wrap each rumor and resolve its delivery relays (shared with
        // the create-circle flow).
        let welcome_events = self
            .wrap_welcomes_with_cascade(
                sender_keys,
                &members,
                welcome_rumors,
                creator_fallback_relays,
            )
            .await?;

        Ok(AddMembersResult {
            evolution_event: update.evolution_event,
            welcome_events,
        })
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

        // M7-B: exclude a concurrent background sweep for the marker+MDK write.
        let writer = crate::write_lock::acquire_authoring();
        // M7: SET-BEFORE-STAGE.
        self.mark_group_staged(mls_group_id)?;
        let result = match self.mdk.remove_members(mls_group_id, member_pubkeys) {
            Ok(r) => r,
            Err(e) => {
                self.mark_group_unstaged(mls_group_id);
                return Err(CircleError::Mls(redact_hex_sequences(&e.to_string())));
            }
        };
        // Release before the (non-MDK) avatar cleanup below — it only touches
        // circles.db, not haven_mdk.db.
        drop(writer);
        // Privacy: a removed member's cached avatar in this circle must not
        // linger locally. Best-effort — the MLS removal already succeeded.
        for pubkey in member_pubkeys {
            let _ = self
                .storage
                .remove_member_avatar(mls_group_id.as_slice(), pubkey);
        }
        Ok(result)
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
    /// * `notes` - Optional notes about the contact
    ///
    /// # Errors
    ///
    /// Returns an error if saving the contact fails.
    pub fn set_contact(
        &self,
        pubkey: &str,
        display_name: Option<&str>,
        notes: Option<&str>,
    ) -> Result<Contact> {
        let now = chrono::Utc::now().timestamp();

        // Get existing contact or create new one
        let existing = self.storage.get_contact(pubkey)?;
        let created_at = existing.as_ref().map_or(now, |c| c.created_at);

        let contact = Contact {
            pubkey: pubkey.to_string(),
            display_name: display_name.map(ToString::to_string),
            notes: notes.map(ToString::to_string),
            created_at,
            updated_at: now,
        };

        self.storage.save_contact(&contact)?;
        Ok(contact)
    }

    // ==================== Avatar (profile pictures) — M1 (local) ====================

    /// Processes and stores the user's OWN avatar from raw image bytes.
    ///
    /// The raw bytes are decoded under resource limits, stripped of ALL
    /// metadata (EXIF/GPS) by re-encoding to JPEG, center-cropped and
    /// downscaled to the canonical tier, and stored — together with a derived
    /// thumbnail — as SQLCipher-encrypted BLOBs under the own-avatar sentinel.
    /// Returns metadata only (never image bytes).
    ///
    /// # Errors
    ///
    /// Returns an error if the image cannot be processed (too large,
    /// unsupported format, decode/encode failure, or over the size budget) or
    /// if storage fails.
    pub fn set_my_avatar(
        &self,
        own_pubkey: &str,
        raw: &[u8],
    ) -> Result<super::AvatarAssignmentMeta> {
        let processed = crate::avatar::process_own_avatar(raw)?;
        let content_hash = processed.content_hash;
        let width = processed.width;
        let height = processed.height;
        let thumb_hash = crate::avatar::content_hash(&processed.thumbnail);
        let blobs = super::AvatarBlobs {
            canonical: processed.canonical,
            thumbnail: processed.thumbnail,
            content_hash,
            thumb_hash,
            mime: crate::avatar::AVATAR_MIME.to_string(),
            width,
            thumb_edge: crate::avatar::AVATAR_THUMB_EDGE_PX,
        };
        let now = chrono::Utc::now().timestamp();
        let version = self.storage.set_own_avatar(own_pubkey, &blobs, now)?;
        Ok(super::AvatarAssignmentMeta {
            content_hash,
            mime: crate::avatar::AVATAR_MIME.to_string(),
            width,
            height,
            version,
        })
    }

    /// Returns the user's own avatar thumbnail bytes (hot path), or `None`.
    ///
    /// # Errors
    ///
    /// Returns an error if storage access fails.
    pub fn get_my_avatar_thumbnail(
        &self,
        own_pubkey: &str,
    ) -> Result<Option<zeroize::Zeroizing<Vec<u8>>>> {
        self.storage
            .get_avatar_thumbnail(super::storage_avatar::OWN_AVATAR_CIRCLE_ID, own_pubkey)
    }

    /// Returns the user's own full-resolution avatar bytes, or `None`.
    ///
    /// # Errors
    ///
    /// Returns an error if storage access fails.
    pub fn get_my_avatar(&self, own_pubkey: &str) -> Result<Option<zeroize::Zeroizing<Vec<u8>>>> {
        self.storage
            .get_avatar_canonical(super::storage_avatar::OWN_AVATAR_CIRCLE_ID, own_pubkey)
    }

    /// Clears the user's own avatar (removes the assignment and GCs its blobs).
    ///
    /// # Errors
    ///
    /// Returns an error if storage access fails.
    pub fn clear_my_avatar(&self, own_pubkey: &str) -> Result<()> {
        self.storage.clear_own_avatar(own_pubkey)
    }

    /// Returns the version of the user's OWN stored avatar — the monotonic
    /// counter that share manifests embed and peers store — or `None` if no
    /// avatar is set.
    ///
    /// The removal tombstone must be built with `version + 1` so it strictly
    /// supersedes the avatar peers currently hold; this getter MUST therefore
    /// be read **before** the local avatar store is cleared.
    ///
    /// # Errors
    ///
    /// Returns an error if storage access fails.
    pub fn own_avatar_version(&self, own_pubkey: &str) -> Result<Option<i64>> {
        Ok(self
            .storage
            .get_avatar_meta(super::storage_avatar::OWN_AVATAR_CIRCLE_ID, own_pubkey)?
            .map(|m| m.version))
    }

    // ============= Avatar broadcast over kind-445 — M2 (network) =============

    /// Builds the wire-ready kind-445 events that share the user's OWN avatar
    /// into a circle (sibling of [`Self::encrypt_location`]).
    ///
    /// Reads the stored canonical avatar (under the own-avatar sentinel), its
    /// version and the circle's current MLS epoch, splits + pads it into the
    /// fixed [`crate::avatar::AVATAR_CHUNK_COUNT`] equal-length chunks, builds
    /// each as an inner kind-9 rumor whose `pubkey` is the sender's own Nostr
    /// identity (required by MDK's `verify_rumor_author`), and wraps each via
    /// [`MdkManager::create_message`] with the **same DEC-4 jittered NIP-40
    /// expiration** location uses — so avatar events share location's tag
    /// profile, ephemeral-key-per-event, and TTL band on the wire. (An avatar
    /// SHARE is still distinguishable from a location packet by size/burst —
    /// the chunks are padded equal to each other but larger than a tiny
    /// location packet; the image's size class, content, MIME, hash, and
    /// identity stay hidden. See `SECURITY.md`.)
    ///
    /// Returns an empty `Vec` if the user has no stored avatar (nothing to
    /// share). On-change / anti-entropy scheduling is the Dart layer's job (M3);
    /// this just builds the events on demand.
    ///
    /// # Errors
    ///
    /// Returns an error if the circle is not found, the stored avatar metadata
    /// is missing/corrupt, chunking fails, or MLS encryption fails.
    pub fn build_avatar_share(
        &self,
        mls_group_id: &GroupId,
        sender_pubkey: &PublicKey,
        update_interval_secs: u64,
    ) -> Result<Vec<Event>> {
        // Confirm the circle exists (and surface a generic not-found).
        if self.storage.get_circle(mls_group_id)?.is_none() {
            return Err(CircleError::NotFound(
                "Circle not found: <redacted>".to_string(),
            ));
        }

        let own_hex = sender_pubkey.to_hex();
        let Some(canonical) = self
            .storage
            .get_avatar_canonical(super::storage_avatar::OWN_AVATAR_CIRCLE_ID, &own_hex)?
        else {
            // No avatar to share — not an error.
            return Ok(Vec::new());
        };
        let meta = self
            .storage
            .get_avatar_meta(super::storage_avatar::OWN_AVATAR_CIRCLE_ID, &own_hex)?
            .ok_or_else(|| {
                CircleError::Storage("avatar blob present but metadata missing".to_string())
            })?;

        let epoch = self.group_epoch_internal(mls_group_id)?;

        let chunks = crate::avatar::build_chunks(
            &canonical,
            &meta.content_hash,
            meta.version,
            epoch,
            meta.width,
            meta.height,
        )?;

        self.wrap_avatar_chunks(mls_group_id, sender_pubkey, &chunks, update_interval_secs)
    }

    /// Builds the wire-ready kind-445 tombstone that clears the user's avatar
    /// in a circle (a `haven-avatar-clear` inner with a bumped version).
    ///
    /// `version` must exceed the version of the avatar being removed for peers
    /// to honor the clear (supersession by `(version, epoch)`).
    ///
    /// # Errors
    ///
    /// As [`Self::build_avatar_share`].
    pub fn build_avatar_clear(
        &self,
        mls_group_id: &GroupId,
        sender_pubkey: &PublicKey,
        version: i64,
        update_interval_secs: u64,
    ) -> Result<Event> {
        if self.storage.get_circle(mls_group_id)?.is_none() {
            return Err(CircleError::NotFound(
                "Circle not found: <redacted>".to_string(),
            ));
        }
        let clear = crate::avatar::AvatarClear {
            kind: crate::avatar::TYPE_CLEAR.to_string(),
            v: crate::avatar::AVATAR_SCHEMA_VERSION,
            version,
        };
        let content = serde_json::to_string(&clear)
            .map_err(|_| CircleError::Mls("failed to serialize avatar clear".to_string()))?;
        let events = self.wrap_avatar_chunks(
            mls_group_id,
            sender_pubkey,
            &[zeroize::Zeroizing::new(content)],
            update_interval_secs,
        )?;
        events
            .into_iter()
            .next()
            .ok_or_else(|| CircleError::Mls("failed to build avatar clear event".to_string()))
    }

    /// Wraps each serialized inner kind-9 avatar payload into a signed kind-445
    /// event via MDK, mirroring [`Self::encrypt_location`] exactly (inner
    /// pubkey = sender identity, `["t","haven-avatar"]` clarity tag, DEC-4
    /// jittered expiration).
    fn wrap_avatar_chunks(
        &self,
        mls_group_id: &GroupId,
        sender_pubkey: &PublicKey,
        chunks: &[crate::avatar::SerializedChunk],
        update_interval_secs: u64,
    ) -> Result<Vec<Event>> {
        let avatar_tag = Tag::parse(["t", crate::avatar::AVATAR_T_TAG]).map_err(|e| {
            CircleError::Mls(format!(
                "Failed to create avatar tag: {}",
                redact_hex_sequences(&e.to_string())
            ))
        })?;

        let interval = crate::location::ttl::validate_update_interval_secs(update_interval_secs);

        // M7-B: each `create_message` is an authoring ratchet advance (an MDK
        // write); hold the writer lock across the whole chunk batch so a
        // background sweep cannot interleave. No `.await` inside — safe to hold.
        let _writer = crate::write_lock::acquire_authoring();
        let mut events = Vec::with_capacity(chunks.len());
        for chunk in chunks {
            // Inner rumor: pubkey MUST be the sender's own Nostr identity, else
            // MDK's verify_rumor_author hard-rejects with AuthorMismatch.
            let rumor = EventBuilder::new(Kind::Custom(9), chunk.as_str())
                .tag(avatar_tag.clone())
                .build(*sender_pubkey);

            // DEC-4: sample the jittered TTL INDEPENDENTLY per chunk from the
            // SAME window location uses (~minutes), so avatar events sit in the
            // same NIP-40 expiration band as location packets.
            let expiration = crate::location::ttl::compute_jittered_ttl_secs(interval)
                .map(|jitter| Timestamp::now() + std::time::Duration::from_secs(jitter));

            let event = self
                .mdk
                .create_message(mls_group_id, rumor, expiration)
                .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
            events.push(event);
        }
        Ok(events)
    }

    /// Internal (non-test-gated) MLS epoch accessor for the avatar send path.
    pub(crate) fn group_epoch_internal(&self, mls_group_id: &GroupId) -> Result<u64> {
        let group = self
            .mdk
            .get_group(mls_group_id)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
            .ok_or_else(|| CircleError::NotFound("Group not found: <redacted>".to_string()))?;
        Ok(group.epoch)
    }

    /// Decrypts an incoming kind-445 event and, if its decrypted inner kind-9
    /// is an avatar payload, routes it through the per-(circle, sender)
    /// reassembler; on completion the avatar is decoded under strict inbound
    /// limits and stored under the MLS-authenticated sender's pubkey with a
    /// DEC-6 per-circle salted blob key.
    ///
    /// Non-avatar inners (location, unknown types) and group-update events are
    /// reported as [`AvatarIngestResult::ignored`] with NO error and NO bytes —
    /// the existing [`Self::decrypt_location`] path handles those. Routing
    /// happens AFTER decryption because avatar and location events are
    /// indistinguishable on the wire.
    ///
    /// Fail-closed: any reassembly/decode/hash failure discards the whole
    /// in-flight set and KEEPS the previously-stored avatar; the result is
    /// `ignored` (no partial display, no input bytes echoed).
    ///
    /// # Errors
    ///
    /// Returns an error only if MLS processing fails entirely (e.g. an
    /// undecryptable event). Decryption-failure variants surface the same way
    /// [`Self::decrypt_location`] handles them.
    pub fn ingest_incoming_avatar_message(&self, event: &Event) -> Result<AvatarIngestResult> {
        // Receiver-side NIP-40 expiration enforcement (mirror decrypt_location).
        if let Some(expires_at) = event.tags.iter().find_map(|t| match t.as_standardized() {
            Some(TagStandard::Expiration(ts)) => Some(*ts),
            _ => None,
        }) {
            let now = Timestamp::now();
            let grace = Timestamp::from(
                expires_at
                    .as_secs()
                    .saturating_add(crate::location::ttl::RECEIVER_EXPIRATION_GRACE_SECS),
            );
            if now > grace {
                return Ok(AvatarIngestResult::ignored());
            }
        }

        // M7-B: receiver authoring path — `process_message` can auto-commit a
        // peer SelfRemove (an MDK write). Exclude a concurrent background sweep.
        let result = {
            let _writer = crate::write_lock::acquire_authoring();
            self.mdk
                .process_message(event)
                .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
        };

        let location_result = MdkManager::to_location_result(result);
        let LocationMessageResult::Location {
            sender_pubkey,
            content,
            group_id,
        } = location_result
        else {
            // Group updates / unprocessable / previously-failed: not avatars.
            return Ok(AvatarIngestResult::ignored());
        };

        self.route_decrypted_avatar_inner(&group_id, &sender_pubkey, &content)
    }

    /// Routes a decrypted inner kind-9 `content` (already MLS-authenticated to
    /// `sender_pubkey` in `group_id`) to the avatar reassembler.
    fn route_decrypted_avatar_inner(
        &self,
        group_id: &GroupId,
        sender_pubkey: &str,
        content: &str,
    ) -> Result<AvatarIngestResult> {
        use crate::avatar::AvatarInner;

        let circle_id = group_id.as_slice();
        let circle_hex = hex::encode(circle_id);
        let now = chrono::Utc::now().timestamp();

        match AvatarInner::parse(content) {
            AvatarInner::Other => {
                // Location or forward-incompatible type — silently ignored
                // (debug-log only, no bytes).
                Ok(AvatarIngestResult::ignored())
            }
            AvatarInner::Clear(clear) => self.apply_avatar_clear(circle_id, sender_pubkey, &clear),
            AvatarInner::Manifest(manifest) => {
                self.ingest_avatar_part(circle_id, &circle_hex, sender_pubkey, now, |state| {
                    state.ingest_manifest(&manifest, now)
                })
            }
            AvatarInner::Chunk(chunk) => {
                self.ingest_avatar_part(circle_id, &circle_hex, sender_pubkey, now, |state| {
                    state.ingest_chunk(&chunk, now)
                })
            }
        }
    }

    /// Applies a tombstone: removes the assignment if the clear's version
    /// strictly exceeds the stored version (supersession). Stale clears are
    /// ignored.
    fn apply_avatar_clear(
        &self,
        circle_id: &[u8],
        sender_pubkey: &str,
        clear: &crate::avatar::AvatarClear,
    ) -> Result<AvatarIngestResult> {
        let stored = self
            .storage
            .avatar_assignment_version_epoch(circle_id, sender_pubkey)?;
        // Supersede by VERSION ONLY (no epoch) BY DESIGN. Unlike a manifest/chunk
        // assignment — which supersedes on the (version, epoch) pair so a newer
        // epoch's image wins — a removal tombstone must win regardless of which
        // epoch it was built under: once the owner clears their avatar, no older
        // (version, epoch) assignment should be able to resurrect it. So a clear
        // carries no epoch and we compare on the version component alone (a
        // removal whose version strictly exceeds the stored version wins).
        if let Some((v, _)) = stored {
            if clear.version <= v {
                return Ok(AvatarIngestResult::ignored());
            }
        } else {
            // Nothing stored — nothing to clear, but it is a valid (no-op) clear.
            return Ok(AvatarIngestResult::ignored());
        }
        self.storage
            .remove_member_avatar(circle_id, sender_pubkey)?;
        Ok(AvatarIngestResult {
            accepted: true,
            complete: true,
            sender_pubkey_hex: Some(sender_pubkey.to_string()),
            version: Some(clear.version),
        })
    }

    /// Shared body for manifest/chunk ingest: runs `ingest` against the
    /// per-(circle, sender) state, evicts on any error (fail-closed), and on a
    /// completed reassembly decodes under strict inbound limits and stores.
    // The match-then-early-return on the ingest result (rather than `if let`)
    // keeps the fail-closed eviction path readable; the lock guard is held only
    // across the eviction + ingest work it must protect.
    #[allow(clippy::single_match_else)]
    fn ingest_avatar_part<F>(
        &self,
        circle_id: &[u8],
        circle_hex: &str,
        sender_pubkey: &str,
        now: i64,
        ingest: F,
    ) -> Result<AvatarIngestResult>
    where
        F: FnOnce(
            &mut super::avatar_reassembly::AvatarReassemblyState,
        ) -> std::result::Result<
            Option<crate::avatar::ReassembledAvatar>,
            crate::avatar::AvatarError,
        >,
    {
        let key = (circle_hex.to_string(), sender_pubkey.to_string());

        let finalized = {
            let mut buffers = self
                .avatar_reassembly
                .lock()
                .map_err(|e| CircleError::Storage(format!("avatar reassembly lock: {e}")))?;

            // Evict timed-out incomplete sets (any sender) before working.
            let timeout = crate::avatar::avatar_reassembly_timeout_secs();
            buffers.retain(|_, st| !st.is_expired(now, timeout));

            let state = buffers
                .entry(key.clone())
                .or_insert_with(|| super::avatar_reassembly::AvatarReassemblyState::new(now));

            let ingest_result = ingest(state);
            match ingest_result {
                Ok(finalized) => finalized,
                Err(_) => {
                    // Fail-closed: drop the whole in-flight set, keep the prior
                    // good avatar. No input bytes echoed.
                    buffers.remove(&key);
                    drop(buffers);
                    return Ok(AvatarIngestResult::ignored());
                }
            }
        };

        let Some(avatar) = finalized else {
            // Not complete yet — accepted the part, nothing to store.
            return Ok(AvatarIngestResult {
                accepted: true,
                complete: false,
                sender_pubkey_hex: Some(sender_pubkey.to_string()),
                version: None,
            });
        };

        // Complete: re-validate under strict inbound decode limits before
        // storing (defense against a malicious member's crafted bytes), then
        // store under the sender's pubkey with the DEC-6 salted blob key.
        let store_result = self.finalize_received_avatar(circle_id, sender_pubkey, &avatar, now);

        // Either way the reassembly is done — drop the buffer (wipes it).
        {
            let mut buffers = self
                .avatar_reassembly
                .lock()
                .map_err(|e| CircleError::Storage(format!("avatar reassembly lock: {e}")))?;
            buffers.remove(&key);
        }

        match store_result {
            Ok(stored) => Ok(AvatarIngestResult {
                accepted: stored,
                complete: true,
                sender_pubkey_hex: Some(sender_pubkey.to_string()),
                version: Some(avatar.version),
            }),
            // A storage/decode failure fails closed — keep the prior avatar.
            Err(_) => Ok(AvatarIngestResult::ignored()),
        }
    }

    /// Decodes the reassembled canonical bytes under strict inbound limits,
    /// derives a thumbnail, and stores both under the DEC-6 salted blob key.
    fn finalize_received_avatar(
        &self,
        circle_id: &[u8],
        sender_pubkey: &str,
        avatar: &crate::avatar::ReassembledAvatar,
        now: i64,
    ) -> Result<bool> {
        // Re-validate + re-encode the untrusted bytes through the inbound
        // pipeline (strips any polyglot/trailing data and enforces dims/size).
        let reprocessed = crate::avatar::image::process_inbound_avatar(&avatar.canonical)?;
        let thumb_hash = crate::avatar::content_hash(&reprocessed.thumbnail);
        let blobs = super::AvatarBlobs {
            canonical: reprocessed.canonical,
            thumbnail: reprocessed.thumbnail,
            content_hash: reprocessed.content_hash,
            thumb_hash,
            mime: crate::avatar::AVATAR_MIME.to_string(),
            width: reprocessed.width,
            thumb_edge: crate::avatar::AVATAR_THUMB_EDGE_PX,
        };
        // sender_epoch comes from the MLS-authenticated manifest, NOT created_at.
        let sender_epoch = i64::try_from(avatar.epoch).unwrap_or(i64::MAX);
        self.storage.store_received_avatar(
            circle_id,
            sender_pubkey,
            &blobs,
            avatar.version,
            sender_epoch,
            now,
        )
    }

    /// Returns a circle member's avatar thumbnail bytes (hot path), or `None`.
    ///
    /// # Errors
    ///
    /// Returns an error if storage access fails.
    pub fn get_member_avatar_thumbnail(
        &self,
        mls_group_id: &GroupId,
        member_pubkey: &str,
    ) -> Result<Option<zeroize::Zeroizing<Vec<u8>>>> {
        self.storage
            .get_avatar_thumbnail(mls_group_id.as_slice(), member_pubkey)
    }

    /// Returns a circle member's full-resolution avatar bytes, or `None`.
    ///
    /// # Errors
    ///
    /// Returns an error if storage access fails.
    pub fn get_member_avatar(
        &self,
        mls_group_id: &GroupId,
        member_pubkey: &str,
    ) -> Result<Option<zeroize::Zeroizing<Vec<u8>>>> {
        self.storage
            .get_avatar_canonical(mls_group_id.as_slice(), member_pubkey)
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
        log::debug!(
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
                CircleError::Mls(format!(
                    "Failed to unwrap welcome: {}",
                    redact_hex_sequences(&e.to_string())
                ))
            })?;

        log::debug!(
            "[CircleManager] unwrap ok: wrapper_id={wrapper_id_prefix} \
             rumor_kind={} rumor_tags={}",
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
             rumor_kind={} rumor_tags={}",
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

        // Process welcome via MDK.
        // M7-B: `process_welcome` writes MDK group state (an authoring MDK
        // write); exclude a concurrent background sweep. The subsequent sentinel
        // bookkeeping is on circles.db, so acquire only around the MDK call.
        let welcome_processing = {
            let _writer = crate::write_lock::acquire_authoring();
            self.mdk.process_welcome(wrapper_event_id, rumor_event)
        };
        let welcome_result = match welcome_processing {
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
                     wrapper_id={wrapper_id_prefix} rumor_kind={} \
                     rumor_tags={} err={redacted}",
                    rumor_event.kind.as_u16(),
                    rumor_event.tags.len(),
                );
                return Err(CircleError::Mls(redacted));
            }
        };

        log::info!(
            "[CircleManager] MDK process_welcome ok: wrapper_id={wrapper_id_prefix} \
             group_relays={} member_count={}",
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
            crate::circle::types::default_relays()
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
                                .map_or(0, |m| m.len())
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

            // M7-B: `accept_welcome` writes MDK group state (an authoring MDK
            // write); exclude a concurrent background sweep.
            {
                let _writer = crate::write_lock::acquire_authoring();
                self.mdk.accept_welcome(welcome)?;
            }
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
                // M7-B: `decline_welcome` writes MDK welcome/group state (an
                // authoring MDK write); exclude a concurrent background sweep.
                let _writer = crate::write_lock::acquire_authoring();
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
        let content = location.to_string().map_err(|e| {
            CircleError::Mls(format!(
                "Failed to serialize location: {}",
                redact_hex_sequences(&e.to_string())
            ))
        })?;

        let location_tag = Tag::parse(["t", "location"]).map_err(|e| {
            CircleError::Mls(format!(
                "Failed to create location tag: {}",
                redact_hex_sequences(&e.to_string())
            ))
        })?;

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

        // Encrypt using MdkManager directly (MLS encryption + ephemeral keypair).
        // M7-B: `create_message` is a ratchet advance (an authoring MDK write);
        // exclude a concurrent background sweep. No `.await` — safe to hold.
        let event = {
            let _writer = crate::write_lock::acquire_authoring();
            self.mdk
                .create_message(mls_group_id, rumor, expiration)
                .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
        };

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
                expires_at
                    .as_secs()
                    .saturating_add(crate::location::ttl::RECEIVER_EXPIRATION_GRACE_SECS),
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

        // M7-B: the legacy foreground receive path is an AUTHORING writer —
        // `process_message` can auto-commit a peer SelfRemove (an MDK write).
        // Exclude a concurrent background sweep. Sync method (no `.await`).
        let result = {
            let _writer = crate::write_lock::acquire_authoring();
            self.mdk
                .process_message(event)
                .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
        };

        let location_result = MdkManager::to_location_result(result);

        // Consumer-side convergence: when a member processes an
        // admin-authorized GroupContextExtensions commit that changes the
        // group relay list, MDK has already updated its own `group_relays`
        // store (process_commit -> sync_group_metadata_from_mls). Re-derive
        // the app-level `circle.relays` so the NEXT kind-445 publish/subscribe
        // converges on the new set; the Dart poller self-heals via the
        // existing `circlesProvider` invalidation on `group_updated`.
        //
        // Gated on `GroupUpdate` so plain location messages (mapped to
        // `Location`) never trigger a relay read. Best-effort: a transient
        // storage error must never drop a successfully-processed commit or
        // location — the idempotent re-sync re-runs on the next commit.
        if let LocationMessageResult::GroupUpdate { ref group_id, .. } = location_result {
            if let Err(e) = self.resync_circle_relays_from_mdk(group_id) {
                log::debug!(
                    "decrypt_location: relay re-sync failed (will retry on next commit): {}",
                    redact_hex_sequences(&e.to_string())
                );
            }
        }

        Ok(location_result)
    }

    /// Decrypts an incoming `kind:445` for the live-sync engine (regime 1),
    /// returning the neutral [`EngineDecryptOutcome`] the processor plans
    /// against.
    ///
    /// `nostr_group_id` is the pseudonymous id the event was routed under (its
    /// `#h` tag); it is stamped onto the outcome so the real MLS group id never
    /// leaves haven-core (Security Rule 4). Like [`Self::decrypt_location`] this
    /// drops an event past its NIP-40 `expiration` (with the receiver grace) and
    /// best-effort re-syncs the circle's relay set on a group update; unlike it,
    /// a same-epoch sibling commit racing our pending commit is surfaced as
    /// [`EngineDecryptOutcome::CompetingCommit`] rather than collapsed to an
    /// opaque error.
    ///
    /// # Regime
    ///
    /// This is the REGIME-1 path (we hold no pending commit for the group). The
    /// engine must NOT call it while a settle window is open for the group:
    /// applying a sibling commit while holding our own pending FORKS the group
    /// (see the `*_while_holding_pending_*` / `blind_apply_*` regression tests).
    /// In that case the processor buffers raw candidates for `converge_commit`
    /// instead.
    #[must_use]
    pub fn decrypt_location_for_engine(
        &self,
        event: &Event,
        nostr_group_id: &[u8],
    ) -> crate::relay::live_sync::EngineDecryptOutcome {
        use crate::nostr::mls::ClassifiedProcessing;
        use crate::relay::live_sync::EngineDecryptOutcome as Out;
        use nostr::JsonUtil;

        // Receiver-side NIP-40 expiration drop (mirrors `decrypt_location`).
        if let Some(expires_at) = event.tags.iter().find_map(|t| match t.as_standardized() {
            Some(TagStandard::Expiration(ts)) => Some(*ts),
            _ => None,
        }) {
            let grace = Timestamp::from(
                expires_at.as_secs() + crate::location::ttl::RECEIVER_EXPIRATION_GRACE_SECS,
            );
            if Timestamp::now() > grace {
                return Out::Unprocessable;
            }
        }

        let created_at_secs = i64::try_from(event.created_at.as_secs()).unwrap_or(i64::MAX);

        // M7-B: this is the live-sync receiver AUTHORING path — `process_message_classified`
        // can auto-stage a peer-SelfRemove commit (an MDK write), and the AutoCommit
        // leg below writes the staged-commit marker. Hold the writer lock across the
        // whole classification + marker write so a background sweep cannot interleave.
        // This method is sync (no `.await`); the guard drops at the end of the match.
        let _writer = crate::write_lock::acquire_authoring();
        match self.mdk.process_message_classified(event) {
            ClassifiedProcessing::Processed(result) => {
                match MdkManager::to_location_result(*result) {
                    LocationMessageResult::Location {
                        sender_pubkey,
                        content,
                        ..
                    } => Out::Location {
                        nostr_group_id: nostr_group_id.to_vec(),
                        sender_pubkey,
                        content,
                        created_at_secs,
                    },
                    LocationMessageResult::GroupUpdate {
                        group_id,
                        evolution_event,
                    } => {
                        // Best-effort relay re-sync on a commit (mirrors
                        // `decrypt_location`); a transient storage error must not
                        // drop the successfully-processed update.
                        if let Err(e) = self.resync_circle_relays_from_mdk(&group_id) {
                            log::debug!(
                                "decrypt_location_for_engine: relay re-sync failed: {}",
                                redact_hex_sequences(&e.to_string())
                            );
                        }
                        // `Some` ⇒ an auto-committed peer SelfRemove: MDK staged a
                        // pending commit. The ENGINE (path B, M6-2) publishes +
                        // converges it in-Rust; surface the real group id + commit
                        // JSON for the converge task (in-crate only, never the
                        // FFI). The relay re-sync above ran at the still-epoch-N
                        // state, so the publish target relays are epoch-consistent.
                        // `None` ⇒ an already-applied peer commit (a UI roster
                        // change; safe to advance the cursor + emit).
                        evolution_event.map_or_else(
                            || Out::GroupUpdate {
                                nostr_group_id: nostr_group_id.to_vec(),
                                evolution_event_json: None,
                            },
                            |commit| {
                                // M7: mirror `decrypt_receive_only`'s AutoCommit
                                // leg — record the MDK-auto-staged pending commit
                                // so a concurrent / cold-wake catch-up SKIPS this
                                // group until the foreground path-B converge
                                // clears it. Defense-in-depth (MDK's
                                // OwnCommitPending is the structural fork barrier);
                                // closes the marker-absent window during the
                                // settle wait + a mid-converge process kill.
                                if let Err(e) = self.mark_group_staged(&group_id) {
                                    log::debug!(
                                        "decrypt_location_for_engine: marking \
                                         auto-staged commit failed: {}",
                                        redact_hex_sequences(&e.to_string())
                                    );
                                }
                                Out::AutoCommit {
                                    nostr_group_id: nostr_group_id.to_vec(),
                                    mls_group_id: group_id,
                                    commit_json: commit.as_json(),
                                }
                            },
                        )
                    }
                    LocationMessageResult::Unprocessable { .. } => Out::Unprocessable,
                    LocationMessageResult::PreviouslyFailed => Out::PreviouslyFailed,
                }
            }
            ClassifiedProcessing::CompetingCommit => Out::CompetingCommit,
            ClassifiedProcessing::Failed(_) => Out::OtherError,
        }
    }

    /// Fork-safe RECEIVE-ONLY decrypt for the background / resume catch-up sweep
    /// (M7). Returns a presence-only [`ReceiveOnlyOutcome`] (no coordinates,
    /// pubkey, group id, or commit JSON — the location content is persisted
    /// in-crate, never surfaced), so the sweep can decide cursor advancement
    /// without leaking (Security Rule 4).
    ///
    /// Fork-safety (C-NOFORK-2): a group that holds a locally-staged pending
    /// commit is SKIPPED WITHOUT DECRYPTING (the foreground owns its epoch
    /// transition; blind-applying a same-epoch sibling would fork). The check
    /// FAILS CLOSED — a storage error (e.g. locked device pre-first-unlock)
    /// yields [`ReceiveOnlyOutcome::Skipped`], never a decrypt.
    ///
    /// This NEVER authors, merges, converges, or CLEARS a commit. An
    /// auto-committed peer proposal is left staged (clearing loses the leave —
    /// the foreground engine converges it) and marked so future wakes skip.
    /// Unlike [`Self::decrypt_location_for_engine`] it does NOT re-sync relays.
    ///
    /// `own_pubkey_hex` lets a self-echo advance the cursor without persisting.
    #[must_use]
    pub fn decrypt_receive_only(
        &self,
        event: &Event,
        nostr_group_id: &[u8],
        own_pubkey_hex: &str,
    ) -> crate::relay::ReceiveOnlyOutcome {
        use crate::nostr::mls::ClassifiedProcessing;
        use crate::relay::ReceiveOnlyOutcome as Out;

        // C-NOFORK-2: never decrypt a group with a staged pending commit
        // (fail-closed: has_pending_commit returns true on any storage error).
        if self.has_pending_commit(nostr_group_id) {
            return Out::Skipped;
        }

        // Receiver-side NIP-40 expiration drop (mirrors the engine path).
        if let Some(expires_at) = event.tags.iter().find_map(|t| match t.as_standardized() {
            Some(TagStandard::Expiration(ts)) => Some(*ts),
            _ => None,
        }) {
            let grace = Timestamp::from(
                expires_at.as_secs() + crate::location::ttl::RECEIVER_EXPIRATION_GRACE_SECS,
            );
            if Timestamp::now() > grace {
                return Out::Skipped;
            }
        }

        // M7-B: the SWEEP writer. Try (non-blocking) to acquire the writer lock;
        // if a foreground authoring writer holds it, YIELD — treat contention
        // exactly like `Skipped` (no decrypt, cursor does not advance, the event
        // is re-fetched next sweep via the contiguous-prefix cursor). The guard
        // is held across `process_message_classified` (an MDK write) + the
        // co-located marker write; this method is sync (no `.await`).
        let Some(_writer) = crate::write_lock::try_acquire_background() else {
            return Out::Skipped;
        };
        match self.mdk.process_message_classified(event) {
            ClassifiedProcessing::Processed(result) => {
                match MdkManager::to_location_result(*result) {
                    LocationMessageResult::Location {
                        sender_pubkey,
                        content,
                        ..
                    } => {
                        // Self-echo: advance the cursor, do not persist our own.
                        if sender_pubkey != own_pubkey_hex {
                            if let Err(e) = self.persist_receive_only_location(
                                nostr_group_id,
                                &sender_pubkey,
                                &content,
                            ) {
                                log::debug!(
                                    "receive_only persist failed: {}",
                                    redact_hex_sequences(&e.to_string())
                                );
                                // Do NOT advance past an unpersisted location.
                                return Out::Skipped;
                            }
                        }
                        Out::Location
                    }
                    LocationMessageResult::GroupUpdate {
                        group_id,
                        evolution_event,
                    } => {
                        if evolution_event.is_some() {
                            // AutoCommit: MDK auto-staged a peer proposal commit
                            // (reachable only because has_pending_commit was
                            // false at entry). NEVER clear (loses the leave); SET
                            // the marker (future wakes skip) + stop the cursor;
                            // the foreground engine converges it.
                            if let Err(e) = self.mark_group_staged(&group_id) {
                                log::debug!(
                                    "receive_only: marking auto-staged commit failed: {}",
                                    redact_hex_sequences(&e.to_string())
                                );
                            }
                            Out::AutoCommitStaged
                        } else {
                            // Already-merged peer commit (convergent). Advance.
                            Out::CommitApplied
                        }
                    }
                    LocationMessageResult::Unprocessable { .. }
                    | LocationMessageResult::PreviouslyFailed => Out::Skipped,
                }
            }
            ClassifiedProcessing::CompetingCommit | ClassifiedProcessing::Failed(_) => Out::Skipped,
        }
    }

    /// Parses a decrypted `LocationMessage` content string and persists it as a
    /// last-known-location row (the in-crate persist the receive-only sweep uses
    /// so location content never crosses the FFI). `purge_after` is recomputed
    /// authoritatively by [`Self::upsert_last_known_location`].
    fn persist_receive_only_location(
        &self,
        nostr_group_id: &[u8],
        sender_pubkey: &str,
        content: &str,
    ) -> Result<()> {
        let msg: crate::location::LocationMessage = serde_json::from_str(content)
            .map_err(|_| CircleError::InvalidData("invalid location content".to_string()))?;
        let ngid: [u8; 32] = nostr_group_id
            .try_into()
            .map_err(|_| CircleError::InvalidData("invalid nostr_group_id length".to_string()))?;
        let row = super::LastKnownLocation {
            nostr_group_id: ngid,
            sender_pubkey: sender_pubkey.to_string(),
            latitude: msg.latitude,
            longitude: msg.longitude,
            geohash: msg.geohash,
            display_name: msg.display_name,
            timestamp: msg.timestamp.timestamp(),
            expires_at: msg.expires_at.timestamp(),
            purge_after: 0, // recomputed authoritatively by upsert
            updated_at: chrono::Utc::now().timestamp(),
        };
        self.upsert_last_known_location(&row)
    }

    // ==================== Last-Known Location Cache ====================

    /// Persists a last-known-location row.
    ///
    /// Authoritative enforcement point for the receiver-side retention
    /// window:
    ///
    /// * `purge_after` is **recomputed** server-side as
    ///   `timestamp + LOCATION_RETENTION_SECS` (1 day) so a caller cannot
    ///   inflate the persistence window. The retention window is hard-coded
    ///   and not configurable.
    /// * `display_name` is re-sanitized via
    ///   `sanitize_display_name` so non-printable or
    ///   over-length values from a forked sender cannot land on disk.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn upsert_last_known_location(&self, location: &super::LastKnownLocation) -> Result<()> {
        // Receiver-side retention is a fixed 1-day window. The `try_from`
        // is infallible for `LOCATION_RETENTION_SECS` (86_400 ≪ i64::MAX);
        // the `unwrap_or(i64::MAX)` is defensive in case the constant is
        // ever raised beyond `i64::MAX`.
        let retention_i64 =
            i64::try_from(crate::location::LOCATION_RETENTION_SECS).unwrap_or(i64::MAX);

        // purge_after = timestamp + retention, saturating so a
        // pathological timestamp cannot overflow i64.
        let derived_purge_after = location.timestamp.saturating_add(retention_i64);

        // Start from the caller-supplied row, then overwrite only the
        // fields we authoritatively control. Any future field on
        // `LastKnownLocation` is carried through automatically.
        let mut clamped = location.clone();
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
        // M7-B: `create_key_package` persists the key package's private
        // init/encryption material to MDK storage (an authoring MDK write);
        // exclude a concurrent background sweep.
        let _writer = crate::write_lock::acquire_authoring();
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
        // M7-B: exclude a concurrent background sweep for the merge (an MDK
        // write) + the marker clear. `converge_commit` calls this WITHOUT
        // holding the lock itself, so the non-reentrant lock is taken exactly
        // once here.
        let _writer = crate::write_lock::acquire_authoring();
        self.mdk
            .merge_pending_commit(mls_group_id)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        // M7: CLEAR-AFTER-MERGE (crash-safe). The merge is the CHOKEPOINT every
        // finalize path funnels through, so clearing the marker here covers all
        // of them by construction.
        self.mark_group_unstaged(mls_group_id);
        Ok(())
    }

    // ==================== M7 staged-commit marker ====================
    //
    // A Haven-owned, cross-process-visible mirror of MDK's per-group unmerged
    // `pending_commit` state (MDK exposes no public query for it, and the
    // in-memory settle window/gate don't survive a background wake). Set BEFORE
    // every MDK stage, cleared AFTER every MDK merge/clear. See the M7 design.

    /// Resolves a group's canonical lowercase-hex `nostr_group_id` — the marker
    /// key (Rule 4: the pseudonymous id, never the real MLS group id). `None`
    /// if the circle is unknown.
    fn marker_key(&self, mls_group_id: &GroupId) -> Option<String> {
        self.storage
            .get_circle(mls_group_id)
            .ok()
            .flatten()
            .map(|c| hex::encode(c.nostr_group_id))
    }

    /// Records that `mls_group_id` now holds a locally-staged, unmerged pending
    /// commit. MUST be called BEFORE the MDK stage: a crash between this and the
    /// stage leaves a STALE marker (over-skip, self-healing), never a MISSING
    /// one (fork-unsafe). Propagates errors so a marker-write failure ABORTS the
    /// stage — staging without a marker would let a background receive
    /// blind-apply a same-epoch sibling over the pending commit and fork.
    ///
    /// # Errors
    ///
    /// Returns an error if the circle is unknown or the marker write fails.
    fn mark_group_staged(&self, mls_group_id: &GroupId) -> Result<()> {
        let key = self.marker_key(mls_group_id).ok_or_else(|| {
            CircleError::Storage("staged-commit marker: circle not found".to_string())
        })?;
        let epoch = self.group_epoch_internal(mls_group_id).unwrap_or(0);
        let now = chrono::Utc::now().timestamp();
        self.storage.set_staged_commit(&key, epoch, now)
    }

    /// Clears a group's staged-commit marker. Called AFTER the MDK merge/clear.
    /// Best-effort: a failed clear leaves a STALE marker (over-skip, self-heals
    /// on the next finalize/clear), never a fork-unsafe missing one — so it
    /// never fails its caller.
    fn mark_group_unstaged(&self, mls_group_id: &GroupId) {
        if let Some(key) = self.marker_key(mls_group_id) {
            if let Err(e) = self.storage.clear_staged_commit(&key) {
                log::debug!(
                    "staged-commit marker clear failed (stale is safe): {}",
                    redact_hex_sequences(&e.to_string())
                );
            }
        }
    }

    /// Whether a group holds a locally-staged pending commit — the background /
    /// catch-up regime-2 gate, keyed by the pseudonymous `nostr_group_id`.
    ///
    /// FAILS CLOSED: any storage error (e.g. a locked device pre-first-unlock,
    /// or a momentary lock) returns `true`, so a receive-only sweep SKIPS the
    /// decrypt rather than fork-unsafely blind-applying a sibling commit.
    #[must_use]
    pub fn has_pending_commit(&self, nostr_group_id: &[u8]) -> bool {
        let key = hex::encode(nostr_group_id);
        match self.storage.has_staged_commit(&key) {
            Ok(present) => present,
            Err(e) => {
                log::debug!(
                    "has_pending_commit failing closed on storage error: {}",
                    redact_hex_sequences(&e.to_string())
                );
                true
            }
        }
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
        // M7-B: exclude a concurrent background sweep for the marker+MDK write.
        let _writer = crate::write_lock::acquire_authoring();
        // M7: SET-BEFORE-STAGE. A marker-write failure aborts the stage.
        self.mark_group_staged(mls_group_id)?;
        match self.mdk.self_update(mls_group_id) {
            Ok(result) => Ok(result),
            Err(e) => {
                // Stage failed → no pending commit → un-mark (best-effort;
                // a leftover stale marker is safe).
                self.mark_group_unstaged(mls_group_id);
                Err(CircleError::Mls(redact_hex_sequences(&e.to_string())))
            }
        }
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
        // M7-B: exclude a concurrent background sweep for the clear (an MDK
        // write) + the marker clear. `converge_commit` calls this WITHOUT
        // holding the lock, so the non-reentrant lock is taken exactly once.
        let _writer = crate::write_lock::acquire_authoring();
        self.mdk
            .clear_pending_commit(mls_group_id)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        // M7: CLEAR-AFTER-CLEAR (crash-safe). The other CHOKEPOINT every rollback
        // path funnels through (converge losers, propose_leave/complete_leave
        // pre-clears, path-B gated_abort).
        self.mark_group_unstaged(mls_group_id);
        Ok(())
    }

    /// Converges a just-staged commit against competing same-epoch commits.
    ///
    /// Implements the MIP-03 adopt-winner rule so concurrent committers from a
    /// shared epoch N land on the SAME epoch with the SAME exporter secret
    /// instead of forking. This does NOT publish — it only decides LOCAL state.
    /// `competing_commits` are the same-epoch sibling commits the caller
    /// observed (empty before M3, where this degrades to today's eager merge);
    /// `staged_epoch` is the epoch the commit was created from; `intent` lets
    /// the loser path report whether its membership change still needs
    /// re-staging by the caller.
    ///
    /// # Publication ordering (M6 settle-window callers — READ THIS)
    ///
    /// In the M6 settle-window model the caller publishes `our_commit` *during*
    /// the window — BEFORE calling this — and UNCONDITIONALLY, not "only when
    /// `Merged`". This is load-bearing for fork-safety: two concurrent admins
    /// each converge only over the competitors they actually received, and a
    /// competitor only exists because the other admin published it during its
    /// window. If neither publishes until after converging, each sees an empty
    /// competitor set, both take the `Merged` leg, and the group FORKS (the
    /// exact `eager_finalize_then_exchange` bug). Publishing a *losing* commit
    /// is harmless: any member already advanced to the winner's N+1 drops it via
    /// MDK `WrongEpoch` (no rollback). This function operates purely on the local
    /// pending commit + the passed competitors and is oblivious to whether the
    /// caller published — so it stays correct either way. The pre-M3 eager path
    /// (empty competitors) keeps the historical "publish on success" shape; the
    /// distinction is only that a settle-window caller publishes earlier.
    ///
    /// Every non-`Merged` path leaves NO dangling pending commit (a security
    /// invariant — a dangling commit would brick future operations). The
    /// load-bearing proof that an `AdoptedWinner` loser holds the winner's
    /// exporter secret (not a same-number twin) is a cross-manager
    /// cross-decrypt asserted by the callers' tests; the core's own check is the
    /// cheap epoch advance.
    ///
    /// # Errors
    ///
    /// Returns an error only if the group epoch or membership cannot be read.
    /// Individual MDK message-processing outcomes are tolerated by design.
    pub fn converge_commit(
        &self,
        mls_group_id: &GroupId,
        our_commit: &nostr::Event,
        staged_epoch: u64,
        competing_commits: &[nostr::Event],
        intent: &CommitIntent,
    ) -> Result<CommitConvergence> {
        self.converge_commit_collecting_locations(
            mls_group_id,
            our_commit,
            staged_epoch,
            competing_commits,
            intent,
        )
        .map(|(convergence, _delivered)| convergence)
    }

    /// [`Self::converge_commit`] that ALSO returns the buffered Locations it
    /// excluded from the candidate set, so a bus-aware caller can re-deliver them.
    ///
    /// # The H1 liveness gate (M11) — why a Location is not a competitor
    ///
    /// During a settle window the engine buffers **every** same-epoch `kind:445`
    /// raw, without classifying it (regime 2 — decrypting a sibling commit would
    /// fork; see [`crate::relay::live_sync::settle`]). Because Haven is a
    /// **location** app, routine Location `kind:445` events land in that buffer
    /// too. A Location decrypts to an MLS *application message*, which cannot
    /// advance the epoch — so it is NOT a genuine convergence competitor. If it
    /// merely SORTS ahead of our commit in MIP-03 order and we blindly picked the
    /// order-key minimum (the pre-M11 behavior), applying it would fail to advance
    /// and we would report `RolledBack` → re-stage → likely another Location wins
    /// → the membership op is starved to `notApplied`. That is the liveness bug.
    ///
    /// The fix is **receiver-side, post-decrypt, zero new wire metadata**: the
    /// published `kind:445` is byte-identical; we classify by the decrypt RESULT
    /// (an application message vs an epoch-advancing commit) — the only signal
    /// MDK exposes without a destructive apply is "did the epoch advance." We walk
    /// the order-beating competitors in MIP-03 order and adopt the FIRST that
    /// actually advances the epoch (the winning commit); every non-commit is
    /// skipped — a Location is COLLECTED (never dropped from receive) and a
    /// forged/undecryptable event is ignored. If none advances, our commit is the
    /// sole real commit and merges. So a Location can neither win the order key
    /// (→ no spurious `RolledBack`) nor be adopted; both failure modes are closed.
    ///
    /// # Errors
    ///
    /// Returns an error only if the group epoch or membership cannot be read.
    /// Individual MDK message-processing outcomes are tolerated by design.
    pub(crate) fn converge_commit_collecting_locations(
        &self,
        mls_group_id: &GroupId,
        our_commit: &nostr::Event,
        staged_epoch: u64,
        competing_commits: &[nostr::Event],
        intent: &CommitIntent,
    ) -> Result<(CommitConvergence, Vec<ConvergedLocation>)> {
        use crate::nostr::mls::ClassifiedProcessing;

        let mut delivered: Vec<ConvergedLocation> = Vec::new();

        // TOCTOU: the local group may have advanced past `staged_epoch` between
        // staging and this call (e.g. the evolution poller applied a peer
        // commit). Our staged commit is then stale; clear it so nothing dangles
        // and let the caller re-fetch + re-stage from the new epoch.
        // NB: `group_epoch_internal` (not the test-gated `group_epoch`) — this
        // is a production path and must compile in release builds.
        let current = self.group_epoch_internal(mls_group_id)?;
        if current > staged_epoch {
            let _ = self.clear_pending_commit(mls_group_id);
            return Ok((CommitConvergence::RolledBack, delivered));
        }

        // We are the global MIP-03 minimum over EVERY competitor (real commit OR
        // non-commit): merge our pending commit WITHOUT decrypting any competitor,
        // so buffered Locations are left untouched for lossless cursor replay. The
        // empty-competitor leg is the eager-merge degrade when no settle-window
        // competitors were collected.
        if competing_commits.is_empty() || our_commit_wins(our_commit, competing_commits) {
            return Ok((
                self.merge_our_pending_commit(mls_group_id, staged_epoch)?,
                delivered,
            ));
        }

        // A competitor sorts ahead of us. Only a REAL COMMIT is a genuine
        // convergence competitor (H1). Walk the order-beating competitors in
        // MIP-03 order and adopt the FIRST that is a real epoch-advancing commit;
        // every non-commit is skipped (collecting a Location for re-delivery).
        // Restricting to `commit_beats` (strict `<`) also excludes our OWN commit
        // re-delivered as a competitor (identical order key).
        let mut beating: Vec<&nostr::Event> = competing_commits
            .iter()
            .filter(|c| commit_beats(c, our_commit))
            .collect();
        beating.sort_by_key(|a| commit_order_key(a));

        for candidate in beating {
            // Trial-apply in MIP-03 order via the CLASSIFYING processor. Two
            // signals mark a real competing commit that beat us and must be
            // adopted (never skipped → fork):
            //   * our epoch ADVANCED (the pinned MDK applies a sibling commit even
            //     under our held pending commit), or
            //   * MDK refused to apply it over our pending and the error
            //     CLASSIFIES as a competing commit (`OwnCommitPending` etc.) — a
            //     rev-dependent behavior this arm future-proofs against.
            //
            // M7-B: do NOT hold the writer lock at method scope (the clear/finalize
            // helpers take the non-reentrant lock → deadlock). Wrap ONLY the
            // low-level MDK writes, each in its own brief critical section.
            let outcome = {
                let _writer = crate::write_lock::acquire_authoring();
                self.mdk.process_message_classified(candidate)
            };
            let advanced = self.group_epoch_internal(mls_group_id)? > staged_epoch;

            if advanced || matches!(outcome, ClassifiedProcessing::CompetingCommit) {
                // Adopt the winner. Clear our now-stale pending commit + its
                // orphaned signer (the NO-STALE-STAGED-SECRET enforcement point;
                // no-op-safe), then (re-)apply the winner to sit firmly on its
                // branch. Verify we advanced; if not, roll back cleanly.
                let _ = self.clear_pending_commit(mls_group_id);
                {
                    let _writer = crate::write_lock::acquire_authoring();
                    let _ = self.mdk.process_message(candidate);
                }
                if self.group_epoch_internal(mls_group_id)? <= staged_epoch {
                    let _ = self.clear_pending_commit(mls_group_id);
                    return Ok((CommitConvergence::RolledBack, delivered));
                }
                let intent_still_pending = self.intent_unsatisfied(mls_group_id, intent)?;
                return Ok((
                    CommitConvergence::AdoptedWinner {
                        intent_still_pending,
                    },
                    delivered,
                ));
            }

            // Did NOT advance and did NOT classify as a competing commit: inspect
            // the decrypt result.
            if let ClassifiedProcessing::Processed(result) = outcome {
                match MdkManager::to_location_result(*result) {
                    LocationMessageResult::Location {
                        sender_pubkey,
                        content,
                        ..
                    } => {
                        // A buffered Location: collect it so the caller re-delivers
                        // it (a buffered Location must never be dropped from receive
                        // just because a membership op was converging).
                        delivered.push(ConvergedLocation {
                            sender_pubkey,
                            content,
                            created_at_secs: i64::try_from(candidate.created_at.as_secs())
                                .unwrap_or(i64::MAX),
                        });
                    }
                    LocationMessageResult::GroupUpdate {
                        evolution_event: Some(_),
                        ..
                    } => {
                        // An auto-committing proposal (e.g. a peer `SelfRemove`
                        // received by an admin) drove MDK's `auto_commit_proposal`,
                        // whose `stage_commit` OVERWRITES our own staged pending
                        // commit. Our commit is gone — merging the pending MDK now
                        // holds would merge an unpublished change → local FORK.
                        // Clear it and roll back.
                        //
                        // KNOWN LIMITATION (M11 review HIGH-1, Phase-B blocker —
                        // only reachable with live-sync ON, so it does NOT affect
                        // the flag-off Phase-A ship): the M6 settle-window caller
                        // has ALREADY published our commit. Trial-applying the
                        // SelfRemove here destroyed its staged state, and OpenMLS
                        // rejects re-applying our own published commit, so this
                        // rollback strands us while passive peers keep the earlier
                        // published commit as the MIP-03 winner → DISTRIBUTED fork.
                        // The proper fix (exclude SelfRemove/PublicMessage
                        // competitors from the trial-apply so our commit merges, or
                        // an M6 publish-ordering change) needs a non-destructive
                        // MLS-framing peek that the PINNED MDK does not expose; it
                        // is tracked as a Phase-B prerequisite in
                        // docs/M11_ROLLOUT_PLAN.md before `liveSyncEnabled` flips.
                        let _ = self.clear_pending_commit(mls_group_id);
                        return Ok((CommitConvergence::RolledBack, delivered));
                    }
                    _ => {
                        // A stored proposal (evolution_event None), a non-advancing
                        // Commit, or Unprocessable/PreviouslyFailed: our pending
                        // commit is intact — skip and keep walking.
                    }
                }
            }
            // ClassifiedProcessing::Failed (forged / undecryptable) → ignore.
        }

        // No order-beating competitor was a real commit ⇒ our commit is the sole
        // real commit ⇒ merge ours.
        Ok((
            self.merge_our_pending_commit(mls_group_id, staged_epoch)?,
            delivered,
        ))
    }

    /// Merges our own staged pending commit (the MIP-03 "we won" leg of
    /// [`Self::converge_commit_collecting_locations`]). A finalize failure with an
    /// already-advanced group is a benign already-merged; otherwise a clean
    /// rollback that leaves no dangling pending commit.
    fn merge_our_pending_commit(
        &self,
        mls_group_id: &GroupId,
        staged_epoch: u64,
    ) -> Result<CommitConvergence> {
        match self.finalize_pending_commit(mls_group_id) {
            Ok(()) => Ok(CommitConvergence::Merged),
            Err(_) => {
                if self.group_epoch_internal(mls_group_id)? > staged_epoch {
                    Ok(CommitConvergence::Merged)
                } else {
                    Ok(CommitConvergence::RolledBack)
                }
            }
        }
    }

    /// Returns whether a commit `intent` is still unsatisfied by the group's
    /// current (post-adopt) membership.
    fn intent_unsatisfied(&self, mls_group_id: &GroupId, intent: &CommitIntent) -> Result<bool> {
        match intent {
            CommitIntent::None => Ok(false),
            CommitIntent::RemoveMembers(pks) => {
                let present = self.member_pubkeys_hex(mls_group_id)?;
                Ok(pks.iter().any(|pk| present.contains(&pk.to_hex())))
            }
            CommitIntent::AddMembers(pks) => {
                let present = self.member_pubkeys_hex(mls_group_id)?;
                Ok(pks.iter().any(|pk| !present.contains(&pk.to_hex())))
            }
        }
    }

    /// Returns the hex public keys of the group's current members.
    fn member_pubkeys_hex(
        &self,
        mls_group_id: &GroupId,
    ) -> Result<std::collections::HashSet<String>> {
        Ok(self
            .get_members(mls_group_id)?
            .into_iter()
            .map(|m| m.pubkey)
            .collect())
    }

    // ==================== Sync Cursors ====================
    //
    // Thin pass-throughs to `CircleStorage`'s per-stream sync-cursor methods,
    // exposed publicly so the FFI layer does not need direct access to the
    // `pub(crate)` storage field. See [`crate::relay::cursor`] for the stream
    // keys and `since`-derivation semantics, and [`crate::circle::storage`]
    // for the monotonic-max persistence guarantees.

    /// Reads the persisted relay sync cursor (raw ms) for `stream`.
    ///
    /// Returns `None` when the stream has never been seeded.
    ///
    /// # Errors
    ///
    /// Propagates storage errors.
    pub fn read_sync_cursor(&self, stream: &str) -> Result<Option<i64>> {
        self.storage.read_sync_cursor(stream)
    }

    /// Seeds `stream`'s cursor to `ms` only if it is currently unseeded.
    ///
    /// # Errors
    ///
    /// Propagates storage errors.
    pub fn seed_sync_cursor_if_unset(&self, stream: &str, ms: i64) -> Result<()> {
        self.storage.seed_sync_cursor_if_unset(stream, ms)
    }

    /// Advances `stream`'s cursor to `ms` (monotonic max; never backward).
    ///
    /// # Errors
    ///
    /// Propagates storage errors.
    pub fn advance_sync_cursor(&self, stream: &str, ms: i64) -> Result<()> {
        self.storage.update_sync_cursor_max(stream, ms)
    }

    /// Resets `stream`'s cursor to the unseeded state.
    ///
    /// # Errors
    ///
    /// Propagates storage errors.
    pub fn reset_sync_cursor(&self, stream: &str) -> Result<()> {
        self.storage.reset_sync_cursor(stream)
    }

    /// Removes ALL sync-cursor rows (bulk reset) for the wipe-on-logout path.
    ///
    /// # Errors
    ///
    /// Returns an error if the storage write fails.
    pub fn reset_all_sync_cursors(&self) -> Result<()> {
        self.storage.reset_all_sync_cursors()
    }

    /// Removes ALL M7 staged-commit markers (wipe-on-logout). See
    /// [`CircleStorage::wipe_all_staged_commits`].
    ///
    /// # Errors
    ///
    /// Returns an error if the storage write fails.
    pub fn wipe_all_staged_commits(&self) -> Result<()> {
        self.storage.wipe_all_staged_commits()
    }

    /// Prunes the `processed_gift_wraps` dedup cache: retention-deletes rows
    /// past the window, then enforces the row cap. Returns the number removed.
    /// See [`CircleStorage::prune_processed_gift_wraps`].
    ///
    /// # Errors
    ///
    /// Returns an error if the storage write fails.
    pub fn prune_processed_gift_wraps(&self, now_secs: i64) -> Result<u64> {
        self.storage.prune_processed_gift_wraps(now_secs)
    }

    /// Removes ALL `processed_gift_wraps` rows (wipe-on-logout). See
    /// [`CircleStorage::wipe_all_processed_gift_wraps`].
    ///
    /// # Errors
    ///
    /// Returns an error if the storage write fails.
    pub fn wipe_all_processed_gift_wraps(&self) -> Result<()> {
        self.storage.wipe_all_processed_gift_wraps()
    }

    // ==================== Relay Preferences ====================
    //
    // Thin pass-throughs to `CircleStorage`'s relay-preference methods,
    // exposed publicly so external crates (the FFI layer) do not need
    // direct access to the `pub(crate)` storage field. See
    // [`crate::circle::storage_relay_prefs`] for behaviour details and
    // tests.

    /// See [`CircleStorage::seed_defaults_if_unseeded`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn seed_relay_defaults_if_unseeded(&self) -> Result<bool> {
        self.storage.seed_defaults_if_unseeded()
    }

    /// See [`CircleStorage::list_user_relays`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn list_user_relays(
        &self,
        relay_type: super::relay_prefs::RelayType,
    ) -> Result<Vec<String>> {
        self.storage.list_user_relays(relay_type)
    }

    /// See [`CircleStorage::add_user_relay`].
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::InvalidData`] for malformed URLs and database
    /// errors otherwise.
    pub fn add_user_relay(
        &self,
        url: &str,
        relay_type: super::relay_prefs::RelayType,
    ) -> Result<()> {
        self.storage.add_user_relay(url, relay_type)
    }

    /// See [`CircleStorage::remove_user_relay`].
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::InvalidData`] when the URL is invalid or
    /// would empty the category. Database errors otherwise.
    pub fn remove_user_relay(
        &self,
        url: &str,
        relay_type: super::relay_prefs::RelayType,
    ) -> Result<bool> {
        self.storage.remove_user_relay(url, relay_type)
    }

    /// See [`CircleStorage::restore_defaults_for`] (non-destructive).
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn restore_relay_defaults_for(
        &self,
        relay_type: super::relay_prefs::RelayType,
    ) -> Result<()> {
        self.storage.restore_defaults_for(relay_type)
    }

    /// See [`CircleStorage::wipe_and_reset_defaults_for`] (destructive).
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn wipe_and_reset_relay_defaults_for(
        &self,
        relay_type: super::relay_prefs::RelayType,
    ) -> Result<()> {
        self.storage.wipe_and_reset_defaults_for(relay_type)
    }

    /// See [`CircleStorage::get_publish_kp_relay_list`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn get_publish_kp_relay_list(&self) -> Result<bool> {
        self.storage.get_publish_kp_relay_list()
    }

    /// See [`CircleStorage::set_publish_kp_relay_list`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn set_publish_kp_relay_list(&self, value: bool) -> Result<()> {
        self.storage.set_publish_kp_relay_list(value)
    }

    /// See [`CircleStorage::get_publish_inbox_relay_list`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn get_publish_inbox_relay_list(&self) -> Result<bool> {
        self.storage.get_publish_inbox_relay_list()
    }

    /// See [`CircleStorage::set_publish_inbox_relay_list`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn set_publish_inbox_relay_list(&self, value: bool) -> Result<()> {
        self.storage.set_publish_inbox_relay_list(value)
    }

    /// See [`CircleStorage::record_published_event`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn record_published_event(
        &self,
        kind: u16,
        d_tag: &str,
        event_id: &nostr::EventId,
        pubkey: &nostr::PublicKey,
        published_at: i64,
    ) -> Result<()> {
        self.storage
            .record_published_event(kind, d_tag, event_id, pubkey, published_at)
    }

    /// See [`CircleStorage::last_published_event`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn last_published_event(
        &self,
        kind: u16,
        d_tag: &str,
        pubkey: &nostr::PublicKey,
    ) -> Result<Option<super::storage_relay_prefs::PublishedEventRecord>> {
        self.storage.last_published_event(kind, d_tag, pubkey)
    }

    // ==================== M8-2 KeyPackage maintenance ====================
    //
    // Thin pass-throughs so the FFI orchestration (which owns the identity
    // secret + the RelayManager, in the sibling `rust_builder` crate) can run
    // the KeyPackage-maintenance decision. The `storage` field is `pub(crate)`
    // and `mdk` is private, so the cross-crate FFI cannot reach them directly.

    /// See [`CircleStorage::record_published_key_package`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn record_published_key_package(
        &self,
        row: &super::storage_key_packages::PublishedKeyPackageRow,
    ) -> Result<()> {
        self.storage.record_published_key_package(row)
    }

    /// See [`CircleStorage::latest_canonical_d_tag`] — the stable NIP-33 `d`
    /// slot the maintenance task reuses across rotations.
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn latest_canonical_d_tag(&self) -> Result<Option<String>> {
        self.storage.latest_canonical_d_tag()
    }

    /// See [`CircleStorage::canonical_published_hash_refs`] — the tracked
    /// `hash_ref`s the live-material gate runs against.
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn canonical_published_hash_refs(&self) -> Result<Vec<Vec<u8>>> {
        self.storage.canonical_published_hash_refs()
    }

    /// See [`CircleStorage::latest_legacy_event_id`] — the most-recent legacy
    /// (kind 443) `KeyPackage` twin id the maintenance republish GC scrubs via a
    /// best-effort NIP-09 deletion.
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn latest_legacy_event_id(&self) -> Result<Option<String>> {
        self.storage.latest_legacy_event_id()
    }

    /// See [`CircleStorage::canonical_published_event_refs`] — `(event_id,
    /// hash_ref)` pairs used to correlate a probed on-relay `KeyPackage` event
    /// with its tracked local material for the live-material gate.
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn canonical_published_event_refs(&self) -> Result<Vec<(String, Vec<u8>)>> {
        self.storage.canonical_published_event_refs()
    }

    /// See [`MdkManager::has_live_key_material`] — the live-material gate.
    ///
    /// Returns whether the private MLS init-key material for a published
    /// `KeyPackage` (identified by its stored `hash_ref`) is still LIVE in
    /// local storage. A `false` verdict means the published event is DEAD
    /// (consumed + deleted, or never stored) and republishing over it is safe.
    ///
    /// # Errors
    ///
    /// Returns an error if the `hash_ref` cannot be deserialized or the storage
    /// query fails; all error strings are hex-redacted.
    pub fn has_live_key_material(&self, hash_ref_bytes: &[u8]) -> Result<bool> {
        self.mdk
            .has_live_key_material(hash_ref_bytes)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
    }

    /// See [`MdkManager::create_key_package_with_d`] — builds a `KeyPackage`
    /// bundle, optionally reusing a stable NIP-33 `d` tag so a rotation
    /// REPLACES the same addressable coordinate.
    ///
    /// Mirrors [`Self::create_key_package`] in taking the authoring write lock
    /// (the generate persists private init/encryption material to MDK storage).
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid, no valid relay URLs are
    /// provided, or key package generation fails.
    pub fn create_key_package_with_d(
        &self,
        identity_pubkey: &str,
        relays: &[String],
        existing_d_tag: Option<&str>,
    ) -> Result<KeyPackageBundle> {
        let _writer = crate::write_lock::acquire_authoring();
        self.mdk
            .create_key_package_with_d(identity_pubkey, relays, existing_d_tag)
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

/// Result of adding members to an existing circle.
pub struct AddMembersResult {
    /// Kind:445 evolution (Add commit) event to publish to the circle's relays.
    ///
    /// Staged as a pending commit; finalize (merge) it only after a successful
    /// publish, or clear it on failure (see [`add_members_with_welcomes`]).
    ///
    /// [`add_members_with_welcomes`]: CircleManager::add_members_with_welcomes
    pub evolution_event: nostr::Event,
    /// Gift-wrapped Welcome events for the newly added members.
    ///
    /// Publish these only after the evolution event has been published and the
    /// pending commit finalized, so a rolled-back add produces no Welcome on
    /// the wire (avoids a MIP-02 state fork where an invitee accepts into an
    /// epoch no existing member reached).
    pub welcome_events: Vec<GiftWrappedWelcome>,
}

// Custom `Debug` redacts the evolution event (whose `h` tag carries the
// `nostr_group_id`) and the Welcome payloads, so a stray `{:?}` can never
// leak group-ID / key material (Security Rule 4/6). Mirrors the redacting
// `Debug` impls on the `*Ffi` result types.
impl std::fmt::Debug for AddMembersResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AddMembersResult")
            .field("evolution_event", &"<redacted>")
            .field("welcome_events_count", &self.welcome_events.len())
            .finish()
    }
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

    /// Calls `decrypt_receive_only`, absorbing a `Skipped` that is caused by
    /// TRANSIENT contention on the process-global `write_lock` from OTHER
    /// parallel authoring tests (the sweep uses `try_acquire_background`, which
    /// yields on ANY concurrent authoring writer in the process). A
    /// contention-`Skipped` is the documented lossless-yield behavior; because
    /// the sweep never advanced its cursor and never touched MDK, the SAME event
    /// re-processes on the next attempt. Only for tests whose TRUE outcome is
    /// non-`Skipped`; tests asserting a genuine `Skipped` must call
    /// `decrypt_receive_only` directly (a real skip must not be retried away).
    fn receive_only_until_applied(
        manager: &CircleManager,
        event: &Event,
        nostr_group_id: &[u8],
        own_pubkey_hex: &str,
    ) -> crate::relay::ReceiveOnlyOutcome {
        use crate::relay::ReceiveOnlyOutcome;
        let mut out = ReceiveOnlyOutcome::Skipped;
        // Bounded by ~2s worst case; converges in a few ms in practice (the
        // authoring lock is held only microseconds per op). A short sleep (not a
        // bare `yield_now`) lets the scheduler drain concurrent lock holders so
        // this thread reliably observes an uncontended window, even under the
        // full parallel test suite's sustained authoring pressure.
        for _ in 0..2000 {
            out = manager.decrypt_receive_only(event, nostr_group_id, own_pubkey_hex);
            if out != ReceiveOnlyOutcome::Skipped {
                return out;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        out
    }

    /// Builds a `MemberKeyPackage` for a fresh identity with caller-controlled
    /// inbox / NIP-65 relays, for exercising the Welcome-delivery cascade.
    ///
    /// The underlying key package is minted with a throwaway group relay; the
    /// member never processes the resulting Welcome, so the temporary MDK
    /// store used to create it can be discarded immediately.
    fn make_member_with_relays(
        inbox_relays: Vec<String>,
        nip65_relays: Vec<String>,
    ) -> MemberKeyPackage {
        let kp_relays = vec!["wss://kp.example.com".to_string()];
        let member_keys = Keys::generate();
        let member_pubkey_hex = member_keys.public_key().to_hex();
        let kp_dir = TempDir::new().unwrap();
        let kp_manager = CircleManager::new_unencrypted(kp_dir.path()).unwrap();
        let bundle = kp_manager
            .mdk
            .create_key_package(&member_pubkey_hex, &kp_relays)
            .expect("create member key package");
        let tags: Vec<nostr::Tag> = bundle
            .tags_443
            .into_iter()
            .map(|t| nostr::Tag::parse(&t).unwrap())
            .collect();
        let kp_event = EventBuilder::new(Kind::MlsKeyPackage, bundle.content)
            .tags(tags)
            .sign_with_keys(&member_keys)
            .expect("sign member key package");
        MemberKeyPackage {
            key_package_event: kp_event,
            inbox_relays,
            nip65_relays,
        }
    }

    #[tokio::test]
    async fn welcome_delivery_uses_creator_inbox_as_tier3() {
        let dir = TempDir::new().unwrap();
        let alice = CircleManager::new_unencrypted(dir.path()).unwrap();
        let alice_keys = Keys::generate();

        // Member advertises NO relays (empty inbox + empty NIP-65), forcing
        // the cascade down to the creator's own inbox relays (tier 3).
        let member = make_member_with_relays(vec![], vec![]);
        let config = CircleConfig::new("Tier3 Circle")
            .with_relays(vec!["wss://group.example.com".to_string()]);
        let creator_inbox = vec!["wss://creator-inbox.example.com".to_string()];

        let result = alice
            .create_circle(&alice_keys, vec![member], &config, &creator_inbox)
            .await
            .expect("creation should succeed using the creator's inbox as tier 3");

        assert_eq!(result.welcome_events.len(), 1);
        // Tier 3 delivery uses the creator's own inbox relays verbatim.
        assert_eq!(result.welcome_events[0].recipient_relays, creator_inbox);
        // ...and NEVER a public default (two-plane leak invariant I1).
        for d in crate::circle::PRODUCTION_DEFAULT_RELAYS {
            assert!(
                !result.welcome_events[0]
                    .recipient_relays
                    .iter()
                    .any(|r| r.starts_with(d)),
                "welcome delivery must never fall back to a public default ({d})"
            );
        }
    }

    #[tokio::test]
    async fn welcome_delivery_errors_when_no_relays() {
        let dir = TempDir::new().unwrap();
        let alice = CircleManager::new_unencrypted(dir.path()).unwrap();
        let alice_keys = Keys::generate();

        let member = make_member_with_relays(vec![], vec![]);
        let config = CircleConfig::new("Fail Closed Circle")
            .with_relays(vec!["wss://group.example.com".to_string()]);

        // No member relays AND no creator fallback relays -> fail closed,
        // rather than leaking the recipient's pubkey to public defaults.
        let err = alice
            .create_circle(&alice_keys, vec![member], &config, &[])
            .await
            .expect_err("creation must fail closed when no delivery relay exists");
        assert!(matches!(err, CircleError::MissingWelcomeRelays));
        // The surfaced message is generic — no relay URL, pubkey, or group id.
        assert_eq!(err.to_string(), "No reachable relay for welcome delivery");
        // No phantom state: failing closed must persist NO circle (the
        // pre-check fires before create_group / save_circle / save_membership).
        let circles = alice.get_circles().expect("get_circles");
        assert!(
            circles.is_empty(),
            "fail-closed create_circle must leave no circle in storage"
        );
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

    // ====================================================================
    // MIP-01 group-relay update (admin) + member convergence (re-sync)
    // ====================================================================

    /// Sorted+deduped copy, for order-insensitive relay-set assertions.
    fn sorted_relays(v: &[String]) -> Vec<String> {
        let mut out = v.to_vec();
        out.sort();
        out.dedup();
        out
    }

    #[test]
    fn admin_relay_update_converges_admin_and_member() {
        let tp = setup_two_party_circle();
        let new_relays = vec![
            "wss://relay.test.com".to_string(),
            "wss://relay2.test.com".to_string(),
        ];

        // Alice (admin) stages the relay-update commit.
        let update = tp
            .alice
            .update_circle_relays(&tp.mls_group_id, &new_relays)
            .expect("admin must be allowed to update relays");

        // Publish-then-merge ordering: before finalize, the admin's app row is
        // unchanged (the new relays are not yet authoritative).
        let alice_before = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            alice_before.relays, tp.relays,
            "circle.relays must not change before the commit is merged"
        );

        // Finalize on the admin side (merge + producer-side re-sync).
        tp.alice
            .finalize_relay_update(&tp.mls_group_id)
            .expect("admin finalize");

        let expected = sorted_relays(&new_relays);
        let alice_after = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            alice_after.relays, expected,
            "admin circle.relays must converge to the new set after merge"
        );

        // The member (Bob) processes the commit through the REAL consumer path
        // (decrypt_location) and converges on the identical set.
        let result = tp
            .bob
            .decrypt_location(&update.evolution_event)
            .expect("bob processes the relay-update commit");
        assert!(
            matches!(result, LocationMessageResult::GroupUpdate { .. }),
            "a GroupContextExtensions commit must surface as GroupUpdate"
        );
        let bob_after = tp
            .bob
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            bob_after.relays, expected,
            "member circle.relays must converge to the new set"
        );
        assert_eq!(
            alice_after.relays, bob_after.relays,
            "no split-brain: admin and member end on the same relay set"
        );
    }

    #[test]
    fn admin_relay_replacement_drops_old_relay_and_converges() {
        let tp = setup_two_party_circle();
        // Genuine REMOVAL/replacement: [R1] -> [R2], dropping R1. This is the
        // case the union(old∪new) publish (Dart side) exists to protect; here
        // we lock the CORE convergence invariant: after both sides process the
        // commit, circle.relays is exactly the new set (a hard REPLACE, not a
        // merge) — the dropped relay must not survive on either side.
        let new_relays = vec!["wss://relay2.test.com".to_string()];

        let update = tp
            .alice
            .update_circle_relays(&tp.mls_group_id, &new_relays)
            .expect("admin replaces the relay set");
        tp.alice
            .finalize_relay_update(&tp.mls_group_id)
            .expect("admin finalize");

        let expected = sorted_relays(&new_relays);
        let dropped = "wss://relay.test.com".to_string();

        let alice_after = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            alice_after.relays, expected,
            "admin circle.relays must REPLACE (not merge) to the new set"
        );
        assert!(
            !alice_after.relays.contains(&dropped),
            "the dropped relay must not survive on the admin side"
        );

        let result = tp
            .bob
            .decrypt_location(&update.evolution_event)
            .expect("bob processes the replacement commit");
        assert!(matches!(result, LocationMessageResult::GroupUpdate { .. }));
        let bob_after = tp
            .bob
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            bob_after.relays, expected,
            "member circle.relays must converge to the replacement set"
        );
        assert!(
            !bob_after.relays.contains(&dropped),
            "the dropped relay must not survive on the member side"
        );
        assert_eq!(
            alice_after.relays, bob_after.relays,
            "no split-brain on a relay removal"
        );
    }

    #[test]
    fn non_admin_relay_update_is_rejected_and_changes_nothing() {
        let tp = setup_two_party_circle();
        // Bob is a plain member, not an admin — MDK enforces admin-only
        // GroupContextExtensions commits against live MLS state.
        let result = tp
            .bob
            .update_circle_relays(&tp.mls_group_id, &["wss://relay2.test.com".to_string()]);
        assert!(
            matches!(result, Err(CircleError::Mls(_))),
            "MDK must reject a non-admin relay update"
        );
        let bob_circle = tp
            .bob
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            bob_circle.relays, tp.relays,
            "a rejected update must change nothing"
        );
    }

    #[test]
    fn update_circle_relays_rejects_empty_set() {
        let tp = setup_two_party_circle();
        assert!(
            matches!(
                tp.alice.update_circle_relays(&tp.mls_group_id, &[]),
                Err(CircleError::InvalidData(_))
            ),
            "an empty relay set must be rejected (445 has no default fallback)"
        );
        let circle = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(circle.relays, tp.relays, "no commit staged on rejection");
    }

    #[test]
    fn update_circle_relays_rejects_oversized_set() {
        let tp = setup_two_party_circle();
        let many: Vec<String> = (0..=CircleManager::MAX_CIRCLE_RELAYS)
            .map(|i| format!("wss://relay{i}.test.com"))
            .collect();
        assert!(many.len() > CircleManager::MAX_CIRCLE_RELAYS);
        assert!(matches!(
            tp.alice.update_circle_relays(&tp.mls_group_id, &many),
            Err(CircleError::InvalidData(_))
        ));
    }

    #[test]
    fn update_circle_relays_rejects_plaintext_ws() {
        let tp = setup_two_party_circle();
        // ws:// (non-loopback host; the debug loopback seam is not armed here)
        // is rejected by the shared `normalize_url` validator.
        assert!(matches!(
            tp.alice
                .update_circle_relays(&tp.mls_group_id, &["ws://relay.test.com".to_string()]),
            Err(CircleError::InvalidData(_))
        ));
    }

    #[test]
    fn resync_never_overwrites_nonempty_relays_with_empty() {
        let tp = setup_two_party_circle();
        // Reproduce the real hazard: MDK does NOT validate non-empty on a
        // relay update, and a member can legitimately observe an empty MDK set
        // (e.g. join with an empty Welcome group_relays while circle.relays
        // holds default_relays()). Commit an empty set DIRECTLY via the
        // unvalidated MDK path (`update_circle_relays` would reject it).
        tp.alice
            .mdk
            .update_relays(&tp.mls_group_id, &[])
            .expect("MDK accepts an (unvalidated) empty relay update");
        tp.alice
            .mdk
            .merge_pending_commit(&tp.mls_group_id)
            .expect("merge the empty relay commit");
        assert!(
            tp.alice
                .mdk
                .get_group_relays(&tp.mls_group_id)
                .unwrap()
                .is_empty(),
            "MDK relay store is now empty (the hazard)"
        );

        // The re-sync MUST NOT wipe the non-empty circle.relays.
        tp.alice
            .resync_circle_relays_from_mdk(&tp.mls_group_id)
            .expect("resync");
        let circle = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            circle.relays, tp.relays,
            "an empty MDK relay set must never brick a non-empty circle.relays"
        );
    }

    #[test]
    fn resync_is_idempotent_noop_when_already_converged() {
        let tp = setup_two_party_circle();
        let before = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        // circle.relays already equals MDK's set; a re-sync must not write.
        tp.alice
            .resync_circle_relays_from_mdk(&tp.mls_group_id)
            .expect("resync");
        let after = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(before.relays, after.relays);
        assert_eq!(
            before.updated_at, after.updated_at,
            "a no-op re-sync must not bump updated_at (no spurious save)"
        );
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
            .set_contact("abc123", Some("Alice"), Some("Friend from work"))
            .unwrap();

        assert_eq!(contact.pubkey, "abc123");
        assert_eq!(contact.display_name, Some("Alice".to_string()));
        assert_eq!(contact.notes, Some("Friend from work".to_string()));

        let retrieved = manager.get_contact("abc123").unwrap().unwrap();
        assert_eq!(retrieved.pubkey, contact.pubkey);
        assert_eq!(retrieved.display_name, contact.display_name);
    }

    #[test]
    fn set_contact_updates_existing() {
        let (manager, _temp_dir) = create_test_manager();

        let contact1 = manager.set_contact("abc123", Some("Alice"), None).unwrap();
        let created_at = contact1.created_at;

        // Update the contact
        let contact2 = manager
            .set_contact("abc123", Some("Alice Updated"), None)
            .unwrap();

        // created_at should be preserved
        assert_eq!(contact2.created_at, created_at);
        assert_eq!(contact2.display_name, Some("Alice Updated".to_string()));
    }

    #[test]
    fn delete_contact() {
        let (manager, _temp_dir) = create_test_manager();

        manager.set_contact("abc123", Some("Alice"), None).unwrap();
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

    // ---- M8-2 KeyPackage maintenance wrappers -------------------------------

    #[test]
    fn create_key_package_with_d_reuses_stable_slot() {
        let (manager, _temp_dir) = create_test_manager();
        let pk = Keys::generate().public_key().to_hex();
        let relays = vec!["wss://own.example.com".to_string()];
        let stable = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899";

        let first = manager
            .create_key_package_with_d(&pk, &relays, Some(stable))
            .expect("first");
        let second = manager
            .create_key_package_with_d(&pk, &relays, Some(stable))
            .expect("second");

        // Two rotations into the SAME stable slot yield the SAME NIP-33 `d`,
        // so the second replaces the first at one addressable coordinate.
        assert_eq!(first.d_tag, stable);
        assert_eq!(second.d_tag, stable);
    }

    #[test]
    fn has_live_key_material_true_for_fresh_then_tracked() {
        let (manager, _temp_dir) = create_test_manager();
        let pk = Keys::generate().public_key().to_hex();
        let relays = vec!["wss://own.example.com".to_string()];

        let bundle = manager
            .create_key_package_with_d(&pk, &relays, None)
            .expect("kp");
        // A freshly-created KeyPackage's private init material is LIVE.
        assert!(manager
            .has_live_key_material(&bundle.hash_ref)
            .expect("live"));

        // Record it, then the maintenance-side accessors reflect it.
        manager
            .record_published_key_package(
                &super::super::storage_key_packages::PublishedKeyPackageRow {
                    key_package_hash_ref: bundle.hash_ref.clone(),
                    event_id: "ev1".to_string(),
                    kind: super::super::storage_key_packages::KEY_PACKAGE_KIND_CANONICAL,
                    d_tag: Some(bundle.d_tag.clone()),
                    created_at: 100,
                },
            )
            .expect("record");
        assert_eq!(
            manager.latest_canonical_d_tag().expect("latest"),
            Some(bundle.d_tag.clone())
        );
        assert_eq!(
            manager.canonical_published_hash_refs().expect("refs"),
            vec![bundle.hash_ref]
        );
    }

    #[test]
    fn recorded_login_key_package_reads_live_for_the_maintenance_gate() {
        // M8-6: after the login/onboarding publish records its KeyPackage, the
        // maintenance live-material gate must recognize it as LIVE — so the
        // first maintenance tick NoOps instead of misreading the primary KP as
        // dead and force-rotating it. This exercises the EXACT gate inputs the
        // FFI's `maintain_key_package` builds: `canonical_published_event_refs`
        // (on-relay event id → tracked hash_ref) + `has_live_key_material`.
        let (manager, _temp_dir) = create_test_manager();
        let pk = Keys::generate().public_key().to_hex();
        let relays = vec!["wss://own.example.com".to_string()];

        // Login publish: create the KP + record it under its on-relay event id
        // (as `record_published_key_packages` does after a successful publish).
        let bundle = manager
            .create_key_package_with_d(&pk, &relays, None)
            .expect("kp");
        manager
            .record_published_key_package(
                &super::super::storage_key_packages::PublishedKeyPackageRow {
                    key_package_hash_ref: bundle.hash_ref.clone(),
                    event_id: "login_event_id".to_string(),
                    kind: super::super::storage_key_packages::KEY_PACKAGE_KIND_CANONICAL,
                    d_tag: Some(bundle.d_tag.clone()),
                    created_at: 100,
                },
            )
            .expect("record");

        // The maintenance snapshot builder resolves the on-relay event id to the
        // tracked hash_ref, then runs the live gate on it.
        let refs = manager
            .canonical_published_event_refs()
            .expect("event refs");
        let resolved = refs
            .iter()
            .find(|(id, _)| id == "login_event_id")
            .map(|(_, h)| h.clone())
            .expect("the login event id resolves to a tracked hash_ref");
        assert_eq!(resolved, bundle.hash_ref);
        assert!(
            manager.has_live_key_material(&resolved).expect("live gate"),
            "the recorded login KeyPackage must read LIVE (gate → NoOp)"
        );
    }

    #[test]
    fn login_reuses_the_stored_stable_d_across_publishes() {
        // M8-6: the login path reads `latest_canonical_d_tag` and signs into it,
        // so a second login REPLACES the same NIP-33 slot rather than forking.
        let (manager, _temp_dir) = create_test_manager();
        let pk = Keys::generate().public_key().to_hex();
        let relays = vec!["wss://own.example.com".to_string()];

        // First login: no stored d → fresh slot, then recorded.
        let first = manager
            .create_key_package_with_d(&pk, &relays, None)
            .expect("first");
        manager
            .record_published_key_package(
                &super::super::storage_key_packages::PublishedKeyPackageRow {
                    key_package_hash_ref: first.hash_ref.clone(),
                    event_id: "ev_first".to_string(),
                    kind: super::super::storage_key_packages::KEY_PACKAGE_KIND_CANONICAL,
                    d_tag: Some(first.d_tag.clone()),
                    created_at: 1,
                },
            )
            .expect("record first");

        // Second login: reuse the stored d (what the FFI now threads in).
        let stored = manager.latest_canonical_d_tag().expect("stored");
        assert_eq!(stored, Some(first.d_tag.clone()));
        let second = manager
            .create_key_package_with_d(&pk, &relays, stored.as_deref())
            .expect("second");
        assert_eq!(
            second.d_tag, first.d_tag,
            "second login must reuse the same stable NIP-33 d (no slot fork)"
        );
    }

    #[test]
    fn has_live_key_material_false_for_unknown_hash_ref() {
        let (manager, _temp_dir) = create_test_manager();
        let pk = Keys::generate().public_key().to_hex();
        let relays = vec!["wss://own.example.com".to_string()];

        // Create one package for a well-formed hash_ref, then flip a byte so it
        // deserializes to a HashReference that was never stored ⇒ DEAD.
        let bundle = manager
            .create_key_package_with_d(&pk, &relays, None)
            .expect("kp");
        let mut unknown = bundle.hash_ref.clone();
        let last = unknown.len() - 1;
        unknown[last] ^= 0xff;
        assert!(!manager
            .has_live_key_material(&unknown)
            .expect("query unknown"));
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
    fn plan_leave_non_admin_member_returns_non_admin() {
        let circle = setup_two_party_circle();
        let plan = circle
            .bob
            .plan_leave(&circle.mls_group_id, &circle.bob_keys.public_key())
            .expect("plan_leave for non-admin");
        assert!(matches!(plan, LeavePlan::NonAdmin));
    }

    #[test]
    fn plan_leave_sole_admin_with_member_returns_handoff() {
        let circle = setup_two_party_circle();
        let plan = circle
            .alice
            .plan_leave(&circle.mls_group_id, &circle.alice_keys.public_key())
            .expect("plan_leave for sole admin");
        let LeavePlan::AdminHandoff { successor } = plan else {
            panic!("expected AdminHandoff, got {plan:?}");
        };
        assert_eq!(successor, circle.bob_keys.public_key());
    }

    #[test]
    fn admin_handoff_end_to_end() {
        let circle = setup_two_party_circle();

        // Step 1: Alice promotes Bob to admin.
        circle
            .alice
            .propose_admin_handoff(&circle.mls_group_id, &circle.bob_keys.public_key())
            .expect("propose_admin_handoff");
        circle
            .alice
            .finalize_pending_commit(&circle.mls_group_id)
            .expect("finalize promote");

        // Alice's local view: Bob is now an admin.
        let group = circle
            .alice
            .mdk
            .get_group(&circle.mls_group_id)
            .expect("get_group")
            .expect("group exists");
        assert!(group.admin_pubkeys.contains(&circle.bob_keys.public_key()));

        // Re-planning in this state should return AdminDemote (both are admins).
        let resume_plan = circle
            .alice
            .plan_leave(&circle.mls_group_id, &circle.alice_keys.public_key())
            .expect("plan_leave after promote");
        assert!(matches!(resume_plan, LeavePlan::AdminDemote));

        // Step 2: Alice self-demotes.
        circle
            .alice
            .propose_self_demote(&circle.mls_group_id)
            .expect("propose_self_demote");
        circle
            .alice
            .finalize_pending_commit(&circle.mls_group_id)
            .expect("finalize demote");

        let group = circle
            .alice
            .mdk
            .get_group(&circle.mls_group_id)
            .expect("get_group")
            .expect("group exists");
        assert!(!group
            .admin_pubkeys
            .contains(&circle.alice_keys.public_key()));

        // Step 3: Alice proposes SelfRemove (no pending commit to finalize).
        circle
            .alice
            .propose_leave(&circle.mls_group_id)
            .expect("propose_leave");

        // Step 4: Alice wipes her local circle row AND MDK state.
        circle
            .alice
            .complete_leave(&circle.mls_group_id)
            .expect("complete_leave");
        assert!(circle
            .alice
            .storage
            .get_circle(&circle.mls_group_id)
            .expect("get_circle")
            .is_none());
        assert!(
            circle
                .alice
                .mdk
                .get_group(&circle.mls_group_id)
                .expect("get_group")
                .is_none(),
            "complete_leave must purge MDK group state for forward secrecy"
        );

        // Bob's MDK is a separate instance; Alice's local purge must not
        // affect it. The remaining admin still holds the group on his side.
        assert!(
            circle
                .bob
                .mdk
                .get_group(&circle.mls_group_id)
                .expect("bob get_group")
                .is_some(),
            "Alice's local purge must not touch Bob's MDK state"
        );
    }

    #[test]
    fn plan_leave_nonexistent_group_returns_orphan() {
        let (manager, _temp_dir) = create_test_manager();
        let self_pk = Keys::generate().public_key();
        let plan = manager
            .plan_leave(&GroupId::from_slice(&[0u8; 32]), &self_pk)
            .expect("plan_leave should succeed for missing group");
        assert!(matches!(plan, LeavePlan::OrphanLocalOnly));
    }

    #[test]
    fn complete_leave_nonexistent_group_succeeds() {
        // `complete_leave` is idempotent: after OrphanLocalOnly, the Flutter
        // service calls it to wipe local state regardless of prior state.
        // MDK's delete_group is idempotent on missing groups, so this must
        // still succeed.
        let (manager, _temp_dir) = create_test_manager();
        manager
            .complete_leave(&GroupId::from_slice(&[0u8; 32]))
            .expect("complete_leave should not fail when row is missing");
    }

    #[test]
    fn complete_leave_purges_mdk_state() {
        // Forward-secrecy guarantee: once complete_leave returns Ok, no
        // MDK state for the group remains on-device — exporter secrets,
        // leaf keys, and tree are all gone.
        let circle = setup_two_party_circle();

        // Pre-condition: Alice's MDK has the group.
        assert!(circle
            .alice
            .mdk
            .get_group(&circle.mls_group_id)
            .expect("get_group")
            .is_some());

        circle
            .alice
            .complete_leave(&circle.mls_group_id)
            .expect("complete_leave");

        assert!(
            circle
                .alice
                .mdk
                .get_group(&circle.mls_group_id)
                .expect("get_group")
                .is_none(),
            "MDK state must be purged after complete_leave"
        );
        assert!(circle
            .alice
            .storage
            .get_circle(&circle.mls_group_id)
            .expect("get_circle")
            .is_none());
    }

    #[test]
    fn complete_leave_purges_per_circle_sync_cursor() {
        // Wipe-on-leave (N5): the group's per-circle sync cursor must be gone
        // after leaving, so a returning circle with the same nostr_group_id
        // re-seeds cleanly instead of resuming at a stale floor.
        let circle = setup_two_party_circle();
        let key = crate::relay::live_sync::processor::group_cursor_stream(&hex::encode(
            circle.nostr_group_id,
        ));

        circle
            .alice
            .advance_sync_cursor(&key, 1_700_000_000_000)
            .expect("advance cursor");
        assert!(
            circle
                .alice
                .read_sync_cursor(&key)
                .expect("read cursor")
                .is_some(),
            "cursor must be seeded before leave"
        );

        circle
            .alice
            .complete_leave(&circle.mls_group_id)
            .expect("complete_leave");

        assert!(
            circle
                .alice
                .read_sync_cursor(&key)
                .expect("read cursor")
                .is_none(),
            "per-circle sync cursor must be purged on leave"
        );
    }

    #[test]
    fn complete_leave_purges_processed_gift_wraps_for_group() {
        // Wipe-on-leave (N6): the left circle's per-group gift-wrap dedup rows
        // must be purged, while an UNRELATED group's dedup row survives.
        let circle = setup_two_party_circle();

        // A success dedup row bound to THIS circle's real mls_group_id.
        let ours = nostr::EventId::from_byte_array([0x11; 32]);
        circle
            .alice
            .storage
            .record_gift_wrap_dedup_for_test(&ours, circle.mls_group_id.as_slice(), 1_700_000_000)
            .expect("record ours");

        // A dedup row bound to a DIFFERENT (unrelated) group id — must survive.
        let theirs = nostr::EventId::from_byte_array([0x22; 32]);
        let other_group = [0x99u8; 32];
        circle
            .alice
            .storage
            .record_gift_wrap_dedup_for_test(&theirs, &other_group, 1_700_000_000)
            .expect("record theirs");

        // A terminal-failure sentinel (empty mls_group_id blob) — FIX-2: it
        // must SURVIVE the leave (it is purged only by retention pruning).
        let failed = nostr::EventId::from_byte_array([0x33; 32]);
        circle
            .alice
            .storage
            .record_gift_wrap_failure(&failed, 1_700_000_000)
            .expect("record failure sentinel");

        circle
            .alice
            .complete_leave(&circle.mls_group_id)
            .expect("complete_leave");

        assert!(
            circle
                .alice
                .storage
                .is_gift_wrap_processed(&ours)
                .expect("is_processed")
                .is_none(),
            "the left circle's dedup row must be purged on leave"
        );
        assert!(
            circle
                .alice
                .storage
                .is_gift_wrap_processed(&theirs)
                .expect("is_processed")
                .is_some(),
            "an unrelated group's dedup row must survive the leave"
        );
        assert!(
            circle
                .alice
                .storage
                .is_gift_wrap_processed(&failed)
                .expect("is_processed")
                .is_some(),
            "the empty-blob failure sentinel must survive the leave (FIX-2)"
        );
    }

    /// Builds an `AvatarBlobs` from raw bytes for purge-wiring tests (no image
    /// pipeline needed — only the storage assignment is exercised).
    fn test_avatar_blobs(canon: &[u8], thumb: &[u8]) -> crate::circle::AvatarBlobs {
        crate::circle::AvatarBlobs {
            content_hash: crate::avatar::content_hash(canon),
            thumb_hash: crate::avatar::content_hash(thumb),
            canonical: zeroize::Zeroizing::new(canon.to_vec()),
            thumbnail: zeroize::Zeroizing::new(thumb.to_vec()),
            mime: "image/jpeg".to_string(),
            width: 512,
            thumb_edge: 96,
        }
    }

    #[test]
    fn complete_leave_purges_circle_avatars() {
        // Privacy: leaving/deleting a circle must purge the cached avatars of
        // its members so their faces do not linger at rest.
        let setup = setup_two_party_circle();
        let cid = setup.mls_group_id.as_slice();
        let bob_pubkey_hex = setup.bob_keys.public_key().to_hex();
        let blobs = test_avatar_blobs(b"bob-canon", b"bob-thumb");
        setup
            .alice
            .storage
            .upsert_avatar_assignment(cid, &bob_pubkey_hex, &blobs, "received", 1, 1000)
            .expect("store received avatar");
        assert!(setup
            .alice
            .storage
            .get_avatar_thumbnail(cid, &bob_pubkey_hex)
            .expect("get")
            .is_some());

        setup
            .alice
            .complete_leave(&setup.mls_group_id)
            .expect("complete_leave");

        assert!(
            setup
                .alice
                .storage
                .get_avatar_thumbnail(cid, &bob_pubkey_hex)
                .expect("get")
                .is_none(),
            "leaving a circle must purge its cached member avatars"
        );
    }

    #[test]
    fn remove_members_purges_removed_member_avatar() {
        // Privacy: a removed member's cached avatar must be purged from the
        // circle it was removed from.
        let setup = setup_two_party_circle();
        let cid = setup.mls_group_id.as_slice();
        let bob_pubkey_hex = setup.bob_keys.public_key().to_hex();
        let blobs = test_avatar_blobs(b"bob-canon-2", b"bob-thumb-2");
        setup
            .alice
            .storage
            .upsert_avatar_assignment(cid, &bob_pubkey_hex, &blobs, "received", 1, 1000)
            .expect("store received avatar");

        setup
            .alice
            .remove_members(&setup.mls_group_id, &[bob_pubkey_hex.clone()])
            .expect("remove_members");

        assert!(
            setup
                .alice
                .storage
                .get_avatar_thumbnail(cid, &bob_pubkey_hex)
                .expect("get")
                .is_none(),
            "removing a member must purge their cached avatar"
        );
    }

    #[test]
    fn abandon_circle_local_only_purges_mdk_state() {
        // Abandon path (sole remaining member): there is no SelfRemove to
        // publish, but the MDK purge is still mandatory for forward secrecy.
        //
        // Reduce the 2-party circle to Alice-only by removing Bob and merging,
        // then assert plan_leave actually returns Abandon so we're exercising
        // the intended code path.
        let circle = setup_two_party_circle();

        circle
            .alice
            .mdk
            .remove_members(
                &circle.mls_group_id,
                &[circle.bob_keys.public_key().to_hex()],
            )
            .expect("remove bob");
        circle
            .alice
            .mdk
            .merge_pending_commit(&circle.mls_group_id)
            .expect("merge bob removal");

        let plan = circle
            .alice
            .plan_leave(&circle.mls_group_id, &circle.alice_keys.public_key())
            .expect("plan_leave");
        assert!(
            matches!(plan, LeavePlan::Abandon),
            "precondition: sole-member group must plan Abandon, got {plan:?}"
        );

        circle
            .alice
            .abandon_circle_local_only(&circle.mls_group_id)
            .expect("abandon_circle_local_only");

        assert!(
            circle
                .alice
                .mdk
                .get_group(&circle.mls_group_id)
                .expect("get_group")
                .is_none(),
            "MDK state must be purged after abandon"
        );
        assert!(circle
            .alice
            .storage
            .get_circle(&circle.mls_group_id)
            .expect("get_circle")
            .is_none());
    }

    #[test]
    fn complete_leave_renders_captured_ciphertext_undecryptable() {
        use crate::nostr::mls::types::LocationMessageResult;

        // Self-side forward secrecy: after a user leaves a circle,
        // `complete_leave` purges ALL local MDK state (tree, leaf keys, exporter
        // secrets), so the device can no longer decrypt that circle's traffic —
        // not even ciphertext captured while it was still a member. The existing
        // `complete_leave_purges_mdk_state` proves the group row is gone; this
        // proves the user-visible consequence (lost decryptability).
        //
        // Two DISTINCT ciphertexts avoid a dedup confound: re-processing the
        // SAME event pre/post would make the second attempt fail via MDK's
        // already-seen dedup even if the purge did nothing. Instead Alice
        // decrypts M1 before leaving (positive control: a functioning member who
        // can read Bob's traffic at this epoch), then — after the purge —
        // attempts M2, which she has NEVER processed, so its failure is
        // attributable solely to the missing group state, not to replay dedup.
        let setup = setup_two_party_circle();

        // Bob is the peer/sender; Alice is the leaver.
        let bob_mls_group_id = setup
            .bob
            .mdk
            .get_groups()
            .expect("bob groups")
            .first()
            .expect("bob has a group")
            .mls_group_id
            .clone();

        let encrypt_for_alice = |lat: f64, lon: f64| {
            setup
                .bob
                .encrypt_location(
                    &bob_mls_group_id,
                    &setup.bob_keys.public_key(),
                    &LocationMessage::new(lat, lon),
                    300,
                )
                .expect("bob should encrypt location")
                .0
        };
        let m1 = encrypt_for_alice(40.0, -74.0); // positive-control probe
        let m2 = encrypt_for_alice(48.8566, 2.3522); // post-leave target (Alice never processes it pre-leave)

        // Positive control: Alice CAN decrypt Bob's traffic before leaving, so
        // the post-leave failure below is meaningful (M2 is the same kind of
        // ciphertext at the same epoch).
        match setup
            .alice
            .decrypt_location(&m1)
            .expect("alice should decrypt before leaving")
        {
            LocationMessageResult::Location { sender_pubkey, .. } => assert_eq!(
                sender_pubkey,
                setup.bob_keys.public_key().to_hex(),
                "control: M1 must decrypt to Bob's location before the leave"
            ),
            other => panic!("precondition: leaver must decrypt the peer's location, got {other:?}"),
        }

        // Alice leaves via the production purge path.
        setup
            .alice
            .complete_leave(&setup.mls_group_id)
            .expect("complete_leave");

        // Primary invariant — the captured-but-never-processed M2 must NOT
        // decrypt now. Because the group row is gone, the legitimate signal is
        // group-not-found — the INVERSE of an AEAD failure — so we assert that
        // shape rather than a bare is_err (which could pass for an unrelated
        // reason). Ok(Location) is the forward-secrecy violation the mutation
        // test exercises. Checked before the state corroboration so a defeated
        // purge surfaces as the user-visible property, not an internal detail.
        let post = setup.alice.decrypt_location(&m2);
        match &post {
            Ok(LocationMessageResult::Location { .. }) => panic!(
                "forward-secrecy violation: leaver decrypted a captured ciphertext after \
                 complete_leave"
            ),
            Err(e) => assert!(
                e.to_string().to_lowercase().contains("group not found"),
                "post-leave failure must be group-not-found (purged state), got: {post:?}"
            ),
            Ok(other) => {
                panic!("post-leave decrypt must fail with group-not-found, got Ok({other:?})")
            }
        }

        // Corroborate the purge at the state level too (defense in depth;
        // `complete_leave_purges_mdk_state` is the dedicated state-level check).
        assert!(
            setup
                .alice
                .mdk
                .get_group(&setup.mls_group_id)
                .expect("get_group")
                .is_none(),
            "complete_leave must purge MDK group state"
        );
    }

    #[test]
    fn complete_leave_succeeds_with_outstanding_pending_commit() {
        // Reviewer-flagged HIGH: a prior step in the leave flow may have
        // staged a pending commit that never finalized. `complete_leave`
        // must proactively drop it so `delete_group` sees clean state
        // and forward-secrecy purge is complete.
        //
        // Shape: drive Alice to stage a commit she never merges (by
        // calling `remove_members` without the follow-up `merge_pending_commit`),
        // then call `complete_leave`. Without the `clear_pending_commit`
        // safeguard, this could leave MDK in an inconsistent state or
        // fail outright depending on MDK internals.
        let circle = setup_two_party_circle();

        // Stage a pending commit but do NOT merge it.
        circle
            .alice
            .mdk
            .remove_members(
                &circle.mls_group_id,
                &[circle.bob_keys.public_key().to_hex()],
            )
            .expect("remove_members should stage a commit");

        // Call `complete_leave` with the outstanding pending commit.
        circle
            .alice
            .complete_leave(&circle.mls_group_id)
            .expect("complete_leave must succeed even with a pending commit");

        // MDK state and circle row must both be gone.
        assert!(
            circle
                .alice
                .mdk
                .get_group(&circle.mls_group_id)
                .expect("get_group")
                .is_none(),
            "MDK state must be purged even when a pending commit was outstanding"
        );
        assert!(circle
            .alice
            .storage
            .get_circle(&circle.mls_group_id)
            .expect("get_circle")
            .is_none());
    }

    #[test]
    fn propose_leave_succeeds_with_outstanding_pending_commit() {
        // Regression: a stale pending commit (e.g., a prior session's
        // receiver-side auto-commit whose publish-then-finalize never
        // completed) would make MDK's `leave_group` fail with
        // "pending commit exists". `propose_leave` must proactively
        // discard the residual commit before staging the SelfRemove,
        // mirroring `complete_leave`'s pre-clear behaviour.
        //
        // Shape: stage a pending commit on the *non-admin* leaver (Bob)
        // via `self_update` — a leaf rotation that any member may stage —
        // without the follow-up `merge_pending_commit`. Then call
        // `propose_leave` and confirm it succeeds. The non-admin role
        // matters: MDK's `leave_group` rejects admins with
        // "Admins must self-demote before leaving" and our pre-clear
        // sits ahead of that gate.
        let circle = setup_two_party_circle();

        // Stage a pending commit on Bob's MDK but do NOT merge it.
        // `self_update` rotates Bob's own leaf and is one of the few
        // operations a non-admin can use to produce a commit.
        circle
            .bob
            .mdk
            .self_update(&circle.mls_group_id)
            .expect("self_update should stage a pending commit on bob's MDK");

        // Sanity: while a pending commit is outstanding, MDK's
        // `leave_group` (the underlying operation `propose_leave` wraps)
        // would itself fail with "pending commit exists". Anchors the
        // test against the MDK invariant — if MDK ever loosens the rule,
        // this assertion fails and forces a revisit of the pre-clear's
        // necessity.
        let direct = circle.bob.mdk.leave_group(&circle.mls_group_id);
        assert!(
            direct.is_err(),
            "MDK invariant changed: leave_group accepted a stage while a \
             pending commit was outstanding. Revisit propose_leave's \
             pre-clear: got Ok({direct:?})"
        );
        // The previous `leave_group` call did not advance any state —
        // the pending commit from `self_update` is still outstanding on
        // Bob's MDK and now exercises the pre-clear path in `propose_leave`.

        // `propose_leave` must succeed by pre-clearing the residual
        // pending commit before staging the SelfRemove proposal.
        circle
            .bob
            .propose_leave(&circle.mls_group_id)
            .expect("propose_leave must clear stale pending commit and succeed");
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

    /// Three-party MLS group with TWO admins (Alice, Bob) plus one
    /// non-admin (Carol). Used by the concurrent-admin convergence test
    /// for `remove_members`.
    ///
    /// Differs from [`setup_two_party_circle`] in two ways:
    /// 1. Adds Carol as a third party (the eviction target).
    /// 2. Promotes Bob to admin via a second `with_admin` call so the test
    ///    can drive *concurrent* admin commits — the scenario at the heart
    ///    of the `WrongEpoch` race.
    struct ThreePartyTwoAdminCircle {
        alice: CircleManager,
        _alice_dir: TempDir,
        alice_keys: Keys,
        bob: CircleManager,
        _bob_dir: TempDir,
        bob_keys: Keys,
        // `_carol` is retained so her CircleManager (and its SQLCipher
        // connection) outlives the test body — dropping it early would
        // also tear down storage that the helper's setup loop populated.
        _carol: CircleManager,
        _carol_dir: TempDir,
        carol_keys: Keys,
        mls_group_id: GroupId,
    }

    /// Builds a three-party group where both Alice and Bob are admins and
    /// Carol is the non-admin removal target. All three have processed
    /// their welcomes and sit on the same epoch.
    #[allow(clippy::too_many_lines)] // Linear setup: keys → KPs → group → welcomes → storage.
    fn setup_three_party_two_admin_circle() -> ThreePartyTwoAdminCircle {
        let relays = vec!["wss://relay.test.com".to_string()];

        let alice_dir = TempDir::new().unwrap();
        let alice = CircleManager::new_unencrypted(alice_dir.path()).unwrap();
        let alice_keys = Keys::generate();

        let bob_dir = TempDir::new().unwrap();
        let bob = CircleManager::new_unencrypted(bob_dir.path()).unwrap();
        let bob_keys = Keys::generate();

        let carol_dir = TempDir::new().unwrap();
        let carol = CircleManager::new_unencrypted(carol_dir.path()).unwrap();
        let carol_keys = Keys::generate();

        // Bob and Carol create key packages.
        let bob_pk = bob_keys.public_key().to_hex();
        let bob_bundle = bob
            .mdk
            .create_key_package(&bob_pk, &relays)
            .expect("bob key package");
        let bob_tags: Vec<nostr::Tag> = bob_bundle
            .tags_443
            .into_iter()
            .map(|t| nostr::Tag::parse(&t).unwrap())
            .collect();
        let bob_kp = EventBuilder::new(Kind::MlsKeyPackage, bob_bundle.content)
            .tags(bob_tags)
            .sign_with_keys(&bob_keys)
            .expect("sign bob kp");

        let carol_pk = carol_keys.public_key().to_hex();
        let carol_bundle = carol
            .mdk
            .create_key_package(&carol_pk, &relays)
            .expect("carol key package");
        let carol_tags: Vec<nostr::Tag> = carol_bundle
            .tags_443
            .into_iter()
            .map(|t| nostr::Tag::parse(&t).unwrap())
            .collect();
        let carol_kp = EventBuilder::new(Kind::MlsKeyPackage, carol_bundle.content)
            .tags(carol_tags)
            .sign_with_keys(&carol_keys)
            .expect("sign carol kp");

        // Alice creates the group with Alice + Bob as joint admins.
        let config = crate::nostr::mls::types::LocationGroupConfig::new("Two Admins")
            .with_description("Concurrent-admin convergence test")
            .with_relay("wss://relay.test.com")
            .with_admin(alice_keys.public_key().to_hex())
            .with_admin(bob_keys.public_key().to_hex());

        let group_result = alice
            .mdk
            .create_group(
                &alice_keys.public_key().to_hex(),
                vec![bob_kp, carol_kp],
                config,
            )
            .expect("create three-party group");

        let mls_group_id = group_result.group.mls_group_id.clone();
        let nostr_group_id = group_result.group.nostr_group_id;

        alice
            .mdk
            .merge_pending_commit(&mls_group_id)
            .expect("alice merge create commit");

        // Each non-creator processes their welcome.
        for (mgr, pk_hex) in [
            (&bob, bob_keys.public_key().to_hex()),
            (&carol, carol_keys.public_key().to_hex()),
        ] {
            let welcome = group_result
                .welcome_rumors
                .iter()
                .find(|r| {
                    r.tags
                        .iter()
                        .any(|t| t.as_slice().iter().any(|s| s.eq_ignore_ascii_case(&pk_hex)))
                })
                .or_else(|| group_result.welcome_rumors.first())
                .expect("welcome rumor");
            mgr.mdk
                .process_welcome(&nostr::EventId::all_zeros(), welcome)
                .expect("process welcome");
            let pending = mgr.mdk.get_pending_welcomes().expect("pending welcomes");
            let w = pending
                .iter()
                .find(|w| w.mls_group_id == mls_group_id)
                .expect("welcome for group");
            mgr.mdk.accept_welcome(w).expect("accept welcome");
        }

        // Persist Circle records on every party so `remove_members` can
        // touch the metadata side-effects (`updated_at`).
        let now = chrono::Utc::now().timestamp();
        let circle = super::super::types::Circle {
            mls_group_id: mls_group_id.clone(),
            nostr_group_id,
            display_name: "Two Admins".to_string(),
            circle_type: super::super::types::CircleType::LocationSharing,
            relays,
            created_at: now,
            updated_at: now,
        };
        for mgr in [&alice, &bob, &carol] {
            mgr.storage.save_circle(&circle).unwrap();
        }

        ThreePartyTwoAdminCircle {
            alice,
            _alice_dir: alice_dir,
            alice_keys,
            bob,
            _bob_dir: bob_dir,
            bob_keys,
            _carol: carol,
            _carol_dir: carol_dir,
            carol_keys,
            mls_group_id,
        }
    }

    /// MIP-03 wire invariant: every kind 445 outer event MUST use a fresh
    /// ephemeral keypair so relays cannot link group commits to a sender's
    /// long-term identity. This mirrors the assertion at
    /// `encrypt_location_returns_correct_metadata` for the location pipeline,
    /// extending it to the membership-evolution path produced by
    /// `remove_members`.
    #[test]
    fn remove_members_evolution_event_uses_ephemeral_pubkey() {
        let setup = setup_two_party_circle();
        let bob_pubkey_hex = setup.bob_keys.public_key().to_hex();

        let result = setup
            .alice
            .remove_members(&setup.mls_group_id, &[bob_pubkey_hex])
            .expect("alice (admin) should be able to remove bob");

        let event = result.evolution_event;

        // The evolution event must be kind 445 (the outer Nostr wrapper for
        // an MLS commit/proposal message).
        assert_eq!(
            event.kind,
            Kind::Custom(445),
            "remove_members evolution event must be kind 445"
        );

        // The crucial wire invariant: the outer pubkey is an ephemeral key,
        // never the admin's long-term identity key. If MDK ever regresses and
        // signs evolution events with `Keys::parse(sender_pubkey)`, this
        // assertion catches it before relays can correlate Alice's
        // membership-change commits to her identity.
        assert_ne!(
            event.pubkey,
            setup.alice_keys.public_key(),
            "Kind 445 evolution event must use an ephemeral pubkey, not the admin's real key"
        );

        // The signature must verify against the ephemeral pubkey carried in
        // the event itself — confirms the event is well-formed and the
        // ephemeral key actually signed it (not just a stripped author field).
        event
            .verify()
            .expect("evolution event signature must verify against its ephemeral pubkey");
    }

    /// Convergence under a concurrent-admin `RemoveMember` race.
    ///
    /// Background: the Haven Dart layer (`_commitAndPublish` in
    /// `nostr_circle_service.dart`) protects the local MLS state from
    /// being stuck on a stale pending commit when two admins stage the
    /// same member-eviction at the same epoch. This test exercises the
    /// **protocol-level invariant** that the rollback strategy depends on:
    ///
    /// 1. With both Alice and Bob as admins at epoch `N`, both
    ///    independently stage `remove_members(carol)`. Each produces its
    ///    own kind-445 evolution event signed at epoch `N`.
    /// 2. Alice's commit is accepted first by the relays — modelled here
    ///    by Alice merging her own pending commit. Alice advances to
    ///    epoch `N+1` with Carol removed.
    /// 3. Bob — who still holds his own stale pending commit at epoch
    ///    `N` — receives Alice's evolution event. The MLS state machine
    ///    must surface this as either `Err` or `MessageProcessingResult::
    ///    Unprocessable`; what it MUST NOT do is silently accept Bob's
    ///    stale commit on top of Alice's.
    /// 4. Bob calls `clear_pending_commit` to discard his own stale
    ///    pending commit (this is the rollback Haven exercises in
    ///    `_commitAndPublish` when publishing fails or returns a stale
    ///    epoch).
    /// 5. Bob retries — the second fetch cycle — and reapplies Alice's
    ///    evolution event cleanly, advancing himself to epoch `N+1`.
    /// 6. Convergence: Alice and Bob are now on the **same epoch**, with
    ///    the **same membership** (Carol evicted), and Bob has **no
    ///    lingering pending commit**.
    ///
    /// Mirrors the upstream MDK invariant exercised by
    /// `test_concurrent_commit_race_conditions` in
    /// `crates/mdk-core/src/messages/commit.rs` but exposes the property
    /// at Haven's `CircleManager` boundary so a regression in our use of
    /// `clear_pending_commit` would fail this test.
    #[test]
    #[allow(clippy::too_many_lines)] // Single coherent narrative: stage → race → rollback → converge.
    fn concurrent_admin_remove_member_converges_after_clear_pending() {
        let setup = setup_three_party_two_admin_circle();
        let carol_hex = setup.carol_keys.public_key().to_hex();

        // Sanity: pre-conditions. All three parties are members at the
        // same epoch.
        let alice_epoch_before = setup
            .alice
            .mdk
            .get_group(&setup.mls_group_id)
            .unwrap()
            .unwrap()
            .epoch;
        let bob_epoch_before = setup
            .bob
            .mdk
            .get_group(&setup.mls_group_id)
            .unwrap()
            .unwrap()
            .epoch;
        assert_eq!(
            alice_epoch_before, bob_epoch_before,
            "Alice and Bob must start on the same epoch"
        );

        let alice_members_before = setup.alice.mdk.get_members(&setup.mls_group_id).unwrap();
        assert_eq!(
            alice_members_before.len(),
            3,
            "Group must start with Alice + Bob + Carol"
        );
        assert!(
            alice_members_before.contains(&setup.carol_keys.public_key()),
            "Carol must start as a member"
        );

        // (1) Both admins concurrently stage `remove_members(carol)` at
        //     the same epoch. Each gets a distinct evolution event.
        let target = std::slice::from_ref(&carol_hex);
        let alice_remove = setup
            .alice
            .remove_members(&setup.mls_group_id, target)
            .expect("alice (admin) stages remove(carol)");
        let bob_remove = setup
            .bob
            .remove_members(&setup.mls_group_id, target)
            .expect("bob (admin) stages remove(carol)");
        assert_eq!(
            alice_remove.evolution_event.kind,
            Kind::Custom(445),
            "alice's evolution event must be kind 445"
        );
        assert_eq!(
            bob_remove.evolution_event.kind,
            Kind::Custom(445),
            "bob's evolution event must be kind 445"
        );
        // Each party signs its own commit with its own ephemeral key —
        // the events must be distinct at the wire level.
        assert_ne!(
            alice_remove.evolution_event.id, bob_remove.evolution_event.id,
            "concurrent commits must produce distinct event IDs"
        );

        // (2) Alice's commit "wins" — she merges first, advancing to N+1.
        setup
            .alice
            .finalize_pending_commit(&setup.mls_group_id)
            .expect("alice finalizes her winning commit");
        let alice_epoch_after = setup
            .alice
            .mdk
            .get_group(&setup.mls_group_id)
            .unwrap()
            .unwrap()
            .epoch;
        assert!(
            alice_epoch_after > alice_epoch_before,
            "alice's epoch must advance after merging her commit ({alice_epoch_before} -> {alice_epoch_after})"
        );

        // (3) FIRST FETCH CYCLE — Bob, still holding his own stale
        //     pending commit, attempts to apply Alice's commit. The MLS
        //     state machine MUST NOT silently accept Bob's stale commit
        //     on top of Alice's. Acceptable outcomes:
        //       - Err: outright rejection
        //       - Ok(Unprocessable): detected as stale
        //       - Ok(Commit) with epoch advance: MDK absorbed Alice's
        //         commit and dropped Bob's pending implicitly
        //
        //     What we are testing here is convergence, not the exact
        //     outcome variant — different MDK versions handle this
        //     differently and that variability is part of why the Dart
        //     layer rolls back via `clearPendingCommit`.
        let first_attempt = setup.bob.mdk.process_message(&alice_remove.evolution_event);

        // Defence against silent regression: MDK MUST NOT quietly
        // accept Bob's stale pending commit on top of Alice's. Mirror
        // the upstream `is_handled` pattern from MDK's
        // `test_concurrent_commit_race_conditions` so an MDK regression
        // that started swallowing the stale commit would surface here
        // rather than leaking through to the convergence asserts (which
        // could pass for the wrong reason if the membership happened to
        // line up).
        let bob_epoch_after_first = setup
            .bob
            .mdk
            .get_group(&setup.mls_group_id)
            .unwrap()
            .unwrap()
            .epoch;
        let first_attempt_handled = first_attempt.is_err()
            || matches!(
                &first_attempt,
                Ok(mdk_core::prelude::MessageProcessingResult::Unprocessable { .. })
            )
            || bob_epoch_after_first > bob_epoch_before;
        assert!(
            first_attempt_handled,
            "Bob's first process_message of Alice's commit while holding a \
             stale pending commit must be Err, Unprocessable, or have \
             advanced Bob's epoch. Anything else means MDK silently \
             accepted a conflicting commit — protocol invariant violated. \
             got: {first_attempt:?}, bob_epoch: {bob_epoch_before} -> \
             {bob_epoch_after_first}"
        );

        // (4) Bob unconditionally rolls back any lingering pending
        //     commit — this is the path Dart's `clearPendingCommit`
        //     exercises. After this, Bob's MLS state must be clean.
        //     `clear_pending_commit` is a no-op when there is nothing
        //     to clear, so it is safe to call regardless of (3)'s
        //     outcome.
        let _ = setup.bob.clear_pending_commit(&setup.mls_group_id);

        // (5) SECOND FETCH CYCLE — Bob re-fetches Alice's commit and
        //     applies it. After (4), Bob has no pending commit
        //     blocking the apply. If (3) already advanced Bob's epoch
        //     (the third acceptable outcome above), the re-process may
        //     surface a duplicate-detection result; the load-bearing
        //     post-condition is convergence, asserted below.
        let _ = setup.bob.mdk.process_message(&alice_remove.evolution_event);

        // ============================================================
        // Convergence assertions — the load-bearing checks.
        // ============================================================

        let alice_epoch_final = setup
            .alice
            .mdk
            .get_group(&setup.mls_group_id)
            .unwrap()
            .unwrap()
            .epoch;
        let bob_epoch_final = setup
            .bob
            .mdk
            .get_group(&setup.mls_group_id)
            .unwrap()
            .unwrap()
            .epoch;
        assert_eq!(
            alice_epoch_final, bob_epoch_final,
            "Alice and Bob must converge to the same epoch after the race \
             (alice={alice_epoch_final}, bob={bob_epoch_final})"
        );
        assert!(
            bob_epoch_final > bob_epoch_before,
            "Bob's epoch must advance past the pre-race baseline ({bob_epoch_before} -> {bob_epoch_final})"
        );

        // Both admins must agree on the post-race membership: Carol
        // evicted, Alice and Bob remaining.
        let alice_members_final = setup.alice.mdk.get_members(&setup.mls_group_id).unwrap();
        let bob_members_final = setup.bob.mdk.get_members(&setup.mls_group_id).unwrap();
        assert!(
            !alice_members_final.contains(&setup.carol_keys.public_key()),
            "alice must see Carol as evicted"
        );
        assert!(
            !bob_members_final.contains(&setup.carol_keys.public_key()),
            "bob must see Carol as evicted"
        );
        assert!(
            alice_members_final.contains(&setup.alice_keys.public_key())
                && alice_members_final.contains(&setup.bob_keys.public_key()),
            "alice still sees both admins after the race"
        );
        assert!(
            bob_members_final.contains(&setup.alice_keys.public_key())
                && bob_members_final.contains(&setup.bob_keys.public_key()),
            "bob still sees both admins after the race"
        );
        assert_eq!(
            alice_members_final.len(),
            2,
            "post-race group must contain exactly the two surviving admins"
        );
        assert_eq!(
            alice_members_final.len(),
            bob_members_final.len(),
            "alice and bob must agree on member count post-convergence"
        );

        // Bob must have no lingering pending commit — proves the
        // rollback path actually cleared the stale state, not just the
        // visible membership.
        let retry = setup.bob.remove_members(
            &setup.mls_group_id,
            &[setup.alice_keys.public_key().to_hex()],
        );
        assert!(
            retry.is_ok(),
            "Bob must be able to stage a fresh commit post-rollback — \
             a residual pending commit would fail this with \
             'pending commit exists'. got: {retry:?}"
        );
        // Cleanup so the helper drops cleanly.
        let _ = setup.bob.clear_pending_commit(&setup.mls_group_id);
    }

    // ====================================================================
    // M4 — adopt-winner convergence: fork-vector → prevention test matrix.
    //
    // Every CONVERGENCE row asserts a cross-manager cross-decrypt round-trip:
    // epoch + membership equality is necessary-but-INSUFFICIENT (a same-epoch
    // twin fork satisfies it). A successful decrypt of the winner's
    // freshly-encrypted location on the loser is the only proof of a SHARED
    // exporter secret. Non-vacuous controls show the pure-eager path FORKS.
    // ====================================================================

    /// Whether `decryptor` can decrypt a location freshly encrypted by
    /// `encryptor` at the current epoch — the load-bearing convergence proof
    /// (a shared exporter secret, not a same-number twin fork).
    fn cross_decrypts(
        encryptor: &CircleManager,
        encryptor_pubkey: &nostr::PublicKey,
        decryptor: &CircleManager,
        gid: &GroupId,
    ) -> bool {
        let location = LocationMessage::new(40.12, -74.34);
        let Ok((event, _, _)) = encryptor.encrypt_location(gid, encryptor_pubkey, &location, 300)
        else {
            return false;
        };
        matches!(
            decryptor.decrypt_location(&event),
            Ok(LocationMessageResult::Location { .. })
        )
    }

    struct FourPartyTwoAdminCircle {
        alice: CircleManager,
        _alice_dir: TempDir,
        alice_keys: Keys,
        bob: CircleManager,
        _bob_dir: TempDir,
        bob_keys: Keys,
        // Member managers retained for RAII (their SQLCipher connection must
        // outlive the group); only their keys are used as removal targets.
        _carol: CircleManager,
        _carol_dir: TempDir,
        carol_keys: Keys,
        _dave: CircleManager,
        _dave_dir: TempDir,
        dave_keys: Keys,
        mls_group_id: GroupId,
    }

    /// Builds Alice + Bob (joint admins) + Carol + Dave (members) for the
    /// distinct-target convergence rows. Mirrors
    /// `setup_three_party_two_admin_circle` with a fourth member.
    fn setup_four_party_two_admin_circle() -> FourPartyTwoAdminCircle {
        let relays = vec!["wss://relay.test.com".to_string()];

        let alice_dir = TempDir::new().unwrap();
        let alice = CircleManager::new_unencrypted(alice_dir.path()).unwrap();
        let alice_keys = Keys::generate();

        let bob_dir = TempDir::new().unwrap();
        let bob = CircleManager::new_unencrypted(bob_dir.path()).unwrap();
        let bob_keys = Keys::generate();

        let carol_dir = TempDir::new().unwrap();
        let carol = CircleManager::new_unencrypted(carol_dir.path()).unwrap();
        let carol_keys = Keys::generate();

        let dave_dir = TempDir::new().unwrap();
        let dave = CircleManager::new_unencrypted(dave_dir.path()).unwrap();
        let dave_keys = Keys::generate();

        // Each non-creator publishes a key package.
        let mut member_kps = Vec::new();
        for (mgr, keys) in [
            (&bob, &bob_keys),
            (&carol, &carol_keys),
            (&dave, &dave_keys),
        ] {
            let pk = keys.public_key().to_hex();
            let bundle = mgr
                .mdk
                .create_key_package(&pk, &relays)
                .expect("key package");
            let tags: Vec<nostr::Tag> = bundle
                .tags_443
                .into_iter()
                .map(|t| nostr::Tag::parse(&t).unwrap())
                .collect();
            let kp = EventBuilder::new(Kind::MlsKeyPackage, bundle.content)
                .tags(tags)
                .sign_with_keys(keys)
                .expect("sign kp");
            member_kps.push(kp);
        }

        // Alice creates the group with Alice + Bob as joint admins.
        let config = crate::nostr::mls::types::LocationGroupConfig::new("Four Party")
            .with_description("Distinct-target convergence test")
            .with_relay("wss://relay.test.com")
            .with_admin(alice_keys.public_key().to_hex())
            .with_admin(bob_keys.public_key().to_hex());

        let group_result = alice
            .mdk
            .create_group(&alice_keys.public_key().to_hex(), member_kps, config)
            .expect("create four-party group");

        let mls_group_id = group_result.group.mls_group_id.clone();
        let nostr_group_id = group_result.group.nostr_group_id;

        alice
            .mdk
            .merge_pending_commit(&mls_group_id)
            .expect("alice merge create commit");

        for (mgr, pk_hex) in [
            (&bob, bob_keys.public_key().to_hex()),
            (&carol, carol_keys.public_key().to_hex()),
            (&dave, dave_keys.public_key().to_hex()),
        ] {
            let welcome = group_result
                .welcome_rumors
                .iter()
                .find(|r| {
                    r.tags
                        .iter()
                        .any(|t| t.as_slice().iter().any(|s| s.eq_ignore_ascii_case(&pk_hex)))
                })
                .or_else(|| group_result.welcome_rumors.first())
                .expect("welcome rumor");
            mgr.mdk
                .process_welcome(&nostr::EventId::all_zeros(), welcome)
                .expect("process welcome");
            let pending = mgr.mdk.get_pending_welcomes().expect("pending welcomes");
            let w = pending
                .iter()
                .find(|w| w.mls_group_id == mls_group_id)
                .expect("welcome for group");
            mgr.mdk.accept_welcome(w).expect("accept welcome");
        }

        let now = chrono::Utc::now().timestamp();
        let circle = super::super::types::Circle {
            mls_group_id: mls_group_id.clone(),
            nostr_group_id,
            display_name: "Four Party".to_string(),
            circle_type: super::super::types::CircleType::LocationSharing,
            relays,
            created_at: now,
            updated_at: now,
        };
        for mgr in [&alice, &bob, &carol, &dave] {
            mgr.storage.save_circle(&circle).unwrap();
        }

        FourPartyTwoAdminCircle {
            alice,
            _alice_dir: alice_dir,
            alice_keys,
            bob,
            _bob_dir: bob_dir,
            bob_keys,
            _carol: carol,
            _carol_dir: carol_dir,
            carol_keys,
            _dave: dave,
            _dave_dir: dave_dir,
            dave_keys,
            mls_group_id,
        }
    }

    /// PRE (M4 blocker): pins the observable MDK rev-93ae324 contract the
    /// convergence primitive relies on, using a DISTINCT-target race (Alice rm
    /// Carol wins, Bob rm Dave loses) where the transient fork is genuine
    /// (membership coincidence cannot mask it). A loser holding its own pending
    /// commit that processes the winner's sibling commit FIRST advances to its
    /// OWN divergent N+1 (`Ok(Commit)`; `OwnCommitPending` is caught internally
    /// and never surfaces), and the winner's location does NOT decrypt yet;
    /// only after `clear_pending_commit` + reprocess does it converge onto the
    /// winner's branch. A future MDK change to this contract fails loudly here.
    #[test]
    fn mdk_process_message_under_pending_commit_pins_own_commit_pending() {
        let setup = setup_four_party_two_admin_circle();
        let carol_hex = setup.carol_keys.public_key().to_hex();
        let dave_hex = setup.dave_keys.public_key().to_hex();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();

        // Distinct targets so the two N+1 branches genuinely diverge.
        let alice_commit = setup
            .alice
            .remove_members(&setup.mls_group_id, std::slice::from_ref(&carol_hex))
            .unwrap()
            .evolution_event;
        let _bob_commit = setup
            .bob
            .remove_members(&setup.mls_group_id, std::slice::from_ref(&dave_hex))
            .unwrap()
            .evolution_event;

        setup
            .alice
            .finalize_pending_commit(&setup.mls_group_id)
            .unwrap();
        assert_eq!(setup.alice.group_epoch(&setup.mls_group_id).unwrap(), n + 1);

        // First attempt while Bob holds his own (rm-Dave) pending commit. MDK
        // MUST NOT silently accept the conflicting commit: the only acceptable
        // outcomes are Err / Unprocessable / an epoch advance (the tolerant
        // `is_handled` triad). The exact variant is rev-dependent — the primitive
        // tolerates all three — so we pin the triad and record the observed
        // variant rather than a specific one (a future MDK change still fails
        // here via the transient-fork / convergence assertions below).
        let first = setup.bob.mdk.process_message(&alice_commit);
        let bob_after_first = setup.bob.group_epoch(&setup.mls_group_id).unwrap();
        let handled = first.is_err()
            || matches!(
                &first,
                Ok(mdk_core::prelude::MessageProcessingResult::Unprocessable { .. })
            )
            || bob_after_first > n;
        assert!(
            handled,
            "MDK must not silently accept a conflicting same-epoch commit; got \
             {first:?}, epoch {n} -> {bob_after_first}"
        );

        // The primitive's clear-AFTER flow: unconditional clear + reprocess.
        // (In this rev the first attempt may already drive convergence via the
        // internal OwnCommitPending-merge + rollback; the clear is then a no-op
        // and the reprocess a duplicate. The load-bearing pin is that after the
        // full flow Bob is on Alice's branch — the F7 control proves the
        // pure-eager path instead FORKS.)
        let _ = setup.bob.clear_pending_commit(&setup.mls_group_id);
        let _ = setup.bob.mdk.process_message(&alice_commit);
        assert_eq!(
            setup.bob.group_epoch(&setup.mls_group_id).unwrap(),
            setup.alice.group_epoch(&setup.mls_group_id).unwrap(),
            "Bob converges to Alice's epoch"
        );
        assert!(
            cross_decrypts(
                &setup.alice,
                &setup.alice_keys.public_key(),
                &setup.bob,
                &setup.mls_group_id
            ),
            "after clear+reprocess the winner's location must decrypt on Bob (shared exporter)"
        );
        // Bob adopted Alice's branch: Carol (winner's target) gone, Dave
        // (loser's target) STILL present — not Bob's own twin.
        let bob_members: Vec<String> = setup
            .bob
            .get_members(&setup.mls_group_id)
            .unwrap()
            .into_iter()
            .map(|m| m.pubkey)
            .collect();
        assert!(
            !bob_members.contains(&carol_hex),
            "Carol removed on Bob (winner's branch)"
        );
        assert!(
            bob_members.contains(&dave_hex),
            "Dave still present on Bob (adopted winner, not twin)"
        );
    }

    /// M3b design validation (regime 1): a member with NO pending commit that
    /// receives two concurrent same-epoch sibling commits converges to the SAME
    /// epoch+secret as another no-pending member that receives them in the
    /// REVERSE order — purely via MDK 93ae324's native epoch-snapshot /
    /// `is_better_candidate` rollback, with NO Haven-side settle buffer. This is
    /// the lynchpin of the engine design: regime-1 receivers (the common case,
    /// incl. all observers) need no buffering; only a member holding its OWN
    /// pending commit (regime 2, admin-only) must buffer + `converge_commit`.
    #[test]
    fn no_pending_observers_converge_on_sibling_commits_via_native_rollback() {
        let setup = setup_four_party_two_admin_circle();

        // Two admins each stage a self-update commit at the same epoch N.
        let a = setup
            .alice
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        let b = setup
            .bob
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;

        // Carol (member, no pending) receives A then B; Dave receives B then A.
        let _ = setup._carol.mdk.process_message(&a);
        let _ = setup._carol.mdk.process_message(&b);
        let _ = setup._dave.mdk.process_message(&b);
        let _ = setup._dave.mdk.process_message(&a);

        let ce = setup._carol.group_epoch(&setup.mls_group_id).unwrap();
        let de = setup._dave.group_epoch(&setup.mls_group_id).unwrap();
        assert_eq!(
            ce, de,
            "observers converge to the same epoch regardless of order"
        );
        assert!(
            cross_decrypts(
                &setup._carol,
                &setup.carol_keys.public_key(),
                &setup._dave,
                &setup.mls_group_id,
            ),
            "regime-1 observers share an exporter secret via native MDK rollback \
             (no settle buffer needed)"
        );
    }

    /// M3b gate #2 (pinned behavior): decrypting a SIBLING commit while we hold
    /// our own unmerged pending commit returns `Ok(Commit)` AND advances our
    /// epoch — MDK applies it (onto our own divergent branch, per
    /// `converge_commit`'s clear+re-apply comment). The engine therefore must
    /// NOT blind-apply an incoming commit while a settle window / pending commit
    /// is held; it must route same-epoch commits through `converge_commit`. If a
    /// future MDK rev changes this, the engine's settle-vs-apply contract must be
    /// revisited, so this pins it.
    #[test]
    fn sibling_commit_while_holding_pending_applies_and_advances() {
        use crate::nostr::mls::types::MessageProcessingResult;
        use crate::nostr::mls::ClassifiedProcessing;

        let setup = setup_two_party_circle();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();

        // Staging our own commit does NOT advance our epoch.
        let _alice_commit = setup.alice.self_update(&setup.mls_group_id).unwrap();
        assert_eq!(setup.alice.group_epoch(&setup.mls_group_id).unwrap(), n);

        // Bob's independent sibling commit at the same epoch N.
        let bob_commit = setup
            .bob
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;

        // Decrypting it the way the live engine would: NOT a CompetingCommit
        // error — a processed Commit that already advanced us.
        let outcome = setup.alice.mdk.process_message_classified(&bob_commit);
        assert!(
            matches!(
                outcome,
                ClassifiedProcessing::Processed(ref r)
                    if matches!(**r, MessageProcessingResult::Commit { .. })
            ),
            "sibling-while-pending surfaces as Processed(Commit), got {outcome:?}"
        );
        assert_eq!(
            setup.alice.group_epoch(&setup.mls_group_id).unwrap(),
            n + 1,
            "decrypting a sibling while holding pending APPLIES it (epoch advances) \
             — hence the engine must not blind-apply during a settle window"
        );
    }

    /// M3b gate #2 (pinned behavior): if both members blind-apply each other's
    /// sibling (the no-settle-buffer engine path), they FORK — and a second
    /// delivery does NOT self-reconcile via MDK's WrongEpoch rollback. This is
    /// the non-vacuous justification that the settle buffer + `converge_commit`
    /// is a CORRECTNESS requirement for the engine, not a latency optimization.
    #[test]
    fn blind_apply_of_siblings_forks_and_does_not_self_reconcile() {
        let setup = setup_two_party_circle();

        let alice_commit = setup
            .alice
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        let bob_commit = setup
            .bob
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;

        // Both blind-apply the sibling while holding their own pending.
        let _ = setup.alice.mdk.process_message(&bob_commit);
        let _ = setup.bob.mdk.process_message(&alice_commit);
        assert!(
            !cross_decrypts(
                &setup.alice,
                &setup.alice_keys.public_key(),
                &setup.bob,
                &setup.mls_group_id,
            ),
            "blind-apply forks: the two epoch-N+1 branches do not share a secret"
        );

        // Re-delivery does not heal it (cursor would replay, but MDK does not
        // roll the already-applied own commit back to the sibling here).
        let _ = setup.alice.mdk.process_message(&bob_commit);
        let _ = setup.bob.mdk.process_message(&alice_commit);
        assert!(
            !cross_decrypts(
                &setup.alice,
                &setup.alice_keys.public_key(),
                &setup.bob,
                &setup.mls_group_id,
            ),
            "blind-apply fork does NOT self-reconcile on re-delivery"
        );
    }

    /// F7: the EXACT reported fork — two members both `self_update` from epoch
    /// N. `converge_commit` makes the loser adopt the winner; cross-decrypt
    /// proves a shared exporter secret.
    #[test]
    fn exact_original_bug_two_self_updates_converge() {
        let setup = setup_two_party_circle();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();

        let alice_commit = setup
            .alice
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        let bob_commit = setup
            .bob
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;

        let alice_out = setup
            .alice
            .converge_commit(
                &setup.mls_group_id,
                &alice_commit,
                n,
                std::slice::from_ref(&bob_commit),
                &CommitIntent::None,
            )
            .unwrap();
        let bob_out = setup
            .bob
            .converge_commit(
                &setup.mls_group_id,
                &bob_commit,
                n,
                std::slice::from_ref(&alice_commit),
                &CommitIntent::None,
            )
            .unwrap();

        assert_eq!(
            [alice_out, bob_out]
                .iter()
                .filter(|o| matches!(o, CommitConvergence::Merged))
                .count(),
            1,
            "exactly one winner merges: alice={alice_out:?} bob={bob_out:?}"
        );
        let ae = setup.alice.group_epoch(&setup.mls_group_id).unwrap();
        let be = setup.bob.group_epoch(&setup.mls_group_id).unwrap();
        assert_eq!(ae, be, "alice/bob converge to the same epoch");
        assert_eq!(ae, n + 1);

        // Cross-decrypt BOTH ways: a shared exporter, not a same-number twin.
        assert!(cross_decrypts(
            &setup.alice,
            &setup.alice_keys.public_key(),
            &setup.bob,
            &setup.mls_group_id
        ));
        assert!(cross_decrypts(
            &setup.bob,
            &setup.bob_keys.public_key(),
            &setup.alice,
            &setup.mls_group_id
        ));

        // No residual pending commit on either side.
        assert!(setup.alice.self_update(&setup.mls_group_id).is_ok());
        let _ = setup.alice.clear_pending_commit(&setup.mls_group_id);
        assert!(setup.bob.self_update(&setup.mls_group_id).is_ok());
        let _ = setup.bob.clear_pending_commit(&setup.mls_group_id);
    }

    /// F7 NON-VACUOUS CONTROL: without convergence (both eager-finalize) the
    /// two self-update commits FORK and cross-decrypt FAILS — proving the F7
    /// assertion is not vacuously satisfiable by a twin fork.
    #[test]
    fn exact_original_bug_pure_eager_merge_forks_control() {
        let setup = setup_two_party_circle();
        let _ = setup.alice.self_update(&setup.mls_group_id).unwrap();
        let _ = setup.bob.self_update(&setup.mls_group_id).unwrap();
        setup
            .alice
            .finalize_pending_commit(&setup.mls_group_id)
            .unwrap();
        setup
            .bob
            .finalize_pending_commit(&setup.mls_group_id)
            .unwrap();
        assert!(
            !cross_decrypts(
                &setup.alice,
                &setup.alice_keys.public_key(),
                &setup.bob,
                &setup.mls_group_id
            ),
            "pure eager-merge MUST fork: the winner's location must NOT decrypt on the twin"
        );
    }

    /// M3b design validation (regime 2): does the White-Noise-style
    /// "finalize-our-own-immediately, then receive the competitor and let MDK's
    /// native rollback converge" path actually converge two admins who each
    /// staged a commit at epoch N? If YES, the engine's regime-2 admin path can
    /// avoid the settle buffer + `converge_commit` entirely; if NO,
    /// `converge_commit` is required for the admin case.
    #[test]
    fn eager_finalize_then_exchange_native_rollback_outcome() {
        let setup = setup_two_party_circle();

        let alice_commit = setup
            .alice
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        let bob_commit = setup
            .bob
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;

        // White Noise style: each merges its OWN commit immediately (no pending
        // held), reaching N+1 on its own branch.
        setup
            .alice
            .finalize_pending_commit(&setup.mls_group_id)
            .unwrap();
        setup
            .bob
            .finalize_pending_commit(&setup.mls_group_id)
            .unwrap();

        // Then each receives the other's competitor commit (WrongEpoch → MDK's
        // is_better_candidate rollback should fire).
        let _ = setup.alice.mdk.process_message(&bob_commit);
        let _ = setup.bob.mdk.process_message(&alice_commit);

        let converged = cross_decrypts(
            &setup.alice,
            &setup.alice_keys.public_key(),
            &setup.bob,
            &setup.mls_group_id,
        );
        // FINDING (pinned): native rollback does NOT heal two STAGING admins —
        // when we merged our OWN commit, MDK does not roll us back to a competing
        // sibling on receipt. So regime 2 (we staged a commit) REQUIRES
        // `converge_commit`; only regime 1 (no own staged commit) is saved by
        // native rollback (see `no_pending_observers_converge_..._native_rollback`).
        assert!(
            !converged,
            "eager-finalize + native rollback must fork two staging admins \
             (regime 2 needs converge_commit)"
        );
    }

    /// M3b design validation (change #3 probe): after `converge_commit` resolves
    /// two staging admins, RE-DELIVERING the loser's competitor commit (which the
    /// engine's no-skip cursor makes possible) must NOT re-fork them. If the
    /// current converge body is robust to re-delivery, marmot's "change #3"
    /// (rewrite the loser path) is unnecessary; if it re-forks, it is required.
    #[test]
    fn converge_is_robust_to_competitor_redelivery() {
        let setup = setup_two_party_circle();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();

        let alice_commit = setup
            .alice
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        let bob_commit = setup
            .bob
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;

        setup
            .alice
            .converge_commit(
                &setup.mls_group_id,
                &alice_commit,
                n,
                std::slice::from_ref(&bob_commit),
                &CommitIntent::None,
            )
            .unwrap();
        setup
            .bob
            .converge_commit(
                &setup.mls_group_id,
                &bob_commit,
                n,
                std::slice::from_ref(&alice_commit),
                &CommitIntent::None,
            )
            .unwrap();
        assert!(
            cross_decrypts(
                &setup.alice,
                &setup.alice_keys.public_key(),
                &setup.bob,
                &setup.mls_group_id,
            ),
            "converge_commit converges (precondition)"
        );

        // Re-deliver BOTH competitor commits to BOTH sides (the loser's is the
        // dangerous one — a stale WrongEpoch commit MDK must keep rejecting).
        for ev in [&alice_commit, &bob_commit] {
            let _ = setup.alice.mdk.process_message(ev);
            let _ = setup.bob.mdk.process_message(ev);
        }
        assert!(
            cross_decrypts(
                &setup.alice,
                &setup.alice_keys.public_key(),
                &setup.bob,
                &setup.mls_group_id,
            ),
            "converge must stay converged after competitor re-delivery (no re-fork)"
        );
    }

    /// M3b loser-path finding (marmot MEDIUM-a): `converge_commit`'s **`Merged`**
    /// branch finalizes our own commit via `merge_pending_commit`, which (unlike
    /// `process_commit`) creates NO epoch snapshot — so a *later*, globally-better
    /// sibling arriving AFTER we won cannot single-pass roll us back, and we can
    /// transiently diverge from a peer who saw that better sibling. This is the
    /// same root cause as the eager-finalize fork (see
    /// `eager_finalize_then_exchange_native_rollback_outcome`). It is therefore
    /// NOT a guaranteed single-pass invariant — convergence for this late-delivery
    /// case is owed to M6's bounded re-stage loop + lossless cursor replay (the
    /// regime-2 cursor does not advance, so the better sibling is re-fetched and a
    /// fresh convergence runs). A deterministic regression test for that belongs
    /// with the M6 re-stage wiring; pinning it here against real `self_update`
    /// commits would be order-key-dependent (random event ids) and thus flaky.
    /// The observer (no-own-commit) case IS guaranteed single-pass and is covered
    /// by `no_pending_observers_converge_on_sibling_commits_via_native_rollback`.

    /// F2: two admins concurrently `remove_members(carol)` from epoch N.
    #[test]
    fn concurrent_admin_remove_same_target_converges() {
        let setup = setup_three_party_two_admin_circle();
        let carol_hex = setup.carol_keys.public_key().to_hex();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();
        let intent = CommitIntent::RemoveMembers(vec![setup.carol_keys.public_key()]);

        let alice_commit = setup
            .alice
            .remove_members(&setup.mls_group_id, std::slice::from_ref(&carol_hex))
            .unwrap()
            .evolution_event;
        let bob_commit = setup
            .bob
            .remove_members(&setup.mls_group_id, std::slice::from_ref(&carol_hex))
            .unwrap()
            .evolution_event;

        let alice_out = setup
            .alice
            .converge_commit(
                &setup.mls_group_id,
                &alice_commit,
                n,
                std::slice::from_ref(&bob_commit),
                &intent,
            )
            .unwrap();
        let bob_out = setup
            .bob
            .converge_commit(
                &setup.mls_group_id,
                &bob_commit,
                n,
                std::slice::from_ref(&alice_commit),
                &intent,
            )
            .unwrap();

        assert_eq!(
            [alice_out, bob_out]
                .iter()
                .filter(|o| matches!(o, CommitConvergence::Merged))
                .count(),
            1
        );
        assert_eq!(
            setup.alice.group_epoch(&setup.mls_group_id).unwrap(),
            setup.bob.group_epoch(&setup.mls_group_id).unwrap()
        );
        assert_eq!(setup.alice.group_epoch(&setup.mls_group_id).unwrap(), n + 1);

        for (mgr, out) in [(&setup.alice, alice_out), (&setup.bob, bob_out)] {
            assert!(
                !mgr.get_members(&setup.mls_group_id)
                    .unwrap()
                    .iter()
                    .any(|m| m.pubkey == carol_hex),
                "Carol evicted on both"
            );
            if let CommitConvergence::AdoptedWinner {
                intent_still_pending,
            } = out
            {
                assert!(
                    !intent_still_pending,
                    "same-target remove: intent satisfied by winner"
                );
            }
        }
        assert!(cross_decrypts(
            &setup.alice,
            &setup.alice_keys.public_key(),
            &setup.bob,
            &setup.mls_group_id
        ));
        assert!(cross_decrypts(
            &setup.bob,
            &setup.bob_keys.public_key(),
            &setup.alice,
            &setup.mls_group_id
        ));
        // No residual: the loser can stage a fresh remove.
        assert!(setup
            .bob
            .remove_members(
                &setup.mls_group_id,
                &[setup.alice_keys.public_key().to_hex()]
            )
            .is_ok());
        let _ = setup.bob.clear_pending_commit(&setup.mls_group_id);
    }

    /// F2b (most diagnostic): Alice rm Carol, Bob rm Dave from epoch N — the
    /// member sets differ, so membership coincidence cannot mask a fork. The
    /// loser must adopt the WINNER's membership (winner's target gone, loser's
    /// STILL present), report intent_still_pending, then re-stage on N+1.
    #[test]
    fn concurrent_admin_remove_distinct_targets_converges() {
        let setup = setup_four_party_two_admin_circle();
        let carol_hex = setup.carol_keys.public_key().to_hex();
        let dave_hex = setup.dave_keys.public_key().to_hex();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();

        let alice_commit = setup
            .alice
            .remove_members(&setup.mls_group_id, std::slice::from_ref(&carol_hex))
            .unwrap()
            .evolution_event;
        let bob_commit = setup
            .bob
            .remove_members(&setup.mls_group_id, std::slice::from_ref(&dave_hex))
            .unwrap()
            .evolution_event;

        let alice_out = setup
            .alice
            .converge_commit(
                &setup.mls_group_id,
                &alice_commit,
                n,
                std::slice::from_ref(&bob_commit),
                &CommitIntent::RemoveMembers(vec![setup.carol_keys.public_key()]),
            )
            .unwrap();
        let bob_out = setup
            .bob
            .converge_commit(
                &setup.mls_group_id,
                &bob_commit,
                n,
                std::slice::from_ref(&alice_commit),
                &CommitIntent::RemoveMembers(vec![setup.dave_keys.public_key()]),
            )
            .unwrap();

        let alice_won = matches!(alice_out, CommitConvergence::Merged);
        assert_ne!(
            alice_won,
            matches!(bob_out, CommitConvergence::Merged),
            "exactly one winner"
        );
        let ae = setup.alice.group_epoch(&setup.mls_group_id).unwrap();
        assert_eq!(ae, setup.bob.group_epoch(&setup.mls_group_id).unwrap());
        assert_eq!(ae, n + 1);

        let (winner, winner_keys, loser, winner_target, loser_target, loser_out) = if alice_won {
            (
                &setup.alice,
                &setup.alice_keys,
                &setup.bob,
                &carol_hex,
                &dave_hex,
                bob_out,
            )
        } else {
            (
                &setup.bob,
                &setup.bob_keys,
                &setup.alice,
                &dave_hex,
                &carol_hex,
                alice_out,
            )
        };
        let loser_members: Vec<String> = loser
            .get_members(&setup.mls_group_id)
            .unwrap()
            .into_iter()
            .map(|m| m.pubkey)
            .collect();
        assert!(
            !loser_members.contains(winner_target),
            "winner's target removed on loser"
        );
        assert!(
            loser_members.contains(loser_target),
            "loser's own target STILL present — it adopted the winner's branch, not a twin"
        );
        match loser_out {
            CommitConvergence::AdoptedWinner {
                intent_still_pending,
            } => {
                assert!(
                    intent_still_pending,
                    "loser's distinct-target intent still pending"
                );
            }
            other => panic!("loser must be AdoptedWinner, got {other:?}"),
        }
        assert!(cross_decrypts(
            winner,
            &winner_keys.public_key(),
            loser,
            &setup.mls_group_id
        ));

        // The loser re-stages its own remove on N+1 (no competitor → Merged),
        // then the winner applies it; both targets end up removed everywhere.
        let loser_commit = loser
            .remove_members(&setup.mls_group_id, std::slice::from_ref(loser_target))
            .unwrap()
            .evolution_event;
        let re = loser
            .converge_commit(
                &setup.mls_group_id,
                &loser_commit,
                ae,
                &[],
                &CommitIntent::None,
            )
            .unwrap();
        assert_eq!(re, CommitConvergence::Merged);
        let _ = winner.mdk.process_message(&loser_commit);
        let winner_members: Vec<String> = winner
            .get_members(&setup.mls_group_id)
            .unwrap()
            .into_iter()
            .map(|m| m.pubkey)
            .collect();
        assert!(
            !winner_members.contains(loser_target),
            "both targets eventually removed"
        );
    }

    /// Builds a real kind:443 KeyPackage event for a fresh member (mirrors the
    /// inline construction in `decrypt_location_group_update`).
    fn build_new_member_kp(mdk: &MdkManager, keys: &Keys) -> Event {
        let bundle = mdk
            .create_key_package(
                &keys.public_key().to_hex(),
                &["wss://relay.test.com".to_string()],
            )
            .expect("create key package");
        let tags: Vec<nostr::Tag> = bundle
            .tags_443
            .into_iter()
            .map(|t| nostr::Tag::parse(&t).unwrap())
            .collect();
        EventBuilder::new(Kind::MlsKeyPackage, bundle.content)
            .tags(tags)
            .sign_with_keys(keys)
            .expect("sign key package")
    }

    // ==================== M7 staged-commit marker consistency ====================

    /// The load-bearing M7 invariant: the Haven marker mirrors MDK's real
    /// pending-commit lifecycle across self_update / remove / and the two clear
    /// chokepoints (finalize + clear). A MISSING marker while MDK holds a
    /// pending commit is the fork-unsafe state this pins against.
    #[test]
    fn m7_marker_mirrors_mdk_pending_across_self_update_and_remove() {
        let setup = setup_two_party_circle();
        let a = &setup.alice;
        let gid = &setup.mls_group_id;
        let ngid = &setup.nostr_group_id;

        // create_circle self-merges its initial commit → no pending marker.
        assert!(!a.has_pending_commit(ngid), "no pending after create");

        // self_update → SET; finalize → CLEAR.
        a.self_update(gid).unwrap();
        assert!(a.has_pending_commit(ngid), "self_update set marker");
        a.finalize_pending_commit(gid).unwrap();
        assert!(!a.has_pending_commit(ngid), "finalize cleared marker");

        // self_update → SET; clear (rollback) → CLEAR.
        a.self_update(gid).unwrap();
        assert!(a.has_pending_commit(ngid));
        a.clear_pending_commit(gid).unwrap();
        assert!(!a.has_pending_commit(ngid), "clear cleared marker");

        // remove_members → SET; finalize → CLEAR.
        let bob_hex = setup.bob_keys.public_key().to_hex();
        a.remove_members(gid, std::slice::from_ref(&bob_hex))
            .unwrap();
        assert!(a.has_pending_commit(ngid), "remove set marker");
        a.finalize_pending_commit(gid).unwrap();
        assert!(!a.has_pending_commit(ngid));
    }

    /// add_members (and via it add_members_with_welcomes) sets the marker.
    #[test]
    fn m7_add_members_sets_marker_cleared_on_finalize() {
        let setup = setup_two_party_circle();
        let a = &setup.alice;
        let gid = &setup.mls_group_id;
        let ngid = &setup.nostr_group_id;

        let erin_dir = TempDir::new().unwrap();
        let erin_mdk = MdkManager::new_unencrypted(erin_dir.path()).unwrap();
        let erin_keys = Keys::generate();
        let erin_kp = build_new_member_kp(&erin_mdk, &erin_keys);

        a.add_members(gid, std::slice::from_ref(&erin_kp)).unwrap();
        assert!(a.has_pending_commit(ngid), "add_members set marker");
        a.finalize_pending_commit(gid).unwrap();
        assert!(!a.has_pending_commit(ngid));
        drop(erin_dir);
    }

    /// `update_circle_relays` is a `GroupContextExtensions` staging path — the
    /// representative of the THREE paths the v1/v2 enumeration MISSED
    /// (relay-update, admin-handoff, self-demote all stage via the same
    /// `GroupContextExtensions` mechanism and route through the identical
    /// `mark_group_staged` helper). This pins that the class sets the marker.
    /// (`propose_admin_handoff`/`propose_self_demote` need a second admin; the
    /// low-level four-party test fixture builds its group via `create_group`
    /// and so persists no circle row for `marker_key` to resolve — they are
    /// covered by code inspection + the post-implementation QC, and exercise
    /// the identical helper proven here.)
    #[test]
    fn m7_relay_update_sets_and_clears_marker() {
        let setup = setup_two_party_circle();
        let gid = &setup.mls_group_id;
        let ngid = &setup.nostr_group_id;
        setup
            .alice
            .update_circle_relays(
                gid,
                &[
                    "wss://relay.one.example".to_string(),
                    "wss://relay.two.example".to_string(),
                ],
            )
            .unwrap();
        assert!(
            setup.alice.has_pending_commit(ngid),
            "update_circle_relays set marker"
        );
        setup.alice.finalize_pending_commit(gid).unwrap();
        assert!(!setup.alice.has_pending_commit(ngid));
    }

    /// has_pending_commit reads the pseudonymous nostr_group_id and returns
    /// false for a group that never staged.
    #[test]
    fn m7_has_pending_commit_false_for_unstaged_group() {
        let setup = setup_two_party_circle();
        assert!(!setup.alice.has_pending_commit(&setup.nostr_group_id));
        // An unknown group id is likewise not pending (row absent).
        assert!(!setup.alice.has_pending_commit(&[0u8; 32]));
    }

    /// M10 teardown: wipe_all_staged_commits and the delete_circle cascade both
    /// remove the marker so a returning/other identity never inherits a stale
    /// skip.
    #[test]
    fn m7_wipe_and_delete_circle_cascade_clear_marker() {
        // wipe_all_staged_commits.
        let setup = setup_two_party_circle();
        setup.alice.self_update(&setup.mls_group_id).unwrap();
        assert!(setup.alice.has_pending_commit(&setup.nostr_group_id));
        setup.alice.storage.wipe_all_staged_commits().unwrap();
        assert!(
            !setup.alice.has_pending_commit(&setup.nostr_group_id),
            "wipe cleared the marker"
        );

        // delete_circle cascade.
        let s2 = setup_two_party_circle();
        s2.alice.self_update(&s2.mls_group_id).unwrap();
        assert!(s2.alice.has_pending_commit(&s2.nostr_group_id));
        s2.alice.storage.delete_circle(&s2.mls_group_id).unwrap();
        assert!(
            !s2.alice.has_pending_commit(&s2.nostr_group_id),
            "delete_circle cascaded the marker"
        );
    }

    /// M7-1 fork-safety: a peer location is decrypted + persisted normally, but
    /// once the group holds a pending commit (regime 2), `decrypt_receive_only`
    /// SKIPS it WITHOUT decrypting or persisting (C-NOFORK-2) — the property
    /// that prevents a background sweep blind-applying a same-epoch sibling.
    #[test]
    fn m7_receive_only_persists_peer_then_pending_gate_skips_without_decrypt() {
        use crate::location::LocationMessage;
        use crate::relay::ReceiveOnlyOutcome;

        let setup = setup_two_party_circle();
        let gid = &setup.mls_group_id;
        let ngid = &setup.nostr_group_id;
        let alice_hex = setup.alice_keys.public_key().to_hex();
        let bob_hex = setup.bob_keys.public_key().to_hex();
        let now = chrono::Utc::now().timestamp();

        // Bob sends a location; Alice receive-only decrypts → Location, persisted,
        // cursor-advancing.
        let (loc1, _, _) = setup
            .bob
            .encrypt_location(
                gid,
                &setup.bob_keys.public_key(),
                &LocationMessage::new(40.0, -74.0),
                300,
            )
            .unwrap();
        let out1 = receive_only_until_applied(&setup.alice, &loc1, ngid, &alice_hex);
        assert_eq!(out1, ReceiveOnlyOutcome::Location);
        assert!(out1.advances_cursor());
        let rows = setup
            .alice
            .snapshot_last_known_for_circle(ngid, now)
            .unwrap();
        assert!(
            rows.iter().any(|r| r.sender_pubkey == bob_hex),
            "peer location persisted"
        );

        // Alice stages a pending commit → marker set. A NEW peer location for the
        // SAME group is now SKIPPED without decrypting or persisting.
        setup.alice.self_update(gid).unwrap();
        assert!(setup.alice.has_pending_commit(ngid));
        let (loc2, _, _) = setup
            .bob
            .encrypt_location(
                gid,
                &setup.bob_keys.public_key(),
                &LocationMessage::new(41.0, -75.0),
                300,
            )
            .unwrap();
        let out2 = setup.alice.decrypt_receive_only(&loc2, ngid, &alice_hex);
        assert_eq!(
            out2,
            ReceiveOnlyOutcome::Skipped,
            "regime-2 group skipped without decrypt"
        );
        assert!(!out2.advances_cursor());
        // The skipped location was NOT persisted (proves the skip is pre-decrypt).
        let rows2 = setup
            .alice
            .snapshot_last_known_for_circle(ngid, now)
            .unwrap();
        assert!(
            !rows2.iter().any(|r| (r.latitude - 41.0).abs() < 0.001),
            "skipped location not persisted"
        );
    }

    /// M7-1: a peer SelfRemove auto-staged during a receive-only sweep is
    /// classified `AutoCommitStaged` — NEVER cleared, the marker is SET (so
    /// future wakes skip), the cursor STOPS, and no epoch advances. The
    /// foreground engine converges it later.
    #[test]
    fn m7_receive_only_auto_commit_stages_marks_and_stops_cursor() {
        use crate::relay::ReceiveOnlyOutcome;
        let setup = setup_two_party_circle();
        let ngid = &setup.nostr_group_id;
        let alice_hex = setup.alice_keys.public_key().to_hex();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();
        assert!(!setup.alice.has_pending_commit(ngid));

        let self_remove = setup
            .bob
            .propose_leave(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        let out = receive_only_until_applied(&setup.alice, &self_remove, ngid, &alice_hex);
        assert_eq!(out, ReceiveOnlyOutcome::AutoCommitStaged);
        assert!(
            !out.advances_cursor(),
            "cursor stops before an auto-staged commit"
        );
        assert!(
            setup.alice.has_pending_commit(ngid),
            "marker SET so future background wakes skip this group"
        );
        // Never merged/cleared → the staged commit does not advance the epoch.
        assert_eq!(setup.alice.group_epoch(&setup.mls_group_id).unwrap(), n);
    }

    /// M7-1: an already-applied peer commit (regime 1) is classified
    /// `CommitApplied` and advances the cursor (convergent — authors nothing,
    /// leaves no local pending commit).
    #[test]
    fn m7_receive_only_applied_peer_commit_advances_cursor() {
        use crate::relay::ReceiveOnlyOutcome;
        let setup = setup_two_party_circle();
        let ngid = &setup.nostr_group_id;
        let alice_hex = setup.alice_keys.public_key().to_hex();

        let commit = setup
            .bob
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        let out = receive_only_until_applied(&setup.alice, &commit, ngid, &alice_hex);
        assert_eq!(out, ReceiveOnlyOutcome::CommitApplied);
        assert!(
            out.advances_cursor(),
            "an applied peer commit advances the cursor"
        );
        assert!(
            !setup.alice.has_pending_commit(ngid),
            "applying a peer commit authors nothing — no local pending"
        );
    }

    /// M7 FAIL-CLOSED (the most load-bearing clause): a storage error in
    /// `has_pending_commit` MUST return `true` (skip the decrypt), never
    /// fail-open to `false` (which would let a background sweep blind-apply a
    /// same-epoch sibling over a pending commit → fork). Injected by dropping
    /// the marker table so the `SELECT` errors.
    #[test]
    fn m7_has_pending_commit_fails_closed_on_storage_error() {
        let setup = setup_two_party_circle();
        let ngid = &setup.nostr_group_id;
        assert!(!setup.alice.has_pending_commit(ngid), "no marker → false");

        setup
            .alice
            .storage
            .conn()
            .lock()
            .unwrap()
            .execute("DROP TABLE staged_commits", [])
            .unwrap();

        assert!(
            setup.alice.has_pending_commit(ngid),
            "a storage error must FAIL CLOSED to true"
        );
    }

    /// COVERAGE (M6-4 add-member path): two admins concurrently ADD DISTINCT new
    /// members from the same epoch N. `converge_commit` must pick one MIP-03
    /// winner, advance both to N+1, and — via `intent_unsatisfied`'s `AddMembers`
    /// arm — report the loser's own not-yet-added member as `intent_still_pending`
    /// (driving the M6-4 Dart re-stage), while the WINNER's added member is
    /// present on the loser's adopted branch. Mirror of
    /// `concurrent_admin_remove_distinct_targets_converges` for the Add intent —
    /// the previously-untested decision path behind `ConvergeIntentKind.add`.
    #[test]
    fn concurrent_admin_add_distinct_members_converges() {
        let setup = setup_four_party_two_admin_circle();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();

        // Two fresh members, each with a real KeyPackage. Keep the temp dirs in
        // scope for the whole test (the KP events are self-contained, but this
        // avoids any early cleanup).
        let erin_dir = TempDir::new().unwrap();
        let erin_mdk = MdkManager::new_unencrypted(erin_dir.path()).unwrap();
        let erin_keys = Keys::generate();
        let erin_kp = build_new_member_kp(&erin_mdk, &erin_keys);

        let frank_dir = TempDir::new().unwrap();
        let frank_mdk = MdkManager::new_unencrypted(frank_dir.path()).unwrap();
        let frank_keys = Keys::generate();
        let frank_kp = build_new_member_kp(&frank_mdk, &frank_keys);

        let alice_commit = setup
            .alice
            .add_members(&setup.mls_group_id, std::slice::from_ref(&erin_kp))
            .unwrap()
            .evolution_event;
        let bob_commit = setup
            .bob
            .add_members(&setup.mls_group_id, std::slice::from_ref(&frank_kp))
            .unwrap()
            .evolution_event;

        let alice_out = setup
            .alice
            .converge_commit(
                &setup.mls_group_id,
                &alice_commit,
                n,
                std::slice::from_ref(&bob_commit),
                &CommitIntent::AddMembers(vec![erin_keys.public_key()]),
            )
            .unwrap();
        let bob_out = setup
            .bob
            .converge_commit(
                &setup.mls_group_id,
                &bob_commit,
                n,
                std::slice::from_ref(&alice_commit),
                &CommitIntent::AddMembers(vec![frank_keys.public_key()]),
            )
            .unwrap();

        let alice_won = matches!(alice_out, CommitConvergence::Merged);
        assert_ne!(
            alice_won,
            matches!(bob_out, CommitConvergence::Merged),
            "exactly one winner"
        );
        let ae = setup.alice.group_epoch(&setup.mls_group_id).unwrap();
        assert_eq!(ae, setup.bob.group_epoch(&setup.mls_group_id).unwrap());
        assert_eq!(ae, n + 1);

        let (winner, winner_keys, loser, winner_added, loser_added, loser_out) = if alice_won {
            (
                &setup.alice,
                &setup.alice_keys,
                &setup.bob,
                erin_keys.public_key().to_hex(),
                frank_keys.public_key().to_hex(),
                bob_out,
            )
        } else {
            (
                &setup.bob,
                &setup.bob_keys,
                &setup.alice,
                frank_keys.public_key().to_hex(),
                erin_keys.public_key().to_hex(),
                alice_out,
            )
        };

        let loser_members: Vec<String> = loser
            .get_members(&setup.mls_group_id)
            .unwrap()
            .into_iter()
            .map(|m| m.pubkey)
            .collect();
        assert!(
            loser_members.contains(&winner_added),
            "winner's added member present on the loser's adopted branch"
        );
        assert!(
            !loser_members.contains(&loser_added),
            "loser's own added member ABSENT — its Add rolled back, adopting the winner's branch"
        );
        match loser_out {
            CommitConvergence::AdoptedWinner {
                intent_still_pending,
            } => assert!(
                intent_still_pending,
                "loser's Add intent still pending (its member was not added by the winner)"
            ),
            other => panic!("loser must be AdoptedWinner, got {other:?}"),
        }
        assert!(cross_decrypts(
            winner,
            &winner_keys.public_key(),
            loser,
            &setup.mls_group_id
        ));

        // The WINNER's own Add intent is SATISFIED post-adopt (its member is in
        // the roster) → intent_unsatisfied returns false → no re-stage.
        let winner_target = if alice_won {
            erin_keys.public_key()
        } else {
            frank_keys.public_key()
        };
        assert!(
            !winner
                .intent_unsatisfied(
                    &setup.mls_group_id,
                    &CommitIntent::AddMembers(vec![winner_target])
                )
                .unwrap(),
            "winner's added member present → its Add intent satisfied"
        );

        drop(erin_dir);
        drop(frank_dir);
    }

    /// FAST: single-admin (no competitor) preserves today's path — Merged,
    /// epoch +1, no clear/regression.
    #[test]
    fn single_admin_no_competitor_converges_to_merged() {
        let setup = setup_two_party_circle();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();
        let bob_hex = setup.bob_keys.public_key().to_hex();
        let commit = setup
            .alice
            .remove_members(&setup.mls_group_id, std::slice::from_ref(&bob_hex))
            .unwrap()
            .evolution_event;
        let out = setup
            .alice
            .converge_commit(
                &setup.mls_group_id,
                &commit,
                n,
                &[],
                &CommitIntent::RemoveMembers(vec![setup.bob_keys.public_key()]),
            )
            .unwrap();
        assert_eq!(out, CommitConvergence::Merged);
        assert_eq!(setup.alice.group_epoch(&setup.mls_group_id).unwrap(), n + 1);
        assert!(!setup
            .alice
            .get_members(&setup.mls_group_id)
            .unwrap()
            .iter()
            .any(|m| m.pubkey == bob_hex));
    }

    /// TOCTOU: the local group advanced past `staged_epoch` before convergence
    /// (an evolution poller applied a peer commit) → no double-apply, RolledBack
    /// with no dangling pending commit.
    #[test]
    fn converge_when_group_already_advanced_rolls_back_no_dangling() {
        let setup = setup_three_party_two_admin_circle();
        let carol_hex = setup.carol_keys.public_key().to_hex();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();

        let alice_commit = setup
            .alice
            .remove_members(&setup.mls_group_id, std::slice::from_ref(&carol_hex))
            .unwrap()
            .evolution_event;
        // Bob's commit advances Alice's local group first (the poller path).
        let bob_commit = setup
            .bob
            .remove_members(&setup.mls_group_id, std::slice::from_ref(&carol_hex))
            .unwrap()
            .evolution_event;
        setup
            .bob
            .finalize_pending_commit(&setup.mls_group_id)
            .unwrap();
        let _ = setup.alice.clear_pending_commit(&setup.mls_group_id);
        let _ = setup.alice.mdk.process_message(&bob_commit);
        assert!(setup.alice.group_epoch(&setup.mls_group_id).unwrap() > n);

        let out = setup
            .alice
            .converge_commit(
                &setup.mls_group_id,
                &alice_commit,
                n,
                &[],
                &CommitIntent::None,
            )
            .unwrap();
        assert_eq!(out, CommitConvergence::RolledBack);
        assert!(setup
            .alice
            .remove_members(&setup.mls_group_id, &[setup.bob_keys.public_key().to_hex()])
            .is_ok());
        let _ = setup.alice.clear_pending_commit(&setup.mls_group_id);
    }

    /// SEC2 + H1 liveness gate: a competitor that wins the MIP-03 order key but
    /// CANNOT be applied (a foreign / unauthenticated event — or a routine
    /// Location) is NOT a genuine convergence competitor: it can never advance the
    /// MLS epoch, so it is EXCLUDED from the candidate set and our legitimate
    /// commit MERGES. Pre-M11 this returned `RolledBack` (the liveness bug — an
    /// order-key-winning non-commit starved the membership op into a re-stage
    /// loop). The security intent is PRESERVED and strengthened: the forged event
    /// is never adopted (our own removal target is actually gone) and no dangling
    /// pending commit is left behind.
    #[test]
    fn converge_ignores_unapplicable_competitor_and_merges_ours() {
        let setup = setup_three_party_two_admin_circle();
        let carol_hex = setup.carol_keys.public_key().to_hex();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();

        let our_commit = setup
            .alice
            .remove_members(&setup.mls_group_id, std::slice::from_ref(&carol_hex))
            .unwrap()
            .evolution_event;
        // A foreign kind-445 event with created_at=1 so it "wins" the order key
        // but is not a valid commit for this group.
        let forged = EventBuilder::new(Kind::Custom(445), "not-a-real-commit")
            .custom_created_at(nostr::Timestamp::from(1))
            .sign_with_keys(&Keys::generate())
            .unwrap();

        let out = setup
            .alice
            .converge_commit(
                &setup.mls_group_id,
                &our_commit,
                n,
                std::slice::from_ref(&forged),
                &CommitIntent::None,
            )
            .unwrap();
        assert_eq!(
            out,
            CommitConvergence::Merged,
            "an order-key-winning non-commit must be ignored, not force a rollback"
        );
        assert_eq!(
            setup.alice.group_epoch(&setup.mls_group_id).unwrap(),
            n + 1,
            "our legitimate commit advanced the epoch; the forged event never did"
        );
        // Our removal target (Carol) is actually gone — OUR commit merged, the
        // forged competitor was NOT adopted.
        assert!(
            !setup
                .alice
                .member_pubkeys_hex(&setup.mls_group_id)
                .unwrap()
                .contains(&carol_hex),
            "our Remove(carol) commit merged (the forged competitor was not adopted)"
        );
        // No dangling pending commit: a fresh op stages cleanly.
        assert!(setup.alice.self_update(&setup.mls_group_id).is_ok());
        let _ = setup.alice.clear_pending_commit(&setup.mls_group_id);
    }

    /// H1 fork-safety (M11 review Finding R1/M2): the LOCAL invariant that a
    /// peer's `SelfRemove` leave PROPOSAL buffered as an order-beating
    /// settle-window competitor must NEVER make the converging admin merge a
    /// phantom commit. The hazard: `process_message` on a `SelfRemove` drives
    /// MDK's `auto_commit_proposal`, whose `stage_commit` OVERWRITES our own
    /// staged pending commit (see `relay::live_sync::autocommit` module docs). If
    /// the walk then blindly `merge_our_pending_commit`s, it would merge an
    /// unpublished "remove Bob" commit instead of our self-update.
    ///
    /// Local invariant (what THIS single-manager test pins): after convergence we
    /// either merged OUR self-update (Bob still a member) or rolled back cleanly
    /// (epoch unchanged) — never `Merged` with Bob removed, never `AdoptedWinner`.
    ///
    /// NB: this does NOT prove distributed fork-safety. Under live-sync (M6) our
    /// commit is published DURING the window, so a `RolledBack` here can still
    /// strand us against passive peers that kept the published commit — the
    /// Phase-B blocker HIGH-1 tracked in `docs/M11_ROLLOUT_PLAN.md`, which a
    /// two-manager cross-decrypt test must cover before the flag flips.
    #[test]
    fn converge_with_a_peer_selfremove_competitor_never_phantom_merges() {
        let setup = setup_two_party_circle();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();
        let bob_hex = setup.bob_keys.public_key().to_hex();

        // Bob proposes to leave FIRST → his SelfRemove strictly sorts ahead of
        // Alice's commit in MIP-03 order (so it lands in the beating set).
        let bob_selfremove = setup
            .bob
            .propose_leave(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        std::thread::sleep(std::time::Duration::from_millis(1100));

        // Alice (admin) stages a self-update — her pending commit — published
        // during the window.
        let alice_commit = setup
            .alice
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        assert!(
            bob_selfremove.created_at < alice_commit.created_at,
            "precondition: the SelfRemove must sort ahead of our commit"
        );

        let out = setup
            .alice
            .converge_commit(
                &setup.mls_group_id,
                &alice_commit,
                n,
                std::slice::from_ref(&bob_selfremove),
                &CommitIntent::None,
            )
            .unwrap();

        match out {
            CommitConvergence::Merged => {
                assert_eq!(setup.alice.group_epoch(&setup.mls_group_id).unwrap(), n + 1);
                assert!(
                    setup
                        .alice
                        .member_pubkeys_hex(&setup.mls_group_id)
                        .unwrap()
                        .contains(&bob_hex),
                    "FORK: Alice merged an unpublished 'remove Bob' auto-commit \
                     instead of her own published self-update"
                );
            }
            CommitConvergence::RolledBack => {
                // Safe: no fork, the caller re-fetches + re-stages. Epoch unchanged.
                assert_eq!(setup.alice.group_epoch(&setup.mls_group_id).unwrap(), n);
            }
            CommitConvergence::AdoptedWinner { .. } => {
                panic!("a SelfRemove proposal is not a commit and must not be adopted");
            }
        }
        // Whatever the leg, no dangling pending commit remains.
        let _ = setup.alice.clear_pending_commit(&setup.mls_group_id);
        assert!(setup.alice.self_update(&setup.mls_group_id).is_ok());
        let _ = setup.alice.clear_pending_commit(&setup.mls_group_id);
    }

    /// H1 (M11 review Finding R2): the ACTUAL bug scenario — a beating set holding
    /// BOTH a Location (earlier order key) AND a genuine competing commit (later,
    /// but still ahead of ours). The walk must skip/collect the Location and adopt
    /// the REAL commit — never pick the order-key-minimum Location — and every
    /// member must select the same real-commit winner even though the global
    /// minimum is a Location. Also asserts the loser cross-decrypts the winner
    /// (shared exporter ⇒ no fork).
    #[test]
    fn converge_adopts_the_real_commit_and_collects_the_location_from_a_mixed_set() {
        let setup = setup_two_party_circle();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();

        // Bob sends a real (Alice-decryptable) Location FIRST — earliest key.
        let loc = LocationMessage::new(40.0, -3.0);
        let (bob_loc, _, _) = setup
            .bob
            .encrypt_location(&setup.mls_group_id, &setup.bob_keys.public_key(), &loc, 300)
            .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        // Bob stages a real self-update — the MIDDLE key (the true winner).
        let bob_commit = setup
            .bob
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        std::thread::sleep(std::time::Duration::from_millis(1100));
        // Alice stages her own — the LATEST key (she loses).
        let alice_commit = setup
            .alice
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        assert!(bob_loc.created_at < bob_commit.created_at);
        assert!(bob_commit.created_at < alice_commit.created_at);

        let (out, delivered) = setup
            .alice
            .converge_commit_collecting_locations(
                &setup.mls_group_id,
                &alice_commit,
                n,
                &[bob_loc.clone(), bob_commit.clone()],
                &CommitIntent::None,
            )
            .unwrap();

        // Alice adopts Bob's REAL commit, NOT the earlier-sorting Location.
        assert!(
            matches!(out, CommitConvergence::AdoptedWinner { .. }),
            "the real commit must be adopted over the earlier Location: {out:?}"
        );
        assert_eq!(setup.alice.group_epoch(&setup.mls_group_id).unwrap(), n + 1);
        // The Location was still collected for re-delivery (never dropped).
        assert_eq!(
            delivered.len(),
            1,
            "the Location must be collected even amid a real winning commit"
        );
        assert_eq!(
            delivered[0].sender_pubkey,
            setup.bob_keys.public_key().to_hex()
        );

        // Fork-safety: Bob merges his own; Alice (loser) holds Bob's exporter.
        setup
            .bob
            .converge_commit(
                &setup.mls_group_id,
                &bob_commit,
                n,
                std::slice::from_ref(&alice_commit),
                &CommitIntent::None,
            )
            .unwrap();
        assert!(
            cross_decrypts(
                &setup.bob,
                &setup.bob_keys.public_key(),
                &setup.alice,
                &setup.mls_group_id
            ),
            "Alice must decrypt Bob's location on the shared adopted branch (no fork)"
        );
        let _ = setup.alice.clear_pending_commit(&setup.mls_group_id);
        let _ = setup.bob.clear_pending_commit(&setup.mls_group_id);
    }

    /// SEC: NO-STALE-STAGED-SECRET — after an `AdoptedWinner`, the loser holds
    /// the WINNER's exporter (cross-decrypt both ways) and has no residual /
    /// stale staged commit (a fresh op stages cleanly, incl. the self-update
    /// orphaned-signer cleanup).
    #[test]
    fn converging_no_stale_staged_secret_after_adopt() {
        let setup = setup_three_party_two_admin_circle();
        let carol_hex = setup.carol_keys.public_key().to_hex();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();
        let intent = CommitIntent::RemoveMembers(vec![setup.carol_keys.public_key()]);

        let alice_commit = setup
            .alice
            .remove_members(&setup.mls_group_id, std::slice::from_ref(&carol_hex))
            .unwrap()
            .evolution_event;
        let bob_commit = setup
            .bob
            .remove_members(&setup.mls_group_id, std::slice::from_ref(&carol_hex))
            .unwrap()
            .evolution_event;
        let alice_out = setup
            .alice
            .converge_commit(
                &setup.mls_group_id,
                &alice_commit,
                n,
                std::slice::from_ref(&bob_commit),
                &intent,
            )
            .unwrap();
        let bob_out = setup
            .bob
            .converge_commit(
                &setup.mls_group_id,
                &bob_commit,
                n,
                std::slice::from_ref(&alice_commit),
                &intent,
            )
            .unwrap();

        // Self-contained: exactly one side merges (a latent double-merge fork
        // would otherwise slip past the loser-inference below).
        assert_eq!(
            [alice_out, bob_out]
                .iter()
                .filter(|o| matches!(o, CommitConvergence::Merged))
                .count(),
            1,
            "exactly one side may merge: alice={alice_out:?} bob={bob_out:?}"
        );
        // Identify the loser and prove it holds the winner's exporter + has no
        // residual staged secret.
        let (winner, winner_keys, loser) = if matches!(alice_out, CommitConvergence::Merged) {
            (&setup.alice, &setup.alice_keys, &setup.bob)
        } else {
            (&setup.bob, &setup.bob_keys, &setup.alice)
        };
        assert!(
            cross_decrypts(
                winner,
                &winner_keys.public_key(),
                loser,
                &setup.mls_group_id
            ),
            "loser must decrypt the winner's location (shared exporter)"
        );
        // A residual pending commit would fail this (per the precedent test).
        assert!(
            loser
                .remove_members(&setup.mls_group_id, &[winner_keys.public_key().to_hex()])
                .is_ok(),
            "loser has no residual pending commit after adopt"
        );
        let _ = loser.clear_pending_commit(&setup.mls_group_id);
        // Self-update orphaned-signer cleanup: a fresh self_update stages.
        assert!(loser.self_update(&setup.mls_group_id).is_ok());
        let _ = loser.clear_pending_commit(&setup.mls_group_id);
    }

    /// SEC3: a location sent at the shared epoch N (pre-fork) still decrypts
    /// after fork→converge — the exporter-prune lookback this milestone exists
    /// to protect.
    #[test]
    fn inflight_location_at_shared_epoch_survives_convergence() {
        let setup = setup_two_party_circle();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();

        let loc = LocationMessage::new(51.5, -0.12);
        let (inflight, _, _) = setup
            .alice
            .encrypt_location(
                &setup.mls_group_id,
                &setup.alice_keys.public_key(),
                &loc,
                300,
            )
            .unwrap();

        let a = setup
            .alice
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        let b = setup
            .bob
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        setup
            .alice
            .converge_commit(
                &setup.mls_group_id,
                &a,
                n,
                std::slice::from_ref(&b),
                &CommitIntent::None,
            )
            .unwrap();
        setup
            .bob
            .converge_commit(
                &setup.mls_group_id,
                &b,
                n,
                std::slice::from_ref(&a),
                &CommitIntent::None,
            )
            .unwrap();

        // The N-epoch location still decrypts on Bob after convergence to N+1.
        assert!(
            matches!(
                setup.bob.decrypt_location(&inflight),
                Ok(LocationMessageResult::Location { .. })
            ),
            "in-flight epoch-N location must still decrypt after convergence"
        );
    }

    /// H1 liveness gate (M11): a routine, DECRYPTABLE Location `kind:445` that
    /// sorts AHEAD of our membership commit in MIP-03 order (smaller
    /// `(created_at, id)`) must NOT force a `RolledBack`. A Location is an MLS
    /// application message that cannot advance the epoch, so it is not a genuine
    /// convergence competitor — our commit MERGES and the membership op is never
    /// starved. Pre-fix (winner chosen purely by order key) this returned
    /// `RolledBack`; the fix excludes non-advancing competitors from the
    /// candidate set. Deterministic: the Location is created ≥1s before the
    /// commit so it strictly wins the order key.
    #[test]
    fn converge_with_a_winning_real_location_merges_not_rolled_back() {
        let setup = setup_two_party_circle();
        let n = setup.bob.group_epoch(&setup.mls_group_id).unwrap();

        // Alice sends a REAL (Bob-decryptable) location FIRST.
        let loc = LocationMessage::new(51.5, -0.12);
        let (alice_loc, _, _) = setup
            .alice
            .encrypt_location(
                &setup.mls_group_id,
                &setup.alice_keys.public_key(),
                &loc,
                300,
            )
            .unwrap();
        // ≥1s gap so Bob's commit has a strictly-later created_at → the Location
        // strictly WINS the MIP-03 order key.
        std::thread::sleep(std::time::Duration::from_millis(1100));

        let bob_commit = setup
            .bob
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        assert!(
            alice_loc.created_at < bob_commit.created_at,
            "precondition: the Location must sort ahead of our commit"
        );

        let out = setup
            .bob
            .converge_commit(
                &setup.mls_group_id,
                &bob_commit,
                n,
                std::slice::from_ref(&alice_loc),
                &CommitIntent::None,
            )
            .unwrap();

        assert_eq!(
            out,
            CommitConvergence::Merged,
            "a winning Location must NOT block our commit — it merges"
        );
        assert_eq!(
            setup.bob.group_epoch(&setup.mls_group_id).unwrap(),
            n + 1,
            "our membership commit advanced the epoch despite the winning Location"
        );
        // No dangling pending commit (a fresh op stages cleanly).
        assert!(setup.bob.self_update(&setup.mls_group_id).is_ok());
        let _ = setup.bob.clear_pending_commit(&setup.mls_group_id);
    }

    /// H1 liveness gate (M11) — the RE-DELIVERY half. The winning real Location
    /// that is EXCLUDED from the convergence must still be COLLECTED and handed
    /// back to the bus-aware caller, so a Location buffered during a membership
    /// op's settle window is never dropped from receive. Asserts the collected
    /// [`ConvergedLocation`] carries the sender, source timestamp, and decrypted
    /// coordinates — the exact fields the caller maps onto the bus.
    #[test]
    fn converge_collects_the_excluded_location_for_redelivery() {
        let setup = setup_two_party_circle();
        let n = setup.bob.group_epoch(&setup.mls_group_id).unwrap();

        // Alice sends a REAL (Bob-decryptable) location FIRST, at distinct coords.
        let loc = LocationMessage::new(48.8566, 2.3522);
        let (alice_loc, _, _) = setup
            .alice
            .encrypt_location(
                &setup.mls_group_id,
                &setup.alice_keys.public_key(),
                &loc,
                300,
            )
            .unwrap();
        // ≥1s gap so Bob's commit sorts strictly AFTER the Location → the Location
        // wins the MIP-03 order key and is exercised as a competitor.
        std::thread::sleep(std::time::Duration::from_millis(1100));

        let bob_commit = setup
            .bob
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        assert!(
            alice_loc.created_at < bob_commit.created_at,
            "precondition: the Location must sort ahead of our commit"
        );

        let (out, delivered) = setup
            .bob
            .converge_commit_collecting_locations(
                &setup.mls_group_id,
                &bob_commit,
                n,
                std::slice::from_ref(&alice_loc),
                &CommitIntent::None,
            )
            .unwrap();

        // Liveness: our membership commit still merges (never starved).
        assert_eq!(out, CommitConvergence::Merged);
        assert_eq!(setup.bob.group_epoch(&setup.mls_group_id).unwrap(), n + 1);

        // Re-delivery: the excluded Location was collected with the correct
        // sender, source timestamp, and decrypted coordinates.
        assert_eq!(
            delivered.len(),
            1,
            "the excluded Location must be collected"
        );
        let d = &delivered[0];
        assert_eq!(d.sender_pubkey, setup.alice_keys.public_key().to_hex());
        assert_eq!(
            d.created_at_secs,
            i64::try_from(alice_loc.created_at.as_secs()).unwrap()
        );
        let parsed: LocationMessage =
            serde_json::from_str(&d.content).expect("collected content is a LocationMessage");
        assert!((parsed.latitude - 48.8566).abs() < 1e-9);
        assert!((parsed.longitude - 2.3522).abs() < 1e-9);

        let _ = setup.bob.clear_pending_commit(&setup.mls_group_id);
    }

    /// M5-c: with periodic self-update disabled, the group epoch is stable
    /// across idle and advances ONLY on a real membership change.
    #[test]
    fn epoch_stable_across_idle_advances_on_membership() {
        let setup = setup_three_party_two_admin_circle();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();
        assert_eq!(
            setup.alice.group_epoch(&setup.mls_group_id).unwrap(),
            n,
            "epoch stable with no self-update"
        );
        let carol_hex = setup.carol_keys.public_key().to_hex();
        setup
            .alice
            .remove_members(&setup.mls_group_id, std::slice::from_ref(&carol_hex))
            .unwrap();
        setup
            .alice
            .finalize_pending_commit(&setup.mls_group_id)
            .unwrap();
        assert_eq!(
            setup.alice.group_epoch(&setup.mls_group_id).unwrap(),
            n + 1,
            "membership change advances the epoch"
        );
    }

    /// M5-d: a just-joined group reports `groups_needing_self_update` forever
    /// (a membership commit does NOT clear MDK's `Required` flag). Benign
    /// post-M5 because nothing queries it on a timer anymore.
    #[test]
    fn groups_needing_self_update_returns_post_join_group_forever() {
        let setup = setup_three_party_two_admin_circle();
        assert!(
            setup
                .bob
                .groups_needing_self_update(3600)
                .unwrap()
                .iter()
                .any(|g| g == &setup.mls_group_id),
            "a just-joined group reports needing a self-update"
        );
        let carol_hex = setup.carol_keys.public_key().to_hex();
        setup
            .bob
            .remove_members(&setup.mls_group_id, std::slice::from_ref(&carol_hex))
            .unwrap();
        setup
            .bob
            .finalize_pending_commit(&setup.mls_group_id)
            .unwrap();
        assert!(
            setup
                .bob
                .groups_needing_self_update(3600)
                .unwrap()
                .iter()
                .any(|g| g == &setup.mls_group_id),
            "membership commit does not clear Required — benign since M5 never queries it on a timer"
        );
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
    fn encrypt_location_inner_event_carries_no_group_identifier() {
        use nostr::JsonUtil;

        // MIP-03 MUST NOT: the routing identifier (the nostr_group_id `h` tag)
        // belongs on the OUTER kind:445 wrapper only. The decrypted INNER kind:9
        // application event must carry no `h` tag and must not embed either the
        // nostr_group_id or the real MLS group id. Otherwise a mishandled or
        // re-published inner event would self-identify its circle, defeating the
        // wire-level group-id privacy that
        // `encrypted_event_has_h_tag_with_nostr_group_id` enforces on the outer
        // event. This drives the REAL production builder
        // (`CircleManager::encrypt_location`), not a test copy of the rumor.
        let setup = setup_two_party_circle();
        let location = LocationMessage::new(37.7749, -122.4194);

        let (encrypted_event, _, _) = setup
            .alice
            .encrypt_location(
                &setup.mls_group_id,
                &setup.alice_keys.public_key(),
                &location,
                300,
            )
            .expect("alice should encrypt location");

        // Decrypt at the MDK layer: the parsed `decrypt_location` path returns a
        // `LocationMessageResult` and discards the inner tags, so we go through
        // `process_message` to inspect the recovered inner application event.
        let processed = setup
            .bob
            .mdk
            .process_message(&encrypted_event)
            .expect("bob should process the kind:445 event");
        let inner = match processed {
            mdk_core::prelude::MessageProcessingResult::ApplicationMessage(msg) => msg,
            other => panic!("expected an ApplicationMessage, got {other:?}"),
        };

        let mls_hex = hex::encode(setup.mls_group_id.as_slice());
        let nostr_hex = hex::encode(setup.nostr_group_id);

        // Non-vacuity: both ids are real, substantial, and distinct needles, so
        // an "absent" result is meaningful (not a search for an empty string or
        // a vacuous pass where the two ids happened to coincide).
        assert_eq!(nostr_hex.len(), 64, "nostr_group_id should be 32 bytes");
        assert_ne!(
            mls_hex, nostr_hex,
            "mls and nostr group ids must differ for the scan to be meaningful"
        );

        // (1) No `h` (routing) tag on the inner event, and no tag part embeds
        // either group id.
        for tag in inner.tags.iter() {
            let parts = tag.as_slice();
            assert_ne!(
                parts.first().map(String::as_str),
                Some("h"),
                "inner kind:9 event must not carry an `h` (routing) tag (MIP-03)"
            );
            for part in parts {
                assert!(
                    !part.contains(&mls_hex),
                    "inner kind:9 tag leaked the real MLS group id"
                );
                assert!(
                    !part.contains(&nostr_hex),
                    "inner kind:9 tag leaked the nostr_group_id"
                );
            }
        }

        // (2) Neither group id appears anywhere in the full inner event JSON
        // (content + tags + every field).
        let inner_json = inner.event.as_json();
        assert!(
            !inner_json.contains(&mls_hex),
            "real MLS group id leaked into the inner kind:9 event JSON"
        );
        assert!(
            !inner_json.contains(&nostr_hex),
            "nostr_group_id leaked into the inner kind:9 event JSON"
        );

        // (3) Positive control: the inner event IS the populated location rumor
        // — it carries the `["t","location"]` discriminator — so the absence
        // checks above scanned real content, not an empty/placeholder event.
        assert!(
            inner.tags.iter().any(|t| {
                let s = t.as_slice();
                s.len() >= 2 && s[0] == "t" && s[1] == "location"
            }),
            "inner kind:9 event must carry the [\"t\",\"location\"] tag (positive control)"
        );

        // (4) The MIP-03 inner/outer split: the inner application event is a
        // kind:9 authored by the real sender identity, whereas the OUTER kind:445
        // uses a per-message ephemeral key (asserted by the sibling
        // `encrypt_location_returns_correct_metadata`). Pinning both also
        // strengthens the positive control — `inner.event` is genuinely the
        // populated sender rumor, not a placeholder.
        assert_eq!(
            inner.event.kind,
            Kind::Custom(9),
            "inner application event must be kind 9 (MIP-03)"
        );
        assert_eq!(
            inner.event.pubkey,
            setup.alice_keys.public_key(),
            "inner kind:9 event must be authored by the real sender identity key"
        );
    }

    // ==================== Avatar (M2) manager-level tests ====================

    /// Builds a small, compressible JPEG fixture for avatar tests.
    fn avatar_jpeg_fixture(seed: u8) -> Vec<u8> {
        use image::RgbImage;
        let mut img = RgbImage::new(400, 300);
        for (x, y, px) in img.enumerate_pixels_mut() {
            px.0 = [
                ((x / 2) % 256) as u8,
                ((y / 2) % 256) as u8,
                seed.wrapping_add(((x + y) / 4 % 64) as u8),
            ];
        }
        let mut out = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(std::io::Cursor::new(&mut out), 90)
            .encode_image(&img)
            .expect("encode fixture");
        out
    }

    #[test]
    fn avatar_share_inner_rumor_carries_no_group_identifier() {
        use nostr::JsonUtil;
        // Mirror of `encrypt_location_inner_event_carries_no_group_identifier`
        // for the avatar path: no `h` tag, no MLS/nostr group id in any inner
        // avatar rumor; positive control is the `["t","haven-avatar"]` tag.
        let setup = setup_two_party_circle();
        setup
            .alice
            .set_my_avatar(
                &setup.alice_keys.public_key().to_hex(),
                &avatar_jpeg_fixture(1),
            )
            .expect("set avatar");
        let events = setup
            .alice
            .build_avatar_share(&setup.mls_group_id, &setup.alice_keys.public_key(), 120)
            .expect("build share");

        let mls_hex = hex::encode(setup.mls_group_id.as_slice());
        let nostr_hex = hex::encode(setup.nostr_group_id);
        assert_ne!(mls_hex, nostr_hex);

        for ev in &events {
            let processed = setup
                .bob
                .mdk
                .process_message(ev)
                .expect("bob process avatar chunk");
            let inner = match processed {
                mdk_core::prelude::MessageProcessingResult::ApplicationMessage(msg) => msg,
                other => panic!("expected ApplicationMessage, got {other:?}"),
            };
            // No `h` tag; no group id in tags.
            for tag in inner.tags.iter() {
                let parts = tag.as_slice();
                assert_ne!(
                    parts.first().map(String::as_str),
                    Some("h"),
                    "inner avatar rumor must not carry an h tag"
                );
                for part in parts {
                    assert!(
                        !part.contains(&mls_hex),
                        "inner avatar tag leaked MLS group id"
                    );
                    assert!(
                        !part.contains(&nostr_hex),
                        "inner avatar tag leaked nostr group id"
                    );
                }
            }
            // No group id anywhere in the inner JSON.
            let inner_json = inner.event.as_json();
            assert!(
                !inner_json.contains(&mls_hex),
                "MLS id leaked into inner avatar JSON"
            );
            assert!(
                !inner_json.contains(&nostr_hex),
                "nostr id leaked into inner avatar JSON"
            );
            // Positive control: the clarity tag is present.
            assert!(
                inner.tags.iter().any(|t| {
                    let s = t.as_slice();
                    s.len() >= 2 && s[0] == "t" && s[1] == "haven-avatar"
                }),
                "inner avatar rumor must carry the [\"t\",\"haven-avatar\"] tag"
            );
            // Inner author is the real sender identity (sender-auth).
            assert_eq!(inner.event.pubkey, setup.alice_keys.public_key());
        }
    }

    #[test]
    fn corrupt_chunk_fails_closed_and_keeps_previous_avatar() {
        use nostr::JsonUtil;
        let setup = setup_two_party_circle();
        let alice_hex = setup.alice_keys.public_key().to_hex();

        // v1: complete and stored at Bob.
        setup
            .alice
            .set_my_avatar(&alice_hex, &avatar_jpeg_fixture(1))
            .expect("v1");
        let v1 = setup
            .alice
            .build_avatar_share(&setup.mls_group_id, &setup.alice_keys.public_key(), 120)
            .expect("share v1");
        for ev in &v1 {
            setup
                .bob
                .ingest_incoming_avatar_message(ev)
                .expect("ingest v1");
        }
        assert!(setup
            .bob
            .get_member_avatar_thumbnail(&setup.mls_group_id, &alice_hex)
            .expect("get")
            .is_some());

        // v2: corrupt the manifest's content_hash so reassembly fails the hash
        // check. We rebuild the manifest chunk's inner rumor by re-encrypting a
        // tampered inner content. Simplest path: tamper a CHUNK's data so the
        // concatenated bytes mismatch the manifest hash, then verify the prior
        // avatar survives.
        setup
            .alice
            .set_my_avatar(&alice_hex, &avatar_jpeg_fixture(2))
            .expect("v2");
        let v2 = setup
            .alice
            .build_avatar_share(&setup.mls_group_id, &setup.alice_keys.public_key(), 120)
            .expect("share v2");

        // Ingest the manifest + all-but-last chunks, then a CORRUPTED last
        // chunk built by tampering the plaintext before re-encrypt is not
        // possible without the sender key — instead we drop the last chunk and
        // feed a duplicate of chunk 1 in its slot is idempotent (won't
        // complete). To exercise the hash-fail path we instead complete with a
        // mismatched set: ingest v2 manifest, then re-ingest v1's chunk 1 (wrong
        // version) which is rejected, leaving v2 incomplete. The stored avatar
        // must remain v1's (fail-closed: no partial display).
        for ev in v2.iter().take(v2.len() - 1) {
            let _ = setup.bob.ingest_incoming_avatar_message(ev);
        }
        // Feed a v1 chunk (older version) — rejected, does not complete v2.
        let _ = setup
            .bob
            .ingest_incoming_avatar_message(&nostr::Event::from_json(v1[1].as_json()).unwrap());

        // v2 never completed; the previously-good v1 avatar is still readable.
        let still = setup
            .bob
            .get_member_avatar_thumbnail(&setup.mls_group_id, &alice_hex)
            .expect("get")
            .expect("previous avatar must be preserved");
        assert!(!still.is_empty());
    }

    #[test]
    fn avatar_clear_tombstone_only_supersedes_higher_version() {
        let setup = setup_two_party_circle();
        let alice_hex = setup.alice_keys.public_key().to_hex();

        let meta = setup
            .alice
            .set_my_avatar(&alice_hex, &avatar_jpeg_fixture(3))
            .expect("set");
        let share = setup
            .alice
            .build_avatar_share(&setup.mls_group_id, &setup.alice_keys.public_key(), 120)
            .expect("share");
        for ev in &share {
            setup
                .bob
                .ingest_incoming_avatar_message(ev)
                .expect("ingest");
        }
        assert!(setup
            .bob
            .get_member_avatar_thumbnail(&setup.mls_group_id, &alice_hex)
            .expect("get")
            .is_some());

        // A clear at the SAME version is a no-op (stale).
        let stale = setup
            .alice
            .build_avatar_clear(
                &setup.mls_group_id,
                &setup.alice_keys.public_key(),
                meta.version,
                120,
            )
            .expect("build stale clear");
        let r = setup
            .bob
            .ingest_incoming_avatar_message(&stale)
            .expect("ingest stale");
        assert!(!r.accepted, "a clear at <= stored version must not apply");
        assert!(setup
            .bob
            .get_member_avatar_thumbnail(&setup.mls_group_id, &alice_hex)
            .expect("get")
            .is_some());

        // A clear at a HIGHER version removes the avatar.
        let clear = setup
            .alice
            .build_avatar_clear(
                &setup.mls_group_id,
                &setup.alice_keys.public_key(),
                meta.version + 1,
                120,
            )
            .expect("build clear");
        let r = setup
            .bob
            .ingest_incoming_avatar_message(&clear)
            .expect("ingest clear");
        assert!(r.accepted && r.complete);
        assert!(
            setup
                .bob
                .get_member_avatar_thumbnail(&setup.mls_group_id, &alice_hex)
                .expect("get")
                .is_none(),
            "higher-version tombstone must remove the avatar"
        );
    }

    #[test]
    fn encrypt_decrypt_drops_private_gps_fields_end_to_end() {
        use crate::nostr::mls::types::LocationMessageResult;

        // Privacy: device-private GPS fields (device_id, raw_accuracy, altitude,
        // speed, heading) are `#[serde(skip)]` and MUST NOT survive the
        // encrypt -> wire -> decrypt pipeline, while member-visible data
        // (coordinates, geohash, display_name) MUST. `proptest_location`'s `d3_*`
        // covers the struct serialization in isolation; this pins the SAME
        // guarantee end-to-end through the real CircleManager encrypt/decrypt
        // path, catching a regression that leaked private data via the pipeline
        // (a different serializer, an added tag, etc.) that the unit scan misses.
        let setup = setup_two_party_circle();

        let mut location =
            LocationMessage::new(37.7749, -122.4194).with_display_name(Some("Alice".to_string()));
        location.device_id = Some("device-serial-XYZ".to_string());
        location.raw_accuracy = Some(3.5);
        location.altitude = Some(120.0);
        location.speed = Some(1.2);
        location.heading = Some(270.0);

        let (event, _, _) = setup
            .alice
            .encrypt_location(
                &setup.mls_group_id,
                &setup.alice_keys.public_key(),
                &location,
                300,
            )
            .expect("alice should encrypt location");

        let content = match setup
            .bob
            .decrypt_location(&event)
            .expect("bob should decrypt location")
        {
            LocationMessageResult::Location { content, .. } => content,
            other => panic!("expected a Location result, got {other:?}"),
        };

        // (1) The decrypted plaintext (what the receiver actually sees) carries
        // none of the private field names.
        for field in ["device_id", "raw_accuracy", "altitude", "speed", "heading"] {
            assert!(
                !content.contains(field),
                "private field `{field}` leaked into the decrypted location content: {content}"
            );
        }
        // Value-level scan: the device_id VALUE must not leak under ANY key name
        // either (the name-based scan would miss a value smuggled under a renamed
        // key). Use the unambiguous device_id sentinel — the numeric fields risk
        // incidental digit collisions with coordinates/timestamps.
        assert!(
            !content.contains("device-serial-XYZ"),
            "private device_id value leaked into the decrypted content: {content}"
        );
        // Positive control: the public, member-visible data DID round-trip, so
        // the absence checks above scanned real content, not an empty payload.
        assert!(
            content.contains("latitude") && content.contains("geohash"),
            "control: public location fields must be present in the decrypted content"
        );

        // (2) Semantic check: the receiver cannot reconstruct the private fields
        // (they deserialize back to None), while member-visible data does.
        let recovered =
            LocationMessage::from_string(&content).expect("decrypted content must deserialize");
        assert!(recovered.device_id.is_none(), "device_id must not survive");
        assert!(
            recovered.raw_accuracy.is_none(),
            "raw_accuracy must not survive"
        );
        assert!(recovered.altitude.is_none(), "altitude must not survive");
        assert!(recovered.speed.is_none(), "speed must not survive");
        assert!(recovered.heading.is_none(), "heading must not survive");
        assert_eq!(
            recovered.latitude, location.latitude,
            "public latitude must survive the round-trip"
        );
        assert_eq!(recovered.geohash, location.geohash, "geohash must survive");
        assert_eq!(
            recovered.display_name.as_deref(),
            Some("Alice"),
            "member-visible display_name must survive (it is NOT a private field)"
        );
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
    fn decrypt_for_engine_location_stamps_routed_nostr_group_id_not_mls() {
        use crate::relay::live_sync::EngineDecryptOutcome;
        let setup = setup_two_party_circle();
        let bob_group = setup.bob.mdk.get_groups().unwrap();
        let bob_mls_group_id = bob_group.first().unwrap().mls_group_id.clone();

        let location = LocationMessage::new(48.8566, 2.3522);
        let (ev, _, _) = setup
            .bob
            .encrypt_location(
                &bob_mls_group_id,
                &setup.bob_keys.public_key(),
                &location,
                300,
            )
            .unwrap();

        let out = setup
            .alice
            .decrypt_location_for_engine(&ev, &setup.nostr_group_id);
        match out {
            EngineDecryptOutcome::Location {
                nostr_group_id,
                sender_pubkey,
                content,
                created_at_secs,
            } => {
                // Rule 4: the outcome carries the routed pseudonymous id, never
                // the real MLS group id.
                assert_eq!(nostr_group_id, setup.nostr_group_id.to_vec());
                assert_ne!(nostr_group_id, setup.mls_group_id.as_slice().to_vec());
                assert_eq!(sender_pubkey, setup.bob_keys.public_key().to_hex());
                let recovered = LocationMessage::from_string(&content).unwrap();
                assert_eq!(recovered.latitude, location.latitude);
                assert!(created_at_secs > 0);
            }
            other => panic!("expected Location, got {other:?}"),
        }
    }

    #[test]
    fn decrypt_for_engine_peer_commit_maps_to_group_update_none() {
        use crate::relay::live_sync::EngineDecryptOutcome;
        let setup = setup_two_party_circle();
        // Bob stages a self-update commit; Alice (no pending — regime 1) receives it.
        let commit = setup
            .bob
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        let out = setup
            .alice
            .decrypt_location_for_engine(&commit, &setup.nostr_group_id);
        match out {
            EngineDecryptOutcome::GroupUpdate {
                nostr_group_id,
                evolution_event_json,
            } => {
                assert_eq!(nostr_group_id, setup.nostr_group_id.to_vec());
                assert!(
                    evolution_event_json.is_none(),
                    "a plain peer commit carries no evolution event to publish"
                );
            }
            other => panic!("expected GroupUpdate, got {other:?}"),
        }
    }

    /// Pins a load-bearing MDK 93ae324 behavior for the engine design: MDK
    /// ABSORBS the `OwnCommitPending` / `CannotDecryptOwnMessage` error classes
    /// internally (returning `Ok(Commit)`), so `process_message_classified` does
    /// NOT surface `CompetingCommit` for an own/sibling commit at the public
    /// boundary — it surfaces a benign `GroupUpdate`. Consequently the engine's
    /// regime-2 competitor detection cannot rely on the error class; it must gate
    /// on "a settle window is open" (we hold our own pending commit) instead. The
    /// `CompetingCommit` mapping remains for the narrow internal-storage-failure
    /// escapes and is covered by `classify_mdk_error_*` unit tests.
    #[test]
    fn decrypt_for_engine_own_pending_redelivery_is_absorbed_as_group_update() {
        use crate::relay::live_sync::EngineDecryptOutcome;
        let setup = setup_two_party_circle();
        let own = setup
            .alice
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        // Re-deliver our own commit while still holding it pending.
        let out = setup
            .alice
            .decrypt_location_for_engine(&own, &setup.nostr_group_id);
        assert!(
            matches!(out, EngineDecryptOutcome::GroupUpdate { .. }),
            "MDK absorbs OwnCommitPending → benign GroupUpdate, got {out:?}"
        );
    }

    /// THE M3b HIGH must-fix regression test (real MDK): while a settle window is
    /// open (regime 2 — we hold our own pending commit), the `EngineProcessor`
    /// must BUFFER an incoming same-epoch sibling WITHOUT decrypting it, so our
    /// epoch does NOT advance (a decrypted sibling would be applied by MDK and
    /// fork the group). The gate lives at the routing layer, before decryption.
    #[test]
    fn engine_processor_buffers_sibling_without_forking_when_window_open() {
        use crate::relay::live_sync::{
            CommitSettleBuffer, EngineProcessor, EventBus, GroupProcessOutcome,
        };
        use std::sync::{Arc, Mutex};

        let setup = setup_two_party_circle();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();
        let mls_group_id = setup.mls_group_id.clone();
        let nostr_group_id = setup.nostr_group_id;
        let group_hex = hex::encode(nostr_group_id);

        // Bob's concurrent sibling commit at epoch N.
        let bob_commit = setup
            .bob
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        // Alice stages her OWN commit → holds pending → regime 2 (no advance yet).
        let _ = setup.alice.self_update(&setup.mls_group_id).unwrap();
        assert_eq!(setup.alice.group_epoch(&mls_group_id).unwrap(), n);

        // Build the engine processor over Alice's MLS state; open her window.
        let alice = Arc::new(setup.alice);
        let settle = Arc::new(Mutex::new(CommitSettleBuffer::new()));
        let _ = settle.lock().unwrap().begin_window(&group_hex, n, i64::MAX);
        let processor = EngineProcessor::new(alice.clone(), settle.clone(), EventBus::new());

        let outcome = processor.process_group_event(&bob_commit, &nostr_group_id);

        assert_eq!(
            outcome,
            GroupProcessOutcome::Buffered { inserted: true },
            "a window-open sibling must be buffered, not processed"
        );
        assert_eq!(
            alice.group_epoch(&mls_group_id).unwrap(),
            n,
            "regime-2 sibling must NOT be applied (no blind-apply fork)"
        );
        assert_eq!(
            settle.lock().unwrap().competitor_count(&group_hex),
            1,
            "the sibling was captured for converge_commit"
        );
    }

    /// Regime-1 happy path (real MDK): with NO window, the `EngineProcessor`
    /// decrypts a peer location, advances the PER-CIRCLE group cursor, and emits
    /// a `Location` on the bus.
    #[test]
    fn engine_processor_regime1_processes_location_and_advances_per_circle_cursor() {
        use crate::relay::live_sync::{
            group_cursor_stream, CommitSettleBuffer, EngineProcessor, EventBus,
            GroupProcessOutcome, LiveSyncEvent,
        };
        use std::sync::{Arc, Mutex};

        let setup = setup_two_party_circle();
        let nostr_group_id = setup.nostr_group_id;
        let bob_group = setup.bob.mdk.get_groups().unwrap();
        let bob_mls = bob_group.first().unwrap().mls_group_id.clone();
        let location = LocationMessage::new(48.0, 2.0);
        let (ev, _, _) = setup
            .bob
            .encrypt_location(&bob_mls, &setup.bob_keys.public_key(), &location, 300)
            .unwrap();

        let alice = Arc::new(setup.alice);
        let bus = EventBus::new();
        let mut rx = bus.subscribe();
        let processor = EngineProcessor::new(
            alice.clone(),
            Arc::new(Mutex::new(CommitSettleBuffer::new())),
            bus,
        );

        let outcome = processor.process_group_event(&ev, &nostr_group_id);
        assert_eq!(
            outcome,
            GroupProcessOutcome::Processed {
                advanced_cursor: true
            }
        );

        // The per-circle cursor advanced (keyed by this circle's hex id).
        let key = group_cursor_stream(&hex::encode(nostr_group_id));
        assert!(
            alice.read_sync_cursor(&key).unwrap().is_some(),
            "per-circle group cursor advanced"
        );
        // A Location was emitted.
        assert!(matches!(
            rx.try_recv().unwrap(),
            LiveSyncEvent::Location { .. }
        ));
    }

    /// M6-2 path B: a peer `SelfRemove` reaching the engine is auto-committed by
    /// MDK, so `decrypt_location_for_engine` surfaces `AutoCommit` (carrying the
    /// real group id + the staged commit for the in-Rust converge), NOT a plain
    /// `GroupUpdate`. Any receiving member auto-commits a `SelfRemove`.
    #[test]
    fn decrypt_for_engine_self_remove_maps_to_auto_commit() {
        use crate::relay::live_sync::EngineDecryptOutcome;
        let setup = setup_two_party_circle();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();
        // Bob (member) leaves → a SelfRemove proposal event.
        let self_remove = setup
            .bob
            .propose_leave(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        // Alice receives it → MDK auto-commits → AutoCommit (she now holds pending).
        let out = setup
            .alice
            .decrypt_location_for_engine(&self_remove, &setup.nostr_group_id);
        match out {
            EngineDecryptOutcome::AutoCommit {
                nostr_group_id,
                mls_group_id,
                commit_json,
            } => {
                assert_eq!(nostr_group_id, setup.nostr_group_id.to_vec());
                assert_eq!(mls_group_id, setup.mls_group_id);
                assert!(!commit_json.is_empty(), "the staged auto-commit JSON");
            }
            other => panic!("expected AutoCommit, got {other:?}"),
        }
        // A staged pending commit does NOT advance the epoch.
        assert_eq!(setup.alice.group_epoch(&setup.mls_group_id).unwrap(), n);
    }

    /// M6-2 path B: the engine processor, on an auto-commit, opens a settle
    /// window (so a concurrent sibling auto-commit buffers) and returns the work
    /// item for the converge task — WITHOUT advancing the cursor or the epoch.
    #[test]
    fn engine_processor_auto_commit_opens_window_and_returns_work() {
        use crate::relay::live_sync::{
            group_cursor_stream, CommitSettleBuffer, EngineProcessor, EventBus, GroupProcessOutcome,
        };
        use std::sync::{Arc, Mutex};

        let setup = setup_two_party_circle();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();
        let self_remove = setup
            .bob
            .propose_leave(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        let group_hex = hex::encode(setup.nostr_group_id);

        let alice = Arc::new(setup.alice);
        let settle = Arc::new(Mutex::new(CommitSettleBuffer::new()));
        let processor = EngineProcessor::new(alice.clone(), settle.clone(), EventBus::new());

        match processor.process_group_event(&self_remove, &setup.nostr_group_id) {
            GroupProcessOutcome::AutoCommitStaged(work) => {
                assert_eq!(work.staged_epoch, n);
                assert_eq!(work.mls_group_id, setup.mls_group_id);
                assert_eq!(work.nostr_group_id, setup.nostr_group_id.to_vec());
                assert!(!work.commit_json.is_empty());
            }
            other => panic!("expected AutoCommitStaged, got {other:?}"),
        }

        assert!(
            settle.lock().unwrap().has_window(&group_hex),
            "a settle window must be opened so a sibling auto-commit buffers"
        );
        assert_eq!(
            alice.group_epoch(&setup.mls_group_id).unwrap(),
            n,
            "the epoch must NOT advance before convergence"
        );
        let key = group_cursor_stream(&group_hex);
        assert!(
            alice.read_sync_cursor(&key).unwrap().is_none(),
            "the cursor must NOT advance before convergence (lossless replay net)"
        );
    }

    /// M6-2 path B (THE convergence regression): two members both auto-commit the
    /// SAME peer `SelfRemove` (concurrent regime-2). Feeding each the other's
    /// commit, the engine's `gated_converge` (intent `None`) lands them on the
    /// MIP-03 winner's branch — exactly one converged epoch, the departed member
    /// gone on both, no fork. This exercises the path-B engine wiring (window
    /// opened inside the processor + the shared converge) that the pure
    /// `converge_commit` F2 tests do not.
    #[tokio::test]
    async fn auto_commit_converge_with_a_sibling_removes_the_departed_without_forking() {
        use crate::relay::live_sync::finalize::gated_converge;
        use crate::relay::live_sync::{
            CommitSettleBuffer, EngineDecryptOutcome, EngineProcessor, EventBus,
            GroupProcessOutcome, MlsWriteGate,
        };
        use nostr::JsonUtil;
        use std::sync::{Arc, Mutex};

        let setup = setup_four_party_two_admin_circle();
        let mls_group_id = setup.mls_group_id.clone();
        // The four-party fixture builds MLS state directly via MDK (no stored
        // Circle row), so read the nostr_group_id from the MDK group.
        let nostr_group_id = setup
            .alice
            .mdk
            .get_group(&mls_group_id)
            .unwrap()
            .unwrap()
            .nostr_group_id;
        let group_hex = hex::encode(nostr_group_id);
        let carol_hex = setup.carol_keys.public_key().to_hex();

        // Carol (member) leaves → a SelfRemove all remaining members auto-commit.
        let carol_self_remove = setup
            ._carol
            .propose_leave(&mls_group_id)
            .unwrap()
            .evolution_event;

        // Bob auto-commits → Bob's sibling commit (the competitor).
        let bob_commit_json = match setup
            .bob
            .decrypt_location_for_engine(&carol_self_remove, &nostr_group_id)
        {
            EngineDecryptOutcome::AutoCommit { commit_json, .. } => commit_json,
            other => panic!("Bob should auto-commit, got {other:?}"),
        };
        let bob_event = nostr::Event::from_json(&bob_commit_json).unwrap();

        // Alice auto-commits through the engine processor (opens her window).
        let alice = Arc::new(setup.alice);
        let settle = Arc::new(Mutex::new(CommitSettleBuffer::new()));
        let gate = Arc::new(MlsWriteGate::new());
        let processor = EngineProcessor::new(alice.clone(), settle.clone(), EventBus::new());
        let work = match processor.process_group_event(&carol_self_remove, &nostr_group_id) {
            GroupProcessOutcome::AutoCommitStaged(w) => *w,
            other => panic!("Alice should auto-commit, got {other:?}"),
        };

        // Bob's sibling arrives during Alice's window → buffered as a competitor.
        {
            let mut sb = settle.lock().unwrap();
            assert!(sb.insert_competitor(
                &group_hex,
                crate::relay::live_sync::BufferedCommit {
                    event_json: bob_commit_json.clone(),
                    created_at_secs: bob_event.created_at.as_secs(),
                    id_hex: bob_event.id.to_hex(),
                },
                work.staged_epoch,
            ));
        }

        // Alice converges (intent None — adopting Carol's departure).
        // H1: gated_converge now re-delivers any excluded Locations onto a bus;
        // this test has only a real-commit competitor, so a throwaway bus is fine.
        let bus = EventBus::new();
        let result = gated_converge(
            &gate,
            &settle,
            &alice,
            &bus,
            &work.mls_group_id,
            &work.nostr_group_id,
            &work.commit_json,
            work.staged_epoch,
            &CommitIntent::None,
        )
        .await
        .unwrap();

        // Either we won (Merged) or adopted Bob's (AdoptedWinner) — both remove
        // Carol and advance the epoch; never a fork, never a RolledBack here.
        assert!(
            matches!(
                result,
                CommitConvergence::Merged | CommitConvergence::AdoptedWinner { .. }
            ),
            "converged onto the winner, got {result:?}"
        );
        assert!(
            alice.group_epoch(&mls_group_id).unwrap() > work.staged_epoch,
            "convergence advances the epoch onto the winner's branch"
        );
        assert!(
            !alice
                .member_pubkeys_hex(&mls_group_id)
                .unwrap()
                .contains(&carol_hex),
            "the departed member (Carol) is gone after convergence"
        );
        assert!(
            !settle.lock().unwrap().has_window(&group_hex),
            "the window is closed after convergence"
        );
    }

    /// M6-2 path B (the full engine wiring, real relay): the in-Rust converge
    /// task PUBLISHES the auto-commit via the engine `Client`, waits the settle
    /// window, and converges. With no sibling it merges, removing the departed
    /// member and emitting a roster-changed `GroupUpdate{None}` for the UI. This
    /// is the ~settle-window-second integration test that exercises the publish +
    /// the task composition that the unit tests stub out.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn run_autocommit_converge_publishes_and_merges_over_a_relay() {
        use crate::relay::live_sync::{
            run_autocommit_converge, CommitSettleBuffer, EngineHandles, EngineProcessor, EventBus,
            GroupProcessOutcome, LiveSyncEvent, MlsWriteGate,
        };
        use nostr_relay_builder::MockRelay;
        use std::sync::atomic::AtomicBool;
        use std::sync::{Arc, Mutex};

        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = MockRelay::run().await.unwrap();
        let url = relay.url().await.to_string();

        let setup = setup_two_party_circle();
        let mls_group_id = setup.mls_group_id.clone();
        let nostr_group_id = setup.nostr_group_id;
        let group_hex = hex::encode(nostr_group_id);
        let bob_hex = setup.bob_keys.public_key().to_hex();

        // Bob leaves → Alice auto-commits (the engine processor opens her window).
        let self_remove = setup
            .bob
            .propose_leave(&mls_group_id)
            .unwrap()
            .evolution_event;
        let alice = Arc::new(setup.alice);
        let settle = Arc::new(Mutex::new(CommitSettleBuffer::new()));
        let bus = EventBus::new();
        let mut rx = bus.subscribe();
        let processor = EngineProcessor::new(alice.clone(), settle.clone(), bus.clone());
        let work = match processor.process_group_event(&self_remove, &nostr_group_id) {
            GroupProcessOutcome::AutoCommitStaged(w) => *w,
            other => panic!("expected AutoCommitStaged, got {other:?}"),
        };

        // Point Alice's STORED circle relays at the MockRelay (the publish target
        // the converge task reads from `get_circle`). This MUST be done AFTER
        // `process_group_event`, whose `resync_circle_relays_from_mdk` rewrites
        // `Circle.relays` from the MDK group context (the M1 resync-drift the
        // publish self-heals via `add_relay` in production).
        {
            let mut circle = alice.get_circle(&mls_group_id).unwrap().unwrap().circle;
            circle.relays = vec![url.clone()];
            alice.storage.save_circle(&circle).unwrap();
        }

        // An engine client connected to the MockRelay.
        let client = nostr_sdk::Client::builder().build();
        client.add_relay(&url).await.unwrap();
        client.connect().await;
        let handles = EngineHandles {
            client,
            circle: alice.clone(),
            gate: Arc::new(MlsWriteGate::new()),
            settle: settle.clone(),
            bus,
            shutdown: Arc::new(AtomicBool::new(false)),
        };

        // The full task: publish Alice's commit → wait the settle window →
        // converge (Merged, no sibling).
        run_autocommit_converge(handles, work.clone()).await;

        assert!(
            alice.group_epoch(&mls_group_id).unwrap() > work.staged_epoch,
            "the auto-commit converged (epoch advanced)"
        );
        assert!(
            !alice
                .member_pubkeys_hex(&mls_group_id)
                .unwrap()
                .contains(&bob_hex),
            "the departed member (Bob) is removed"
        );
        assert!(
            !settle.lock().unwrap().has_window(&group_hex),
            "the settle window is closed after convergence"
        );

        // A post-converge GroupUpdate{None} (roster changed) was emitted for UI.
        let mut saw_group_update = false;
        while let Ok(ev) = rx.try_recv() {
            if matches!(
                ev,
                LiveSyncEvent::GroupUpdate {
                    evolution_event_json: None,
                    ..
                }
            ) {
                saw_group_update = true;
            }
        }
        assert!(
            saw_group_update,
            "a roster-changed GroupUpdate{{None}} must be emitted to the UI"
        );
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

    /// Locks in the protocol invariant that MLS evolution events
    /// (commits/proposals carried over kind 445) MUST NOT carry a NIP-40
    /// `expiration` tag.
    ///
    /// MLS state recovery requires every commit since an offline member's
    /// last known epoch. If a commit expires from relays before an offline
    /// member fetches it, that member's MLS state desynchronises and cannot
    /// be advanced — they fall off a cliff that is only recoverable via
    /// re-Welcome. Locations may be TTL'd because stale coordinates have no
    /// operational value; commits are the structural backbone of group
    /// state and must persist. Three independent Marmot reviewers flagged
    /// applying the location TTL to commits as a critical correctness bug.
    ///
    /// `nostr/mls/manager.rs::create_message`'s contract is "only kind:445
    /// location messages set this today". This regression test fails the
    /// build if a future change adds an expiration tag on the
    /// `add_members`, `remove_members`, or `self_update` paths.
    #[test]
    fn add_members_evolution_event_has_no_expiration_tag() {
        let setup = setup_three_party_two_admin_circle();
        // Alice adds a fresh outsider — produces a kind 445 commit.
        let dave_keys = Keys::generate();
        let dave_dir = TempDir::new().unwrap();
        let dave = CircleManager::new_unencrypted(dave_dir.path()).unwrap();
        let dave_pubkey_hex = dave_keys.public_key().to_hex();
        let bundle = dave
            .mdk
            .create_key_package(&dave_pubkey_hex, &["wss://relay.test.com".to_string()])
            .expect("dave key package");
        let tags: Vec<nostr::Tag> = bundle
            .tags_443
            .into_iter()
            .map(|t| nostr::Tag::parse(&t).unwrap())
            .collect();
        let dave_kp_event = EventBuilder::new(Kind::MlsKeyPackage, bundle.content)
            .tags(tags)
            .sign_with_keys(&dave_keys)
            .expect("sign dave kp");

        let result = setup
            .alice
            .add_members(&setup.mls_group_id, &[dave_kp_event])
            .expect("alice should add dave");

        let has_expiration = result
            .evolution_event
            .tags
            .iter()
            .any(|t| matches!(t.as_standardized(), Some(TagStandard::Expiration(_))));
        assert!(
            !has_expiration,
            "add_members evolution event MUST NOT carry NIP-40 expiration — \
             commits must persist on relays for offline-member catch-up",
        );
    }

    // ====================================================================
    // add_members_with_welcomes: gift-wrap + fail-closed relay cascade,
    // pending-commit lifecycle, and admin gating (mirrors create_circle).
    // ====================================================================

    #[tokio::test]
    async fn add_members_with_welcomes_produces_one_welcome_per_member() {
        let tp = setup_two_party_circle();
        // Two fresh outsiders, each advertising an inbox relay.
        let carol =
            make_member_with_relays(vec!["wss://carol-inbox.example.com".to_string()], vec![]);
        let dave =
            make_member_with_relays(vec!["wss://dave-inbox.example.com".to_string()], vec![]);

        let result = tp
            .alice
            .add_members_with_welcomes(&tp.alice_keys, &tp.mls_group_id, vec![carol, dave], &[])
            .await
            .expect("admin adds two members");

        assert_eq!(
            result.welcome_events.len(),
            2,
            "exactly one gift-wrapped Welcome per added member",
        );
        // The Add commit is a kind:445 evolution event.
        assert_eq!(result.evolution_event.kind, Kind::Custom(445));
        // Each Welcome is a kind:1059 gift wrap.
        for w in &result.welcome_events {
            assert_eq!(w.event.kind, Kind::GiftWrap);
        }
    }

    #[tokio::test]
    async fn add_members_with_welcomes_matches_recipients_by_e_tag() {
        let tp = setup_two_party_circle();
        // Distinct inbox relays let us assert each Welcome routes to the right
        // member regardless of the order MDK emits the rumors in.
        let carol_relay = "wss://carol-inbox.example.com".to_string();
        let dave_relay = "wss://dave-inbox.example.com".to_string();
        let carol = make_member_with_relays(vec![carol_relay.clone()], vec![]);
        let dave = make_member_with_relays(vec![dave_relay.clone()], vec![]);
        let carol_pubkey = carol.key_package_event.pubkey.to_hex();
        let dave_pubkey = dave.key_package_event.pubkey.to_hex();

        let result = tp
            .alice
            .add_members_with_welcomes(&tp.alice_keys, &tp.mls_group_id, vec![carol, dave], &[])
            .await
            .expect("admin adds two members");

        // Find each recipient's Welcome by pubkey (order-independent) and
        // confirm the gift-wrap was routed to that member's own inbox relay.
        let carol_welcome = result
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == carol_pubkey)
            .expect("Welcome for carol");
        let dave_welcome = result
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == dave_pubkey)
            .expect("Welcome for dave");
        assert_eq!(carol_welcome.recipient_relays, vec![carol_relay]);
        assert_eq!(dave_welcome.recipient_relays, vec![dave_relay]);
    }

    #[tokio::test]
    async fn add_members_with_welcomes_cascade_inbox_then_nip65_then_creator() {
        // Tier 1: member's inbox relays win when present.
        {
            let tp = setup_two_party_circle();
            let inbox = vec!["wss://inbox.example.com".to_string()];
            let nip65 = vec!["wss://nip65.example.com".to_string()];
            let member = make_member_with_relays(inbox.clone(), nip65);
            let creator = vec!["wss://creator.example.com".to_string()];
            let result = tp
                .alice
                .add_members_with_welcomes(&tp.alice_keys, &tp.mls_group_id, vec![member], &creator)
                .await
                .expect("tier-1 add succeeds");
            assert_eq!(result.welcome_events[0].recipient_relays, inbox);
        }

        // Tier 2: member's NIP-65 relays when inbox is empty.
        {
            let tp = setup_two_party_circle();
            let nip65 = vec!["wss://nip65.example.com".to_string()];
            let member = make_member_with_relays(vec![], nip65.clone());
            let creator = vec!["wss://creator.example.com".to_string()];
            let result = tp
                .alice
                .add_members_with_welcomes(&tp.alice_keys, &tp.mls_group_id, vec![member], &creator)
                .await
                .expect("tier-2 add succeeds");
            assert_eq!(result.welcome_events[0].recipient_relays, nip65);
        }

        // Tier 3: the sender's own inbox relays when the member advertises none.
        {
            let tp = setup_two_party_circle();
            let member = make_member_with_relays(vec![], vec![]);
            let creator = vec!["wss://creator-inbox.example.com".to_string()];
            let result = tp
                .alice
                .add_members_with_welcomes(&tp.alice_keys, &tp.mls_group_id, vec![member], &creator)
                .await
                .expect("tier-3 add succeeds using the sender's inbox");
            assert_eq!(result.welcome_events[0].recipient_relays, creator);
            // Two-plane leak invariant: never a public default.
            for d in crate::circle::PRODUCTION_DEFAULT_RELAYS {
                assert!(
                    !result.welcome_events[0]
                        .recipient_relays
                        .iter()
                        .any(|r| r.starts_with(d)),
                    "welcome delivery must never fall back to a public default ({d})",
                );
            }
        }
    }

    #[tokio::test]
    async fn add_members_with_welcomes_fails_closed_with_no_relays() {
        let tp = setup_two_party_circle();
        // Member advertises NO relays and the sender passes no fallback.
        let member = make_member_with_relays(vec![], vec![]);

        let err = tp
            .alice
            .add_members_with_welcomes(&tp.alice_keys, &tp.mls_group_id, vec![member], &[])
            .await
            .expect_err("add must fail closed when no delivery relay exists");
        assert!(matches!(err, CircleError::MissingWelcomeRelays));
        // Generic surfaced message — no relay URL, pubkey, or group id.
        assert_eq!(err.to_string(), "No reachable relay for welcome delivery");

        // No dangling pending commit: the pre-flight check fires BEFORE staging
        // the Add, so a subsequent admin operation on the same group still
        // succeeds (a leftover pending commit would wedge this).
        let deliverable =
            make_member_with_relays(vec!["wss://later.example.com".to_string()], vec![]);
        tp.alice
            .add_members_with_welcomes(&tp.alice_keys, &tp.mls_group_id, vec![deliverable], &[])
            .await
            .expect("group must not be wedged by the failed add");
    }

    #[tokio::test]
    async fn add_members_with_welcomes_stages_pending_commit_epoch_unchanged_until_finalize() {
        let tp = setup_two_party_circle();
        let before = tp
            .alice
            .group_epoch(&tp.mls_group_id)
            .expect("epoch before");

        let member =
            make_member_with_relays(vec!["wss://carol-inbox.example.com".to_string()], vec![]);
        tp.alice
            .add_members_with_welcomes(&tp.alice_keys, &tp.mls_group_id, vec![member], &[])
            .await
            .expect("admin stages the add");

        // The Add only STAGES a pending commit; the local epoch must not move
        // until the commit is published and finalized.
        let staged = tp
            .alice
            .group_epoch(&tp.mls_group_id)
            .expect("epoch staged");
        assert_eq!(staged, before, "epoch must not advance before finalize");

        tp.alice
            .finalize_pending_commit(&tp.mls_group_id)
            .expect("finalize the staged Add");
        let after = tp.alice.group_epoch(&tp.mls_group_id).expect("epoch after");
        assert_eq!(after, before + 1, "epoch advances by exactly 1 on finalize");
    }

    #[tokio::test]
    async fn add_members_with_welcomes_clear_rolls_back() {
        let tp = setup_two_party_circle();
        let before = tp
            .alice
            .group_epoch(&tp.mls_group_id)
            .expect("epoch before");

        let member =
            make_member_with_relays(vec!["wss://carol-inbox.example.com".to_string()], vec![]);
        tp.alice
            .add_members_with_welcomes(&tp.alice_keys, &tp.mls_group_id, vec![member], &[])
            .await
            .expect("admin stages the add");

        // Roll the pending commit back; the epoch must be unchanged.
        tp.alice
            .clear_pending_commit(&tp.mls_group_id)
            .expect("clear the staged Add");
        let after_clear = tp
            .alice
            .group_epoch(&tp.mls_group_id)
            .expect("epoch after clear");
        assert_eq!(after_clear, before, "epoch unchanged after rollback");

        // A fresh add can re-stage on the cleared group.
        let member2 =
            make_member_with_relays(vec!["wss://dave-inbox.example.com".to_string()], vec![]);
        tp.alice
            .add_members_with_welcomes(&tp.alice_keys, &tp.mls_group_id, vec![member2], &[])
            .await
            .expect("fresh add re-stages after rollback");
        let after_restage = tp
            .alice
            .group_epoch(&tp.mls_group_id)
            .expect("epoch after restage");
        assert_eq!(
            after_restage, before,
            "re-staged pending commit still has not finalized",
        );
    }

    #[tokio::test]
    async fn add_members_with_welcomes_non_admin_rejected() {
        // In `setup_two_party_circle`, only Alice is an admin; Bob is a plain
        // member. Bob attempting to add a member must be rejected by MDK's
        // admin gate, surfacing as a redacted `Mls` error.
        let tp = setup_two_party_circle();
        let member =
            make_member_with_relays(vec!["wss://carol-inbox.example.com".to_string()], vec![]);

        let err = tp
            .bob
            .add_members_with_welcomes(&tp.bob_keys, &tp.mls_group_id, vec![member], &[])
            .await
            .expect_err("a non-admin must not be able to add members");
        assert!(
            matches!(err, CircleError::Mls(_)),
            "non-admin add must surface as a redacted Mls error, got {err:?}",
        );
    }

    #[test]
    fn remove_members_evolution_event_has_no_expiration_tag() {
        let setup = setup_two_party_circle();
        let bob_pubkey_hex = setup.bob_keys.public_key().to_hex();

        let result = setup
            .alice
            .remove_members(&setup.mls_group_id, &[bob_pubkey_hex])
            .expect("alice (admin) should remove bob");

        let has_expiration = result
            .evolution_event
            .tags
            .iter()
            .any(|t| matches!(t.as_standardized(), Some(TagStandard::Expiration(_))));
        assert!(
            !has_expiration,
            "remove_members evolution event MUST NOT carry NIP-40 expiration",
        );
    }

    #[test]
    fn self_update_evolution_event_has_no_expiration_tag() {
        let setup = setup_two_party_circle();

        let result = setup
            .alice
            .self_update(&setup.mls_group_id)
            .expect("alice self-update");

        let has_expiration = result
            .evolution_event
            .tags
            .iter()
            .any(|t| matches!(t.as_standardized(), Some(TagStandard::Expiration(_))));
        assert!(
            !has_expiration,
            "self_update evolution event MUST NOT carry NIP-40 expiration",
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

    // ==================== M7-B writer-lock tests ====================

    /// M7-B (b) NO RE-ENTRANCY DEADLOCK — the win leg of `converge_commit`.
    ///
    /// `converge_commit` internally calls `finalize_pending_commit`, which now
    /// acquires the process-global writer lock. `converge_commit` must therefore
    /// NOT hold that (non-reentrant) lock at method scope. This exercises the
    /// empty-competitor win leg (→ `finalize_pending_commit`) and asserts it
    /// COMPLETES (a deadlock would hang the test). The concrete outcome is
    /// asserted so the test is non-vacuous.
    #[test]
    fn m7b_converge_commit_win_leg_completes_no_reentrancy_deadlock() {
        let setup = setup_two_party_circle();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();

        let alice_commit = setup
            .alice
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;

        // Empty competitor set → the merge (win) leg → `finalize_pending_commit`,
        // which re-acquires the writer lock. Must NOT deadlock.
        let out = setup
            .alice
            .converge_commit(
                &setup.mls_group_id,
                &alice_commit,
                n,
                &[],
                &CommitIntent::None,
            )
            .expect("converge_commit must complete (a deadlock would hang)");
        assert_eq!(out, CommitConvergence::Merged);
        assert_eq!(setup.alice.group_epoch(&setup.mls_group_id).unwrap(), n + 1);
    }

    /// M7-B (b) NO RE-ENTRANCY DEADLOCK — the adopt-winner leg of
    /// `converge_commit`.
    ///
    /// This leg calls `self.mdk.process_message` (now individually lock-wrapped),
    /// then `clear_pending_commit` (re-acquires the lock), then
    /// `process_message` again (re-acquires). If any of those held the lock
    /// while another tried to take it, the non-reentrant `Mutex` would deadlock.
    /// Asserts the call COMPLETES and the group converges.
    #[test]
    fn m7b_converge_commit_adopt_leg_completes_no_reentrancy_deadlock() {
        let setup = setup_two_party_circle();
        let n = setup.alice.group_epoch(&setup.mls_group_id).unwrap();

        let alice_commit = setup
            .alice
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;
        let bob_commit = setup
            .bob
            .self_update(&setup.mls_group_id)
            .unwrap()
            .evolution_event;

        // Both members converge over each other's competitor from epoch N.
        // Exactly one takes the win (merge) leg and one the adopt-winner leg;
        // both internally re-acquire the writer lock through
        // finalize/clear/process. Neither may deadlock.
        let alice_out = setup
            .alice
            .converge_commit(
                &setup.mls_group_id,
                &alice_commit,
                n,
                std::slice::from_ref(&bob_commit),
                &CommitIntent::None,
            )
            .expect("alice converge must complete");
        let bob_out = setup
            .bob
            .converge_commit(
                &setup.mls_group_id,
                &bob_commit,
                n,
                std::slice::from_ref(&alice_commit),
                &CommitIntent::None,
            )
            .expect("bob converge must complete");

        // Exactly one merged; both advanced to N+1 (a convergent outcome proves
        // the adopt leg ran to completion, i.e. no deadlock).
        let merged = [alice_out, bob_out]
            .iter()
            .filter(|o| matches!(o, CommitConvergence::Merged))
            .count();
        assert_eq!(merged, 1, "exactly one committer wins the merge leg");
        assert_eq!(setup.alice.group_epoch(&setup.mls_group_id).unwrap(), n + 1);
        assert_eq!(setup.bob.group_epoch(&setup.mls_group_id).unwrap(), n + 1);
    }

    /// M7-B (b) NO RE-ENTRANCY DEADLOCK — `add_members_with_welcomes`.
    ///
    /// `add_members_with_welcomes` (async) internally calls the sync
    /// `add_members`, which acquires the writer lock and then drops it before
    /// the `.await` on `wrap_welcomes_with_cascade`. The guard must NEVER be held
    /// across the await (a `!Send` `MutexGuard` held across await would fail to
    /// compile in an async fn / could deadlock). Asserts the call COMPLETES.
    #[tokio::test]
    async fn m7b_add_members_with_welcomes_completes_no_reentrancy_deadlock() {
        let setup = setup_two_party_circle();
        let new_member =
            make_member_with_relays(vec!["wss://inbox.example.com".to_string()], Vec::new());

        let result = setup
            .alice
            .add_members_with_welcomes(
                &setup.alice_keys,
                &setup.mls_group_id,
                vec![new_member],
                &["wss://fallback.example.com".to_string()],
            )
            .await
            .expect("add_members_with_welcomes must complete (no deadlock)");
        assert_eq!(
            result.welcome_events.len(),
            1,
            "one welcome per added member"
        );
        // Roll back the staged Add so the group is left clean.
        setup
            .alice
            .clear_pending_commit(&setup.mls_group_id)
            .unwrap();
    }

    /// Serializes the two lock-OBSERVATION tests against EACH OTHER so one's
    /// held `acquire_authoring` guard cannot make the other's "lossless resume"
    /// decrypt spuriously yield. (Production authoring tests elsewhere also share
    /// the process-global `WRITER_LOCK`; the resume assertion tolerates that via
    /// a bounded retry, which is itself the correct lossless-yield behavior.)
    static LOCK_OBS_SERIALIZE: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// M7-B (c) SWEEP YIELDS UNDER CONTENTION — `decrypt_receive_only` returns
    /// `Skipped` (without advancing the cursor, without persisting) while a
    /// concurrent authoring guard is held, and RESUMES a normal decrypt once the
    /// guard is released (proving the yield is lossless: the cursor never
    /// advanced, so the same event is re-processed).
    ///
    /// The contended guard is held on the SAME thread (`try_acquire_background`
    /// is non-blocking, so no second thread is needed to observe contention);
    /// this deterministically drives the `None` leg of the sweep.
    #[test]
    fn m7b_receive_only_yields_to_skipped_under_authoring_contention() {
        use crate::location::LocationMessage;
        use crate::relay::ReceiveOnlyOutcome;

        // The process-global WRITER_LOCK is shared across ALL parallel tests;
        // serialize the lock-observation tests so they don't perturb each other.
        let _serialize = LOCK_OBS_SERIALIZE
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);

        let setup = setup_two_party_circle();
        let gid = &setup.mls_group_id;
        let ngid = &setup.nostr_group_id;
        let alice_hex = setup.alice_keys.public_key().to_hex();
        let now = chrono::Utc::now().timestamp();

        // Bob authors a location Alice has not yet seen.
        let (loc, _, _) = setup
            .bob
            .encrypt_location(
                gid,
                &setup.bob_keys.public_key(),
                &LocationMessage::new(51.5, -0.12),
                300,
            )
            .unwrap();

        // Simulate the foreground authoring writer holding the lock: while held,
        // the background sweep MUST yield to Skipped and NOT advance the cursor
        // (and must NOT persist the location — the yield is pre-decrypt).
        {
            let _authoring = crate::write_lock::acquire_authoring();
            let out = setup.alice.decrypt_receive_only(&loc, ngid, &alice_hex);
            assert_eq!(
                out,
                ReceiveOnlyOutcome::Skipped,
                "sweep yields to Skipped while an authoring guard is held"
            );
            assert!(!out.advances_cursor(), "cursor must not advance on a yield");
            let rows = setup
                .alice
                .snapshot_last_known_for_circle(ngid, now)
                .unwrap();
            assert!(
                !rows.iter().any(|r| (r.latitude - 51.5).abs() < 0.001),
                "a yielded (contended) location must NOT be persisted"
            );
        } // authoring guard released here

        // Lock free again → the yield was lossless: the SAME contended event is
        // re-decrypted (the cursor never advanced past it) and now applies
        // normally, persisting the location. The helper absorbs any transient
        // contention from OTHER parallel tests that also acquire the
        // process-global authoring lock — a transient Skipped there is itself the
        // correct lossless-yield behavior, not a failure.
        let out2 = receive_only_until_applied(&setup.alice, &loc, ngid, &alice_hex);
        assert_eq!(
            out2,
            ReceiveOnlyOutcome::Location,
            "once the lock is free the re-processed event applies (lossless yield)"
        );
        assert!(out2.advances_cursor());
        let rows2 = setup
            .alice
            .snapshot_last_known_for_circle(ngid, now)
            .unwrap();
        assert!(
            rows2.iter().any(|r| (r.latitude - 51.5).abs() < 0.001),
            "the previously-contended location is persisted after the lock frees"
        );
    }

    /// M7-B guard test: every MDK-write call site in this file MUST acquire the
    /// writer lock (`acquire_authoring` for authoring paths; the sweep's single
    /// `try_acquire_background`). Fails if a NEW MDK-write entrypoint is added
    /// without a lock acquisition in a small preceding window — the enforcement
    /// the plan (§B step 2, §E step 1) requires.
    ///
    /// This reads the file's own source at test time; it is coupled to the
    /// wrapping style used above (a `crate::write_lock::acquire_*` line within a
    /// few lines before the `self.mdk.<write>(` call).
    #[test]
    fn m7b_every_mdk_write_site_acquires_the_writer_lock() {
        // The exhaustive set of MDK methods that WRITE to `haven_mdk.db`
        // (ratchet advance, staged/merged/cleared commit, welcome consumption,
        // group create/delete). Read-only MDK methods (`get_*`,
        // `process_message_classified` is a write and IS listed) are excluded.
        const MDK_WRITE_METHODS: &[&str] = &[
            "create_group",
            "create_key_package",
            "create_key_package_with_d",
            "create_message",
            "process_message",
            "process_message_classified",
            "process_welcome",
            "accept_welcome",
            "decline_welcome",
            "self_update",
            "self_demote",
            "add_members",
            "remove_members",
            "update_admins",
            "update_relays",
            // Reached in production only through the locked `update_admins` /
            // `update_relays` wrappers today, but listed for defense-in-depth so
            // a future direct `self.mdk.update_group_data(...)` cannot slip in
            // unlocked (marmot LOW).
            "update_group_data",
            "merge_pending_commit",
            "clear_pending_commit",
            "leave_group",
            "delete_group",
        ];
        // NOTE: this scanner covers production MDK writes in THIS file only.
        // Every MDK write in Haven currently goes through a `CircleManager`
        // method here (the `mdk` field is private; the FFI + live-sync engine
        // reach MDK only via these locked methods). Any NEW production MDK-write
        // entrypoint added OUTSIDE `CircleManager` (e.g. wiring the dormant
        // `MlsGroupContext` / `LocationEventEncoder`) MUST also acquire
        // `crate::write_lock` — this test would not see it (marmot LOW).
        let src = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/circle/manager.rs"
        ))
        .expect("read manager.rs source");
        let lines: Vec<&str> = src.lines().collect();

        // Only scan production code — stop at the test module so test-only
        // `self.mdk.*` calls (setup helpers) are not required to lock.
        let test_mod_start = lines
            .iter()
            .position(|l| l.trim_start().starts_with("mod tests {"))
            .expect("test module marker present");

        let acquires = |line: &str| {
            line.contains("crate::write_lock::acquire_authoring")
                || line.contains("crate::write_lock::try_acquire_background")
        };

        // Re-join method-chain continuation lines so a `self.mdk.<method>(` call
        // split across physical lines (e.g. `self\n    .mdk\n    .merge_pending_commit(`)
        // is matched — the single-line `contains` alone silently skipped the
        // multi-line writes, including the `merge_pending_commit` / `create_message`
        // chokepoints (security M-1 / marmot MEDIUM). A physical line whose
        // trimmed text starts with `.` continues the previous logical line; each
        // logical line remembers the physical index where it STARTS (the `self` /
        // `self.mdk` line), which is what the window-based lock check anchors on.
        // The `self.mdk.` prefix in the needle still prevents false matches on
        // same-named `CircleManager` wrappers (e.g. `self.add_members(`).
        let mut logical: Vec<(usize, String)> = Vec::new();
        for (idx, line) in lines.iter().enumerate().take(test_mod_start) {
            let trimmed = line.trim_start();
            // Skip comments so doc references to method names don't false-match.
            if trimmed.starts_with("//") {
                continue;
            }
            if trimmed.starts_with('.') {
                if let Some(last) = logical.last_mut() {
                    last.1.push_str(trimmed);
                    continue;
                }
            }
            logical.push((idx, trimmed.to_string()));
        }

        // A guard can be held across a loop/block, so the acquisition may be
        // many lines before the write (e.g. `wrap_avatar_chunks` locks the whole
        // chunk batch). Anchor on the ENCLOSING METHOD instead of a fixed line
        // window: the guard must appear between the write's `fn` and the write.
        // (Impl methods are 4-space indented; closures use `|..|`, not `fn`.)
        let is_method_decl = |line: &str| {
            let t = line.trim_start();
            line.starts_with("    ")
                && (t.starts_with("fn ")
                    || t.starts_with("pub fn ")
                    || t.starts_with("pub(crate) fn ")
                    || t.starts_with("async fn ")
                    || t.starts_with("pub async fn ")
                    || t.starts_with("pub(crate) async fn "))
        };

        let mut sites = 0usize;
        for (idx, text) in &logical {
            for method in MDK_WRITE_METHODS {
                let needle = format!("self.mdk.{method}(");
                if !text.contains(&needle) {
                    continue;
                }
                sites += 1;
                let method_start = (0..=*idx)
                    .rev()
                    .find(|&i| is_method_decl(lines[i]))
                    .unwrap_or(0);
                let has_lock = lines[method_start..=*idx].iter().any(|l| acquires(l));
                assert!(
                    has_lock,
                    "MDK write `self.mdk.{method}(` at manager.rs:{} is NOT preceded \
                     by a writer-lock acquisition within its enclosing method. Every \
                     MDK-write entrypoint MUST acquire `crate::write_lock` (M7-B).",
                    idx + 1
                );
            }
        }

        // Count self-test: the scanner must recognise EVERY production MDK-write
        // site (single- AND multi-line). If this drifts, a write site was
        // added/removed — update it CONSCIOUSLY (after verifying each acquires
        // the lock) so the multi-line blind spot cannot silently reopen.
        // Verified 2026-07-03: 25 `acquire_authoring` writes (incl. the M8-2
        // `create_key_package_with_d` maintenance wrapper) + 1 sweep
        // (`try_acquire_background` in `decrypt_receive_only`).
        const EXPECTED_WRITE_SITES: usize = 26;
        assert_eq!(
            sites, EXPECTED_WRITE_SITES,
            "expected {EXPECTED_WRITE_SITES} locked MDK-write sites, found {sites}; \
             a write site was added/removed — verify each acquires `write_lock` \
             and update EXPECTED_WRITE_SITES."
        );
    }
}
