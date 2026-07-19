//! Session manager for group and message operations (Marmot "Dark Matter").
//!
//! This module provides [`SessionManager`], Haven's interface to the Dark
//! Matter MLS engine. It replaces the old `MdkManager` (an interior-mutable,
//! all-`&self`, synchronous wrapper over `MDK<MdkSqliteStorage>`) with a
//! wrapper over a `tokio::sync::Mutex<AccountDeviceSession>`.
//!
//! # Locking model (plan §5.3)
//!
//! The engine hydrates authoritative group state into memory at `open()` and
//! all mutating engine calls take `&mut self`. Haven serializes every writer
//! through one `tokio::sync::Mutex`, replacing the old process-global
//! `write_lock`. Because the mutators `.await` internally, the guard is held
//! across await points, which mandates a `tokio` (not `std`) mutex. As a
//! consequence **every** [`SessionManager`] method that touches the session is
//! `async` — including the engine's synchronous reads — since they all acquire
//! the same async lock. **Rule 14: at most one live [`SessionManager`] per DB
//! file across all isolates.**
//!
//! # Publish-before-apply (plan §5.4, Rule 13)
//!
//! `create_group` / `add_members` / `remove_members` / `advance_convergence`
//! and inbound `ingest` return [`SessionEffects`] carrying `PublishWork` items.
//! Items tagged with a [`PendingStateRef`] (`GroupCreated` / `GroupEvolution` /
//! `AutoPublish`) are staged, not applied: the caller publishes the transport
//! message(s) through Haven's own relay layer, then calls
//! [`SessionManager::confirm_published`] on ≥1-relay ack, or
//! [`SessionManager::publish_failed`] on failure. DM-3 wires this discipline.

use std::path::Path;
use std::sync::Arc;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use nostr::{Event, JsonUtil, Keys, Kind, PublicKey, Tag, Timestamp, UnsignedEvent};
use rand::rngs::OsRng;
use rand::RngCore;
use tokio::sync::Mutex;

use cgka_engine::canonicalization::CanonicalizationPolicy;
use cgka_engine::feature_registry::FeatureRegistry;
use cgka_session::{
    AccountDeviceSession, CreateGroupEffects, IngestEffects, SessionConfig, SessionEffects,
    SessionError,
};
use cgka_traits::app_components::{
    encode_nostr_routing_v1, AppComponentData, NostrRoutingV1, GROUP_ADMIN_POLICY_COMPONENT_ID,
    GROUP_MESSAGE_RETENTION_COMPONENT_ID, GROUP_PROFILE_COMPONENT_ID, NOSTR_ROUTING_COMPONENT_ID,
};
use cgka_traits::capabilities::{Capability, CapabilityRequirement, Feature, RequirementLevel};
use cgka_traits::engine::{CreateGroupRequest, GroupEvent, KeyPackage, SendIntent};
use cgka_traits::engine_state::PendingStateRef;
use cgka_traits::error::EngineError;
use cgka_traits::group::{Group, Member};
use cgka_traits::peeler::TransportPeeler;
use cgka_traits::types::{GroupId, MemberId, MessageId};
use storage_sqlite::SqlCipherKey;
use transport_nostr_peeler::{NostrMlsPeeler, NostrTransportEvent};

use super::signer::HavenIdentityProofSigner;
use super::storage::{LiveSessionGuard, StorageConfig};
use super::types::{LocationGroupConfig, LocationMessageResult};
use super::welcome::WelcomePreview;
use crate::nostr::error::{NostrError, Result};

// `redact_hex_sequences` lives in the neutral `crate::util` module. Re-exported
// here so every `crate::nostr::mls::redact_hex_sequences` caller (circle/error,
// relay/manager) keeps working unchanged.
pub use crate::util::redact_hex_sequences;

/// Group-message exporter label used by the Dark Matter peeler
/// (`MLS-Exporter("marmot", "group-event", 32)`). Exposed for the re-expressed
/// Rule-5 exporter-secret retention test (§5.7).
pub const DEFAULT_EXPORTER_LABEL: &str = "marmot/group-event";

/// Bound on a group's relay set for NIP-59 welcome wrapping (protocol W8,
/// `peeler.rs:427-449`): the engine's internal `wrap_welcome_with_metadata`
/// fail-closes above this count, so Haven validates before create/invite.
const MAX_GROUP_WELCOME_RELAYS: usize = 16;
/// Bound on each group relay URL length in bytes (protocol W8).
const MAX_GROUP_RELAY_URL_LEN: usize = 512;

/// Maps any engine/session/peeler error into Haven's redacted MLS-error bucket.
///
/// #864 (open upstream): several `EngineError` validators embed full group-id
/// hex in their message, so [`redact_hex_sequences`] stays at this boundary
/// (Security Rule 6/8).
fn map_mls_err<E: std::fmt::Display>(e: E) -> NostrError {
    NostrError::MdkError(redact_hex_sequences(&e.to_string()))
}

/// Manager for MLS session operations over the Dark Matter engine.
///
/// Wraps a single, hydrated [`AccountDeviceSession`] behind a `tokio` mutex and
/// exposes Haven's group-lifecycle + message surface. Constructed with the
/// device's Nostr identity keys, which bind the session's account identity, its
/// NIP-59 welcome signer, and its hardened account-identity-proof signer.
pub struct SessionManager {
    /// The single live engine session. Rule 14: one per DB file, ever.
    session: Mutex<AccountDeviceSession>,
    /// The local identity public key (x-only). Used to stamp inner app-message
    /// pubkeys (W9) and to route welcomes.
    identity_pubkey: PublicKey,
    /// A standalone peeler used only to peel a gift wrap for a pre-accept
    /// preview WITHOUT ingesting it (`peel_welcome` is engine-independent). It
    /// shares the identity welcome signer with the engine's peeler.
    preview_peeler: NostrMlsPeeler,
    /// Runtime Rule-14 enforcement: registers this session's `session.sqlite`
    /// path in a process-global set at open and releases it on drop, so a
    /// second `AccountDeviceSession::open` on the same DB file (e.g. a
    /// background isolate) fails closed instead of hydrating a divergent epoch
    /// state. Held for the session's lifetime; never read after construction.
    _live_guard: LiveSessionGuard,
}

impl SessionManager {
    /// Opens a session over the encrypted `session.sqlite` in `data_dir`, bound
    /// to the identity `keys`.
    ///
    /// The `SQLCipher` passphrase is provisioned from the platform keyring (see
    /// [`StorageConfig::sqlcipher_key`]). Rule 14: do not open a second session
    /// on the same directory.
    ///
    /// # Errors
    ///
    /// Returns an error if the data directory cannot be created, the keyring is
    /// unavailable, or the session cannot open/hydrate.
    pub fn new(data_dir: &Path, keys: &Keys) -> Result<Self> {
        std::fs::create_dir_all(data_dir).map_err(|e| {
            NostrError::StorageError(format!("failed to create MLS data directory: {e}"))
        })?;
        let config = StorageConfig::new(data_dir);
        let key = config.sqlcipher_key()?;
        Self::open_session(config.database_path(), key, keys)
    }

    /// Opens a session over a fixed-key encrypted temp database, bypassing the
    /// keyring. Test/development only.
    ///
    /// The Dark Matter `storage-sqlite` backend always encrypts (SQLCipher); the
    /// "unencrypted" name is retained for continuity with the old test API. It
    /// uses a constant test passphrase so no platform keyring is required.
    ///
    /// # Errors
    ///
    /// Returns an error if the directory cannot be created or the session cannot
    /// open/hydrate.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn new_unencrypted(data_dir: &Path, keys: &Keys) -> Result<Self> {
        std::fs::create_dir_all(data_dir).map_err(|e| {
            NostrError::StorageError(format!("failed to create MLS data directory: {e}"))
        })?;
        let config = StorageConfig::new(data_dir);
        let key = SqlCipherKey::new("haven-test-mls-passphrase")
            .map_err(|e| NostrError::StorageError(format!("failed to build test key: {e}")))?;
        Self::open_session(config.database_path(), key, keys)
    }

    /// Shared open path: wires the peeler, the hardened proof signer, and the
    /// supported app-component set, then hydrates the session.
    fn open_session(db_path: std::path::PathBuf, key: SqlCipherKey, keys: &Keys) -> Result<Self> {
        // Rule 14 (runtime): fail closed if a live session already holds this DB
        // file. Acquired BEFORE the engine open so a rejected second open never
        // touches the on-disk state; if the engine open below fails, the guard
        // drops and releases the path (no false lockout on a legitimate retry).
        let live_guard = LiveSessionGuard::acquire(&db_path)?;
        let identity = keys.public_key().to_bytes().to_vec();
        // The engine's peeler owns NIP-59 welcome crypto; we keep an identical
        // clone (shared identity signer via Arc) for pre-accept preview peels.
        let peeler = NostrMlsPeeler::new().with_welcome_signer(keys.clone());
        let preview_peeler = peeler.clone();
        let proof_signer: Arc<_> = HavenIdentityProofSigner::arc(keys);

        let config = SessionConfig::new(db_path, key, identity, Box::new(peeler))
            .account_identity_proof_signer(proof_signer)
            // Haven groups carry Nostr routing (0x8004) and message retention
            // (0x8005) in addition to the default profile/admin-policy
            // components; the KeyPackages Haven mints must advertise support
            // for them so self-invite/create pass capability validation
            // (W6/W7; §8 Q7). Retention drives the engine's NIP-40
            // `expiration` tag on kind-445 application messages (DM-2
            // deviation #2 re-wired) — location ciphertexts must not linger
            // on relays past their usefulness.
            .supported_app_components([
                GROUP_PROFILE_COMPONENT_ID,
                GROUP_ADMIN_POLICY_COMPONENT_ID,
                NOSTR_ROUTING_COMPONENT_ID,
                GROUP_MESSAGE_RETENTION_COMPONENT_ID,
            ])
            // Immediate settlement (no quiescence delay). The engine's stored
            // convergence replaces Haven's deleted 8s settle window; the engine's
            // OWN default `settlement_quiescence_ms = 1_000` would re-introduce a
            // settle delay that (a) lags every membership/relay commit by ≥1s and
            // (b) risks a commit sitting `Buffered` until an unrelated later event
            // re-ticks `advance_convergence` — the delivery-stall class Haven
            // fought. Deterministic branch selection (`CommitOrderingKey`) still
            // resolves concurrent same-epoch commits, and out-of-order
            // future-epoch buffering (the F2 gate) is independent of quiescence,
            // so fork-safety + reordering are preserved; only the same-epoch
            // sibling settle DELAY is removed. `app_message_past_epoch_limit`
            // stays at the default 5 (aligns with Rule 5 / DEFAULT_MAX_PAST_EPOCHS).
            // NOTE (DM-5a, flag for security review): revisit if concurrent-commit
            // reorg churn (visible flip → deterministic re-converge) proves
            // material at larger group scale.
            .convergence_policy(CanonicalizationPolicy {
                settlement_quiescence_ms: 0,
                ..CanonicalizationPolicy::default()
            })
            // Enable MIP-03 SelfRemove. The engine's default `FeatureRegistry` is
            // EMPTY, so a group's leaves advertise no `self-remove` proposal-type
            // capability and a remaining member's auto-commit of a peer's
            // `SelfRemove` fails `ProposalValidationError(UnsupportedProposalType)`
            // — i.e. leaving is broken. Registering `self-remove`
            // (`Capability::Proposal(10)`, MIP-03) makes `fresh_key_package`
            // advertise the capability and `create_group` require it, so every
            // Haven member can commit a leaver's SelfRemove. `Required` (not
            // `Optional`) matches the 30443 KeyPackage `mls_proposals` tag set,
            // which already lists `0x000a` (= 10).
            .feature_registry(self_remove_feature_registry());

        let session = AccountDeviceSession::open(config).map_err(map_mls_err)?;
        Ok(Self {
            session: Mutex::new(session),
            identity_pubkey: keys.public_key(),
            preview_peeler,
            _live_guard: live_guard,
        })
    }

    // ── Identity / conversions ───────────────────────────────────────────────

    /// The local identity public key.
    #[must_use]
    pub const fn identity_pubkey(&self) -> PublicKey {
        self.identity_pubkey
    }

    /// The engine's stable member id for the local client (the account
    /// identity, x-only pubkey bytes).
    pub async fn self_id(&self) -> MemberId {
        self.session.lock().await.self_id()
    }

    /// Parses a `KeyPackage` event (kind 30443) into an engine [`KeyPackage`],
    /// carrying the source event id so a welcome can reference it.
    ///
    /// The event `content` is base64 of the TLS-serialized MLS `KeyPackage`.
    ///
    /// # Errors
    ///
    /// Returns an error if the content is not valid base64.
    pub fn key_package_from_event(event: &Event) -> Result<KeyPackage> {
        let bytes = BASE64.decode(event.content.as_bytes()).map_err(|e| {
            NostrError::InvalidEvent(format!("key package content not base64: {e}"))
        })?;
        let source = MessageId::new(event.id.to_bytes().to_vec());
        Ok(KeyPackage::with_source_event_id(bytes, source))
    }

    /// Converts an inbound signed Nostr event into the engine's transport
    /// message form (kind 445 → group message, kind 1059 → welcome).
    ///
    /// # Errors
    ///
    /// Returns an error if the event is not a supported kind or is malformed.
    pub fn event_to_transport_message(
        event: &Event,
    ) -> Result<cgka_traits::transport::TransportMessage> {
        NostrTransportEvent::from_nostr_event(event)
            .and_then(|e| e.to_transport_message())
            .map_err(map_mls_err)
    }

    /// Converts an engine-produced transport message back into a signed,
    /// verified Nostr event ready for Haven's relay layer to publish.
    ///
    /// # Errors
    ///
    /// Returns an error if the payload is malformed or fails verification.
    pub fn transport_message_to_event(
        msg: &cgka_traits::transport::TransportMessage,
    ) -> Result<Event> {
        NostrTransportEvent::from_transport_message(msg)
            .and_then(|e| e.to_verified_nostr_event())
            .map_err(map_mls_err)
    }

    // ── Group lifecycle ──────────────────────────────────────────────────────

    /// Creates a new location sharing group.
    ///
    /// Builds a [`CreateGroupRequest`]: name/description become the group's
    /// profile component, `config.relays` become a freshly-minted
    /// `marmot.transport.nostr.routing.v1` component (with a random 32-byte
    /// `nostr_group_id`), and `config.admins` bootstrap the initial admin set
    /// (the creator is always an admin implicitly). The returned
    /// [`CreateGroupEffects`] carries the welcomes to publish and a
    /// `PendingStateRef` to confirm after publish.
    ///
    /// # Errors
    ///
    /// Returns an error if the relay set is invalid, an admin pubkey is
    /// malformed, or the engine rejects creation.
    pub async fn create_group(
        &self,
        member_key_packages: Vec<KeyPackage>,
        config: LocationGroupConfig,
    ) -> Result<CreateGroupEffects> {
        validate_group_relays(&config.relays)?;

        let mut nostr_group_id = [0u8; 32];
        OsRng.fill_bytes(&mut nostr_group_id);
        let routing = NostrRoutingV1::new(nostr_group_id, config.relays.clone())
            .map_err(|e| NostrError::InvalidEvent(format!("invalid group routing: {e}")))?;
        let routing_bytes = encode_nostr_routing_v1(&routing)
            .map_err(|e| NostrError::InvalidEvent(format!("routing encode failed: {e}")))?;

        let initial_admins = parse_member_ids(&config.admins);

        let req = CreateGroupRequest {
            name: config.name,
            description: config.description,
            members: member_key_packages,
            required_features: Vec::new(),
            app_components: vec![
                AppComponentData {
                    component_id: NOSTR_ROUTING_COMPONENT_ID,
                    data: routing_bytes,
                },
                // `message-retention.v1`: the engine stamps every kind-445
                // APPLICATION message with a NIP-40 `expiration` of
                // `inner_created_at + retention` (commits/proposals are never
                // stamped — group history must outlive any TTL). Bounds
                // relay-side residency of location ciphertext to roughly two
                // publish cycles, replacing the pre-Dark-Matter per-send
                // jittered TTL (DM-2 deviation #2 re-wired).
                AppComponentData {
                    component_id: GROUP_MESSAGE_RETENTION_COMPONENT_ID,
                    data: crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS
                        .to_be_bytes()
                        .to_vec(),
                },
            ],
            initial_admins,
        };

        self.session
            .lock()
            .await
            .create_group(req)
            .await
            .map_err(map_mls_err)
    }

    /// Adds members to an existing group via their `KeyPackages`.
    ///
    /// Returns [`SessionEffects`] carrying a `GroupEvolution` (commit + welcomes
    /// + `PendingStateRef`). Publish-before-apply: publish then confirm.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown, the caller is not an admin, or
    /// a `KeyPackage` is invalid.
    pub async fn add_members(
        &self,
        group_id: &GroupId,
        key_packages: Vec<KeyPackage>,
    ) -> Result<SessionEffects> {
        self.send(SendIntent::Invite {
            group_id: group_id.clone(),
            key_packages,
        })
        .await
    }

    /// Removes members from a group by their hex-encoded public keys.
    ///
    /// # Errors
    ///
    /// Returns an error if no valid pubkeys are provided, the caller is not an
    /// admin, or the group is unknown.
    pub async fn remove_members(
        &self,
        group_id: &GroupId,
        member_pubkeys: &[String],
    ) -> Result<SessionEffects> {
        let members = parse_member_ids(member_pubkeys);
        if members.is_empty() {
            return Err(NostrError::InvalidEvent(
                "No valid public keys provided".to_string(),
            ));
        }
        self.send(SendIntent::RemoveMembers {
            group_id: group_id.clone(),
            members,
        })
        .await
    }

    /// Leaves a group via a MIP-03 `SelfRemove` proposal.
    ///
    /// Returns [`SessionEffects`] carrying a `Proposal` to publish. A bare
    /// proposal has no `PendingStateRef` (the epoch advances later via a peer's
    /// auto-commit), so there is nothing to confirm.
    ///
    /// # Errors
    ///
    /// Returns [`NostrError::AdminSelfDemoteRequired`] if the caller is still
    /// an admin — matched on the engine's typed `AdminCannotSelfRemove`
    /// variant (never its message text) so Haven's actionable "self-demote
    /// first" routing signal is stable across upstream wording changes and
    /// never carries the group id. Any other engine rejection (e.g. unknown
    /// group) maps to the redacted MLS-error bucket.
    pub async fn leave_group(&self, group_id: &GroupId) -> Result<SessionEffects> {
        self.session
            .lock()
            .await
            .send(SendIntent::Leave {
                group_id: group_id.clone(),
            })
            .await
            .map_err(|e| match e {
                SessionError::Engine(EngineError::AdminCannotSelfRemove { .. }) => {
                    NostrError::AdminSelfDemoteRequired
                }
                other => map_mls_err(other),
            })
    }

    /// Replaces the group's Nostr routing relay set (keeps the existing
    /// `nostr_group_id`) via an `UpdateAppComponents` commit.
    ///
    /// # Errors
    ///
    /// Returns an error if the group has no routing component, the relay set is
    /// invalid, or the caller is not an admin.
    pub async fn update_relays(
        &self,
        group_id: &GroupId,
        relays: Vec<String>,
    ) -> Result<SessionEffects> {
        validate_group_relays(&relays)?;
        let (nostr_group_id, _current) = self.group_routing(group_id).await?;
        let routing = NostrRoutingV1::new(nostr_group_id, relays)
            .map_err(|e| NostrError::InvalidEvent(format!("invalid group routing: {e}")))?;
        let routing_bytes = encode_nostr_routing_v1(&routing)
            .map_err(|e| NostrError::InvalidEvent(format!("routing encode failed: {e}")))?;
        self.send(SendIntent::UpdateAppComponents {
            group_id: group_id.clone(),
            updates: vec![AppComponentData {
                component_id: NOSTR_ROUTING_COMPONENT_ID,
                data: routing_bytes,
            }],
        })
        .await
    }

    /// Low-level passthrough to `session.send`.
    ///
    /// # Errors
    ///
    /// Returns any engine error, redacted.
    pub async fn send(&self, intent: SendIntent) -> Result<SessionEffects> {
        self.session
            .lock()
            .await
            .send(intent)
            .await
            .map_err(map_mls_err)
    }

    // ── Messaging ────────────────────────────────────────────────────────────

    /// Encrypts and prepares an inner application message (a location update)
    /// for a group.
    ///
    /// The inner `rumor` is a Marmot app event (W9): unsigned, canonical NIP-01
    /// id, `pubkey` == the local sender identity. It is serialized as the
    /// `SendIntent::AppMessage` payload. The returned [`SessionEffects`] carries
    /// an `ApplicationMessage` transport message to publish (no pending ref —
    /// application messages do not advance the epoch).
    ///
    /// # Errors
    ///
    /// Returns an error if the rumor's pubkey is not the local identity (fail
    /// closed on a spoofed inner sender) or the engine rejects the send.
    pub async fn create_message(
        &self,
        group_id: &GroupId,
        rumor: UnsignedEvent,
    ) -> Result<SessionEffects> {
        if rumor.pubkey != self.identity_pubkey {
            return Err(NostrError::InvalidEvent(
                "inner app-message pubkey must equal the local sender identity".to_string(),
            ));
        }
        let payload = rumor.as_json().into_bytes();
        self.send(SendIntent::AppMessage {
            group_id: group_id.clone(),
            payload,
        })
        .await
    }

    /// Builds an unsigned location rumor (inner kind-9 Marmot app event) for the
    /// local sender and sends it.
    ///
    /// Convenience over [`Self::create_message`]: constructs the canonical inner
    /// event with `pubkey` == the local identity and a `["t","location"]` tag.
    ///
    /// # Errors
    ///
    /// Returns an error if the engine rejects the send.
    pub async fn send_location(
        &self,
        group_id: &GroupId,
        content: String,
    ) -> Result<SessionEffects> {
        let rumor = nostr::EventBuilder::new(Kind::Custom(9), content)
            .tags([Tag::hashtag("location")])
            .build(self.identity_pubkey);
        self.create_message(group_id, rumor).await
    }

    /// Ingests a raw transport message into the engine (inbound processing).
    ///
    /// Returns [`IngestEffects`] carrying the [`super::types::IngestOutcome`]
    /// classification and any drained events / publish work. The engine
    /// sequences out-of-order input internally; the caller advances its cursor
    /// on `Processed` / `Stale` and relies on the engine's buffering for
    /// `Buffered`.
    ///
    /// # Errors
    ///
    /// Returns an error only for hard failures; stale / duplicate / not-for-us
    /// messages come back as `Ok(IngestOutcome::Stale { .. })`.
    pub async fn ingest(
        &self,
        msg: cgka_traits::transport::TransportMessage,
    ) -> Result<IngestEffects> {
        self.session
            .lock()
            .await
            .ingest(msg)
            .await
            .map_err(map_mls_err)
    }

    /// Converts a signed Nostr event into a transport message and ingests it.
    ///
    /// Receiver-side NIP-40 expiration enforcement (restored post-Dark-Matter;
    /// pre-migration this lived in `decrypt_location`): a well-behaved relay
    /// drops expired events, but a malicious or buggy relay could replay stale
    /// location ciphertext past its advertised TTL. Defense-in-depth: drop
    /// locally too, with a small grace window for clock skew. Every receive
    /// plane (poll drain, live-sync, background catch-up) funnels through this
    /// method, so the guard covers all of them. Gift wraps (kind 1059) carry
    /// no expiration tag and pass through untouched.
    ///
    /// # Errors
    ///
    /// Returns an error if conversion or ingest fails hard.
    pub async fn process_event(&self, event: &Event) -> Result<IngestEffects> {
        if let Some(expires_at) = event.tags.iter().find_map(|t| match t.as_standardized() {
            Some(nostr::TagStandard::Expiration(ts)) => Some(*ts),
            _ => None,
        }) {
            let grace = Timestamp::from(
                expires_at
                    .as_secs()
                    .saturating_add(crate::location::ttl::RECEIVER_EXPIRATION_GRACE_SECS),
            );
            if Timestamp::now() > grace {
                // Terminal for this event: report it as `Stale` with empty
                // effects so every caller advances its cursor past it (the
                // same contract as the engine's own dedup outcomes) and
                // nothing is surfaced to decrypt.
                return Ok(IngestEffects {
                    outcome: super::types::IngestOutcome::Stale {
                        reason: super::types::StaleReason::AlreadySeen,
                    },
                    effects: SessionEffects {
                        events: Vec::new(),
                        publish: Vec::new(),
                        queued: Vec::new(),
                        pending_convergence: Vec::new(),
                    },
                });
            }
        }
        let msg = Self::event_to_transport_message(event)?;
        self.ingest(msg).await
    }

    /// Advances stored convergence for a group, releasing queued work and
    /// buffered inbound messages that are now safe to apply.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown or convergence fails.
    pub async fn advance_convergence(&self, group_id: &GroupId) -> Result<SessionEffects> {
        self.session
            .lock()
            .await
            .advance_convergence(group_id)
            .await
            .map_err(map_mls_err)
    }

    // ── Publish-before-apply (Rule 13) ───────────────────────────────────────

    /// Confirms that a staged `GroupEvolution` / `GroupCreated` / `AutoPublish`
    /// was published (≥1-relay ack). The engine applies the staged commit and
    /// emits the epoch change. Exposed for DM-3's publish discipline.
    ///
    /// # Errors
    ///
    /// Returns an error if the pending ref is unknown (already confirmed,
    /// rolled back, or never issued).
    pub async fn confirm_published(&self, pending: PendingStateRef) -> Result<SessionEffects> {
        self.session
            .lock()
            .await
            .confirm_published(pending)
            .await
            .map_err(map_mls_err)
    }

    /// Reports that a staged publish failed; the engine discards the staged
    /// commit and returns the group to `Stable` at the prior epoch. Exposed for
    /// DM-3's publish discipline.
    ///
    /// # Errors
    ///
    /// Returns an error if the pending ref is unknown.
    pub async fn publish_failed(&self, pending: PendingStateRef) -> Result<SessionEffects> {
        self.session
            .lock()
            .await
            .publish_failed(pending)
            .await
            .map_err(map_mls_err)
    }

    // ── Welcomes (hold-before-ingest, F3) ────────────────────────────────────

    /// Peels a gift-wrapped welcome WITHOUT ingesting it, to derive a pre-accept
    /// preview. The decrypted MLS welcome bytes are read and immediately
    /// discarded — never stored (F3). Only the non-secret inviter identity is
    /// returned.
    ///
    /// # Errors
    ///
    /// Returns an error if the event is not a welcome addressed to this client
    /// or is malformed.
    pub async fn preview_welcome(&self, gift_wrap: &Event) -> Result<WelcomePreview> {
        let msg = Self::event_to_transport_message(gift_wrap)?;
        let peeled = self
            .preview_peeler
            .peel_welcome(&msg)
            .await
            .map_err(map_mls_err)?;
        // `peeled.content` holds the decrypted welcome bytes; drop it by not
        // binding it. Only the seal author (inviter) is retained.
        let inviter_pubkey = peeled
            .sender
            .map(|m| hex::encode(m.as_slice()))
            .unwrap_or_default();
        Ok(WelcomePreview { inviter_pubkey })
    }

    /// Accepts a held welcome by ingesting the still-encrypted 1059 into the
    /// engine, which peels it, joins the group, and emits `GroupJoined`.
    ///
    /// # Errors
    ///
    /// Returns an error if the welcome cannot be peeled/joined.
    pub async fn accept_welcome(&self, gift_wrap: &Event) -> Result<IngestEffects> {
        let msg = Self::event_to_transport_message(gift_wrap)?;
        self.ingest(msg).await
    }

    // ── KeyPackages ──────────────────────────────────────────────────────────

    /// Produces a fresh `KeyPackage` for publishing to a directory (kind 30443).
    ///
    /// Event building / signing stays in Haven's relay layer (DM-2b): this
    /// returns the raw engine [`KeyPackage`] (MLS bytes + source).
    ///
    /// # Errors
    ///
    /// Returns an error if generation fails.
    pub async fn fresh_key_package(&self) -> Result<KeyPackage> {
        self.session
            .lock()
            .await
            .fresh_key_package()
            .await
            .map_err(map_mls_err)
    }

    /// Deletes a previously generated `KeyPackage` bundle from storage.
    ///
    /// Called when publication fails, so a retrying app does not accumulate
    /// orphaned private init-key material (mdk#160). Idempotent.
    ///
    /// # Errors
    ///
    /// Returns an error if deletion fails.
    pub async fn delete_key_package(&self, key_package: &KeyPackage) -> Result<()> {
        self.session
            .lock()
            .await
            .delete_key_package(key_package)
            .await
            .map_err(map_mls_err)
    }

    // ── Inspection ───────────────────────────────────────────────────────────

    /// The engine's record for a group (id, name, description, epoch, members,
    /// required capabilities, removed flag, join epoch).
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown.
    pub async fn group_record(&self, group_id: &GroupId) -> Result<Group> {
        self.session
            .lock()
            .await
            .group_record(group_id)
            .map_err(map_mls_err)
    }

    /// Like [`Self::group_record`] but maps "unknown group" to `Ok(None)`
    /// (mirrors the old `get_group` `Option` contract).
    ///
    /// # Errors
    ///
    /// Returns an error for any failure other than an unknown group.
    pub async fn find_group(&self, group_id: &GroupId) -> Result<Option<Group>> {
        // Bind the query result so the session guard (a significant-`Drop`
        // temporary) is released before the match arms run.
        let record = self.session.lock().await.group_record(group_id);
        match record {
            Ok(group) => Ok(Some(group)),
            // A never-seen group surfaces as `Storage(NotFound)` (the storage
            // `get_group` miss); `UnknownGroup` is returned only for a
            // *quarantined* group (`ensure_group_live`, mdk#364). Both mean "not a
            // live group we hold" ⇒ `None` (mirrors the old `get_group` Option).
            Err(SessionError::Engine(
                EngineError::UnknownGroup(_)
                | EngineError::Storage(cgka_traits::storage::StorageError::NotFound),
            )) => Ok(None),
            Err(e) => Err(map_mls_err(e)),
        }
    }

    /// The group's members.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown.
    pub async fn members(&self, group_id: &GroupId) -> Result<Vec<Member>> {
        self.session
            .lock()
            .await
            .members(group_id)
            .map_err(map_mls_err)
    }

    /// The group's member public keys, hex-encoded.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown.
    pub async fn member_pubkeys(&self, group_id: &GroupId) -> Result<Vec<String>> {
        Ok(self
            .members(group_id)
            .await?
            .into_iter()
            .map(|m| hex::encode(m.id.as_slice()))
            .collect())
    }

    /// The group's admin public keys (raw x-only bytes).
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown.
    pub async fn admin_pubkeys(&self, group_id: &GroupId) -> Result<Vec<[u8; 32]>> {
        self.session
            .lock()
            .await
            .admin_pubkeys(group_id)
            .map_err(map_mls_err)
    }

    /// The current MLS epoch of a group.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown.
    pub async fn epoch(&self, group_id: &GroupId) -> Result<u64> {
        self.session
            .lock()
            .await
            .epoch(group_id)
            .map(|e| e.0)
            .map_err(map_mls_err)
    }

    /// The group's Nostr routing: `(nostr_group_id, relays)` decoded from the
    /// `marmot.transport.nostr.routing.v1` component.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown or has no routing component.
    pub async fn group_routing(&self, group_id: &GroupId) -> Result<([u8; 32], Vec<String>)> {
        let raw = self
            .session
            .lock()
            .await
            .app_component(group_id, NOSTR_ROUTING_COMPONENT_ID)
            .map_err(map_mls_err)?
            .ok_or_else(|| {
                NostrError::MdkError("group has no nostr routing component".to_string())
            })?;
        let routing = cgka_traits::app_components::decode_nostr_routing_v1(&raw)
            .map_err(|e| NostrError::MdkError(format!("routing decode failed: {e}")))?;
        Ok((routing.nostr_group_id, routing.relays))
    }

    /// The group's relay set (sorted, deduped) from its routing component.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown or has no routing component.
    pub async fn group_relays(&self, group_id: &GroupId) -> Result<Vec<String>> {
        Ok(self.group_routing(group_id).await?.1)
    }

    /// The group's `nostr_group_id` hex, from its routing component.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown or has no routing component.
    pub async fn nostr_group_id_hex(&self, group_id: &GroupId) -> Result<String> {
        Ok(hex::encode(self.group_routing(group_id).await?.0))
    }

    /// Whether the group-event exporter secret is currently derivable
    /// (test/feature-only presence probe; re-expressed Rule-5 gate, §5.7).
    ///
    /// The engine retains up to `DEFAULT_MAX_PAST_EPOCHS = 5` past epochs; this
    /// checks the current epoch's exporter secret at [`DEFAULT_EXPORTER_LABEL`].
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn has_current_exporter_secret(&self, group_id: &GroupId) -> Result<bool> {
        Ok(self
            .session
            .lock()
            .await
            .exporter_secret(group_id, DEFAULT_EXPORTER_LABEL, 32)
            .is_ok())
    }

    // ── Event → LocationMessageResult folding (plan §5.2 #32) ────────────────

    /// Folds an ordered engine [`GroupEvent`] into a location-facing
    /// [`LocationMessageResult`], or `None` for events with no location-visible
    /// meaning (group-created, fork-recovery bookkeeping, hydration events).
    ///
    /// - `MessageReceived` → `Location` (inner content extracted from the
    ///   `MarmotAppEvent` payload).
    /// - `GroupJoined` → `Joined`.
    /// - `GroupStateChanged` / `EpochChanged` → `GroupUpdate`.
    /// - `AppMessageInvalidated` / `GroupStateInvalidated` → `Invalidated`.
    /// - `GroupUnrecoverable` → `Unrecoverable`.
    #[must_use]
    pub fn location_result_from_event(event: &GroupEvent) -> Option<LocationMessageResult> {
        match event {
            GroupEvent::MessageReceived {
                group_id,
                sender,
                epoch,
                payload,
            } => Some(LocationMessageResult::Location {
                sender_pubkey: hex::encode(sender.as_slice()),
                content: inner_app_content(payload),
                group_id: group_id.clone(),
                epoch: epoch.0,
            }),
            GroupEvent::GroupJoined { group_id, .. } => Some(LocationMessageResult::Joined {
                group_id: group_id.clone(),
            }),
            // `GroupUpdate` covers both a durable state/epoch change AND a
            // Rule-13 mandatory resync trigger. `PendingCommitRecovered` is
            // emitted from hydrate on the first drain after open when the process
            // crashed between publishing a commit and confirming it: the staged
            // commit is cleared (treated as publish-failed), so if relays DID
            // accept it, this device is now behind and must catch up.
            // `GroupHydrationRecovered` fires when a previously-quarantined group
            // is re-hydrated and likewise needs to catch up. Folding all four to
            // `GroupUpdate` makes the receive path drive a refresh + resync
            // instead of silently dropping the recovery signal (Rust F1).
            // `GroupHydrationQuarantined` stays `None` — the group is NOT live, so
            // a resync would find nothing to catch up; `ForkRecovered` /
            // `CommitRolledBack` also stay `None` (their accompanying
            // `EpochChanged` / `GroupStateInvalidated` drives the refresh).
            GroupEvent::GroupStateChanged { group_id, .. }
            | GroupEvent::EpochChanged { group_id, .. }
            | GroupEvent::PendingCommitRecovered { group_id, .. }
            | GroupEvent::GroupHydrationRecovered { group_id, .. } => {
                Some(LocationMessageResult::GroupUpdate {
                    group_id: group_id.clone(),
                })
            }
            GroupEvent::AppMessageInvalidated { group_id, .. }
            | GroupEvent::GroupStateInvalidated { group_id, .. } => {
                Some(LocationMessageResult::Invalidated {
                    group_id: group_id.clone(),
                })
            }
            GroupEvent::GroupUnrecoverable { group_id } => {
                Some(LocationMessageResult::Unrecoverable {
                    group_id: group_id.clone(),
                })
            }
            _ => None,
        }
    }
}

/// The MIP-03 `SelfRemove` feature registry Haven installs on every session.
///
/// Registers `self-remove` as a `Required` capability (`Capability::Proposal(10)`)
/// so `fresh_key_package` advertises it in the leaf capabilities and
/// `create_group` puts it in the group's `RequiredCapabilities`. Without this,
/// the engine's default empty registry leaves the group unable to commit a
/// peer's `SelfRemove` (`UnsupportedProposalType`) — i.e. leaving is broken.
fn self_remove_feature_registry() -> FeatureRegistry {
    let mut registry = FeatureRegistry::new();
    registry.register(
        Feature("self-remove"),
        CapabilityRequirement {
            requires: Capability::Proposal(10),
            level: RequirementLevel::Required,
            description: "MIP-03 SelfRemove",
        },
    );
    registry
}

impl std::fmt::Debug for SessionManager {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SessionManager")
            .field("session", &"<AccountDeviceSession>")
            .field("identity_pubkey", &"<redacted>")
            .finish_non_exhaustive()
    }
}

/// Parses hex-encoded pubkeys into engine [`MemberId`]s, skipping malformed
/// entries (mirrors the old `filter_map` parse tolerance).
fn parse_member_ids(pubkeys: &[String]) -> Vec<MemberId> {
    pubkeys
        .iter()
        .filter_map(|pk| PublicKey::from_hex(pk).ok())
        .map(|pk| MemberId::new(pk.to_bytes().to_vec()))
        .collect()
}

/// Validates a group's relay set against the NIP-59 welcome-wrap bounds
/// (protocol W8): non-empty, ≤16 entries, each ≤512 bytes, ws/wss only. The
/// engine fail-closes internally otherwise; validating here surfaces a clean
/// error before create/invite.
fn validate_group_relays(relays: &[String]) -> Result<()> {
    if relays.is_empty() {
        return Err(NostrError::InvalidEvent(
            "group relay set must contain at least one relay".to_string(),
        ));
    }
    if relays.len() > MAX_GROUP_WELCOME_RELAYS {
        return Err(NostrError::InvalidEvent(format!(
            "group relay set has {} relays, limit is {MAX_GROUP_WELCOME_RELAYS}",
            relays.len()
        )));
    }
    for relay in relays {
        if relay.len() > MAX_GROUP_RELAY_URL_LEN {
            return Err(NostrError::InvalidEvent(
                "group relay URL exceeds 512 bytes".to_string(),
            ));
        }
        if nostr::RelayUrl::parse(relay).is_err() {
            return Err(NostrError::InvalidEvent(
                "group relay is not a valid ws/wss URL".to_string(),
            ));
        }
    }
    Ok(())
}

/// Extracts the inner `content` field from a `MarmotAppEvent` JSON payload,
/// best-effort. Returns an empty string if the payload is not the expected
/// unsigned-event JSON shape (the engine already validated it as a Marmot app
/// event before emitting `MessageReceived`, so this is defensive).
fn inner_app_content(payload: &[u8]) -> String {
    serde_json::from_slice::<serde_json::Value>(payload)
        .ok()
        .and_then(|v| v.get("content").and_then(|c| c.as_str().map(String::from)))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use cgka_traits::types::EpochId;
    use std::env;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn temp_dir() -> std::path::PathBuf {
        let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
        env::temp_dir().join(format!("haven_session_test_{}_{}", std::process::id(), id))
    }

    fn open_manager() -> (SessionManager, std::path::PathBuf) {
        let dir = temp_dir();
        let keys = Keys::generate();
        let manager = SessionManager::new_unencrypted(&dir, &keys).expect("open session");
        (manager, dir)
    }

    #[tokio::test]
    async fn opens_and_reports_self_id() {
        let dir = temp_dir();
        let keys = Keys::generate();
        let manager = SessionManager::new_unencrypted(&dir, &keys).expect("open session");
        // self_id is the account identity (x-only pubkey bytes).
        assert_eq!(
            manager.self_id().await.as_slice(),
            &keys.public_key().to_bytes()
        );
        assert_eq!(manager.identity_pubkey(), keys.public_key());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn debug_does_not_leak() {
        let (manager, dir) = open_manager();
        let out = format!("{manager:?}");
        assert!(out.contains("SessionManager"));
        assert!(out.contains("<redacted>"));
        assert!(!out.contains(&manager.identity_pubkey().to_hex()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn rule14_second_session_on_same_db_fails_and_reopens_after_drop() {
        // Rule 14 runtime enforcement (Security F4 / #14): at most ONE live
        // `AccountDeviceSession` per DB file. A second `SessionManager` on the
        // same directory (the Android background-isolate threat) must fail
        // closed BEFORE hydrating a divergent epoch state.
        let dir = temp_dir();
        let keys = Keys::generate();

        let first = SessionManager::new_unencrypted(&dir, &keys).expect("first open succeeds");

        // A second live session on the SAME directory is rejected.
        let second = SessionManager::new_unencrypted(&dir, &keys);
        assert!(
            second.is_err(),
            "a second session on the same DB file must fail closed (Rule 14)"
        );

        // A DIFFERENT directory coexists with the first (the guard is per-file,
        // never a global single-session lock).
        let other_dir = temp_dir();
        let other =
            SessionManager::new_unencrypted(&other_dir, &keys).expect("a distinct DB coexists");
        drop(other);

        // Dropping the first releases its path; reopening the SAME directory now
        // succeeds (no false-positive lockout after a legitimate close).
        drop(first);
        let reopened = SessionManager::new_unencrypted(&dir, &keys)
            .expect("reopen after drop must succeed (guard released on drop)");
        drop(reopened);

        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&other_dir);
    }

    #[tokio::test]
    async fn find_group_unknown_is_none() {
        let (manager, dir) = open_manager();
        let gid = GroupId::new(vec![1, 2, 3]);
        assert!(manager.find_group(&gid).await.expect("query").is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn group_record_unknown_errors() {
        let (manager, dir) = open_manager();
        let gid = GroupId::new(vec![4, 5, 6]);
        assert!(manager.group_record(&gid).await.is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn create_group_rejects_empty_relay_set() {
        let (manager, dir) = open_manager();
        let config = LocationGroupConfig::new("Test"); // no relays
        let result = manager.create_group(vec![], config).await;
        assert!(matches!(result, Err(NostrError::InvalidEvent(_))));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn create_message_rejects_foreign_inner_pubkey() {
        let (manager, dir) = open_manager();
        // A rumor whose pubkey is NOT the local identity must be refused (W9).
        let other = Keys::generate();
        let rumor = nostr::EventBuilder::new(Kind::Custom(9), "{}").build(other.public_key());
        let gid = GroupId::new(vec![9, 9, 9]);
        let result = manager.create_message(&gid, rumor).await;
        assert!(matches!(result, Err(NostrError::InvalidEvent(_))));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn validate_group_relays_bounds() {
        assert!(validate_group_relays(&[]).is_err());
        assert!(validate_group_relays(&["wss://relay.example.com".to_string()]).is_ok());
        assert!(validate_group_relays(&["not a url".to_string()]).is_err());
        let too_many: Vec<String> = (0..17).map(|i| format!("wss://r{i}.example")).collect();
        assert!(validate_group_relays(&too_many).is_err());
    }

    #[test]
    fn key_package_from_event_decodes_base64_content() {
        let keys = Keys::generate();
        let event = nostr::EventBuilder::new(Kind::Custom(30443), BASE64.encode(b"kp-bytes"))
            .sign_with_keys(&keys)
            .expect("sign");
        let kp = SessionManager::key_package_from_event(&event).expect("parse");
        assert_eq!(kp.bytes(), b"kp-bytes");
        assert!(kp.source.is_some());
    }

    #[test]
    fn location_result_from_message_received_extracts_inner_content() {
        let sender = MemberId::new(vec![0xAB; 32]);
        let inner = nostr::EventBuilder::new(Kind::Custom(9), r#"{"lat":1.5}"#)
            .build(Keys::generate().public_key());
        let payload = inner.as_json().into_bytes();
        let event = GroupEvent::MessageReceived {
            group_id: GroupId::new(vec![7, 7, 7]),
            sender: sender.clone(),
            epoch: EpochId(4),
            payload,
        };
        match SessionManager::location_result_from_event(&event) {
            Some(LocationMessageResult::Location {
                sender_pubkey,
                content,
                epoch,
                ..
            }) => {
                assert_eq!(sender_pubkey, hex::encode(sender.as_slice()));
                assert!(content.contains("lat"));
                assert_eq!(epoch, 4);
            }
            other => panic!("expected Location, got {other:?}"),
        }
    }

    #[test]
    fn location_result_maps_state_and_join_events() {
        let gid = GroupId::new(vec![1]);
        assert!(matches!(
            SessionManager::location_result_from_event(&GroupEvent::EpochChanged {
                group_id: gid.clone(),
                from: EpochId(1),
                to: EpochId(2),
            }),
            Some(LocationMessageResult::GroupUpdate { .. })
        ));
        assert!(matches!(
            SessionManager::location_result_from_event(&GroupEvent::GroupJoined {
                group_id: gid.clone(),
                via_welcome: MessageId::new(vec![0xAA; 32]),
                welcomer: None,
            }),
            Some(LocationMessageResult::Joined { .. })
        ));
        assert!(matches!(
            SessionManager::location_result_from_event(&GroupEvent::GroupUnrecoverable {
                group_id: gid.clone(),
            }),
            Some(LocationMessageResult::Unrecoverable { .. })
        ));
        // A bookkeeping event with no location-visible meaning folds to None.
        assert!(
            SessionManager::location_result_from_event(&GroupEvent::GroupCreated { group_id: gid })
                .is_none()
        );
    }

    #[test]
    fn location_result_maps_recovery_events_to_group_update() {
        // Rule 13 resync (Rust F1): the hydrate-emitted PendingCommitRecovered and
        // the quarantine-retry GroupHydrationRecovered MUST surface a GroupUpdate
        // (drive a catch-up) — not fold to a dropped None.
        let gid = GroupId::new(vec![5, 5, 5]);
        assert!(matches!(
            SessionManager::location_result_from_event(&GroupEvent::PendingCommitRecovered {
                group_id: gid.clone(),
                recovered_epoch: EpochId(3),
            }),
            Some(LocationMessageResult::GroupUpdate { .. })
        ));
        assert!(matches!(
            SessionManager::location_result_from_event(&GroupEvent::GroupHydrationRecovered {
                group_id: gid.clone(),
                recovered_epoch: EpochId(3),
            }),
            Some(LocationMessageResult::GroupUpdate { .. })
        ));
        // A losing-branch rollback stays None (its EpochChanged / GroupStateInvalidated
        // sibling drives the refresh), and a quarantine (not a live group) stays None.
        assert!(
            SessionManager::location_result_from_event(&GroupEvent::CommitRolledBack {
                group_id: gid.clone(),
                invalidated_commit_id: MessageId::new(vec![1; 32]),
            })
            .is_none()
        );
    }

    #[test]
    fn inner_app_content_is_empty_for_garbage() {
        assert_eq!(inner_app_content(b"not json"), "");
        assert_eq!(inner_app_content(br#"{"no_content":1}"#), "");
    }
}
