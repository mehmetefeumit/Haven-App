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
use nostr::{Event, JsonUtil, Keys, Kind, PublicKey, Timestamp, UnsignedEvent};
use rand::rngs::OsRng;
use rand::RngCore;
use tokio::sync::Mutex;

use cgka_engine::canonicalization::CanonicalizationPolicy;
use cgka_engine::feature_registry::FeatureRegistry;
use cgka_engine::openmls_projection::{project_mls_message, OpenMlsContentKind};
use cgka_session::{
    AccountDeviceSession, CreateGroupEffects, IngestEffects, SessionConfig, SessionEffects,
    SessionError,
};
use cgka_traits::app_components::{
    encode_nostr_routing_v1, encode_quic_varint, AppComponentData, NostrRoutingV1,
    GROUP_ADMIN_POLICY_COMPONENT_ID, GROUP_MESSAGE_RETENTION_COMPONENT_ID,
    GROUP_PROFILE_COMPONENT_ID, NOSTR_ROUTING_COMPONENT_ID,
};
use cgka_traits::capabilities::{Capability, CapabilityRequirement, Feature, RequirementLevel};
use cgka_traits::engine::{CreateGroupRequest, GroupEvent, KeyPackage, SendIntent};
use cgka_traits::engine_state::PendingStateRef;
use cgka_traits::error::EngineError;
use cgka_traits::group::{Group, Member};
use cgka_traits::message::{MessageState, StoredMessagePayload};
use cgka_traits::peeler::TransportPeeler;
use cgka_traits::storage::{
    ConvergencePolicyStorage, GroupStorage, MessageStorage, OutboundIntentStorage, StorageError,
    StorageResult,
};
use cgka_traits::types::{EpochId, GroupId, MemberId, MessageId};
use storage_sqlite::{SqlCipherKey, SqliteAccountStorage};
use transport_nostr_peeler::{NostrMlsPeeler, NostrTransportEvent};

use super::retention::RetentionBoundPeeler;
use super::signer::HavenIdentityProofSigner;
use super::storage::{LiveSessionGuard, StorageConfig};
#[cfg(any(test, feature = "test-utils"))]
use super::types::StoredMessageProbe;
use super::types::{
    beyond_relay_retention, ConvergedRoster, ConvergenceSweep, LocationGroupConfig,
    LocationMessageResult, PreAuthRejection, ScreenedIngest,
};
use super::welcome::WelcomePreview;
use crate::log_alias::bucket;
use crate::nostr::error::{NostrError, Result};
use crate::nostr::event::{KIND_LOCATION_UPDATE, LEGACY_KIND_LOCATION_UPDATE};

// `redact_hex_sequences` lives in the neutral `crate::util` module. Re-exported
// here so every `crate::nostr::mls::redact_hex_sequences` caller (circle/error,
// relay/manager) keeps working unchanged.
pub use crate::util::redact_hex_sequences;

/// Group-message exporter label used by the Dark Matter peeler
/// (`MLS-Exporter("marmot", "group-event", 32)`). Exposed for the re-expressed
/// Rule-5 exporter-secret retention test (§5.7).
pub const DEFAULT_EXPORTER_LABEL: &str = "marmot/group-event";

/// The engine's past-epoch exporter-secret retention window (Rule 5). Re-exported
/// rather than copied so a Haven gate pins the number the engine actually keeps
/// keys for; Haven does not override it.
pub use cgka_engine::DEFAULT_MAX_PAST_EPOCHS;

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

/// The `EpochState` names that mean "this group is busy and will settle on its
/// own", as `cgka_traits` stamps them into `InvalidTransition::from`.
///
/// Derived from `EpochState::name()`, which is a `match` over the enum — not
/// prose. `"Stable"` is deliberately absent: it is the one state from which a
/// commit is ACCEPTED, so it can never be the `from` of a refusal, and listing
/// it would classify a hypothetical future refusal as retryable on no evidence.
/// `"Unrecoverable"` is absent for the opposite reason — see
/// [`EPOCH_UNRECOVERABLE_TOKEN`].
const EPOCH_RETRYABLE_TOKENS: [&str; 3] = ["PendingPublish", "Merging", "Recovering"];

/// The `EpochState` name that means "this group is frozen and waiting will not
/// help".
///
/// Kept apart from [`EPOCH_RETRYABLE_TOKENS`] so the two reach the caller as
/// different outcomes: a retry loop against a group the engine has given up on
/// is a UI that can never succeed.
const EPOCH_UNRECOVERABLE_TOKEN: &str = "Unrecoverable";

/// Classifies an engine rejection as an epoch-state refusal, or `None` for every
/// other failure.
///
/// # Why this is a token match rather than a distinct upstream variant
///
/// `cgka-engine` has ONE `InvalidTransition` variant and uses it for several
/// unrelated refusals: a non-`Stable` epoch state (`from` = an `EpochState`
/// name), a local copy marked removed (`from` = `"Removed"`), and a leave
/// already in flight (`from` = `"Leaving"`). Only the epoch-state ones are
/// about the group settling, and only some of THOSE are retryable — so the
/// `from` token, which `EpochState::name()` derives from the enum, is the
/// discriminator. It is stable in exactly the way the accompanying `reason`
/// string is not; matching `reason` would be prose matching, which Haven
/// forbids.
///
/// This is an interim: MDK `e391adc` exposes no `AccountDeviceSession`
/// epoch-state getter and no distinct error variant, so there is nothing better
/// to match. `docs/EPOCH_ROTATION_REPAIR_PLAN.md` §6 carries the upstream ask.
fn epoch_state_rejection(error: &SessionError) -> Option<NostrError> {
    let SessionError::Engine(EngineError::InvalidTransition(transition)) = error else {
        return None;
    };
    if transition.from == EPOCH_UNRECOVERABLE_TOKEN {
        return Some(NostrError::EpochUnrecoverable);
    }
    EPOCH_RETRYABLE_TOKENS
        .contains(&transition.from)
        .then_some(NostrError::EpochNotStable)
}

/// The convergence policy every Haven session installs.
///
/// Immediate settlement (no quiescence delay). The engine's stored convergence
/// replaces Haven's deleted 8s settle window; the engine's OWN default
/// `settlement_quiescence_ms = 1_000` would re-introduce a settle delay that
/// (a) lags every membership/relay commit by ≥1s and (b) risks a commit sitting
/// `Buffered` until an unrelated later event re-ticks `advance_convergence` —
/// the delivery-stall class Haven fought. Deterministic branch selection
/// (`CommitOrderingKey`) still resolves concurrent same-epoch commits, and
/// out-of-order future-epoch buffering (the F2 gate) is independent of
/// quiescence, so fork-safety + reordering are preserved; only the same-epoch
/// sibling settle DELAY is removed. `app_message_past_epoch_limit` stays at the
/// default 5 (aligns with Rule 5 / [`DEFAULT_MAX_PAST_EPOCHS`]).
///
/// NOTE (DM-5a, flag for security review): revisit if concurrent-commit reorg
/// churn (visible flip → deterministic re-converge) proves material at larger
/// group scale.
fn session_convergence_policy() -> CanonicalizationPolicy {
    CanonicalizationPolicy {
        settlement_quiescence_ms: 0,
        ..CanonicalizationPolicy::default()
    }
}

/// How many epochs past the group's tip an application message may be sealed
/// under and still be accepted (Rule 5).
///
/// Reads the policy the session is actually opened with, so a gate pinning this
/// bound cannot pass while the engine runs a different one.
#[must_use]
pub fn app_message_past_epoch_limit() -> u64 {
    session_convergence_policy().app_message_past_epoch_limit
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
    ///
    /// Wrapped in [`RetentionBoundPeeler`] too, even though preview only ever
    /// peels: a bare peeler here would expose an unbounded
    /// `wrap_group_message_with_metadata` beside the one the bound exists to
    /// intercept, and "nobody calls it" is a convention a future edit breaks
    /// silently. Wrapping makes it a type-level property instead.
    preview_peeler: RetentionBoundPeeler,
    /// A second `storage-sqlite` handle on the SAME `session.sqlite`, used ONLY
    /// by the stuck-convergence-input sweep
    /// ([`Self::sweep_unresolvable_inputs`]), its read-only counterpart
    /// ([`Self::gating_input_count`]) and the queued-intent discard
    /// ([`Self::discard_queued_location_intents`]).
    ///
    /// # Why a second handle exists at all
    ///
    /// Neither [`AccountDeviceSession`] nor `cgka_engine::Engine` exposes its
    /// `StorageProvider` (the engine's field is `pub(crate)`; the session has no
    /// accessor at the pinned rev), and no public API gives a stored
    /// `MessageRecord` a terminal disposition or deletes one queued outbound
    /// intent. The three trait methods this needs —
    /// [`MessageStorage::update_message_state`],
    /// [`OutboundIntentStorage::delete_queued_outbound_intent`] and the two
    /// list calls — are public on `cgka_traits::storage`, and
    /// [`SqliteAccountStorage::open_encrypted`] is a public constructor. So the
    /// smallest correct implementation opens the database a second time rather
    /// than forking MDK. See the Unit B notes in
    /// `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md` for the upstream request
    /// that would remove it.
    ///
    /// # Why this is not a second session (Security Rule 14)
    ///
    /// Rule 14 forbids a second live `AccountDeviceSession` because a second
    /// HYDRATED session runs its own in-memory `EpochManager` and would reach
    /// the same `(epoch, leaf, generation)` in the sender ratchet — key/nonce
    /// reuse over location payloads. This handle hydrates nothing: it holds no
    /// epoch state, no `OpenMLS` group, no exporter secret and no signer, and it
    /// touches exactly two tables (message records and the outbound-intent
    /// queue). It never reads or writes group state, ratchet state or key
    /// material. Every access is taken while the [`Self::session`] mutex is
    /// held, so no engine statement is ever in flight against the other
    /// connection; `storage-sqlite` opens WAL with a 5 s `busy_timeout`, which
    /// makes even an unexpected overlap a wait rather than a failure.
    message_store: SqliteAccountStorage,
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
    /// The Dark Matter `storage-sqlite` backend always encrypts (`SQLCipher`); the
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
        let key = StorageConfig::test_sqlcipher_key()?;
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
        // Opened BEFORE the session and from the same key, which is then moved
        // into `SessionConfig` — so the passphrase is never retained by Haven
        // beyond this function. Both opens run `storage-sqlite`'s idempotent
        // migrations; this one simply gets there first on a fresh database.
        // The SAME options the session's own connection uses
        // ([`StorageConfig::storage_options`]). `journal_mode` is DB-wide and
        // PERSISTENT, so two connections opening one file with different
        // options do not merely differ — the second silently re-writes the
        // first's journalling mode. One source of truth removes the question.
        let message_store = SqliteAccountStorage::open_encrypted_with_options(
            &db_path,
            &key,
            StorageConfig::storage_options(),
        )
        .map_err(|e| {
            NostrError::StorageError(format!(
                "failed to open the MLS message store: {}",
                redact_hex_sequences(&e.to_string())
            ))
        })?;
        let identity = keys.public_key().to_bytes().to_vec();
        // The engine's peeler owns NIP-59 welcome crypto; we keep an identical
        // clone (shared identity signer via Arc) for pre-accept preview peels.
        let peeler = NostrMlsPeeler::new().with_welcome_signer(keys.clone());
        let preview_peeler = RetentionBoundPeeler::new(peeler.clone());
        // Every outbound application 445 leaves through this wrapper, which
        // supplies Haven's own retention window when the group declares none —
        // otherwise a circle created by a client that never declared 0x8005
        // would publish location updates with no NIP-40 expiration, which both
        // lets a relay keep them forever AND makes them read as membership
        // changes on the wire (see `retention`).
        let peeler = RetentionBoundPeeler::new(peeler);
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
            .convergence_policy(session_convergence_policy())
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
        // Session-open sweep. A `Created` row orphaned by a kill mid-ingest, or
        // a `Retryable` row left by a decrypt failure that can never succeed
        // (an exhausted sender ratchet), gates EVERY later outbound send for
        // its circle — `cgka_engine`'s `should_queue_outbound_intent` queues
        // instead of encrypting while any such row sits in the convergence
        // window, and a stable circle's epoch never moves, so that window is
        // the circle's whole life. Rows whose event the relay has already
        // deleted can never be resolved by re-delivery, so open is where they
        // are cleared: it is the one moment every isolate and every background
        // wake passes through, and it costs one indexed scan per group.
        //
        // Best-effort, exactly like `CircleManager`'s three startup passes: a
        // session that refused to open because a repair scan failed would take
        // location sharing down to fix location sharing. The pass is idempotent
        // and re-runs at the next open (and on a deferred send).
        match sweep_all_groups(&message_store, Timestamp::now().as_secs()) {
            Ok(sweep) if sweep == ConvergenceSweep::default() => {}
            // Bucketed magnitudes, never exact ones: the number of gating rows
            // is the number of circles mid-transition (Security Rule 15).
            Ok(sweep) => log::info!(
                "MLS convergence sweep at open: {} stale input(s) retired, \
                 {} queued location intent(s) discarded, {} row(s) still gating",
                bucket(sweep.disposed_messages),
                bucket(sweep.discarded_intents),
                bucket(sweep.gating_rows)
            ),
            // The engine's own prose can quote a group id, so only the failure
            // is reported; the sweep retries at the next open either way.
            Err(_) => log::warn!("MLS convergence sweep at open failed (retries next open)"),
        }
        Ok(Self {
            session: Mutex::new(session),
            identity_pubkey: keys.public_key(),
            preview_peeler,
            message_store,
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
        self.create_group_with_retention(
            member_key_packages,
            config,
            Some(crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS),
        )
        .await
    }

    /// Creates a group declaring an arbitrary `message-retention.v1` policy —
    /// `None` for no component at all — modelling a circle created by a client
    /// other than a current Haven build.
    ///
    /// Test-only: the production path always declares Haven's own window. Both
    /// arms are states a JOINED circle really reaches, and they fail in opposite
    /// directions. `None` is the older-Haven / foreign-client case, where the
    /// engine reports no retention and would stamp no NIP-40 expiration on this
    /// device's own application 445s — what
    /// [`RetentionBoundPeeler`](super::RetentionBoundPeeler) exists to prevent.
    /// A `Some` shorter than Haven's window is what the bound HONOURS, and is
    /// the only way to observe the group component (rather than the bound)
    /// driving the stamp that actually leaves.
    ///
    /// # Errors
    ///
    /// As [`Self::create_group`].
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn create_group_declaring_retention(
        &self,
        member_key_packages: Vec<KeyPackage>,
        config: LocationGroupConfig,
        retention_secs: Option<u64>,
    ) -> Result<CreateGroupEffects> {
        self.create_group_with_retention(member_key_packages, config, retention_secs)
            .await
    }

    /// Shared group-creation path. `retention_secs` is the group's
    /// `message-retention.v1` (0x8005) policy; `None` declares the component not
    /// at all.
    async fn create_group_with_retention(
        &self,
        member_key_packages: Vec<KeyPackage>,
        config: LocationGroupConfig,
        retention_secs: Option<u64>,
    ) -> Result<CreateGroupEffects> {
        validate_group_relays(&config.relays)?;

        let mut nostr_group_id = [0u8; 32];
        OsRng.fill_bytes(&mut nostr_group_id);
        let routing = NostrRoutingV1::new(nostr_group_id, config.relays.clone())
            .map_err(|e| NostrError::InvalidEvent(format!("invalid group routing: {e}")))?;
        let routing_bytes = encode_nostr_routing_v1(&routing)
            .map_err(|e| NostrError::InvalidEvent(format!("routing encode failed: {e}")))?;

        let initial_admins = parse_member_ids(&config.admins);

        let mut app_components = vec![AppComponentData {
            component_id: NOSTR_ROUTING_COMPONENT_ID,
            data: routing_bytes,
        }];
        // `message-retention.v1`: the engine stamps every kind-445 APPLICATION
        // message with a NIP-40 `expiration` of `inner_created_at + retention`
        // (commits/proposals are never stamped — group history must outlive any
        // TTL). Bounds relay-side residency of location ciphertext to roughly
        // two publish cycles, replacing the pre-Dark-Matter per-send jittered
        // TTL (DM-2 deviation #2 re-wired). A circle whose creator omits it is
        // covered on the send side by
        // [`RetentionBoundPeeler`](super::RetentionBoundPeeler), not
        // here — this component governs the whole group and only its creator
        // (or later, an admin) can set it.
        if let Some(secs) = retention_secs {
            app_components.push(AppComponentData {
                component_id: GROUP_MESSAGE_RETENTION_COMPONENT_ID,
                data: secs.to_be_bytes().to_vec(),
            });
        }

        let req = CreateGroupRequest {
            name: config.name,
            description: config.description,
            members: member_key_packages,
            required_features: Vec::new(),
            app_components,
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

    /// Replaces the group's admin set via an
    /// `UpdateAppComponents(admin-policy.v1)` commit.
    ///
    /// `admins` are raw x-only pubkey bytes (Rule 4: the admin set is member
    /// identity, never the MLS group id). The engine fail-closes on the caller
    /// not being an admin (`NotGroupAdmin`), on an admin with no member leaf,
    /// and on an empty set — so promotion and demotion are both gated
    /// server-side by MLS state, not by Haven's own bookkeeping.
    ///
    /// # Errors
    ///
    /// Returns [`NostrError::InvalidEvent`] if `admins` is empty (a group must
    /// always retain at least one admin), [`NostrError::EpochNotStable`] if the
    /// group's epoch state will not accept a staged commit (see
    /// [`epoch_state_rejection`]), or a redacted MLS error if the engine rejects
    /// the commit for any other reason.
    pub async fn update_admin_policy(
        &self,
        group_id: &GroupId,
        admins: &[[u8; 32]],
    ) -> Result<SessionEffects> {
        let data = encode_admin_policy_v1(admins)?;
        // Not `Self::send`: that funnels every rejection through `map_mls_err`,
        // which stringifies the engine's typed `InvalidTransition` and destroys
        // the one signal the epoch-rotation repair needs to distinguish "the
        // group is busy, try later" from "this failed".
        self.session
            .lock()
            .await
            .send(SendIntent::UpdateAppComponents {
                group_id: group_id.clone(),
                updates: vec![AppComponentData {
                    component_id: GROUP_ADMIN_POLICY_COMPONENT_ID,
                    data,
                }],
            })
            .await
            .map_err(|e| epoch_state_rejection(&e).unwrap_or_else(|| map_mls_err(e)))
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

    /// Builds an unsigned location rumor (inner [`KIND_LOCATION_UPDATE`] Marmot
    /// app event) for the local sender and sends it.
    ///
    /// Convenience over [`Self::create_message`]: constructs the canonical inner
    /// event with `pubkey` == the local identity.
    ///
    /// # Errors
    ///
    /// Returns an error if the engine rejects the send.
    pub async fn send_location(
        &self,
        group_id: &GroupId,
        content: String,
    ) -> Result<SessionEffects> {
        self.create_message(group_id, location_rumor(self.identity_pubkey, content))
            .await
    }

    /// Ingests a raw transport message into the engine (inbound processing).
    ///
    /// Returns [`IngestEffects`] carrying the [`super::types::IngestOutcome`]
    /// classification and any drained events / publish work. The engine
    /// sequences out-of-order input internally.
    ///
    /// No outcome here is a cursor ADVANCE — that is derived from the receive
    /// plane's own window-open time, never from an ingested event's
    /// `created_at` (see [`crate::relay::cursor::cursor_ms_for_window`]). What
    /// the outcome decides is the HOLD-BACK: `Buffered` (and a hard `Err`) keeps
    /// the window's advance at or below that event so it is re-requested, while
    /// `Processed` / `Stale` leave it alone.
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

    /// Screens a signed Nostr event against Haven's local receiver-side policy
    /// and, if it passes, converts it to a transport message and ingests it.
    ///
    /// Returns a [`ScreenedIngest`], which keeps the two dispositions apart at
    /// the type level — see that type for why the distinction cannot be folded
    /// into [`super::types::IngestOutcome`].
    ///
    /// # The two local screens
    ///
    /// Both run before the engine, and both report
    /// [`ScreenedIngest::RejectedBeforeAuth`]: the NIP-40 expiration screen
    /// below, and the pure transport parse further down (see the comment at
    /// that call for why an unparseable envelope is a *pre-authentication*
    /// judgement and what skipping it costs).
    ///
    /// # Receiver-side NIP-40 expiration screen
    ///
    /// Restored post-Dark-Matter (pre-migration this lived in
    /// `decrypt_location`): a well-behaved relay drops expired events, but a
    /// malicious or buggy relay could replay stale location ciphertext past its
    /// advertised TTL. Defense-in-depth: drop locally too, with a small grace
    /// window for clock skew. Every receive plane (poll drain, live-sync,
    /// background catch-up) funnels through this method, so the guard covers all
    /// of them. Gift wraps (kind 1059) carry no expiration tag and pass through
    /// untouched.
    ///
    /// # The screen runs BEFORE authentication — the cursor contract
    ///
    /// The `expiration` tag is read straight off the raw event, so a rejected
    /// event has had NOTHING verified: not its signature, not its ephemeral
    /// author, not its ciphertext, not its membership in the group it claims.
    /// Routing is by the `h` tag, which is the *public* `nostr_group_id` — any
    /// observer of one of a circle's kind-445s can mint a matching event with an
    /// `expiration` in the past and a `created_at` of its choosing.
    ///
    /// A caller therefore MUST treat [`ScreenedIngest::RejectedBeforeAuth`] as
    /// "learned nothing about this event": no routing, no persistence, no
    /// convergence drain, and above all **no sync-cursor advance** — and no
    /// hold-back either. (Before DM-6 this path reported a synthetic `Stale`,
    /// which both cursor gates read as "advance past it" — one forged event
    /// could push a circle's persisted REQ floor to any timestamp it liked and
    /// strand every legitimate event below it, permanently and across restarts.)
    ///
    /// # Errors
    ///
    /// Returns an error only for a hard INGEST failure — i.e. one the engine
    /// raised. A failure of the pre-engine transport parse is not an error here;
    /// it comes back as [`PreAuthRejection::Malformed`].
    pub async fn process_event(&self, event: &Event) -> Result<ScreenedIngest> {
        match Self::screen_before_auth(event) {
            Err(rejection) => Ok(ScreenedIngest::RejectedBeforeAuth(rejection)),
            Ok(msg) => self.ingest(msg).await.map(ScreenedIngest::Ingested),
        }
    }

    /// Runs Haven's two pre-authentication screens over `event` and, if both
    /// pass, converts it to the transport message the engine ingests.
    ///
    /// The single implementation of both screens, so the production entry point
    /// above and the typed test seam below cannot drift: a screen re-implemented
    /// beside its caller asserts the copy, not the policy.
    fn screen_before_auth(
        event: &Event,
    ) -> std::result::Result<cgka_traits::transport::TransportMessage, PreAuthRejection> {
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
                return Err(PreAuthRejection::Expired);
            }
        }
        // ── The pure pre-engine parse, and why its failure is a pre-auth
        //    rejection rather than an un-applied message.
        //
        // `event_to_transport_message` reads ONLY already-materialized envelope
        // fields: the kind, the `h`/`p` routing tag, and the self-reported id
        // against the event's own hash. It touches no key material, never looks
        // at the base64 `content`, reaches no storage, reads no clock and never
        // calls the engine. Every failure it can return therefore says how the
        // event was SIGNED — a missing, duplicated, valueless or wrong-width
        // routing tag, or an unsupported kind — decided before anything
        // authenticated anything. That is the same class of judgement as the
        // expiration screen above, so it is classified the same way:
        // `Malformed`, i.e. terminal, no routing, no persistence, no
        // convergence drain, no cursor advance — and NO HOLD-BACK.
        //
        // # The trade-off this makes, deliberately
        //
        // The previous behaviour returned `Err`, which both receive planes read
        // as "un-applied", holding that window's cursor advance at this event's
        // `created_at`. A circle's `#h` is its PUBLIC `nostr_group_id`, and a
        // conformant relay delivers an event carrying TWO `h` tags to a `#h`
        // subscription for either of them — so any relay observer can mint an
        // unparseable event at a timestamp of its choosing and pin the victim's
        // cursor there, for free, indefinitely, in unlimited supply. Bounded
        // (the cursor write is monotonic-max, so it is a stall and never a
        // skip), but a stall is still the availability loss this whole design
        // exists to remove.
        //
        // What is LOST: if a genuine peer ever emits an unparseable commit, this
        // now steps over it instead of stalling until someone notices. That cost
        // is accepted because holding never recovered such an event either — the
        // parse is deterministic over the delivered bytes, so re-requesting it
        // forever fails identically forever, while the window it re-opens only
        // widens until saturation freezes the cursor for good (Rule 12). Under
        // BOTH rules the engine never sees the event; only the collateral
        // differs.
        //
        // # The boundary, which must not move
        //
        // Scoped deliberately to THIS call's `Err`. The ingest the callers run
        // still propagates its own errors, so an engine-side or decryption-side
        // failure — anything that has already touched key material — keeps
        // holding the cursor. Widening this arm to cover those would hand an
        // attacker a SKIP primitive over authenticated-path failures, which is
        // the exact defect this module's cursor contract exists to prevent.
        Self::event_to_transport_message(event).map_err(|_| PreAuthRejection::Malformed)
    }

    /// [`Self::process_event`] with the engine's own error type preserved.
    ///
    /// Test-only. Identical in every observable respect but one: the ingest
    /// error is NOT flattened through [`map_mls_err`], so the caller can tell a
    /// forked epoch from a storage failure by MATCHING the variant instead of
    /// by reading redacted prose. Both pre-authentication screens run, from the
    /// same [`Self::screen_before_auth`] the production entry point uses.
    ///
    /// # One event, one ingest, one call
    ///
    /// Never call this AND [`Self::process_event`] on the same event: the
    /// engine records each message's outcome and answers a second ingest with
    /// `Stale { AlreadySeen }`, so the second call classifies differently from
    /// the first and a fork silently reads as a duplicate.
    ///
    /// # Errors
    ///
    /// Returns the engine's own error for a hard ingest failure. **Match it,
    /// never format it** — see the re-export note on
    /// [`SessionError`](super::types::SessionError).
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn process_event_typed_for_test(
        &self,
        event: &Event,
    ) -> std::result::Result<ScreenedIngest, SessionError> {
        match Self::screen_before_auth(event) {
            Err(rejection) => Ok(ScreenedIngest::RejectedBeforeAuth(rejection)),
            Ok(msg) => self
                .session
                .lock()
                .await
                .ingest(msg)
                .await
                .map(ScreenedIngest::Ingested),
        }
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

    /// Drains whatever the engine has buffered but not yet handed back.
    ///
    /// The engine's effect buffers are global and one-shot, and a call that
    /// fails MID-WAY leaves everything it already emitted stranded in them:
    /// `confirm_published` / `publish_failed` propagate a replay error BEFORE
    /// `collect_effects` runs, so the caller gets an `Err` and no effects while
    /// a peer location the replay already delivered sits in the buffer with its
    /// durable row written `Processed`. This is how that batch is recovered —
    /// never as a retry, which would apply a commit twice.
    pub async fn drain(&self) -> SessionEffects {
        self.session.lock().await.drain()
    }

    // ── Stuck convergence inputs (the outbound send gate) ────────────────────

    /// Gives a terminal disposition to every stored convergence input that the
    /// relay can no longer redeliver, across every group, and reports what is
    /// still gating outbound sends.
    ///
    /// `now_secs` is injected (Unix seconds) so the age rule is deterministic
    /// under test; production callers pass the wall clock.
    ///
    /// # What it disposes of, and why that cannot fork a group
    ///
    /// ONLY `Created`/`Retryable` rows that project to an MLS **application**
    /// message whose outer `created_at` is [`beyond_relay_retention`]. Such a
    /// row was never applied: it changed no group state, advanced no epoch,
    /// consumed no proposal, and left the `OpenMLS` ratchet exactly where it
    /// was — its whole effect on the group is that the send gate counts it. The
    /// sender's ratchet is derived, not consumed by a receiver, so the peer is
    /// unaffected. And the receive plane's cursor never advanced past it (the
    /// window advance is derived from the plane's own open time, never from an
    /// event stamp), so nothing about re-request semantics changes either —
    /// only the row's state, from "retry me" to `Failed`, which the engine
    /// already reads as `Stale { AlreadySeen }` on a redelivery.
    ///
    /// COMMITS are never disposed of, at any age. Commits and proposals carry
    /// no NIP-40 `expiration`, so a relay keeps them indefinitely and a later
    /// delivery genuinely can resolve them; retiring one would strand this
    /// device at an epoch the group has left — the fork this method must not
    /// cause.
    ///
    /// # What it is FOR, given that the engine self-heals most rows
    ///
    /// A `Created`/`Retryable` application row **at or below** the group tip is
    /// resolved by the engine itself: the next settled canonicalization pass
    /// finds it undecryptable on the canonical branch and writes the terminal
    /// `EpochInvalidated` (`openmls_projection::message_state_for_invalidated_reason`).
    /// The shape that does NOT self-heal is a row whose MLS source epoch is
    /// ABOVE the tip and within `max_rewind_commits` of it: that is kept
    /// `Retryable` deliberately, so the commit that would make it decryptable
    /// can still arrive. When that commit never comes — the sender left, the
    /// relay dropped it, the receive plane missed its window — the row gates
    /// every outbound send for the circle forever. This sweep is the only thing
    /// that clears it, and the age rule is what makes clearing it safe.
    ///
    /// # Errors
    ///
    /// Returns an error if the message store cannot be read or written.
    pub async fn sweep_unresolvable_inputs(&self, now_secs: u64) -> Result<ConvergenceSweep> {
        // Rule 14: hold the session mutex for the whole pass so no engine
        // statement is in flight against the other connection while this one
        // writes.
        let _session = self.session.lock().await;
        sweep_all_groups(&self.message_store, now_secs).map_err(map_storage_err)
    }

    /// [`Self::sweep_unresolvable_inputs`] restricted to one group.
    ///
    /// # Errors
    ///
    /// Returns an error if the message store cannot be read or written.
    pub async fn sweep_unresolvable_inputs_for_group(
        &self,
        group_id: &GroupId,
        now_secs: u64,
    ) -> Result<ConvergenceSweep> {
        let _session = self.session.lock().await;
        scan_group_inputs(
            &self.message_store,
            group_id,
            now_secs,
            ScanMode::RetireUnresolvable,
        )
        .map_err(map_storage_err)
    }

    /// How many stored rows still gate outbound sends for a group, WITHOUT
    /// writing anything.
    ///
    /// The honest way to answer "will the next send encrypt?" after something
    /// else has already changed the state — running a second full sweep to find
    /// out would silently retire rows and report the count of a pass nobody
    /// asked for.
    ///
    /// # Errors
    ///
    /// Returns an error if the message store cannot be read.
    pub async fn gating_input_count(&self, group_id: &GroupId) -> Result<usize> {
        let _session = self.session.lock().await;
        // `now_secs` is unused in `CountOnly` mode (nothing is aged out), so the
        // caller is not asked for a clock it would have no use for.
        scan_group_inputs(&self.message_store, group_id, 0, ScanMode::CountOnly)
            .map(|scan| scan.gating_rows)
            .map_err(map_storage_err)
    }

    /// Whether a stored proposal for this group is still waiting for a commit.
    ///
    /// Deliberately NOT answerable from the engine: a lone uncommitted proposal
    /// is excluded from `has_unresolved_convergence_inputs` on purpose (a
    /// proposal only takes effect once a commit consumes it, so it does not make
    /// canonical state ambiguous), and the in-memory
    /// `scheduled_self_remove_auto_commits` map is `pub(crate)` AND local to
    /// this device — the member that will actually auto-commit the proposal is
    /// somebody else.
    ///
    /// What this answers is the question the epoch-rotation repair has to ask:
    /// *may another member commit at this epoch in a moment?* A stored
    /// `Created`/`Retryable` proposal row inside the group's convergence window
    /// is exactly that evidence, and it is durable, so it survives the restart
    /// that clears every in-memory schedule.
    ///
    /// # Errors
    ///
    /// Returns an error if the message store cannot be read.
    pub async fn has_pending_proposal(&self, group_id: &GroupId) -> Result<bool> {
        let _session = self.session.lock().await;
        pending_proposal_in_window(&self.message_store, group_id).map_err(map_storage_err)
    }

    /// Discards a repair rotation the engine QUEUED instead of staging, and
    /// returns how many rows were removed.
    ///
    /// A queued intent is durable and drains later through
    /// `converge_and_drain_queued_outbound_intents` — at which point it becomes
    /// a real commit with NONE of the repair's gates re-evaluated and no rate
    /// limit charged. Intent ids are not deduplicated, so every Repair tap while
    /// a circle is send-gated would bank another epoch bump, all of them landing
    /// in a burst the moment the circle unblocks.
    ///
    /// The match is deliberately narrow: an `UpdateAppComponents` for this group
    /// whose single update is the admin policy AND whose bytes equal the CURRENT
    /// policy. That payload equality is the whole discriminator — it is what a
    /// repair rotation is (a no-op re-statement) and what a real handoff or
    /// self-demote is not, so a queued membership change parked behind the same
    /// gate survives untouched.
    ///
    /// # Errors
    ///
    /// Returns an error if `current_admins` cannot be encoded, or if the message
    /// store cannot be read or written.
    pub async fn discard_queued_repair_rotation_intents(
        &self,
        group_id: &GroupId,
        current_admins: &[[u8; 32]],
    ) -> Result<usize> {
        let no_op_policy = encode_admin_policy_v1(current_admins)?;
        let _session = self.session.lock().await;
        discard_queued_repair_rotation_intents(&self.message_store, group_id, &no_op_policy)
            .map_err(map_storage_err)
    }

    /// The `admin-policy.v1` encoding of `admins`, as
    /// [`Self::update_admin_policy`] would produce it.
    ///
    /// Test-only. Exposes the codec (which stays private) so a test can build
    /// the exact bytes the repair-rotation discard discriminates on — a no-op
    /// re-statement of the current policy versus a real membership change.
    ///
    /// # Errors
    ///
    /// Returns an error if `admins` is empty.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn admin_policy_payload_for_test(admins: &[[u8; 32]]) -> Result<Vec<u8>> {
        encode_admin_policy_v1(admins)
    }

    /// Hand-queues an `UpdateAppComponents(admin-policy.v1)` intent carrying
    /// `data`, as the engine's own `queue_outbound_intent` would.
    ///
    /// Test-only. `queue_outbound_intent` is `pub(crate)` to the engine and
    /// reachable only by driving a send the gate refuses, which cannot produce
    /// two DIFFERENT policy payloads on demand — so the discard's
    /// discriminator (payload equality) has no other way to be exercised
    /// directly.
    ///
    /// # Errors
    ///
    /// Returns an error if the message store cannot be written.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn queue_admin_policy_intent_for_test(
        &self,
        group_id: &GroupId,
        data: Vec<u8>,
    ) -> Result<()> {
        use cgka_traits::storage::QueuedOutboundIntent;

        let _session = self.session.lock().await;
        let mut id = [0u8; 32];
        OsRng.fill_bytes(&mut id);
        self.message_store
            .put_queued_outbound_intent(&QueuedOutboundIntent {
                id: cgka_traits::types::MessageId::new(id.to_vec()),
                group_id: group_id.clone(),
                intent: SendIntent::UpdateAppComponents {
                    group_id: group_id.clone(),
                    updates: vec![AppComponentData {
                        component_id: GROUP_ADMIN_POLICY_COMPONENT_ID,
                        data,
                    }],
                },
                created_at_ms: 0,
            })
            .map_err(map_storage_err)
    }

    /// The admin-policy payload of every queued `UpdateAppComponents` intent for
    /// a group.
    ///
    /// Test-only. Lets a test distinguish "the repair banked nothing" from "the
    /// repair banked a rotation" WITHOUT reading the engine's private queue
    /// shape, and lets it show that a real membership intent parked behind the
    /// same gate survived.
    ///
    /// # Errors
    ///
    /// Returns an error if the message store cannot be read.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn queued_admin_policy_payloads_for_test(
        &self,
        group_id: &GroupId,
    ) -> Result<Vec<Vec<u8>>> {
        let _session = self.session.lock().await;
        let mut out = Vec::new();
        for queued in self
            .message_store
            .list_queued_outbound_intents(group_id)
            .map_err(map_storage_err)?
        {
            if let SendIntent::UpdateAppComponents { updates, .. } = &queued.intent {
                for update in updates {
                    if update.component_id == GROUP_ADMIN_POLICY_COMPONENT_ID {
                        out.push(update.data.clone());
                    }
                }
            }
        }
        Ok(out)
    }

    /// Discards every durably queued outbound LOCATION intent for a group,
    /// returning how many rows were removed.
    ///
    /// The half of the sweep that a deferral needs even when nothing is stuck:
    /// an eviction-staged deferral has no unresolvable row to retire, but the
    /// engine still queued the location fix that triggered it, and a fix that
    /// waits for the next session open is a stale position on a peer's map.
    /// See [`discard_queued_location_intents`] for why the discard is
    /// unconditional and why it is `AppMessage`-only.
    ///
    /// # Errors
    ///
    /// Returns an error if the message store cannot be read or written.
    pub async fn discard_queued_location_intents(&self, group_id: &GroupId) -> Result<usize> {
        let _session = self.session.lock().await;
        discard_queued_location_intents(&self.message_store, group_id).map_err(map_storage_err)
    }

    /// Reads the MOST RECENTLY stored openmls-wire row of content `kind` whose
    /// MLS source epoch satisfies `source_epoch_at_least`, verbatim.
    ///
    /// Most-recent rather than first, because a fixture almost always wants the
    /// row a test JUST caused to be written — and taking the first match
    /// silently hands back an older row at the same epoch, which is how a
    /// fixture ends up staging a message the device under test has already
    /// processed instead of one it has never seen.
    ///
    /// Test-only, and one half of the fixture pair: a test stages a stuck row by
    /// taking a REAL row a real device really stored (with its real MLS wire
    /// bytes and its real id) and writing it into the device under test with
    /// [`Self::stage_convergence_input_for_test`]. The two halves are separate
    /// so the source row can come from a DIFFERENT member's store — which is the
    /// only way to obtain application bytes sealed at an epoch above this
    /// device's tip, the one shape the engine deliberately never resolves.
    ///
    /// # Errors
    ///
    /// Returns an error if the group holds no matching row, or the store cannot
    /// be read.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn stored_convergence_input_for_test(
        &self,
        group_id: &GroupId,
        kind: OpenMlsContentKind,
        source_epoch_at_least: u64,
    ) -> Result<cgka_traits::message::MessageRecord> {
        let _session = self.session.lock().await;
        self.message_store
            .list_messages(group_id, EpochId(0))
            .map_err(map_storage_err)?
            .into_iter()
            .rev()
            .find(|record| {
                gating_projection(&record.payload).is_some_and(|(_, projection)| {
                    projection.kind == kind
                        && projection
                            .source_epoch
                            .is_some_and(|epoch| epoch >= source_epoch_at_least)
                })
            })
            .ok_or_else(|| {
                NostrError::StorageError(
                    "no stored message of that content kind and epoch to copy".to_string(),
                )
            })
    }

    /// Writes `source` into THIS device's store in `state`, its outer
    /// `created_at` moved `backdated_by_secs` into the past.
    ///
    /// Test-only, and the other half of the fixture pair. It reproduces the
    /// durable row a process kill leaves behind between
    /// `persist_openmls_wire_message(.., Created)` and `process_message`, or the
    /// row a decrypt failure leaves as `Retryable`.
    ///
    /// # The id is preserved, and that is the whole point
    ///
    /// `MessageRecord::id` MUST equal the `TransportMessage::id` embedded in the
    /// payload. Production always writes them equal (`persist_openmls_wire_message`
    /// stores `msg.id` as both), and the engine relies on it: every disposition
    /// path resolves rows by the PAYLOAD-embedded id
    /// (`project_pending_canonicalization_messages` →
    /// `persist_openmls_canonicalization_dispositions`), while the send gate
    /// reads `MessageRecord::state`. A fixture that minted a fresh record id
    /// would therefore build a row the engine can never dispose of and the gate
    /// can never stop counting — an artifact that "proves" a wedge production
    /// cannot reach. Only `TransportMessage::timestamp` is altered here; the id
    /// is an opaque key to every path that touches it, so backdating cannot
    /// desynchronize anything.
    ///
    /// The record's `epoch` column is stamped with THIS device's current group
    /// epoch, exactly as `persist_openmls_wire_message` stamps the receiver's
    /// tip at ingest time.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown or the store cannot be written.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn stage_convergence_input_for_test(
        &self,
        source: &cgka_traits::message::MessageRecord,
        state: MessageState,
        backdated_by_secs: u64,
    ) -> Result<MessageId> {
        use cgka_traits::message::MessageRecord;
        use cgka_traits::transport::Timestamp as TransportTimestamp;

        let _session = self.session.lock().await;
        let group = self
            .message_store
            .get_group(&source.group_id)
            .map_err(map_storage_err)?;

        let decoded = StoredMessagePayload::decode(&source.payload)
            .map_err(|e| NostrError::StorageError(format!("stored payload decode: {e}")))?;
        // Preserved rather than rebuilt: an own published-and-confirmed commit
        // carries a convergence stamp stored convergence needs, and a copy that
        // silently dropped it would not be the row a crash leaves.
        let stamp = decoded.own_commit_stamp().cloned();
        let mut message = decoded.into_message();
        message.timestamp =
            TransportTimestamp(message.timestamp.0.saturating_sub(backdated_by_secs));
        let id = message.id.clone();
        let payload = match stamp {
            Some(stamp) => StoredMessagePayload::own_commit_wire(message, stamp),
            None => StoredMessagePayload::openmls_wire(message),
        }
        .encode()
        .map_err(|e| NostrError::StorageError(format!("stored payload encode: {e}")))?;

        self.message_store
            .put_message(&MessageRecord {
                id: id.clone(),
                group_id: source.group_id.clone(),
                epoch: group.epoch,
                state,
                payload,
            })
            .map_err(map_storage_err)?;
        Ok(id)
    }

    /// The readable part of one stored message row, or `None` when no such row
    /// exists.
    ///
    /// Test-only: lets a test assert that the sweep changed exactly the row it
    /// was supposed to and left the others alone, and lets an undecryptable-event
    /// classifier tell a branch loss (`EpochInvalidated`) from an ordinary
    /// past-epoch drop (`Failed`).
    ///
    /// Returns a [`StoredMessageProbe`], not the `MessageRecord`: the record
    /// also carries the real MLS `group_id` and the ciphertext payload, neither
    /// of which any caller of this needs and both of which a caller that holds
    /// them can render (Security Rules 4 and 15).
    ///
    /// # Errors
    ///
    /// Returns an error if the store cannot be read.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn stored_message_record_for_test(
        &self,
        id: &MessageId,
    ) -> Result<Option<StoredMessageProbe>> {
        let _session = self.session.lock().await;
        match self.message_store.get_message(id) {
            Ok(record) => Ok(Some(StoredMessageProbe {
                epoch: record.epoch,
                state: record.state,
            })),
            Err(StorageError::NotFound) => Ok(None),
            Err(e) => Err(map_storage_err(e)),
        }
    }

    /// How many outbound intents are durably queued for a group.
    ///
    /// Test-only: the discard path's observable effect.
    ///
    /// # Errors
    ///
    /// Returns an error if the store cannot be read.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn queued_intent_count_for_test(&self, group_id: &GroupId) -> Result<usize> {
        let _session = self.session.lock().await;
        self.message_store
            .list_queued_outbound_intents(group_id)
            .map(|queued| queued.len())
            .map_err(map_storage_err)
    }

    // ── Welcomes (hold-before-ingest, F3) ────────────────────────────────────

    /// Peels a gift-wrapped welcome WITHOUT ingesting it, to derive a pre-accept
    /// preview. The decrypted MLS welcome bytes are read and immediately
    /// discarded — never stored (F3). Only the non-secret inviter identity is
    /// returned.
    ///
    /// # Errors
    ///
    /// Returns an error if the event is not a welcome addressed to this client,
    /// is malformed, or carries no verifiable seal author (see
    /// [`inviter_from_sender`]).
    pub async fn preview_welcome(&self, gift_wrap: &Event) -> Result<WelcomePreview> {
        let msg = Self::event_to_transport_message(gift_wrap)?;
        let peeled = self
            .preview_peeler
            .peel_welcome(&msg)
            .await
            .map_err(map_mls_err)?;
        // `peeled.content` holds the decrypted welcome bytes; drop it by not
        // binding it. Only the seal author (inviter) is retained.
        Ok(WelcomePreview {
            inviter_pubkey: inviter_from_sender(peeled.sender.as_ref())?,
        })
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

    /// The engine group ids that failed session-open hydration and were skipped.
    ///
    /// Quarantine is deliberately indistinguishable from "unknown" on every
    /// engine accessor — `ensure_group_live` returns `UnknownGroup` for a
    /// quarantined group — so a caller that must tell "temporarily unreadable"
    /// from "genuinely failed to read" has to ask here.
    ///
    /// "Quarantined" means *for the life of this session*, not for ever:
    /// entries are added only at session open and cleared only by
    /// `retry_hydrate_quarantined_group`, which Haven never calls, so the next
    /// open re-attempts hydration from scratch and a transiently-bad group heals
    /// on a restart.
    ///
    /// The upstream `GroupHydrationQuarantineReason` is dropped: Haven exposes
    /// no per-group recovery surface to branch on, and every consumer needs only
    /// the identity of the groups it must skip.
    pub async fn quarantined_group_ids(&self) -> Vec<GroupId> {
        self.session
            .lock()
            .await
            .quarantined_groups()
            .into_iter()
            .map(|(group_id, _reason)| group_id)
            .collect()
    }

    /// The group's roster, read under the same lock as the gate that says
    /// whether it is safe to persist.
    ///
    /// # Why the gate and the read are one call
    ///
    /// [`Self::members`] returns the engine's OPTIMISTIC PROJECTION for any
    /// group in `PendingPublish`: the send paths overwrite the stored member
    /// list with the post-merge set before anything is published, so someone
    /// added by a commit no relay has seen — and that branch selection can still
    /// withdraw — is in the roster the instant `send()` returns. Gating through
    /// a separate call would release the session lock between the verdict and
    /// the read, and a commit staged in that window would hand the caller
    /// exactly the projection the gate exists to refuse.
    ///
    /// # What the gate is
    ///
    /// * [`Self::epoch`] resolves to the engine's PROJECTED epoch while
    ///   `group_record().epoch` stays at the prior value; the two are re-derived
    ///   together only by the merge and the rollback, so they differ exactly in
    ///   `PendingPublish` and `Merging`.
    /// * `has_pending_convergence_inputs` reports whether a stored
    ///   `Created`/`Retryable` message record inside the rewind window projects
    ///   to a commit or an application message. It FAILS OPEN — a row it cannot
    ///   decode or project is skipped, and an absent group reads `false` — so
    ///   `false` means "nothing resolvable is outstanding", never "clean slate".
    ///   That is why it is paired with the epoch equality instead of trusted
    ///   alone.
    ///
    /// Two states satisfy the epoch equality without being settled: `Recovering`
    /// and `Unrecoverable` both report `last_stable_epoch`, which is what
    /// storage already holds. A third, a zero-invitee create still in
    /// `PendingPublish`, projects epoch 0 against a stored epoch 0 — its roster
    /// is the creator alone, so it carries no peer to mis-persist, but a caller
    /// reading [`ConvergedRoster::Converged`] as "no commit is in flight" would
    /// be wrong.
    ///
    /// # Errors
    ///
    /// Returns an error for any engine failure other than an absent or
    /// quarantined group, both of which are [`ConvergedRoster::Absent`].
    pub async fn converged_member_pubkeys(&self, group_id: &GroupId) -> Result<ConvergedRoster> {
        let session = self.session.lock().await;
        let verdict = converged_roster(&session, group_id);
        drop(session);
        verdict.map_err(map_mls_err)
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

    /// The group's declared `marmot.group.message-retention.v1` (0x8005) window
    /// in seconds, or `None` when the group declares none — or declares zero,
    /// which upstream defines as expiration disabled.
    ///
    /// The zero fold below is load-bearing, unlike the identical-looking one in
    /// `retention::bounded_retention_secs`: `app_component`
    /// hands back the component's RAW bytes, so a peer declaring eight zero
    /// bytes arrives here as `Some(0)` with nothing upstream having collapsed
    /// it, and reporting that as a live window would invert the meaning.
    ///
    /// Absence is a real state of a joined circle, not a default: a circle
    /// created by a client that never declared the component reports `None`
    /// here, and upstream that means "stamp no NIP-40 expiration at all". What
    /// actually leaves this device is bounded independently of this value by
    /// [`RetentionBoundPeeler`](super::RetentionBoundPeeler); this
    /// accessor reports what the GROUP declares, which is what governs every
    /// other member's client.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown, or if the component is present
    /// but not the 8 big-endian bytes the format requires.
    pub async fn group_message_retention_secs(&self, group_id: &GroupId) -> Result<Option<u64>> {
        let raw = self
            .session
            .lock()
            .await
            .app_component(group_id, GROUP_MESSAGE_RETENTION_COMPONENT_ID)
            .map_err(map_mls_err)?;
        let Some(bytes) = raw else { return Ok(None) };
        let encoded: [u8; 8] = bytes.as_slice().try_into().map_err(|_| {
            NostrError::MdkError("message-retention component must be 8 bytes".to_string())
        })?;
        Ok(Some(u64::from_be_bytes(encoded)).filter(|secs| *secs > 0))
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
    /// - `MessageReceived` → `Location`, carrying the inner content only when the
    ///   inner event's kind is a location update (see `inner_location_content`);
    ///   a foreign inner kind yields the variant with empty content, never a
    ///   parseable payload and never an error.
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
                content: inner_location_content(payload),
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

/// Maps a `storage-sqlite` failure into Haven's redacted storage-error bucket.
///
/// Generic over the error type for the same reason [`map_mls_err`] is: it is
/// used both as a `map_err` argument (by value) and on a formatted message.
fn map_storage_err<E: std::fmt::Display>(e: E) -> NostrError {
    NostrError::StorageError(redact_hex_sequences(&e.to_string()))
}

/// Decodes a stored payload into `(outer created_at, MLS projection)`, or
/// `None` when the row is not an openmls-wire payload or does not project.
///
/// Deliberately the same fail-OPEN three-step chain the engine's own send gate
/// uses (`decode -> as_openmls_wire -> project_mls_message`, mdk#752): a row
/// this cannot read is not resolvable convergence work, so it neither gates nor
/// gets a disposition here.
fn gating_projection(
    payload: &[u8],
) -> Option<(
    u64,
    cgka_engine::openmls_projection::OpenMlsMessageProjection,
)> {
    let stored = StoredMessagePayload::decode(payload).ok()?;
    let message = stored.as_openmls_wire()?;
    let projection = project_mls_message(&message.payload).ok()?;
    Some((message.timestamp.0, projection))
}

/// Whether a scan may WRITE.
///
/// Split so the "is anything still gating?" question can be asked without
/// retiring rows as a side effect: a second mutating pass would dispose of rows
/// nobody asked it to and report a count for a pass the caller never requested.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ScanMode {
    /// Retire unresolvable application rows and discard queued location
    /// intents, then count what still gates.
    RetireUnresolvable,
    /// Count what gates. Writes nothing; `now_secs` is unused.
    CountOnly,
}

/// The convergence rewind window this group's send gate will actually use.
///
/// Mirrors the engine's `convergence_policy_for_group` EXACTLY: the PERSISTED
/// per-group policy if one is stored (`ConvergencePolicyStorage`, which
/// `Engine::set_group_convergence_policy` is the only writer of), otherwise the
/// policy this session installs.
///
/// Deliberately NOT `max(stored, session)`. A wider window is not the harmless
/// direction it looks like: this window decides the GATING COUNT as well as the
/// scan, so widening it over-counts — it reports rows as gating that the
/// engine's own narrower window ignores, and a circle the engine would happily
/// let send is then surfaced to the user as permanently stalled. Matching the
/// engine is the only value that makes `gating_rows == 0` mean what it says.
/// A stored policy that cannot be decoded is treated as absent, which is what
/// the engine does with one it cannot validate.
fn convergence_rewind_for_group(store: &SqliteAccountStorage, group_id: &GroupId) -> u64 {
    store
        .convergence_policy(group_id)
        .ok()
        .flatten()
        .and_then(|bytes| serde_json::from_slice::<CanonicalizationPolicy>(&bytes).ok())
        .map_or_else(
            || session_convergence_policy().convergence.max_rewind_commits,
            |policy| policy.convergence.max_rewind_commits,
        )
}

/// One group's pass over the stored convergence inputs.
///
/// Mirrors `cgka_engine`'s `has_unresolved_convergence_inputs` exactly for the
/// GATING count — the same `[tip - max_rewind, tip + max_rewind]` window, the
/// same `Created`/`Retryable` states, the same commit-or-application content
/// kinds, the same future-horizon skip — so `gating_rows == 0` is a faithful
/// prediction of "the next send will encrypt rather than queue".
///
/// In [`ScanMode::RetireUnresolvable`] it also writes: the DISPOSITION is
/// narrower than the gate on purpose (application messages only, and only past
/// [`beyond_relay_retention`]), and queued location intents are discarded. See
/// [`SessionManager::sweep_unresolvable_inputs`] for why a commit is never
/// disposed of at any age.
fn scan_group_inputs(
    store: &SqliteAccountStorage,
    group_id: &GroupId,
    now_secs: u64,
    mode: ScanMode,
) -> StorageResult<ConvergenceSweep> {
    let group = match store.get_group(group_id) {
        Ok(group) => group,
        // The engine's gate reads a missing group as "nothing gates"; so does
        // this, rather than turning a deleted circle into a sweep failure.
        Err(StorageError::NotFound) => return Ok(ConvergenceSweep::default()),
        Err(e) => return Err(e),
    };
    let rewind = convergence_rewind_for_group(store, group_id);
    let anchor = EpochId(group.epoch.0.saturating_sub(rewind));
    let ceiling = group.epoch.0.saturating_add(rewind);
    let retiring = mode == ScanMode::RetireUnresolvable;

    let mut sweep = ConvergenceSweep::default();
    for record in store.list_messages(group_id, anchor)? {
        if !matches!(
            record.state,
            MessageState::Created | MessageState::Retryable
        ) {
            continue;
        }
        let Some((created_at, projection)) = gating_projection(&record.payload) else {
            continue;
        };
        if retiring
            && projection.kind == OpenMlsContentKind::Application
            && beyond_relay_retention(created_at, now_secs)
        {
            // Retired regardless of where the row sits relative to the future
            // horizon: an application message the relay has deleted can never
            // become applicable, so keeping it "in case the tip advances into
            // its window" only re-arms the gate later.
            store.update_message_state(&record.id, MessageState::Failed)?;
            sweep.disposed_messages += 1;
            continue;
        }
        let beyond_horizon = projection.source_epoch.is_some_and(|epoch| epoch > ceiling);
        if !beyond_horizon
            && matches!(
                projection.kind,
                OpenMlsContentKind::Application | OpenMlsContentKind::Commit
            )
        {
            sweep.gating_rows += 1;
        }
    }

    if !retiring {
        return Ok(sweep);
    }

    sweep.discarded_intents = discard_queued_location_intents(store, group_id)?;
    Ok(sweep)
}

/// Whether the group holds a proposal that a member could still commit.
///
/// # Why the epoch bound is the whole predicate
///
/// A proposal is only committable at the epoch it was made for: MDK's own replay
/// refuses one whose `source_epoch` no longer equals the group's
/// (`replay_scheduled_self_remove_auto_commit`), and RFC 9420 says the same — a
/// commit references proposals from the epoch it extends. A proposal BELOW the
/// group record's epoch has already been superseded and cannot produce a
/// competing commit.
///
/// That bound is not a refinement, it is the difference between a gate and a
/// wedge. The engine never marks a proposal row `Processed`: its ingest arm
/// stores the row and returns, and the row keeps its `Created` state for the
/// life of the group. Counting `Created` proposal rows at ANY epoch would make
/// every circle that has ever had a departure permanently unrepairable —
/// silently, because a skip is indistinguishable from a healthy circle.
/// `a_repair_is_possible_again_once_the_departure_commits` is the test that
/// fails when this regresses.
///
/// A proposal above the future horizon is skipped for the same reason
/// [`scan_group_inputs`] skips one: it cannot chain from the current tip yet, so
/// no member can commit it.
fn pending_proposal_in_window(
    store: &SqliteAccountStorage,
    group_id: &GroupId,
) -> StorageResult<bool> {
    let group = match store.get_group(group_id) {
        Ok(group) => group,
        // A missing group holds no proposals; the engine's own gate reads a
        // missing group the same way.
        Err(StorageError::NotFound) => return Ok(false),
        Err(e) => return Err(e),
    };
    let rewind = convergence_rewind_for_group(store, group_id);
    let anchor = EpochId(group.epoch.0.saturating_sub(rewind));
    let ceiling = group.epoch.0.saturating_add(rewind);

    for record in store.list_messages(group_id, anchor)? {
        if !matches!(
            record.state,
            MessageState::Created | MessageState::Retryable
        ) {
            continue;
        }
        let Some((_created_at, projection)) = gating_projection(&record.payload) else {
            continue;
        };
        if projection.kind != OpenMlsContentKind::Proposal {
            continue;
        }
        // No source epoch is not "harmless": an undatable proposal cannot be
        // shown to be superseded, so it counts. Production always carries one
        // (`project_mls_message` reads it off the wire for the plaintext
        // proposals MDK sends), so this is the fail-closed floor, not a path.
        let committable = projection
            .source_epoch
            .is_none_or(|epoch| epoch >= group.epoch.0 && epoch <= ceiling);
        if committable {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Deletes every durably queued outbound LOCATION intent for a group, returning
/// how many rows were removed.
///
/// `AppMessage` is the ONLY intent Haven ever sends that is disposable:
/// [`SessionManager::create_message`] is reached from
/// [`SessionManager::send_location`] and nowhere else, so every queued app
/// message is a location fix. A queued membership change (a leave, an invite) is
/// durable user intent parked behind the same gate and is never touched.
///
/// Discarded UNCONDITIONALLY rather than by age. An intent is queued only
/// because the circle could not send, so by the time anything reads it the fix
/// has already missed at least one publish cycle and the next tick carries a
/// better one — there is no age at which publishing it beats publishing a
/// current position, and a stale marker on a peer's map is worse than no marker.
/// (There is also no honest age to test: the engine stamps `created_at_ms` from
/// `convergence_now_ms`, which is elapsed time since THIS engine started, not a
/// wall clock, so it is neither comparable to a Unix timestamp nor stable across
/// a restart.)
/// Deletes every durably queued outbound intent for a group that is a repair
/// rotation — an `UpdateAppComponents` carrying exactly one update, for the
/// admin-policy component, whose bytes equal `no_op_policy`.
///
/// See [`SessionManager::discard_queued_repair_rotation_intents`] for why the
/// payload equality is the discriminator and why nothing else may be discarded.
fn discard_queued_repair_rotation_intents(
    store: &SqliteAccountStorage,
    group_id: &GroupId,
    no_op_policy: &[u8],
) -> StorageResult<usize> {
    let mut discarded = 0;
    for queued in store.list_queued_outbound_intents(group_id)? {
        let SendIntent::UpdateAppComponents { updates, .. } = &queued.intent else {
            continue;
        };
        let [update] = updates.as_slice() else {
            continue;
        };
        if update.component_id == GROUP_ADMIN_POLICY_COMPONENT_ID && update.data == no_op_policy {
            store.delete_queued_outbound_intent(&queued.id)?;
            discarded += 1;
        }
    }
    Ok(discarded)
}

fn discard_queued_location_intents(
    store: &SqliteAccountStorage,
    group_id: &GroupId,
) -> StorageResult<usize> {
    let mut discarded = 0;
    for queued in store.list_queued_outbound_intents(group_id)? {
        if matches!(queued.intent, SendIntent::AppMessage { .. }) {
            store.delete_queued_outbound_intent(&queued.id)?;
            discarded += 1;
        }
    }
    Ok(discarded)
}

/// [`scan_group_inputs`] in [`ScanMode::RetireUnresolvable`] over every group
/// the store holds.
fn sweep_all_groups(
    store: &SqliteAccountStorage,
    now_secs: u64,
) -> StorageResult<ConvergenceSweep> {
    let mut total = ConvergenceSweep::default();
    for group_id in store.list_groups()? {
        total.absorb(scan_group_inputs(
            store,
            &group_id,
            now_secs,
            ScanMode::RetireUnresolvable,
        )?);
    }
    Ok(total)
}

/// The [`ConvergedRoster`] verdict for one group, taken from a single, already
/// acquired session guard.
///
/// Split out of [`SessionManager::converged_member_pubkeys`] so the guard is
/// held across the three engine reads (making them describe one instant) and
/// still released before the error mapping runs.
fn converged_roster(
    session: &AccountDeviceSession,
    group_id: &GroupId,
) -> std::result::Result<ConvergedRoster, SessionError> {
    let group = match session.group_record(group_id) {
        Ok(group) => group,
        // A never-seen group surfaces as `Storage(NotFound)`; a group
        // quarantined at hydration surfaces as `UnknownGroup`. Both mean "no
        // live group here", which is a skip — never a read failure.
        Err(SessionError::Engine(
            EngineError::UnknownGroup(_)
            | EngineError::Storage(cgka_traits::storage::StorageError::NotFound),
        )) => return Ok(ConvergedRoster::Absent),
        Err(e) => return Err(e),
    };
    if session.epoch(group_id)? != group.epoch
        || session.has_pending_convergence_inputs(group_id)?
    {
        return Ok(ConvergedRoster::NotConverged);
    }
    Ok(ConvergedRoster::Converged {
        member_pubkeys_hex: session
            .members(group_id)?
            .into_iter()
            .map(|m| hex::encode(m.id.as_slice()))
            .collect(),
        removed: group.removed,
    })
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

/// Encodes an admin set into the `admin-policy.v1` app-component wire format.
///
/// The format is a QUIC varint byte-length prefix followed by the concatenated
/// 32-byte x-only admin pubkeys, ascending byte order, no duplicates — the
/// engine's decoder rejects trailing bytes, a non-multiple-of-32 length, and
/// any unsorted/duplicated key, so the sort+dedup here is load-bearing rather
/// than cosmetic. Keeping the codec Haven-side is what the pre-Dark-Matter
/// stubs assumed impossible: the engine's own `encode_admin_policy` is
/// `pub(crate)`, but every primitive it is built from
/// (`GROUP_ADMIN_POLICY_COMPONENT_ID`, `AppComponentData`, `encode_quic_varint`)
/// is public, and MDK's conformance simulator — an external crate — encodes it
/// exactly this way.
fn encode_admin_policy_v1(admins: &[[u8; 32]]) -> Result<Vec<u8>> {
    let mut admins = admins.to_vec();
    admins.sort_unstable();
    admins.dedup();
    if admins.is_empty() {
        return Err(NostrError::InvalidEvent(
            "admin policy must contain at least one admin".to_string(),
        ));
    }
    let byte_len = admins
        .len()
        .checked_mul(32)
        .and_then(|n| u64::try_from(n).ok())
        .ok_or_else(|| NostrError::InvalidEvent("admin policy is too large".to_string()))?;
    let mut out = Vec::new();
    encode_quic_varint(byte_len, &mut out);
    for admin in &admins {
        out.extend_from_slice(admin);
    }
    Ok(out)
}

/// Builds the canonical inner location rumor for `sender`.
///
/// Split out of [`SessionManager::send_location`] so the one guarantee that
/// cannot be observed downstream — the KIND on the wire, which is sealed inside
/// the 445 before anything else can look at it — is directly assertable.
///
/// No tags: the kind is the discriminator now, and the `["t","location"]`
/// hashtag the pre-cutover rumor carried is read by no receiver anywhere — not
/// MDK, not White Noise, not Haven's own gate on a current-kind rumor.
fn location_rumor(sender: PublicKey, content: String) -> UnsignedEvent {
    nostr::EventBuilder::new(Kind::Custom(KIND_LOCATION_UPDATE), content).build(sender)
}

/// Extracts the inner `content` of a `MarmotAppEvent` JSON payload **only when
/// the inner event's kind says it is a location update**; otherwise the empty
/// string. [`LEGACY_KIND_LOCATION_UPDATE`] counts only paired with a
/// `["t","location"]` hashtag — see that constant for what the pair does and
/// does not buy.
///
/// The empty string, rather than `None` or an `Err`, is what keeps a gated
/// message honest: the fold still reports `LocationMessageResult::Location`, so
/// the caller advances past an authenticated message it cannot use. `None` is
/// how every plane spells "no message arrived", and an error would put a peer's
/// choice of message kind in front of the user.
fn inner_location_content(payload: &[u8]) -> String {
    let Ok(inner) = serde_json::from_slice::<serde_json::Value>(payload) else {
        return String::new();
    };
    if !is_location_rumor(&inner) {
        return String::new();
    }
    inner
        .get("content")
        .and_then(|c| c.as_str().map(String::from))
        .unwrap_or_default()
}

/// Whether an inner unsigned-event JSON value carries a Haven location update.
fn is_location_rumor(inner: &serde_json::Value) -> bool {
    let Some(kind) = inner.get("kind").and_then(serde_json::Value::as_u64) else {
        return false;
    };
    if kind == u64::from(KIND_LOCATION_UPDATE) {
        return true;
    }
    kind == u64::from(LEGACY_KIND_LOCATION_UPDATE) && has_location_hashtag(inner)
}

/// Whether an inner unsigned-event JSON value carries `["t","location"]`.
fn has_location_hashtag(inner: &serde_json::Value) -> bool {
    inner
        .get("tags")
        .and_then(serde_json::Value::as_array)
        .is_some_and(|tags| {
            tags.iter().any(|tag| {
                tag.as_array().is_some_and(|parts| {
                    parts.first().and_then(serde_json::Value::as_str) == Some("t")
                        && parts.get(1).and_then(serde_json::Value::as_str) == Some("location")
                })
            })
        })
}

/// The inviter a welcome preview may show, from the seal author the transient
/// peel exposed.
///
/// Refuses anything that is not a public key rather than previewing a blank or
/// uncheckable identity: the peel proves nothing else about an invitation, and
/// the anti-impersonation mitigation on the accept screen is entirely that the
/// user can compare the inviter's npub with what they were handed. The peeler
/// has never yet produced an authorless welcome — but `sender` is an `Option`,
/// so the state is representable, and `hex_to_npub("")` returns its own input,
/// which put an EMPTY npub beside an Accept button for live location sharing.
///
/// # Errors
///
/// Returns [`NostrError::InvalidEvent`] when the peel exposes no usable author.
fn inviter_from_sender(sender: Option<&MemberId>) -> Result<String> {
    sender
        .and_then(|m| PublicKey::from_slice(m.as_slice()).ok())
        .map(|pk| pk.to_hex())
        .ok_or_else(|| NostrError::InvalidEvent("welcome has no verifiable sender".to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Gate 2: the epoch-state token match ──────────────────────────────────

    #[test]
    fn every_epoch_state_name_is_pinned_by_the_token_set() {
        use cgka_traits::engine_state::{EpochState, PendingStateRef, StagedCommitHandle};
        use cgka_traits::types::EpochId;

        // Real states, built through the public transition API, so the tokens
        // asserted here are the ones `EpochState::name()` actually produces —
        // not literals copied from the upstream source.
        let stable = EpochState::stable(EpochId(7));
        let pending = stable
            .clone()
            .begin_pending(
                EpochId(8),
                StagedCommitHandle::from_bytes(Vec::new()),
                PendingStateRef::new(1),
            )
            .expect("Stable -> PendingPublish is legal");
        let merging = pending
            .clone()
            .confirm_publish()
            .expect("PendingPublish -> Merging is legal");
        let recovering = EpochState::stable(EpochId(7)).detect_fork(Vec::new());
        let unrecoverable = EpochState::stable(EpochId(7)).to_unrecoverable();

        // An exhaustive match, so a NEW upstream `EpochState` variant breaks
        // compilation here rather than silently arriving as an `InvalidTransition`
        // this classifier drops into the generic MLS-error bucket.
        for state in [&stable, &pending, &merging, &recovering, &unrecoverable] {
            let expected = match state {
                EpochState::Stable { .. } => "Stable",
                EpochState::PendingPublish(_) => "PendingPublish",
                EpochState::Merging(_) => "Merging",
                EpochState::Recovering(_) => "Recovering",
                EpochState::Unrecoverable(_) => "Unrecoverable",
            };
            assert_eq!(state.name(), expected, "upstream renamed an epoch state");
            // Every epoch state must land in EXACTLY one bucket: retryable,
            // terminal, or `Stable` (which is never the `from` of a refusal,
            // because it is the one state a commit is accepted from).
            let retryable = EPOCH_RETRYABLE_TOKENS.contains(&state.name());
            let terminal = state.name() == EPOCH_UNRECOVERABLE_TOKEN;
            let accepting = state.name() == "Stable";
            assert_eq!(
                usize::from(retryable) + usize::from(terminal) + usize::from(accepting),
                1,
                "'{}' must be classified exactly once",
                state.name()
            );
        }
        assert!(
            !EPOCH_RETRYABLE_TOKENS.contains(&"Stable"),
            "`Stable` can never be a refusal's `from`; listing it would classify a future \
             refusal as retryable on no evidence"
        );
    }

    #[test]
    fn only_an_epoch_state_transition_maps_to_epoch_not_stable() {
        use cgka_traits::engine_state::InvalidTransition;

        let refusal = |from: &'static str| {
            SessionError::Engine(EngineError::InvalidTransition(InvalidTransition {
                from,
                to: "UpdateAppComponents",
                reason: "update_app_components requires Stable",
            }))
        };

        // The same `InvalidTransition` variant carries several unrelated
        // refusals, and they need OPPOSITE handling.
        for token in EPOCH_RETRYABLE_TOKENS {
            assert!(
                matches!(
                    epoch_state_rejection(&refusal(token)),
                    Some(NostrError::EpochNotStable)
                ),
                "'{token}' is a state the group leaves on its own and must read as retryable"
            );
        }
        assert!(
            matches!(
                epoch_state_rejection(&refusal(EPOCH_UNRECOVERABLE_TOKEN)),
                Some(NostrError::EpochUnrecoverable)
            ),
            "a frozen group must NOT read as retryable — that is a repair loop that can \
             never succeed"
        );
        // `Stable` is not a refusal state; if one ever arrives it must not be
        // guessed at.
        assert!(epoch_state_rejection(&refusal("Stable")).is_none());

        for token in ["Removed", "Leaving"] {
            let err = SessionError::Engine(EngineError::InvalidTransition(InvalidTransition {
                from: token,
                to: "UpdateAppComponents",
                reason: "local group copy is marked removed (self-evicted)",
            }));
            assert!(
                epoch_state_rejection(&err).is_none(),
                "'{token}' is not an epoch state and must not read as retryable"
            );
        }

        // Nor may any other engine failure.
        let other = SessionError::Engine(EngineError::UnknownGroup(GroupId::new(vec![9; 32])));
        assert!(epoch_state_rejection(&other).is_none());
    }

    #[test]
    fn the_epoch_not_stable_error_names_no_state_and_no_group() {
        // It is surfaced to the user through `CircleError::Mls`, so its Display
        // must carry no group id, no epoch, and not even the state name — which
        // is engine bookkeeping the user cannot act on (Security Rule 8).
        for (error, expected) in [
            (
                NostrError::EpochNotStable,
                "the circle's group state is busy; try again shortly",
            ),
            (
                NostrError::EpochUnrecoverable,
                "the circle's group state cannot be repaired on this device",
            ),
        ] {
            let rendered = error.to_string();
            assert_eq!(rendered, expected);
            for needle in EPOCH_RETRYABLE_TOKENS
                .iter()
                .chain(std::iter::once(&EPOCH_UNRECOVERABLE_TOKEN))
            {
                assert!(
                    !rendered.contains(needle),
                    "the surfaced message must not name the epoch state"
                );
            }
        }
    }

    #[test]
    fn a_welcome_preview_carries_the_seal_author_as_canonical_hex() {
        let keys = Keys::generate();
        let sender = MemberId::new(keys.public_key().to_bytes().to_vec());
        assert_eq!(
            inviter_from_sender(Some(&sender)).expect("a real author previews"),
            keys.public_key().to_hex()
        );
    }

    #[test]
    fn a_welcome_with_no_usable_seal_author_is_refused_not_previewed_blank() {
        // The seal author is the ONLY thing a transient peel proves about an
        // invitation, and the anti-impersonation mitigation on the accept
        // screen is entirely that the user can check the inviter's npub
        // against what they were handed. `hex_to_npub("")` returns its own
        // input, so a blank author reached the FFI as a blank npub — an
        // unattributable request to share live location, rendered beside an
        // Accept button. A refusal the user can act on is the weaker failure.
        for unusable in [
            None,
            Some(MemberId::new(Vec::new())),
            Some(MemberId::new(vec![0xAB; 16])),
        ] {
            assert!(
                inviter_from_sender(unusable.as_ref()).is_err(),
                "{unusable:?} must not preview"
            );
        }
    }
    use cgka_traits::types::EpochId;
    use nostr::Tag;
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

    // ── admin-policy.v1 codec ────────────────────────────────────────────────
    //
    // Byte-level pins for `encode_admin_policy_v1`. The engine's `decode_admin_policy`
    // is `pub(crate)`, so these assert the wire shape directly; the cross-party
    // interop proof (a second session applying the resulting commit) lives in
    // `circle::manager::tests::admin_handoff_end_to_end` and
    // `tests/circle_integration_test.rs`.

    /// The session holds this account's identity key; its rendering names the
    /// engine handle and nothing about the account (Rule 15).
    #[test]
    fn session_manager_debug_redacts_the_identity_pubkey() {
        let dir = temp_dir();
        let keys = Keys::generate();
        let manager: SessionManager =
            SessionManager::new_unencrypted(&dir, &keys).expect("open session");
        crate::assert_debug_redacted!(
            manager,
            "SessionManager",
            &[
                &keys.public_key().to_hex(),
                &keys.secret_key().to_secret_hex(),
            ]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn admin_policy_encodes_length_prefixed_sorted_keys() {
        // Deliberately unsorted input: the decoder rejects unsorted or duplicated
        // keys, so the encoder must normalise rather than pass them through.
        let high = [0xFEu8; 32];
        let low = [0x01u8; 32];
        let encoded = encode_admin_policy_v1(&[high, low]).expect("encode two admins");
        // 64 bytes of payload fits a 2-byte QUIC varint (0x4040), then the keys
        // in ascending order.
        let mut expected = Vec::new();
        encode_quic_varint(64, &mut expected);
        expected.extend_from_slice(&low);
        expected.extend_from_slice(&high);
        assert_eq!(encoded, expected);
    }

    #[test]
    fn admin_policy_dedups_repeated_keys() {
        let key = [0x07u8; 32];
        let encoded = encode_admin_policy_v1(&[key, key, key]).expect("encode");
        let mut expected = Vec::new();
        encode_quic_varint(32, &mut expected);
        expected.extend_from_slice(&key);
        assert_eq!(
            encoded, expected,
            "a repeated admin must collapse to one entry — the decoder rejects duplicates"
        );
    }

    #[test]
    fn admin_policy_rejects_an_empty_admin_set() {
        // A group with no admins can never add, remove, or re-key again. This is
        // the encoder-level half of the fail-closed pair; the other half is
        // `CircleManager::propose_self_demote` refusing to drop the last admin.
        assert!(matches!(
            encode_admin_policy_v1(&[]),
            Err(NostrError::InvalidEvent(_))
        ));
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
        let rumor = location_rumor(other.public_key(), "{}".to_string());
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

    /// Content passes the gate VERBATIM, whether or not it parses as a
    /// `LocationMessage`: a peer on a newer content schema must still surface as
    /// a `Location` the caller advances past, not be re-classified by shape.
    #[test]
    fn location_result_from_message_received_extracts_inner_content() {
        let sender = MemberId::new(vec![0xAB; 32]);
        let inner = nostr::EventBuilder::new(Kind::Custom(KIND_LOCATION_UPDATE), r#"{"lat":1.5}"#)
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
                group_id: gid,
                invalidated_commit_id: MessageId::new(vec![1; 32]),
            })
            .is_none()
        );
    }

    // ── The inner-event kind: the send side ─────────────────────────────────

    #[test]
    fn the_location_rumor_is_minted_at_the_location_kind_and_never_the_chat_kind() {
        let rumor = location_rumor(Keys::generate().public_key(), "{}".to_string());
        assert_eq!(rumor.kind, Kind::Custom(KIND_LOCATION_UPDATE));
        assert_ne!(
            rumor.kind,
            Kind::Custom(LEGACY_KIND_LOCATION_UPDATE),
            "kind 9 is MARMOT_APP_EVENT_KIND_CHAT: a co-member's White Noise \
             would draw the coordinate as a chat bubble and push-notify it"
        );
    }

    #[test]
    fn the_location_rumor_carries_no_tags() {
        let rumor = location_rumor(Keys::generate().public_key(), "{}".to_string());
        assert!(rumor.tags.is_empty(), "unexpected tags: {:?}", rumor.tags);
    }

    #[test]
    fn the_location_rumor_is_stamped_with_the_senders_own_pubkey() {
        let sender = Keys::generate().public_key();
        assert_eq!(location_rumor(sender, "{}".to_string()).pubkey, sender);
    }

    // ── The inner-event kind: the receive gate ──────────────────────────────
    //
    // `location_result_from_event` folds every authenticated inner app message
    // into `Location`. What varies — and what these pin — is whether the inner
    // CONTENT is carried through, because content is what becomes a marker on
    // the map. A foreign kind must yield the variant with EMPTY content: the
    // caller still learns a message arrived at this position (so it advances
    // past it), gets no error to show a user, and gets nothing that can parse.

    /// The `MessageReceived` an engine emits once it has authenticated an inner
    /// rumor, carrying that rumor's JSON verbatim as the payload.
    fn message_received(rumor: &UnsignedEvent) -> GroupEvent {
        GroupEvent::MessageReceived {
            group_id: GroupId::new(vec![7, 7, 7]),
            sender: MemberId::new(vec![0xAB; 32]),
            epoch: EpochId(4),
            payload: rumor.as_json().into_bytes(),
        }
    }

    /// The folded `Location` content, asserting the variant on the way through.
    /// Every caller here also proves the fold produced a `Location` at all —
    /// a foreign kind must not collapse to `None`, which is how the planes
    /// spell "no message".
    fn folded_location_content(rumor: &UnsignedEvent) -> String {
        match SessionManager::location_result_from_event(&message_received(rumor)) {
            Some(LocationMessageResult::Location {
                sender_pubkey,
                content,
                group_id,
                epoch,
            }) => {
                // The caller's bookkeeping must survive the gate intact, or a
                // gated message would damage cursor/roster state on its way past.
                assert_eq!(sender_pubkey, hex::encode([0xABu8; 32]));
                assert_eq!(group_id, GroupId::new(vec![7, 7, 7]));
                assert_eq!(epoch, 4);
                content
            }
            other => panic!("expected a Location result, got {other:?}"),
        }
    }

    /// A real serialized `LocationMessage` — the exact shape that renders a
    /// member marker.
    fn location_payload() -> String {
        crate::location::LocationMessage::new(52.370_216, 4.895_168)
            .to_string()
            .expect("serialize location")
    }

    fn parses_as_a_marker(content: &str) -> bool {
        serde_json::from_str::<crate::location::LocationMessage>(content).is_ok()
    }

    #[test]
    fn a_location_update_rumor_is_folded_as_a_location() {
        let payload = location_payload();
        let rumor = location_rumor(Keys::generate().public_key(), payload.clone());
        let content = folded_location_content(&rumor);
        assert_eq!(content, payload);
        assert!(
            parses_as_a_marker(&content),
            "the whole point of the kind: this one must reach the map"
        );
    }

    #[test]
    fn a_pre_cutover_haven_rumor_is_still_folded_as_a_location() {
        // Exactly what v0.1.11 / v0.1.12 put in the tunnel: kind 9 WITH the
        // `["t","location"]` hashtag. Rejecting it would silently drop a
        // not-yet-updated circle member off every updated member's map.
        let payload = location_payload();
        let rumor =
            nostr::EventBuilder::new(Kind::Custom(LEGACY_KIND_LOCATION_UPDATE), payload.clone())
                .tags([Tag::hashtag("location")])
                .build(Keys::generate().public_key());
        let content = folded_location_content(&rumor);
        assert_eq!(content, payload);
        assert!(parses_as_a_marker(&content));
    }

    #[test]
    fn foreign_inner_events_never_carry_content_out_of_the_gate() {
        // Realistic co-member traffic in a shared Marmot group. The kind-9 row
        // is a White Noise chat message: same kind Haven used to send, no
        // hashtag, and its plaintext must not reach the caller either.
        let sender = Keys::generate().public_key();
        let cases = [
            (
                "White Noise chat message",
                nostr::EventBuilder::new(Kind::Custom(9), "hey").build(sender),
            ),
            (
                "reaction",
                nostr::EventBuilder::new(Kind::Custom(7), "+").build(sender),
            ),
            (
                "group system row",
                nostr::EventBuilder::new(Kind::Custom(1210), "{}").build(sender),
            ),
            (
                "a kind-9 chat message wearing an unrelated hashtag",
                nostr::EventBuilder::new(Kind::Custom(9), "hey")
                    .tags([Tag::hashtag("nostr")])
                    .build(sender),
            ),
        ];
        for (label, rumor) in cases {
            let content = folded_location_content(&rumor);
            assert!(
                content.is_empty(),
                "`{label}` must carry no content out of the gate, got {content:?}"
            );
        }
    }

    #[test]
    fn a_location_shaped_payload_under_a_foreign_kind_never_becomes_a_marker() {
        // THE regression the missing gate allowed. `LocationMessage` carries no
        // `deny_unknown_fields` (deliberately, for wire compatibility), so
        // before the gate ANY inner event whose content happened to deserialize
        // rendered as a member marker on the map.
        let payload = location_payload();
        assert!(
            parses_as_a_marker(&payload),
            "precondition: this payload really would render, or the assertions \
             below prove nothing"
        );
        let sender = Keys::generate().public_key();
        for kind in [7u16, 1210, 1, 25443] {
            let rumor = nostr::EventBuilder::new(Kind::Custom(kind), payload.clone()).build(sender);
            let content = folded_location_content(&rumor);
            assert!(
                content.is_empty() && !parses_as_a_marker(&content),
                "a location-shaped payload at kind {kind} must not reach the map"
            );
        }
        // Including under the legacy kind when the hashtag pairing is absent:
        // that combination is a White Noise chat message, not a Haven rumor.
        let untagged_legacy =
            nostr::EventBuilder::new(Kind::Custom(LEGACY_KIND_LOCATION_UPDATE), payload)
                .build(sender);
        assert!(folded_location_content(&untagged_legacy).is_empty());
    }

    #[test]
    fn a_foreign_kind_carrying_the_location_hashtag_is_not_a_location() {
        // The hashtag qualifies NOTHING on its own — it is only ever read in
        // conjunction with `LEGACY_KIND_LOCATION_UPDATE`. Read alone it would
        // restore the exact hole the kind gate closes: one sender-chosen tag
        // admitting any authenticated inner event to the map.
        let payload = location_payload();
        let sender = Keys::generate().public_key();
        for kind in [7u16, 1210, 25443] {
            let rumor = nostr::EventBuilder::new(Kind::Custom(kind), payload.clone())
                .tags([Tag::hashtag("location")])
                .build(sender);
            let content = folded_location_content(&rumor);
            assert!(
                content.is_empty() && !parses_as_a_marker(&content),
                "kind {kind} wearing `[\"t\",\"location\"]` must carry no content \
                 out of the gate, got {content:?}"
            );
        }
    }

    #[test]
    fn the_location_hashtag_must_be_a_t_tag() {
        // The pairing is the TAG `["t","location"]`, not the string "location"
        // in any tag's value slot. `e`/`p`/`r` values are references a sender
        // picks freely, so matching on the value alone would let a plain chat
        // message name itself through the gate.
        let payload = location_payload();
        let sender = Keys::generate().public_key();
        for name in ["e", "p", "r", "hashtag"] {
            let rumor = nostr::EventBuilder::new(
                Kind::Custom(LEGACY_KIND_LOCATION_UPDATE),
                payload.clone(),
            )
            .tags([Tag::parse([name, "location"]).expect("build tag")])
            .build(sender);
            let content = folded_location_content(&rumor);
            assert!(
                content.is_empty() && !parses_as_a_marker(&content),
                "`[\"{name}\",\"location\"]` is not the location hashtag, yet it \
                 carried content out of the gate: {content:?}"
            );
        }
    }

    #[test]
    fn a_chat_message_hashtagged_location_dies_at_the_location_message_parse() {
        // The legacy pair is forgeable: a Marmot client that lifts `#hashtags`
        // out of message content into `t` tags emits kind 9 + `["t","location"]`
        // for anyone who types "#location", and at the gate that is
        // indistinguishable from a pre-cutover Haven rumor. The kind gate is
        // therefore defense in depth on top of the `LocationMessage` parse, and
        // this pins the layer that actually stops prose.
        let rumor = nostr::EventBuilder::new(
            Kind::Custom(LEGACY_KIND_LOCATION_UPDATE),
            "on my way — will drop my #location when I get there",
        )
        .tags([Tag::hashtag("location")])
        .build(Keys::generate().public_key());
        let content = folded_location_content(&rumor);
        assert!(
            !content.is_empty(),
            "precondition: this pair really does pass the kind gate, or the \
             assertion below proves nothing about the second layer"
        );
        assert!(
            !parses_as_a_marker(&content),
            "a co-member's chat prose must never render as a marker: {content:?}"
        );
    }

    #[test]
    fn inner_location_content_is_empty_for_garbage() {
        assert_eq!(inner_location_content(b"not json"), "");
        assert_eq!(inner_location_content(br#"{"no_content":1}"#), "");
        // Well-formed JSON, no kind field at all: the gate must fail closed
        // rather than default the kind in.
        assert_eq!(inner_location_content(br#"{"content":"x"}"#), "");
        // A kind that is not a number, and a tags field that is not an array.
        assert_eq!(
            inner_location_content(br#"{"kind":"25442","content":"x"}"#),
            ""
        );
        assert_eq!(
            inner_location_content(br#"{"kind":9,"tags":"location","content":"x"}"#),
            ""
        );
    }

    // ── The pre-engine parse screen (`PreAuthRejection::Malformed`) ──────────
    //
    // These pin the CLASSIFICATION boundary at its source: exactly which inputs
    // `process_event` may screen out before the engine, and — just as
    // importantly — which it may not. The cursor consequences of each side are
    // asserted in the two planes (`relay::catchup`, `relay::live_sync`) and end
    // to end in `tests/cursor_poisoning_e2e.rs`.

    /// A signed `kind:445` routed at `h`, minted by a throwaway key that belongs
    /// to no member — what any observer of a circle's public `#h` can produce.
    fn signed_445(tags: Vec<Tag>, content: &str) -> Event {
        nostr::EventBuilder::new(Kind::Custom(445), content)
            .tags(tags)
            .sign_with_keys(&Keys::generate())
            .expect("sign 445")
    }

    fn h_tag(hex_value: &str) -> Tag {
        Tag::parse(["h", hex_value]).expect("h tag")
    }

    #[tokio::test]
    async fn a_duplicate_routing_tag_is_screened_as_malformed() {
        // The cheapest reachable shape, and the reason this classification
        // exists: `#h` matches an event carrying MORE than one `h` tag, so a
        // conformant relay delivers this to a victim subscribed on the first
        // one. The peeler DTO then refuses it ("exactly one h tag"), before the
        // engine and before any key material is touched.
        let (manager, dir) = open_manager();
        let ev = signed_445(
            vec![
                h_tag(&hex::encode([0xAAu8; 32])),
                h_tag(&hex::encode([0x11u8; 32])),
            ],
            "b3BhcXVl",
        );
        assert!(
            matches!(
                manager.process_event(&ev).await,
                Ok(ScreenedIngest::RejectedBeforeAuth(
                    PreAuthRejection::Malformed
                ))
            ),
            "an envelope the pure pre-engine parse cannot read is a \
             PRE-AUTHENTICATION rejection, not an un-applied message"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn every_pre_engine_parse_failure_is_screened_as_malformed() {
        // The full set the parse can reject, so a future peeler bump that adds
        // one is not silently split across the two classifications. Each of
        // these is an envelope-shape judgement: no ciphertext, no key material.
        let (manager, dir) = open_manager();
        let good_h = hex::encode([0xAAu8; 32]);
        let cases: Vec<(&str, Event)> = vec![
            ("no h tag at all", signed_445(vec![], "b3BhcXVl")),
            (
                "two h tags",
                signed_445(
                    vec![h_tag(&good_h), h_tag(&hex::encode([1u8; 32]))],
                    "b3BhcXVl",
                ),
            ),
            (
                "valueless h tag",
                signed_445(vec![Tag::parse(["h"]).expect("bare h")], "b3BhcXVl"),
            ),
            (
                "h tag of the wrong width",
                signed_445(vec![h_tag("abcd")], "b3BhcXVl"),
            ),
            (
                "h tag that is not hex",
                signed_445(vec![h_tag(&"z".repeat(64))], "b3BhcXVl"),
            ),
            (
                // The INNER location kind, worn as an OUTER event kind: the
                // transport carries 445 (and the gift wrap), nothing else, so a
                // rumor kind escaping onto a relay is screened before the engine.
                "a kind the transport does not carry",
                nostr::EventBuilder::new(Kind::Custom(KIND_LOCATION_UPDATE), "hi")
                    .tags(vec![h_tag(&good_h)])
                    .sign_with_keys(&Keys::generate())
                    .expect("sign the inner kind as an outer event"),
            ),
        ];
        for (label, ev) in cases {
            assert!(
                SessionManager::event_to_transport_message(&ev).is_err(),
                "precondition: `{label}` must really fail the pre-engine parse, \
                 or the assertion below proves nothing",
            );
            assert!(
                matches!(
                    manager.process_event(&ev).await,
                    Ok(ScreenedIngest::RejectedBeforeAuth(
                        PreAuthRejection::Malformed
                    ))
                ),
                "`{label}` must be screened as Malformed",
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_parseable_envelope_reaches_the_engine_and_is_never_screened() {
        // THE BOUNDARY, at its source: the screen is a function of the ENVELOPE
        // alone. This event's `content` is not base64 — garbage to the engine —
        // but the pre-engine parse never looks at `content`, so nothing here may
        // be screened. Whatever the engine then makes of it is an engine
        // disposition, and the cursor planes must keep holding on it.
        //
        // This session holds no groups, so the engine answers "not mine" rather
        // than erroring; the ERROR half of the boundary needs a real group and
        // is pinned end to end, at the cursor, by
        // `tests/cursor_poisoning_e2e.rs::{livesync,catchup}_an_engine_side_failure_*`.
        let (manager, dir) = open_manager();
        let ev = signed_445(
            vec![h_tag(&hex::encode([0xAAu8; 32]))],
            "!!!!not-base64!!!!",
        );
        assert!(
            SessionManager::event_to_transport_message(&ev).is_ok(),
            "precondition: the ENVELOPE is well-formed — only its content is \
             junk — so any failure this event produces is the engine's"
        );
        assert!(
            matches!(
                manager.process_event(&ev).await,
                Ok(ScreenedIngest::Ingested(_))
            ),
            "a parseable envelope must reach the engine: only the pre-engine \
             parse and the expiration screen may reject before authentication"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
