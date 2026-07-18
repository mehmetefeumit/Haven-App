//! High-level circle management API.
//!
//! This module provides the [`CircleManager`] which combines MLS operations
//! (via [`SessionManager`]) with application-level storage ([`CircleStorage`])
//! to provide a unified API for circle management.
//!
//! # Privacy Model
//!
//! Haven uses a privacy-first approach where:
//! - User profiles (kind 0) are public-by-default; all other group metadata
//!   stays local
//! - Contact info (petnames) is stored locally only
//! - Relays only see pubkeys and the pseudonymous `nostr_group_id`
//!
//! # Dark Matter engine (DM-3)
//!
//! The circle layer sits on the Dark Matter [`SessionManager`] (one hydrated
//! `AccountDeviceSession` behind a `tokio` mutex). Its mutating calls are
//! `async` and take `&mut self` internally, so every `CircleManager` method
//! that touches the session is `async`. The engine owns convergence,
//! out-of-order sequencing, and publish-before-apply (`PendingStateRef`); the
//! hand-rolled settle-window / staged-commit / un-poison machinery that used to
//! live here is deleted (plan §5.3/§5.4).
//!
//! [`SessionManager`]: crate::nostr::mls::SessionManager

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};

use nostr::{Event, EventId, Keys, PublicKey};

use super::error::{CircleError, Result};
use super::leave::{plan_leave, LeavePlan};
use super::storage::CircleStorage;
use super::types::{
    Circle, CircleConfig, CircleMember, CircleMembership, CircleType, CircleWithMembers, Contact,
    GiftWrappedWelcome, Invitation, MemberKeyPackage, MembershipStatus,
};
use crate::location::LocationMessage;
use crate::nostr::mls::redact_hex_sequences;
use crate::nostr::mls::types::{
    GroupEvent, GroupId, GroupIdExt, KeyPackage, LocationGroupConfig, LocationMessageResult,
    PendingStateRef, PublishWork, SessionEffects, TransportMessage,
};
use crate::nostr::mls::{PendingWelcome, PendingWelcomeStore, SessionManager};

/// Formats the first 8 hex chars of an event ID for diagnostic logging.
///
/// Safe to log: gives operators enough to correlate a log line with a relay
/// event without exposing the full ID.
#[must_use]
pub fn short_id(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut out = String::with_capacity(8);
    for b in bytes.iter().take(4) {
        let _ = write!(out, "{b:02x}");
    }
    out
}

/// High-level API for circle management.
///
/// Combines MLS operations with application-level storage to provide a unified
/// interface for creating and managing circles.
pub struct CircleManager {
    /// The single, process-global Dark Matter session (Rule 14: one live
    /// [`SessionManager`] per DB file across ALL isolates — the M7 background
    /// catch-up path MUST reuse this handle, never open a second session).
    session: Arc<SessionManager>,
    /// Hold-before-ingest pending-welcome store (F3): the still-encrypted 1059
    /// gift wraps awaiting the user's accept / decline. In-memory; re-seeded
    /// from relays on each poll (gift wraps are permanent on relays).
    pending_welcomes: PendingWelcomeStore,
    /// Binds each in-flight `GroupCreated` `pending` to its group id so a
    /// create that is rolled back (all welcomes zero-ack → `publish_failed`, or
    /// a post-stage error) removes the eagerly-persisted circle/membership rows
    /// instead of stranding a ghost circle backed by no confirmed group (F2).
    /// In-memory: an unresolved create at process exit self-clears on restart
    /// (the engine also rolls the staged create back at hydrate).
    create_pending: Mutex<HashMap<PendingStateRef, GroupId>>,
    pub(crate) storage: CircleStorage,
}

impl CircleManager {
    /// Maximum number of relays a circle may carry.
    ///
    /// MIP-01 says the group relay list SHOULD NOT exceed 20; Haven enforces it
    /// as a hard cap to bound kind-445 fan-out metadata and to stop an admin
    /// from inflating every member's subscription set.
    const MAX_CIRCLE_RELAYS: usize = 20;

    /// Creates a new circle manager bound to the device identity `keys`.
    ///
    /// Initializes both the MLS session and circle storage at the given path.
    /// The identity keys bind the engine's account identity, its NIP-59 welcome
    /// signer, and its hardened account-identity-proof signer (Rule 1).
    ///
    /// # Arguments
    ///
    /// * `data_dir` - Base directory for all Haven data
    /// * `keys` - The device's Nostr identity keys
    /// * `circle_db_hex_key` - Optional hex-encoded encryption key for
    ///   circles.db. When provided, the database is encrypted with `SQLCipher`.
    ///
    /// # Errors
    ///
    /// Returns an error if initialization fails.
    pub fn new(data_dir: &Path, keys: &Keys, circle_db_hex_key: Option<&str>) -> Result<Self> {
        std::fs::create_dir_all(data_dir)
            .map_err(|e| CircleError::Storage(format!("Failed to create data directory: {e}")))?;

        let session = SessionManager::new(data_dir, keys)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        let db_path = data_dir.join("circles.db");
        let storage = CircleStorage::new(&db_path, circle_db_hex_key)?;

        Ok(Self {
            session: Arc::new(session),
            pending_welcomes: PendingWelcomeStore::new(),
            create_pending: Mutex::new(HashMap::new()),
            storage,
        })
    }

    /// Creates a new circle manager with a fixed-key (test) MLS session.
    ///
    /// # Warning
    ///
    /// Uses a constant passphrase for the encrypted session DB. Only for
    /// testing or development.
    ///
    /// # Errors
    ///
    /// Returns an error if initialization fails.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn new_unencrypted(data_dir: &Path, keys: &Keys) -> Result<Self> {
        std::fs::create_dir_all(data_dir)
            .map_err(|e| CircleError::Storage(format!("Failed to create data directory: {e}")))?;

        let session = SessionManager::new_unencrypted(data_dir, keys)
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        let db_path = data_dir.join("circles.db");
        let storage = CircleStorage::new(&db_path, None)?;

        Ok(Self {
            session: Arc::new(session),
            pending_welcomes: PendingWelcomeStore::new(),
            create_pending: Mutex::new(HashMap::new()),
            storage,
        })
    }

    /// A shared handle to the underlying session (for a group-scoped context).
    #[must_use]
    pub const fn session(&self) -> &Arc<SessionManager> {
        &self.session
    }

    /// Returns the current MLS epoch for a group (test/feature-only).
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::NotFound`] if the group does not exist, or
    /// [`CircleError::Mls`] if the query fails.
    #[cfg(any(test, feature = "test-utils", debug_assertions))]
    pub async fn group_epoch(&self, mls_group_id: &GroupId) -> Result<u64> {
        let group = self
            .session
            .find_group(mls_group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
            .ok_or_else(|| CircleError::NotFound("Group not found: <redacted>".to_string()))?;
        Ok(group.epoch.0)
    }

    /// Returns whether `pubkey_hex` is still present in the group's current
    /// roster — the REV-1 leaver-backstop liveness predicate.
    ///
    /// Fails SAFE to `false` when the group is gone or the caller has been
    /// evicted, so a removed leaver stops re-issuing.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Mls`] if the roster cannot be read.
    pub async fn still_a_member(&self, mls_group_id: &GroupId, pubkey_hex: &str) -> Result<bool> {
        if self
            .session
            .find_group(mls_group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
            .is_none()
        {
            return Ok(false);
        }

        Ok(self
            .session
            .member_pubkeys(mls_group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?
            .iter()
            .any(|pk| pk == pubkey_hex))
    }

    // ==================== Circle Lifecycle ====================

    /// Creates a new circle with gift-wrapped welcome events.
    ///
    /// Creates the underlying MLS group and stores circle metadata. The engine
    /// produces the per-member gift-wrapped Welcomes (kind 1059) itself (the
    /// peeler owns the NIP-59 crypto now); Haven only resolves each recipient's
    /// delivery relays through the fail-closed cascade (member inbox → member
    /// NIP-65 → creator inbox → fail closed), so a bare-pubkey invitee with no
    /// advertised relay is uninvitable (the intended two-plane tradeoff).
    ///
    /// Publish-before-apply (Rule 13): the returned
    /// [`CircleCreationResult::pending`] must be confirmed via
    /// [`Self::confirm_published`] after the welcomes reach ≥1 relay, or rolled
    /// back via [`Self::publish_failed`] on failure.
    ///
    /// # Errors
    ///
    /// Returns an error if circle creation or welcome routing fails.
    pub async fn create_circle(
        &self,
        sender_keys: &Keys,
        members: Vec<MemberKeyPackage>,
        config: &CircleConfig,
        creator_fallback_relays: &[String],
    ) -> Result<CircleCreationResult> {
        // Fail closed BEFORE creating the MLS group: a member is deliverable iff
        // it advertises an inbox/NIP-65 relay OR the creator has an inbox
        // fallback (identical for every member). Pre-validate so the fail-closed
        // path leaves storage untouched.
        if creator_fallback_relays.is_empty() {
            for m in &members {
                if m.inbox_relays.is_empty() && m.nip65_relays.is_empty() {
                    return Err(CircleError::MissingWelcomeRelays);
                }
            }
        }

        // Default the group relay set to the user's Inbox relays when the caller
        // passed none (the group relay list drives kind-445 routing and the
        // Welcome metadata; the engine fail-closes on an empty set — W8).
        let effective_relays: Vec<String> = if config.relays.is_empty() {
            let inbox = self
                .storage
                .list_user_relays(crate::circle::relay_prefs::RelayType::Inbox)
                .unwrap_or_default();
            if inbox.is_empty() {
                log::warn!(
                    "[CircleManager] create_circle: user inbox relays empty, \
                     falling back to default relays (seed may not have run yet)"
                );
                crate::circle::types::default_relays()
            } else {
                inbox
            }
        } else {
            config.relays.clone()
        };

        let mut mls_config = LocationGroupConfig::new(&config.name)
            .with_relays(effective_relays.iter().map(String::as_str))
            .with_admin(sender_keys.public_key().to_hex());
        if let Some(ref description) = config.description {
            mls_config = mls_config.with_description(description);
        }

        let key_package_events: Vec<Event> = members
            .iter()
            .map(|m| m.key_package_event.clone())
            .collect();

        let mut cfg = config.clone();
        cfg.relays = effective_relays;

        self.create_circle_with_config(
            &members,
            key_package_events,
            mls_config,
            &cfg,
            creator_fallback_relays,
        )
        .await
    }

    /// Internal helper for circle creation with a configured MLS config.
    async fn create_circle_with_config(
        &self,
        members: &[MemberKeyPackage],
        key_package_events: Vec<Event>,
        mls_config: LocationGroupConfig,
        config: &CircleConfig,
        creator_fallback_relays: &[String],
    ) -> Result<CircleCreationResult> {
        let key_packages = parse_key_packages(&key_package_events)?;

        let effects = self
            .session
            .create_group(key_packages, mls_config)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        let group_id = effects.group_id.clone();

        // The transport routing id comes from the engine's freshly-minted
        // `marmot.transport.nostr.routing.v1` component (Rule 4: never the real
        // MLS group id).
        let (nostr_group_id, _) = self
            .session
            .group_routing(&group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        // The engine returns gift-wrapped 1059 welcomes + a PendingStateRef under
        // GroupCreated. Extract BEFORE persisting any storage row, so a
        // (defensive) extraction failure leaves storage untouched.
        let (welcomes, pending) = take_group_created(effects.effects)?;

        let now = chrono::Utc::now().timestamp();
        let circle = Circle {
            mls_group_id: group_id.clone(),
            nostr_group_id,
            display_name: config.name.clone(),
            circle_type: config.circle_type,
            relays: config.relays.clone(),
            created_at: now,
            updated_at: now,
        };
        self.storage.save_circle(&circle)?;

        let membership = CircleMembership {
            mls_group_id: group_id.clone(),
            status: MembershipStatus::Accepted,
            inviter_pubkey: None,
            invited_at: now,
            responded_at: Some(now),
        };
        self.storage.save_membership(&membership)?;

        // F2: bind this create's `pending` to the just-saved rows so a later
        // rollback (all welcomes zero-ack → `publish_failed`, or the route error
        // below) deletes them instead of stranding a ghost circle backed by no
        // confirmed group.
        self.register_create_pending(pending, &group_id);

        // Route each welcome to its recipient's cascade relays. F3: if routing
        // fails AFTER the group + rows are staged, roll the pending back — which
        // also deletes the just-saved rows via the create-pending map — so
        // neither a PendingStateRef nor a ghost circle row leaks.
        let welcome_events = match self
            .route_welcomes_with_cascade(members, welcomes, creator_fallback_relays)
            .await
        {
            Ok(events) => events,
            Err(e) => {
                let _ = self.publish_failed(pending).await;
                return Err(e);
            }
        };

        Ok(CircleCreationResult {
            circle,
            welcome_events,
            pending,
        })
    }

    /// Binds a create's `pending` to its group id so a later rollback removes
    /// the eagerly-persisted circle/membership rows (F2). See
    /// [`Self::publish_failed`].
    fn register_create_pending(&self, pending: PendingStateRef, group_id: &GroupId) {
        self.create_pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(pending, group_id.clone());
    }

    /// Removes and returns any group id bound to `pending` in the create-pending
    /// map (F2).
    fn take_create_pending(&self, pending: PendingStateRef) -> Option<GroupId> {
        self.create_pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&pending)
    }

    /// Routes engine-produced gift-wrapped Welcomes to their recipients' relays.
    ///
    /// The Dark Matter peeler owns the NIP-59 1059 crypto, so Haven no longer
    /// wraps welcomes — it fans the engine's wrapped 1059s out to the
    /// fail-closed delivery cascade. Each welcome is matched to its `members`
    /// entry by the recipient pubkey carried in the 1059's `p` tag.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Mls`] on a count/recipient mismatch, or
    /// [`CircleError::MissingWelcomeRelays`] if a member has no advertised relay
    /// and there is no sender fallback.
    // `async` is part of the welcome fan-out contract DM-4 wires to real relay
    // publishing; the body has no `await` yet (the gift wraps are assembled
    // synchronously), so the lint is suppressed rather than flip the signature.
    #[allow(clippy::unused_async)]
    async fn route_welcomes_with_cascade(
        &self,
        members: &[MemberKeyPackage],
        welcomes: Vec<TransportMessage>,
        creator_fallback_relays: &[String],
    ) -> Result<Vec<GiftWrappedWelcome>> {
        if welcomes.len() != members.len() {
            return Err(CircleError::Mls(format!(
                "Expected {} welcome(s), got {}",
                members.len(),
                welcomes.len()
            )));
        }

        let mut welcome_events = Vec::with_capacity(welcomes.len());
        for wt in welcomes {
            let event = SessionManager::transport_message_to_event(&wt)
                .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

            // The gift wrap's `p` tag is the recipient identity.
            let recipient_pubkey = event
                .tags
                .iter()
                .find_map(|tag| {
                    let v = tag.as_slice();
                    if v.len() >= 2 && v[0] == "p" {
                        PublicKey::from_hex(&v[1]).ok()
                    } else {
                        None
                    }
                })
                .ok_or_else(|| {
                    CircleError::Mls("Welcome gift wrap missing recipient 'p' tag".to_string())
                })?;

            let member = members
                .iter()
                .find(|m| m.key_package_event.pubkey == recipient_pubkey)
                .ok_or_else(|| {
                    CircleError::Mls("No member matches welcome recipient".to_string())
                })?;

            // Cascade: member inbox → member NIP-65 → sender inbox → fail closed.
            let recipient_relays = if !member.inbox_relays.is_empty() {
                member.inbox_relays.clone()
            } else if !member.nip65_relays.is_empty() {
                member.nip65_relays.clone()
            } else if !creator_fallback_relays.is_empty() {
                creator_fallback_relays.to_vec()
            } else {
                return Err(CircleError::MissingWelcomeRelays);
            };

            welcome_events.push(GiftWrappedWelcome {
                recipient_pubkey: recipient_pubkey.to_hex(),
                recipient_relays,
                event,
            });
        }

        Ok(welcome_events)
    }

    /// Retrieves a circle with its members.
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub async fn get_circle(&self, mls_group_id: &GroupId) -> Result<Option<CircleWithMembers>> {
        let Some(circle) = self.storage.get_circle(mls_group_id)? else {
            return Ok(None);
        };

        let membership = self.storage.get_membership(mls_group_id)?.ok_or_else(|| {
            CircleError::NotFound("Membership not found for circle: <redacted>".to_string())
        })?;

        let members = self.get_members(mls_group_id).await?;

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
    pub async fn get_circles(&self) -> Result<Vec<CircleWithMembers>> {
        let circles = self.storage.get_all_circles()?;
        let mut result = Vec::with_capacity(circles.len());

        for circle in circles {
            if let Some(membership) = self.storage.get_membership(&circle.mls_group_id)? {
                let members = self
                    .get_members(&circle.mls_group_id)
                    .await
                    .unwrap_or_default();
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
    pub async fn get_visible_circles(&self) -> Result<Vec<CircleWithMembers>> {
        let circles = self.get_circles().await?;
        Ok(circles
            .into_iter()
            .filter(|c| c.membership.status.is_visible())
            .collect())
    }

    /// Classifies what the caller must do to leave the circle.
    ///
    /// See [`LeavePlan`]. Admin exits are gated by the engine's `SelfRemove` rules
    /// (`AdminCannotSelfRemove`/`AdminDepletion`): an admin exits the admin set
    /// first.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::Mls`] if the engine query fails for a reason other
    /// than "group not found" (which maps to `OrphanLocalOnly`).
    pub async fn plan_leave(
        &self,
        mls_group_id: &GroupId,
        self_pubkey: &PublicKey,
    ) -> Result<LeavePlan> {
        plan_leave(&self.session, mls_group_id, self_pubkey).await
    }

    /// Step 1 of admin handoff: promote `successor` to admin.
    ///
    /// # GAP (plan §5.2 #18)
    ///
    /// The Dark Matter v0.9.4 public API exposes no admin-policy component codec
    /// (`GROUP_ADMIN_POLICY_COMPONENT_ID` exists but no encode/decode helper),
    /// so Haven cannot construct the `UpdateAppComponents(admin-policy.v1)`
    /// commit that would grant admin. Fails with a documented error until the
    /// codec lands (tracked upstream alongside mdk#755).
    ///
    /// USER-FACING CONSEQUENCE: because an admin cannot hand off or self-demote,
    /// a circle's admin can only leave once every *other* member has left (the
    /// `Abandon` leg). This ships with an admin-only note beside the Leave Circle
    /// button (`circles_bottom_sheet.dart`, l10n `leaveCircleAdminLimitationNote`).
    /// Full write-up + removal steps: `docs/MDK_DARKMATTER_MIGRATION_PLAN.md` §11.1.
    ///
    /// # Errors
    ///
    /// Always returns [`CircleError::Mls`] (admin-policy codec unavailable).
    // `async` is retained for the admin-policy flow DM-4 wires once the codec
    // lands (it will `session.send(UpdateAppComponents)`); today it only errors.
    #[allow(clippy::unused_async)]
    pub async fn propose_admin_handoff(
        &self,
        _mls_group_id: &GroupId,
        _successor: &PublicKey,
    ) -> Result<CommitToPublish> {
        Err(CircleError::Mls(
            "admin handoff requires the admin-policy component codec, which the \
             Dark Matter v0.9.4 public API does not expose (GAP, plan §5.2 #18)"
                .to_string(),
        ))
    }

    /// Proposes an admin update of a circle's group relay list (MIP-01) via an
    /// `UpdateAppComponents(nostr-routing.v1)` commit.
    ///
    /// Publish-before-apply (Rule 13): publish [`CommitToPublish::commit_event`]
    /// to the union of the circle's current and new relays, then
    /// [`Self::finalize_relay_update`] on ≥1-relay ack or [`Self::publish_failed`]
    /// on failure. The circle row is updated only on a successful confirm.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::InvalidData`] for an empty / all-invalid /
    /// oversized relay set, or [`CircleError::Mls`] if the caller is not an admin
    /// or the engine rejects the update.
    pub async fn update_circle_relays(
        &self,
        mls_group_id: &GroupId,
        new_relays: &[String],
    ) -> Result<CommitToPublish> {
        let mut canonical: Vec<String> = Vec::with_capacity(new_relays.len());
        for relay in new_relays {
            canonical.push(super::storage_relay_prefs::normalize_url(relay)?);
        }
        canonical.sort();
        canonical.dedup();

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

        let effects = self
            .session
            .update_relays(mls_group_id, canonical)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        let (commit_event, _welcomes, pending) = take_group_evolution(effects)?;
        Ok(CommitToPublish {
            commit_event,
            pending,
        })
    }

    /// Re-derives the app-level `circle.relays` row from the engine's routing
    /// component after a commit. Idempotent; never overwrites a non-empty
    /// `circle.relays` with an empty set (never bricks 445 routing).
    ///
    /// # Errors
    ///
    /// Returns an error if the engine or storage access fails.
    async fn resync_circle_relays_from_mdk(&self, mls_group_id: &GroupId) -> Result<()> {
        let mut engine_relays = self
            .session
            .group_relays(mls_group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        engine_relays.sort();
        engine_relays.dedup();

        let Some(mut circle) = self.storage.get_circle(mls_group_id)? else {
            return Ok(());
        };

        if engine_relays.is_empty() {
            return Ok(());
        }

        let mut current = circle.relays.clone();
        current.sort();
        current.dedup();
        if current != engine_relays {
            circle.relays = engine_relays;
            circle.updated_at = chrono::Utc::now().timestamp();
            self.storage.save_circle(&circle)?;
        }
        Ok(())
    }

    /// Finalizes an admin relay update: confirms the pending commit, then
    /// re-syncs the admin's own `circle.relays` from the engine.
    ///
    /// # Errors
    ///
    /// Returns an error if the confirm fails. A confirm success followed by a
    /// transient re-sync failure is logged (not returned) — the commit is
    /// already applied and the re-sync self-heals idempotently.
    pub async fn finalize_relay_update(
        &self,
        pending: PendingStateRef,
        mls_group_id: &GroupId,
    ) -> Result<()> {
        self.confirm_published(pending).await?;
        if let Err(e) = self.resync_circle_relays_from_mdk(mls_group_id).await {
            log::warn!(
                "finalize_relay_update: relay re-sync failed (will self-heal): {}",
                redact_hex_sequences(&e.to_string())
            );
        }
        Ok(())
    }

    /// Step 2 of admin handoff (or step 1 for `Abandon`): demote the caller from
    /// the admin set.
    ///
    /// # GAP (plan §5.2 #18)
    ///
    /// Same admin-policy-codec gap as [`Self::propose_admin_handoff`].
    ///
    /// # Errors
    ///
    /// Always returns [`CircleError::Mls`] (admin-policy codec unavailable).
    // See `propose_admin_handoff`: `async` is retained for the DM-4 wiring.
    #[allow(clippy::unused_async)]
    pub async fn propose_self_demote(&self, _mls_group_id: &GroupId) -> Result<CommitToPublish> {
        Err(CircleError::Mls(
            "self-demote requires the admin-policy component codec, which the \
             Dark Matter v0.9.4 public API does not expose (GAP, plan §5.2 #18)"
                .to_string(),
        ))
    }

    /// Final step of every non-abandoning leave: returns a `SelfRemove` proposal
    /// event so peers can advance past the caller.
    ///
    /// A bare proposal has no `PendingStateRef` — a remaining member commits it
    /// later (RFC 9420 §12.1.2). The caller publishes the returned event, then
    /// calls [`Self::complete_leave`]; there is nothing to confirm.
    ///
    /// # Errors
    ///
    /// Returns an error if the engine rejects the leave (e.g. the caller is
    /// still an admin — `AdminCannotSelfRemove`).
    pub async fn propose_leave(&self, mls_group_id: &GroupId) -> Result<Event> {
        let effects = self
            .session
            .leave_group(mls_group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        take_proposal(effects)
    }

    /// Finalizes a leave by removing the local circle row.
    ///
    /// The Dark Matter engine has no per-group delete: leaving is a `SelfRemove`
    /// (via [`Self::propose_leave`]) after which the engine marks its local copy
    /// `removed` (retained inactive, spec `member-departure.md`). Haven removes
    /// its own circle row here. Safe for the `OrphanLocalOnly` plan.
    ///
    /// # Errors
    ///
    /// Returns an error if the circle-row deletion fails.
    pub fn complete_leave(&self, mls_group_id: &GroupId) -> Result<()> {
        let _existed = self.storage.delete_circle(mls_group_id)?;
        Ok(())
    }

    /// Abandons a circle where the caller is the sole remaining member.
    ///
    /// Same local-teardown semantics as [`Self::complete_leave`] (no relay
    /// publish — there is no one to receive a `SelfRemove`).
    ///
    /// # Errors
    ///
    /// Returns an error if the circle-row deletion fails.
    pub fn abandon_circle_local_only(&self, mls_group_id: &GroupId) -> Result<()> {
        self.complete_leave(mls_group_id)
    }

    // ==================== Publish-before-apply (Rule 13) ====================

    /// Confirms a staged commit was published (≥1-relay OK-ack) so the engine
    /// applies it and advances the epoch.
    ///
    /// "Acked" MUST mean a relay returned OK — never merely "sent" — to avoid
    /// optimistic-merge forks (Rule 13, security F13).
    ///
    /// # Errors
    ///
    /// Returns an error if the pending ref is unknown or the engine rejects it.
    pub async fn confirm_published(&self, pending: PendingStateRef) -> Result<()> {
        let result = self
            .session
            .confirm_published(pending)
            .await
            .map(|_| ())
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())));
        // A confirmed create KEEPS its eagerly-persisted rows; just drop the
        // rollback binding so a subsequent stray `publish_failed` can never
        // delete a now-live circle (F2). A no-op for every non-create pending.
        if result.is_ok() {
            let _ = self.take_create_pending(pending);
        }
        result
    }

    /// Reports that a staged publish failed; the engine discards the staged
    /// commit and returns the group to `Stable` at the prior epoch.
    ///
    /// # Errors
    ///
    /// Returns an error if the pending ref is unknown.
    pub async fn publish_failed(&self, pending: PendingStateRef) -> Result<()> {
        let result = self
            .session
            .publish_failed(pending)
            .await
            .map(|_| ())
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())));
        // F2: a rolled-back create must not strand a ghost circle row. Delete the
        // eagerly-persisted rows ONLY on a SUCCESSFUL rollback (the engine
        // actually discarded the staged create); an unknown / already-resolved
        // pending — e.g. one already confirmed — leaves storage untouched. A
        // no-op for every non-create pending (auto-commit / evolution).
        if result.is_ok() {
            if let Some(group_id) = self.take_create_pending(pending) {
                if let Err(e) = self.storage.delete_circle(&group_id) {
                    log::warn!(
                        "create rollback: circle-row cleanup failed (self-heals on logout wipe): {}",
                        redact_hex_sequences(&e.to_string())
                    );
                }
            }
        }
        result
    }

    // ==================== Member Management ====================

    /// Adds members to a circle, returning the engine [`SessionEffects`]
    /// (a `GroupEvolution` with the commit + welcomes + `PendingStateRef`).
    ///
    /// # Errors
    ///
    /// Returns an error if adding members fails.
    pub async fn add_members(
        &self,
        mls_group_id: &GroupId,
        key_packages: &[Event],
    ) -> Result<SessionEffects> {
        if let Some(mut circle) = self.storage.get_circle(mls_group_id)? {
            circle.updated_at = chrono::Utc::now().timestamp();
            self.storage.save_circle(&circle)?;
        }

        let kps = parse_key_packages(key_packages)?;
        self.session
            .add_members(mls_group_id, kps)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
    }

    /// Adds members to an existing circle and routes their gift-wrapped Welcomes.
    ///
    /// Publish-before-apply (Rule 13): publish
    /// [`AddMembersResult::commit_event`] to the circle's relays, confirm via
    /// [`Self::confirm_published`] on ≥1-relay ack (or [`Self::publish_failed`]
    /// on failure), and only after a successful confirm publish each
    /// [`AddMembersResult::welcome_events`] entry.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::MissingWelcomeRelays`] (checked before staging) or
    /// [`CircleError::Mls`] if staging or the admin gate rejects.
    pub async fn add_members_with_welcomes(
        &self,
        _sender_keys: &Keys,
        mls_group_id: &GroupId,
        members: Vec<MemberKeyPackage>,
        creator_fallback_relays: &[String],
    ) -> Result<AddMembersResult> {
        if creator_fallback_relays.is_empty() {
            for m in &members {
                if m.inbox_relays.is_empty() && m.nip65_relays.is_empty() {
                    return Err(CircleError::MissingWelcomeRelays);
                }
            }
        }

        let key_package_events: Vec<Event> = members
            .iter()
            .map(|m| m.key_package_event.clone())
            .collect();

        let effects = self.add_members(mls_group_id, &key_package_events).await?;
        let (commit_event, welcomes, pending) = take_group_evolution(effects)?;
        let welcome_events = self
            .route_welcomes_with_cascade(&members, welcomes, creator_fallback_relays)
            .await?;

        Ok(AddMembersResult {
            commit_event,
            welcome_events,
            pending,
        })
    }

    /// Removes members from a circle, returning the commit + pending ref.
    ///
    /// Publish-before-apply (Rule 13).
    ///
    /// # Errors
    ///
    /// Returns an error if removing members fails (e.g. `NotGroupAdmin`).
    pub async fn remove_members(
        &self,
        mls_group_id: &GroupId,
        member_pubkeys: &[String],
    ) -> Result<CommitToPublish> {
        if let Some(mut circle) = self.storage.get_circle(mls_group_id)? {
            circle.updated_at = chrono::Utc::now().timestamp();
            self.storage.save_circle(&circle)?;
        }

        let effects = self
            .session
            .remove_members(mls_group_id, member_pubkeys)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        let (commit_event, _welcomes, pending) = take_group_evolution(effects)?;
        Ok(CommitToPublish {
            commit_event,
            pending,
        })
    }

    /// Gets members of a circle with resolved contact info.
    ///
    /// # Errors
    ///
    /// Returns an error if retrieving members fails.
    pub async fn get_members(&self, mls_group_id: &GroupId) -> Result<Vec<CircleMember>> {
        let member_hexes = self
            .session
            .member_pubkeys(mls_group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        // Admin pubkeys are raw x-only bytes; hex-encode to compare with members.
        let admin_hexes: std::collections::HashSet<String> = self
            .session
            .admin_pubkeys(mls_group_id)
            .await
            .unwrap_or_default()
            .iter()
            .map(hex::encode)
            .collect();

        let mut members = Vec::with_capacity(member_hexes.len());
        for pubkey_hex in member_hexes {
            let is_admin = admin_hexes.contains(&pubkey_hex);
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

    /// Sets or updates a contact (stored locally only, never synced to relays).
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

    /// Processes a gift-wrapped Welcome event (kind 1059) into a held pending
    /// welcome (hold-before-ingest, F3).
    ///
    /// The still-encrypted 1059 is held locally and a non-secret preview (the
    /// inviter identity only — group name / member count are unavailable
    /// pre-join by design) is derived via a transient peel. Nothing is ingested
    /// until [`Self::accept_invitation`]; declining leaves no on-wire trace
    /// (Rule 10).
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::AlreadyProcessed`] for a duplicate, or
    /// [`CircleError::Mls`] if the gift wrap cannot be peeled.
    pub async fn process_gift_wrapped_invitation(
        &self,
        _recipient_keys: &Keys,
        gift_wrap_event: &Event,
    ) -> Result<Invitation> {
        let wrapper_id_prefix = short_id(gift_wrap_event.id.as_bytes());
        log::debug!(
            "[CircleManager] process_gift_wrapped_invitation: wrapper_id={wrapper_id_prefix} \
             kind={}",
            gift_wrap_event.kind.as_u16(),
        );

        // A resolved (accepted/declined) wrap is skipped; a still-held one is a
        // no-op (the store is idempotent per gift-wrap id).
        if self
            .storage
            .is_gift_wrap_processed(&gift_wrap_event.id)?
            .is_some()
        {
            return Err(CircleError::AlreadyProcessed);
        }
        if self.pending_welcomes.contains(&gift_wrap_event.id) {
            return Err(CircleError::AlreadyProcessed);
        }

        // Peel a non-secret preview WITHOUT ingesting; the encrypted 1059 is held
        // verbatim (the decrypted welcome bytes carry MLS join secrets and are
        // never stored — F3).
        let preview = self
            .session
            .preview_welcome(gift_wrap_event)
            .await
            .map_err(|e| {
                CircleError::Mls(format!(
                    "Failed to preview welcome: {}",
                    redact_hex_sequences(&e.to_string())
                ))
            })?;
        let inviter_pubkey = preview.inviter_pubkey.clone();

        self.pending_welcomes
            .insert(PendingWelcome::new(gift_wrap_event.clone(), preview));

        let now = chrono::Utc::now().timestamp();
        Ok(Invitation {
            // Pre-join the real MLS group id is unavailable (it lives inside the
            // still-encrypted welcome). Key the invitation by the gift-wrap id as
            // a stand-in until Accept ingests and `GroupJoined` yields the real
            // id. DM-4: the Dart accept path passes the gift-wrap id.
            mls_group_id: GroupId::from_slice(gift_wrap_event.id.as_bytes()),
            circle_name: "New Circle".to_string(),
            inviter_pubkey,
            member_count: 0,
            invited_at: now,
        })
    }

    /// Gets all pending invitations (from the held-welcome store).
    ///
    /// # Errors
    ///
    /// Never errors; the `Result` is kept for API stability.
    pub fn get_pending_invitations(&self) -> Result<Vec<Invitation>> {
        Ok(self
            .pending_welcomes
            .previews()
            .into_iter()
            .map(|(id, preview)| Invitation {
                mls_group_id: GroupId::from_slice(id.as_bytes()),
                circle_name: "New Circle".to_string(),
                inviter_pubkey: preview.inviter_pubkey,
                member_count: 0,
                invited_at: 0,
            })
            .collect())
    }

    /// Accepts an invitation to join a circle by ingesting the held welcome.
    ///
    /// Feeds the still-encrypted 1059 to the engine, which peels + joins and
    /// emits `GroupJoined` carrying the real MLS group id. Haven then
    /// materializes the circle row + accepted membership and drops the held
    /// welcome.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::NotFound`] if no welcome is held for `gift_wrap_id`,
    /// or [`CircleError::Mls`] if the join fails.
    pub async fn accept_invitation(&self, gift_wrap_id: &EventId) -> Result<CircleWithMembers> {
        let held = self
            .pending_welcomes
            .get(gift_wrap_id)
            .ok_or_else(|| CircleError::NotFound("No held welcome for invitation".to_string()))?;

        let ingest = self
            .session
            .accept_welcome(held.gift_wrap())
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        let group_id = ingest
            .effects
            .events
            .iter()
            .find_map(|ev| match ev {
                GroupEvent::GroupJoined { group_id, .. } => Some(group_id.clone()),
                _ => None,
            })
            .ok_or_else(|| {
                CircleError::Mls("welcome accept did not yield a joined group".to_string())
            })?;

        let (nostr_group_id, relays) = self
            .session
            .group_routing(&group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        let group = self
            .session
            .group_record(&group_id)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        let now = chrono::Utc::now().timestamp();
        let resolved_name = if group.name.is_empty() {
            "New Circle".to_string()
        } else {
            group.name
        };
        let effective_relays = if relays.is_empty() {
            crate::circle::types::default_relays()
        } else {
            relays
        };
        let circle = Circle {
            mls_group_id: group_id.clone(),
            nostr_group_id,
            display_name: resolved_name,
            circle_type: CircleType::LocationSharing,
            relays: effective_relays,
            created_at: now,
            updated_at: now,
        };
        let membership = CircleMembership {
            mls_group_id: group_id.clone(),
            status: MembershipStatus::Accepted,
            inviter_pubkey: Some(held.preview().inviter_pubkey.clone()),
            invited_at: now,
            responded_at: Some(now),
        };

        // Atomically persist the circle + membership + dedup row, then drop the
        // held welcome (terminal).
        self.storage
            .record_processed_invitation(gift_wrap_id, &circle, &membership, now)?;
        self.pending_welcomes.remove(gift_wrap_id);

        self.get_circle(&group_id)
            .await?
            .ok_or_else(|| CircleError::NotFound("Circle not found after acceptance".to_string()))
    }

    /// Declines an invitation: drops the held 1059 locally.
    ///
    /// The welcome is never ingested, so there is no join commit, no
    /// self-remove, nothing on the wire (Rule 10). The gift wrap is marked
    /// resolved so a re-poll does not re-surface it.
    ///
    /// # Errors
    ///
    /// Returns an error only if the resolution sentinel write fails.
    pub fn decline_invitation(&self, gift_wrap_id: &EventId) -> Result<()> {
        self.pending_welcomes.remove(gift_wrap_id);
        let now = chrono::Utc::now().timestamp();
        // Reuse the failure-sentinel row as a "resolved, do not re-surface" mark.
        let _ = self.storage.record_gift_wrap_failure(gift_wrap_id, now);
        Ok(())
    }

    // ==================== Location Sharing ====================

    /// Encrypts a location for a circle, producing a kind 445 event.
    ///
    /// Builds the inner Marmot app event (kind 9, `["t","location"]`, `pubkey`
    /// == the local identity per W9) and sends it via the engine, returning the
    /// transport event plus the circle's `nostr_group_id` and relays for the
    /// relay layer to publish.
    ///
    /// The per-send NIP-40 expiration is dropped (retention is now a group-level
    /// `message-retention.v1` component, not a per-message tag — `dm2_report` #2);
    /// `update_interval_secs` is retained for signature stability but unused.
    ///
    /// # Errors
    ///
    /// Returns an error if the circle is not found, serialization fails, or the
    /// engine rejects the send.
    pub async fn encrypt_location(
        &self,
        mls_group_id: &GroupId,
        _sender_pubkey: &PublicKey,
        location: &LocationMessage,
        _update_interval_secs: u64,
    ) -> Result<(Event, [u8; 32], Vec<String>)> {
        let circle = self
            .storage
            .get_circle(mls_group_id)?
            .ok_or_else(|| CircleError::NotFound("Circle not found: <redacted>".to_string()))?;

        let content = location.to_string().map_err(|e| {
            CircleError::Mls(format!(
                "Failed to serialize location: {}",
                redact_hex_sequences(&e.to_string())
            ))
        })?;

        // `send_location` stamps the inner pubkey with the session identity (W9)
        // and generates a fresh ephemeral key per 445 (Rule 2, engine-owned).
        let effects = self
            .session
            .send_location(mls_group_id, content)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
        let event = take_app_message(effects)?;

        Ok((event, circle.nostr_group_id, circle.relays))
    }

    /// The group relays a `kind:445` commit routes to, resolved from its `#h`
    /// (`nostr_group_id`) tag against the local circle rows.
    ///
    /// Used by the receive-side auto-commit publisher
    /// ([`crate::relay::auto_commit`]) to target a peer `SelfRemove` eviction
    /// commit at the correct circle's relays. Returns `None` (fail closed — the
    /// caller then rolls the commit back rather than publish it nowhere) when the
    /// `#h` tag is absent/malformed or no local circle matches.
    #[must_use]
    pub fn relays_for_commit_event(&self, event: &Event) -> Option<Vec<String>> {
        let ngid = nostr_group_id_from_commit_event(event)?;
        let circles = self.storage.get_all_circles().ok()?;
        circles
            .into_iter()
            .find(|c| c.nostr_group_id == ngid)
            .map(|c| c.relays)
    }

    /// Decrypts / ingests a received kind 445 event, returning the folded
    /// location-facing results AND any receive-side auto-commit(s) the engine
    /// staged (a peer `SelfRemove` eviction).
    ///
    /// Ingests the transport message, drains the engine's emitted
    /// [`GroupEvent`]s, advances stored convergence for any group with pending
    /// convergence, folds each event into a [`LocationMessageResult`], and
    /// collects every [`PublishWork::AutoPublish`] into a [`CommitToPublish`].
    ///
    /// Publish-before-apply (Rule 13): the caller MUST publish each returned
    /// [`DecryptedIngest::auto_commits`] entry's `commit_event` to the circle's
    /// relays and then [`Self::confirm_published`] on a ≥1-relay ack (or
    /// [`Self::publish_failed`] on failure) — exactly like [`CommitToPublish`]
    /// from the send paths. An auto-commit that cannot be serialized is rolled
    /// back here (never surfaced half-formed).
    ///
    /// # Errors
    ///
    /// Returns an error only for a hard ingest failure.
    pub async fn decrypt_location_collecting_commits(
        &self,
        event: &Event,
    ) -> Result<DecryptedIngest> {
        let ingest = self
            .session
            .process_event(event)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;

        let mut results = fold_group_events(&ingest.effects.events);
        let mut auto_commits = Vec::new();
        self.collect_auto_commits(&ingest.effects.publish, &mut auto_commits)
            .await;

        // Release any queued work + buffered inbound now safe to apply, re-ticking
        // a group that stays pending until its jitter-delayed `SelfRemove`
        // auto-commit surfaces (bounded) — a single advance would drain the group
        // out of the engine's pending set before the auto-commit's wall-clock due
        // time, so the eviction would never be surfaced for the caller to publish.
        // A quiet group exits immediately (no delay).
        let mut pending: Vec<GroupId> = ingest.effects.pending_convergence.clone();
        for _ in 0..crate::relay::auto_commit::MAX_CONVERGENCE_RETICKS {
            if pending.is_empty() {
                break;
            }
            let mut next: Vec<GroupId> = Vec::new();
            for gid in &pending {
                if let Ok(more) = self.session.advance_convergence(gid).await {
                    results.extend(fold_group_events(&more.events));
                    self.collect_auto_commits(&more.publish, &mut auto_commits)
                        .await;
                    next.extend(more.pending_convergence);
                }
            }
            pending = next;
            if !pending.is_empty() {
                tokio::time::sleep(crate::relay::auto_commit::CONVERGENCE_RETICK_DELAY).await;
            }
        }

        // Best-effort: re-derive `circle.relays` after a group update. Collect
        // ids first to avoid borrowing `results` across the await.
        let updated: Vec<GroupId> = results
            .iter()
            .filter_map(|r| match r {
                LocationMessageResult::GroupUpdate { group_id } => Some(group_id.clone()),
                _ => None,
            })
            .collect();
        for gid in updated {
            if let Err(e) = self.resync_circle_relays_from_mdk(&gid).await {
                log::debug!(
                    "decrypt_location: relay re-sync failed (will retry on next commit): {}",
                    redact_hex_sequences(&e.to_string())
                );
            }
        }

        Ok(DecryptedIngest {
            results,
            auto_commits,
        })
    }

    /// Converts each [`PublishWork::AutoPublish`] in `work` into a surfaced
    /// [`CommitToPublish`]; an auto-commit whose wrapped message cannot be
    /// serialized is rolled back ([`Self::publish_failed`]) rather than surfaced
    /// half-formed (Rule 13: never leave a pending ref dangling).
    async fn collect_auto_commits(&self, work: &[PublishWork], out: &mut Vec<CommitToPublish>) {
        for item in work {
            if let PublishWork::AutoPublish { msg, pending } = item {
                match SessionManager::transport_message_to_event(msg) {
                    Ok(commit_event) => out.push(CommitToPublish {
                        commit_event,
                        pending: *pending,
                    }),
                    Err(_) => {
                        let _ = self.publish_failed(*pending).await;
                    }
                }
            }
        }
    }

    /// Decrypts / ingests a received kind 445 event, returning ONLY the folded
    /// location-facing results.
    ///
    /// Back-compatible shim over [`Self::decrypt_location_collecting_commits`]
    /// for call sites (chiefly tests) that never trigger a peer `SelfRemove`. It
    /// does NOT surface receive-side auto-commits; to stay Rule-13-safe it rolls
    /// back ([`Self::publish_failed`]) any that surfaced rather than
    /// optimistically applying an unpublished commit. Production receive paths use
    /// [`Self::decrypt_location_collecting_commits`] (poll → Dart publishes) or
    /// the live-sync / catch-up planes (which publish in-Rust).
    ///
    /// # Errors
    ///
    /// Returns an error only for a hard ingest failure.
    pub async fn decrypt_location(&self, event: &Event) -> Result<Vec<LocationMessageResult>> {
        let ingest = self.decrypt_location_collecting_commits(event).await?;
        for commit in ingest.auto_commits {
            // No relay plane here — never apply an unpublished eviction commit.
            let _ = self.publish_failed(commit.pending).await;
        }
        Ok(ingest.results)
    }

    // ==================== Last-Known Location Cache ====================

    /// Persists a last-known-location row (authoritative retention-window and
    /// display-name sanitization enforcement point).
    ///
    /// # Errors
    ///
    /// Returns an error if the database operation fails.
    pub fn upsert_last_known_location(&self, location: &super::LastKnownLocation) -> Result<()> {
        let retention_i64 =
            i64::try_from(crate::location::LOCATION_RETENTION_SECS).unwrap_or(i64::MAX);
        let derived_purge_after = location.timestamp.saturating_add(retention_i64);

        let mut clamped = location.clone();
        clamped.purge_after = derived_purge_after;
        clamped.display_name = crate::location::types::sanitize_display_name(clamped.display_name);

        self.storage.upsert_last_known_location(&clamped)
    }

    /// Returns all non-purged last-known locations for a circle (display names
    /// re-sanitized on read).
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

    /// Produces a fresh `KeyPackage` for publishing to a directory (kind 30443).
    ///
    /// Event building / signing stays in Haven's relay layer (DM-2b); this
    /// returns the raw engine [`KeyPackage`].
    ///
    /// # Errors
    ///
    /// Returns an error if generation fails.
    pub async fn fresh_key_package(&self) -> Result<KeyPackage> {
        self.session
            .fresh_key_package()
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
    }

    /// Deletes a previously generated `KeyPackage` bundle (publish-failure cleanup;
    /// mdk#160). Idempotent.
    ///
    /// # Errors
    ///
    /// Returns an error if deletion fails.
    pub async fn delete_key_package(&self, key_package: &KeyPackage) -> Result<()> {
        self.session
            .delete_key_package(key_package)
            .await
            .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))
    }

    // ==================== Sync Cursors ====================

    /// Reads the persisted relay sync cursor (raw ms) for `stream`.
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

    /// Prunes the `processed_gift_wraps` dedup cache. Returns the number removed.
    ///
    /// # Errors
    ///
    /// Returns an error if the storage write fails.
    pub fn prune_processed_gift_wraps(&self, now_secs: i64) -> Result<u64> {
        self.storage.prune_processed_gift_wraps(now_secs)
    }

    /// Removes ALL `processed_gift_wraps` rows (wipe-on-logout).
    ///
    /// # Errors
    ///
    /// Returns an error if the storage write fails.
    pub fn wipe_all_processed_gift_wraps(&self) -> Result<()> {
        self.storage.wipe_all_processed_gift_wraps()
    }

    // ==================== Relay Preferences ====================

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
    /// Returns [`CircleError::InvalidData`] when the URL is invalid or would
    /// empty the category. Database errors otherwise.
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

    // ==================== KeyPackage maintenance (storage) ====================

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

    /// See [`CircleStorage::latest_published_key_package`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn latest_published_key_package(
        &self,
    ) -> Result<Option<super::storage_key_packages::PublishedKeyPackageRow>> {
        self.storage.latest_published_key_package()
    }

    /// See [`CircleStorage::latest_canonical_d_tag`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn latest_canonical_d_tag(&self) -> Result<Option<String>> {
        self.storage.latest_canonical_d_tag()
    }

    /// See [`CircleStorage::wipe_published_key_packages`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn wipe_published_key_packages(&self) -> Result<()> {
        self.storage.wipe_published_key_packages()
    }

    /// See [`CircleStorage::legacy_kp_retraction_done`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn legacy_kp_retraction_done(&self) -> Result<bool> {
        self.storage.legacy_kp_retraction_done()
    }

    /// See [`CircleStorage::mark_legacy_kp_retraction_done`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn mark_legacy_kp_retraction_done(&self) -> Result<()> {
        self.storage.mark_legacy_kp_retraction_done()
    }

    // ==================== Public-profile cache (storage) ====================

    /// See [`CircleStorage::upsert_profile`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn upsert_profile(&self, cached: &crate::profile::CachedProfile) -> Result<()> {
        self.storage.upsert_profile(cached)
    }

    /// See [`CircleStorage::upsert_profile_if_newer`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn upsert_profile_if_newer(&self, cached: &crate::profile::CachedProfile) -> Result<bool> {
        self.storage.upsert_profile_if_newer(cached)
    }

    /// See [`CircleStorage::get_profile`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn get_profile(&self, pubkey_hex: &str) -> Result<Option<crate::profile::CachedProfile>> {
        self.storage.get_profile(pubkey_hex)
    }

    /// See [`CircleStorage::get_profiles`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn get_profiles(
        &self,
        pubkeys_hex: &[String],
    ) -> Result<Vec<crate::profile::CachedProfile>> {
        self.storage.get_profiles(pubkeys_hex)
    }

    /// See [`CircleStorage::mark_profiles_unknown`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn mark_profiles_unknown(&self, pubkeys_hex: &[String], now_unix_secs: i64) -> Result<()> {
        self.storage
            .mark_profiles_unknown(pubkeys_hex, now_unix_secs)
    }

    /// See [`CircleStorage::upsert_profile_picture`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn upsert_profile_picture(
        &self,
        pubkey_hex: &str,
        url: &str,
        sha256: &[u8],
        canonical: &[u8],
        thumbnail: &[u8],
        updated_at: i64,
    ) -> Result<()> {
        self.storage
            .upsert_profile_picture(pubkey_hex, url, sha256, canonical, thumbnail, updated_at)
    }

    /// See [`CircleStorage::get_profile_thumbnail`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn get_profile_thumbnail(
        &self,
        pubkey_hex: &str,
    ) -> Result<Option<zeroize::Zeroizing<Vec<u8>>>> {
        self.storage.get_profile_thumbnail(pubkey_hex)
    }

    /// See [`CircleStorage::get_profile_picture`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn get_profile_picture(
        &self,
        pubkey_hex: &str,
    ) -> Result<Option<zeroize::Zeroizing<Vec<u8>>>> {
        self.storage.get_profile_picture(pubkey_hex)
    }

    /// See [`CircleStorage::get_profile_picture_url`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn get_profile_picture_url(&self, pubkey_hex: &str) -> Result<Option<String>> {
        self.storage.get_profile_picture_url(pubkey_hex)
    }

    /// See [`CircleStorage::has_current_picture`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn has_current_picture(&self, pubkey_hex: &str, current_url: Option<&str>) -> Result<bool> {
        self.storage.has_current_picture(pubkey_hex, current_url)
    }

    /// See [`CircleStorage::delete_profile_picture`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn delete_profile_picture(&self, pubkey_hex: &str) -> Result<()> {
        self.storage.delete_profile_picture(pubkey_hex)
    }

    /// See [`CircleStorage::has_published_profile`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn has_published_profile(&self, pubkey: &PublicKey) -> Result<bool> {
        self.storage.has_published_profile(pubkey)
    }

    /// See [`CircleStorage::wipe_all_profiles`].
    ///
    /// # Errors
    ///
    /// Propagates database errors.
    pub fn wipe_all_profiles(&self) -> Result<()> {
        self.storage.wipe_all_profiles()
    }
}

/// Parses invitee `KeyPackage` events (kind 30443) into engine [`KeyPackage`]s.
fn parse_key_packages(events: &[Event]) -> Result<Vec<KeyPackage>> {
    events
        .iter()
        .map(|e| {
            SessionManager::key_package_from_event(e)
                .map_err(|err| CircleError::Mls(redact_hex_sequences(&err.to_string())))
        })
        .collect()
}

/// Emits a redacted debug note if a send/create drain would drop a Rule-13
/// resync signal, so the occurrence is never SILENT (Rust F1).
///
/// The `take_*` helpers extract only [`PublishWork`]; they intentionally ignore
/// `effects.events`. Engine [`GroupEvent`]s are folded to location results ONLY
/// on the ingest / `advance_convergence` path
/// ([`CircleManager::decrypt_location_collecting_commits`] → [`fold_group_events`]),
/// which is Haven's authoritative resync driver and always runs first after open
/// (startup relay catch-up) — so a hydrate-emitted `PendingCommitRecovered` /
/// `GroupHydrationRecovered` surfaces there and maps to a `GroupUpdate`. In the
/// corner case where a send/create is somehow the first post-open drain, these
/// events would be consumed here; this logs a redacted, group-id-free note
/// rather than dropping them without a trace.
fn note_dropped_resync_events(events: &[GroupEvent]) {
    let dropped = events
        .iter()
        .filter(|e| {
            matches!(
                e,
                GroupEvent::PendingCommitRecovered { .. }
                    | GroupEvent::GroupHydrationRecovered { .. }
            )
        })
        .count();
    if dropped > 0 {
        log::debug!(
            "send/create drain observed {dropped} resync signal(s); \
             resync is authoritatively driven by the receive path"
        );
    }
}

/// Extracts the `GroupCreated { welcomes, pending }` publish work from a
/// create-group's effects.
fn take_group_created(effects: SessionEffects) -> Result<(Vec<TransportMessage>, PendingStateRef)> {
    note_dropped_resync_events(&effects.events);
    for work in effects.publish {
        if let PublishWork::GroupCreated { welcomes, pending } = work {
            return Ok((welcomes, pending));
        }
    }
    Err(CircleError::Mls(
        "create_group produced no GroupCreated publish work".to_string(),
    ))
}

/// Extracts the `GroupEvolution { commit, welcomes, pending }` publish work from
/// an invite/remove/update's effects, converting the commit to a signed Event.
fn take_group_evolution(
    effects: SessionEffects,
) -> Result<(Event, Vec<TransportMessage>, PendingStateRef)> {
    note_dropped_resync_events(&effects.events);
    for work in effects.publish {
        if let PublishWork::GroupEvolution {
            msg,
            welcomes,
            pending,
        } = work
        {
            let commit = SessionManager::transport_message_to_event(&msg)
                .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())))?;
            return Ok((commit, welcomes, pending));
        }
    }
    Err(CircleError::Mls(
        "operation produced no GroupEvolution publish work".to_string(),
    ))
}

/// Extracts the bare `Proposal { msg }` (`SelfRemove`) transport event.
fn take_proposal(effects: SessionEffects) -> Result<Event> {
    note_dropped_resync_events(&effects.events);
    for work in effects.publish {
        if let PublishWork::Proposal { msg } = work {
            return SessionManager::transport_message_to_event(&msg)
                .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())));
        }
    }
    Err(CircleError::Mls(
        "leave produced no Proposal publish work".to_string(),
    ))
}

/// Extracts the `ApplicationMessage { msg }` (location) transport event.
fn take_app_message(effects: SessionEffects) -> Result<Event> {
    note_dropped_resync_events(&effects.events);
    for work in effects.publish {
        if let PublishWork::ApplicationMessage { msg } = work {
            return SessionManager::transport_message_to_event(&msg)
                .map_err(|e| CircleError::Mls(redact_hex_sequences(&e.to_string())));
        }
    }
    Err(CircleError::Mls(
        "send produced no ApplicationMessage publish work".to_string(),
    ))
}

/// Folds an engine [`GroupEvent`] batch into location-facing results.
fn fold_group_events(events: &[GroupEvent]) -> Vec<LocationMessageResult> {
    events
        .iter()
        .filter_map(SessionManager::location_result_from_event)
        .collect()
}

/// Reads the 32-byte `nostr_group_id` from a `kind:445` event's `#h` tag
/// (`["h", "<hex>"]`), or `None` if the tag is absent / malformed. Never exposes
/// the real MLS group id (Rule 4) — the `#h` tag carries only the pseudonymous
/// routing id.
fn nostr_group_id_from_commit_event(event: &Event) -> Option<[u8; 32]> {
    let hex_str = event.tags.iter().find_map(|t| {
        let slice = t.as_slice();
        if slice.first().map(String::as_str) == Some("h") {
            slice.get(1).cloned()
        } else {
            None
        }
    })?;
    let bytes = hex::decode(hex_str).ok()?;
    bytes.try_into().ok()
}

/// Result of circle creation.
///
/// Publish-before-apply (Rule 13): publish `welcome_events`, then confirm
/// `pending`.
pub struct CircleCreationResult {
    /// The created circle.
    pub circle: Circle,
    /// Gift-wrapped Welcome events (engine-produced 1059s) ready to publish.
    pub welcome_events: Vec<GiftWrappedWelcome>,
    /// The pending group-creation state to confirm after ≥1-relay welcome ack.
    pub pending: PendingStateRef,
}

impl std::fmt::Debug for CircleCreationResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CircleCreationResult")
            .field("circle", &"<redacted>")
            .field("welcome_events_count", &self.welcome_events.len())
            .field("pending", &self.pending)
            .finish()
    }
}

/// Result of adding members to an existing circle.
///
/// Publish-before-apply (Rule 13): publish `commit_event`, confirm `pending`,
/// then publish `welcome_events`.
pub struct AddMembersResult {
    /// The kind:445 evolution (Add) commit to publish to the circle's relays.
    pub commit_event: Event,
    /// Gift-wrapped Welcome events for the newly added members. Publish only
    /// after `commit_event` is published and `pending` is confirmed.
    pub welcome_events: Vec<GiftWrappedWelcome>,
    /// The pending commit to confirm after ≥1-relay commit ack.
    pub pending: PendingStateRef,
}

impl std::fmt::Debug for AddMembersResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AddMembersResult")
            .field("commit_event", &"<redacted>")
            .field("welcome_events_count", &self.welcome_events.len())
            .field("pending", &self.pending)
            .finish()
    }
}

/// A group-evolving commit awaiting publish + confirm (remove / relay update).
pub struct CommitToPublish {
    /// The kind:445 commit to publish to the circle's relays.
    pub commit_event: Event,
    /// The pending commit to confirm after ≥1-relay ack.
    pub pending: PendingStateRef,
}

/// The folded outcome of ingesting one received `kind:445`
/// ([`CircleManager::decrypt_location_collecting_commits`]).
///
/// Carries the location-facing results AND any receive-side auto-commit the
/// engine staged (a peer `SelfRemove` eviction). Publish-before-apply (Rule 13):
/// each [`Self::auto_commits`] entry MUST be published to the circle's relays and
/// then confirmed on a ≥1-relay ack (or rolled back on failure).
pub struct DecryptedIngest {
    /// The folded location-facing results (locations, joins, updates, …).
    pub results: Vec<LocationMessageResult>,
    /// Receive-side auto-commits the caller must publish then confirm/fail.
    pub auto_commits: Vec<CommitToPublish>,
}

impl std::fmt::Debug for DecryptedIngest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DecryptedIngest")
            .field("results_count", &self.results.len())
            .field("auto_commits_count", &self.auto_commits.len())
            .finish()
    }
}

// Redacts the commit event (whose `h` tag carries the `nostr_group_id`) so a
// stray `{:?}` cannot leak group-id material (Rule 4/6).
impl std::fmt::Debug for CommitToPublish {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CommitToPublish")
            .field("commit_event", &"<redacted>")
            .field("pending", &self.pending)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    //! Dark Matter (DM-5a) re-expression of the `CircleManager` test suite.
    //!
    //! The pre-migration suite tested the hand-rolled convergence / settle-window
    //! / staged-commit-marker / peek / self-update stack that the engine now owns
    //! (plan §5.3/§5.4). Those tests are **deleted with their subject** — the
    //! subject no longer exists to test:
    //!
    //! * `converge_commit` / `CommitConvergence` / `CommitIntent` fork-selection
    //!   internals, `decrypt_receive_only` / `ReceiveOnlyOutcome::Skipped`, the
    //!   `receive_only_until_applied` contention helper, `mdk_process_message_*`,
    //!   the `no_pending_observers_*` / `sibling_commit_*` / `blind_apply_*` /
    //!   `exact_original_bug_*` / `eager_finalize_*` / `converge_*` /
    //!   `concurrent_admin_remove_*` / `rev1_*` / `auto_commit_*` /
    //!   `engine_processor_*` / `decrypt_for_engine_*` families — the engine's
    //!   `advance_convergence` + branch selection replaces Haven's picker. The
    //!   surviving INVARIANT (real out-of-order multi-party convergence with no
    //!   loss) is **re-expressed as the black-box F2 gate**
    //!   `tests/live_sync_out_of_order_commit_e2e.rs`, not here.
    //! * `m7_*` / `should3_*` staged-commit-marker tests — the marker + its
    //!   `staged_commits` table are deleted; crash recovery is now the engine's
    //!   `PendingCommitRecovered` at hydrate.
    //! * `rev1_peek_*` — `peek_crypto` is deleted (the peeler's non-destructive
    //!   outer decrypt replaces it).
    //! * `self_update` / `groups_needing_self_update` / `epoch_stable_across_idle`
    //!   — the engine converges; Haven's periodic self-update ritual is gone.
    //! * per-send NIP-40 expiration tests (`encrypt_location_attaches_expiration_*`,
    //!   `*_evolution_event_has_no_expiration_tag`, `decrypt_location_drops_expired`)
    //!   — per-message TTL is dropped (retention is a group-level
    //!   `message-retention.v1` component now, `dm2_report` #2).
    //! * `has_live_key_material_*` / `create_key_package_with_d_*` /
    //!   `*_login_key_package_*` — the M8-2 gate + `create_key_package_with_d`
    //!   dissolve (last-resort KP semantics); KP lifetime tracking is DM-2b's
    //!   `relay/maintenance/key_package.rs` suite.
    //! * `admin_handoff_end_to_end` — `propose_admin_handoff`/`propose_self_demote`
    //!   are a documented GAP (no admin-policy component codec in v0.9.4); the GAP
    //!   error is asserted below instead.
    //! * `m7b_every_mdk_write_site_acquires_the_writer_lock` — the process-global
    //!   `write_lock` is superseded by the engine's single
    //!   `tokio::sync::Mutex<AccountDeviceSession>`; the invariant is re-expressed
    //!   structurally as `single_account_device_session_construction_site` below
    //!   (Rule 14: at most one session per DB file).

    use super::*;
    use crate::nostr::mls::types::LocationMessageResult;
    use crate::relay::maintenance::build_kp_maintenance_events;
    use nostr::JsonUtil as _;
    use tempfile::TempDir;

    // ── Construction helpers (new-stack idiom) ───────────────────────────────

    fn create_test_manager() -> (CircleManager, Keys, TempDir) {
        let temp_dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let manager = CircleManager::new_unencrypted(temp_dir.path(), &keys).unwrap();
        (manager, keys, temp_dir)
    }

    /// Mints a signed kind-30443 KeyPackage event via the DM-2b maintenance
    /// builder (the real publish path), so `create_group`/`add_members` consume a
    /// KeyPackage the receiver actually produced, exactly as in production.
    async fn make_kp_event(manager: &CircleManager, keys: &Keys, relays: &[String]) -> Event {
        build_kp_maintenance_events(manager.session(), keys, relays, None)
            .await
            .expect("build key package event")
            .event
    }

    /// Builds a `MemberKeyPackage` for a fresh identity with caller-controlled
    /// delivery relays, for exercising the Welcome-delivery cascade. The member's
    /// throwaway session is dropped after minting the KP event.
    async fn make_member_with_relays(
        inbox_relays: Vec<String>,
        nip65_relays: Vec<String>,
    ) -> MemberKeyPackage {
        let kp_relays = vec!["wss://kp.example.com".to_string()];
        let member_keys = Keys::generate();
        let kp_dir = TempDir::new().unwrap();
        let member = CircleManager::new_unencrypted(kp_dir.path(), &member_keys).unwrap();
        let event = make_kp_event(&member, &member_keys, &kp_relays).await;
        MemberKeyPackage {
            key_package_event: event,
            inbox_relays,
            nip65_relays,
        }
    }

    /// A real two-party MLS circle established over the Dark Matter stack.
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

    /// Establishes a two-party circle: Alice creates with Bob's KeyPackage,
    /// confirms the pending create (publish-before-apply), then Bob holds and
    /// accepts the engine-produced gift-wrapped (1059) welcome.
    async fn setup_two_party_circle() -> TwoPartyCircle {
        let relays = vec!["wss://relay.test.com".to_string()];

        let alice_dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).unwrap();

        let bob_dir = TempDir::new().unwrap();
        let bob_keys = Keys::generate();
        let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();

        let bob_kp_event = make_kp_event(&bob, &bob_keys, &relays).await;
        let bob_member = MemberKeyPackage {
            key_package_event: bob_kp_event,
            inbox_relays: relays.clone(),
            nip65_relays: vec![],
        };

        let config = CircleConfig::new("Test Circle").with_relays(relays.clone());
        let creation = alice
            .create_circle(&alice_keys, vec![bob_member], &config, &relays)
            .await
            .expect("create two-party circle");
        alice
            .confirm_published(creation.pending)
            .await
            .expect("confirm create");

        let mls_group_id = creation.circle.mls_group_id.clone();
        let nostr_group_id = creation.circle.nostr_group_id;

        let welcome = creation.welcome_events.first().expect("one welcome");
        bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
            .await
            .expect("bob holds welcome");
        bob.accept_invitation(&welcome.event.id)
            .await
            .expect("bob accepts welcome");

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

    fn sorted_relays(v: &[String]) -> Vec<String> {
        let mut out = v.to_vec();
        out.sort();
        out.dedup();
        out
    }

    /// A random 32-byte `GroupId` for storage-only fixtures (no live MLS group).
    fn random_group_id() -> GroupId {
        GroupId::from_slice(&Keys::generate().public_key().to_bytes())
    }

    /// Returns the first `Location` result (or panics) in a decrypt batch.
    fn expect_location(results: &[LocationMessageResult]) -> (&str, &str) {
        for r in results {
            if let LocationMessageResult::Location {
                sender_pubkey,
                content,
                ..
            } = r
            {
                return (sender_pubkey, content);
            }
        }
        panic!("expected a Location result, got {results:?}");
    }

    fn save_stored_circle(manager: &CircleManager, status: MembershipStatus) {
        let now = chrono::Utc::now().timestamp();
        let gid = random_group_id();
        let circle = Circle {
            mls_group_id: gid.clone(),
            nostr_group_id: [1u8; 32],
            display_name: "Stored".to_string(),
            circle_type: CircleType::LocationSharing,
            relays: vec!["wss://relay.test.com".to_string()],
            created_at: now,
            updated_at: now,
        };
        manager.storage.save_circle(&circle).unwrap();
        manager
            .storage
            .save_membership(&CircleMembership {
                mls_group_id: gid,
                status,
                inviter_pubkey: None,
                invited_at: now,
                responded_at: Some(now),
            })
            .unwrap();
    }

    // ── Welcome-delivery cascade ─────────────────────────────────────────────

    #[tokio::test]
    async fn welcome_delivery_uses_creator_inbox_as_tier3() {
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();

        // Member advertises NO relays (empty inbox + empty NIP-65), forcing the
        // cascade down to the creator's own inbox relays (tier 3).
        let member = make_member_with_relays(vec![], vec![]).await;
        let config = CircleConfig::new("Tier3 Circle")
            .with_relays(vec!["wss://group.example.com".to_string()]);
        let creator_inbox = vec!["wss://creator-inbox.example.com".to_string()];

        let result = alice
            .create_circle(&alice_keys, vec![member], &config, &creator_inbox)
            .await
            .expect("creation should succeed using the creator's inbox as tier 3");

        assert_eq!(result.welcome_events.len(), 1);
        assert_eq!(result.welcome_events[0].recipient_relays, creator_inbox);
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
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();

        let member = make_member_with_relays(vec![], vec![]).await;
        let config = CircleConfig::new("Fail Closed Circle")
            .with_relays(vec!["wss://group.example.com".to_string()]);

        let err = alice
            .create_circle(&alice_keys, vec![member], &config, &[])
            .await
            .expect_err("creation must fail closed when no delivery relay exists");
        assert!(matches!(err, CircleError::MissingWelcomeRelays));
        assert_eq!(err.to_string(), "No reachable relay for welcome delivery");
        // No phantom state: failing closed persists NO circle.
        let circles = alice.get_circles().await.expect("get_circles");
        assert!(
            circles.is_empty(),
            "fail-closed create_circle must leave no circle in storage"
        );
    }

    // ── Create rollback / ghost-row cleanup (F2/F3) ──────────────────────────

    #[tokio::test]
    async fn create_then_publish_failed_removes_orphan_circle_row() {
        // F2: create succeeds (deliverable member) and eagerly persists a circle
        // row; then all welcomes zero-ack and the caller calls `publish_failed`.
        // The circle row MUST be rolled back — no ghost circle backed by an
        // unconfirmed group survives.
        let relays = vec!["wss://relay.test.com".to_string()];
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();

        let member = make_member_with_relays(relays.clone(), vec![]).await;
        let config = CircleConfig::new("Rollback Circle").with_relays(relays.clone());
        let creation = alice
            .create_circle(&alice_keys, vec![member], &config, &relays)
            .await
            .expect("create");

        // Before rollback the row exists (eager persistence is unchanged).
        assert_eq!(alice.get_circles().await.unwrap().len(), 1);

        alice
            .publish_failed(creation.pending)
            .await
            .expect("rollback the unconfirmed create");

        assert!(
            alice.get_circles().await.unwrap().is_empty(),
            "publish_failed on a create must remove the orphan circle row"
        );
    }

    #[tokio::test]
    async fn create_then_confirm_persists_exactly_one_circle() {
        // The happy path is unchanged: a confirmed create keeps exactly one row.
        let relays = vec!["wss://relay.test.com".to_string()];
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();

        let member = make_member_with_relays(relays.clone(), vec![]).await;
        let config = CircleConfig::new("Confirmed Circle").with_relays(relays.clone());
        let creation = alice
            .create_circle(&alice_keys, vec![member], &config, &relays)
            .await
            .expect("create");
        assert_eq!(alice.get_circles().await.unwrap().len(), 1);

        alice
            .confirm_published(creation.pending)
            .await
            .expect("confirm");
        assert_eq!(
            alice.get_circles().await.unwrap().len(),
            1,
            "a confirmed create persists exactly one circle"
        );

        // A stray publish_failed after confirm must NOT delete the now-live row
        // (the create binding was dropped on confirm). It errors on the unknown
        // pending; the circle survives.
        let _ = alice.publish_failed(creation.pending).await;
        assert_eq!(
            alice.get_circles().await.unwrap().len(),
            1,
            "a confirmed circle must survive a stray publish_failed"
        );
    }

    #[tokio::test]
    async fn create_route_error_rolls_back_pending_and_leaves_no_row() {
        // F3: exercise the internal helper directly so `route_welcomes_with_cascade`
        // fails AFTER the MLS group + storage rows are staged (a member with no
        // delivery relay and no creator fallback). The post-stage error path MUST
        // roll the pending back and leave NO orphan circle row.
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();

        let member = make_member_with_relays(vec![], vec![]).await; // undeliverable
        let group_relays = vec!["wss://group.example.com".to_string()];
        let mls_config = LocationGroupConfig::new("Route Error Circle")
            .with_relays(group_relays.iter().map(String::as_str))
            .with_admin(alice_keys.public_key().to_hex());
        let config = CircleConfig::new("Route Error Circle").with_relays(group_relays.clone());
        let kp_events = vec![member.key_package_event.clone()];

        let result = alice
            .create_circle_with_config(&[member], kp_events, mls_config, &config, &[])
            .await;
        assert!(
            matches!(result, Err(CircleError::MissingWelcomeRelays)),
            "welcome routing must fail closed for an undeliverable member"
        );

        assert!(
            alice.get_circles().await.unwrap().is_empty(),
            "a post-stage route error must roll back the ghost circle row (F2/F3)"
        );
        // The create binding was consumed by the rollback, so nothing lingers to
        // re-delete: a fresh, deliverable create then works cleanly.
        let ok_member =
            make_member_with_relays(vec!["wss://relay.test.com".to_string()], vec![]).await;
        let ok_config = CircleConfig::new("Recovered Circle")
            .with_relays(vec!["wss://relay.test.com".to_string()]);
        alice
            .create_circle(
                &alice_keys,
                vec![ok_member],
                &ok_config,
                &["wss://relay.test.com".to_string()],
            )
            .await
            .expect("a subsequent create is unaffected by the prior rollback");
        assert_eq!(alice.get_circles().await.unwrap().len(), 1);
    }

    #[test]
    fn fold_surfaces_pending_commit_recovered_as_group_update() {
        // Rust F1: the ingest/drain fold path must surface a hydrate-emitted
        // PendingCommitRecovered as a GroupUpdate (drive resync), not drop it.
        use crate::nostr::mls::types::EpochId;
        let gid = GroupId::new(vec![7, 7, 7]);
        let folded = fold_group_events(&[GroupEvent::PendingCommitRecovered {
            group_id: gid.clone(),
            recovered_epoch: EpochId(2),
        }]);
        assert!(
            matches!(
                folded.as_slice(),
                [LocationMessageResult::GroupUpdate { .. }]
            ),
            "a drained PendingCommitRecovered must fold to a GroupUpdate, got {folded:?}"
        );
    }

    // ── Basic construction / empty getters ───────────────────────────────────

    #[test]
    fn new_creates_manager() {
        let (_manager, _keys, _dir) = create_test_manager();
    }

    #[tokio::test]
    async fn get_circles_returns_empty_initially() {
        let (manager, _keys, _dir) = create_test_manager();
        assert!(manager.get_circles().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn get_visible_circles_returns_empty_initially() {
        let (manager, _keys, _dir) = create_test_manager();
        assert!(manager.get_visible_circles().await.unwrap().is_empty());
    }

    #[test]
    fn get_pending_invitations_returns_empty_initially() {
        let (manager, _keys, _dir) = create_test_manager();
        assert!(manager.get_pending_invitations().unwrap().is_empty());
    }

    #[test]
    fn get_all_contacts_returns_empty_initially() {
        let (manager, _keys, _dir) = create_test_manager();
        assert!(manager.get_all_contacts().unwrap().is_empty());
    }

    // ── Contacts (local-only, sync) ──────────────────────────────────────────

    #[test]
    fn set_and_get_contact() {
        let (manager, _keys, _dir) = create_test_manager();
        let pk = Keys::generate().public_key().to_hex();
        let contact = manager
            .set_contact(&pk, Some("Alice"), Some("note"))
            .unwrap();
        assert_eq!(contact.display_name.as_deref(), Some("Alice"));
        let fetched = manager.get_contact(&pk).unwrap().unwrap();
        assert_eq!(fetched.display_name.as_deref(), Some("Alice"));
        assert_eq!(fetched.notes.as_deref(), Some("note"));
    }

    #[test]
    fn set_contact_updates_existing() {
        let (manager, _keys, _dir) = create_test_manager();
        let pk = Keys::generate().public_key().to_hex();
        let first = manager.set_contact(&pk, Some("Old"), None).unwrap();
        let second = manager.set_contact(&pk, Some("New"), None).unwrap();
        assert_eq!(second.display_name.as_deref(), Some("New"));
        assert_eq!(first.created_at, second.created_at, "created_at preserved");
    }

    #[test]
    fn delete_contact_removes_it() {
        let (manager, _keys, _dir) = create_test_manager();
        let pk = Keys::generate().public_key().to_hex();
        manager.set_contact(&pk, Some("X"), None).unwrap();
        manager.delete_contact(&pk).unwrap();
        assert!(manager.get_contact(&pk).unwrap().is_none());
    }

    #[test]
    fn get_contact_nonexistent_returns_none() {
        let (manager, _keys, _dir) = create_test_manager();
        let pk = Keys::generate().public_key().to_hex();
        assert!(manager.get_contact(&pk).unwrap().is_none());
    }

    #[tokio::test]
    async fn get_circle_nonexistent_returns_none() {
        let (manager, _keys, _dir) = create_test_manager();
        assert!(manager
            .get_circle(&random_group_id())
            .await
            .unwrap()
            .is_none());
    }

    // ── Stored-data getters (storage-only, no live MLS group) ─────────────────

    #[tokio::test]
    async fn get_circles_with_stored_data() {
        let (manager, _keys, _dir) = create_test_manager();
        save_stored_circle(&manager, MembershipStatus::Accepted);
        let circles = manager.get_circles().await.unwrap();
        assert_eq!(circles.len(), 1);
        // A stored-only circle (no live MLS group) tolerates an empty roster.
        assert!(circles[0].members.is_empty());
    }

    #[tokio::test]
    async fn get_visible_circles_filters_declined() {
        let (manager, _keys, _dir) = create_test_manager();
        save_stored_circle(&manager, MembershipStatus::Accepted);
        save_stored_circle(&manager, MembershipStatus::Declined);
        assert_eq!(manager.get_circles().await.unwrap().len(), 2);
        assert_eq!(manager.get_visible_circles().await.unwrap().len(), 1);
    }

    // ── MIP-01 group-relay update (admin) + member convergence ───────────────

    #[tokio::test]
    async fn admin_relay_update_converges_admin_and_member() {
        let tp = setup_two_party_circle().await;
        let new_relays = vec![
            "wss://relay.test.com".to_string(),
            "wss://relay2.test.com".to_string(),
        ];

        let update = tp
            .alice
            .update_circle_relays(&tp.mls_group_id, &new_relays)
            .await
            .expect("admin must be allowed to update relays");

        // Publish-before-apply: before finalize, the admin's app row is unchanged.
        let alice_before = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            alice_before.relays, tp.relays,
            "circle.relays must not change before the commit is confirmed"
        );

        tp.alice
            .finalize_relay_update(update.pending, &tp.mls_group_id)
            .await
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
            "admin circle.relays must converge to the new set after confirm"
        );

        // The member (Bob) processes the commit through the REAL consumer path.
        let results = tp
            .bob
            .decrypt_location(&update.commit_event)
            .await
            .expect("bob processes the relay-update commit");
        assert!(
            results
                .iter()
                .any(|r| matches!(r, LocationMessageResult::GroupUpdate { .. })),
            "a routing-component commit must surface as GroupUpdate, got {results:?}"
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

    #[tokio::test]
    async fn admin_relay_replacement_drops_old_relay_and_converges() {
        let tp = setup_two_party_circle().await;
        let new_relays = vec!["wss://relay2.test.com".to_string()];

        let update = tp
            .alice
            .update_circle_relays(&tp.mls_group_id, &new_relays)
            .await
            .expect("admin replaces the relay set");
        tp.alice
            .finalize_relay_update(update.pending, &tp.mls_group_id)
            .await
            .expect("admin finalize");

        let expected = sorted_relays(&new_relays);
        let dropped = "wss://relay.test.com".to_string();

        let alice_after = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(alice_after.relays, expected);
        assert!(!alice_after.relays.contains(&dropped));

        let results = tp
            .bob
            .decrypt_location(&update.commit_event)
            .await
            .expect("bob processes the replacement commit");
        assert!(results
            .iter()
            .any(|r| matches!(r, LocationMessageResult::GroupUpdate { .. })));
        let bob_after = tp
            .bob
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(bob_after.relays, expected);
        assert!(!bob_after.relays.contains(&dropped));
        assert_eq!(alice_after.relays, bob_after.relays);
    }

    #[tokio::test]
    async fn non_admin_relay_update_is_rejected_and_changes_nothing() {
        let tp = setup_two_party_circle().await;
        // Bob is a plain member — the engine enforces admin-only routing commits.
        let result = tp
            .bob
            .update_circle_relays(&tp.mls_group_id, &["wss://relay2.test.com".to_string()])
            .await;
        assert!(
            matches!(result, Err(CircleError::Mls(_))),
            "the engine must reject a non-admin relay update, got {result:?}"
        );
        let bob_circle = tp
            .bob
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(bob_circle.relays, tp.relays);
    }

    #[tokio::test]
    async fn update_circle_relays_rejects_empty_set() {
        let tp = setup_two_party_circle().await;
        assert!(matches!(
            tp.alice.update_circle_relays(&tp.mls_group_id, &[]).await,
            Err(CircleError::InvalidData(_))
        ));
        let circle = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(circle.relays, tp.relays, "no commit staged on rejection");
    }

    #[tokio::test]
    async fn update_circle_relays_rejects_oversized_set() {
        let tp = setup_two_party_circle().await;
        let many: Vec<String> = (0..=CircleManager::MAX_CIRCLE_RELAYS)
            .map(|i| format!("wss://relay{i}.test.com"))
            .collect();
        assert!(many.len() > CircleManager::MAX_CIRCLE_RELAYS);
        assert!(matches!(
            tp.alice.update_circle_relays(&tp.mls_group_id, &many).await,
            Err(CircleError::InvalidData(_))
        ));
    }

    #[tokio::test]
    async fn update_circle_relays_rejects_plaintext_ws() {
        let tp = setup_two_party_circle().await;
        assert!(matches!(
            tp.alice
                .update_circle_relays(&tp.mls_group_id, &["ws://relay.test.com".to_string()])
                .await,
            Err(CircleError::InvalidData(_))
        ));
    }

    #[tokio::test]
    async fn resync_is_idempotent_noop_when_already_converged() {
        let tp = setup_two_party_circle().await;
        let before = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        tp.alice
            .resync_circle_relays_from_mdk(&tp.mls_group_id)
            .await
            .expect("resync");
        let after = tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(before.relays, after.relays);
    }
    // DELETED-WITH-SUBJECT: `resync_never_overwrites_nonempty_relays_with_empty`
    // drove the hazard via `mdk.update_relays(&[])` — the UNVALIDATED empty relay
    // update. The session's `validate_group_relays` now rejects an empty set at
    // the source (both `update_relays` and `create_group`), so the engine never
    // holds an empty routing set and the hazard is unreachable from the public
    // API. The defensive `if engine_relays.is_empty()` guard in
    // `resync_circle_relays_from_mdk` remains but cannot be driven.

    // ── Leave planning + local teardown ──────────────────────────────────────

    #[tokio::test]
    async fn plan_leave_non_admin_member_returns_non_admin() {
        let tp = setup_two_party_circle().await;
        let plan = tp
            .bob
            .plan_leave(&tp.mls_group_id, &tp.bob_keys.public_key())
            .await
            .expect("plan_leave for non-admin");
        assert!(matches!(plan, LeavePlan::NonAdmin));
    }

    #[tokio::test]
    async fn plan_leave_sole_admin_with_member_returns_handoff() {
        let tp = setup_two_party_circle().await;
        let plan = tp
            .alice
            .plan_leave(&tp.mls_group_id, &tp.alice_keys.public_key())
            .await
            .expect("plan_leave for sole admin");
        let LeavePlan::AdminHandoff { successor } = plan else {
            panic!("expected AdminHandoff, got {plan:?}");
        };
        assert_eq!(successor, tp.bob_keys.public_key());
    }

    #[tokio::test]
    async fn plan_leave_nonexistent_group_returns_orphan() {
        let (manager, _keys, _dir) = create_test_manager();
        let self_pk = Keys::generate().public_key();
        let plan = manager
            .plan_leave(&GroupId::from_slice(&[0u8; 32]), &self_pk)
            .await
            .expect("plan_leave should succeed for missing group");
        assert!(matches!(plan, LeavePlan::OrphanLocalOnly));
    }

    #[tokio::test]
    async fn propose_admin_handoff_is_a_documented_gap() {
        // RE-EXPRESSED from `admin_handoff_end_to_end`: v0.9.4 exposes no
        // admin-policy component codec, so post-hoc admin grant / self-demote are
        // a documented GAP that fails with a clear (redacted) error rather than
        // silently succeeding.
        let tp = setup_two_party_circle().await;
        assert!(matches!(
            tp.alice
                .propose_admin_handoff(&tp.mls_group_id, &tp.bob_keys.public_key())
                .await,
            Err(CircleError::Mls(_))
        ));
        assert!(matches!(
            tp.alice.propose_self_demote(&tp.mls_group_id).await,
            Err(CircleError::Mls(_))
        ));
    }

    #[test]
    fn complete_leave_nonexistent_group_succeeds() {
        let (manager, _keys, _dir) = create_test_manager();
        manager
            .complete_leave(&GroupId::from_slice(&[0u8; 32]))
            .expect("complete_leave should not fail when row is missing");
    }

    #[tokio::test]
    async fn complete_leave_removes_circle_row() {
        // DM has no per-group MLS delete (the `complete_leave_purges_mdk_state`
        // subject is gone); `complete_leave` removes the local circle row and its
        // cascade. The engine keeps its own `removed`-marked copy.
        let tp = setup_two_party_circle().await;
        assert!(tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .is_some());
        tp.alice
            .complete_leave(&tp.mls_group_id)
            .expect("complete_leave");
        assert!(tp
            .alice
            .storage
            .get_circle(&tp.mls_group_id)
            .unwrap()
            .is_none());
    }

    #[tokio::test]
    async fn complete_leave_purges_per_circle_sync_cursor() {
        let tp = setup_two_party_circle().await;
        let key = crate::relay::live_sync::processor::group_cursor_stream(&hex::encode(
            tp.nostr_group_id,
        ));
        tp.alice
            .advance_sync_cursor(&key, 1_700_000_000_000)
            .expect("advance cursor");
        assert!(tp.alice.read_sync_cursor(&key).unwrap().is_some());
        tp.alice
            .complete_leave(&tp.mls_group_id)
            .expect("complete_leave");
        assert!(
            tp.alice.read_sync_cursor(&key).unwrap().is_none(),
            "the per-circle group cursor must be purged on leave (wipe-on-leave)"
        );
    }

    #[tokio::test]
    async fn propose_leave_by_non_admin_returns_proposal_event() {
        let tp = setup_two_party_circle().await;
        let ev = tp
            .bob
            .propose_leave(&tp.mls_group_id)
            .await
            .expect("non-admin bob can propose SelfRemove");
        assert_eq!(ev.kind.as_u16(), 445);
    }

    #[tokio::test]
    async fn propose_leave_by_sole_admin_is_rejected() {
        let tp = setup_two_party_circle().await;
        // Alice is the sole admin — the engine's AdminCannotSelfRemove gate
        // rejects a bare SelfRemove until she exits the admin set first.
        assert!(matches!(
            tp.alice.propose_leave(&tp.mls_group_id).await,
            Err(CircleError::Mls(_))
        ));
    }

    // ── Member management ────────────────────────────────────────────────────

    #[tokio::test]
    async fn add_members_nonexistent_group_fails() {
        let (manager, _keys, _dir) = create_test_manager();
        let member = make_member_with_relays(vec!["wss://r.test".to_string()], vec![]).await;
        let res = manager
            .add_members(
                &GroupId::from_slice(&[0u8; 32]),
                &[member.key_package_event],
            )
            .await;
        assert!(res.is_err());
    }

    #[tokio::test]
    async fn remove_members_nonexistent_group_fails() {
        let (manager, _keys, _dir) = create_test_manager();
        let res = manager
            .remove_members(
                &GroupId::from_slice(&[0u8; 32]),
                &[Keys::generate().public_key().to_hex()],
            )
            .await;
        assert!(res.is_err());
    }

    #[tokio::test]
    async fn get_members_nonexistent_group_fails() {
        let (manager, _keys, _dir) = create_test_manager();
        assert!(manager
            .get_members(&GroupId::from_slice(&[0u8; 32]))
            .await
            .is_err());
    }

    #[tokio::test]
    async fn get_members_returns_roster_with_admin_flag() {
        let tp = setup_two_party_circle().await;
        let members = tp.alice.get_members(&tp.mls_group_id).await.unwrap();
        assert_eq!(members.len(), 2, "alice + bob");
        let alice_hex = tp.alice_keys.public_key().to_hex();
        let bob_hex = tp.bob_keys.public_key().to_hex();
        let alice = members.iter().find(|m| m.pubkey == alice_hex).unwrap();
        let bob = members.iter().find(|m| m.pubkey == bob_hex).unwrap();
        assert!(alice.is_admin, "creator is admin");
        assert!(!bob.is_admin, "invitee is not admin");
    }

    #[tokio::test]
    async fn remove_members_flow_evicts_the_member() {
        let tp = setup_two_party_circle().await;
        let bob_hex = tp.bob_keys.public_key().to_hex();
        let commit = tp
            .alice
            .remove_members(&tp.mls_group_id, &[bob_hex.clone()])
            .await
            .expect("admin removes bob");
        assert_eq!(commit.commit_event.kind.as_u16(), 445);
        tp.alice
            .confirm_published(commit.pending)
            .await
            .expect("confirm remove");
        let members = tp.alice.get_members(&tp.mls_group_id).await.unwrap();
        assert!(
            members.iter().all(|m| m.pubkey != bob_hex),
            "bob must be gone from alice's roster after confirm"
        );
    }

    #[tokio::test]
    async fn add_members_with_welcomes_produces_one_welcome_per_member() {
        let tp = setup_two_party_circle().await;
        let carol = make_member_with_relays(vec!["wss://carol.test".to_string()], vec![]).await;
        let result = tp
            .alice
            .add_members_with_welcomes(&tp.alice_keys, &tp.mls_group_id, vec![carol], &tp.relays)
            .await
            .expect("admin adds carol");
        assert_eq!(result.welcome_events.len(), 1);
        assert_eq!(result.commit_event.kind.as_u16(), 445);
    }

    #[tokio::test]
    async fn add_members_with_welcomes_fails_closed_with_no_relays() {
        let tp = setup_two_party_circle().await;
        let carol = make_member_with_relays(vec![], vec![]).await;
        let err = tp
            .alice
            .add_members_with_welcomes(&tp.alice_keys, &tp.mls_group_id, vec![carol], &[])
            .await
            .expect_err("no delivery relay must fail closed");
        assert!(matches!(err, CircleError::MissingWelcomeRelays));
    }

    #[tokio::test]
    async fn add_members_with_welcomes_non_admin_rejected() {
        let tp = setup_two_party_circle().await;
        let carol = make_member_with_relays(vec!["wss://carol.test".to_string()], vec![]).await;
        let res = tp
            .bob
            .add_members_with_welcomes(&tp.bob_keys, &tp.mls_group_id, vec![carol], &tp.relays)
            .await;
        assert!(matches!(res, Err(CircleError::Mls(_))));
    }

    // ── Invitations (hold-before-ingest) ─────────────────────────────────────

    #[tokio::test]
    async fn accept_invitation_nonexistent_fails() {
        let (manager, _keys, _dir) = create_test_manager();
        let res = manager.accept_invitation(&EventId::all_zeros()).await;
        assert!(matches!(res, Err(CircleError::NotFound(_))));
    }

    #[test]
    fn decline_invitation_nonexistent_is_idempotent() {
        // Decline is a local drop + resolution sentinel; it never touches the
        // wire (Rule 10) and is idempotent even with nothing held.
        let (manager, _keys, _dir) = create_test_manager();
        manager.decline_invitation(&EventId::all_zeros()).unwrap();
    }

    #[tokio::test]
    async fn accept_invitation_materializes_circle_and_membership() {
        // The setup already accepts Bob's welcome; assert the resulting state.
        let tp = setup_two_party_circle().await;
        let circle = tp
            .bob
            .get_circle(&tp.mls_group_id)
            .await
            .unwrap()
            .expect("bob has the circle after accepting");
        assert!(circle.membership.status.is_visible());
        assert_eq!(
            circle.membership.inviter_pubkey,
            Some(tp.alice_keys.public_key().to_hex())
        );
        assert!(tp.bob.get_pending_invitations().unwrap().is_empty());
    }

    #[tokio::test]
    async fn reprocess_accepted_invitation_returns_already_processed() {
        let dir = TempDir::new().unwrap();
        let alice_keys = Keys::generate();
        let alice = CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap();

        let bob_dir = TempDir::new().unwrap();
        let bob_keys = Keys::generate();
        let bob = CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap();

        let relays = vec!["wss://relay.test.com".to_string()];
        let bob_kp = make_kp_event(&bob, &bob_keys, &relays).await;
        let member = MemberKeyPackage {
            key_package_event: bob_kp,
            inbox_relays: relays.clone(),
            nip65_relays: vec![],
        };
        let config = CircleConfig::new("Dedup Circle").with_relays(relays.clone());
        let creation = alice
            .create_circle(&alice_keys, vec![member], &config, &relays)
            .await
            .unwrap();
        alice.confirm_published(creation.pending).await.unwrap();
        let welcome = &creation.welcome_events[0];

        bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
            .await
            .unwrap();
        bob.accept_invitation(&welcome.event.id).await.unwrap();

        // A second hold attempt after acceptance is rejected by the dedup row.
        let re = bob
            .process_gift_wrapped_invitation(&bob_keys, &welcome.event)
            .await;
        assert!(matches!(re, Err(CircleError::AlreadyProcessed)));
    }

    // ── Location sharing ─────────────────────────────────────────────────────

    #[tokio::test]
    async fn encrypt_location_nonexistent_circle_fails() {
        let (manager, keys, _dir) = create_test_manager();
        let loc = crate::location::LocationMessage::new(1.0, 2.0);
        let res = manager
            .encrypt_location(
                &GroupId::from_slice(&[0u8; 32]),
                &keys.public_key(),
                &loc,
                60,
            )
            .await;
        assert!(matches!(res, Err(CircleError::NotFound(_))));
    }

    #[tokio::test]
    async fn encrypt_location_returns_correct_metadata() {
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(37.7, -122.4);
        let (event, nostr_group_id, relays) = tp
            .alice
            .encrypt_location(&tp.mls_group_id, &tp.alice_keys.public_key(), &loc, 60)
            .await
            .expect("encrypt");
        assert_eq!(event.kind.as_u16(), 445);
        assert_eq!(nostr_group_id, tp.nostr_group_id);
        assert_eq!(relays, tp.relays);
    }

    #[tokio::test]
    async fn encrypt_location_and_decrypt_roundtrip() {
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(51.5, -0.12);
        let (event, _ngid, _relays) = tp
            .alice
            .encrypt_location(&tp.mls_group_id, &tp.alice_keys.public_key(), &loc, 60)
            .await
            .expect("alice encrypts");

        let results = tp.bob.decrypt_location(&event).await.expect("bob decrypts");
        let (sender, content) = expect_location(&results);
        assert_eq!(sender, tp.alice_keys.public_key().to_hex());
        let decoded = crate::location::LocationMessage::from_string(content).expect("parse");
        assert!((decoded.latitude - 51.5).abs() < 1e-9);
        assert!((decoded.longitude - -0.12).abs() < 1e-9);
    }

    #[tokio::test]
    async fn decrypt_location_bidirectional() {
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(10.0, 20.0);
        let (event, _n, _r) = tp
            .bob
            .encrypt_location(&tp.mls_group_id, &tp.bob_keys.public_key(), &loc, 60)
            .await
            .expect("bob encrypts");
        let results = tp
            .alice
            .decrypt_location(&event)
            .await
            .expect("alice decrypts");
        let (sender, _content) = expect_location(&results);
        assert_eq!(sender, tp.bob_keys.public_key().to_hex());
    }

    #[tokio::test]
    async fn encrypt_location_inner_event_carries_no_group_identifier() {
        // Rule 4: a published kind:445 must carry the pseudonymous
        // nostr_group_id, never the real MLS GroupId.
        let tp = setup_two_party_circle().await;
        let loc = crate::location::LocationMessage::new(1.0, 2.0);
        let (event, nostr_group_id, _relays) = tp
            .alice
            .encrypt_location(&tp.mls_group_id, &tp.alice_keys.public_key(), &loc, 60)
            .await
            .expect("encrypt");

        let raw_mls_hex = hex::encode(tp.mls_group_id.as_slice());
        let nostr_hex = hex::encode(nostr_group_id);
        assert_ne!(raw_mls_hex, nostr_hex);
        let json = event.as_json();
        assert!(
            !json.contains(&raw_mls_hex),
            "the real MLS group id must never appear in a published 445"
        );
        assert!(
            json.contains(&nostr_hex),
            "the pseudonymous nostr_group_id should appear (in the h tag)"
        );
    }

    #[tokio::test]
    async fn decrypt_relay_commit_surfaces_group_update() {
        let tp = setup_two_party_circle().await;
        let update = tp
            .alice
            .update_circle_relays(&tp.mls_group_id, &["wss://relay3.test.com".to_string()])
            .await
            .expect("relay update");
        tp.alice
            .confirm_published(update.pending)
            .await
            .expect("confirm");
        let results = tp
            .bob
            .decrypt_location(&update.commit_event)
            .await
            .expect("bob ingests the commit");
        assert!(results
            .iter()
            .any(|r| matches!(r, LocationMessageResult::GroupUpdate { .. })));
    }

    // ── Key packages ─────────────────────────────────────────────────────────

    #[tokio::test]
    async fn fresh_key_package_produces_bytes() {
        let (manager, _keys, _dir) = create_test_manager();
        let kp = manager.fresh_key_package().await.expect("fresh kp");
        assert!(!kp.bytes().is_empty());
    }

    #[tokio::test]
    async fn delete_key_package_is_idempotent() {
        let (manager, _keys, _dir) = create_test_manager();
        let kp = manager.fresh_key_package().await.expect("fresh kp");
        manager.delete_key_package(&kp).await.expect("first delete");
        manager
            .delete_key_package(&kp)
            .await
            .expect("idempotent delete");
    }

    // ── Publish-before-apply (Rule 13) unknown-ref rejection ─────────────────

    #[tokio::test]
    async fn confirm_published_unknown_pending_fails() {
        let (manager, _keys, _dir) = create_test_manager();
        let bogus = PendingStateRef::new(u64::MAX);
        assert!(manager.confirm_published(bogus).await.is_err());
    }

    #[tokio::test]
    async fn publish_failed_unknown_pending_fails() {
        let (manager, _keys, _dir) = create_test_manager();
        let bogus = PendingStateRef::new(u64::MAX);
        assert!(manager.publish_failed(bogus).await.is_err());
    }

    // ── Rule 14 (single-session) — RE-EXPRESSED write-site guard ─────────────

    /// Recursively collects `path:line` sites where `needle` appears in a
    /// non-comment source line under `dir`.
    fn walk_for_sites(dir: &std::path::Path, needle: &str, sites: &mut Vec<String>) {
        for entry in std::fs::read_dir(dir).expect("read_dir") {
            let path = entry.expect("entry").path();
            if path.is_dir() {
                walk_for_sites(&path, needle, sites);
            } else if path.extension().and_then(|e| e.to_str()) == Some("rs") {
                let src = std::fs::read_to_string(&path).expect("read source");
                for (i, line) in src.lines().enumerate() {
                    let t = line.trim_start();
                    // Skip comment / doc lines that merely name the type.
                    if t.starts_with("//") || t.starts_with('*') {
                        continue;
                    }
                    if line.contains(needle) {
                        sites.push(format!("{}:{}", path.display(), i + 1));
                    }
                }
            }
        }
    }

    #[test]
    fn single_account_device_session_construction_site() {
        // RE-EXPRESSES `m7b_every_mdk_write_site_acquires_the_writer_lock`.
        //
        // The pre-migration invariant ("every MDK write acquires the process
        // global `write_lock`") is superseded by the engine's own
        // `tokio::sync::Mutex<AccountDeviceSession>`: `&mut self` on every mutator
        // means the single session mutex IS the write serializer. The stronger
        // Rule-14 invariant that replaces it is STRUCTURAL: at most one live
        // `AccountDeviceSession` is ever constructed per DB file across all
        // isolates — divergent hydrated epoch state would erode forward secrecy
        // (security F4). This guard asserts the ONLY `AccountDeviceSession::open`
        // construction site in the whole crate is the sanctioned one inside
        // `SessionManager::open_session`; every other access reuses that one
        // handle (`Arc<SessionManager>`), never opening a second session.
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        // Built by concatenation so THIS scanner's own source line does not
        // contain the literal needle and thus never self-matches.
        let needle = concat!("AccountDeviceSession", "::open(");
        let mut sites: Vec<String> = Vec::new();
        walk_for_sites(&root, needle, &mut sites);
        assert_eq!(
            sites.len(),
            1,
            "exactly one AccountDeviceSession::open construction site is allowed \
             (Rule 14: one live session per DB file); found: {sites:?}"
        );
        assert!(
            sites[0].replace('\\', "/").contains("nostr/mls/manager.rs"),
            "the single session construction site must live in \
             SessionManager::open_session, found {}",
            sites[0]
        );
    }
}
