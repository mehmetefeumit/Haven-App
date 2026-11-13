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
//! Every commit and proposal the engine stages is given a durable MDK fanout
//! record in the session-lock hold that staged it (the `*_staging` entries),
//! and only the fanout driver (`relay/fanout.rs`) sends it, confirms it on a
//! relay's acknowledgement and rolls it back when every relay proved it
//! refused it.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use nostr::{Event, JsonUtil, Keys, Kind, PublicKey, RelayUrl, Timestamp, UnsignedEvent};
use rand::rngs::OsRng;
use rand::RngCore;
use tokio::sync::Mutex;

use cgka_engine::canonicalization::CanonicalizationPolicy;
use cgka_engine::feature_registry::FeatureRegistry;
use cgka_engine::openmls_projection::{project_mls_message, OpenMlsContentKind};
use cgka_session::{
    AccountDeviceSession, CreateGroupEffects, IngestEffects, QueuedIntentRef, SessionConfig,
    SessionEffects, SessionError,
};
use cgka_traits::app_components::{
    default_group_components, encode_nostr_routing_v1, encode_quic_varint, AppComponentData,
    AppComponentId, NostrRoutingV1, GROUP_ADMIN_POLICY_COMPONENT_ID,
    GROUP_MESSAGE_RETENTION_COMPONENT_ID, NOSTR_ROUTING_COMPONENT_ID,
};
use cgka_traits::capabilities::{Capability, CapabilityRequirement, Feature, RequirementLevel};
use cgka_traits::engine::{
    CreateGroupRequest, GroupEvent, GroupStateChange, GroupStateInvalidationReason, KeyPackage,
    SendIntent,
};
use cgka_traits::engine_state::EpochState;
use cgka_traits::engine_state::PendingStateRef;
use cgka_traits::error::EngineError;
use cgka_traits::error::PeelerError;
use cgka_traits::group::{Group, Member, ProtocolProfile};
use cgka_traits::maintenance::{
    GroupEvolutionPhase, GroupEvolutionSemantic, KeyPackageLifecycleState, MaintenanceObligation,
    MaintenancePhase, MaintenanceTrigger, PeriodicMaintenancePolicy, SignedPublicationArtifact,
    TransportFanoutAttemptState, TransportFanoutTarget, POST_JOIN_CONTENTION_JITTER_MAX_MS,
};
use cgka_traits::message::{MessageRecord, MessageState, StoredMessagePayload};
use cgka_traits::peeler::TransportPeeler;
use cgka_traits::storage::{
    ConvergencePassStorage, GroupStorage, KeyPackageBundleStorage, MaintenanceStorage,
    MessageStorage, OutboundFanoutStorage, OutboundIntentStorage, StorageError, StorageResult,
};
use cgka_traits::transport::TransportEnvelope;
use cgka_traits::transport_adapter::{
    FanoutMlsState, FanoutPendingKind, FanoutTargetStatus, OutboundApplicationMessage,
    OutboundFanout, TransportEndpoint, TransportPublishRequest, TransportPublishTarget,
};
use cgka_traits::types::{EpochId, GroupId, MemberId, MessageId};
use storage_sqlite::{
    SqlCipherKey, SqliteAccountStorage, SqliteStorageOptions, TransportReconciliationItem,
    TransportReconciliationRoute,
};
use transport_nostr_peeler::{NostrMlsPeeler, NostrPeelerError, NostrTransportEvent};

use super::commit_notes::{
    ChangeNote, ChangeNotice, CommitNotes, InMemoryCommitNotes, KeptTarget, RestageWait,
};
use super::engine_gate::{Engine, Gated, Held, Reading};
use super::epoch_stall::{BackfillDecision, EpochStallDetector, NoStallEvidence, StallEvidence};
use super::kept_input::{KeptEvent, KEPT_BYTES_PER_CIRCLE, KEPT_EVENTS_PER_CIRCLE};
use super::retention::RetentionBoundPeeler;
use super::signer::HavenIdentityProofSigner;
use super::storage::{LiveSessionGuard, StorageConfig};
// Only the two outbound-forging test seams below reach these; gated so a plain
// build does not carry the imports as dead weight.
#[cfg(any(test, feature = "test-utils"))]
use super::types::FanoutProbe;
#[cfg(any(test, feature = "test-utils"))]
use super::types::StoredMessageProbe;
#[cfg(any(test, feature = "test-utils"))]
use super::types::WelcomeRecordProbe;
use super::types::{
    beyond_relay_retention, AppliedCommit, ConvergedRoster, ConvergenceSweep, FanoutId,
    FanoutSettlement, FanoutStanding, FoundingWelcome, KeyPackageAdmission,
    KeyPackageAdmissionRule, LeftGroup, LocationGroupConfig, LocationMessageResult, OwedJoin,
    OwedReinvite, PreAuthRejection, ReinviteRefusal, ReinviteReservation, ReinviteStanding,
    RejoinConfirmation, RejoinOffer, ScreenedIngest, Staged, StoredFanout, WelcomeAcceptance,
    WelcomeEnd, WelcomeFate, WelcomeHandOver, WelcomeRecord, WithdrawnChange, WithdrawnKind,
    WithdrawnOutcome, WELCOME_RECORD_BOUND_SECS,
};
use super::welcome::WelcomePreview;
use crate::log_alias::bucket;
use crate::nostr::error::{NostrError, Result};
use crate::nostr::event::{KIND_GROUP_MESSAGE, KIND_LOCATION_UPDATE};
use crate::relay::fanout::{DriveMode, Still};
use crate::relay::maintenance::KIND_MARMOT_KEY_PACKAGE;
use cgka_session::PublishWork;
use cgka_traits::group_context::GroupContextSnapshot;
use cgka_traits::ingest::PeeledContent;
use cgka_traits::ingest::{IngestOutcome, LocalIngestState};
#[cfg(any(test, feature = "test-utils"))]
use cgka_traits::peeler::GroupMessageMetadata;
#[cfg(any(test, feature = "test-utils"))]
use cgka_traits::transport::EncryptedPayload;

mod mesh;

use self::mesh::MeshKeys;
pub use self::mesh::{MeshDrive, MeshKeyStore, MeshPacket, StoredMeshKey, MESH_ON_MAX_MS};

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

/// A fixed, Haven-renderable code for an MDK error value.
///
/// MDK's `Display` prints full group-id and member hex and absolute epochs
/// (`ForkedEpoch`, `AppMessageEpochMismatch`, `PeelerError::StaleEpoch`, …), so
/// no MDK error's text crosses this boundary at all: only the code does
/// (Security Rules 8 and 15; tracker T-DISPLAY).
trait MdkErrorKind {
    fn kind(&self) -> &'static str;
}

impl MdkErrorKind for EngineError {
    /// MDK's own `privacy_safe_kind` (`traits/src/error.rs:252-289`), unwrapped
    /// one layer further for storage, as MDK's app runtime does, so a busy
    /// database stays distinguishable from a durable fault.
    fn kind(&self) -> &'static str {
        match self {
            Self::Storage(e) => e.kind(),
            other => other.privacy_safe_kind(),
        }
    }
}

impl MdkErrorKind for StorageError {
    /// `StorageError` has no `privacy_safe_kind` upstream (tracker
    /// T-STORAGE-KIND), so Haven names its variants itself.
    fn kind(&self) -> &'static str {
        match self {
            Self::NotFound => "storage_not_found",
            Self::AlreadyExists => "storage_already_exists",
            Self::SnapshotMissing(_) => "storage_snapshot_missing",
            Self::TimelineCursorExpired => "storage_timeline_cursor_expired",
            Self::Busy(_) => "storage_busy",
            Self::Corruption(_) => "storage_corruption",
            Self::Capacity(_) => "storage_capacity",
            Self::Closed(_) => "storage_closed",
            Self::UnsupportedSchemaVersion { .. } => "storage_unsupported_schema_version",
            Self::Backend(_) => "storage_backend",
            Self::Serialization(_) => "storage_serialization",
        }
    }
}

impl MdkErrorKind for SessionError {
    fn kind(&self) -> &'static str {
        match self {
            Self::Engine(e) => e.kind(),
            Self::Storage(e) => e.kind(),
        }
    }
}

impl MdkErrorKind for PeelerError {
    fn kind(&self) -> &'static str {
        "peeler"
    }
}

impl MdkErrorKind for NostrPeelerError {
    fn kind(&self) -> &'static str {
        "peeler"
    }
}

/// The `KeyPackage` kind builds before the addressable 30443 cutover published;
/// a peer still advertising it must update before it can be invited.
const KIND_PRE_MIGRATION_KEY_PACKAGE: u16 = 443;

/// What MDK is told about when a staged package should be refreshed: a quarter
/// of the maximum `KeyPackage` lifetime before `not_after`
/// (`foundation/key-packages.md:77-80`), the point Haven's own rotation rule
/// reads off the package (`relay::maintenance::KP_ROTATE_AT_LIFETIME_FRACTION`).
/// Haven schedules from the package, never from this stored value.
const KEY_PACKAGE_REFRESH_LEAD_SECS: u64 = 7_261_200 / 4;

/// The `KeyPackage` this device tracks: Haven's view of MDK's durable
/// lifecycle record (`KeyPackageLifecycleState`, v0.10.4
/// `traits/src/maintenance.rs:267-302`).
///
/// `Debug` is hand-written: the slot and the events are identifiers and the
/// package is MLS wire material (Security Rules 6 and 15).
#[derive(Clone, PartialEq, Eq)]
pub struct TrackedKeyPackage {
    /// The stable NIP-33 `d` slot.
    pub slot: String,
    /// The signed kind-30443 a relay last acknowledged for the current
    /// package, exactly as published: a heal republishes these bytes.
    pub published: Option<Event>,
    /// `created_at` of the newest event known in the slot; the next one is
    /// stamped after it.
    pub created_at: Option<u64>,
    /// The current package's wire bytes; empty when none is held.
    pub package: Vec<u8>,
    /// A staged replacement no relay has acknowledged yet: its exact signed
    /// event, republished verbatim until one does.
    pub pending: Option<Event>,
    /// The slot was adopted from the relays and this device has had nothing
    /// acknowledged into it.
    pub adopted: bool,
    /// A Welcome consumed the current package, or its private bundle is no
    /// longer held: a replacement is owed
    /// (`foundation/key-packages.md:86-87`).
    pub replacement_owed: bool,
    /// The replacement is owed only because a Welcome consumed the package:
    /// its private bundle is still held, so it can still open another Welcome
    /// made for it — which is why its replacement may wait for an invitation
    /// the user has not answered yet.
    pub consumed_but_held: bool,
}

impl std::fmt::Debug for TrackedKeyPackage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TrackedKeyPackage")
            .field("slot", &"<redacted>")
            .field("published", &self.published.is_some())
            .field("package", &!self.package.is_empty())
            .field("pending", &self.pending.is_some())
            .field("adopted", &self.adopted)
            .field("replacement_owed", &self.replacement_owed)
            .field("consumed_but_held", &self.consumed_but_held)
            .finish_non_exhaustive()
    }
}

/// The exact signed event a lifecycle record froze, verified, or `None` when
/// the stored bytes are not one.
fn frozen_event(artifact: &SignedPublicationArtifact) -> Option<Event> {
    serde_json::from_slice::<NostrTransportEvent>(&artifact.bytes)
        .ok()?
        .to_verified_nostr_event()
        .ok()
}

/// Deletes the private bundle of the `KeyPackage` named by `key_package_ref`
/// through the second storage handle, and reports whether one was held.
///
/// MDK's own deletes (`delete_key_package`, `promote_key_package_lifecycle`)
/// validate the package's lifetime first, so they refuse the one package the
/// `not_after` bound exists to delete. A bundle's storage key embeds the
/// serde encoding of its ref (`storage-sqlite/src/openmls_storage/provider.rs`
/// `write_key_package`, `labels.rs` `build_key`), which is how it is found.
/// MDK's only listing returns each bundle's value with its key
/// (`storage-sqlite/src/openmls_storage.rs:40-66`), so every stored bundle is
/// loaded to find one; only the storage keys are read here.
fn delete_key_package_bundle(
    store: &SqliteAccountStorage,
    key_package_ref: &[u8],
) -> StorageResult<bool> {
    let needle = serde_json::to_vec(&serde_json::json!({ "value": { "vec": key_package_ref } }))
        .map_err(|_| StorageError::Backend("key package ref".to_owned()))?;
    let mut deleted = false;
    for bundle in store.stored_key_package_bundles()? {
        if bundle
            .storage_key
            .windows(needle.len())
            .any(|window| window == needle)
        {
            store.delete_stored_key_package_bundle(&bundle.storage_key)?;
            deleted = true;
        }
    }
    Ok(deleted)
}

/// Maps any engine/session/peeler error into Haven's MLS-error bucket, keeping
/// the fixed code and nothing else.
#[allow(clippy::needless_pass_by_value)] // by value so it can be a `map_err` argument
fn map_mls_err<E: MdkErrorKind>(e: E) -> NostrError {
    NostrError::MdkError(e.kind())
}

/// How a commit-staging send reads the group's epoch state, or `None` when the
/// group will accept a staged commit (or is unknown, which the send itself
/// then reports).
///
/// Read through MDK's typed `AccountDeviceSession::epoch_state` getter
/// (v0.10.4 `cgka-session/src/lib.rs:1281`) under the same session lock as the
/// send, so no refusal is ever classified from an error's text or tokens. Two
/// outcomes, because they need opposite handling: a busy group settles on its
/// own and invites a retry, a frozen or disbanded one never does.
const fn epoch_state_refusal(state: Option<&EpochState>) -> Option<NostrError> {
    match state {
        None | Some(EpochState::Stable { .. }) => None,
        Some(
            EpochState::PendingPublish(_) | EpochState::Merging(_) | EpochState::Recovering(_),
        ) => Some(NostrError::EpochNotStable),
        Some(EpochState::Unrecoverable(_) | EpochState::Disbanded(_)) => {
            Some(NostrError::EpochUnrecoverable)
        }
    }
}

/// What one ingest answer tells the epoch-stall detector.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StallInput {
    /// A deferral, of either lineage: MDK's app feeds both, because a fork
    /// that never resolves is the wedge that most needs reporting
    /// (`marmot-app/src/client/sync.rs` 2840-2852).
    Undecryptable,
    /// A want of room: direct evidence history was not retained.
    Refused,
    /// No evidence, only where the circle now stands.
    Landing,
}

/// The circle an ingest answer names and what it tells the detector; `None`
/// for an answer that names no circle.
const fn stall_input(outcome: &IngestOutcome) -> Option<(&GroupId, StallInput)> {
    match outcome {
        IngestOutcome::TransportDeferred { group_id, .. } => {
            Some((group_id, StallInput::Undecryptable))
        }
        IngestOutcome::ResourceRefused { group_id, .. } => Some((group_id, StallInput::Refused)),
        IngestOutcome::Buffered { group_id, .. } => Some((group_id, StallInput::Landing)),
        _ => None,
    }
}

/// MDK's account crate's grace after a circle's end of stored events
/// before its post-join self-update (`MAINTENANCE_POST_EOSE_GRACE_SECS`,
/// `marmot-account/src/runtime.rs` 65-67).
pub const POST_JOIN_GRACE_MS: u64 = 15_000;

/// MDK's account crate's quiet window before a post-join self-update, which
/// any epoch change or accepted proposal restarts, and so does the
/// obligation's re-arm (`MAINTENANCE_QUIET_SECS`).
pub const POST_JOIN_QUIET_MS: u64 = 60_000;

/// The least gap between two post-join self-updates of one session: the
/// publish stagger's floor, so no two circles' commits share a second.
pub const POST_JOIN_SPACING_MIN_MS: u64 = 2_000;

/// The greatest such gap: wider than a location burst's, for a commit that
/// is a one-off per circle.
pub const POST_JOIN_SPACING_MAX_MS: u64 = 30_000;

/// The earliest instant a circle's post-join self-update may be made, as
/// MDK's account crate times it (`marmot-account/src/runtime.rs` 1404-1449,
/// 1662-1722): the quiet window runs from the later of the grace's end and
/// the last state-bearing input, then the sampled jitter, capped at MDK's
/// contention bound; never before `spaced_until`. All on one clock.
#[must_use]
pub const fn post_join_not_before(
    caught_up_at: u64,
    state_input_at: Option<u64>,
    sampled_jitter_ms: u64,
    spaced_until: Option<u64>,
) -> u64 {
    let grace_end = caught_up_at.saturating_add(POST_JOIN_GRACE_MS);
    let quiet_from = match state_input_at {
        Some(at) if at > grace_end => at,
        _ => grace_end,
    };
    let jitter = if sampled_jitter_ms < POST_JOIN_CONTENTION_JITTER_MAX_MS {
        sampled_jitter_ms
    } else {
        POST_JOIN_CONTENTION_JITTER_MAX_MS
    };
    let at = quiet_from
        .saturating_add(POST_JOIN_QUIET_MS)
        .saturating_add(jitter);
    match spaced_until {
        Some(spaced) if spaced > at => spaced,
        _ => at,
    }
}

/// How many epochs past the group's tip an application message may be sealed
/// under and still be accepted (Rule 5).
///
/// Reads MDK's pinned convergence policy v1, which is the only policy a
/// session opens with (`CanonicalizationPolicy::ensure_acceptable`, MDK
/// `cgka-engine/src/canonicalization.rs:117-128`), so a gate pinning this bound
/// cannot pass while the engine runs a different one.
#[must_use]
pub fn app_message_past_epoch_limit() -> u64 {
    CanonicalizationPolicy::default().app_message_past_epoch_limit
}

/// How far below its tip a group rewinds to converge a sibling branch.
///
/// The session-wide value, which is what a group with no stored per-group
/// override runs under — and, at MDK v0.10.4, what every group runs under: a
/// stored per-group policy is accepted only when it equals the pinned v1
/// (`accept_convergence_policy`, MDK `distributed_convergence.rs:329-348`).
/// Public for the same reason
/// [`app_message_past_epoch_limit`] is: a caller outside this module that has
/// to know how many commits exhaust the rewind horizon must READ the policy the
/// session installs, because a restated literal is a second copy that drifts.
#[must_use]
pub fn max_rewind_commits() -> u64 {
    CanonicalizationPolicy::default()
        .convergence
        .max_rewind_commits
}

/// Where the live plane that shares a session stands, as it last said
/// (`SessionManager::plane_stands`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlaneStanding {
    /// No live plane, or one that has ended.
    Gone = 0,
    /// Started, and claimed for by nobody: a foreground launch before its
    /// claim, or a background wake that cold-launched the process.
    Launched = 1,
    /// A claimed foreground.
    Foreground = 2,
    /// A background burst or a pause: the plane makes no commit.
    MakesNone = 3,
}

/// What holds a circle's sends (`SessionManager::held_away`): a relay
/// change holds every call but a claimed foreground's, the others every call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AwayHold {
    /// A change of the circle's relays was applied away from the foreground
    /// ([`ChangeNote::AwaitsForeground`]).
    RelayChange,
    /// A removal the user asked for was set aside or dropped unmade, and a
    /// member it named is still listed ([`ChangeNote::QueuedRemovalDropped`]).
    /// Holds every call, a claimed foreground's included.
    RemovalUnmade,
    /// This device asked to leave the circle ([`SessionManager::leaving`]).
    /// Holds every call, a claimed foreground's included.
    Leaving,
    /// The circle's routing id is another local circle's too
    /// ([`ChangeNote::RoutingCollision`]). Holds every call, a claimed
    /// foreground's included.
    RoutingCollision,
}

/// The routing id a group message is carried under, or `None` for a
/// Welcome or a routing tag that is not 32 bytes.
fn transport_route(msg: &cgka_traits::transport::TransportMessage) -> Option<[u8; 32]> {
    match &msg.envelope {
        TransportEnvelope::GroupMessage { transport_group_id } => {
            transport_group_id.as_slice().try_into().ok()
        }
        TransportEnvelope::Welcome { .. } => None,
    }
}

/// What a stored `kind:445` is at its circle's current epoch, read only to
/// order a batch for ingest ([`SessionManager::order_for_ingest`]).
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum IngestClass {
    /// A proposal at the current epoch.
    Proposal,
    /// A commit at the current epoch.
    Commit,
    /// Anything else, or what did not peel or parse.
    Other,
}

/// An event whose content is this makes [`SessionManager::order_for_ingest`]'s
/// classification panic.
#[cfg(any(test, feature = "test-utils"))]
pub const ORDER_PANIC_FOR_TEST: &str = "__order_panic_for_test__";

/// Manager for MLS session operations over the Dark Matter engine.
///
/// Wraps a single, hydrated [`AccountDeviceSession`] behind a `tokio` mutex and
/// exposes Haven's group-lifecycle + message surface. Constructed with the
/// device's Nostr identity keys, which bind the session's account identity, its
/// NIP-59 welcome signer, and its hardened account-identity-proof signer.
pub struct SessionManager {
    /// The single live engine session, behind its lock and the gate that
    /// alone hands it out mutably ([`Self::engine`]). Rule 14: one per DB
    /// file, ever.
    session: Gated<AccountDeviceSession>,
    /// The groups this session held live when it opened, or `None` when the
    /// engine could not list them: the only candidates the orphan sweep may
    /// forget, so a group made after the open is never one of them.
    groups_at_open: Option<Vec<GroupId>>,
    /// The circles holding fetched input not yet taken in, which no location
    /// is sealed for meanwhile ([`Self::holds_unread_input`]).
    unread_input: std::sync::Mutex<UnreadInput>,
    /// What the NIP-77 pass keeps for the life of the process, never sent
    /// ([`crate::relay::negentropy::NegMemo`]).
    negentropy: std::sync::Mutex<crate::relay::negentropy::NegMemo>,
    /// The mesh packet keys of each circle and the hand-off they fill, kept
    /// only while mesh is on ([`Self::mesh_on_until`]).
    mesh_keys: MeshKeys,
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
    /// A second `storage-sqlite` handle on the SAME `session.sqlite`, for what
    /// MDK has no session API for: each use is a row of
    /// `docs/MDK_UPSTREAM_TRACKER.md` T-SECOND-HANDLE — the stuck-input sweep
    /// ([`Self::sweep_unresolvable_inputs`]), the queued-intent discard
    /// ([`Self::discard_queued_location_intents`]), commit retirement, the
    /// expired `KeyPackage` bundle, application outputs, the pass before the
    /// open, a lost Welcome's end, the stranded hand-back, and the reads MDK
    /// keeps behind a command. The method names it may call are pinned by
    /// `the_sweeps_second_connection_touches_only_message_shaped_storage`.
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
    /// touches message records, the pending-output table, the outbound-intent
    /// queue and the stored `KeyPackage` bundles, to delete the one whose
    /// lifetime has ended ([`delete_key_package_bundle`]). Finding it loads
    /// every stored bundle, the live one's private keys included, because MDK
    /// has no delete-by-ref and no keys-only listing; the values sit in
    /// `Zeroizing` buffers, are never inspected and are dropped at once. It
    /// never reads or writes group state or ratchet state. Every write is
    /// taken while the [`Self::session`] mutex is held, so no engine statement
    /// is ever in flight against it on the other connection
    /// (`every_second_handle_write_runs_with_the_engine_held`). Four reads run
    /// beside the engine on a WAL snapshot — [`Self::leave_proposed`],
    /// [`Self::leave_proposed_epoch`], `engine_processed` (which
    /// [`Self::holds_unread_input`] also reads) and [`Self::leave_requested`] —
    /// which can be one write stale and each read fails safe. `storage-sqlite`
    /// opens WAL with a 5 s `busy_timeout`, which makes even an unexpected
    /// overlap a wait rather than a failure.
    message_store: SqliteAccountStorage,
    /// Runtime Rule-14 enforcement: registers this session's `session.sqlite`
    /// path in a process-global set at open and releases it on drop, so a
    /// second `AccountDeviceSession::open` on the same DB file (e.g. a
    /// background isolate) fails closed instead of hydrating a divergent epoch
    /// state. Held for the session's lifetime; never read after construction.
    _live_guard: LiveSessionGuard,
    /// Whether this session still owes the once-per-open recovery of what
    /// the engine handed back at the open ([`Self::take_open_recovery`]).
    open_recovery_owed: AtomicBool,
    /// The groups the engine named as owing an advance, from every batch
    /// Haven received since a plane last drained them
    /// ([`Self::take_owed_advance`]): MDK's host scheduler's pending set.
    owed_advance: std::sync::Mutex<Vec<GroupId>>,
    /// How many advances each group was given (tests only).
    #[cfg(any(test, feature = "test-utils"))]
    advances: std::sync::Mutex<HashMap<GroupId, usize>>,
    /// How many times the engine was asked for a self-update (tests only).
    #[cfg(any(test, feature = "test-utils"))]
    self_update_asks: std::sync::atomic::AtomicUsize,
    /// How many times the epoch-stall detector armed a walk (tests only).
    #[cfg(any(test, feature = "test-utils"))]
    stall_arms: std::sync::atomic::AtomicUsize,
    /// Groups whose eviction of a member who left was rolled back, keyed to the
    /// epoch of the rollback: [`Self::receive_retick_after`] does not wait on
    /// their re-armed eviction until the epoch moves. MDK v0.10.4 re-arms an
    /// eviction after a rollback; re-staging it inside the
    /// same receive pass would retry at jitter cadence against the relays (or
    /// the missing circle row) that just refused it. The next advance stages it.
    eviction_retick_hold: std::sync::Mutex<HashMap<GroupId, EpochId>>,
    /// Event ids of transport objects the engine deferred and then retired for
    /// a local resource bound (`GroupEvent::TransportObjectResourceRefused`),
    /// per group, until the catch-up sweep refetches them by id — see
    /// [`Self::refused_redeliveries`]. Durable once a `CircleManager` installs
    /// its store ([`Self::install_refused_ledger`]).
    refused_ledger: Arc<dyn RefusedRedeliveryLedger>,
    /// What is kept per circle about a commit under a durable fanout — see
    /// [`CommitNotes`]. Durable when the session was opened over a
    /// `CircleManager`'s store.
    commit_notes: Arc<dyn CommitNotes>,
    /// One `KeyPackage` maintenance tick at a time — see
    /// [`Self::key_package_tick`].
    key_package_tick: Mutex<()>,
    /// Commits a plain rollback rewound whose own stored row could not be
    /// retired, and so has no rolled-back fanout row to say so: retired
    /// before the engine is next handed over ([`Self::engine`]).
    unretired: std::sync::Mutex<Vec<MessageId>>,
    /// The open could not read which commits it cleared: read again before
    /// the engine is next handed over ([`Self::finish_rollbacks`]).
    cleared_unread: AtomicBool,
    /// Commits staged in staging mode that could be neither recorded nor
    /// rolled back in their hold: nothing was sent, so the rollback is tried
    /// again at the next staging hold ([`Self::retry_unrecorded`]).
    unrecorded: std::sync::Mutex<Vec<PendingStateRef>>,
    /// Members whose directory rows the circle layer is to delete
    /// ([`Self::take_dropped_removals`]): their queued removal was retired
    /// as moot, or the driver confirmed the commit that removed them.
    dropped_removals: std::sync::Mutex<Vec<String>>,
    /// The circles the last look found holding stranded input that may be
    /// taken over ([`Self::look_for_stranded`]): what the next ingest or
    /// advance hands back to the engine first. An index of what the store
    /// says, rebuilt at every open; never the record of it.
    holding_stranded: std::sync::Mutex<Vec<GroupId>>,
    /// The circles this session has caught up with ([`Self::caught_up`]).
    caught_up: std::sync::Mutex<HashSet<GroupId>>,
    /// The epoch-stall detector (`docs/MDK_UPSTREAM_TRACKER.md`
    /// T-EPOCH-STALL), on [`Self::legacy_now_ms`]: when a circle has fallen
    /// behind its group, and when the history walks meant to bring it back
    /// are not working.
    epoch_stall: std::sync::Mutex<EpochStallDetector>,
    /// Where the detector's frozen-epoch evidence outlives the process.
    stall_evidence: Arc<dyn StallEvidence>,
    /// An arm owed a refetch since the live plane last asked.
    stall_armed: AtomicBool,
    /// The circles whose self-update the open cleared and nobody asked for
    /// ([`settle_fanouts_before_open`]): the hydrate's clear is not told to
    /// the user as an undone change.
    unasked_clears: std::sync::Mutex<HashSet<GroupId>>,
    /// When each circle was first caught up in this session, on
    /// [`Self::legacy_now_ms`]: where its post-join grace starts. A later
    /// fetch answered to the end does not restart it, as a second end of
    /// stored events does not restart MDK's.
    caught_up_since: std::sync::Mutex<HashMap<GroupId, u64>>,
    /// When each circle last took in state-bearing input — an epoch change
    /// or a proposal the engine accepted — on [`Self::legacy_now_ms`]: where
    /// its post-join quiet window starts again.
    state_input_at: std::sync::Mutex<HashMap<GroupId, u64>>,
    /// The earliest instant, on [`Self::legacy_now_ms`], at which this
    /// session makes its next post-join self-update: the last one's instant
    /// plus a CSPRNG gap, so no two circles' commits share a second.
    post_join_spaced_until: std::sync::Mutex<Option<u64>>,
    /// Bumped at each [`Self::mark_caught_up`], for a test to await.
    #[cfg(any(test, feature = "test-utils"))]
    caught_up_marks: tokio::sync::watch::Sender<u64>,
    /// A test's word that this session asks for its removals set aside again,
    /// as [`REQUEUE_SET_ASIDE_REMOVALS`] would ([`Self::requeue_for_test`]).
    #[cfg(any(test, feature = "test-utils"))]
    requeues_for_test: AtomicBool,
    /// What the engine handed over for stranded input in a call that then
    /// failed: put ahead of the next batch that comes back
    /// ([`Self::behind_what_was_handed_back`]).
    handed_back: std::sync::Mutex<Option<SessionEffects>>,
    /// The locations this session sealed and recorded
    /// ([`Self::record_location`]), by transport id, each with whether it was
    /// sealed for the mesh alone: a record that is not one of them was left
    /// by a process that died with its send unfinished.
    own_locations: std::sync::Mutex<HashMap<MessageId, bool>>,
    /// What the live plane that shares this session last said of itself,
    /// and which plane said it ([`Self::plane_stands`]): the plane's number
    /// shifted up two, its [`PlaneStanding`] in the low bits.
    live_plane: AtomicU64,
    /// When the live plane's current background burst ends, as its opener
    /// measured it ([`Self::burst_ends`]); `None` outside a burst and for
    /// a burst given no budget.
    burst_end: std::sync::Mutex<Option<crate::relay::fanout::BurstEnd>>,
    /// Bridge calls in flight that their caller said are the app's in front
    /// of its user, in a process with no live plane ([`Self::count_bridge_claim`]).
    bridge_claims: AtomicU64,
    /// The stranded events the engine was handed, or could not be handed,
    /// since the last look and that are still Haven's or the engine's
    /// unopened: none is tried again before the next look — an open, a
    /// confirm or rollback, a change of its circle's epoch.
    tried: std::sync::Mutex<HashSet<MessageId>>,
    /// The circles a redelivery has had told since the last look
    /// ([`Self::holds_stranded`]): a relay can serve a stranded event again
    /// without number, and each circle is scanned for it once.
    told_at_redelivery: std::sync::Mutex<HashSet<GroupId>>,
    /// What looking for stranded input has cost, for a test to read.
    examined: Examined,
    /// Where the hand-back of stranded input ends as a process death would
    /// end it, after how many more passes of that point — and, once it has,
    /// that it has: `None` for the point.
    #[cfg(any(test, feature = "test-utils"))]
    hand_back_stop: std::sync::Mutex<Option<(Option<HandBackStop>, usize)>>,
    /// What runs once, inside the next hand-back: something that happens
    /// while a call waits there ([`Self::during_next_hand_back_for_test`]).
    #[cfg(any(test, feature = "test-utils"))]
    during_hand_back: std::sync::Mutex<Option<Box<dyn FnOnce() + Send>>>,
    /// The store reads and writes a test has failing
    /// ([`Self::fail_store_for_test`]).
    #[cfg(any(test, feature = "test-utils"))]
    store_faults: std::sync::Mutex<Vec<StoreFault>>,
    /// How many rows [`proposal_stands`] reads, as a test sets it
    /// ([`Self::cap_proposal_scan_for_test`]).
    #[cfg(any(test, feature = "test-utils"))]
    proposal_scan_cap: std::sync::atomic::AtomicUsize,
    /// Errors the next full advances of a plane that drives fail with AFTER
    /// the engine ran them: what a failure past the engine's own staging
    /// leaves.
    #[cfg(any(test, feature = "test-utils"))]
    advance_faults: std::sync::Mutex<VecDeque<SessionError>>,
    /// How the next plain rollbacks go wrong ([`RollbackFault`]).
    #[cfg(any(test, feature = "test-utils"))]
    rollback_faults: std::sync::Mutex<VecDeque<RollbackFault>>,
    /// What a hold with no clock of its caller's reads as now, when a test
    /// has set one; zero for the device's own.
    #[cfg(any(test, feature = "test-utils"))]
    legacy_now_ms: AtomicU64,
    /// Errors the next confirms of a fanout's commit fail with, in place of
    /// asking the engine: the only way to hand the driver a store that is
    /// busy at exactly that call.
    #[cfg(any(test, feature = "test-utils"))]
    confirm_faults: std::sync::Mutex<VecDeque<SessionError>>,
    /// The next ingest errs after the engine ran it: what MDK leaves when it
    /// records an event and then fails on it.
    #[cfg(any(test, feature = "test-utils"))]
    ingest_fault: std::sync::atomic::AtomicBool,
    /// What the next fanout resolution finds in the engine's one-shot buffers
    /// beside its own batch: how a test hands the driver a commit an earlier
    /// call left there with a live ref and no record.
    #[cfg(any(test, feature = "test-utils"))]
    stranded: std::sync::Mutex<Option<SessionEffects>>,
}

/// The refused ids one circle may hold by id.
///
/// Its later refusals are owed as a history range instead
/// ([`RefusedRedeliveryLedger::record`]), so a flood of refusals — an
/// outsider's forgeries past MDK's deferral cap each announce one — can grow
/// neither the ledger nor the refetch without bound.
pub const MAX_REFUSED_IDS_PER_GROUP: usize = 1024;

/// How long a refused id waits before it is asked for again after its first
/// unsuccessful sweep; each later one doubles the wait, up to
/// [`REFETCH_SPACING_CAP_SECS`].
pub const REFETCH_SPACING_BASE_SECS: i64 = 60;

/// The longest a refused id waits between two sweeps that ask for it.
///
/// An object the engine has no room for becomes one it can take only when
/// its store of what it cannot open drains: at a new epoch, which makes
/// every owed id due at once ([`RefusedRedeliveryLedger::moved`]), or as
/// MDK's own thirty-day residence retires rows. Asking a relay for the same
/// id more than once a day in between buys nothing, and anyone who knows a
/// routing tag decides how many such ids a circle owes.
pub const REFETCH_SPACING_CAP_SECS: i64 = 24 * 60 * 60;

/// The wait a refused id has earned after `attempts` unsuccessful sweeps.
#[must_use]
pub fn refetch_spacing_secs(attempts: u32) -> i64 {
    REFETCH_SPACING_BASE_SECS
        .saturating_mul(1_i64 << attempts.saturating_sub(1).min(32))
        .min(REFETCH_SPACING_CAP_SECS)
}

/// Where the ids of refused transport objects wait for their refetch.
///
/// The engine keeps nothing of a refused object and the cursor has usually
/// passed it, so the id is the object's only way back; it must survive a
/// process kill and a wake deadline (MDK v0.10.4 `cgka-engine/src/store.rs:854-912`
/// asks the host to arm the backfill). Nothing is given up on a count: an id
/// a sweep could not discharge is asked for again after a wait that doubles
/// ([`refetch_spacing_secs`]), so a relay is not asked for the same id at
/// every sweep for ever. Implementations never log an id.
pub trait RefusedRedeliveryLedger: Send + Sync {
    /// Records `ids` as owed a refetch in `group_id`. Past
    /// [`MAX_REFUSED_IDS_PER_GROUP`] owed ids, the rest are owed as a refetch
    /// of the circle's history up to `now_secs` instead: the range is not
    /// ended by a walk that began before this, nor by one in which the
    /// engine took nothing of an event it was handed
    /// ([`Self::settle_owed_range`]). Answers whether every one of them is
    /// on record now: a caller that holds the event's only other copy keeps
    /// it when this says no.
    fn record(&self, group_id: &GroupId, ids: &[nostr::EventId], now_secs: i64) -> bool;
    /// Owes a refetch of `group_id`'s history up to `now_secs`, as an
    /// overflow of [`Self::record`] does: the range is opened, or widened and
    /// its generation bumped, so a pass that read it before ends nothing. What
    /// the epoch-stall detector's arm asks for (T-EPOCH-STALL). Answers
    /// whether the write landed.
    fn owe_range(&self, group_id: &GroupId, now_secs: i64) -> bool;
    /// Up to `limit` owed ids whose wait is over at `now_secs`, from the
    /// front of the queue: an id joins at the back when it is recorded and
    /// goes to the back each time it is asked for, so one that has had its
    /// turn is ahead of every id recorded after — an order nobody who mints
    /// ids can put theirs first in. A clock that reads earlier than an id
    /// was last tried at has been stepped back, and that id is due.
    fn owed(&self, group_id: &GroupId, limit: usize, now_secs: i64) -> Vec<nostr::EventId>;
    /// Marks `ids` asked for at `now_secs` and still owed: each waits twice
    /// as long as it last did. `wholesale` says the engine had no room for
    /// anything the request brought back: the circle's other ids that have
    /// already been asked for since they last became due at once then wait
    /// at least as long as the soonest of these. One not yet asked for keeps
    /// its turn — it may be the one the engine can open.
    fn tried(&self, group_id: &GroupId, ids: &[nostr::EventId], now_secs: i64, wholesale: bool);
    /// Every id `group_id` owes a refetch of, whether its wait is over or not.
    fn owed_ids(&self, group_id: &GroupId) -> HashSet<nostr::EventId>;
    /// Discharges `ids`: delivered, or proven gone from every relay asked.
    fn resolve(&self, group_id: &GroupId, ids: &[nostr::EventId]);
    /// `group_id` has reached a new epoch: what the engine could not open or
    /// had no room for it may take now, so every owed id and the owed range
    /// are due at once. Nothing ends here: what was refused for want of room
    /// is as a rule an event from an epoch the device has not reached, and
    /// how far ahead it lies is not known.
    fn moved(&self, group_id: &GroupId);
    /// The history range `group_id` owes a refetch of, if any.
    fn owed_range(&self, group_id: &GroupId) -> Option<OwedRange>;
    /// A pass is about to ask for the owed range at `now_secs`: unless it
    /// carries the walk further down, the next waits twice as long as this
    /// one did. A walk that is not under way begins here, at the ceiling.
    fn range_tried(&self, group_id: &GroupId, now_secs: i64);
    /// Records how far the pass that read `read` got, and only if the walk
    /// still stands where that pass found it.
    ///
    /// [`RangePass::Halted`] below where it began carries the walk down, and
    /// the rest is due at once; one that got no further has earned its wait.
    /// [`RangePass::Whole`] ends the range only when nothing in the whole
    /// walk is still owed — no pass of it left an event with the engine
    /// holding nothing of it, and no refusal was recorded since it began.
    /// Otherwise the next pass begins a new walk at the ceiling, after the
    /// wait this one earned. The ceiling is never lowered: `created_at` is
    /// the sender's to choose. A pass that halted on a full page dated
    /// entirely in one second is recorded below that second, owing: events
    /// beyond a relay's page limit that share one second are unreachable by
    /// NIP-01 paging, and everything below them stays reachable.
    fn settle_owed_range(&self, group_id: &GroupId, read: OwedRange, pass: RangePass);
}

/// How far one pass over a circle's owed range got. `owing`: the engine
/// holds nothing of an event the pass brought back — it had no room for it,
/// erred on it with no record of its own, or was never asked.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum RangePass {
    /// It stopped with history below `at_secs` still to ask for.
    Halted { at_secs: i64, owing: bool },
    /// Every relay answered down to the circle's start.
    Whole { owing: bool },
}

/// The history range one circle owes a refetch of, as a pass reads it. No
/// `Debug`: three of its fields are absolute instants (Security Rule 15).
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct OwedRange {
    /// The range's ceiling, unix seconds; its floor is the circle's start.
    pub until_secs: i64,
    /// Where the walk under way has got down to — what the next pass asks
    /// down from; the ceiling when none is under way.
    pub walk_secs: i64,
    /// Bumped by every refusal that widens the range, so a pass ends only
    /// the range it read.
    pub generation: i64,
    /// When a pass last asked for it, unix seconds; zero if none has.
    pub tried_secs: i64,
    /// When it may be asked for again.
    pub due_secs: i64,
}

impl OwedRange {
    /// Whether a pass may ask for the range at `now_secs`: its wait is over,
    /// or the clock reads earlier than its last pass and so was stepped back.
    #[must_use]
    pub const fn is_due(&self, now_secs: i64) -> bool {
        self.due_secs <= now_secs || now_secs < self.tried_secs
    }
}

/// The ledger a bare session keeps until a store is installed: in memory.
#[derive(Default)]
struct InMemoryRefusedLedger(std::sync::Mutex<InMemoryRefused>);

#[derive(Default)]
struct InMemoryRefused {
    ids: HashMap<GroupId, HashMap<nostr::EventId, OwedId>>,
    ranges: HashMap<GroupId, InMemoryRange>,
    /// Outlives a settled range, so a range owed again after one is cleared
    /// never reuses a generation a pass still holds.
    generations: HashMap<GroupId, i64>,
    recorded: u64,
}

impl InMemoryRefused {
    /// Opens `group_id`'s owed range, or widens it to `now_secs` and bumps
    /// its generation.
    fn owe_range(&mut self, group_id: &GroupId, now_secs: i64) {
        let generation = self.generations.entry(group_id.clone()).or_default();
        *generation += 1;
        let generation = *generation;
        let kept = self
            .ranges
            .entry(group_id.clone())
            .or_insert(InMemoryRange {
                range: OwedRange {
                    until_secs: now_secs,
                    walk_secs: now_secs,
                    generation,
                    tried_secs: 0,
                    due_secs: 0,
                },
                walking: false,
                attempts: 0,
                unsettled: true,
            });
        kept.range.until_secs = kept.range.until_secs.max(now_secs);
        kept.range.generation = generation;
        kept.unsettled = true;
        if !kept.walking {
            kept.range.walk_secs = kept.range.until_secs;
        }
    }
}

impl InMemoryRefusedLedger {
    fn held(&self) -> std::sync::MutexGuard<'_, InMemoryRefused> {
        self.0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// One owed range, as the in-memory ledger keeps it.
#[derive(Clone, Copy)]
struct InMemoryRange {
    range: OwedRange,
    /// Whether a walk is under way: `range.walk_secs` is then where it has
    /// got to, and the ceiling otherwise.
    walking: bool,
    /// Passes since it was last due at once that did not carry a walk down.
    attempts: u32,
    /// Something of the walk under way is still owed.
    unsettled: bool,
}

/// One refused id, as the in-memory ledger keeps it.
#[derive(Default, Clone, Copy)]
struct OwedId {
    tried: i64,
    attempts: u32,
    due: i64,
    /// Its place in the queue ids are asked for from: the back when it is
    /// recorded, and the back again each time it is asked for.
    seq: u64,
}

impl RefusedRedeliveryLedger for InMemoryRefusedLedger {
    fn record(&self, group_id: &GroupId, ids: &[nostr::EventId], now_secs: i64) -> bool {
        let mut held = self.held();
        let mut seq = held.recorded;
        let owed = held.ids.entry(group_id.clone()).or_default();
        let mut overflowed = false;
        for id in ids {
            if owed.contains_key(id) {
                continue;
            }
            if owed.len() < MAX_REFUSED_IDS_PER_GROUP {
                seq += 1;
                owed.insert(
                    *id,
                    OwedId {
                        seq,
                        ..OwedId::default()
                    },
                );
            } else {
                overflowed = true;
            }
        }
        held.recorded = seq;
        if overflowed {
            InMemoryRefused::owe_range(&mut held, group_id, now_secs);
        }
        drop(held);
        true
    }

    fn owe_range(&self, group_id: &GroupId, now_secs: i64) -> bool {
        InMemoryRefused::owe_range(&mut self.held(), group_id, now_secs);
        true
    }

    fn owed(&self, group_id: &GroupId, limit: usize, now_secs: i64) -> Vec<nostr::EventId> {
        let mut owed: Vec<_> = self
            .held()
            .ids
            .get(group_id)
            .map(|ids| {
                ids.iter()
                    .filter(|(_, owed)| owed.due <= now_secs || now_secs < owed.tried)
                    .map(|(id, owed)| (owed.seq, *id))
                    .collect()
            })
            .unwrap_or_default();
        owed.sort_unstable();
        owed.into_iter().take(limit).map(|(_, id)| id).collect()
    }

    fn tried(&self, group_id: &GroupId, ids: &[nostr::EventId], now_secs: i64, wholesale: bool) {
        let mut held = self.held();
        let mut seq = held.recorded;
        if let Some(owed) = held.ids.get_mut(group_id) {
            let mut soonest = None;
            for id in ids {
                if let Some(owed) = owed.get_mut(id) {
                    seq += 1;
                    owed.seq = seq;
                    owed.tried = now_secs;
                    owed.attempts = owed.attempts.saturating_add(1);
                    owed.due = now_secs.saturating_add(refetch_spacing_secs(owed.attempts));
                    soonest = Some(soonest.map_or(owed.due, |due: i64| due.min(owed.due)));
                }
            }
            if let Some(soonest) = soonest.filter(|_| wholesale) {
                for owed in owed.values_mut().filter(|owed| owed.due > 0) {
                    owed.due = owed.due.max(soonest);
                }
            }
        }
        held.recorded = seq;
    }

    fn moved(&self, group_id: &GroupId) {
        let mut held = self.held();
        if let Some(owed) = held.ids.get_mut(group_id) {
            for owed in owed.values_mut() {
                owed.due = 0;
            }
        }
        if let Some(kept) = held.ranges.get_mut(group_id) {
            kept.range.due_secs = 0;
            kept.attempts = 0;
        }
    }

    fn resolve(&self, group_id: &GroupId, ids: &[nostr::EventId]) {
        let mut held = self.held();
        if let Some(owed) = held.ids.get_mut(group_id) {
            for id in ids {
                owed.remove(id);
            }
            if owed.is_empty() {
                held.ids.remove(group_id);
            }
        }
    }

    fn owed_ids(&self, group_id: &GroupId) -> HashSet<nostr::EventId> {
        self.held()
            .ids
            .get(group_id)
            .map(|ids| ids.keys().copied().collect())
            .unwrap_or_default()
    }

    fn owed_range(&self, group_id: &GroupId) -> Option<OwedRange> {
        self.held().ranges.get(group_id).map(|kept| kept.range)
    }

    fn range_tried(&self, group_id: &GroupId, now_secs: i64) {
        if let Some(kept) = self.held().ranges.get_mut(group_id) {
            kept.attempts = kept.attempts.saturating_add(1);
            kept.range.tried_secs = now_secs;
            kept.range.due_secs = now_secs.saturating_add(refetch_spacing_secs(kept.attempts));
            if !kept.walking {
                kept.walking = true;
                kept.unsettled = false;
            }
        }
    }

    fn settle_owed_range(&self, group_id: &GroupId, read: OwedRange, pass: RangePass) {
        let mut held = self.held();
        let Some(kept) = held
            .ranges
            .get_mut(group_id)
            .filter(|kept| kept.walking && kept.range.walk_secs == read.walk_secs)
        else {
            return;
        };
        match pass {
            RangePass::Halted { at_secs, owing } => {
                kept.unsettled |= owing;
                if at_secs < kept.range.walk_secs {
                    kept.range.walk_secs = at_secs;
                    kept.range.due_secs = 0;
                    kept.attempts = kept.attempts.saturating_sub(1);
                }
            }
            RangePass::Whole { owing }
                if owing || kept.unsettled || kept.range.generation != read.generation =>
            {
                kept.walking = false;
                kept.range.walk_secs = kept.range.until_secs;
            }
            RangePass::Whole { .. } => {
                held.ranges.remove(group_id);
            }
        }
    }
}

/// Advances one [`SessionManager::advance_for_receive`] may take to give every
/// deferred-peel row a try: MDK's per-group row cap
/// (`MAX_PEEL_DEFERRED_ROWS_PER_GROUP`) over the rows one advance retries
/// (`MAX_DEFERRED_ROWS_PER_SWEEP` = 64, `cgka-engine/src/message_processor/mod.rs:155`,
/// crate-private and so restated here), plus the advance that finds the store
/// settled.
pub const DEFERRED_PEEL_DRAIN_ADVANCES: usize =
    cgka_engine::message_processor::MAX_PEEL_DEFERRED_ROWS_PER_GROUP.div_ceil(64) + 1;

/// Advances the drain ahead of the user's own send may take: one per row MDK's
/// per-group cap lets the store hold, plus the advance that finds it settled.
/// MDK cuts an advance at `BACKGROUND_CONVERGENCE_BUDGET_MS` of wall clock
/// (`message_processor/mod.rs:209`) but always finishes one row of a slice that
/// starts with time (`:1928-1934`), so a slow device takes more advances, never
/// leaves a row the send's preflight would queue the send behind.
pub const SEND_PEEL_DRAIN_ADVANCES: usize =
    cgka_engine::message_processor::MAX_PEEL_DEFERRED_ROWS_PER_GROUP + 1;

/// Wall-clock budget for a receive plane's deferred-peel drain after its
/// first advance. Rows it leaves untried are the next pass's: MDK reports them
/// due now, so the planes' own scheduler re-ticks the group.
pub const DEFERRED_PEEL_DRAIN_BUDGET: std::time::Duration = std::time::Duration::from_secs(1);

/// `first`'s effects followed by `then`'s, every field kept.
#[must_use]
pub fn chain_effects(mut first: SessionEffects, then: SessionEffects) -> SessionEffects {
    first.events.extend(then.events);
    first.publish.extend(then.publish);
    first.queued.extend(then.queued);
    first.pending_convergence.extend(then.pending_convergence);
    first
}

/// An engine batch whose events and named groups [`SessionManager::noted`]
/// reads.
trait EngineBatch {
    fn events(&self) -> &[GroupEvent];
    fn pending(&self) -> &[GroupId];
    /// The groups a proposal the engine accepted in this batch belongs to.
    fn proposals(&self) -> &[GroupId] {
        &[]
    }
}

/// An engine batch that what was handed back ahead of it can be put before
/// ([`SessionManager::behind_what_was_handed_back`]).
trait Effects {
    fn effects_mut(&mut self) -> &mut SessionEffects;
}

impl EngineBatch for SessionEffects {
    fn events(&self) -> &[GroupEvent] {
        &self.events
    }

    fn pending(&self) -> &[GroupId] {
        &self.pending_convergence
    }
}

impl Effects for SessionEffects {
    fn effects_mut(&mut self) -> &mut SessionEffects {
        self
    }
}

impl EngineBatch for IngestEffects {
    fn events(&self) -> &[GroupEvent] {
        &self.effects.events
    }

    fn pending(&self) -> &[GroupId] {
        &self.effects.pending_convergence
    }

    fn proposals(&self) -> &[GroupId] {
        &self.valid_proposal_groups
    }
}

impl Effects for IngestEffects {
    fn effects_mut(&mut self) -> &mut SessionEffects {
        &mut self.effects
    }
}

impl EngineBatch for Option<SessionEffects> {
    fn events(&self) -> &[GroupEvent] {
        self.as_ref().map_or(&[], |effects| &effects.events)
    }

    fn pending(&self) -> &[GroupId] {
        self.as_ref()
            .map_or(&[], |effects| &effects.pending_convergence)
    }
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
        Self::new_with_notes(data_dir, keys, None)
    }

    /// [`Self::new`], keeping what is noted per circle in `notes`. A removal
    /// found staged with no fanout record is given one before the engine
    /// hydrates (see `settle_fanouts_before_open`).
    ///
    /// `notes` is where what is kept per circle about its commits is stored
    /// ([`CommitNotes`]): handed over here, not installed afterwards, because
    /// the pass before the engine opens already has things to note and must
    /// note them durably before it deletes the row that says them. `None`
    /// keeps them for as long as this session lasts.
    ///
    /// # Errors
    ///
    /// As [`Self::new`].
    pub fn new_with_notes(
        data_dir: &Path,
        keys: &Keys,
        notes: Option<Arc<dyn CommitNotes>>,
    ) -> Result<Self> {
        std::fs::create_dir_all(data_dir).map_err(|e| {
            NostrError::StorageError(format!("failed to create MLS data directory: {e}"))
        })?;
        let config = StorageConfig::new(data_dir);
        let key = config.sqlcipher_key()?;
        Self::open_session(
            config.database_path(),
            key,
            StorageConfig::storage_options(),
            keys,
            notes,
        )
    }

    /// Opens a session over a fixed-key encrypted temp database, bypassing the
    /// keyring. Test/development only.
    ///
    /// The Dark Matter `storage-sqlite` backend always encrypts (`SQLCipher`); the
    /// "unencrypted" name is retained for continuity with the old test API. It
    /// uses a constant test key so no platform keyring is required, and
    /// [`StorageConfig::test_storage_options`].
    ///
    /// # Errors
    ///
    /// Returns an error if the directory cannot be created or the session cannot
    /// open/hydrate.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn new_unencrypted(data_dir: &Path, keys: &Keys) -> Result<Self> {
        Self::new_unencrypted_with_notes(data_dir, keys, None)
    }

    /// [`Self::new_with_notes`] over the fixed test key.
    ///
    /// # Errors
    ///
    /// As [`Self::new_unencrypted`].
    #[cfg(any(test, feature = "test-utils"))]
    pub fn new_unencrypted_with_notes(
        data_dir: &Path,
        keys: &Keys,
        notes: Option<Arc<dyn CommitNotes>>,
    ) -> Result<Self> {
        std::fs::create_dir_all(data_dir).map_err(|e| {
            NostrError::StorageError(format!("failed to create MLS data directory: {e}"))
        })?;
        let config = StorageConfig::new(data_dir);
        let key = StorageConfig::test_sqlcipher_key()?;
        Self::open_session(
            config.database_path(),
            key,
            StorageConfig::test_storage_options(),
            keys,
            notes,
        )
    }

    /// Shared open path: wires the peeler, the hardened proof signer, and the
    /// supported app-component set, then hydrates the session.
    // One struct literal of the session's fields.
    #[allow(clippy::too_many_lines)]
    fn open_session(
        db_path: std::path::PathBuf,
        key: SqlCipherKey,
        options: SqliteStorageOptions,
        keys: &Keys,
        notes: Option<Arc<dyn CommitNotes>>,
    ) -> Result<Self> {
        crate::sqlcipher_init::ensure()
            .map_err(|_| NostrError::StorageError("failed to initialise SQLite".to_owned()))?;
        // Rule 14 (runtime): fail closed if a live session already holds this DB
        // file. Acquired BEFORE the engine open so a rejected second open never
        // touches the on-disk state; if the engine open below fails, the guard
        // drops and releases the path (no false lockout on a legitimate retry).
        let live_guard = LiveSessionGuard::acquire(&db_path)?;
        // Opened BEFORE the session and from the same key, which is then moved
        // into `SessionConfig` — so the passphrase is never retained by Haven
        // beyond this function. Both opens run `storage-sqlite`'s idempotent
        // migrations; this one simply gets there first on a fresh database.
        // The SAME options the session's own connection is given below.
        // `journal_mode` is DB-wide and PERSISTENT, so two connections opening
        // one file with different options do not merely differ — the second
        // silently re-writes the first's journalling mode.
        let message_store =
            SqliteAccountStorage::open_encrypted_with_options(&db_path, &key, options.clone())
                .map_err(map_storage_err)?;
        let identity = keys.public_key().to_bytes().to_vec();
        // Before the engine hydrates and before anything can publish: hydrate
        // binds a group's first pending fanout row to WHATEVER commit it finds
        // staged, and the relay layer refuses a row's event only once the row
        // is in its registry. Best-effort like the sweep below — what a failed
        // pass leaves, the post-open pass and the driver's own checks meet.
        let notes_are_kept = notes.is_some();
        let commit_notes =
            notes.unwrap_or_else(|| Arc::new(InMemoryCommitNotes::default()) as Arc<_>);
        let mut unasked = HashSet::new();
        let rollback_unfinished = settle_fanouts_before_open(
            &message_store,
            &identity,
            commit_notes.as_ref(),
            notes_are_kept,
            &mut unasked,
        )
        .is_err();
        // Whatever the pass came to, no repair is mid-staging any more.
        for group_id in message_store.list_groups().unwrap_or_default() {
            if commit_notes.repair_marked(&group_id) != Some(false) {
                commit_notes.mark_repair(&group_id, false);
            }
        }
        if rollback_unfinished {
            log::warn!("[Fanout] settling the stored fanouts before the open failed");
        }
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
            .storage_options(options)
            .account_identity_proof_signer(proof_signer)
            .supported_app_components(haven_app_components())
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

        // No convergence policy is installed: production sessions MUST run
        // MDK's pinned v1 (`SessionConfig::convergence_policy` doc), and `open`
        // refuses anything else.
        let session = AccountDeviceSession::open(config).map_err(map_mls_err)?;
        // Haven never enrols a circle in periodic self-update: key changes
        // happen on membership changes and explicit repair only, never on a
        // timer (MDK defaults to `EnabledForNewGroups`, and only its own
        // runtime drives the resulting obligations). Written before any
        // create or join can read it, on every open.
        session
            .put_periodic_maintenance_policy(PeriodicMaintenancePolicy::Disabled)
            .map_err(map_mls_err)?;
        // Session-open sweep. A commit row orphaned by a kill mid-ingest, or
        // left `Retryable` by a decrypt failure that can never succeed (an
        // exhausted sender ratchet), gates EVERY later outbound send for its
        // circle — MDK's outbound preflight (`should_queue_outbound_intent`,
        // v0.10.4 `message_processor/mod.rs:1177`) queues instead of encrypting
        // while an unresolved convergence input sits in the window
        // (`has_unresolved_convergence_inputs`, `:1600`), and a stable circle's
        // epoch never moves, so that window is the circle's whole life. Rows
        // whose event the relay has already deleted can never be resolved by
        // re-delivery, so open is where they are cleared: it is the one moment
        // every isolate and every background wake passes through, and it costs
        // one indexed scan per group.
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
        settle_fanouts_after_open(&message_store, &session);
        // Only the open engine says who is listed: a removal the pass before
        // the open set aside is read again, and one that names nobody still
        // in its circle holds nothing.
        for group_id in message_store.list_groups().unwrap_or_default() {
            let _ = removal_unmade(&message_store, commit_notes.as_ref(), &session, &group_id);
        }
        // Read from the engine now that it is open, and before anything else
        // can act on a circle: only the open engine says which circles hold
        // no commit of their own pending.
        let examined = Examined::default();
        let stranded = find_stranded(
            &message_store,
            commit_notes.as_ref(),
            &session,
            &HashSet::new(),
            &examined,
        );
        // What the hydrate cleared, read before any call can serve a
        // convergence pass: a commit it cleared had no record, so it never
        // left the device, and its stored row would be selected and applied
        // here alone. The engine gate retires it before the first call.
        // Unreadable now, it is read again with the engine held, and no call
        // is handed the engine until it has been.
        let cleared = cleared_at_open(&message_store, &session);
        let unread = cleared.is_none();
        let cleared = cleared.unwrap_or_default();
        let groups_at_open = session.live_group_ids().ok();
        let this = Self {
            groups_at_open,
            unread_input: std::sync::Mutex::new(UnreadInput::default()),
            negentropy: std::sync::Mutex::new(crate::relay::negentropy::NegMemo::default()),
            mesh_keys: MeshKeys::new(),
            // A pass that failed may have left a rolled-back row unfinished,
            // and a commit the hydrate cleared is owed its retirement.
            session: Gated::new(
                session,
                rollback_unfinished || !cleared.is_empty() || unread,
            ),
            cleared_unread: AtomicBool::new(unread),
            identity_pubkey: keys.public_key(),
            preview_peeler,
            message_store,
            _live_guard: live_guard,
            open_recovery_owed: AtomicBool::new(true),
            owed_advance: std::sync::Mutex::new(Vec::new()),
            #[cfg(any(test, feature = "test-utils"))]
            advances: std::sync::Mutex::new(HashMap::new()),
            #[cfg(any(test, feature = "test-utils"))]
            self_update_asks: std::sync::atomic::AtomicUsize::new(0),
            #[cfg(any(test, feature = "test-utils"))]
            stall_arms: std::sync::atomic::AtomicUsize::new(0),
            eviction_retick_hold: std::sync::Mutex::new(HashMap::new()),
            refused_ledger: Arc::new(InMemoryRefusedLedger::default()),
            commit_notes,
            key_package_tick: Mutex::new(()),
            unretired: std::sync::Mutex::new(cleared),
            unrecorded: std::sync::Mutex::new(Vec::new()),
            dropped_removals: std::sync::Mutex::new(Vec::new()),
            holding_stranded: std::sync::Mutex::new(stranded),
            caught_up: std::sync::Mutex::new(HashSet::new()),
            epoch_stall: std::sync::Mutex::new(EpochStallDetector::default()),
            stall_evidence: Arc::new(NoStallEvidence),
            stall_armed: AtomicBool::new(false),
            unasked_clears: std::sync::Mutex::new(unasked),
            caught_up_since: std::sync::Mutex::new(HashMap::new()),
            state_input_at: std::sync::Mutex::new(HashMap::new()),
            post_join_spaced_until: std::sync::Mutex::new(None),
            #[cfg(any(test, feature = "test-utils"))]
            caught_up_marks: tokio::sync::watch::channel(0).0,
            #[cfg(any(test, feature = "test-utils"))]
            requeues_for_test: AtomicBool::new(false),
            handed_back: std::sync::Mutex::new(None),
            own_locations: std::sync::Mutex::new(HashMap::new()),
            live_plane: AtomicU64::new(0),
            burst_end: std::sync::Mutex::new(None),
            bridge_claims: AtomicU64::new(0),
            tried: std::sync::Mutex::new(HashSet::new()),
            told_at_redelivery: std::sync::Mutex::new(HashSet::new()),
            examined,
            #[cfg(any(test, feature = "test-utils"))]
            hand_back_stop: std::sync::Mutex::new(None),
            #[cfg(any(test, feature = "test-utils"))]
            during_hand_back: std::sync::Mutex::new(None),
            #[cfg(any(test, feature = "test-utils"))]
            store_faults: std::sync::Mutex::new(Vec::new()),
            #[cfg(any(test, feature = "test-utils"))]
            proposal_scan_cap: std::sync::atomic::AtomicUsize::new(PROPOSAL_SCAN_CAP),
            #[cfg(any(test, feature = "test-utils"))]
            advance_faults: std::sync::Mutex::new(VecDeque::new()),
            #[cfg(any(test, feature = "test-utils"))]
            rollback_faults: std::sync::Mutex::new(VecDeque::new()),
            #[cfg(any(test, feature = "test-utils"))]
            legacy_now_ms: std::sync::atomic::AtomicU64::new(0),
            #[cfg(any(test, feature = "test-utils"))]
            confirm_faults: std::sync::Mutex::new(VecDeque::new()),
            #[cfg(any(test, feature = "test-utils"))]
            ingest_fault: AtomicBool::new(false),
            #[cfg(any(test, feature = "test-utils"))]
            stranded: std::sync::Mutex::new(None),
        };
        Ok(this)
    }

    // ── The engine's lock ────────────────────────────────────────────────────

    /// The session, for a call that cannot run a convergence pass.
    ///
    /// What it hands out cannot be borrowed mutably, and every engine call
    /// that can run a pass for a circle — a send, an ingest, an advance, a
    /// confirm, a rollback, a hydrate — takes `&mut` (v0.10.4
    /// `cgka-session/src/lib.rs`). So none of them can be reached from here:
    /// they go through [`Self::engine`]. That is not "only reads": the
    /// session's `&self` calls include durable writes — a fanout row put or
    /// deleted, a Welcome marked delivered, a queued change retired — and
    /// those go through here.
    async fn reading(&self) -> Reading<'_, AccountDeviceSession> {
        self.session.reading().await
    }

    /// The session, for a call that may change a circle: the ONE way to a
    /// `&mut AccountDeviceSession`, and the compiler's — the lock is private
    /// to [`super::engine_gate`].
    ///
    /// MDK's rollback rewinds the commit and leaves its own stored row as
    /// sent, where any later convergence pass of the circle can select it
    /// and merge a commit every relay refused
    /// (`docs/MDK_UPSTREAM_TRACKER.md` T-ROLLBACK-RESURRECT). Haven retires
    /// that row right after the rewind; while one may still be unretired —
    /// the write failed, the rollback's future was dropped, or the pass
    /// before the open could not finish — it is retired HERE, before the
    /// engine is handed over, and the call is refused if it still cannot be.
    /// The gate is one for every circle: a call for one circle can run
    /// another's pass.
    ///
    /// # Errors
    ///
    /// Returns [`NostrError::EngineHeld`] when a rolled-back commit's row
    /// could not be retired: no engine call that could merge it is made.
    async fn engine(&self) -> Result<Engine<'_, AccountDeviceSession>> {
        self.session
            .engine(|session| self.finish_rollbacks(session))
            .await
            .map_err(|Held| {
                log::warn!(
                    "[Fanout] a rolled-back commit is not yet retired; the engine is not \
                     called until it is"
                );
                NostrError::EngineHeld
            })
    }

    /// Retires every commit a rollback rewound and left stored as sent: the
    /// ones a plain rollback could not retire, which no row names, and the
    /// one behind each stored rolled-back fanout row.
    fn finish_rollbacks(&self, session: &AccountDeviceSession) -> Result<()> {
        let mut unretired = self
            .unretired
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if self.cleared_unread.load(Ordering::Acquire) {
            let cleared = cleared_at_open(&self.message_store, session).ok_or_else(|| {
                NostrError::StorageError("the commits the open cleared are unread".to_string())
            })?;
            for origin in cleared {
                if !unretired.contains(&origin) {
                    unretired.push(origin);
                }
            }
            self.cleared_unread.store(false, Ordering::Release);
        }
        let mut failed = None;
        unretired.retain(|origin| {
            // Owed before its rewind, by a call that was dropped before it
            // rewound anything: the commit is still staged, and its row is
            // not one to retire.
            if Self::still_staged(session, origin) {
                return false;
            }
            retire_commit(&self.message_store, origin)
                .map_err(|e| failed = Some(e))
                .is_err()
        });
        drop(unretired);
        if let Some(e) = failed {
            return Err(map_storage_err(e));
        }
        session
            .outbound_fanouts()
            .map_err(map_mls_err)?
            .iter()
            .filter(|row| row.mls_state() == FanoutMlsState::RolledBack)
            .try_for_each(|row| self.finish_rolled_back_in(session, row))
    }

    /// Makes the next `reads` of the commits an open cleared, on this thread,
    /// fail as an unreadable store would.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn fail_cleared_reads_for_test(reads: u32) {
        CLEARED_READ_FAULTS.with(|left| left.set(reads));
    }

    /// Whether the commit `origin` names is the one some circle holds staged.
    fn still_staged(session: &AccountDeviceSession, origin: &MessageId) -> bool {
        session.live_group_ids().is_ok_and(|ids| {
            ids.iter().any(|group_id| {
                matches!(
                    session.epoch_state(group_id),
                    Some(EpochState::PendingPublish(staged))
                        if session
                            .pending_origin_message_id(staged.pending_ref())
                            .is_ok_and(|staged| &staged == origin)
                )
            })
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
        self.reading().await.self_id()
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
        // Current profile: the only one a v0.10.4 session invites or mints
        // (MDK `traits/src/engine.rs:60-95` defaults to Legacy, which every
        // create and invite then refuses). A Legacy package fails metadata and
        // invite validation instead of being misread.
        Ok(KeyPackage::with_source_event_id(bytes, source)
            .with_protocol_profile(ProtocolProfile::Current))
    }

    /// What a `KeyPackage` must be to be invited into the existing circle
    /// `group_id`, or — `None` — into a new Haven circle: MDK's
    /// `invite_key_package_requirements` / `create_key_package_requirements`
    /// (v0.10.4 `cgka-session/src/lib.rs:837-849`). A fetch reads it once and
    /// filters its candidates with it BEFORE ranking them
    /// (`foundation/key-packages.md:65-66,72-75`).
    ///
    /// # Errors
    ///
    /// Returns an error if the circle is unknown or its state cannot be read.
    pub async fn key_package_admission_rule(
        &self,
        group_id: Option<&GroupId>,
    ) -> Result<KeyPackageAdmissionRule> {
        let session = self.reading().await;
        group_id
            .map_or_else(
                || session.create_key_package_requirements(&haven_circle_request()),
                |group_id| session.invite_key_package_requirements(group_id),
            )
            .map(KeyPackageAdmissionRule)
            .map_err(map_mls_err)
    }

    /// Whether a fetched `KeyPackage` event can be invited: into the existing
    /// circle `group_id`, or — `None` — into a new Haven circle.
    ///
    /// The verdict is MDK's own admission check,
    /// `invite_key_package_requirements` / `create_key_package_requirements`
    /// `.validate()` (v0.10.4 `cgka-engine/src/key_package.rs:196-261`), so an
    /// invite this admits is one the engine will accept. A package that fails
    /// it but decodes as the Legacy profile — and every kind-443 — belongs to
    /// a peer still on a pre-migration build.
    pub async fn key_package_admission(
        &self,
        event: &Event,
        group_id: Option<&GroupId>,
    ) -> KeyPackageAdmission {
        if event.kind == Kind::Custom(KIND_PRE_MIGRATION_KEY_PACKAGE) {
            return KeyPackageAdmission::NeedsUpdate;
        }
        if event.kind != Kind::Custom(KIND_MARMOT_KEY_PACKAGE) {
            return KeyPackageAdmission::Unusable;
        }
        let Ok(package) = Self::key_package_from_event(event) else {
            return KeyPackageAdmission::Unusable;
        };
        let admitted = self
            .key_package_admission_rule(group_id)
            .await
            .is_ok_and(|rule| rule.admits(&package));
        if admitted {
            KeyPackageAdmission::Admissible
        } else if cgka_engine::key_package_metadata(
            &package.with_protocol_profile(ProtocolProfile::Legacy),
        )
        .is_ok()
        {
            KeyPackageAdmission::NeedsUpdate
        } else {
            KeyPackageAdmission::Unusable
        }
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

    /// Every bare proposal in `work` as a publishable event.
    ///
    /// Outside a released queued leave, the only one is the local user's own
    /// re-proposed leave, which an advance after a peer's commit re-mints ONCE
    /// per epoch (MDK `fcc85edd` `cgka-engine/src/message_processor/send.rs`
    /// 874-892) — so a receive path that drops it wedges the leave until the
    /// next epoch.
    #[must_use]
    pub fn proposal_events(work: &[PublishWork]) -> Vec<Event> {
        let mut events = Vec::new();
        for item in work {
            if let PublishWork::Proposal { msg, .. } = item {
                match Self::transport_message_to_event(msg) {
                    Ok(event) => events.push(event),
                    Err(e) => log::warn!(
                        "receive path: dropping an unserializable proposal: {}",
                        e.code()
                    ),
                }
            }
        }
        events
    }

    // ── Group lifecycle ──────────────────────────────────────────────────────

    /// Creates a new location sharing group.
    ///
    /// Builds a [`CreateGroupRequest`]: name/description become the group's
    /// profile component, `config.relays` become a freshly-minted
    /// `marmot.transport.nostr.routing.v1` component (with a random 32-byte
    /// `nostr_group_id`), and `config.admins` bootstrap the initial admin set
    /// (the creator is always an admin implicitly). The returned
    /// [`CreateGroupEffects`] carries the welcomes to publish; a founding create
    /// is canonical at once (`PublishWork::FoundingGroupCreated`), with nothing
    /// to confirm.
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
        let mut nostr_group_id = [0u8; 32];
        OsRng.fill_bytes(&mut nostr_group_id);
        let routing = routing_of(nostr_group_id, config.relays.clone())?;
        let routing_bytes = encode_nostr_routing_v1(&routing)
            .map_err(|_| NostrError::InvalidEvent("routing encode failed".to_string()))?;

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

        let mut session = self.engine().await?;
        let created = session.create_group(req).await.map_err(map_mls_err);
        // MDK collects every batch's effects into the create's own, a group
        // named owing an advance among them.
        if let Ok(created) = &created {
            self.note_effects(&session, &created.effects);
        }
        drop(session);
        created
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
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn add_members(
        &self,
        group_id: &GroupId,
        key_packages: Vec<KeyPackage>,
    ) -> Result<SessionEffects> {
        self.send(Self::invite_intent(group_id, key_packages)).await
    }

    fn invite_intent(group_id: &GroupId, key_packages: Vec<KeyPackage>) -> SendIntent {
        SendIntent::Invite {
            group_id: group_id.clone(),
            key_packages,
            initial_admins: Vec::new(),
        }
    }

    /// Removes members from a group by their hex-encoded public keys.
    ///
    /// # Errors
    ///
    /// Returns an error if no valid pubkeys are provided, the caller is not an
    /// admin, or the group is unknown.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn remove_members(
        &self,
        group_id: &GroupId,
        member_pubkeys: &[String],
    ) -> Result<SessionEffects> {
        self.send(Self::removal_intent(group_id, member_pubkeys)?)
            .await
    }

    fn removal_intent(group_id: &GroupId, member_pubkeys: &[String]) -> Result<SendIntent> {
        let members = parse_member_ids(member_pubkeys);
        if members.is_empty() {
            return Err(NostrError::InvalidEvent(
                "No valid public keys provided".to_string(),
            ));
        }
        Ok(SendIntent::RemoveMembers {
            group_id: group_id.clone(),
            members,
        })
    }

    /// Leaves a group via a MIP-03 `SelfRemove` proposal.
    ///
    /// Returns [`SessionEffects`] carrying a `Proposal` to publish. A bare
    /// proposal has no `PendingStateRef` (the epoch advances later via a peer's
    /// auto-commit), so there is nothing to confirm. `None` when this epoch's
    /// leave proposal already exists (MDK's typed `LeaveAlreadyRequested`,
    /// v0.10.4 `message_processor/send.rs:730-746`): the leave stands and
    /// there is nothing new to publish.
    ///
    /// # Errors
    ///
    /// Returns [`NostrError::AdminSelfDemoteRequired`] if the caller is still
    /// an admin — matched on the engine's typed `AdminCannotSelfRemove`
    /// variant (never its message text) so Haven's actionable "self-demote
    /// first" routing signal is stable across upstream wording changes and
    /// never carries the group id. Any other engine rejection (e.g. unknown
    /// group) maps to the redacted MLS-error bucket.
    pub async fn leave_group(&self, group_id: &GroupId) -> Result<Option<SessionEffects>> {
        let mut session = self.engine().await?;
        let ahead = Box::pin(self.hand_back_stranded(&mut session, Some(group_id), true)).await?;
        let result = Self::send_leave(&mut session, group_id).await;
        let result = match self.noted(&session, result) {
            Ok(Some(effects)) => Ok(Some(
                self.unstaged_beside_a_fanout(&mut session, chain_effects(ahead, effects))
                    .await,
            )),
            other => {
                self.keep_handed_back(ahead);
                other
            }
        };
        drop(session);
        result
    }

    /// The engine's leave, its refusals typed: [`NostrError::AdminSelfDemoteRequired`]
    /// and [`NostrError::GroupNotFound`] no retry changes; [`NostrError::EpochNotStable`]
    /// ends when the circle is stable again (`send.rs` 782-792). `None` when
    /// this epoch's proposal already exists.
    async fn send_leave(
        session: &mut AccountDeviceSession,
        group_id: &GroupId,
    ) -> Result<Option<SessionEffects>> {
        match Box::pin(session.send(SendIntent::Leave {
            group_id: group_id.clone(),
        }))
        .await
        {
            Ok(effects) => Ok(Some(effects)),
            Err(SessionError::Engine(EngineError::LeaveAlreadyRequested { .. })) => Ok(None),
            Err(SessionError::Engine(EngineError::AdminCannotSelfRemove { .. })) => {
                Err(NostrError::AdminSelfDemoteRequired)
            }
            // Never seen (a storage miss) or quarantined, as `find_group`
            // reads them.
            Err(SessionError::Engine(
                EngineError::UnknownGroup(_)
                | EngineError::Storage(cgka_traits::storage::StorageError::NotFound),
            )) => Err(NostrError::GroupNotFound("<redacted>".to_owned())),
            Err(SessionError::Engine(EngineError::InvalidTransition(_)))
                if !matches!(
                    session.epoch_state(group_id),
                    Some(EpochState::Stable { .. })
                ) =>
            {
                Err(NostrError::EpochNotStable)
            }
            Err(other) => Err(map_mls_err(other)),
        }
    }

    /// [`Self::leave_group`] in staging mode: the proposal gets its durable
    /// fanout in the hold that minted it, and a due eviction the leave's
    /// preflight staged is recorded — or, inside a refusal wait, undone in
    /// the hold ([`Self::stage_commits`]). `None` when this epoch's proposal
    /// already exists. The mode is the one `still` was decided in, asked
    /// again after the hand-back: a leave decided in the foreground and
    /// made behind a hand-back in which the foreground ended records no
    /// eviction its preflight staged.
    ///
    /// # Errors
    ///
    /// As [`Self::send_leave`], and [`NostrError::EngineHeld`].
    pub(crate) async fn leave_group_staging(
        &self,
        group_id: &GroupId,
        now_ms: u64,
        still: Still<'_>,
    ) -> Result<Option<Staged>> {
        let mut session = self.engine().await?;
        let whole = still.holds() && still.decided() == DriveMode::Full;
        let ahead = Box::pin(self.hand_back_stranded(&mut session, Some(group_id), whole)).await?;
        let mode = if still.holds() {
            still.decided()
        } else {
            DriveMode::FinishOnly
        };
        let result = Self::send_leave(&mut session, group_id).await;
        let result = match self.noted(&session, result) {
            Ok(Some(effects)) => {
                #[cfg(any(test, feature = "test-utils"))]
                let effects = self.beside_stranded_for_test(effects);
                self.take_back_queued_leave(&mut session, group_id, &effects);
                let effects = chain_effects(ahead, effects);
                Ok(Some(
                    self.stage_commits(&mut session, effects, now_ms, None, false, mode)
                        .await,
                ))
            }
            other => {
                self.keep_handed_back(ahead);
                other.map(|_| None)
            }
        };
        drop(session);
        result
    }

    /// Replaces the group's Nostr routing relay set (keeps the existing
    /// `nostr_group_id`) via an `UpdateAppComponents` commit.
    ///
    /// # Errors
    ///
    /// Returns an error if the group has no routing component, the relay set is
    /// invalid, or the caller is not an admin.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn update_relays(
        &self,
        group_id: &GroupId,
        relays: Vec<String>,
    ) -> Result<SessionEffects> {
        self.send(self.relay_update_intent(group_id, relays).await?)
            .await
    }

    async fn relay_update_intent(
        &self,
        group_id: &GroupId,
        relays: Vec<String>,
    ) -> Result<SendIntent> {
        let (nostr_group_id, _current) = self.group_routing(group_id).await?;
        let routing = routing_of(nostr_group_id, relays)?;
        let routing_bytes = encode_nostr_routing_v1(&routing)
            .map_err(|_| NostrError::InvalidEvent("routing encode failed".to_string()))?;
        Ok(SendIntent::UpdateAppComponents {
            group_id: group_id.clone(),
            updates: vec![AppComponentData {
                component_id: NOSTR_ROUTING_COMPONENT_ID,
                data: routing_bytes,
            }],
        })
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
    /// [`epoch_state_refusal`]), or a redacted MLS error if the engine rejects
    /// the commit for any other reason.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn update_admin_policy(
        &self,
        group_id: &GroupId,
        admins: &[[u8; 32]],
    ) -> Result<SessionEffects> {
        let data = encode_admin_policy_v1(admins)?;
        let mut session = self.engine().await?;
        let result = match self.send_admin_policy(&mut session, group_id, data).await {
            Ok(effects) => Ok(self.unstaged_beside_a_fanout(&mut session, effects).await),
            Err(e) => Err(e),
        };
        drop(session);
        result
    }

    /// The epoch-rotation repair (`CircleManager::repair_epoch_rotation_staging`):
    /// a self-update of this device's leaf, in staging mode. The mode is the
    /// one `still` was decided in, asked again after the hand-back: a repair
    /// decided in the foreground and made behind a hand-back in which the
    /// foreground ended records no commit.
    ///
    /// A mark is kept beside the circle for as long as the hold lasts, so a
    /// process that dies between the engine's staging and the record's write
    /// leaves the next open able to tell the user their repair was undone
    /// ([`settle_fanouts_before_open`]); a post-join self-update writes none,
    /// because nobody asked for it.
    ///
    /// # Errors
    ///
    /// As [`Self::send_self_update_now`] and [`Self::send_staging`];
    /// [`NostrError::StorageError`] when the mark cannot be written, with
    /// nothing asked of the engine.
    pub(crate) async fn repair_self_update_staging(
        &self,
        group_id: &GroupId,
        now_ms: u64,
        still: Still<'_>,
    ) -> Result<Staged> {
        let mut session = self.engine().await?;
        let whole = still.holds() && still.decided() == DriveMode::Full;
        let ahead = Box::pin(self.hand_back_stranded(&mut session, Some(group_id), whole)).await?;
        let mode = if still.holds() {
            still.decided()
        } else {
            DriveMode::FinishOnly
        };
        if !self.commit_notes.mark_repair(group_id, true) {
            self.keep_handed_back(ahead);
            drop(session);
            return Err(NostrError::StorageError(UNNOTED.to_owned()));
        }
        let before = self.roster_before(&session, group_id);
        let result = self.send_self_update_now(&mut session, group_id).await;
        let result = self.behind_what_was_handed_back(ahead, result);
        let staged = self
            .staged(&mut session, result, now_ms, before.as_ref(), false, mode)
            .await;
        // Recorded, refused or undone, the commit is past the window the
        // mark covers.
        self.commit_notes.mark_repair(group_id, false);
        drop(session);
        staged
    }

    /// The self-update MDK's post-join obligation owes
    /// ([`Self::post_join_due`]), in staging mode, with none of the repair's
    /// gates and no rate limit charged. Only a full drive makes it
    /// (`Publishing::resume`).
    ///
    /// # Errors
    ///
    /// As [`Self::send_self_update_now`] and [`Self::send_staging`].
    pub(crate) async fn post_join_self_update_staging(
        &self,
        group_id: &GroupId,
        now_ms: u64,
        still: Still<'_>,
    ) -> Result<Staged> {
        let mut session = self.engine().await?;
        let whole = still.holds() && still.decided() == DriveMode::Full;
        let ahead = Box::pin(self.hand_back_stranded(&mut session, Some(group_id), whole)).await?;
        let mode = if still.holds() {
            still.decided()
        } else {
            DriveMode::FinishOnly
        };
        let before = self.roster_before(&session, group_id);
        let result = self.send_self_update_now(&mut session, group_id).await;
        let result = self.behind_what_was_handed_back(ahead, result);
        let staged = self
            .staged(&mut session, result, now_ms, before.as_ref(), false, mode)
            .await;
        drop(session);
        staged
    }

    /// Asks the engine for a self-update of `group_id`: the one construction
    /// of [`SendIntent::SelfUpdate`] in shipped code.
    ///
    /// MDK QUEUES a self-update it cannot make now — a stable circle whose
    /// convergence advance is pending or out of budget
    /// (`cgka-engine/src/message_processor/mod.rs` 1219-1231) — and a later
    /// full advance drains it with none of Haven's gates, as a self-update no
    /// user asked for and no obligation owes. So one the engine queued is
    /// retired here, under the same guard as the send, through the engine's
    /// own delete-by-id; the batch keeps its queued refs so the caller can
    /// tell that nothing was made. What else the send staged — an eviction
    /// due ahead of it — is the caller's to record.
    ///
    /// # Errors
    ///
    /// [`NostrError::EpochNotStable`] when the circle will not take a staged
    /// commit now (a transient state, or a pending record of another commit),
    /// [`NostrError::EpochUnrecoverable`] for the terminal state, or a
    /// redacted MLS error.
    async fn send_self_update_now(
        &self,
        session: &mut AccountDeviceSession,
        group_id: &GroupId,
    ) -> Result<SessionEffects> {
        if let Some(refusal) = epoch_state_refusal(session.epoch_state(group_id).as_ref()) {
            return Err(refusal);
        }
        if Self::blocked_by_unheld_fanout(session, group_id) {
            return Err(NostrError::EpochNotStable);
        }
        #[cfg(any(test, feature = "test-utils"))]
        self.self_update_asks.fetch_add(1, Ordering::SeqCst);
        let result = session
            .send(SendIntent::SelfUpdate {
                group_id: group_id.clone(),
            })
            .await
            .map_err(|e| match e {
                SessionError::Engine(EngineError::GroupUnrecoverableRepairRequired { .. }) => {
                    NostrError::EpochUnrecoverable
                }
                SessionError::Engine(EngineError::InvalidTransition(_)) => {
                    NostrError::EpochNotStable
                }
                other => map_mls_err(other),
            });
        let result = self.noted(session, result);
        if result.as_ref().is_ok_and(|effects| {
            effects
                .queued
                .iter()
                .any(|queued| &queued.group_id == group_id)
        }) {
            self.retire_queued_self_updates(session, group_id);
        }
        result
    }

    /// Retires every self-update of `group_id` the engine holds queued,
    /// through its own delete-by-id (`confirm_regenerated_queued_intent`,
    /// which deletes the stored row: `cgka-engine/src/message_processor/mod.rs`
    /// 1287-1297). Says whether none is left: a queue that cannot be read, or
    /// a row that cannot be deleted, leaves the answer `false`, and the caller
    /// makes no advance that would drain it.
    fn retire_queued_self_updates(
        &self,
        session: &mut AccountDeviceSession,
        group_id: &GroupId,
    ) -> bool {
        let Ok(queue) = self.message_store.list_queued_outbound_intents(group_id) else {
            return false;
        };
        let mut none_left = true;
        for queued in queue {
            if !matches!(queued.intent, SendIntent::SelfUpdate { .. }) {
                continue;
            }
            let retired = session.confirm_regenerated_queued_intent(&QueuedIntentRef {
                group_id: queued.group_id.clone(),
                intent_id: queued.id,
            });
            if let Err(e) = retired {
                log::warn!(
                    "[Fanout] a self-update the engine queued was not retired, and no \
                     advance that would make it runs: {}",
                    e.kind()
                );
                none_left = false;
            }
        }
        none_left
    }

    /// [`Self::update_admin_policy`] in staging mode, for a change of the
    /// circle's admins: `None`, with nothing staged, when they are already
    /// `admins`, read in this hold. MDK stages a policy naming the admins the
    /// circle has all the same, so a hand-over or a step-down a stale plan
    /// asks for again would put a commit for nothing on the wire. The mode is
    /// the one `still` was decided in, asked again after the hand-back.
    ///
    /// # Errors
    ///
    /// As [`Self::update_admin_policy`] and [`Self::send_staging`].
    pub(crate) async fn change_admin_policy_staging(
        &self,
        group_id: &GroupId,
        admins: &[[u8; 32]],
        now_ms: u64,
        still: Still<'_>,
    ) -> Result<Option<Staged>> {
        let data = encode_admin_policy_v1(admins)?;
        let mut session = self.engine().await?;
        let whole = still.holds() && still.decided() == DriveMode::Full;
        let ahead = Box::pin(self.hand_back_stranded(&mut session, Some(group_id), whole)).await?;
        let mode = if still.holds() {
            still.decided()
        } else {
            DriveMode::FinishOnly
        };
        let wanted: BTreeSet<&[u8; 32]> = admins.iter().collect();
        if session
            .admin_pubkeys(group_id)
            .is_ok_and(|held| held.iter().collect::<BTreeSet<_>>() == wanted)
        {
            self.keep_handed_back(ahead);
            drop(session);
            return Ok(None);
        }
        let before = self.roster_before(&session, group_id);
        let result = self
            .send_admin_policy_now(&mut session, group_id, data)
            .await;
        let result = self.behind_what_was_handed_back(ahead, result);
        let staged = self
            .staged(&mut session, result, now_ms, before.as_ref(), false, mode)
            .await;
        drop(session);
        staged.map(Some)
    }

    /// Not [`Self::send`]: the epoch-rotation repair needs to tell "the group
    /// is busy, try later" from "this failed", so the state is read first,
    /// under the same lock as the send. Its preflight can stage a due
    /// eviction like any send's: each caller disposes of that in this hold —
    /// the legacy two through [`Self::unstaged_beside_a_fanout`], the staging
    /// one through [`Self::stage_commits`].
    #[cfg(any(test, feature = "test-utils"))]
    async fn send_admin_policy(
        &self,
        session: &mut AccountDeviceSession,
        group_id: &GroupId,
        data: Vec<u8>,
    ) -> Result<SessionEffects> {
        let ahead = Box::pin(self.hand_back_stranded(session, Some(group_id), true)).await?;
        let result = self.send_admin_policy_now(session, group_id, data).await;
        self.behind_what_was_handed_back(ahead, result)
    }

    /// [`Self::send_admin_policy`] once the circle's stranded input has been
    /// handed back.
    async fn send_admin_policy_now(
        &self,
        session: &mut AccountDeviceSession,
        group_id: &GroupId,
        data: Vec<u8>,
    ) -> Result<SessionEffects> {
        if let Some(refusal) = epoch_state_refusal(session.epoch_state(group_id).as_ref()) {
            return Err(refusal);
        }
        if Self::blocked_by_unheld_fanout(session, group_id) {
            return Err(NostrError::EpochNotStable);
        }
        let result = session
            .send(SendIntent::UpdateAppComponents {
                group_id: group_id.clone(),
                updates: vec![AppComponentData {
                    component_id: GROUP_ADMIN_POLICY_COMPONENT_ID,
                    data,
                }],
            })
            .await
            .map_err(|e| match e {
                SessionError::Engine(EngineError::GroupUnrecoverableRepairRequired { .. }) => {
                    NostrError::EpochUnrecoverable
                }
                other => map_mls_err(other),
            });
        self.noted(session, result)
    }

    /// Low-level passthrough to `session.send`.
    ///
    /// # Errors
    ///
    /// Returns any engine error, redacted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn send(&self, intent: SendIntent) -> Result<SessionEffects> {
        self.send_inner(intent).await
    }

    /// Retires each change the engine has just queued in `effects`.
    ///
    /// A change of the group left queued holds its circle still on every
    /// plane that does not make the engine's full advance: once the circle's
    /// convergence pass has closed, the engine opens no other until that
    /// change has had its one attempt
    /// (`cgka-engine/src/distributed_convergence.rs` 728-745, the spec's
    /// `protocol-core/convergence.md` 140-149), and until then the device
    /// applies no commit it receives and seals at the epoch it stands on. A
    /// caller that reports the change as failed will not come back to make
    /// that attempt — the user asks again — so the queue's copy goes in the
    /// same hold, through the engine's own delete-by-id.
    ///
    /// A take-back the store refuses leaves the change queued behind an
    /// answer that said it was not made: its circle is told so durably
    /// ([`ChangeNote::QueuedChangesHeld`]), and the next open retires it
    /// ([`retire_queued_group_changes`]).
    fn take_back_queued(&self, session: &mut AccountDeviceSession, effects: &SessionEffects) {
        for queued in &effects.queued {
            if let Err(e) = session.confirm_regenerated_queued_intent(queued) {
                let _ = self
                    .commit_notes
                    .note(&queued.group_id, ChangeNote::QueuedChangesHeld);
                log::warn!(
                    "[Fanout] a change reported as not made is still queued, and its circle \
                     applies nothing it receives until a full advance: {}",
                    e.kind()
                );
            }
        }
    }

    /// Takes a leave the engine QUEUED back out of the queue in the hold
    /// that queued it: its drain would later mint the proposal outside any
    /// record, in whatever hold drains it. The intent stands, and
    /// `resume_leave` proposes once the circle is stable.
    fn take_back_queued_leave(
        &self,
        session: &mut AccountDeviceSession,
        group_id: &GroupId,
        effects: &SessionEffects,
    ) {
        let leave = SessionEffects {
            queued: effects
                .queued
                .iter()
                .filter(|queued| &queued.group_id == group_id)
                .cloned()
                .collect(),
            ..empty_effects()
        };
        self.take_back_queued(session, &leave);
    }

    #[cfg(any(test, feature = "test-utils"))]
    async fn send_inner(&self, intent: SendIntent) -> Result<SessionEffects> {
        let mut session = self.engine().await?;
        if group_change_of(&intent)
            .is_some_and(|group_id| Self::blocked_by_unheld_fanout(&session, group_id))
        {
            return Err(NostrError::EpochNotStable);
        }
        let sealing_for = match &intent {
            SendIntent::AppMessage { group_id, .. } => Some(group_id.clone()),
            _ => None,
        };
        if sealing_for
            .as_ref()
            .is_some_and(|group_id| self.leaving(group_id))
        {
            return Err(NostrError::LeaveInProgress);
        }
        let ahead =
            Box::pin(self.hand_back_stranded(&mut session, Some(intent_group(&intent)), true))
                .await?;
        // Read again with nothing awaited before the seal: a leave asked for
        // while the hand-back ran holds this send too.
        if sealing_for
            .as_ref()
            .is_some_and(|group_id| self.leaving(group_id))
        {
            self.keep_handed_back(ahead);
            return Err(NostrError::LeaveInProgress);
        }
        let result = match Box::pin(session.send(intent)).await {
            Err(SessionError::Engine(EngineError::Backend(_)))
                if sealing_for
                    .as_ref()
                    .is_some_and(|group_id| self.departure_blocks_sends(&session, group_id)) =>
            {
                Err(NostrError::SendBlockedByDeparture)
            }
            sent => sent.map_err(map_mls_err),
        };
        // A location send's or a leave's preflight can stage a due eviction,
        // and it runs a convergence pass first only when one is already
        // open (`cgka-engine/src/message_processor/mod.rs` 1515, 1231).
        let result = self.noted(&session, result);
        let result = match self.behind_what_was_handed_back(ahead, result) {
            Ok(effects) => Ok(self.unstaged_beside_a_fanout(&mut session, effects).await),
            Err(e) => Err(e),
        };
        drop(session);
        result
    }

    /// Says where the live plane that shares this session stands. While it
    /// is anything but a claimed foreground — or there is none — what a
    /// circle was left waiting for holds its sends
    /// ([`Self::away_from_the_foreground`]), and a bridge call may not make
    /// a commit on its caller's word ([`Self::bridge_may_commit`]).
    ///
    /// The live plane's alone to write. `plane` numbers the planes in the
    /// order they were made, and an older one's word counts for nothing once
    /// a newer one has spoken: a plane that is let go late — a worker still
    /// holding it — must not lower the hold of the burst that has replaced
    /// it.
    pub(crate) fn plane_stands(&self, plane: u64, standing: PlaneStanding) {
        let _ = self
            .live_plane
            .try_update(Ordering::SeqCst, Ordering::SeqCst, |current| {
                (plane >= current >> 2).then_some(plane << 2 | standing as u64)
            });
    }

    /// Says that `plane`, only started until now, has been claimed for the
    /// foreground — and only if "only started" is still the last word it
    /// gave: a pause or a stop that has overtaken the claim stands.
    pub(crate) fn plane_claimed(&self, plane: u64) {
        let _ = self.live_plane.compare_exchange(
            plane << 2 | PlaneStanding::Launched as u64,
            plane << 2 | PlaneStanding::Foreground as u64,
            Ordering::SeqCst,
            Ordering::SeqCst,
        );
    }

    /// Says when the live plane `plane`'s burst ends, or that it is in none
    /// with a measured end. As [`Self::plane_stands`], an older plane's word
    /// counts for nothing once a newer one has spoken.
    pub(crate) fn burst_ends(&self, plane: u64, ends: Option<crate::relay::fanout::BurstEnd>) {
        let mut slot = self
            .burst_end
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if plane >= self.live_plane.load(Ordering::SeqCst) >> 2 {
            *slot = ends;
        }
    }

    /// When the live plane's current burst ends, if its opener measured it.
    pub(crate) fn burst_end(&self) -> Option<crate::relay::fanout::BurstEnd> {
        *self
            .burst_end
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Whether the burst under way has a measured end.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn burst_bounded(&self) -> bool {
        self.burst_end().is_some()
    }

    fn plane_standing(&self) -> u64 {
        self.live_plane.load(Ordering::SeqCst) & 3
    }

    /// Whether the live plane sharing this session makes no commit
    /// ([`Self::plane_stands`]) or has been claimed by nobody — a session only
    /// started, which a background wake that cold-launched the process also
    /// is.
    pub(crate) fn beside_a_plane_that_makes_none(&self) -> bool {
        let plane = self.plane_standing();
        plane == PlaneStanding::MakesNone as u64 || plane == PlaneStanding::Launched as u64
    }

    /// Whether a bridge call may make commits on its caller's word
    /// ([`crate::relay::fanout::Claimed`]): in a process with no live plane,
    /// where that word is all there is, or beside a live plane a claim has put
    /// in the foreground. Beside a plane only started, in a burst or a pause,
    /// the plane's own lifecycle decides and the word cannot widen it.
    pub(crate) fn bridge_may_commit(&self) -> bool {
        let plane = self.plane_standing();
        plane == PlaneStanding::Gone as u64 || plane == PlaneStanding::Foreground as u64
    }

    /// Whether this device asked to leave `group_id`: from the instant the
    /// intent is written, nothing is sealed or sent for the circle on any
    /// plane, whatever else is pending. A store that cannot say is read as
    /// "it did".
    pub(crate) fn leaving(&self, group_id: &GroupId) -> bool {
        self.commit_notes.leaving(group_id).unwrap_or(true)
    }

    /// Whether no claimed foreground stands behind this session: its live
    /// plane is in a burst, paused, or only started — which a background
    /// wake that cold-launched the process also is — or it has none. A call
    /// made then reads what a circle was left waiting for
    /// ([`Self::held_away`]).
    ///
    /// A process with no live plane says nothing about whether it is in
    /// front of its user, and on Android the one that shares in the
    /// background is such a process: the absence of a claim is read as its
    /// absence, never as a claim.
    pub(crate) fn away_from_the_foreground(&self) -> bool {
        let plane = self.plane_standing();
        plane != PlaneStanding::Foreground as u64
            && !(plane == PlaneStanding::Gone as u64
                && self.bridge_claims.load(Ordering::SeqCst) > 0)
    }

    /// Counts a bridge call whose caller says the app is in front of its
    /// user, in a process with no live plane — the flag-off configuration —
    /// where nothing else could claim it: until [`Self::release_claim`] the
    /// session reads as the foreground's. Android's background service passes
    /// no claim. Returns whether it was counted.
    pub(crate) fn count_bridge_claim(&self) -> bool {
        if self.plane_standing() != PlaneStanding::Gone as u64 {
            return false;
        }
        self.bridge_claims.fetch_add(1, Ordering::SeqCst);
        true
    }

    /// Ends a claim [`Self::count_bridge_claim`] counted.
    pub(crate) fn release_claim(&self) {
        let _ = self
            .bridge_claims
            .try_update(Ordering::SeqCst, Ordering::SeqCst, |held| {
                held.checked_sub(1)
            });
    }

    /// What holds `group_id`'s sends for a call in `mode`, read with the
    /// engine held ([`AwayHold`]).
    fn away_hold(
        &self,
        session: &AccountDeviceSession,
        group_id: &GroupId,
        mode: DriveMode,
    ) -> Option<AwayHold> {
        match self.stored_hold(group_id, mode) {
            StoredHold::Held(held) => return Some(held),
            StoredHold::Clear => return None,
            StoredHold::AskTheRoster => {}
        }
        // Decision 238: a member the user asked to remove reads nothing
        // sealed after the ask, so this one holds the foreground too.
        if removal_unmade(
            &self.message_store,
            self.commit_notes.as_ref(),
            session,
            group_id,
        ) {
            return Some(AwayHold::RemovalUnmade);
        }
        self.relay_change_hold(group_id, mode)
    }

    /// [`Self::away_hold`] as far as the circle store alone answers it, the
    /// one place a send that skips the engine may read.
    fn stored_hold(&self, group_id: &GroupId, mode: DriveMode) -> StoredHold {
        if self.leaving(group_id) {
            return StoredHold::Held(AwayHold::Leaving);
        }
        // Decision 250: a store that cannot say holds too.
        if self.routing_collided(group_id) {
            return StoredHold::Held(AwayHold::RoutingCollision);
        }
        if !self
            .commit_notes
            .removal_targets(group_id)
            .is_some_and(|kept| kept.is_empty())
        {
            return StoredHold::AskTheRoster;
        }
        self.relay_change_hold(group_id, mode)
            .map_or(StoredHold::Clear, StoredHold::Held)
    }

    /// Whether `group_id`'s routing id is another circle's on this device
    /// too ([`ChangeNote::RoutingCollision`]); a store that cannot say reads
    /// as yes.
    pub(crate) fn routing_collided(&self, group_id: &GroupId) -> bool {
        self.commit_notes
            .stands(group_id, ChangeNote::RoutingCollision)
            != Some(false)
    }

    /// The hold a change of relays applied away puts on every call but a
    /// claimed foreground's full one.
    fn relay_change_hold(&self, group_id: &GroupId, mode: DriveMode) -> Option<AwayHold> {
        if mode == DriveMode::Full && !self.away_from_the_foreground() {
            return None;
        }
        self.awaits_foreground(group_id)
            .then_some(AwayHold::RelayChange)
    }

    /// What holds `group_id`'s sends for a call in `mode`: a leave, or a
    /// removal the user asked for set aside or dropped unmade with a member
    /// it named still listed ([`ChangeNote::QueuedRemovalDropped`]), for
    /// every call; and for a call that is not a claimed foreground's full
    /// one, a change of its relays applied while the app was away
    /// ([`ChangeNote::AwaitsForeground`]).
    pub(crate) async fn held_away(&self, group_id: &GroupId, mode: DriveMode) -> Option<AwayHold> {
        let session = self.reading().await;
        let held = self.away_hold(&session, group_id, mode);
        drop(session);
        held
    }

    /// What a location send is answered with while its circle may not make
    /// the removal of a member who left: `None` when nothing stands in the
    /// send's way, else what an inputs-only advance handed back and whether
    /// the send must not be made.
    ///
    /// The engine stages a due eviction in the preflight of every send
    /// (`cgka-engine/src/message_processor/mod.rs` 1231) and queues the send
    /// behind it. Inside the wait a refusal earned
    /// ([`Self::restaging_held`]) that eviction is not this device's to send,
    /// and staging it only to undo it — at every publish tick — would open,
    /// each time, the four writes a process death can land between
    /// (`docs/MDK_UPSTREAM_TRACKER.md` T-KILL-WINDOW) and leave one more
    /// retired commit row. So the send is not made at all: what the circle
    /// has received is settled by MDK's inputs-only advance, which stages
    /// nothing (`cgka-session/src/lib.rs` 1053-1062), and while the wait
    /// still runs and the engine still announces the eviction the send is
    /// answered as deferred. A hold whose mode makes no new commit does the
    /// same once the eviction is due — and only while the departure still
    /// stands ([`departure_stands`]): the engine goes on announcing a
    /// departure another member has already committed until something makes
    /// it look, which nothing in such a hold does. And no call makes a send
    /// for a circle held as [`Self::held_away`] says, so a circle still
    /// keeping a dropped removal's targets never takes the fast way out.
    /// That costs a send one engine hold more only while a target is held:
    /// a removal answered as already so keeps its members as taken out,
    /// which `removal_targets` does not read, and the first send that finds
    /// a held target off a stable, applied roster takes it out again.
    ///
    /// `now_ms` is the caller's clock; `None` for a hold that has none. The
    /// mode is the one `still` was decided in, asked again after the
    /// hand-back: a send that may go ahead in the foreground does not once
    /// the foreground has ended in it.
    ///
    /// # Errors
    ///
    /// Returns the inputs-only advance's error, redacted.
    pub(crate) async fn departure_holds_a_send(
        &self,
        group_id: &GroupId,
        now_ms: Option<u64>,
        still: Still<'_>,
    ) -> Result<Option<(SessionEffects, bool)>> {
        let now_ms = now_ms.unwrap_or_else(|| self.legacy_now_ms());
        let whole = still.holds() && still.decided() == DriveMode::Full;
        if whole
            && !self.away_from_the_foreground()
            && !self.refusal_stands(group_id)
            && matches!(
                self.stored_hold(group_id, DriveMode::Full),
                StoredHold::Clear
            )
        {
            return Ok(None);
        }
        let mut session = self.engine().await?;
        let ahead = Box::pin(self.hand_back_stranded(&mut session, Some(group_id), whole)).await?;
        let mode = if still.holds() {
            still.decided()
        } else {
            DriveMode::FinishOnly
        };
        let makes_none = mode == DriveMode::FinishOnly;
        if self.away_hold(&session, group_id, mode).is_some() {
            return Ok(Some((ahead, true)));
        }
        if !makes_none && !self.refusal_stands(group_id) {
            self.keep_handed_back(ahead);
            return Ok(None);
        }
        if !self.restage_wait_runs(group_id, now_ms)
            && !matches!(
                session.scheduled_self_remove_auto_commit_delay_ms(group_id),
                Ok(Some(_))
            )
        {
            self.keep_handed_back(ahead);
            return Ok(None);
        }
        let advanced = Box::pin(session.advance_convergence_inputs(group_id))
            .await
            .map_err(map_mls_err);
        let advanced = self.noted(&session, advanced);
        let effects = self.behind_what_was_handed_back(ahead, advanced)?;
        let effects = self.unstaged_beside_a_fanout(&mut session, effects).await;
        // Read again: the advance may have moved the epoch, which ends both
        // the wait and the departure it was for.
        let held = departure_held(
            session
                .scheduled_self_remove_auto_commit_delay_ms(group_id)
                .ok()
                .flatten(),
            self.restage_wait_runs(group_id, now_ms),
            self.refusal_stands(group_id),
            makes_none,
            || self.departure_stands(group_id),
        );
        drop(session);
        Ok(Some((effects, held)))
    }

    /// Whether a departure may still be to be committed in `group_id`
    /// ([`proposal_stands`]). A store that cannot say is read as "it
    /// stands": nothing is sealed for a member who may still hold the
    /// epoch's keys.
    fn departure_stands(&self, group_id: &GroupId) -> bool {
        #[cfg(any(test, feature = "test-utils"))]
        let cap = self.proposal_scan_cap.load(Ordering::SeqCst);
        #[cfg(not(any(test, feature = "test-utils")))]
        let cap = PROPOSAL_SCAN_CAP;
        let stands = proposal_stands(&self.message_store, group_id, cap).ok();
        #[cfg(any(test, feature = "test-utils"))]
        let stands = self.unless_faulted(StoreFault::Departure, stands);
        stands.unwrap_or(true)
    }

    /// Whether a send the engine has just refused outright was refused in a
    /// circle that is stable, has no commit awaiting relays, and holds a
    /// departure nobody has committed.
    ///
    /// That is what a circle looks like after a kill inside the engine's
    /// staging of an eviction, between `OpenMLS` storing the leaver's
    /// proposal and the commit's own row being written
    /// (`cgka-engine/src/message_processor/ingest.rs` 2253-2298): the
    /// proposal stays in `OpenMLS`'s store, which then refuses to seal
    /// (`openmls` `group/mls_group/application.rs` 92-94), nothing stages the
    /// eviction again (`ingest.rs` 2245-2248), and nothing stored names the
    /// state (`docs/MDK_UPSTREAM_TRACKER.md` T-KILL-WINDOW). The engine's
    /// error for it is a backend failure with prose; no kind says which. So
    /// these three facts are what is read, and they are not a proof: any
    /// other backend refusal of a send while a departure is unresolved reads
    /// the same.
    fn departure_blocks_sends(&self, session: &AccountDeviceSession, group_id: &GroupId) -> bool {
        matches!(
            session.epoch_state(group_id),
            Some(EpochState::Stable { .. })
        ) && !Self::has_pending_record(session, group_id)
            && pending_proposal_in_window(&self.message_store, group_id).unwrap_or(false)
    }

    // ── Messaging ────────────────────────────────────────────────────────────

    /// Encrypts and prepares an inner application message (a location update)
    /// for a group. Test builds only: its kind 445 has no record, and a shipped
    /// send is sealed under one (`send_location_staging`, Security Rule 13).
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
    #[cfg(any(test, feature = "test-utils"))]
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
        self.send_inner(SendIntent::AppMessage {
            group_id: group_id.clone(),
            payload,
            expected_epoch: None,
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
    #[cfg(any(test, feature = "test-utils"))]
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
    ///
    /// Private: every caller goes through the screen ([`Self::process_event`]),
    /// because the engine joins any Welcome it is handed.
    async fn ingest(
        &self,
        event: &Event,
        msg: cgka_traits::transport::TransportMessage,
    ) -> Result<IngestEffects> {
        let mut session = self.engine().await?;
        let first = self.flagged_circle_of(&session, &msg);
        let ahead = Box::pin(self.hand_back_stranded(&mut session, first.as_ref(), true)).await?;
        let id = msg.id.clone();
        let route = transport_route(&msg);
        // Boxed: MDK v0.10.4's engine futures are ~16 KB, and every receive
        // plane awaits them inside its own (`clippy::large_futures`).
        let result = Box::pin(session.ingest(msg)).await.map_err(map_mls_err);
        let result = self.ingest_faulted(result);
        self.note_ingested(&session, event, route, &id, &result, false);
        let result = self.noted(&session, result);
        let mut result = self.behind_what_was_handed_back(ahead, result);
        if let Ok(ingested) = &mut result {
            let effects = std::mem::replace(&mut ingested.effects, empty_effects());
            ingested.effects = self.unstaged_beside_a_fanout(&mut session, effects).await;
        }
        drop(session);
        result
    }

    /// Screens a signed Nostr event against Haven's local receiver-side policy
    /// and, if it passes, converts it to a transport message and ingests it.
    ///
    /// Returns a [`ScreenedIngest`], which keeps the two dispositions apart at
    /// the type level — see that type for why the distinction cannot be folded
    /// into [`super::types::IngestOutcome`].
    ///
    /// # The one local screen, and the one Haven does not run
    ///
    /// The pure transport parse runs before the engine and reports
    /// [`ScreenedIngest::RejectedBeforeAuth`] (see the comment at that call for
    /// why an unparseable envelope is a *pre-authentication* judgement and what
    /// skipping it costs).
    ///
    /// The NIP-40 `expiration` tag is NOT a screen. Receivers must not judge
    /// validity, ordering or branch selection by it (Marmot
    /// `transports/nostr.md:190-192`), and it is untrusted until the event is
    /// authenticated (`:59-61`): a member can stamp a past `expiration` on a
    /// genuine commit every conformant peer applies, and application messages
    /// are witnesses in branch selection (`protocol-core/convergence.md`), so a
    /// device that dropped them could stall or pick a different branch.
    /// Staleness is judged in presentation, on the MLS-authenticated inner
    /// timestamp. `nostr-relay-pool` still drops an already-expired event before
    /// any subscriber sees it, by the local clock
    /// (`docs/MDK_UPSTREAM_TRACKER.md` T-NIP40-POOL).
    ///
    /// # The screen runs BEFORE authentication — the cursor contract
    ///
    /// A rejected event has had NOTHING verified: not its signature, not its
    /// ephemeral author, not its ciphertext, not its membership in the group it
    /// claims. Routing is by the `h` tag, which is the *public*
    /// `nostr_group_id` — any observer of one of a circle's kind-445s can mint a
    /// matching event with a `created_at` of its choosing.
    ///
    /// A caller therefore MUST treat [`ScreenedIngest::RejectedBeforeAuth`] as
    /// "learned nothing about this event": no routing, no persistence, no
    /// convergence drain, and above all **no sync-cursor advance** — and no
    /// hold-back either. (Before DM-6 a local drop reported a synthetic `Stale`,
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
            Ok(msg) => self.ingest(event, msg).await.map(ScreenedIngest::Ingested),
        }
    }

    /// [`Self::process_event`] in staging mode: every commit and every bare
    /// proposal the ingest hands back gets its record in the hold that took
    /// the event, and comes back as a handle beside the screened ingest. In
    /// [`DriveMode::FinishOnly`] no commit is recorded: see
    /// [`Self::stage_commits`]. The mode is the one `still` was decided in,
    /// asked again after the hand-back: an ingest decided in the foreground
    /// and made behind a hand-back in which the foreground ended records no
    /// commit.
    ///
    /// # Errors
    ///
    /// As [`Self::process_event`].
    pub(crate) async fn process_event_staging(
        &self,
        event: &Event,
        now_ms: u64,
        still: Still<'_>,
    ) -> Result<(ScreenedIngest, Vec<FanoutId>)> {
        self.staging_ingest(event, now_ms, still, false).await
    }

    /// [`Self::process_event_staging`], for a relay's event or, with
    /// `from_mesh`, for one a mesh packet carried. What a relay is asked next
    /// may not turn on what the mesh brought, so such an event is noted
    /// nowhere the relay path reads what it has seen: not in the NIP-77
    /// pass's memory, which a relay's own copy enters when it comes, and not
    /// in the refused ledger.
    async fn staging_ingest(
        &self,
        event: &Event,
        now_ms: u64,
        still: Still<'_>,
        from_mesh: bool,
    ) -> Result<(ScreenedIngest, Vec<FanoutId>)> {
        let msg = match Self::screen_before_auth(event) {
            Err(rejection) => {
                return Ok((ScreenedIngest::RejectedBeforeAuth(rejection), Vec::new()))
            }
            Ok(msg) => msg,
        };
        let mut session = self.engine().await?;
        let first = self.flagged_circle_of(&session, &msg);
        let whole = still.holds() && still.decided() == DriveMode::Full;
        let ahead = Box::pin(self.hand_back_stranded(&mut session, first.as_ref(), whole)).await?;
        let mode = if still.holds() {
            still.decided()
        } else {
            DriveMode::FinishOnly
        };
        let id = msg.id.clone();
        let route = transport_route(&msg);
        let result = Box::pin(session.ingest(msg)).await.map_err(map_mls_err);
        let mut result = self.ingest_faulted(result);
        if from_mesh {
            // Owed no refetch when the engine lets it go: its packet is held
            // and offered again, and no relay is asked for it by id.
            if let Ok(batch) = &mut result {
                batch.effects.events.retain(|refused| {
                    !matches!(refused, GroupEvent::TransportObjectResourceRefused { message_id, .. }
                        if *message_id == id)
                });
            }
        } else {
            self.note_ingested(
                &session,
                event,
                route,
                &id,
                &result,
                mode == DriveMode::Full,
            );
        }
        let result = self.noted(&session, result);
        let mut ingested = self.behind_what_was_handed_back(ahead, result)?;
        let effects = std::mem::replace(&mut ingested.effects, empty_effects());
        #[cfg(any(test, feature = "test-utils"))]
        let effects = self.beside_stranded_for_test(effects);
        let staged = self
            .stage_commits(&mut session, effects, now_ms, None, true, mode)
            .await;
        drop(session);
        ingested.effects = staged.effects;
        let mut recorded = staged.fanouts;
        recorded.extend(staged.proposals);
        Ok((ScreenedIngest::Ingested(ingested), recorded))
    }

    /// One event a mesh packet carried, into the engine:
    /// [`Self::process_event_staging`] in the mode that makes nothing, and
    /// never in the full one. Nothing a mesh packet leads to is committed,
    /// and nothing the relay path reads of what it has seen is written
    /// ([`Self::staging_ingest`]). The stall detector never arms a history
    /// walk on it: only a full drive's ingest arms. A peer's update at the
    /// circle's epoch does end the count of fruitless walks behind the
    /// `Stalled` reading, as one a relay brought does
    /// ([`Self::note_stall_evidence`]) — this device read a peer — and that
    /// changes nothing a relay is asked: when a walk is armed, and how
    /// often, is left as it stands (`EpochStallDetector::observe_peer_heard`).
    /// A replayed packet ends nothing: the engine announces an update once.
    /// The caller has verified the event and found it an application message
    /// of an epoch this device holds the key of ([`Self::mesh_read`]).
    ///
    /// Returns whether the engine took the event in ([`Self::took_in`]),
    /// whether it read in it a peer's update it had not read before, that
    /// update as the engine announced it, and the rest of the hold's batch.
    /// The engine says the second, off its own durable records: it answers
    /// `Processed` for an application message it reads, and a duplicate or
    /// an own echo for one it holds a record of — by the event's id or, for
    /// the same update in another event, by a digest of what it carries —
    /// whether a relay brought it, the mesh did in an earlier process, or
    /// this device sent it (MDK `message_processor/ingest.rs` 937-970,
    /// `store.rs` `recorded_message_outcome`). A proposal the hold recorded
    /// keeps its stored record, which the next relay drive sends.
    ///
    /// The update is taken out of the batch, found by the digest it is
    /// announced under ([`Self::application_at`]): the rest is relay input
    /// the hold handed back, folded as any plane's, while the update is
    /// folded as one the mesh brought (`CircleManager::fold_mesh_update`).
    ///
    /// # Errors
    ///
    /// As [`Self::process_event`]; the event is then not taken in.
    pub(crate) async fn ingest_from_mesh(
        &self,
        group_id: &GroupId,
        event: &Event,
        now_ms: u64,
    ) -> Result<(bool, bool, Option<GroupEvent>, SessionEffects)> {
        self.mesh_ingesting();
        let content = self.mesh_content(group_id, event);
        let still = Still::always(&DriveMode::FinishOnly);
        let (screened, _) = self.staging_ingest(event, now_ms, still, true).await?;
        Ok(match screened {
            ScreenedIngest::Ingested(mut ingested) => {
                let kept = Self::kept(&ingested);
                #[cfg(any(test, feature = "test-utils"))]
                let kept = kept && !self.mesh_ingest_unkept_for_test();
                let new = matches!(ingested.outcome, IngestOutcome::Processed);
                let events = &mut ingested.effects.events;
                let update = (events.iter())
                    .position(|announced| {
                        matches!(announced, GroupEvent::MessageReceived { message_id, .. }
                            if new && content.is_some_and(|id| message_id.as_slice() == id))
                    })
                    .map(|at| events.remove(at));
                (kept, new, update, ingested.effects)
            }
            // Never taken in, however often it is offered.
            ScreenedIngest::RejectedBeforeAuth(_) => (true, false, None, empty_effects()),
        })
    }

    /// `events`, one circle's stored `kind:445`s, in the order the engine is
    /// to take them in, each with its [`IngestClass`]: ascending
    /// `(created_at, id)`, then every proposal at the circle's current epoch
    /// moved, keeping its order, ahead of the rest. MDK drops for good a
    /// commit it takes in before the proposal it commits
    /// (`docs/MDK_UPSTREAM_TRACKER.md` T-COMMIT-BEFORE-PROPOSAL), and a
    /// current-epoch proposal depends on nothing else in the batch.
    ///
    /// Fails open: when the circle's exporter cannot be read or the
    /// classification panics, `events` come back as given, every one
    /// [`IngestClass::Other`]; one that does not peel or parse is `Other` in
    /// its sorted place. Nothing is dropped and nothing is logged.
    pub(crate) async fn order_for_ingest(
        &self,
        group_id: &GroupId,
        events: Vec<Event>,
    ) -> Vec<(IngestClass, Event)> {
        let Some(classes) = self.classify_for_ingest(group_id, &events).await else {
            return events
                .into_iter()
                .map(|event| (IngestClass::Other, event))
                .collect();
        };
        let mut ordered: Vec<(IngestClass, Event)> = classes.into_iter().zip(events).collect();
        ordered.sort_by_key(|(_, event)| (event.created_at, event.id));
        ordered.sort_by_key(|(class, _)| *class != IngestClass::Proposal);
        ordered
    }

    /// The class of each of `events` at `group_id`'s current epoch, or `None`
    /// when the exporter cannot be read or a peel or parse panics.
    ///
    /// The exporter is read through the live session's read guard alone,
    /// dropped before any peel (Rule 14), and moved, never copied, into a
    /// snapshot dropped before this returns (Rule 7) — so before the first
    /// ingest of what it ordered. The label is the fixed one (Rule 11).
    async fn classify_for_ingest(
        &self,
        group_id: &GroupId,
        events: &[Event],
    ) -> Option<Vec<IngestClass>> {
        let (epoch, mut secret) = {
            let session = self.reading().await;
            session
                .exporter_secret_with_epoch(group_id, DEFAULT_EXPORTER_LABEL, 32)
                .ok()?
        };
        let mut secrets = HashMap::new();
        secrets.insert(
            DEFAULT_EXPORTER_LABEL.to_string(),
            std::mem::take(&mut *secret),
        );
        let ctx = GroupContextSnapshot::new(epoch, secrets, None);
        let classify = async {
            let mut classes = Vec::with_capacity(events.len());
            for event in events {
                classes.push(self.class_at(event, epoch.0, &ctx).await);
            }
            classes
        };
        futures::FutureExt::catch_unwind(std::panic::AssertUnwindSafe(classify))
            .await
            .ok()
    }

    /// What `event` is at `epoch`: only its kind and source epoch are read
    /// off the peeled MLS message, which is dropped at once.
    async fn class_at(&self, event: &Event, epoch: u64, ctx: &GroupContextSnapshot) -> IngestClass {
        #[cfg(any(test, feature = "test-utils"))]
        #[allow(clippy::manual_assert)]
        if event.content == ORDER_PANIC_FOR_TEST {
            panic!("injected classification panic (test seam)");
        }
        match self.projected(event, ctx).await {
            Some((kind, Some(source_epoch), _)) if source_epoch == epoch => match kind {
                OpenMlsContentKind::Proposal => IngestClass::Proposal,
                OpenMlsContentKind::Commit => IngestClass::Commit,
                OpenMlsContentKind::Application
                | OpenMlsContentKind::Welcome
                | OpenMlsContentKind::Other => IngestClass::Other,
            },
            _ => IngestClass::Other,
        }
    }

    /// The kind and source epoch of the MLS message `event` carries, peeled
    /// under `ctx`'s exporter secret and dropped at once, with the SHA-256
    /// of that message; `None` when it does not peel or parse.
    async fn projected(
        &self,
        event: &Event,
        ctx: &GroupContextSnapshot,
    ) -> Option<(OpenMlsContentKind, Option<u64>, [u8; 32])> {
        let msg = Self::event_to_transport_message(event).ok()?;
        let peeled = self.preview_peeler.peel_group_message(&msg, ctx).await;
        let PeeledContent::MlsMessage { bytes } = peeled.ok()?.content else {
            return None;
        };
        let projection = project_mls_message(&bytes).ok()?;
        let digest = <sha2::Sha256 as sha2::Digest>::digest(&bytes).into();
        Some((projection.kind, projection.source_epoch, digest))
    }

    /// Whether `event` is an application message of `epoch`, the epoch
    /// `exporter` is the group-event secret of: what the mesh ingress asks
    /// before the engine sees a packet's event (plan §4.3). A commit or a
    /// proposal a member wrapped is not one — taken in ahead of its proposal
    /// a commit is dropped for good (T-COMMIT-BEFORE-PROPOSAL) — and neither
    /// is a message of another epoch, which the engine would buffer without
    /// bound (Security Rule 12). One that does not peel or parse, or whose
    /// parse panics, is none.
    ///
    /// An application message is answered by the SHA-256 of the MLS message
    /// it carries: the id the engine announces the update under once it
    /// reads it, whatever event carried it (MDK `message_processor/mod.rs`
    /// `content_dedup_id`), and so how its own announcement is told from
    /// every other in the batch ([`Self::ingest_from_mesh`]).
    ///
    /// The secret is moved into a snapshot dropped before this returns
    /// (Rule 7), under the fixed label (Rule 11).
    async fn application_at(
        &self,
        event: &Event,
        epoch: u64,
        exporter: &[u8; 32],
    ) -> Option<[u8; 32]> {
        let mut secrets = HashMap::new();
        secrets.insert(DEFAULT_EXPORTER_LABEL.to_string(), exporter.to_vec());
        let ctx = GroupContextSnapshot::new(EpochId(epoch), secrets, None);
        let peel = std::panic::AssertUnwindSafe(self.projected(event, &ctx));
        match futures::FutureExt::catch_unwind(peel).await {
            Ok(Some((OpenMlsContentKind::Application, Some(source_epoch), digest)))
                if source_epoch == epoch =>
            {
                Some(digest)
            }
            _ => None,
        }
    }

    /// Reads the mesh packets `taken` (plan §5.2): each is tried under every
    /// key of the ring, the event one carried is rebuilt and verified, and
    /// only an application message of the very epoch its key is of is kept
    /// for the engine ([`Self::application_at`]) — all before the engine
    /// sees anything. `drive` is told of every packet settled here: one no
    /// key opened, one whose event fails any of this, a second packet of an
    /// event already held, one a circle's quota pushed out.
    ///
    /// The ring is brought in line with the engine first, in one hold, so a
    /// deadline that has passed opens nothing.
    ///
    /// Returns, for each circle, the events to offer the engine now: what it
    /// holds from this drive and from earlier ones, oldest first.
    pub(crate) async fn mesh_read(
        &self,
        taken: Vec<MeshPacket>,
        drive: &mut MeshDrive,
    ) -> Vec<(GroupId, Vec<Event>)> {
        {
            let session = self.reading().await;
            let circles = session.live_group_ids().unwrap_or_default();
            self.sync_mesh_circles(&*session, &circles);
        }
        for packet in &taken {
            let Some(opened) = self.mesh_opened(packet, drive) else {
                continue;
            };
            let update = self
                .application_at(&opened.event, opened.epoch, &opened.exporter)
                .await;
            self.mesh_keep(opened, update, drive);
        }
        self.mesh_due()
    }

    /// [`Self::order_for_ingest`], the events alone.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn order_for_ingest_for_test(
        &self,
        group_id: &GroupId,
        events: Vec<Event>,
    ) -> Vec<Event> {
        self.order_for_ingest(group_id, events)
            .await
            .into_iter()
            .map(|(_, event)| event)
            .collect()
    }

    /// Runs Haven's pre-authentication screen over `event` and, if it passes,
    /// converts it to the transport message the engine ingests.
    ///
    /// The single implementation of the screen, so the production entry point
    /// above and the typed test seam below cannot drift: a screen re-implemented
    /// beside its caller asserts the copy, not the policy.
    fn screen_before_auth(
        event: &Event,
    ) -> std::result::Result<cgka_traits::transport::TransportMessage, PreAuthRejection> {
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
        // authenticated anything. So it is classified `Malformed`, i.e.
        // terminal, no routing, no persistence, no convergence drain, no cursor
        // advance — and NO HOLD-BACK.
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
        //
        // # Only group traffic reaches the engine here
        //
        // A receive plane ingests whatever a relay returns, and the engine
        // joins any Welcome it is handed (kind 1059 is a Welcome envelope,
        // MDK `transport-nostr-peeler/src/event.rs:45-50`). A Welcome enters
        // only through `accept_welcome`, after the user accepted it; anything
        // but a kind-445 is therefore refused here, before the engine sees it.
        if event.kind != Kind::Custom(KIND_GROUP_MESSAGE) {
            return Err(PreAuthRejection::Malformed);
        }
        Self::event_to_transport_message(event).map_err(|_| PreAuthRejection::Malformed)
    }

    /// [`Self::process_event`] with the engine's own error type preserved.
    ///
    /// Test-only. Identical in every observable respect but one: the ingest
    /// error is NOT flattened through [`map_mls_err`], so the caller can tell a
    /// forked epoch from a storage failure by MATCHING the variant instead of
    /// by reading redacted prose. The pre-authentication screen runs, from the
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
                .engine()
                .await
                .map_err(|e| SessionError::Storage(StorageError::Backend(e.code().to_owned())))?
                .ingest(msg)
                .await
                .map(ScreenedIngest::Ingested),
        }
    }

    /// The groups an engine batch leaves owing a drain's advance: the engine's
    /// own pending set, plus every group whose epoch the batch moved.
    ///
    /// The second half is Haven's mitigation of an MDK gap (C7, edge 1,
    /// tracked in `docs/MDK_UPSTREAM_TRACKER.md`): an epoch change is exactly
    /// what can make a `PeelDeferred` row peelable. Kept: with Haven's
    /// in-plane serving dropped, the chained-backlog tests and S23 still
    /// converge on MDK's in-advance retry alone, so no test can show this
    /// edge unneeded, and an edge no test can see is not removed.
    #[must_use]
    pub fn groups_owing_advance(effects: &SessionEffects) -> Vec<GroupId> {
        let mut groups = effects.pending_convergence.clone();
        for event in &effects.events {
            if let GroupEvent::EpochChanged { group_id, .. } = event {
                if !groups.contains(group_id) {
                    groups.push(group_id.clone());
                }
            }
        }
        groups
    }

    /// Claims, once per session, the recovery of what the engine handed back
    /// at the open (`CircleManager::recover_owed_outputs`): run by the first
    /// plane before it takes the owed advances, since the drain it makes is
    /// usually the call that collects the groups the engine's hydrate named.
    pub fn take_open_recovery(&self) -> bool {
        self.open_recovery_owed.swap(false, Ordering::AcqRel)
    }

    /// Takes every group the engine has named as owing an advance since the
    /// last take: MDK's host scheduler's pending set, which the engine hands
    /// out once, in the effects of whatever call comes next — the hydrate's
    /// at the open, a deferral, a fairness slot, a retry
    /// (`cgka-engine/src/engine.rs` 2165-2173, `cgka-session/src/lib.rs`
    /// 1268-1275). Only a plane that drains them takes them, and it owes back
    /// each one it leaves unfinished ([`Self::owe_advance`]); an advance made
    /// for another reason never takes a group out.
    pub fn take_owed_advance(&self) -> Vec<GroupId> {
        std::mem::take(
            &mut *self
                .owed_advance
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
        )
    }

    /// Owes `groups` an advance at the next plane that drains them
    /// ([`Self::take_owed_advance`]).
    pub fn owe_advance(&self, groups: &[GroupId]) {
        let mut owed = self
            .owed_advance
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        for group_id in groups {
            if !owed.contains(group_id) {
                owed.push(group_id.clone());
            }
        }
    }

    /// Whether the engine still owes `group_id` work an advance does, read
    /// after a drain consumed the edge that named it (MDK's level signal,
    /// `cgka-engine/src/publish.rs` 556-561): input still to resolve, or a
    /// deferred peel due to be retried NOW. A row that has had its try at the
    /// current epoch answers only its remaining residence — up to 30 days —
    /// and is owed nothing until a new epoch re-arms it: one undecryptable
    /// envelope anyone with the public tag can publish must not make every
    /// claim point re-advance the circle for a month. A store that cannot
    /// say reads as yes.
    pub async fn still_owes_advance(&self, group_id: &GroupId) -> bool {
        let Ok(mut session) = self.engine().await else {
            return true;
        };
        !matches!(session.has_pending_convergence_inputs(group_id), Ok(false))
            || matches!(
                session.deferred_peel_cutoff_delay_ms(group_id),
                Ok(Some(0)) | Err(_)
            )
    }

    /// How many advances a plane gave `group_id` since this session opened:
    /// a receive, drive or settle advance, or a user-facing one.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn advances_for_test(&self, group_id: &GroupId) -> usize {
        self.advances
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(group_id)
            .copied()
            .unwrap_or(0)
    }

    /// Counts one advance of `group_id` (tests only; nothing in a shipped
    /// build).
    #[allow(clippy::unused_self)]
    fn count_advance(&self, group_id: &GroupId) {
        #[cfg(any(test, feature = "test-utils"))]
        {
            *self
                .advances
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .entry(group_id.clone())
                .or_default() += 1;
        }
        #[cfg(not(any(test, feature = "test-utils")))]
        let _ = group_id;
    }

    /// How long a receive plane waits before re-advancing `group_id`, when the
    /// engine owes it a deadline within
    /// [`RECEIVE_RETICK_HORIZON`](crate::relay::retick::RECEIVE_RETICK_HORIZON);
    /// `None`: nothing is owed that soon.
    ///
    /// MDK's own scheduler (`marmot-app` `convergence_schedule_state`, v0.10.4
    /// `client/sync.rs:589-660`) reads the same three engine deadlines
    /// (`cgka-session/src/lib.rs:1090-1106,1174`), with one difference: while a
    /// convergence pass is collecting, this waits for the pass to close rather
    /// than for a deferred peel that reads as due. An advance returns at the
    /// collecting pass before it retries any deferred peel
    /// (`message_processor/mod.rs:1514-1539`), so that wake would do nothing,
    /// and MDK's app spins on it at a 10 ms clamp. A `SelfRemove` auto-commit's
    /// deadline counts only for an otherwise idle group, as there.
    ///
    /// `prepare_convergence_cutoff_delay_ms` is a command, not a read: it may
    /// open or rebase the group's convergence pass, exactly as MDK's own host
    /// scheduler uses it.
    pub async fn receive_retick_after(&self, group_id: &GroupId) -> Option<std::time::Duration> {
        let mut session = self.engine().await.ok()?;
        let pass_closes = session
            .prepare_convergence_cutoff_delay_ms(group_id)
            .ok()
            .flatten();
        let after = pass_closes.or_else(|| {
            // Nor for a circle held for a routing collision, whose eviction no
            // receive stages: its deadline would wake each pass for nothing.
            let eviction = if self.eviction_retick_held_in(&session, group_id)
                || self.routing_collided(group_id)
            {
                Ok(None)
            } else {
                session.scheduled_self_remove_auto_commit_delay_ms(group_id)
            };
            [session.deferred_peel_cutoff_delay_ms(group_id), eviction]
                .into_iter()
                .filter_map(|delay| delay.ok().flatten())
                .min()
        });
        drop(session);
        after
            .map(std::time::Duration::from_millis)
            .filter(|after| *after <= crate::relay::retick::RECEIVE_RETICK_HORIZON)
    }

    /// The distinct groups `events` are about, in first-seen order.
    #[must_use]
    pub fn groups_of(events: &[GroupEvent]) -> Vec<GroupId> {
        let mut groups: Vec<GroupId> = Vec::new();
        for event in events {
            let group_id = Self::event_group_id(event);
            if !groups.contains(group_id) {
                groups.push(group_id.clone());
            }
        }
        groups
    }

    /// The group an engine event is about.
    #[must_use]
    pub const fn event_group_id(event: &GroupEvent) -> &GroupId {
        match event {
            GroupEvent::GroupCreated { group_id, .. }
            | GroupEvent::GroupJoined { group_id, .. }
            | GroupEvent::TransportObjectResourceRefused { group_id, .. }
            | GroupEvent::MessageReceived { group_id, .. }
            | GroupEvent::AppMessageInvalidated { group_id, .. }
            | GroupEvent::GroupStateChanged { group_id, .. }
            | GroupEvent::GroupHydrationQuarantined { group_id, .. }
            | GroupEvent::EpochChanged { group_id, .. }
            | GroupEvent::CommitRolledBack { group_id, .. }
            | GroupEvent::GroupStateInvalidated { group_id, .. }
            | GroupEvent::GroupStateRevalidated { group_id, .. }
            | GroupEvent::GroupUnrecoverable { group_id, .. }
            | GroupEvent::PendingCommitRecovered { group_id, .. }
            | GroupEvent::GroupHydrationRecovered { group_id, .. } => group_id,
        }
    }

    /// Whether a receive path rolled back `group_id`'s eviction in its current
    /// epoch, so no receive retick may re-stage it (see `eviction_retick_hold`).
    pub async fn eviction_retick_held(&self, group_id: &GroupId) -> bool {
        let session = self.reading().await;
        self.eviction_retick_held_in(&session, group_id)
    }

    /// [`Self::eviction_retick_held`] under a session lock the caller holds; a
    /// hold from an earlier epoch is dropped.
    fn eviction_retick_held_in(&self, session: &AccountDeviceSession, group_id: &GroupId) -> bool {
        let mut hold = self
            .eviction_retick_hold
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let epoch = session.epoch_state(group_id).map(|state| state.epoch());
        match hold.get(group_id) {
            Some(at) if Some(*at) == epoch => true,
            Some(_) => {
                hold.remove(group_id);
                false
            }
            None => false,
        }
    }

    /// The groups an ingest leaves owing a receive plane's advance:
    /// [`Self::groups_owing_advance`] plus the group a `Buffered` or
    /// `TransportDeferred` outcome names, whose pending convergence the engine
    /// reports as a cutoff rather than in the effects.
    #[must_use]
    pub fn groups_owing_service(ingest: &IngestEffects) -> Vec<GroupId> {
        let mut groups = Self::groups_owing_advance(&ingest.effects);
        if let IngestOutcome::Buffered { group_id, .. }
        | IngestOutcome::TransportDeferred { group_id, .. } = &ingest.outcome
        {
            if !groups.contains(group_id) {
                groups.push(group_id.clone());
            }
        }
        groups
    }

    /// A receive plane's advance: settles convergence inputs, gives every
    /// deferred-peel row a try under the current context, and releases no
    /// queued user intent.
    ///
    /// While the group holds a queued outbound intent this is MDK's
    /// inputs-only `advance_convergence_inputs` (v0.10.4
    /// `cgka-session/src/lib.rs:1053-1080`): epoch progression and fork healing
    /// stay live, and the queue — with the engine's own maintenance behind it —
    /// waits for a user-facing advance, which alone can hand a released
    /// intent to a publisher that owes it its Welcomes and its obligation
    /// (Addendum A, C7 re-review F1–F4). It is the inputs-only advance, too,
    /// while the live plane sharing the session makes no commit
    /// ([`Self::plane_stands`]): the engine's maintenance is what mints the
    /// user's own leave again for a new epoch, once, and a sweep running
    /// beside a burst or a pause would publish it from the background — or,
    /// handed to a plane that sends nothing there, lose it for that epoch.
    /// Left unminted, the first full advance mints it. With nothing queued
    /// and no such hold, the full advance
    /// can release nothing the user asked for: all it may stage is the
    /// engine's own maintenance — a due `SelfRemove` auto-commit or a
    /// re-proposed leave (`message_processor/mod.rs:972-1100,1144-1163`) —
    /// which every receive plane already publishes. MDK's runtime makes the
    /// same split against a different condition — a fanout that is backing
    /// off (`marmot-account/src/runtime.rs:2400-2413`), where this keys on any
    /// queued intent — so it never leaves a queued change standing, and this
    /// does: such a change holds its circle at its epoch until a full advance
    /// (`advance_for_drive`) gives it its one attempt.
    ///
    /// One advance retries at most 64 deferred-peel rows
    /// (`MAX_DEFERRED_ROWS_PER_SWEEP`, `message_processor/mod.rs:155`), and MDK
    /// reports rows still untried under the current context as due now
    /// (`deferred_peel_cutoff_delay_ms` = `Some(0)`, `:2862-2877`), which its own
    /// runtime treats as ready (`marmot-app/src/client/sync.rs:600-610,649`). So
    /// this re-advances while that holds and no convergence pass is collecting,
    /// up to [`DEFERRED_PEEL_DRAIN_ADVANCES`] and [`DEFERRED_PEEL_DRAIN_BUDGET`]:
    /// a store a non-member filled to MDK's cap would otherwise leave rows the
    /// next send's preflight must try first, four at a time
    /// (`:215-222,1208-1230`), queuing the user's send
    /// (`docs/MDK_UPSTREAM_TRACKER.md` T-FOREGROUND-PEEL). The session lock is
    /// taken per advance, so no hold outlasts one advance — which MDK itself
    /// cuts at `BACKGROUND_CONVERGENCE_BUDGET_MS` (500 ms, `:209`) — and each
    /// advance re-reads whether an intent is queued.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown or the first advance fails; a
    /// later failure returns what the earlier advances produced.
    pub async fn advance_for_receive(&self, group_id: &GroupId) -> Result<SessionEffects> {
        let deadline = std::time::Instant::now() + DEFERRED_PEEL_DRAIN_BUDGET;
        self.advance_and_drain(group_id, Some(deadline)).await
    }

    /// The drain of [`Self::advance_for_receive`] alone, cut at `deadline`
    /// instead of [`DEFERRED_PEEL_DRAIN_BUDGET`]: it advances only while
    /// deferred-peel rows are untried. `None` if no advance was due.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown or the first advance fails; a
    /// later failure returns what the earlier advances produced.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn drain_deferred_peels(
        &self,
        group_id: &GroupId,
        deadline: Option<std::time::Instant>,
    ) -> Result<Option<SessionEffects>> {
        if !Self::peel_drain_due(&mut *self.engine().await?, group_id) {
            return Ok(None);
        }
        self.advance_and_drain(group_id, deadline).await.map(Some)
    }

    /// Rows remain untried under the current peel context and no convergence
    /// pass is collecting, so another advance makes progress now. The pass
    /// query can open a pass, so it is asked only when rows are untried.
    fn peel_drain_due(session: &mut AccountDeviceSession, group_id: &GroupId) -> bool {
        matches!(session.deferred_peel_cutoff_delay_ms(group_id), Ok(Some(0)))
            && !matches!(
                session.prepare_convergence_cutoff_delay_ms(group_id),
                Ok(Some(ms)) if ms > 0
            )
    }

    /// One advance, then more while rows are untried, up to
    /// [`DEFERRED_PEEL_DRAIN_ADVANCES`] and `deadline`, whichever comes first,
    /// taking the session lock afresh for each.
    async fn advance_and_drain(
        &self,
        group_id: &GroupId,
        deadline: Option<std::time::Instant>,
    ) -> Result<SessionEffects> {
        let mut all = self
            .advance_once_for_receive(&mut *self.engine().await?, group_id)
            .await?;
        for _ in 1..DEFERRED_PEEL_DRAIN_ADVANCES {
            if deadline.is_some_and(|deadline| std::time::Instant::now() >= deadline) {
                break;
            }
            let Ok(mut session) = self.engine().await else {
                break;
            };
            if !Self::peel_drain_due(&mut session, group_id) {
                break;
            }
            let Ok(more) = self.advance_once_for_receive(&mut session, group_id).await else {
                break;
            };
            drop(session);
            all = chain_effects(all, more);
        }
        Ok(all)
    }

    /// Whether `group_id` holds deferred-peel rows still untried under its
    /// current peel context (MDK reports them due now, `Some(0)`).
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn deferred_peels_untried_for_test(&self, group_id: &GroupId) -> bool {
        self.engine().await.is_ok_and(|mut session| {
            matches!(session.deferred_peel_cutoff_delay_ms(group_id), Ok(Some(0)))
        })
    }

    async fn advance_once_for_receive(
        &self,
        session: &mut AccountDeviceSession,
        group_id: &GroupId,
    ) -> Result<SessionEffects> {
        self.count_advance(group_id);
        let ahead = Box::pin(self.hand_back_stranded(session, Some(group_id), true)).await?;
        let advanced = Box::pin(session.advance_convergence_inputs(group_id))
            .await
            .map_err(map_mls_err);
        let advanced = self.noted(session, advanced);
        match self.behind_what_was_handed_back(ahead, advanced) {
            Ok(effects) => Ok(self.unstaged_beside_a_fanout(session, effects).await),
            Err(e) => Err(e),
        }
    }

    /// Serves `group_id` the way a receive plane does — [`Self::advance_for_receive`],
    /// then again at each deadline [`Self::receive_retick_after`] announces —
    /// until the engine owes it nothing within the retick horizon, and returns
    /// every effect collected.
    ///
    /// Test-only. The pinned convergence policy holds a received commit
    /// `Buffered` until its pass closes a quiescence window later, on MDK's own
    /// monotonic clock, which a host cannot inject
    /// (`docs/MDK_UPSTREAM_TRACKER.md` T-CONVERGENCE-CLOCK); so the wait is real
    /// time, bounded by the deadlines the engine itself reports, and a test that
    /// pauses tokio's clock cannot use this.
    ///
    /// # Errors
    ///
    /// Returns an error if an advance fails.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn settle_receive_for_test(&self, group_id: &GroupId) -> Result<SessionEffects> {
        let mut all = self.advance_for_receive(group_id).await?;
        for _ in 0..crate::relay::retick::MAX_CONVERGENCE_RETICKS {
            let Some(after) = self.receive_retick_after(group_id).await else {
                break;
            };
            tokio::time::sleep(after).await;
            let more = self.advance_for_receive(group_id).await?;
            all.events.extend(more.events);
            all.publish.extend(more.publish);
            all.queued.extend(more.queued);
            all.pending_convergence.extend(more.pending_convergence);
        }
        Ok(all)
    }

    /// [`Self::process_event`], then [`Self::settle_receive_for_test`] for every
    /// group the ingest leaves owing service, with the settled effects appended
    /// to the ingest's own. The outcome is the ingest's, unchanged: a commit is
    /// still reported `Buffered` even though the returned effects carry its
    /// apply.
    ///
    /// Test-only: what a receive plane does with one event, for a test that
    /// drives the engine seam directly.
    ///
    /// # Errors
    ///
    /// Returns an error if the ingest or an advance fails.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn process_event_settled_for_test(&self, event: &Event) -> Result<ScreenedIngest> {
        let mut screened = self.process_event(event).await?;
        if let ScreenedIngest::Ingested(ingest) = &mut screened {
            for group_id in Self::groups_owing_service(ingest) {
                let more = self.settle_receive_for_test(&group_id).await?;
                ingest.effects.events.extend(more.events);
                ingest.effects.publish.extend(more.publish);
                ingest.effects.queued.extend(more.queued);
                ingest
                    .effects
                    .pending_convergence
                    .extend(more.pending_convergence);
            }
        }
        Ok(screened)
    }

    /// Advances stored convergence for a group, releasing queued work and
    /// buffered inbound messages that are now safe to apply.
    ///
    /// The intent-draining advance: only a user-facing path may call it — one
    /// whose disposition of a released intent publishes it as the user's own
    /// change. Receive planes call [`Self::advance_for_receive`].
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown or convergence fails.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn advance_convergence(&self, group_id: &GroupId) -> Result<SessionEffects> {
        self.count_advance(group_id);
        let mut session = self.engine().await?;
        let ahead = Box::pin(self.hand_back_stranded(&mut session, Some(group_id), true)).await?;
        self.retire_unmakeable_queued_changes(&mut session, group_id, false);
        // A circle held for a routing collision makes no commit of the
        // engine's: what it receives is settled, and nothing is staged. Nor
        // one holding a self-update the engine queued and Haven could not
        // retire.
        let result = if self.routing_collided(group_id)
            || !self.retire_queued_self_updates(&mut session, group_id)
        {
            Box::pin(session.advance_convergence_inputs(group_id)).await
        } else {
            Box::pin(session.advance_convergence(group_id)).await
        }
        .map_err(map_mls_err);
        let result = self.noted(&session, result);
        let result = match self.behind_what_was_handed_back(ahead, result) {
            Ok(effects) => Ok(self.unstaged_beside_a_fanout(&mut session, effects).await),
            Err(e) => Err(e),
        };
        drop(session);
        result
    }

    /// The group's epoch state, through MDK's typed getter
    /// (`AccountDeviceSession::epoch_state`), or `None` for a group this
    /// session does not hold live.
    pub async fn epoch_state(&self, group_id: &GroupId) -> Option<EpochState> {
        self.reading().await.epoch_state(group_id)
    }

    /// Whether MDK enrolled `group_id` in periodic self-update
    /// (`GroupMaintenanceState::periodic_enrolled`). Test-only: pins that no
    /// circle, created or joined, is ever put on a rotation timer.
    ///
    /// # Errors
    ///
    /// Returns an error if the maintenance record cannot be read.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn periodic_rotation_enrolled_for_test(&self, group_id: &GroupId) -> Result<bool> {
        Ok(self
            .reading()
            .await
            .group_maintenance(group_id)
            .map_err(map_mls_err)?
            .is_some_and(|state| state.periodic_enrolled))
    }

    /// Every group this session holds live (hydrated and not quarantined).
    ///
    /// # Errors
    ///
    /// Returns an error if the engine cannot list its groups.
    pub async fn live_group_ids(&self) -> Result<Vec<GroupId>> {
        self.reading().await.live_group_ids().map_err(map_mls_err)
    }

    /// Retires a queued intent the engine regenerated into publish work
    /// (`AccountDeviceSession::confirm_regenerated_queued_intent`): its durable
    /// row is deleted and it is never regenerated again.
    ///
    /// # Errors
    ///
    /// Returns an error if the engine cannot delete the durable row.
    pub async fn retire_queued_intent(&self, intent: &QueuedIntentRef) -> Result<()> {
        self.engine()
            .await?
            .confirm_regenerated_queued_intent(intent)
            .map_err(map_mls_err)
    }

    /// Abandons a group locally, without sending a leave or a disband
    /// (`AccountDeviceSession::forget_group_local`, mdk#1815): its MLS state is
    /// deleted and a later fresh Welcome may rejoin it.
    ///
    /// # Errors
    ///
    /// Returns an error if the engine refuses the forget.
    pub async fn forget_group_local(&self, group_id: &GroupId) -> Result<()> {
        let mut session = self.engine().await?;
        let rows: Vec<MessageId> = session
            .outbound_fanouts_for_group(group_id)
            .map_err(map_mls_err)?
            .iter()
            .map(|row| row.message_id().clone())
            .collect();
        session.forget_group_local(group_id).map_err(map_mls_err)?;
        self.mesh_keys.forget(&*session, group_id);
        drop(session);
        // The rows went with the group (their foreign key cascades); the
        // process-wide registry must not go on refusing their events.
        for row in &rows {
            crate::relay::fanout::release(row);
        }
        self.unread().pager.remove(group_id);
        Ok(())
    }

    /// Whether `group_id` holds input this device fetched and has not taken
    /// in: a current-epoch commit the catch-up pager held back from a page,
    /// or stored replay a live REQ holds until its relay's `EOSE`. Such a
    /// commit may remove a member, so no location is sealed for the circle
    /// until it is in (Security Rule 10).
    ///
    /// A held commit the engine already records as processed is released
    /// here: a hold set after another plane's ingest took it in would
    /// otherwise wait for a refetch nothing owes, which could only answer
    /// `Duplicate`. Recorded is not applied — MDK records a commit when it
    /// admits it to convergence — but one still unresolved holds the circle
    /// through the engine's own send gate. A store fault keeps the hold.
    pub(crate) fn holds_unread_input(&self, group_id: &GroupId) -> bool {
        let held: Vec<Vec<u8>> = self
            .unread()
            .pager
            .get(group_id)
            .map(|ids| ids.iter().cloned().collect())
            .unwrap_or_default();
        // No store read runs under `unread`, as in `note_taken_in`.
        let recorded: Vec<Vec<u8>> = held
            .into_iter()
            .filter(|id| {
                nostr::EventId::from_slice(id).is_ok_and(|event| self.engine_processed(&event))
            })
            .collect();
        let mut unread = self.unread();
        if let Some(ids) = unread.pager.get_mut(group_id) {
            for id in &recorded {
                ids.remove(id);
            }
        }
        unread
            .pager
            .get(group_id)
            .is_some_and(|ids| !ids.is_empty())
            || unread.live.get(group_id).is_some_and(|n| *n > 0)
    }

    /// Whether `group_id` holds input this device fetched and has not taken in.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn holds_unread_input_for_test(&self, group_id: &GroupId) -> bool {
        self.holds_unread_input(group_id)
    }

    /// As the pager holding back `commits` of `group_id`.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn hold_pager_commits_for_test(&self, group_id: &GroupId, commits: &[nostr::EventId]) {
        self.hold_pager_commits(group_id, commits);
    }

    /// The pager held back `commits`, current-epoch commits of `group_id`:
    /// each stays unread until an ingest takes it in
    /// ([`Self::note_taken_in`]), whichever plane makes it, or the engine's
    /// record shows one already did ([`Self::holds_unread_input`]).
    pub(crate) fn hold_pager_commits<'a>(
        &self,
        group_id: &GroupId,
        commits: impl IntoIterator<Item = &'a nostr::EventId>,
    ) {
        self.unread()
            .pager
            .entry(group_id.clone())
            .or_default()
            .extend(commits.into_iter().map(|id| id.as_bytes().to_vec()));
        // After the hold stands: a seal that began once the circle fell
        // silent then reads the hold.
        self.mesh_keys.silence(group_id);
    }

    /// Ends the pager's hold on `id` once the engine answered its ingest with
    /// anything but a want of room: processed, rejected, invalidated, buffered
    /// or retained, it is in, and a commit the engine rejects can never hold
    /// sharing back. An error counts only when the engine recorded the event
    /// before it erred.
    fn note_taken_in(&self, id: &MessageId, result: &Result<IngestEffects>) {
        if self.took_in(id, result) {
            let mut unread = self.unread();
            unread.pager.retain(|_, ids| {
                ids.remove(id.as_slice());
                !ids.is_empty()
            });
        }
    }

    /// Whether the engine answered `id`'s ingest with anything but a want of
    /// room: an error counts only when the engine recorded the event first.
    fn took_in(&self, id: &MessageId, result: &Result<IngestEffects>) -> bool {
        result.as_ref().map_or_else(
            |_| {
                self.message_store
                    .has_processed_transport_id(id)
                    .unwrap_or(false)
            },
            Self::kept,
        )
    }

    /// Whether the engine's answer to an ingest says it holds the event:
    /// anything but a want of room.
    const fn kept(ingested: &IngestEffects) -> bool {
        match ingested.outcome {
            IngestOutcome::ResourceRefused { .. } => false,
            IngestOutcome::Ignored { .. } => true,
            _ => !ingested.left_object_unpersisted,
        }
    }

    /// What every ingest funnel notes of an event a relay plane fetched once
    /// the engine answered it, with the engine held: the pager's hold ends
    /// ([`Self::note_taken_in`]), a full drive's ingest feeds the stall
    /// detector (`observe`), and a `kind:445` the engine took in for a group
    /// it knows is recorded where the NIP-77 pass reads what this device
    /// holds of its routing — MDK's inventory for an event that does not
    /// expire, this process's memory for one that does, so no lasting local
    /// trace of a location is kept. Nothing recorded here is ever sent
    /// (`relay::negentropy`). A refused or unpersisted object is never
    /// recorded: its redelivery is owed (Security Rule 12).
    fn note_ingested(
        &self,
        session: &AccountDeviceSession,
        event: &Event,
        route: Option<[u8; 32]>,
        id: &MessageId,
        result: &Result<IngestEffects>,
        observe: bool,
    ) {
        self.note_taken_in(id, result);
        if observe {
            self.observe_stall(session, event.created_at.as_secs(), id, result);
        }
        let unknown_route = result.as_ref().is_ok_and(|ingested| {
            matches!(
                ingested.outcome,
                IngestOutcome::Ignored {
                    category: cgka_traits::ingest::InputRejectionCategory::UnknownGroup
                }
            )
        });
        let Some(route) = route.filter(|_| !unknown_route && self.took_in(id, result)) else {
            return;
        };
        let now_secs = Timestamp::now().as_secs();
        self.neg_memo().resolve(
            route,
            event.id,
            crate::relay::negentropy::forget_at(event, now_secs),
            now_secs,
        );
        if event.tags.expiration().is_none() {
            let _ = self.message_store.record_transport_reconciliation_item(
                &TransportReconciliationRoute::Group(route),
                &TransportReconciliationItem {
                    event_id: event.id.to_bytes(),
                    created_at: event.created_at.as_secs(),
                },
            );
        }
    }

    /// Records `event`, which Haven's screen refused before authentication
    /// after a plane fetched it for `routing`, as judged under that routing
    /// alone: the refusal is a property of its bytes, which its id commits to
    /// (every relay event passed `verify()`, Security Rule 16), so no NIP-77
    /// pass of that routing asks for it again. Never under another routing
    /// the event names: what one routing's pass asks may not depend on what
    /// arrived for another, and an event names as many as it likes. Kept in
    /// memory alone and never sent.
    pub(crate) fn neg_judge_refused(&self, routing: &[u8; 32], event: &Event) {
        let now_secs = Timestamp::now().as_secs();
        self.neg_memo().resolve(
            *routing,
            event.id,
            crate::relay::negentropy::forget_at(event, now_secs),
            now_secs,
        );
    }

    /// The NIP-77 pass's memory ([`crate::relay::negentropy::NegMemo`]).
    pub(crate) fn neg_memo(&self) -> std::sync::MutexGuard<'_, crate::relay::negentropy::NegMemo> {
        self.negentropy
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The ids MDK's inventory holds of `routing_id`'s window ending at
    /// `until`; `None` when the store cannot say. Read with the engine held.
    pub(crate) async fn neg_inventory(
        &self,
        routing_id: &[u8; 32],
        until: u64,
    ) -> Option<HashSet<nostr::EventId>> {
        let session = self.reading().await;
        let inventory = self
            .message_store
            .transport_reconciliation_inventory(
                &TransportReconciliationRoute::Group(*routing_id),
                until,
            )
            .ok();
        drop(session);
        Some(
            inventory?
                .items
                .into_iter()
                .map(|item| nostr::EventId::from_byte_array(item.event_id))
                .collect(),
        )
    }

    /// Records `items` (id, `created_at`) in MDK's inventory of
    /// `routing_id`, as the ingest funnels do, with the engine held.
    ///
    /// # Panics
    ///
    /// When the store refuses a row: a test's setup.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn record_neg_items_for_test(
        &self,
        routing_id: [u8; 32],
        items: &[(nostr::EventId, u64)],
    ) {
        let session = self.reading().await;
        for (id, created_at) in items {
            self.message_store
                .record_transport_reconciliation_item(
                    &TransportReconciliationRoute::Group(routing_id),
                    &TransportReconciliationItem {
                        event_id: id.to_bytes(),
                        created_at: *created_at,
                    },
                )
                .expect("record an inventory item");
        }
        drop(session);
    }

    /// What MDK's inventory holds of `routing_id`'s window ending now.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn neg_inventory_for_test(&self, routing_id: [u8; 32]) -> HashSet<nostr::EventId> {
        self.neg_inventory(&routing_id, Timestamp::now().as_secs())
            .await
            .unwrap_or_default()
    }

    /// The routing id MDK's durable route cursor last moved to, if any.
    pub(crate) async fn neg_route_cursor(&self) -> Option<[u8; 32]> {
        let session = self.reading().await;
        let cursor = self.message_store.transport_reconciliation_route_cursor();
        drop(session);
        match cursor {
            Ok(Some(TransportReconciliationRoute::Group(routing_id))) => Some(routing_id),
            _ => None,
        }
    }

    /// Moves MDK's durable route cursor to `routing_id`, with the engine held.
    pub(crate) async fn neg_advance_route_cursor(&self, routing_id: &[u8; 32]) {
        let session = self.reading().await;
        let _ = self
            .message_store
            .advance_transport_reconciliation_route_cursor(&TransportReconciliationRoute::Group(
                *routing_id,
            ));
        drop(session);
    }

    /// Where `routing_id`'s by-id batch last ended, if anywhere.
    pub(crate) async fn neg_replay_cursor(&self, routing_id: &[u8; 32]) -> Option<nostr::EventId> {
        let session = self.reading().await;
        let cursor = self.message_store.transport_reconciliation_replay_cursor(
            &TransportReconciliationRoute::Group(*routing_id),
        );
        drop(session);
        cursor.ok().flatten().map(nostr::EventId::from_byte_array)
    }

    /// Records that `routing_id`'s by-id batch ended at `last`, before the
    /// fetch it names, with the engine held.
    pub(crate) async fn neg_advance_replay_cursor(
        &self,
        routing_id: &[u8; 32],
        last: &nostr::EventId,
    ) {
        let session = self.reading().await;
        let _ = self
            .message_store
            .advance_transport_reconciliation_replay_cursor(
                &TransportReconciliationRoute::Group(*routing_id),
                Some(last.to_bytes()),
            );
        drop(session);
    }

    /// Whether Haven's screen before authentication lets `event` through
    /// to the engine ([`Self::process_event`]).
    pub(crate) fn passes_screen(event: &Event) -> bool {
        Self::screen_before_auth(event).is_ok()
    }

    /// As a live REQ beginning to hold stored replay for `group_id`.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn hold_live_replay_for_test(&self, group_id: &GroupId) {
        self.hold_live_replay(group_id);
    }

    /// A live REQ began holding stored replay for `group_id`.
    pub(crate) fn hold_live_replay(&self, group_id: &GroupId) {
        *self.unread().live.entry(group_id.clone()).or_default() += 1;
        // After the hold stands, as [`Self::hold_pager_commits`].
        self.mesh_keys.silence(group_id);
    }

    /// A live REQ's stored replay for `group_id` was taken in.
    pub(crate) fn release_live_replay(&self, group_id: &GroupId) {
        let mut unread = self.unread();
        if let Some(n) = unread.live.get_mut(group_id) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                unread.live.remove(group_id);
            }
        }
    }

    fn unread(&self) -> std::sync::MutexGuard<'_, UnreadInput> {
        self.unread_input
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Whether MDK holds `group_id` unrecoverable: its persisted flag
    /// (`traits/src/group.rs` 65-75), re-seeded at every open
    /// (`cgka-engine/src/engine.rs` 1484-1500) and cleared by an
    /// authenticated rejoin (`group_lifecycle.rs` 1574-1590). `None` when the
    /// engine does not hold the group live — quarantined, not hydrated — or
    /// its record cannot be read: a caller that gates a commit or a roster
    /// stamp reads that as yes, one that reads for the user as no.
    pub(crate) async fn unrecoverable(&self, group_id: &GroupId) -> Option<bool> {
        self.reading()
            .await
            .group_record(group_id)
            .ok()
            .map(|group| group.unrecoverable)
    }

    /// Whether `group_id` was disbanded: MDK's tombstone, durable and put
    /// back at every open (`cgka-engine/src/engine.rs` 1621-1700).
    pub async fn disbanded(&self, group_id: &GroupId) -> bool {
        let session = self.reading().await;
        matches!(
            session.epoch_state(group_id),
            Some(EpochState::Disbanded(_))
        ) || session
            .group_record(group_id)
            .is_ok_and(|group| group.disbanded.is_some())
    }

    /// The disband's author, as lowercase hex, from the tombstone; `None`
    /// for a group not disbanded.
    pub(crate) async fn disbanded_by(&self, group_id: &GroupId) -> Option<String> {
        let tombstone = self
            .reading()
            .await
            .group_record(group_id)
            .ok()?
            .disbanded?;
        Some(hex::encode(tombstone.actor.as_slice()))
    }

    /// Clears the notes that a Welcome or a re-invite is owed for
    /// `group_id`: nothing can deliver either any more.
    pub(crate) fn clear_owed_notes(&self, group_id: &GroupId) {
        self.commit_notes.clear(group_id, ChangeNote::WelcomeOwed);
        self.commit_notes.clear(group_id, ChangeNote::ReinviteOwed);
    }

    /// The groups this session held live when it opened; `None` when the
    /// engine could not list them.
    pub(crate) fn groups_at_open(&self) -> Option<&[GroupId]> {
        self.groups_at_open.as_deref()
    }

    /// Where a group whose circle has ended stands, for the forget that
    /// ends its MLS state.
    pub(crate) async fn left_group(&self, group_id: &GroupId) -> LeftGroup {
        let record = self.reading().await.group_record(group_id);
        match record {
            Ok(group) if group.disbanded.is_some() => LeftGroup::Disbanded,
            Ok(group) => LeftGroup::Held(group.members.into_iter().map(|m| m.id).collect()),
            Err(SessionError::Engine(EngineError::Storage(
                cgka_traits::storage::StorageError::NotFound,
            ))) => LeftGroup::Gone,
            Err(_) => LeftGroup::Unread,
        }
    }

    /// Every join the engine still holds unacknowledged
    /// ([`Self::acknowledge_outputs`]); `None` when they cannot be read.
    pub(crate) async fn owed_joins(&self) -> Option<Vec<OwedJoin>> {
        let _session = self.reading().await;
        let events = self.message_store.list_pending_application_events().ok()?;
        Some(
            events
                .into_iter()
                .filter_map(|event| match event {
                    GroupEvent::GroupJoined {
                        group_id,
                        via_welcome,
                        welcomer,
                        ..
                    } => Some(OwedJoin {
                        group_id,
                        via_welcome,
                        welcomer,
                    }),
                    _ => None,
                })
                .collect(),
        )
    }

    // ── Publish-before-apply (Rule 13) ───────────────────────────────────────

    /// Confirms that a staged `GroupEvolution` / `GroupCreated` / `AutoPublish`
    /// was published (≥1-relay ack). The engine applies the staged commit and
    /// emits the epoch change. Exposed for DM-3's publish discipline.
    ///
    /// # Errors
    ///
    /// Returns an error if the pending ref is unknown (already confirmed,
    /// rolled back, or never issued), and [`NostrError::FanoutOwned`] for a
    /// commit under a fanout row, which only the fanout driver resolves.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn confirm_published(&self, pending: PendingStateRef) -> Result<SessionEffects> {
        let mut session = self.engine().await?;
        Self::refuse_fanout_owned(&session, pending)?;
        let result = Box::pin(session.confirm_published(pending))
            .await
            .map_err(map_mls_err);
        self.look_for_stranded(&session);
        let result = self.noted(&session, result);
        drop(session);
        result
    }

    /// Reports that a staged publish failed; the engine discards the staged
    /// commit and returns the group to `Stable` at the prior epoch. Exposed for
    /// DM-3's publish discipline.
    ///
    /// # Errors
    ///
    /// Returns an error if the pending ref is unknown.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn publish_failed(&self, pending: PendingStateRef) -> Result<SessionEffects> {
        self.publish_failed_holding(pending, false).await
    }

    /// [`Self::publish_failed`] from a receive path: the rolled-back group's
    /// re-armed eviction is not waited on by a receive retick until its epoch
    /// moves (see `eviction_retick_hold`).
    ///
    /// # Errors
    ///
    /// Returns any engine error, redacted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn publish_failed_on_receive(
        &self,
        pending: PendingStateRef,
    ) -> Result<SessionEffects> {
        self.publish_failed_holding(pending, true).await
    }

    #[cfg(any(test, feature = "test-utils"))]
    async fn publish_failed_holding(
        &self,
        pending: PendingStateRef,
        hold_eviction_retick: bool,
    ) -> Result<SessionEffects> {
        let mut session = self.engine().await?;
        Self::refuse_fanout_owned(&session, pending)?;
        self.publish_failed_in(&mut session, pending, hold_eviction_retick)
            .await
    }

    /// [`Self::publish_failed`] under a session lock the caller holds.
    async fn publish_failed_in(
        &self,
        session: &mut AccountDeviceSession,
        pending: PendingStateRef,
        hold_eviction_retick: bool,
    ) -> Result<SessionEffects> {
        let staged_in = |session: &AccountDeviceSession, group_id: &GroupId| {
            matches!(
                session.epoch_state(group_id),
                Some(EpochState::PendingPublish(staged)) if staged.pending_ref() == pending
            )
        };
        let group_id = session
            .live_group_ids()
            .ok()
            .and_then(|ids| ids.into_iter().find(|id| staged_in(session, id)));
        let origin = session.pending_origin_message_id(pending).ok();
        // Owed BEFORE the rewind, as the fanout form owes it: a rewind whose
        // caller drops this call before the retirement below leaves the
        // commit's row stored as sent,
        // and only what is remembered here has the engine gate retire it.
        if let Some(origin) = &origin {
            self.unretired
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(origin.clone());
            self.session.owe_finish(session);
        }
        let injected = || Err(NostrError::MdkError("injected"));
        let result = match self.rollback_fault() {
            Some(RollbackFault::Refused) => injected(),
            Some(RollbackFault::ParksBeforeTheRewind) => std::future::pending().await,
            fault => {
                let rewound = Box::pin(session.publish_failed(pending))
                    .await
                    .map_err(map_mls_err);
                match fault {
                    Some(RollbackFault::ParksAfterTheRewind) => std::future::pending().await,
                    Some(_) => injected(),
                    None => rewound,
                }
            }
        };
        let nothing_owed = || {
            if let Some(origin) = &origin {
                let mut unretired = self
                    .unretired
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if let Some(at) = unretired.iter().position(|owed| owed == origin) {
                    unretired.swap_remove(at);
                }
            }
        };
        // MDK rewinds the staged commit but keeps its `Sent` message row, and
        // a later convergence pass selects that row as a candidate edge and
        // merges the commit no relay accepted — locally, unpublished: a fork
        // (`docs/MDK_UPSTREAM_TRACKER.md` T-ROLLBACK-RESURRECT). An `Err` can
        // follow a completed rewind (a replay error), so the state decides.
        if let Some(group_id) = group_id.filter(|id| !staged_in(session, id)) {
            // The commit that was rewound, and no other: by the id the engine
            // tracked for its ref, which it does for every commit a Haven
            // session can stage (`track_pending_origin_commit` at each
            // staging site; only the legacy profile's create has none).
            debug_assert!(
                origin.is_some(),
                "a rewound commit with no tracked origin: its stored row cannot be retired",
            );
            if let Some(origin) = &origin {
                match retire_commit(&self.message_store, origin) {
                    Ok(()) => nothing_owed(),
                    // No fanout row says this commit was rolled back, so
                    // nothing durable would have the engine gate retire it:
                    // it stays remembered, and the gate holds every later
                    // engine call until the retirement lands. A convergence
                    // pass before then could merge a commit nobody was sent.
                    Err(e) => log::warn!(
                        "publish failed: retiring the rewound commit's row failed; the engine \
                         is not called again until it is retired: {}",
                        e.kind()
                    ),
                }
            }
            if hold_eviction_retick {
                self.hold_eviction_retick(session, group_id);
            }
        } else {
            // Nothing was rewound: the commit is still staged, and its row is
            // not one to retire.
            nothing_owed();
        }
        self.look_for_stranded(session);
        self.noted(session, result)
    }

    /// Keeps receive reticks from waiting on `group_id`'s re-armed eviction
    /// until its epoch moves (see `eviction_retick_hold`).
    fn hold_eviction_retick(&self, session: &AccountDeviceSession, group_id: GroupId) {
        if let Some(epoch) = session.epoch_state(&group_id).map(|state| state.epoch()) {
            self.eviction_retick_hold
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(group_id, epoch);
        }
    }

    // ── Durable fanout (Rule 13) ─────────────────────────────────────────────
    //
    // A call made in STAGING MODE writes a durable MDK `OutboundFanout` for
    // every commit the engine hands back, before it releases the session lock,
    // and returns the row's handle in the commit's place. Staging-mode forms
    // exist for the send (`send_staging` and the three built on it), for one
    // receive advance (`advance_staging`), and for the fanout driver's own
    // engine calls below. Every other engine call — ingest, the receive
    // planes' drains, a leave, an admin-policy change — still hands a commit
    // back as publish work with no row; nothing here covers those. Beside a
    // pending record the engine no longer holds, a group change is refused
    // before the engine is asked (`send`, `update_admin_policy`) and a
    // commit any other legacy call staged is rolled back in its hold
    // (`ingest`, the two receive advances, and a send or a leave, whose
    // preflight can stage a due eviction: `unstaged_beside_a_fanout`).

    /// [`Self::send`] in staging mode.
    ///
    /// # Errors
    ///
    /// Returns any engine error, redacted; and the rollback's error when a
    /// commit could be neither recorded nor rolled back.
    pub async fn send_staging(&self, intent: SendIntent, now_ms: u64) -> Result<Staged> {
        self.send_staging_keeping(intent, now_ms, true).await
    }

    /// [`Self::remove_members_staging`] for decision 180's ask: a removal the
    /// engine queues rather than stages is taken back in the hold that queued
    /// it, and comes back with no record.
    pub(crate) async fn requeue_removal_staging(
        &self,
        group_id: &GroupId,
        member_pubkeys: &[String],
        now_ms: u64,
    ) -> Result<Staged> {
        self.send_staging_keeping(
            Self::removal_intent(group_id, member_pubkeys)?,
            now_ms,
            false,
        )
        .await
    }

    async fn send_staging_keeping(
        &self,
        intent: SendIntent,
        now_ms: u64,
        keep_queued: bool,
    ) -> Result<Staged> {
        let mut session = self.engine().await?;
        // Handed back before the roster is read: a leave among it is a
        // proposal the commit could take in.
        let ahead =
            Box::pin(self.hand_back_stranded(&mut session, Some(intent_group(&intent)), true))
                .await?;
        let before = self.roster_before(&session, intent_group(&intent));
        let result = Box::pin(session.send(intent)).await.map_err(map_mls_err);
        let result = self.noted(&session, result);
        let result = self.behind_what_was_handed_back(ahead, result);
        let staged = self
            .staged(
                &mut session,
                result,
                now_ms,
                before.as_ref(),
                false,
                DriveMode::Full,
            )
            .await;
        if let (false, Ok(staged)) = (keep_queued, &staged) {
            self.take_back_queued(&mut session, &staged.effects);
        }
        drop(session);
        staged
    }

    /// [`Self::send_location`] in staging mode: an eviction the engine's
    /// preflight stages ahead of the location gets its record in this hold —
    /// or, inside the wait a refusal earned and in a hold whose mode makes
    /// no new commit, is undone in it, unsent
    /// ([`Self::stage_commits`]).
    ///
    /// One engine hold, in this order. The circle's stranded input is
    /// handed back, or the call is answered held. The mode is the one
    /// `still` was decided in, asked again after that hand-back and with
    /// nothing awaited before the send: a send decided in the foreground and
    /// made behind a wait in which the foreground ended is a send that makes
    /// no commit. A circle left waiting for a foreground is sealed for by
    /// nobody else ([`Self::held_away`]): it comes back in
    /// [`Staged::waiting`], with nothing sealed. Then the send; and a
    /// location the engine sealed is given its record before the hold ends
    /// ([`Self::record_location`]), so that no relay is ever written to for
    /// a location the store does not know of. `mesh_only` is kept with that
    /// record's entry in this session, in the same hold: its send hands the
    /// location to the mesh and to no relay ([`LocationToSend::mesh_only`]).
    ///
    /// # Errors
    ///
    /// As [`Self::send_location`]; and the store's error when the record
    /// could not be written — the sealed location is then dropped unsent.
    pub(crate) async fn send_location_staging(
        &self,
        group_id: &GroupId,
        content: String,
        now_ms: u64,
        still: Still<'_>,
        mesh_only: bool,
    ) -> Result<(Staged, Option<RecordedLocation>)> {
        let intent = SendIntent::AppMessage {
            group_id: group_id.clone(),
            payload: location_rumor(self.identity_pubkey, content)
                .as_json()
                .into_bytes(),
            expected_epoch: None,
        };
        let mut session = self.engine().await?;
        let whole = still.holds() && still.decided() == DriveMode::Full;
        let ahead = Box::pin(self.hand_back_stranded(&mut session, Some(group_id), whole)).await?;
        let mode = if still.holds() {
            still.decided()
        } else {
            DriveMode::FinishOnly
        };
        if self.away_hold(&session, group_id, mode).is_some() {
            drop(session);
            let held = Staged {
                effects: ahead,
                fanouts: Vec::new(),
                welcomes: Vec::new(),
                proposals: Vec::new(),
                unrecorded: Vec::new(),
                waiting: vec![group_id.clone()],
            };
            return Ok((held, None));
        }
        let result = match Box::pin(session.send(intent)).await {
            Err(SessionError::Engine(EngineError::Backend(_)))
                if self.departure_blocks_sends(&session, group_id) =>
            {
                Err(NostrError::SendBlockedByDeparture)
            }
            sent => sent.map_err(map_mls_err),
        };
        let result = self.noted(&session, result);
        let result = self.behind_what_was_handed_back(ahead, result);
        #[cfg(any(test, feature = "test-utils"))]
        let result = result.map(|effects| self.beside_stranded_for_test(effects));
        let staged = self
            .staged(&mut session, result, now_ms, None, false, mode)
            .await;
        let recorded =
            staged.and_then(|staged| self.record_location(&session, staged, now_ms, mesh_only));
        drop(session);
        recorded
    }

    /// Gives the location `staged` carries its durable record — MDK's own
    /// for an application message (`traits/src/transport_adapter.rs`
    /// 272-279, 406-425): the exact signed event, frozen for the relays its
    /// circle names now, with the epoch it was sealed at — in the hold that
    /// sealed it. Nothing when the send was queued or made nothing.
    ///
    /// The record is what lets a later process find a send a kill
    /// interrupted, and end it unsent; it is never a queue. A put the store
    /// refuses fails the seal: the location is dropped, and what the hold
    /// had handed back is kept for the next batch.
    fn record_location(
        &self,
        session: &AccountDeviceSession,
        mut staged: Staged,
        now_ms: u64,
        mesh_only: bool,
    ) -> Result<(Staged, Option<RecordedLocation>)> {
        let sealed = staged
            .effects
            .publish
            .iter()
            .position(|work| matches!(work, PublishWork::ApplicationMessage { .. }))
            .filter(|_| staged.effects.queued.is_empty());
        let Some(at) = sealed else {
            return Ok((staged, None));
        };
        let recorded = Self::put_location_fanout(session, &staged.effects.publish[at], now_ms);
        match recorded {
            Ok(recorded) => {
                crate::relay::fanout::own(recorded.id.message());
                self.own_locations
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .insert(recorded.id.message().clone(), mesh_only);
                Ok((staged, Some(recorded)))
            }
            Err(e) => {
                log::warn!(
                    "[Fanout] a sealed location could not be recorded and is dropped unsent: {}",
                    e.code()
                );
                staged.effects.publish.remove(at);
                self.keep_handed_back(staged.effects);
                Err(e)
            }
        }
    }

    fn put_location_fanout(
        session: &AccountDeviceSession,
        work: &PublishWork,
        now_ms: u64,
    ) -> Result<RecordedLocation> {
        let PublishWork::ApplicationMessage {
            msg,
            group_id,
            app_event_id,
            source_epoch,
            retention,
            authority,
            ..
        } = work
        else {
            return Err(NostrError::MdkError("not a sealed application message"));
        };
        let TransportEnvelope::GroupMessage { transport_group_id } = &msg.envelope else {
            return Err(NostrError::MdkError("a location is not a group message"));
        };
        let endpoints = fanout_targets(session, group_id)?;
        let mut fanout = OutboundFanout::stage(
            TransportPublishRequest {
                account_id: session.self_id(),
                target: TransportPublishTarget::Group {
                    group_id: group_id.clone(),
                    transport_group_id: transport_group_id.clone(),
                    endpoints: endpoints.clone(),
                },
                // One relay's acknowledgement is a location's success.
                required_acks: 1,
                message: msg.clone(),
            },
            None,
            None,
            now_ms,
        )
        .map_err(|_| NostrError::MdkError("the fanout record was refused"))?;
        fanout
            .set_application_message(OutboundApplicationMessage {
                group_id: group_id.clone(),
                app_event_id: app_event_id.clone(),
                source_epoch: *source_epoch,
                retention: *retention,
                authority: *authority,
            })
            .map_err(|_| NostrError::MdkError("the fanout record was refused"))?;
        session.put_outbound_fanout(&fanout).map_err(map_mls_err)?;
        Ok(RecordedLocation {
            id: FanoutId::new(group_id.clone(), fanout.message_id().clone()),
            relays: endpoints.into_iter().map(|endpoint| endpoint.0).collect(),
        })
    }

    /// The stored application records — `group_id`'s, or every live
    /// circle's — in staging order, each with what a drive needs to decide
    /// what becomes of it.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted.
    pub(crate) async fn location_fanouts(
        &self,
        group_id: Option<&GroupId>,
    ) -> Result<Vec<LocationRecord>> {
        let session = self.reading().await;
        let rows = group_id
            .map_or_else(
                || session.outbound_fanouts(),
                |group_id| session.outbound_fanouts_for_group(group_id),
            )
            .map_err(map_mls_err)?;
        drop(session);
        let here = self
            .own_locations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        Ok(rows
            .iter()
            .filter(|row| row.application_message().is_some())
            .filter_map(|row| {
                Some(LocationRecord {
                    id: FanoutId::new(row.group_id()?.clone(), row.message_id().clone()),
                    expires_at_secs: location_expiry_secs(row),
                    here: here.contains_key(row.message_id()),
                })
            })
            .collect())
    }

    /// What the application record `message` names says of its send: the
    /// relays it is frozen for, when its event expires, and whether it may
    /// be sent now ([`Self::location_may_be_sent`]), read in one hold of the
    /// engine immediately before the send. `None` when no such record is
    /// stored — its send was completed, or it was ended.
    ///
    /// # Errors
    ///
    /// Returns the engine's error, redacted, and [`NostrError::EngineHeld`]
    /// while a rolled-back commit is not yet retired.
    pub(crate) async fn location_to_send(
        &self,
        message: &MessageId,
        now_ms: u64,
        mode: DriveMode,
    ) -> Result<Option<LocationToSend>> {
        let mut session = self.engine().await?;
        let rows = session.outbound_fanouts().map_err(map_mls_err)?;
        // A record of another process is not in the map, and so is neither
        // sent nor known as sealed for the mesh alone.
        let sealed_here = self
            .own_locations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(message)
            .copied();
        let found = rows
            .iter()
            .find(|row| row.message_id() == message)
            .and_then(|row| Some((row, row.application_message()?)))
            .map(|(row, application)| {
                // Before the check: a circle silenced while it runs — a
                // leave asked, fetched input held, with no engine hold — is
                // then handed nothing by this send.
                let silences = self.mesh_silences(&application.group_id);
                let may_be_sent = sealed_here.is_some()
                    && self.location_may_be_sent(
                        &mut session,
                        &application.group_id,
                        application.source_epoch,
                        now_ms,
                        mode,
                    );
                LocationToSend {
                    relays: row
                        .request()
                        .target
                        .endpoints()
                        .iter()
                        .map(|endpoint| endpoint.as_str().to_owned())
                        .collect(),
                    expires_at_secs: location_expiry_secs(row),
                    may_be_sent,
                    mesh_only: sealed_here == Some(true),
                    mesh_turn: may_be_sent
                        .then(|| self.mesh_turn(&*session, &application.group_id, now_ms, silences))
                        .flatten(),
                }
            });
        drop(session);
        Ok(found)
    }

    /// Whether a location sealed in `group_id` at `source_epoch` may still
    /// be sent, and on any doubt not. Read, in one engine hold:
    /// - the circle's row still exists (a left circle sends nothing);
    /// - this device is still a member — MDK's own rule is that a removed
    ///   copy never publishes (`message_processor/ingest.rs` 2452-2456), and
    ///   a record it cannot read is a removed one;
    /// - the circle stands, stable, on the very epoch it was sealed at, so a
    ///   member removed since — who could still read it — is not handed it
    ///   by a relay that does not hold it yet;
    /// - nothing it has received is still unresolved: MDK queues a fresh
    ///   application message then (`message_processor/mod.rs` 1219-1230),
    ///   and a commit taken in may remove a member;
    /// - no commit of this device's is staged and nothing stranded is owed;
    /// - no hold stands ([`Self::away_hold`]: a leave, or for a call that is
    ///   not a claimed foreground's, what a circle was left waiting for);
    /// - a scheduled departure holds it as the seal's own hold does
    ///   (`departure_holds_a_send`): inside the wait a refused eviction
    ///   earned, or once due for a call that makes no commit. Never off the
    ///   engine's wall-clock timer alone in the full mode, whose due-ness the
    ///   seal does not read either: a send would otherwise turn on how much
    ///   real time passed since its seal.
    ///
    /// Read before the send begins: bytes already handed over are not
    /// recalled by a commit applied while they travel.
    fn location_may_be_sent(
        &self,
        session: &mut AccountDeviceSession,
        group_id: &GroupId,
        source_epoch: EpochId,
        now_ms: u64,
        mode: DriveMode,
    ) -> bool {
        let stranded = self
            .holding_stranded
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(group_id);
        session
            .group_record(group_id)
            .is_ok_and(|group| !group.removed)
            && matches!(
                session.epoch_state(group_id),
                Some(EpochState::Stable { epoch }) if epoch == source_epoch
            )
            && matches!(session.has_pending_convergence_inputs(group_id), Ok(false))
            && Self::staged_ref_of(session, group_id).is_none()
            && !stranded
            && self.commit_notes.circle_stands(group_id).unwrap_or(false)
            && self.away_hold(session, group_id, mode).is_none()
            && match session.scheduled_self_remove_auto_commit_delay_ms(group_id) {
                Ok(None) => true,
                Ok(Some(due_in_ms)) => {
                    !(self.restage_wait_runs(group_id, now_ms)
                        || (mode == DriveMode::FinishOnly
                            && due_in_ms == 0
                            && self.departure_stands(group_id)))
                }
                Err(_) => false,
            }
    }

    /// Deletes every location record of `group_id`, unsent: its circle was
    /// left or disbanded, and its mesh keys go with them. A store error
    /// leaves the rest for their expiration, and the send's own check finds
    /// no circle row to send for.
    pub(crate) async fn end_location_records(&self, group_id: &GroupId) {
        let rows = {
            let session = self.reading().await;
            self.mesh_keys.forget(&*session, group_id);
            session
                .outbound_fanouts_for_group(group_id)
                .unwrap_or_default()
        };
        for row in rows
            .iter()
            .filter(|row| row.application_message().is_some())
        {
            let _ = self.end_location(row.message_id()).await;
        }
    }

    /// Ends the application record `message` names: its send has returned,
    /// its event has expired, or it is one nothing may send. The second and
    /// last write of a location's send.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted; the row is kept, and
    /// ends at its expiration.
    pub(crate) async fn end_location(&self, message: &MessageId) -> Result<()> {
        self.reading()
            .await
            .delete_outbound_fanout(message)
            .map_err(map_mls_err)?;
        crate::relay::fanout::release(message);
        self.own_locations
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(message);
        Ok(())
    }

    /// [`Self::add_members`] in staging mode. The Welcomes are frozen in the
    /// commit's fanout, to be released by its confirm.
    ///
    /// # Errors
    ///
    /// As [`Self::add_members`] and [`Self::send_staging`].
    pub async fn add_members_staging(
        &self,
        group_id: &GroupId,
        key_packages: Vec<KeyPackage>,
        now_ms: u64,
    ) -> Result<Staged> {
        self.send_staging(Self::invite_intent(group_id, key_packages), now_ms)
            .await
    }

    /// [`Self::remove_members`] in staging mode.
    ///
    /// # Errors
    ///
    /// As [`Self::remove_members`] and [`Self::send_staging`].
    pub async fn remove_members_staging(
        &self,
        group_id: &GroupId,
        member_pubkeys: &[String],
        now_ms: u64,
    ) -> Result<Staged> {
        self.send_staging(Self::removal_intent(group_id, member_pubkeys)?, now_ms)
            .await
    }

    /// [`Self::update_relays`] in staging mode. The commit's fanout targets
    /// the relays of the epoch it leaves, not the ones it names.
    ///
    /// # Errors
    ///
    /// As [`Self::update_relays`] and [`Self::send_staging`].
    pub async fn update_relays_staging(
        &self,
        group_id: &GroupId,
        relays: Vec<String>,
        now_ms: u64,
    ) -> Result<Staged> {
        let intent = self.relay_update_intent(group_id, relays).await?;
        self.send_staging(intent, now_ms).await
    }

    /// The advance of a plane that drives what it stages: what the engine
    /// releases — a due `SelfRemove` eviction, the user's re-proposed leave, a
    /// change the user queued — gets its record in the hold that staged it.
    ///
    /// MDK's host's rule (`marmot-account/src/runtime.rs` 2403-2413): while
    /// the circle has a commit record still pending, only its convergence
    /// inputs are settled (`advance_convergence_inputs`), so nothing new is
    /// produced behind work that has not left; otherwise the full advance
    /// runs, and the queue drains. Where Haven differs is which record holds
    /// the queue back: one that is still pending, never an applied one that
    /// only owes a second relay.
    ///
    /// Before a full advance each queued change that can no longer be made
    /// is retired ([`Self::retire_unmakeable_queued_changes`]), and a full
    /// advance that fails is followed, in the same hold, by the inputs-only
    /// one ([`Self::after_a_failed_advance`]).
    ///
    /// The full advance is not held back until the circle's backlog has been
    /// read. It could not usefully be: while an admin's change is queued the
    /// engine applies nothing it has received until that change has had its
    /// one attempt (`cgka-engine/src/distributed_convergence.rs` 728-744, the
    /// spec's one-attempt reservation), and only the full advance makes it.
    ///
    /// Then, as [`Self::advance_for_receive`], more advances while deferred
    /// peels are untried, each in its own hold.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown or the first advance fails; a
    /// later failure returns what the earlier advances produced.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn advance_for_drive(&self, group_id: &GroupId, now_ms: u64) -> Result<Staged> {
        self.advance_for_drive_while(group_id, now_ms, Still::always(&DriveMode::Full))
            .await
    }

    /// [`Self::advance_for_drive`] if the full mode its caller decided on
    /// `still` holds once the engine is held; the advance of a plane that
    /// makes no commit otherwise ([`Self::settle_inputs_for_drive`]): the
    /// wait for the engine is where a foreground ends, and a commit staged
    /// behind that would be one a paused plane made. Each further advance
    /// asks again in its own hold, and ends the call where it no longer
    /// holds.
    ///
    /// A test's entry alone is [`Self::advance_for_drive`]: no shipped call
    /// makes the full advance in a mode it has not just read again.
    ///
    /// # Errors
    ///
    /// As [`Self::advance_for_drive`].
    pub(crate) async fn advance_for_drive_while(
        &self,
        group_id: &GroupId,
        now_ms: u64,
        still: Still<'_>,
    ) -> Result<Staged> {
        let deadline = std::time::Instant::now() + DEFERRED_PEEL_DRAIN_BUDGET;
        let mut session = self.engine().await?;
        if !still.holds() {
            drop(session);
            return self.settle_inputs_for_drive(group_id, now_ms).await;
        }
        let mut all = self
            .advance_once_for_drive(&mut session, group_id, now_ms, still)
            .await?;
        drop(session);
        for _ in 1..DEFERRED_PEEL_DRAIN_ADVANCES {
            if std::time::Instant::now() >= deadline {
                break;
            }
            let Ok(mut session) = self.engine().await else {
                break;
            };
            if !still.holds() || !Self::peel_drain_due(&mut session, group_id) {
                break;
            }
            let Ok(more) = self
                .advance_once_for_drive(&mut session, group_id, now_ms, still)
                .await
            else {
                break;
            };
            drop(session);
            all.effects = chain_effects(all.effects, more.effects);
            all.fanouts.extend(more.fanouts);
            all.proposals.extend(more.proposals);
        }
        Ok(all)
    }

    async fn advance_once_for_drive(
        &self,
        session: &mut AccountDeviceSession,
        group_id: &GroupId,
        now_ms: u64,
        still: Still<'_>,
    ) -> Result<Staged> {
        self.count_advance(group_id);
        // Handed back before the roster is read: a leave among it is a
        // proposal the commit could take in.
        let ahead = Box::pin(self.hand_back_stranded(session, Some(group_id), true)).await?;
        let before = self.roster_before(session, group_id);
        // Asked again, and nothing is awaited between this and the advance:
        // a hand-back takes long enough for a foreground to end in it.
        let holds = still.holds();
        // Nor for a circle held for a routing collision: in the circle MDK
        // has stopped routing to, an engine commit would be made at a stale
        // epoch — a fork a member removed since can read. The eviction is
        // left to the other members; where none of them can commit it, it
        // stays unmade, which costs nothing while nothing is sealed.
        // And no self-update the engine queued is drained into a commit
        // nobody asked for: one that could not be retired holds the circle
        // to the inputs-only advance.
        let result = if holds
            && !Self::has_pending_record(session, group_id)
            && !self.routing_collided(group_id)
            && self.retire_queued_self_updates(session, group_id)
        {
            self.retire_unmakeable_queued_changes(session, group_id, false);
            let staged_before = Self::staged_ref_of(session, group_id);
            let full = Box::pin(session.advance_convergence(group_id)).await;
            let full = match self.advance_fault() {
                Some(fault) if full.is_ok() => Err(fault),
                _ => full,
            };
            match full {
                Ok(effects) => Ok(effects),
                Err(e) => {
                    self.after_a_failed_advance(session, group_id, &e, staged_before)
                        .await
                }
            }
        } else {
            Box::pin(session.advance_convergence_inputs(group_id))
                .await
                .map_err(map_mls_err)
        };
        let mode = if holds {
            DriveMode::Full
        } else {
            DriveMode::FinishOnly
        };
        let result = self.noted(session, result);
        let result = self.behind_what_was_handed_back(ahead, result);
        self.staged(session, result, now_ms, before.as_ref(), true, mode)
            .await
    }

    /// The advance of a call that makes no new commit
    /// ([`DriveMode::FinishOnly`]): MDK's inputs-only advance, which settles
    /// what the circle has received and stages nothing — no eviction, and
    /// nothing the user queued (`cgka-session/src/lib.rs` 1053-1062). The one
    /// thing it can hand back to be published is the user's own leave,
    /// proposed again by the engine for an epoch a commit it applied has
    /// just reached (`cgka-engine/src/message_processor/ingest.rs` 1817): the
    /// engine mints that once per epoch and hands it over in memory only, so
    /// it is recorded in this hold like any other, and left for a full drive
    /// to send: the one record a finish-only call writes.
    ///
    /// An inputs-only advance cannot give a queued change of the group its
    /// one attempt, and until it has had it the engine takes up nothing the
    /// circle has received
    /// (`cgka-engine/src/distributed_convergence.rs` 728-746): the circle
    /// would stay at its epoch, sealing for whoever has been removed since,
    /// for as long as this device is driven in this mode alone. So when that
    /// is the state the advance leaves — input waiting, no pass open to take
    /// it up, a change of the group queued — the change is retired, its
    /// circle told first ([`ChangeNote::QueuedChangeDropped`]), and the
    /// advance made again. Never before: a change that is not in the way is
    /// kept for the full advance that makes it.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown or the advance fails.
    pub(crate) async fn settle_inputs_for_drive(
        &self,
        group_id: &GroupId,
        now_ms: u64,
    ) -> Result<Staged> {
        self.count_advance(group_id);
        let mut session = self.engine().await?;
        let ahead = Box::pin(self.hand_back_stranded(&mut session, Some(group_id), false)).await?;
        let advanced = Box::pin(session.advance_convergence_inputs(group_id))
            .await
            .map_err(map_mls_err);
        let advanced = self.noted(&session, advanced);
        let mut result = self.behind_what_was_handed_back(ahead, advanced);
        // A claimed foreground's drive gives the change its full advance
        // (`EngineProcessor::drive_due`): nothing is retired under it.
        if result.is_ok()
            && self.away_from_the_foreground()
            && self.reservation_freezes(&session, group_id)
        {
            self.retire_unmakeable_queued_changes(&mut session, group_id, true);
            let again = Box::pin(session.advance_convergence_inputs(group_id))
                .await
                .map_err(map_mls_err);
            if let (Ok(first), Ok(then)) = (&mut result, self.noted(&session, again)) {
                *first = chain_effects(std::mem::replace(first, empty_effects()), then);
            }
        }
        let staged = self
            .staged(
                &mut session,
                result,
                now_ms,
                None,
                true,
                DriveMode::FinishOnly,
            )
            .await;
        drop(session);
        staged
    }

    /// Whether a queued change of `group_id` is holding back what the circle
    /// has received: input is waiting, a change of the group is queued, and
    /// the engine holds its one-attempt reservation for it — the circle's
    /// convergence pass is completed with its fairness slot still available,
    /// which is the engine's own test for opening no further pass until the
    /// queued change has had its attempt
    /// (`cgka-engine/src/distributed_convergence.rs` 728-746).
    ///
    /// Read from the stored pass, never asked of the engine: its
    /// `prepare_convergence_cutoff_delay_ms` is a command that may itself
    /// open a pass or use the slot, and under the reservation it answers
    /// "due now" for a circle that is held all the same whenever canonical
    /// applications are pending behind the unresolved input
    /// (`distributed_convergence.rs` 218-230) — the inputs-only advance never
    /// reaches their drain (`message_processor/mod.rs` 1558-1567).
    ///
    /// A read that fails answers no on every leg: a change the user asked
    /// for is never retired because the store was busy.
    fn reservation_freezes(&self, session: &AccountDeviceSession, group_id: &GroupId) -> bool {
        matches!(
            session.epoch_state(group_id),
            Some(EpochState::Stable { .. })
        ) && session
            .has_pending_convergence_inputs(group_id)
            .unwrap_or(false)
            && !queued_group_changes(&self.message_store, group_id).is_empty()
            && reservation_held(&self.message_store.convergence_pass(group_id))
    }

    /// What is done in the hold of a full advance that failed.
    ///
    /// `cgka-session` returns an advance's error before it collects effects
    /// (v0.10.4 `cgka-session/src/lib.rs` 1043-1050), so whatever the failed
    /// call had already emitted is still in the engine's one-shot buffers:
    /// the inputs-only advance that follows collects it, and settles what
    /// the circle has received. That is all the fallback is for. The engine
    /// runs its own maintenance — a due eviction, a leave proposed again —
    /// BEFORE it prepares anything queued, and returns an error only from
    /// the queue (`cgka-engine/src/message_processor/mod.rs` 987-1011, 1059):
    /// a queued change that cannot be prepared does not hold maintenance
    /// back, it holds back what is queued behind it.
    ///
    /// The engine can fail AFTER it staged a queued change
    /// (`mod.rs` 1077-1083): the result is dropped with the error and the
    /// commit stays staged with no handle and no record. Nothing has left
    /// the device, so it is rolled back here — only when this very call
    /// staged it (`staged_before`), never a commit some other call staged
    /// and may have published.
    async fn after_a_failed_advance(
        &self,
        session: &mut AccountDeviceSession,
        group_id: &GroupId,
        failed: &SessionError,
        staged_before: Option<PendingStateRef>,
    ) -> Result<SessionEffects> {
        log::warn!(
            "[Fanout] a circle's full advance failed; what it left is collected and its \
             queue is not drained: {}",
            failed.kind()
        );
        let mut left = empty_effects();
        if let Some(pending) =
            Self::staged_ref_of(session, group_id).filter(|_| staged_before.is_none())
        {
            log::warn!("[Fanout] a commit a failed advance left staged is rolled back unsent");
            if let Ok(undone) = self.unstage_unsent(session, pending).await {
                left = undone;
            }
        }
        // Whatever the cause, the circle's queue did not drain.
        if !failed.is_transient()
            && session
                .has_queued_outbound_intents(group_id)
                .unwrap_or(false)
        {
            let _ = self
                .commit_notes
                .note(group_id, ChangeNote::QueuedChangesHeld);
        }
        let collected = Box::pin(session.advance_convergence_inputs(group_id))
            .await
            .map_err(map_mls_err)?;
        Ok(chain_effects(left, collected))
    }

    /// The plain rollback of a commit this hold staged, recorded nowhere and
    /// sent to nobody.
    async fn unstage_unsent(
        &self,
        session: &mut AccountDeviceSession,
        pending: PendingStateRef,
    ) -> Result<SessionEffects> {
        self.publish_failed_in(session, pending, true).await
    }

    /// The pending ref `group_id`'s staged commit is held under, when it has
    /// one.
    fn staged_ref_of(
        session: &AccountDeviceSession,
        group_id: &GroupId,
    ) -> Option<PendingStateRef> {
        match session.epoch_state(group_id) {
            Some(EpochState::PendingPublish(staged)) => Some(staged.pending_ref()),
            _ => None,
        }
    }

    /// The error the next full advance of a driving plane is to fail with
    /// once the engine has run it, when a test has queued one.
    #[cfg(any(test, feature = "test-utils"))]
    fn advance_fault(&self) -> Option<SessionError> {
        self.advance_faults
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .pop_front()
    }

    #[cfg(not(any(test, feature = "test-utils")))]
    #[allow(clippy::unused_self)]
    const fn advance_fault(&self) -> Option<SessionError> {
        None
    }

    /// Now, for a hold whose caller hands it no clock — a legacy send, a
    /// receive plane's advance: the device's own, in the milliseconds a
    /// stored wait is written in.
    #[cfg_attr(not(any(test, feature = "test-utils")), allow(clippy::unused_self))]
    pub(crate) fn legacy_now_ms(&self) -> u64 {
        #[cfg(any(test, feature = "test-utils"))]
        {
            let set = self.legacy_now_ms.load(std::sync::atomic::Ordering::SeqCst);
            if set != 0 {
                return set;
            }
        }
        u64::try_from(chrono::Utc::now().timestamp_millis()).unwrap_or(0)
    }

    /// Sets what [`Self::legacy_now_ms`] answers: a driver test's clock is
    /// the test's, and a wait it stored is not one the device's clock is in.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn set_legacy_clock_for_test(&self, now_ms: u64) {
        self.legacy_now_ms
            .store(now_ms, std::sync::atomic::Ordering::SeqCst);
    }

    /// Makes the next plain rollback fail: with `after_the_rewind`, after
    /// the engine ran it — the rewind landed and the call still errored, as a
    /// replay error leaves it; without, in the engine's place — nothing was
    /// rewound.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn fail_next_rollback_for_test(&self, after_the_rewind: bool) {
        self.queue_rollback_fault(if after_the_rewind {
            RollbackFault::ErrorsAfterTheRewind
        } else {
            RollbackFault::Refused
        });
    }

    /// Makes the next plain rollback never return — with `after_the_rewind`
    /// once the engine has rewound, without before it is asked: the two
    /// places a caller that drops the call's future can leave it.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn park_next_rollback_for_test(&self, after_the_rewind: bool) {
        self.queue_rollback_fault(if after_the_rewind {
            RollbackFault::ParksAfterTheRewind
        } else {
            RollbackFault::ParksBeforeTheRewind
        });
    }

    #[cfg(any(test, feature = "test-utils"))]
    fn queue_rollback_fault(&self, fault: RollbackFault) {
        self.rollback_faults
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push_back(fault);
    }

    /// How many of [`Self::fail_next_rollback_for_test`]'s failures no
    /// rollback has met yet.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn rollback_faults_left_for_test(&self) -> usize {
        self.rollback_faults
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .len()
    }

    /// The fault a test queued for the next plain rollback.
    #[cfg(any(test, feature = "test-utils"))]
    fn rollback_fault(&self) -> Option<RollbackFault> {
        self.rollback_faults
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .pop_front()
    }

    #[cfg(not(any(test, feature = "test-utils")))]
    #[allow(clippy::unused_self)]
    const fn rollback_fault(&self) -> Option<RollbackFault> {
        None
    }

    /// Makes the next ingest return an error after the engine ran it, its
    /// result dropped ([`Self::ingest_faulted`]).
    #[cfg(any(test, feature = "test-utils"))]
    pub fn fail_next_ingest_for_test(&self) {
        self.ingest_fault
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }

    /// Whether the fault [`Self::fail_next_ingest_for_test`] armed is still
    /// to fire.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn ingest_fault_armed_for_test(&self) -> bool {
        self.ingest_fault.load(std::sync::atomic::Ordering::SeqCst)
    }

    #[cfg(any(test, feature = "test-utils"))]
    fn ingest_faulted(&self, result: Result<IngestEffects>) -> Result<IngestEffects> {
        if self
            .ingest_fault
            .swap(false, std::sync::atomic::Ordering::SeqCst)
        {
            return result.and(Err(NostrError::MdkError("injected")));
        }
        result
    }

    #[cfg(not(any(test, feature = "test-utils")))]
    #[allow(clippy::unused_self)]
    const fn ingest_faulted(&self, result: Result<IngestEffects>) -> Result<IngestEffects> {
        result
    }

    /// Makes the next full advance of a driving plane return an error after
    /// the engine ran it, its result dropped: what a store that fails behind
    /// the engine's own staging leaves.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn fail_next_full_advance_for_test(&self) {
        self.advance_faults
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push_back(SessionError::Storage(StorageError::Backend(
                "injected".to_owned(),
            )));
    }

    /// Retires each of `group_id`'s queued changes that can no longer be
    /// made as asked, in the hold of the full advance that would otherwise
    /// prepare it.
    ///
    /// The engine prepares a queued change at every full advance with no
    /// word on the epoch or the day it was asked in
    /// (`cgka-engine/src/message_processor/mod.rs` 1013-1060). One whose
    /// premise is gone fails that advance's queue for as long as it stays —
    /// and everything queued behind it waits — and then FIRES when the
    /// premise returns: a removal queued for a member somebody else has
    /// since removed takes that member out again the day they are invited
    /// back; a change an admin queued is made the day they are an admin
    /// again. So a change is checked against what is true now, and retired
    /// through the engine's own call
    /// (`AccountDeviceSession::confirm_regenerated_queued_intent`, which
    /// deletes a queued change by id: `mod.rs` 1287-1297) when:
    ///
    /// * it changes the group and this device is no longer an admin; or
    /// * it removes a member who is no longer in the circle.
    ///
    /// Its circle is told first ([`ChangeNote::QueuedChangeDropped`], or
    /// [`ChangeNote::QueuedRemovalDropped`] for the removal of somebody who
    /// is still in the circle): the
    /// note is the only other trace of what the user asked for, so a change
    /// whose note cannot be written stays queued. Nothing is read from the
    /// engine's error, and no change is blamed for one by its place in the
    /// queue. An invite, and an admin-policy change naming somebody who has
    /// left, are not judged — a choice: what they name could be read from a
    /// `KeyPackage`'s metadata and from the policy's own bytes.
    ///
    /// The queue is judged as the engine will meet it: up to and including
    /// the first change of the group that is KEPT, and no further. The
    /// engine prepares that one next and judges whatever follows against the
    /// circle it leaves — an invite of somebody, then their removal, is a
    /// removal that can be made by the time its turn comes.
    ///
    /// Only while the circle is stable, and a member is called gone only
    /// while the roster the engine reports is the applied one: with a commit
    /// of this device's own left staged under no ref — a process died inside
    /// an eviction's staging — the roster is that commit's, and the member it
    /// omits is still in the circle.
    ///
    /// With `every`, each change of the group is retired whatever the roster
    /// says: what a hold that can never make one does when the queue is what
    /// holds its circle still ([`Self::settle_inputs_for_drive`]).
    ///
    /// It stops at a change it could not retire or could not tell its circle
    /// of: that one is still queued, and whatever follows it would be judged
    /// against a circle it may yet change.
    fn retire_unmakeable_queued_changes(
        &self,
        session: &mut AccountDeviceSession,
        group_id: &GroupId,
        every: bool,
    ) {
        if !matches!(
            session.epoch_state(group_id),
            Some(EpochState::Stable { .. })
        ) {
            return;
        }
        let Ok(queue) = self.message_store.list_queued_outbound_intents(group_id) else {
            return;
        };
        if queue.is_empty() {
            return;
        }
        let (Ok(members), Ok(admins)) =
            (session.members(group_id), session.admin_pubkeys(group_id))
        else {
            return;
        };
        let own = session.self_id();
        let is_admin = admins
            .iter()
            .any(|admin| admin.as_slice() == own.as_slice());
        let applied = roster_is_applied(&self.message_store, group_id);
        let epoch = session.epoch(group_id).map_or(0, |epoch| epoch.0);
        let listed = |member: &MemberId| members.iter().any(|listed| &listed.id == member);
        for queued in queue {
            let gone: Vec<&MemberId> = match &queued.intent {
                SendIntent::RemoveMembers { members, .. } if applied => {
                    members.iter().filter(|member| !listed(member)).collect()
                }
                _ => Vec::new(),
            };
            if !changes_group(&queued.intent) {
                continue;
            }
            if !every && gone.is_empty() && is_admin {
                break;
            }
            // A removal of somebody who is still in the circle is said as
            // one: they can still read, and the user must ask again. While
            // the roster is a staged commit's, everyone it names may be.
            let still_listed: Vec<MemberId> = match &queued.intent {
                SendIntent::RemoveMembers { members, .. } => members
                    .iter()
                    .filter(|member| !applied || listed(member))
                    .cloned()
                    .collect(),
                _ => Vec::new(),
            };
            let dropped = if still_listed.is_empty() {
                ChangeNote::QueuedChangeDropped
            } else {
                ChangeNote::QueuedRemovalDropped
            };
            let told_before = self.commit_notes.peek(group_id).contains(&dropped);
            // Who it named is kept first, as the note is said first: while
            // one of them is listed nothing is sealed for the circle away
            // from the foreground ([`Self::held_away`]).
            if (!still_listed.is_empty()
                && !self.commit_notes.keep_removal_targets(
                    group_id,
                    &still_listed,
                    epoch,
                    asks_spent(&queued),
                ))
                || !self.commit_notes.note(group_id, dropped)
            {
                log::warn!(
                    "[Fanout] a queued change that can no longer be made stays queued: its \
                     circle could not be told"
                );
                break;
            }
            let retired = session.confirm_regenerated_queued_intent(&QueuedIntentRef {
                group_id: queued.group_id.clone(),
                intent_id: queued.id.clone(),
            });
            if let Err(e) = retired {
                log::warn!(
                    "[Fanout] a queued change that can no longer be made was not retired: {}",
                    e.kind()
                );
                // Still queued, so not dropped: the note written ahead of the
                // retirement is taken back unless an earlier one stands.
                if !told_before {
                    self.commit_notes.clear(group_id, dropped);
                }
                break;
            }
            log::warn!("[Fanout] a queued change that can no longer be made was retired unmade");
            self.dropped_removals
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .extend(
                    gone.into_iter()
                        .map(|member| hex::encode(member.as_slice())),
                );
        }
    }

    /// [`Self::retire_unmakeable_queued_changes`] alone, in a hold of its
    /// own: the check without the engine's attempt that follows it in a full
    /// advance.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn retire_unmakeable_queued_changes_for_test(&self, group_id: &GroupId) {
        if let Ok(mut session) = self.engine().await {
            self.retire_unmakeable_queued_changes(&mut session, group_id, false);
        }
    }

    /// As [`Self::retire_unmakeable_queued_changes_for_test`], retiring every
    /// change of the group whatever the roster says: what a hold that can
    /// never make one does.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn retire_every_queued_change_for_test(&self, group_id: &GroupId) {
        if let Ok(mut session) = self.engine().await {
            self.retire_unmakeable_queued_changes(&mut session, group_id, true);
        }
    }

    /// The circles that hold a queued change of the group, each of which is
    /// owed the engine's full advance: such a change keeps its circle from
    /// applying anything it receives until it has had its one attempt
    /// (`take_back_queued`). A queued location makes no such reservation and
    /// owes none. Empty when the store cannot be read.
    pub(crate) async fn groups_holding_queued_changes(&self) -> Vec<GroupId> {
        let _session = self.reading().await;
        let mut holding = self.message_store.list_groups().unwrap_or_default();
        holding.retain(|group_id| !queued_group_changes(&self.message_store, group_id).is_empty());
        holding
    }

    /// Records that `group_id` is caught up in this session: one fetch of
    /// its circle has been answered to the end — a catch-up sweep's top-down
    /// pass finished with a relay drained and every other one drained or
    /// given up on, or every relay of the live plane's subscription sent its
    /// end of stored events.
    pub(crate) fn mark_caught_up(&self, group_id: &GroupId) {
        self.caught_up
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(group_id.clone());
        let now_ms = self.legacy_now_ms();
        self.caught_up_since
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(group_id.clone())
            .or_insert(now_ms);
        #[cfg(any(test, feature = "test-utils"))]
        self.caught_up_marks.send_modify(|marks| *marks += 1);
    }

    /// Forgets that `group_id` — or, with `None`, every circle — is caught
    /// up: what was fetched to the end may have gone stale since. Cleared
    /// when the live plane pauses or stops, and for a circle when a sweep of
    /// it begins. What the circle kept to pass on to its relays was kept
    /// under the receive that ended, and goes with it
    /// ([`Self::mesh_bridge_take`]).
    pub(crate) fn forget_caught_up(&self, group_id: Option<&GroupId>) {
        let mut caught_up = self
            .caught_up
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match group_id {
            Some(group_id) => {
                caught_up.remove(group_id);
            }
            None => caught_up.clear(),
        }
        drop(caught_up);
        drop(self.mesh_keys.take_bridge(group_id));
    }

    /// Whether `group_id` is caught up in this session
    /// ([`Self::mark_caught_up`]) and nothing has ended that since
    /// ([`Self::forget_caught_up`]).
    fn caught_up(&self, group_id: &GroupId) -> bool {
        self.caught_up
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(group_id)
    }

    /// Whether a fellow member's location that reached `group_id` by mesh,
    /// which the engine has just read for the first time, is kept to be
    /// passed on to the circle's relays (plan §5.5): this device's last
    /// fetch of the circle was answered to the end — an update that arrives
    /// before a receive has completed is tied to no drive that may send it —
    /// and this device has not asked to leave. A circle with a commit of
    /// this device's pending, or input held unread, takes nothing in by mesh
    /// at all (`Publishing::mesh_drive`). What is kept is checked again,
    /// against the engine, immediately before it is sent
    /// ([`Self::mesh_bridge_check`]).
    fn keeps_to_pass_on(&self, group_id: &GroupId) -> bool {
        self.caught_up(group_id) && !self.leaving(group_id)
    }

    /// What `group_id` kept to pass on to its relays (plan §5.5), newest
    /// first, taken — the circle keeps none after this, so what the drive
    /// that asks does not send is never sent. Nothing unless `received`: the
    /// caller's word that this drive's own relay receive of the circle was
    /// answered to the end before its send. Only the caller knows where a
    /// drive begins; this session's own word, that the last receive
    /// completed and nothing has ended it since, is read with the rest
    /// ([`Self::mesh_bridge_check`]), and what was kept under a receive that
    /// has ended is gone already ([`Self::forget_caught_up`]). A device that
    /// publishes before it fetches so passes nothing on: a member a commit
    /// it has not fetched removed could otherwise read, from the relays, an
    /// update that reaches them today only within radio range.
    pub(crate) fn mesh_bridge_take(
        &self,
        group_id: &GroupId,
        received: bool,
    ) -> Vec<self::mesh::Candidate> {
        let waiting = self.mesh_keys.take_bridge(Some(group_id));
        if received {
            waiting
        } else {
            Vec::new()
        }
    }

    /// The event of `update`, one [`Self::mesh_bridge_take`] handed out, and
    /// the relays to hand it — or `None`: it is not sent. Read in one hold
    /// of the engine, immediately before the send:
    /// - the event can still reach a relay before it expires, and declares
    ///   no longer a life than a location of Haven's (`Candidate::in_time`);
    /// - a location this device sealed at the same epoch could be sent now
    ///   ([`Self::location_may_be_sent`]): this device is a member, the
    ///   circle stands stable on the very epoch the update was sealed at —
    ///   so nobody removed since is handed it, and its sender, whom the
    ///   engine authenticated at that epoch, is a member still — with
    ///   nothing received left unresolved, no commit staged, no hold and no
    ///   departure in the way;
    /// - the circle is still caught up, and holds no fetched input unread;
    /// - the relays are the circle's own, and among them only those of
    ///   `accepted`, the relays that took this device's own send;
    /// - no update of the same member was passed on in the last 72 seconds.
    pub(crate) async fn mesh_bridge_check(
        &self,
        group_id: &GroupId,
        update: self::mesh::Candidate,
        accepted: &[String],
        now_ms: u64,
        mode: DriveMode,
    ) -> Option<(Event, Vec<String>)> {
        let (event, epoch, sender) = update.in_time(now_ms)?;
        let mut session = self.engine().await.ok()?;
        let stands =
            self.location_may_be_sent(&mut session, group_id, EpochId(epoch), now_ms, mode)
                && self.caught_up(group_id)
                && !self.holds_unread_input(group_id);
        let targets = if stands {
            fanout_targets(&session, group_id).unwrap_or_default()
        } else {
            Vec::new()
        };
        drop(session);
        let accepted: Vec<RelayUrl> = (accepted.iter())
            .filter_map(|relay| RelayUrl::parse(relay).ok())
            .collect();
        let targets: Vec<String> = (targets.into_iter())
            .map(|endpoint| endpoint.0)
            .filter(|relay| RelayUrl::parse(relay).is_ok_and(|url| accepted.contains(&url)))
            .collect();
        (!targets.is_empty() && self.mesh_keys.bridges(group_id, &sender, now_ms))
            .then_some((event, targets))
    }

    /// Whether a full drive may stage `group_id`'s eviction left due: the
    /// circle is caught up in this session ([`Self::mark_caught_up`]), no
    /// convergence input is unresolved, and the departure still stands
    /// ([`Self::departure_stands`]). Before that the eviction would be made
    /// from an epoch the circle may have left — another member may have made
    /// it already, and two such commits fork the circle.
    pub(crate) async fn may_stage_left_due(&self, group_id: &GroupId) -> bool {
        let caught_up = self
            .caught_up
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(group_id);
        if !caught_up {
            return false;
        }
        let Ok(session) = self.engine().await else {
            return false;
        };
        let settled = matches!(session.has_pending_convergence_inputs(group_id), Ok(false));
        drop(session);
        settled && self.departure_stands(group_id)
    }

    /// Puts each of MDK's post-join obligations in the phase this device's
    /// state says it is in, and returns those still open. MDK writes one at
    /// every Welcome join (`cgka-engine/src/group_lifecycle.rs` 52-105) and
    /// only its forbidden account crate completes it; this mirrors that
    /// crate (`marmot-account/src/runtime.rs` 2810-2850, 2958-3020):
    ///
    /// * a circle this device is no longer in, or one removed or disbanded,
    ///   fails its obligation;
    /// * one whose canonical own leaf differs from the obligation's baseline
    ///   completes it — a confirmed post-join self-update, a repair (MDK
    ///   attaches it to the open obligation), or any commit of this device's
    ///   that rotated the leaf;
    /// * a completed one whose leaf is back at its baseline — the
    ///   self-update that completed it withdrawn by branch selection — is
    ///   opened again (MDK's post-compromise re-arm), and its circle's quiet
    ///   window restarts at `now_ms`, as MDK's re-arm restarts it
    ///   (`mark_evolution_superseded`): a switch at the same height moves no
    ///   epoch, so nothing else would.
    ///
    /// These are the only obligation writes Haven makes, and it never
    /// creates one. A circle the engine does not hold live is left as it is.
    fn settle_post_join(
        &self,
        session: &AccountDeviceSession,
        now_ms: u64,
    ) -> Vec<MaintenanceObligation> {
        let Ok(obligations) = session.maintenance_obligations() else {
            return Vec::new();
        };
        let own = session.self_id();
        let mut open = Vec::new();
        for mut obligation in obligations {
            if obligation.trigger != MaintenanceTrigger::PostJoin
                || obligation.phase == MaintenancePhase::Failed
            {
                continue;
            }
            let group_id = obligation.group_id.clone();
            let (Ok(group), Ok(members)) =
                (session.group_record(&group_id), session.members(&group_id))
            else {
                continue;
            };
            let mut rearmed = false;
            let phase = if group.is_terminal() || !members.iter().any(|member| member.id == own) {
                MaintenancePhase::Failed
            } else if Self::leaf_rotated(session, &obligation) {
                MaintenancePhase::Complete
            } else if obligation.phase == MaintenancePhase::Complete {
                rearmed = true;
                MaintenancePhase::CatchUp
            } else {
                obligation.phase
            };
            if phase != obligation.phase {
                obligation.phase = phase;
                if let Err(e) = session.put_maintenance_obligation(&obligation) {
                    // Not made due on a phase that could not be kept.
                    log::warn!("a post-join obligation was not updated: {}", e.kind());
                    continue;
                }
                if rearmed {
                    // `now_ms` was read before the engine was waited for: an
                    // input taken in meanwhile is later and stands.
                    self.state_input_at
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .entry(group_id)
                        .and_modify(|at| *at = (*at).max(now_ms))
                        .or_insert(now_ms);
                }
            }
            if !matches!(
                obligation.phase,
                MaintenancePhase::Complete | MaintenancePhase::Failed
            ) {
                open.push(obligation);
            }
        }
        open
    }

    /// Whether this device's canonical leaf in the obligation's circle is
    /// no longer the one it was joined with. An obligation with no baseline
    /// is satisfied only by a confirmed self-update made for it, as MDK's
    /// account crate completes one on `Confirmed`.
    fn leaf_rotated(session: &AccountDeviceSession, obligation: &MaintenanceObligation) -> bool {
        obligation.own_leaf_baseline_hash.as_ref().map_or_else(
            || {
                session
                    .group_evolutions_for_group(&obligation.group_id)
                    .is_ok_and(|evolutions| {
                        evolutions.iter().any(|evolution| {
                            evolution.phase == GroupEvolutionPhase::Confirmed
                                && matches!(
                                    &evolution.semantic,
                                    GroupEvolutionSemantic::SelfUpdate {
                                        obligation_id: Some(id),
                                        ..
                                    } if *id == obligation.id
                                )
                        })
                    })
            },
            |baseline| {
                session
                    .own_leaf_hash(&obligation.group_id)
                    .is_ok_and(|leaf| leaf != *baseline)
            },
        )
    }

    /// The circles whose post-join self-update a full drive may make at
    /// `now_ms` (on [`Self::legacy_now_ms`]), and how long until the next
    /// one may be, in milliseconds, when one is waiting only for time.
    ///
    /// A circle is due once its obligation is open
    /// ([`Self::settle_post_join`]), it is caught up in this session
    /// ([`Self::mark_caught_up`]), it may take a staged commit
    /// ([`Self::post_join_may_stage`]), and MDK's account crate's windows
    /// have passed ([`post_join_not_before`]): the 15 s grace after the end
    /// of stored events, a 60 s quiet window that any epoch change,
    /// accepted proposal or re-arm restarts, the obligation's own jitter, and
    /// the spacing after this session's last post-join self-update. The wait
    /// a rolled-back commit earned is another such time. These are
    /// earliest-allowed times that the full drives already running serve;
    /// nothing here arms a timer.
    pub(crate) async fn post_join_due(&self, now_ms: u64) -> (Vec<GroupId>, Option<u64>) {
        let Ok(session) = self.engine().await else {
            return (Vec::new(), None);
        };
        let open = self.settle_post_join(&session, now_ms);
        if open.is_empty() {
            return (Vec::new(), None);
        }
        let caught_up = self
            .caught_up
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        let since = self
            .caught_up_since
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        let inputs = self
            .state_input_at
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        let spaced = *self
            .post_join_spaced_until
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut due: Vec<GroupId> = Vec::new();
        let mut soonest: Option<u64> = None;
        for obligation in open {
            let group_id = &obligation.group_id;
            let Some(&caught_up_at) = since.get(group_id).filter(|_| caught_up.contains(group_id))
            else {
                continue;
            };
            if due.contains(group_id) || !self.post_join_may_stage(&session, group_id, now_ms) {
                if let Some(wait) = self.restage_wait_left_ms(group_id, now_ms) {
                    soonest = Some(soonest.map_or(wait, |least| least.min(wait)));
                }
                continue;
            }
            let not_before = post_join_not_before(
                caught_up_at,
                inputs.get(group_id).copied(),
                obligation.sampled_jitter_ms,
                spaced,
            );
            if not_before <= now_ms {
                due.push(group_id.clone());
            } else {
                let wait = not_before - now_ms;
                soonest = Some(soonest.map_or(wait, |least| least.min(wait)));
            }
        }
        drop(session);
        (due, soonest)
    }

    /// Whether `group_id` may take a post-join self-update at `now_ms`:
    /// stable, settled, nothing of this device's staged, recorded or queued,
    /// no proposal pending, outside the wait a rolled-back commit earned
    /// ([`Self::hold_restaging`]: relays that proved they refuse it are not
    /// asked again sooner), and not being left, disbanded, unrecoverable or
    /// held for a routing collision. A read that fails declines.
    fn post_join_may_stage(
        &self,
        session: &AccountDeviceSession,
        group_id: &GroupId,
        now_ms: u64,
    ) -> bool {
        !self.restage_wait_runs(group_id, now_ms)
            && matches!(session.has_pending_convergence_inputs(group_id), Ok(false))
            && matches!(
                session.epoch_state(group_id),
                Some(EpochState::Stable { .. })
            )
            && Self::staged_ref_of(session, group_id).is_none()
            && !Self::has_pending_record(session, group_id)
            && matches!(session.has_queued_outbound_intents(group_id), Ok(false))
            && session
                .group_record(group_id)
                .is_ok_and(|group| group.disbanded.is_none() && !group.unrecoverable)
            && !self.leaving(group_id)
            && !self.routing_collided(group_id)
            && matches!(
                pending_proposal_in_window(&self.message_store, group_id),
                Ok(false)
            )
    }

    /// Records that a post-join self-update was made at `now_ms`: the next
    /// circle's waits at least a CSPRNG gap of [`POST_JOIN_SPACING_MIN_MS`]
    /// to [`POST_JOIN_SPACING_MAX_MS`] more, so two circles' commits never
    /// share a whole second (`INV-R-PER-CIRCLE-PUBLISH-DECORRELATED`).
    pub(crate) fn post_join_made(&self, now_ms: u64) {
        let span = POST_JOIN_SPACING_MAX_MS - POST_JOIN_SPACING_MIN_MS + 1;
        let gap = POST_JOIN_SPACING_MIN_MS + OsRng.next_u64() % span;
        *self
            .post_join_spaced_until
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(now_ms.saturating_add(gap));
    }

    /// Hands MDK the next change of this device's that branch selection
    /// withdrew (mdk#1734), through its own per-commit entry — never a
    /// second implementation — and returns what became of it; a withdrawn
    /// removal excepted, which is dropped as an offer instead
    /// ([`Self::drop_withdrawn_removal`], decision 233).
    ///
    /// What is owed is read from stored state, as MDK's state-derived form
    /// reads it (`own_commit_intent.rs` 334-344): a retained intent whose
    /// commit is parked `ConvergenceDeferred` or `EpochInvalidated`. So a
    /// withdrawal survives a process that never drove it. A removal is
    /// dropped at once, wherever its circle stands: its members are held
    /// from then. Another change is asked for only where nothing can make it
    /// from an epoch the circle may have left, or leave it queued: in a
    /// circle this session has caught up with ([`Self::mark_caught_up`])
    /// that is stable, with no convergence input unresolved, no commit of
    /// this device's staged and no group change queued — or one this device
    /// is no longer in, where MDK makes nothing, or holds no row for and
    /// that is stable, where what MDK queues again is taken back. A circle
    /// whose leave cannot be read — Haven's intent or MDK's own
    /// `LeaveRequest`, which a legacy leave writes alone — is skipped:
    /// whether a re-issued change would be made or retired cannot be told.
    /// With a change MDK queued again comes the id of its queued copy, for
    /// the drive to tell whether its advance released it.
    ///
    /// MDK's state-derived form, which re-issues every parked record it
    /// finds, runs only once nothing owed is left unasked — for what it
    /// alone does, collecting the records past the rewind horizon — so it
    /// finds nothing to re-issue. While anything is left (a circle not yet
    /// settled, a removal whose drop failed), it does not run.
    ///
    /// A circle being left gets nothing made again — MDK sends nothing of
    /// it but the leave (`LeaveGated`) — and the one copy MDK queued is taken
    /// back in this hold, through MDK's own delete. What the user has to ask
    /// again for is said durably ([`ChangeNote::ChangeWithdrawn`]; a
    /// removal's members are kept and hold the circle's sends,
    /// [`ChangeNote::QueuedRemovalDropped`]).
    pub(crate) async fn reissue_next_withdrawn(
        &self,
    ) -> Option<(WithdrawnChange, Option<SendIntent>)> {
        let Ok(mut session) = self.engine().await else {
            return None;
        };
        let caught_up = self
            .caught_up
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        let records = self.message_store.list_own_commit_intents(None).ok()?;
        let mut left_unasked = false;
        for record in records {
            if record.reinvite.is_some() {
                continue;
            }
            let Some(parked) = self.set_aside_commit(&record.commit_id) else {
                left_unasked = true;
                continue;
            };
            if !parked {
                continue;
            }
            let group_id = &record.group_id;
            // A withdrawn removal is never made again by itself (decision
            // 233): MDK's re-issue would remove a member the circle invited
            // back on the strength of a member id it cannot tell from the one
            // it named (T-REISSUE ask 4). One whose members are all gone is
            // already so and goes unsaid; any other is dropped as an offer,
            // its members held, and the user decides from the notice.
            if let SendIntent::RemoveMembers { members, .. } = &record.intent {
                let epoch = session.epoch(group_id).map_or(0, |epoch| epoch.0);
                let dropping = self.held_for(group_id).map(|held| {
                    if !held {
                        Dropping::NobodyToHold
                    } else if removal_satisfied(&self.message_store, &session, group_id, members) {
                        Dropping::AlreadySo(members.as_slice(), epoch)
                    } else {
                        Dropping::Held(members.as_slice(), epoch)
                    }
                });
                if let Some(dropped) = dropping.and_then(|dropping| {
                    self.drop_withdrawn_removal(&record.commit_id, group_id, dropping)
                }) {
                    drop(session);
                    return Some((dropped, None));
                }
                left_unasked = true;
                continue;
            }
            let Some(leaving) = self.withdrawn_circle(&session, &caught_up, group_id) else {
                left_unasked = true;
                continue;
            };
            let queued_before: Vec<_> = queued_group_changes(&self.message_store, group_id)
                .into_iter()
                .map(|queued| queued.id)
                .collect();
            match session.reissue_superseded_own_commit(&record.commit_id) {
                Ok(Some(report)) => {
                    let change = self.said_withdrawn(
                        &mut session,
                        &report,
                        leaving.then_some(queued_before.as_slice()),
                    );
                    let requeued = (change.outcome == WithdrawnOutcome::Reissued)
                        .then(|| {
                            queued_group_changes(&self.message_store, group_id)
                                .into_iter()
                                .find(|queued| !queued_before.contains(&queued.id))
                                .map(|queued| queued.intent)
                        })
                        .flatten();
                    drop(session);
                    return Some((change, requeued));
                }
                Ok(None) => {}
                Err(_) => left_unasked = true,
            }
        }
        if !left_unasked {
            // Collection only: everything it would re-issue was asked for
            // above.
            let _ = session.reissue_superseded_own_commits_from_state();
        }
        drop(session);
        None
    }

    /// Whether MDK may be asked about a withdrawn change of `group_id` now —
    /// `Some`, saying whether the circle is being left — or not now, which
    /// holds back the collection: something could not be read, or the
    /// circle is not settled. A circle this device keeps no row for — it was
    /// left, and its state is kept until it is forgotten — gets nothing made
    /// again; its records are asked about once it is stable.
    fn withdrawn_circle(
        &self,
        session: &AccountDeviceSession,
        caught_up: &HashSet<GroupId>,
        group_id: &GroupId,
    ) -> Option<bool> {
        // A change withdrawn from a circle held for a routing collision
        // stays owed, as a change asked for there is refused.
        if self.routing_collided(group_id) {
            return None;
        }
        let member = match self.message_store.get_group(group_id) {
            Ok(group) => !group.is_terminal(),
            Err(StorageError::NotFound) => false,
            Err(_) => return None,
        };
        let stable = matches!(
            session.epoch_state(group_id),
            Some(EpochState::Stable { .. })
        );
        match (member, self.commit_notes.circle_stands(group_id)) {
            (false, _) => Some(false),
            (true, Some(false)) => stable.then_some(true),
            (true, _) => {
                let settled = caught_up.contains(group_id)
                    && stable
                    && matches!(session.has_pending_convergence_inputs(group_id), Ok(false));
                self.leaving_once_settled(group_id, settled)
            }
        }
    }

    /// For a member's circle with a row: whether it is being left, once it is
    /// settled enough for MDK to be asked about its withdrawn change — Haven's
    /// intent, or a leave MDK holds that the legacy path asked for without
    /// one. Only a change that would be made needs the queue clear: one behind
    /// another change would wait in it; in a circle being left the copy is
    /// taken back whatever is queued. `None` while it is not settled, or its
    /// leave cannot be read.
    fn leaving_once_settled(&self, group_id: &GroupId, settled: bool) -> Option<bool> {
        use cgka_traits::storage::LeaveRequestStorage as _;
        let mdk_leave = self
            .message_store
            .leave_request(group_id)
            .map(|request| request.is_some());
        let queue_clear = || queued_group_changes(&self.message_store, group_id).is_empty();
        match (self.commit_notes.leaving(group_id), mdk_leave) {
            (Some(haven), Ok(mdk)) if settled && (haven || mdk || queue_clear()) => {
                Some(haven || mdk)
            }
            _ => None,
        }
    }

    /// Whether a removal of `group_id` set aside has anyone to hold the
    /// circle for: this device is still a member and keeps the circle's row.
    /// `None` when that cannot be read.
    fn held_for(&self, group_id: &GroupId) -> Option<bool> {
        let member = match self.message_store.get_group(group_id) {
            Ok(group) => !group.is_terminal(),
            Err(StorageError::NotFound) => false,
            Err(_) => return None,
        };
        Some(member && self.commit_notes.circle_stands(group_id)?)
    }

    /// Drops the withdrawn removal `commit_id` of `group_id` instead of
    /// handing it to MDK's re-issue (decision 233), and says so as
    /// `dropping` reads. [`Dropping::Held`]: every named member is kept with
    /// its asks spent, so the circle's sends are held while one is still
    /// listed, then the circle is told, and only then is MDK's record
    /// deleted. [`Dropping::AlreadySo`]: nothing is said, and every named
    /// member is kept as taken out at this epoch, with its asks spent, so
    /// that a reorg bringing one back holds the circle and says so as for
    /// any member a withdrawn commit had taken out. [`Dropping::NobodyToHold`]:
    /// the record goes alone, with nothing said. `None`, with the record left
    /// in place, when any of that fails.
    fn drop_withdrawn_removal(
        &self,
        commit_id: &MessageId,
        group_id: &GroupId,
        dropping: Dropping<'_>,
    ) -> Option<WithdrawnChange> {
        let (told, outcome) = match dropping {
            Dropping::Held(named, epoch) => (
                self.commit_notes.keep_removal_targets(
                    group_id,
                    named,
                    epoch,
                    MAX_REQUEUE_ATTEMPTS,
                ) && self.commit_notes.keep_dropped_removal(group_id, commit_id)
                    && self
                        .commit_notes
                        .note(group_id, ChangeNote::QueuedRemovalDropped)
                    && self
                        .commit_notes
                        .note(group_id, ChangeNote::ChangeWithdrawn),
                WithdrawnOutcome::Abandoned,
            ),
            Dropping::AlreadySo(named, epoch) => (
                self.commit_notes.keep_removal_targets(
                    group_id,
                    named,
                    epoch,
                    MAX_REQUEUE_ATTEMPTS,
                ) && self
                    .commit_notes
                    .take_out_removal_targets(group_id, named, epoch, None),
                WithdrawnOutcome::AlreadySatisfied,
            ),
            Dropping::NobodyToHold => (true, WithdrawnOutcome::NotMember),
        };
        if !told {
            return None;
        }
        self.message_store
            .delete_own_commit_intent(commit_id)
            .ok()?;
        Some(WithdrawnChange {
            group_id: group_id.clone(),
            kind: WithdrawnKind::RemoveMembers,
            outcome,
        })
    }

    /// Whether `commit` is stored as set aside by branch selection; `None`
    /// when the store cannot say.
    fn set_aside_commit(&self, commit: &MessageId) -> Option<bool> {
        match self.message_store.get_message(commit) {
            Ok(stored) => Some(matches!(
                stored.state,
                MessageState::ConvergenceDeferred | MessageState::EpochInvalidated
            )),
            Err(StorageError::NotFound) => Some(false),
            Err(_) => None,
        }
    }

    /// Every invite MDK holds owed a re-invite and has not given up on, with
    /// the invitees the circle does not list and where the circle stands
    /// ([`ReinviteStanding`]). One whose circle this device is no longer a
    /// member of, or whose invitees are all in, names nobody and ends: MDK's
    /// re-issue answers it on an empty set of key packages, as its own host
    /// does (`marmot-app/src/client/invite_recovery.rs` 277-280). A circle
    /// the store cannot read is left out.
    pub(crate) async fn owed_reinvites(&self) -> Vec<OwedReinvite> {
        let Ok(session) = self.engine().await else {
            return Vec::new();
        };
        let Ok(records) = session.pending_reinvites() else {
            return Vec::new();
        };
        let caught_up = self
            .caught_up
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        let mut owed = Vec::new();
        for record in records {
            let SendIntent::Invite { key_packages, .. } = &record.intent else {
                continue;
            };
            let listed: Vec<String> = match self.message_store.get_group(&record.group_id) {
                Ok(group) if !group.is_terminal() => group
                    .members
                    .iter()
                    .map(|member| hex::encode(member.id.as_slice()))
                    .collect(),
                Ok(_) | Err(StorageError::NotFound) => {
                    owed.push(OwedReinvite {
                        commit_id: record.commit_id,
                        group_id: record.group_id,
                        invitees: Vec::new(),
                        standing: ReinviteStanding::Ends,
                    });
                    continue;
                }
                Err(_) => continue,
            };
            let invitees: Vec<String> = key_packages
                .iter()
                .filter_map(|package| cgka_engine::key_package_metadata(package).ok())
                .map(|metadata| metadata.credential_identity_hex)
                .filter(|invitee| !listed.contains(invitee))
                .collect();
            let settled = caught_up.contains(&record.group_id)
                && matches!(
                    session.epoch_state(&record.group_id),
                    Some(EpochState::Stable { .. })
                )
                && matches!(
                    session.has_pending_convergence_inputs(&record.group_id),
                    Ok(false)
                );
            let standing = if invitees.is_empty() {
                ReinviteStanding::Ends
            } else if settled {
                ReinviteStanding::Settled
            } else {
                ReinviteStanding::Unsettled
            };
            owed.push(OwedReinvite {
                commit_id: record.commit_id,
                group_id: record.group_id,
                invitees,
                standing,
            });
        }
        drop(session);
        owed
    }

    /// Asks MDK for a lookup of fresh key packages for `commit_id`'s re-invite
    /// at `now_ms`, which it reserves durably before anything is fetched, so
    /// neither a cancelled call nor a restart resets its budget or its pacing.
    /// A store that cannot say reserves nothing.
    pub(crate) async fn reserve_reinvite(
        &self,
        commit_id: &MessageId,
        now_ms: u64,
    ) -> ReinviteReservation {
        let Ok(mut session) = self.engine().await else {
            return ReinviteReservation::NotDue;
        };
        let reserved = session.reserve_reinvite_lookup(commit_id, now_ms);
        let abandoned = || {
            self.message_store
                .own_commit_intent(commit_id)
                .ok()
                .flatten()
                .and_then(|record| record.reinvite)
                .is_some_and(|retry| retry.abandoned)
        };
        let reservation = match reserved {
            Ok(true) => ReinviteReservation::Reserved,
            Ok(false) if abandoned() => ReinviteReservation::GaveUp,
            Ok(false) | Err(_) => ReinviteReservation::NotDue,
        };
        drop(session);
        reservation
    }

    /// Hands `commit_id`'s re-invite to MDK with `key_packages` freshly found
    /// for its invitees. MDK queues the invite again and answers with its
    /// report, said durably where the user has to act; with a re-invite it
    /// queued comes the id of its queued copy, for the drive to tell whether
    /// its advance released it. `Ok(None)` when MDK has no such re-invite
    /// (any more).
    ///
    /// # Errors
    ///
    /// [`ReinviteRefusal::KeyPackage`] when MDK refuses a package — one the
    /// withdrawn invite already spent, which an invitee keeps published
    /// while the invitation is unanswered (Security Rule 5), or one naming
    /// nobody it invited (`own_commit_intent.rs` 516-526); and
    /// [`ReinviteRefusal::Failed`] when MDK or the store failed. MDK still
    /// owes the re-invite either way.
    pub(crate) async fn reissue_invite(
        &self,
        commit_id: &MessageId,
        key_packages: Vec<KeyPackage>,
    ) -> std::result::Result<Option<(WithdrawnChange, Option<SendIntent>)>, ReinviteRefusal> {
        let Ok(mut session) = self.engine().await else {
            return Err(ReinviteRefusal::Failed);
        };
        let record = match self.message_store.own_commit_intent(commit_id) {
            Ok(Some(record)) => record,
            Ok(None) => return Ok(None),
            Err(_) => return Err(ReinviteRefusal::Failed),
        };
        let group_id = record.group_id;
        let queued_before: Vec<_> = queued_group_changes(&self.message_store, &group_id)
            .into_iter()
            .map(|queued| queued.id)
            .collect();
        let report = match session.reissue_invite_with_key_packages(commit_id, key_packages) {
            Ok(Some(report)) => report,
            Ok(None) => return Ok(None),
            Err(SessionError::Engine(
                EngineError::InvalidWelcome
                | EngineError::InvalidKeyPackageLifetime { .. }
                | EngineError::InvalidKeyPackageCapabilities { .. },
            )) => return Err(ReinviteRefusal::KeyPackage),
            Err(_) => return Err(ReinviteRefusal::Failed),
        };
        let change = self.said_withdrawn(&mut session, &report, None);
        let requeued = (change.outcome == WithdrawnOutcome::Reissued)
            .then(|| {
                queued_group_changes(&self.message_store, &group_id)
                    .into_iter()
                    .find(|queued| !queued_before.contains(&queued.id))
                    .map(|queued| queued.intent)
            })
            .flatten();
        drop(session);
        Ok(Some((change, requeued)))
    }

    /// [`Self::reissue_next_withdrawn`] alone, as a test asks it: what MDK
    /// answered for the next change, when one was asked about.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn reissue_next_withdrawn_for_test(&self) -> Option<WithdrawnOutcome> {
        self.reissue_next_withdrawn()
            .await
            .map(|(change, _)| change.outcome)
    }

    /// Whether the change MDK queued again — `intent` — in `group_id` was
    /// released by the advance into one of the records `recorded`: a record
    /// whose commit carries that intent. Nothing else says so — not a copy
    /// that left the queue retired as moot, and not a read that failed.
    pub(crate) async fn released_into_record(
        &self,
        group_id: &GroupId,
        intent: &SendIntent,
        recorded: &[FanoutId],
    ) -> bool {
        let session = self.reading().await;
        let Ok(rows) = session.outbound_fanouts_for_group(group_id) else {
            return false;
        };
        drop(session);
        rows.iter()
            .filter(|row| recorded.iter().any(|id| id.message() == row.message_id()))
            .filter_map(OutboundFanout::pending_origin_message_id)
            .any(|origin| {
                self.message_store
                    .own_commit_intent(origin)
                    .is_ok_and(|own| own.is_some_and(|own| &own.intent == intent))
            })
    }

    /// The typed outcome of one MDK report, said durably where the user has
    /// to act. With `leaving_queued` — the circle is being left, and these
    /// are the ids its queue held before MDK answered — a change MDK queued
    /// again is taken back in this hold: the one id that is new.
    fn said_withdrawn(
        &self,
        session: &mut AccountDeviceSession,
        report: &cgka_traits::engine::SupersededIntentReport,
        leaving_queued: Option<&[MessageId]>,
    ) -> WithdrawnChange {
        use cgka_traits::engine::{SupersededIntentKind, SupersededIntentOutcome as Mdk};
        let group_id = &report.group_id;
        let kind = match report.kind {
            SupersededIntentKind::GroupProfile => WithdrawnKind::GroupProfile,
            SupersededIntentKind::AppComponents => WithdrawnKind::AppComponents,
            SupersededIntentKind::RemoveMembers => WithdrawnKind::RemoveMembers,
            SupersededIntentKind::Invite => WithdrawnKind::Invite,
        };
        let outcome = match report.outcome {
            Mdk::Reissued => leaving_queued.map_or(WithdrawnOutcome::Reissued, |before| {
                taken_back_for_leave(&self.message_store, session, group_id, before)
            }),
            Mdk::AlreadySatisfied => WithdrawnOutcome::AlreadySatisfied,
            Mdk::NotMember => WithdrawnOutcome::NotMember,
            Mdk::ReinviteRequired => {
                let _ = self.commit_notes.note(group_id, ChangeNote::ReinviteOwed);
                WithdrawnOutcome::ReinviteRequired
            }
            Mdk::Conflict => {
                let _ = self
                    .commit_notes
                    .note(group_id, ChangeNote::ChangeWithdrawn);
                WithdrawnOutcome::Conflict
            }
            // MDK spent its own asks on it, or found the circle's queue full:
            // the change is the user's to ask again. (A removal never comes
            // here: it is dropped before MDK is asked.)
            Mdk::Abandoned => {
                let _ = self
                    .commit_notes
                    .note(group_id, ChangeNote::ChangeWithdrawn);
                WithdrawnOutcome::Abandoned
            }
        };
        WithdrawnChange {
            group_id: group_id.clone(),
            kind,
            outcome,
        }
    }

    /// Whether this session asks for its removals set aside again on its own
    /// ([`REQUEUE_SET_ASIDE_REMOVALS`], or a test's word for one session).
    fn requeues(&self) -> bool {
        #[cfg(any(test, feature = "test-utils"))]
        if self.requeues_for_test.load(Ordering::SeqCst) {
            return true;
        }
        REQUEUE_SET_ASIDE_REMOVALS
    }

    /// Makes this session ask for its removals set aside again, as the
    /// automatic posture the owner may still choose would (decision 180).
    #[cfg(any(test, feature = "test-utils"))]
    pub fn requeue_for_test(&self) {
        self.requeues_for_test.store(true, Ordering::SeqCst);
    }

    /// What a full drive is to do with each removal set aside unmade
    /// (decision 180, automatic — [`REQUEUE_SET_ASIDE_REMOVALS`]): ask for it
    /// again for the members it named who are still listed.
    ///
    /// Only in a circle this session has caught up with, that is stable,
    /// with no convergence input unresolved, no commit of this device's
    /// staged and no group change queued — so the ask is made at once under
    /// a record, never queued — that this device is not leaving, and only
    /// while it is an admin. A member any commit this device applied took
    /// out is not asked for ([`CommitNotes::take_out_removal_targets`], at the
    /// fold): one removed and invited back is not removed again. And per
    /// member, bounded by Haven's own rule: [`MAX_REQUEUE_ATTEMPTS`] asks,
    /// each spent before its removal is asked for and given back when
    /// nothing was staged under a record, and none once
    /// the circle is past MDK's rewind horizon from the epoch the removal was
    /// set aside at. Past either bound the members stay held and the note
    /// stands for the user.
    pub(crate) async fn removals_to_requeue(&self) -> Vec<(GroupId, RemovalRequeue)> {
        if !self.requeues() {
            return Vec::new();
        }
        let Ok(session) = self.engine().await else {
            return Vec::new();
        };
        let caught_up = self
            .caught_up
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        let own = MemberId::new(self.identity_pubkey.to_bytes().to_vec());
        let mut decided = Vec::new();
        for group_id in self.message_store.list_groups().unwrap_or_default() {
            let settled = caught_up.contains(&group_id)
                && self.commit_notes.leaving(&group_id) == Some(false)
                && matches!(
                    session.epoch_state(&group_id),
                    Some(EpochState::Stable { .. })
                )
                && matches!(session.has_pending_convergence_inputs(&group_id), Ok(false))
                && queued_group_changes(&self.message_store, &group_id).is_empty()
                && self
                    .commit_notes
                    .stands(&group_id, ChangeNote::QueuedRemovalDropped)
                    == Some(true);
            if !settled {
                continue;
            }
            let (Some(kept), Ok(members), Ok(epoch)) = (
                self.commit_notes.kept_removals(&group_id),
                session.members(&group_id),
                session.epoch(&group_id),
            ) else {
                continue;
            };
            // Marks gone whoever the applied roster no longer lists, and with
            // the last of them takes the note back.
            if !removal_unmade(
                &self.message_store,
                self.commit_notes.as_ref(),
                &session,
                &group_id,
            ) {
                decided.push((group_id, RemovalRequeue::AlreadyMade));
                continue;
            }
            let admin = session.admin_pubkeys(&group_id).is_ok_and(|admins| {
                admins
                    .iter()
                    .any(|admin| admin.as_slice() == own.as_slice())
            });
            let listed: Vec<&KeptTarget> = kept
                .iter()
                .filter(|target| members.iter().any(|member| member.id == target.member))
                .collect();
            if listed.is_empty() || !admin {
                continue;
            }
            let expired = |target: &KeptTarget| {
                epoch.0 > target.set_aside_epoch.saturating_add(max_rewind_commits())
            };
            let askable: Vec<MemberId> = listed
                .iter()
                .filter(|target| !expired(target) && target.asks < MAX_REQUEUE_ATTEMPTS)
                .map(|target| target.member.clone())
                .collect();
            decided.push((
                group_id,
                if !askable.is_empty() {
                    RemovalRequeue::Remove(askable)
                } else if listed.iter().all(|target| expired(target)) {
                    RemovalRequeue::Expired
                } else {
                    RemovalRequeue::Abandoned
                },
            ));
        }
        drop(session);
        decided
    }

    /// Spends one ask of decision 180 against `members` of `group_id`,
    /// before their removal is asked for: one whose spend cannot be written
    /// is not asked for, so a store that will not count never lets every
    /// drive ask again. Returns whether it was spent.
    pub(crate) fn spend_requeue_ask(
        &self,
        group_id: &GroupId,
        members: &[MemberId],
    ) -> Option<Vec<(MemberId, u32)>> {
        self.commit_notes.count_removal_asks(group_id, members)
    }

    /// Gives back the ask [`Self::spend_requeue_ask`] spent: nothing was
    /// staged under it.
    pub(crate) fn refund_requeue_ask(&self, group_id: &GroupId, counted: &[(MemberId, u32)]) {
        self.commit_notes.refund_removal_asks(group_id, counted);
    }

    /// The circles whose eviction of a member who left the engine announces
    /// as due, outside any wait a refusal earned: a plane that makes no
    /// commit left it so — a background burst, a pause — or the driver
    /// rolled one back and the wait that earned is over. Nothing else
    /// stages it for a device that is not sending — the engine does so only
    /// in a send's preflight and in the full advance — so a full drive gives
    /// each the advance, once its circle is caught up
    /// ([`Self::may_stage_left_due`]).
    pub(crate) async fn evictions_left_due(&self, now_ms: u64) -> Vec<GroupId> {
        let Ok(mut session) = self.engine().await else {
            return Vec::new();
        };
        let mut due = self.message_store.list_groups().unwrap_or_default();
        due.retain(|group_id| {
            !self.restage_wait_runs(group_id, now_ms)
                && matches!(
                    session.scheduled_self_remove_auto_commit_delay_ms(group_id),
                    Ok(Some(0))
                )
        });
        drop(session);
        due
    }

    /// How long until the soonest wait a refused eviction earned is over,
    /// among the circles whose eviction the engine still announces: when a
    /// full drive next has one to stage again
    /// ([`Self::evictions_left_due`]). `None` when no such wait runs.
    pub(crate) async fn restage_due_after_ms(&self, now_ms: u64) -> Option<u64> {
        let mut session = self.engine().await.ok()?;
        let soonest = self
            .message_store
            .list_groups()
            .unwrap_or_default()
            .iter()
            .filter(|group_id| self.restage_wait_runs(group_id, now_ms))
            .filter(|group_id| {
                matches!(
                    session.scheduled_self_remove_auto_commit_delay_ms(group_id),
                    Ok(Some(_))
                )
            })
            .filter_map(|group_id| self.commit_notes.restage_wait(group_id))
            .map(|wait| wait.not_before_ms.saturating_sub(now_ms))
            .min();
        drop(session);
        soonest
    }

    /// Whether the commit `id`'s record holds changes the circle's relays. A
    /// record whose intent cannot be read is taken for one: its confirm is
    /// then left to a full drive.
    pub(crate) fn changes_routing(&self, id: &FanoutId) -> bool {
        match self.message_store.own_commit_intent(id.message()) {
            Ok(Some(own)) => matches!(
                own.intent,
                SendIntent::UpdateAppComponents { updates, .. } if updates
                    .iter()
                    .any(|update| update.component_id == NOSTR_ROUTING_COMPONENT_ID)
            ),
            Ok(None) => false,
            Err(_) => true,
        }
    }

    /// Whether a relay has acknowledged `group_id`'s pending commit record:
    /// what is left to do for it is the confirm.
    pub(crate) async fn pending_commit_acknowledged(&self, group_id: &GroupId) -> bool {
        self.reading()
            .await
            .outbound_fanouts_for_group(group_id)
            .is_ok_and(|rows| {
                rows.iter().any(|row| {
                    matches!(row.mls_state(), FanoutMlsState::Pending(_))
                        && row.outcome().mls_confirmation_required
                })
            })
    }

    /// The handle of `group_id`'s commit record that is still pending, when
    /// it has one: what holds the circle's sends and its unread traffic.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted.
    pub(crate) async fn pending_commit_fanout(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<FanoutId>> {
        Ok(self
            .reading()
            .await
            .outbound_fanouts_for_group(group_id)
            .map_err(map_mls_err)?
            .iter()
            .find(|row| row.pending_ref().is_some())
            .map(|row| FanoutId::new(group_id.clone(), row.message_id().clone())))
    }

    /// Whether `group_id` holds a staged commit, and whether that commit has
    /// a record. A record that cannot be read is taken to be there.
    pub(crate) async fn staged_commit(&self, group_id: &GroupId) -> Option<bool> {
        let session = self.reading().await;
        let recorded = Self::staged_ref_of(&session, group_id)
            .map(|pending| Self::has_fanout(&session, pending).unwrap_or(true));
        drop(session);
        recorded
    }

    /// Whether `group_id` waits out a refused eviction the engine still
    /// announces: any change or proposal asked of it now would have the
    /// engine stage that eviction ahead of it, only for the hold to undo it
    /// and queue what was asked behind it. Inside the wait it answers "no"
    /// only when the engine says no eviction is scheduled: an engine that
    /// cannot be had, or cannot say, is waited out too.
    pub(crate) async fn refused_eviction_waits(&self, group_id: &GroupId, now_ms: u64) -> bool {
        if !self.restage_wait_runs(group_id, now_ms) {
            return false;
        }
        !self.engine().await.is_ok_and(|mut session| {
            matches!(
                session.scheduled_self_remove_auto_commit_delay_ms(group_id),
                Ok(None)
            )
        })
    }

    /// How long `group_id`'s refusal wait still runs at `now_ms`, when one
    /// does ([`Self::refused_eviction_waits`]).
    pub(crate) fn restage_wait_left_ms(&self, group_id: &GroupId, now_ms: u64) -> Option<u64> {
        self.restage_wait_runs(group_id, now_ms)
            .then(|| self.commit_notes.restage_wait(group_id))
            .flatten()
            .map(|wait| wait.not_before_ms.saturating_sub(now_ms))
    }

    /// Whether deferred-peel rows of `group_id` are untried, so that the
    /// engine's preflight would queue a send behind them.
    pub(crate) async fn deferred_peels_due(&self, group_id: &GroupId) -> bool {
        self.engine()
            .await
            .is_ok_and(|mut session| Self::peel_drain_due(&mut session, group_id))
    }

    /// The members whose queued removal was retired because they were
    /// already gone, and those a removal the driver confirmed took out: the
    /// circle layer deletes their directory rows, as it does for a removal
    /// the engine announces.
    pub(crate) fn take_dropped_removals(&self) -> Vec<String> {
        std::mem::take(
            &mut self
                .dropped_removals
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
        )
    }

    /// Whether `group_id` holds no commit of this device's: stable, no
    /// record of one pending on its relays, and no change of the group in
    /// the engine's queue. A store that cannot say answers that it holds one.
    pub(crate) async fn holds_no_own_commit(&self, group_id: &GroupId) -> bool {
        let session = self.reading().await;
        let none = session
            .outbound_fanouts_for_group(group_id)
            .ok()
            .zip(
                self.message_store
                    .list_queued_outbound_intents(group_id)
                    .ok(),
            )
            .map(|(rows, queue)| {
                !rows.iter().any(|row| row.pending_ref().is_some())
                    && !queue.iter().any(|queued| changes_group(&queued.intent))
            });
        #[cfg(any(test, feature = "test-utils"))]
        let none = self.unless_faulted(StoreFault::OwnCommit, none);
        matches!(
            session.epoch_state(group_id),
            Some(EpochState::Stable { .. })
        ) && none.unwrap_or(false)
    }

    /// Whether `group_id` has a commit record that is still pending.
    fn has_pending_record(session: &AccountDeviceSession, group_id: &GroupId) -> bool {
        session
            .outbound_fanouts_for_group(group_id)
            .is_ok_and(|rows| rows.iter().any(|row| row.pending_ref().is_some()))
    }

    /// [`Self::stage_commits`] over a call's result. `before` is the roster of
    /// the circle the call was made for, read in this hold before the engine
    /// was asked; `released` says the call was not a send.
    async fn staged(
        &self,
        session: &mut AccountDeviceSession,
        result: Result<SessionEffects>,
        now_ms: u64,
        before: Option<&(GroupId, Vec<MemberId>)>,
        released: bool,
        mode: DriveMode,
    ) -> Result<Staged> {
        match result {
            Ok(effects) => Ok(self
                .stage_commits(session, effects, now_ms, before, released, mode)
                .await),
            Err(e) => Err(e),
        }
    }

    /// `group_id`'s roster as the engine reports it now, or `None` when it
    /// cannot be read — which leaves a commit staged next unknown, and so
    /// never undone for want of a relay.
    ///
    /// `None` too while the circle holds a proposal a commit could still
    /// take in: `OpenMLS` commits whatever its proposal store holds, by
    /// reference, and the roster the engine projects is the one the INTENT
    /// asks for. A relay change staged over a leaver's stored proposal would
    /// evict the leaver and still compare as removing nobody.
    fn roster_before(
        &self,
        session: &AccountDeviceSession,
        group_id: &GroupId,
    ) -> Option<(GroupId, Vec<MemberId>)> {
        if pending_proposal_in_window(&self.message_store, group_id).unwrap_or(true) {
            return None;
        }
        let members = session.members(group_id).ok()?;
        Some((
            group_id.clone(),
            members.into_iter().map(|member| member.id).collect(),
        ))
    }

    /// Whether the commit just staged in `group_id` removed nobody: every
    /// member of `before` is still on the roster the engine now projects
    /// (it writes the roster its intent asks for to the group record as it
    /// stages, `cgka-engine/src/message_processor/send.rs` 652-656, and
    /// `members` reads that record, `group_lifecycle.rs` 1711-1719). That
    /// projection is of the intent, not of the commit `OpenMLS` built, so it
    /// is trusted only for a circle that held no proposal the commit could
    /// have taken in ([`Self::roster_before`]).
    fn staged_commit_removes_nobody(
        session: &AccountDeviceSession,
        group_id: &GroupId,
        before: Option<&(GroupId, Vec<MemberId>)>,
    ) -> bool {
        let Some((_, before)) = before.filter(|(of, _)| of == group_id) else {
            return false;
        };
        session.members(group_id).is_ok_and(|after| {
            before
                .iter()
                .all(|member| after.iter().any(|now| &now.id == member))
        })
    }

    /// What one of the fanout driver's own engine calls left, in the hold that
    /// made it. `cgka-session` returns a confirm's or a rollback's error
    /// before it collects effects (v0.10.4 `cgka-session/src/lib.rs`
    /// 1224-1228, 1258-1259), so after a failure what the engine had already
    /// emitted is drained HERE: left in its one-shot buffer, the next engine
    /// call of any plane would collect a commit with a live ref and no row.
    async fn settled(
        &self,
        session: &mut AccountDeviceSession,
        result: Result<SessionEffects>,
        now_ms: u64,
        mode: DriveMode,
    ) -> (Staged, Option<NostrError>) {
        let (effects, error) = match result {
            Ok(effects) => (effects, None),
            Err(e) => {
                let stranded = session.drain();
                self.note_effects(session, &stranded);
                (stranded, Some(e))
            }
        };
        #[cfg(any(test, feature = "test-utils"))]
        let effects = self.beside_stranded_for_test(effects);
        // A resolution stages nothing itself, so there is no roster to compare:
        // whatever it hands back is recorded as a commit that may remove.
        (
            self.stage_commits(session, effects, now_ms, None, true, mode)
                .await,
            error,
        )
    }

    /// What a rollback of `circle`'s commit under `pending` came to, by the
    /// engine's state and never by the call's `result`: an error can follow
    /// a rewind that landed, and its commit is then gone — kept as "still
    /// staged" its dead ref would outlive it. What such a call had emitted
    /// is still in the engine's one-shot buffers, and is taken here.
    fn rolled_back_by_state(
        &self,
        session: &mut AccountDeviceSession,
        circle: Option<&GroupId>,
        pending: PendingStateRef,
        result: Result<SessionEffects>,
    ) -> Result<SessionEffects> {
        match result {
            Err(_)
                if circle.is_some_and(|circle| {
                    Self::staged_ref_of(session, circle) != Some(pending)
                }) =>
            {
                log::warn!(
                    "[Fanout] a rollback that failed after it had rewound its commit is \
                     read as done"
                );
                let stranded = session.drain();
                self.note_effects(session, &stranded);
                Ok(stranded)
            }
            other => other,
        }
    }

    /// Gives every commit in `effects` its durable fanout and takes it out of
    /// the publish work — inside the lock hold that staged it.
    ///
    /// A commit the engine has staged and Haven has not recorded is the one
    /// state a restart cannot recover: MDK's hydrate restores a pending ref
    /// only from a stored fanout (v0.10.4 `cgka-engine/src/engine.rs`
    /// 1894-1946) and leaves a removal-bearing commit staged without one
    /// (1962-1979), after which the group refuses this device's sends or its
    /// every convergence pass (`docs/MDK_UPSTREAM_TRACKER.md` T-KILL-WINDOW).
    /// So the row is written before anything can release the lock, and a
    /// commit whose row cannot be written is rolled back here as MDK's own
    /// host does (`marmot-account/src/runtime.rs` 3801-3815): nothing has left
    /// the device. What that rollback hands back is staged in turn; it can
    /// only be a commit the replay of a finite buffer staged.
    ///
    /// A bare proposal — the user's own leave, minted again for each epoch
    /// the circle reaches — gets a record too, with nothing to confirm: the
    /// same bytes are then sent until enough relays hold them
    /// ([`Self::put_proposal_fanout`]). One whose record cannot be written
    /// stays in the publish work, to be published once as it always was.
    ///
    /// `released` says the batch is not a send's: a group evolution in it is
    /// then a change the user queued earlier and the engine has now released
    /// ([`Self::retire_released_change`]).
    ///
    /// Never fails and never drops what it was handed: a commit that can be
    /// neither recorded nor rolled back stays in the publish work with its
    /// live ref, staged and unsent — nothing without a record is published
    /// from here — its circle is told ([`ChangeNote::ChangeUnrecorded`]),
    /// and its rollback is tried again at the next staging hold
    /// ([`Self::retry_unrecorded`]).
    ///
    /// In [`DriveMode::FinishOnly`] no commit is recorded. Nothing such a
    /// hold asks of the engine stages one — an ingest, the inputs-only
    /// advance and the finish of a stored confirm do not, and a send's
    /// preflight is not reached while an eviction is due
    /// ([`Self::departure_holds_a_send`]) — so one
    /// found here was left in the engine's one-shot buffers by a call that
    /// failed, or staged by a preflight that raced the check. It was handed
    /// to nobody, and it is undone in the hold exactly as inside a wait: the
    /// engine arms an eviction again, and keeps a released change queued. A
    /// proposal is recorded in either mode.
    async fn stage_commits(
        &self,
        session: &mut AccountDeviceSession,
        effects: SessionEffects,
        now_ms: u64,
        before: Option<&(GroupId, Vec<MemberId>)>,
        released: bool,
        mode: DriveMode,
    ) -> Staged {
        // A commit the engine released from its queue is never marked as
        // removing nobody: what it took in by reference on the way out of
        // the queue is not what the roster read before the call can show.
        let before = if released { None } else { before };
        // What an earlier hold could neither record nor undo is undone
        // now, and what that hands back is staged with this batch.
        let undone = self.retry_unrecorded(session).await;
        let effects = undone.into_iter().fold(effects, chain_effects);
        let SessionEffects {
            mut events,
            publish,
            mut queued,
            mut pending_convergence,
        } = effects;
        let mut work = VecDeque::from(publish);
        let (mut kept, mut fanouts, mut proposals) = (Vec::new(), Vec::new(), Vec::new());
        let (mut unrecorded, mut waiting, mut carried) = (Vec::new(), Vec::new(), Vec::new());
        while let Some(item) = work.pop_front() {
            let pending = match &item {
                PublishWork::GroupEvolution { pending, .. }
                | PublishWork::AutoPublish { pending, .. } => *pending,
                PublishWork::Proposal { msg, queued_intent } => {
                    match self.record_proposal(session, msg, queued_intent.as_ref(), now_ms) {
                        Ok(id) => proposals.push(id),
                        Err(_) => kept.push(item),
                    }
                    continue;
                }
                // An application message carries no pending ref; a founding
                // create is canonical already; `GroupCreated` is the legacy
                // profile's, which no Haven session opens.
                PublishWork::ApplicationMessage { .. }
                | PublishWork::FoundingGroupCreated { .. }
                | PublishWork::GroupCreated { .. } => {
                    kept.push(item);
                    continue;
                }
            };
            let recorded = match &item {
                PublishWork::GroupEvolution { .. } | PublishWork::AutoPublish { .. }
                    if mode == DriveMode::FinishOnly =>
                {
                    None
                }
                PublishWork::GroupEvolution { msg, welcomes, .. } => Some(
                    self.put_commit_fanout_marked(session, msg, welcomes, pending, now_ms, before)
                        .inspect(|id| {
                            if released {
                                let _ = self.retire_released_change(session, id);
                            }
                            carried.push((
                                id.clone(),
                                welcomes.iter().map(|welcome| welcome.id.clone()).collect(),
                            ));
                        }),
                ),
                PublishWork::AutoPublish { .. }
                    if self.restaging_held(session, pending, now_ms) =>
                {
                    None
                }
                // The engine's own commit is an eviction: it removes a member
                // whatever the rosters say.
                PublishWork::AutoPublish { msg, .. } => {
                    Some(self.put_commit_fanout_marked(session, msg, &[], pending, now_ms, None))
                }
                _ => continue,
            };
            let held_back = recorded.is_none() && matches!(item, PublishWork::AutoPublish { .. });
            let failed = match recorded {
                Some(Ok(id)) => {
                    fanouts.push(id);
                    continue;
                }
                Some(Err(e)) => Some(e),
                None => None,
            };
            say_undone_in_its_hold(failed.as_ref(), mode);
            let circle = session.pending_group_id(pending).ok();
            let rolled_back = self.publish_failed_in(session, pending, true).await;
            match self.rolled_back_by_state(session, circle.as_ref(), pending, rolled_back) {
                Ok(undone) => {
                    waiting.extend(circle.filter(|_| held_back));
                    events.extend(undone.events);
                    work.extend(undone.publish);
                    queued.extend(undone.queued);
                    pending_convergence.extend(undone.pending_convergence);
                }
                Err(e) => {
                    unrecorded.extend(self.keep_unrecorded(session, pending, &e));
                    kept.push(item);
                }
            }
        }
        self.silence_staged(fanouts.iter().chain(&proposals), &unrecorded);
        Staged {
            effects: SessionEffects {
                events,
                publish: kept,
                queued,
                pending_convergence,
            },
            fanouts,
            welcomes: carried,
            proposals,
            unrecorded,
            waiting,
        }
    }

    /// No location is sent for a circle with a commit or a proposal of this
    /// device's on its way, and none sealed before it goes out by mesh.
    fn silence_staged<'a>(
        &self,
        recorded: impl Iterator<Item = &'a FanoutId>,
        unrecorded: &'a [GroupId],
    ) {
        for group_id in recorded.map(FanoutId::group).chain(unrecorded) {
            self.mesh_keys.silence(group_id);
        }
    }

    /// Keeps the ref of a commit that could be neither recorded nor rolled
    /// back, and tells its circle. Nothing was sent, so undoing it later is
    /// as safe as undoing it now.
    fn keep_unrecorded(
        &self,
        session: &AccountDeviceSession,
        pending: PendingStateRef,
        failure: &NostrError,
    ) -> Option<GroupId> {
        log::warn!(
            "[Fanout] a staged commit could be neither recorded nor rolled back; it stays \
             staged, unsent, and its rollback is tried again: {}",
            failure.code()
        );
        self.unrecorded
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(pending);
        let group_id = session.pending_group_id(pending).ok()?;
        let _ = self
            .commit_notes
            .note(&group_id, ChangeNote::ChangeUnrecorded);
        Some(group_id)
    }

    /// Tries again the rollback of every commit an earlier hold could
    /// neither record nor roll back ([`Self::stage_commits`]), and returns
    /// what each rollback handed back.
    ///
    /// Such a commit was never sent — it had no record, and nothing without
    /// one is published from a staging-mode hold — so the rollback is as
    /// safe now as it was then. A commit that has been given a record since
    /// (the next open's repair) or is no longer staged is the driver's or
    /// nobody's, and is let go.
    async fn retry_unrecorded(&self, session: &mut AccountDeviceSession) -> Vec<SessionEffects> {
        let owed = std::mem::take(
            &mut *self
                .unrecorded
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
        );
        let mut undone = Vec::new();
        for pending in owed {
            let still_staged = session
                .pending_group_id(pending)
                .is_ok_and(|group_id| Self::staged_ref_of(session, &group_id) == Some(pending));
            if !still_staged || Self::has_fanout(session, pending).unwrap_or(true) {
                continue;
            }
            match self.publish_failed_in(session, pending, true).await {
                Ok(effects) => {
                    log::info!(
                        "[Fanout] a commit left staged with no record was rolled back unsent"
                    );
                    undone.push(effects);
                }
                Err(_) => self
                    .unrecorded
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .push(pending),
            }
        }
        undone
    }

    /// Retires the queued change a just-recorded commit was released from.
    ///
    /// The engine deletes a queued change only in the confirm of the commit
    /// it became, and only through a link it keeps in memory
    /// (`cgka-engine/src/engine.rs` 229; `publish.rs` 93, 250-252). A commit
    /// restored after a restart is confirmed without that link, its change
    /// stays queued, and every later full advance of the circle then tries to
    /// make it a second time — which for a removal or an invite fails the
    /// whole advance, for good (`docs/MDK_UPSTREAM_TRACKER.md`
    /// T-QUEUED-INTENT-RESTORE). The commit's record is durable from this
    /// hold on and is sent until it is resolved, so the queue's copy is
    /// retired here, where the two are still known to be one: the engine
    /// released the first queued change it could prepare, and recorded the
    /// change it prepared as the commit's own intent
    /// (`message_processor/send.rs` 136-148) — so every queued change equal
    /// to that intent is retired: the one that was released, and any twin of
    /// it. A commit of a kind the engine keeps no intent for is left to the
    /// engine.
    ///
    /// With it goes the engine's retry: a commit every relay refuses is
    /// undone and its author told, as a change asked for directly is.
    fn retire_released_change(
        &self,
        session: &mut AccountDeviceSession,
        id: &FanoutId,
    ) -> Option<SendIntent> {
        let own = self
            .message_store
            .own_commit_intent(id.message())
            .ok()
            .flatten()?;
        let Ok(queue) = self.message_store.list_queued_outbound_intents(id.group()) else {
            return Some(own.intent);
        };
        // Every one of them: a change asked twice is queued twice, and the
        // twin of a change that is made is one that cannot be.
        for released in queue
            .into_iter()
            .filter(|queued| queued.intent == own.intent)
        {
            let retired = session.confirm_regenerated_queued_intent(&QueuedIntentRef {
                group_id: released.group_id,
                intent_id: released.id,
            });
            if let Err(e) = retired {
                // Tried again when the commit is confirmed; failing there
                // too, the change stays queued and is checked against the
                // roster before every later advance.
                log::warn!(
                    "[Fanout] the queued copy of a recorded change was not retired: {}",
                    e.kind()
                );
            }
        }
        Some(own.intent)
    }

    /// Records the bare proposal `msg` ([`Self::put_proposal_fanout`]) and
    /// confirms the queued copy of one the queue regenerated: the record is
    /// the proposal's durable form now.
    fn record_proposal(
        &self,
        session: &mut AccountDeviceSession,
        msg: &cgka_traits::transport::TransportMessage,
        queued_intent: Option<&QueuedIntentRef>,
        now_ms: u64,
    ) -> Result<FanoutId> {
        let id = self.put_proposal_fanout(session, msg, now_ms)?;
        if let Some(intent) = queued_intent {
            let _ = session.confirm_regenerated_queued_intent(intent);
        }
        Ok(id)
    }

    /// Whether a record of this device's proposal for `group_id` minted at
    /// `epoch` stands and is not spent ([`Self::proposal_is_spent`]): an
    /// earlier epoch's record says nothing of this one's. What cannot be read
    /// counts as no record.
    pub(crate) async fn proposal_recorded_at(&self, group_id: &GroupId, epoch: u64) -> bool {
        let session = self.reading().await;
        let recorded = session
            .outbound_fanouts_for_group(group_id)
            .is_ok_and(|rows| {
                rows.iter().any(|row| {
                    is_proposal_record(row)
                        && !self.proposal_is_spent(&session, group_id, row)
                        && self
                            .message_store
                            .get_message(row.message_id())
                            .is_ok_and(|stored| stored.epoch.0 == epoch)
                })
            });
        drop(session);
        recorded
    }

    /// The circle a bare proposal of this device's is for: the one MDK's own
    /// record of it names (`MessageRecord.group_id`, written in the hold that
    /// minted it), while this device is still in it. Never a guess: `None`
    /// with no record, one that cannot be read, or a circle this device's
    /// copy of is marked removed. The engine hands a proposal back with no
    /// circle on it, and drains its one-shot buffer into whichever call comes
    /// next — another circle's leave included — while the address it is sent
    /// to can name two circles (a routing collision).
    fn proposal_circle(
        &self,
        session: &AccountDeviceSession,
        msg: &cgka_traits::transport::TransportMessage,
    ) -> Option<GroupId> {
        let group_id = self.message_store.get_message(&msg.id).ok()?.group_id;
        session
            .group_record(&group_id)
            .is_ok_and(|group| !group.removed)
            .then_some(group_id)
    }

    /// Stores the durable fanout of one bare proposal: its exact signed
    /// event, frozen for the relays of the circle it is for
    /// ([`Self::proposal_circle`]), with nothing to confirm (MDK's own shape
    /// for a standalone proposal, `traits/src/transport_adapter.rs` 206-211).
    /// With no such circle it is not recorded: frozen for the wrong circle's
    /// relays, a leave would tell those relays of a circle they do not carry.
    fn put_proposal_fanout(
        &self,
        session: &AccountDeviceSession,
        msg: &cgka_traits::transport::TransportMessage,
        now_ms: u64,
    ) -> Result<FanoutId> {
        let TransportEnvelope::GroupMessage { transport_group_id } = &msg.envelope else {
            return Err(NostrError::MdkError("a proposal is not a group message"));
        };
        let group_id = self
            .proposal_circle(session, msg)
            .ok_or(NostrError::MdkError(
                "the proposal names no circle of its own",
            ))?;
        let endpoints = fanout_targets(session, &group_id)?;
        let fanout = OutboundFanout::stage(
            TransportPublishRequest {
                account_id: session.self_id(),
                target: TransportPublishTarget::Group {
                    group_id: group_id.clone(),
                    transport_group_id: transport_group_id.clone(),
                    endpoints: endpoints.clone(),
                },
                required_acks: required_acks(&endpoints),
                message: msg.clone(),
            },
            None,
            None,
            now_ms,
        )
        .map_err(|_| NostrError::MdkError("the fanout record was refused"))?;
        session.put_outbound_fanout(&fanout).map_err(map_mls_err)?;
        crate::relay::fanout::own(fanout.message_id());
        Ok(FanoutId::new(group_id, fanout.message_id().clone()))
    }

    /// Whether the circle `pending` belongs to is still inside the wait its
    /// last rolled-back commit earned, so the engine's own commit for it — an
    /// eviction the engine stages again after every rollback — is undone in
    /// the hold instead of being sent.
    ///
    /// Every relay proved it would not take the last one, and what made them
    /// refuse — a device clock that is wrong is the usual cause, answered
    /// `invalid:` — is still true a moment later. Without the wait each pass
    /// would stage the eviction, send it to every relay and roll it back. The
    /// waits double from [`RESTAGE_BASE_MS`](crate::relay::fanout::RESTAGE_BASE_MS)
    /// to the pacing maximum, counted per circle and forgotten when its epoch
    /// moves. A change the user asks for directly is never held: they are
    /// told it was refused. One already queued behind the eviction gets no
    /// turn while the wait runs: the engine's drain serves the eviction
    /// first, and each such staging is undone here.
    ///
    /// Kept with the circle's commit notes ([`RestageWait`]), so it outlives
    /// the session: a run of short sessions would otherwise each stage and
    /// send one. What the wait costs is said where it is paid: while it runs
    /// this device shares nothing to the circle — a location send inside it
    /// is answered deferred and never made
    /// ([`Self::departure_holds_a_send`]) — so nothing is sealed at the
    /// epoch the member who left can read.
    ///
    /// A wait longer than the schedule's own maximum means the clock was
    /// stepped back since it was written; it is over, as a relay's is
    /// (`due_attempts`): a stepped clock must not hold an eviction for days.
    fn restaging_held(
        &self,
        session: &AccountDeviceSession,
        pending: PendingStateRef,
        now_ms: u64,
    ) -> bool {
        session
            .pending_group_id(pending)
            .is_ok_and(|group_id| self.restage_wait_runs(&group_id, now_ms))
    }

    /// [`Self::restaging_held`] for a circle named outright.
    fn restage_wait_runs(&self, group_id: &GroupId, now_ms: u64) -> bool {
        self.commit_notes
            .restage_wait(group_id)
            .is_some_and(|wait| {
                now_ms < wait.not_before_ms
                    && wait.not_before_ms - now_ms <= crate::relay::fanout::RETRY_MAX_MS
            })
    }

    /// Whether a commit of `group_id` was rolled back at its current epoch:
    /// the record a refusal leaves, kept until the epoch moves, whether or not
    /// its wait still runs.
    fn refusal_stands(&self, group_id: &GroupId) -> bool {
        self.commit_notes.restage_wait(group_id).is_some()
    }

    /// Records that the fanout driver rolled back a commit of `group_id` at
    /// `now_ms`: see [`Self::restaging_held`].
    fn hold_restaging(&self, group_id: &GroupId, now_ms: u64) {
        let rollbacks = self
            .commit_notes
            .restage_wait(group_id)
            .map_or(1, |wait| wait.rollbacks.saturating_add(1));
        let wait = crate::relay::fanout::RESTAGE_BASE_MS
            .saturating_mul(1_u64 << (rollbacks - 1).min(7))
            .min(crate::relay::fanout::RETRY_MAX_MS);
        self.commit_notes.set_restage_wait(
            group_id,
            Some(RestageWait {
                rollbacks,
                not_before_ms: now_ms.saturating_add(wait),
            }),
        );
    }

    /// [`Self::put_commit_fanout`], with the circle's removal mark kept true
    /// around it ([`CommitNotes`]): cleared BEFORE the record is written and
    /// set after it, and only for a commit shown to remove nobody. A kill in
    /// between, or a mark that cannot be cleared, never leaves a removal
    /// reading as something a day without relays may undo — a commit whose
    /// mark cannot be cleared is not recorded, and so is rolled back in this
    /// hold like any other that cannot be.
    fn put_commit_fanout_marked(
        &self,
        session: &AccountDeviceSession,
        msg: &cgka_traits::transport::TransportMessage,
        welcomes: &[cgka_traits::transport::TransportMessage],
        pending: PendingStateRef,
        now_ms: u64,
        before: Option<&(GroupId, Vec<MemberId>)>,
    ) -> Result<FanoutId> {
        let group_id = session.pending_group_id(pending).map_err(map_mls_err)?;
        if !self.commit_notes.set_removes_nobody(&group_id, false) {
            return Err(NostrError::MdkError(
                "the circle's removal mark could not be cleared",
            ));
        }
        let id = self.put_commit_fanout(session, msg, welcomes, pending, now_ms)?;
        if Self::staged_commit_removes_nobody(session, &group_id, before) {
            self.commit_notes.set_removes_nobody(&group_id, true);
        }
        Ok(id)
    }

    /// Stages and stores the durable fanout of one commit the engine holds
    /// under `pending`.
    ///
    /// The targets are the group's routing component as the engine reads it
    /// NOW, after it returned the work: the live, unmerged group (`engine.rs`
    /// 3529-3540), so a commit that changes the relays is frozen for the ones
    /// its source epoch names (`transports/nostr.md` 343-347), and a peer's
    /// routing change the same call folded first is already in it.
    ///
    /// One pending commit row per group. A row found whose own commit is no
    /// longer stored as sent is stale and is deleted here. Refused — and so
    /// rolled back by the caller, in the hold — when the group has a pending
    /// row whose commit IS still stored as sent, which can only be one the
    /// engine no longer holds: MDK's hydrate would bind that older row's ref
    /// to this commit; and when no relay can be frozen for it, as MDK's host
    /// resolves a fanout with no target inside the call that staged it
    /// (`marmot-account/src/runtime.rs` 3795, 4041-4050): a commit must not
    /// hold the circle's sends and its unread traffic for a drive that could
    /// only roll it back.
    fn put_commit_fanout(
        &self,
        session: &AccountDeviceSession,
        msg: &cgka_traits::transport::TransportMessage,
        welcomes: &[cgka_traits::transport::TransportMessage],
        pending: PendingStateRef,
        now_ms: u64,
    ) -> Result<FanoutId> {
        let group_id = session.pending_group_id(pending).map_err(map_mls_err)?;
        let origin = session
            .pending_origin_message_id(pending)
            .map_err(map_mls_err)?;
        let kind = session.pending_fanout_kind(pending).map_err(map_mls_err)?;
        for row in session
            .outbound_fanouts_for_group(&group_id)
            .map_err(map_mls_err)?
        {
            if row.pending_ref().is_none() {
                continue;
            }
            if Self::origin_is_sent(session, &row)? {
                return Err(NostrError::MdkError(
                    "the circle already has a pending commit record",
                ));
            }
            // Its commit was resolved by some other path: it describes
            // nothing that is staged, and left pending it is what hydrate
            // would bind.
            self.settle_stale_row(session, &row)?;
        }
        let fanout = commit_fanout(
            session.self_id(),
            &group_id,
            msg.clone(),
            &fanout_targets(session, &group_id)?,
            (pending, origin, kind),
            welcomes.to_vec(),
            now_ms,
        )?;
        session.put_outbound_fanout(&fanout).map_err(map_mls_err)?;
        crate::relay::fanout::own(fanout.message_id());
        Ok(FanoutId::new(group_id, fanout.message_id().clone()))
    }

    /// Whether the engine holds `fanout`'s OWN commit staged: under the row's
    /// pending ref, and tracked as the row's origin message. The ref alone is a
    /// process-local counter that starts over with every session
    /// (`cgka-engine/src/epoch_manager.rs` 51, 109-111), so a row an earlier
    /// process left can carry the number a later commit was given.
    fn holds(session: &AccountDeviceSession, fanout: &OutboundFanout) -> bool {
        let (Some(pending), Some(group_id)) = (fanout.pending_ref(), fanout.group_id()) else {
            return false;
        };
        matches!(
            session.epoch_state(group_id),
            Some(EpochState::PendingPublish(staged)) if staged.pending_ref() == pending
        ) && session.pending_origin_message_id(pending).ok().as_ref()
            == fanout.pending_origin_message_id()
    }

    /// Whether `fanout`'s commit is still stored as sent and unresolved.
    fn origin_is_sent(session: &AccountDeviceSession, fanout: &OutboundFanout) -> Result<bool> {
        Ok(match fanout.pending_origin_message_id() {
            Some(origin) => {
                session.stored_message_state(origin).map_err(map_mls_err)?
                    == Some(MessageState::Sent)
            }
            None => false,
        })
    }

    /// The engine's pending ref for the commit a `Confirmed` row names, when
    /// the engine still holds that commit staged. The engine merges a commit
    /// and stores its row `Confirmed` in one transaction and leaves
    /// `PendingPublish` afterwards (v0.10.4 `cgka-engine/src/publish.rs`
    /// 120-272); an error between the two leaves exactly this.
    fn unfinished_confirm(
        session: &AccountDeviceSession,
        fanout: &OutboundFanout,
    ) -> Option<PendingStateRef> {
        let Some(EpochState::PendingPublish(staged)) = session.epoch_state(fanout.group_id()?)
        else {
            return None;
        };
        let pending = staged.pending_ref();
        (fanout.mls_state() == FanoutMlsState::Confirmed
            && session.pending_origin_message_id(pending).ok().as_ref()
                == fanout.pending_origin_message_id())
        .then_some(pending)
    }

    /// Ends a pending record whose commit some other path resolved.
    ///
    /// A commit that ended APPLIED on this device keeps its record, marked
    /// confirmed: each relay it was frozen for is still owed the commit
    /// (`transports/nostr.md`, "Publish targets and acknowledgements"), and
    /// when no relay took it this device is alone at the new epoch until one
    /// does. A confirmed record is never one hydrate binds. Any other end —
    /// discarded, or lost to a rival branch — leaves nothing to send.
    ///
    /// One end is said, never silent: a commit a relay may hold — an attempt
    /// at it was begun, or one was acknowledged — that the engine has given a
    /// final state without ever applying it here. The circle's other members
    /// may have applied it; this device then stays at the epoch they left,
    /// and what it seals there the member that commit removed can still
    /// read. Nothing on this device can tell which; the circle is told it
    /// may be out of step ([`ChangeNote::MayBeOutOfStep`]).
    fn settle_stale_row(&self, session: &AccountDeviceSession, row: &OutboundFanout) -> Result<()> {
        let state = match row.pending_origin_message_id() {
            Some(origin) => session.stored_message_state(origin).map_err(map_mls_err)?,
            None => None,
        };
        let applied = state == Some(MessageState::Processed);
        if let Some(confirmed) = confirmed_copy(row).filter(|_| applied) {
            return session.put_outbound_fanout(&confirmed).map_err(map_mls_err);
        }
        let ended_for_good = matches!(
            state,
            Some(MessageState::EpochInvalidated | MessageState::Failed)
        );
        if ended_for_good && !never_attempted(row) {
            // Said before the row goes: the row is the only other trace.
            if let Some(group_id) = row.group_id() {
                if !self.commit_notes.note(group_id, ChangeNote::MayBeOutOfStep) {
                    return Err(NostrError::MdkError(UNNOTED));
                }
            }
            log::warn!(
                "[Fanout] a commit a relay may hold was set aside for good; its circle may be \
                 out of step"
            );
        }
        session
            .delete_outbound_fanout(row.message_id())
            .map_err(map_mls_err)?;
        crate::relay::fanout::release(row.message_id());
        Ok(())
    }

    /// Stores an update of a row that is still stored, and refuses one of a
    /// row that is not: MDK's `put_outbound_fanout` is an upsert
    /// (`storage-sqlite/src/storage/outbound.rs` 207-266), and an answer that
    /// outlived its row must not write the row back.
    fn update_fanout(session: &AccountDeviceSession, fanout: &OutboundFanout) -> Result<()> {
        let stored = fanout
            .group_id()
            .map_or_else(
                || session.outbound_fanouts(),
                |group_id| session.outbound_fanouts_for_group(group_id),
            )
            .map_err(map_mls_err)?;
        if !stored
            .iter()
            .any(|row| row.message_id() == fanout.message_id())
        {
            return Err(NostrError::MdkError("the fanout record has ended"));
        }
        session.put_outbound_fanout(fanout).map_err(map_mls_err)
    }

    /// The stored fanout `id` names, and what its driver may do with it.
    ///
    /// One hold, so the row, its commit's stored state and the engine's
    /// pending state are read together. A row whose commit is no longer
    /// `Sent` was resolved by some other path, and confirming through it
    /// would apply whatever commit the engine holds under its ref
    /// (T-STALE-FANOUT).
    pub(crate) async fn fanout_standing(&self, id: &FanoutId) -> Result<FanoutStanding> {
        let session = self.reading().await;
        let rows = session
            .outbound_fanouts_for_group(id.group())
            .map_err(map_mls_err)?;
        let Some(fanout) = rows.iter().find(|row| row.message_id() == id.message()) else {
            return Ok(FanoutStanding::Absent);
        };
        if Self::group_gone(&session, id.group()) {
            return Ok(FanoutStanding::GroupGone(StoredFanout::new(fanout.clone())));
        }
        let pending = match fanout.mls_state() {
            FanoutMlsState::Pending(pending) => pending,
            FanoutMlsState::Confirmed => {
                return Ok(FanoutStanding::Confirmed {
                    fanout: StoredFanout::new(fanout.clone()),
                    unfinished: Self::unfinished_confirm(&session, fanout),
                    commit: Self::applied_commit(&session, fanout)?,
                })
            }
            FanoutMlsState::NotApplicable => {
                return Ok(if fanout.application_message().is_some() {
                    FanoutStanding::NoCommit
                } else if self.commit_notes.circle_stands(id.group()).is_none() {
                    FanoutStanding::Unread
                } else {
                    FanoutStanding::Proposal {
                        spent: self.proposal_is_spent(&session, id.group(), fanout),
                        fanout: StoredFanout::new(fanout.clone()),
                    }
                })
            }
            FanoutMlsState::RolledBack => {
                return Ok(FanoutStanding::RolledBack(StoredFanout::new(
                    fanout.clone(),
                )))
            }
        };
        if Self::origin_is_sent(&session, fanout)? {
            return Ok(if Self::holds(&session, fanout) {
                FanoutStanding::Staged(StoredFanout::new(fanout.clone()))
            } else {
                FanoutStanding::Unheld {
                    unsent: never_attempted(fanout),
                }
            });
        }
        // The engine holding this row's ref then holds some OTHER commit
        // under it. It can have no row of its own: every writer keeps a
        // circle to one pending record (`put_commit_fanout`,
        // `settle_fanouts_before_open`).
        let _ = pending;
        let bound = Self::holds(&session, fanout);
        drop(session);
        Ok(FanoutStanding::Stale { bound })
    }

    /// The commit the stored record `id` names: what [`Self::commit_state`]
    /// reads once another drive has ended the record. `None` when the record
    /// is not stored or names none.
    pub(crate) async fn fanout_origin(&self, id: &FanoutId) -> Option<MessageId> {
        let rows = self
            .reading()
            .await
            .outbound_fanouts_for_group(id.group())
            .ok()?;
        rows.iter()
            .find(|row| row.message_id() == id.message())?
            .pending_origin_message_id()
            .cloned()
    }

    /// How this device's commit `origin` is stored; `None` when it cannot be
    /// read.
    pub(crate) async fn commit_state(&self, origin: &MessageId) -> Option<MessageState> {
        self.reading()
            .await
            .stored_message_state(origin)
            .ok()
            .flatten()
    }

    /// Whether `group_id` is finished on this device: its copy is removed or
    /// disbanded, or the engine holds no record of it. A quarantined group
    /// and one not yet hydrated are not: they are halted, and a retry brings
    /// them back with whatever their records still have to drive.
    fn group_gone(session: &AccountDeviceSession, group_id: &GroupId) -> bool {
        match session.group_record(group_id) {
            Ok(group) => group.is_terminal(),
            Err(SessionError::Engine(EngineError::Storage(
                cgka_traits::storage::StorageError::NotFound,
            ))) => true,
            Err(_) => false,
        }
    }

    /// Whether the record `id` names went with its group: the group is
    /// finished on this device (a disband's settle deleted its records) and
    /// the record is no longer stored. The relay layer lets go of it too, and
    /// nothing of it is sent.
    pub(crate) async fn fanout_ended(&self, id: &FanoutId) -> bool {
        let session = self.reading().await;
        let Ok(rows) = session.outbound_fanouts_for_group(id.group()) else {
            return false;
        };
        let gone = Self::group_gone(&session, id.group());
        drop(session);
        let ended = gone && !rows.iter().any(|row| row.message_id() == id.message());
        if ended {
            crate::relay::fanout::release(id.message());
        }
        ended
    }

    /// Whether nothing can act on a bare proposal's event any more.
    ///
    /// A proposal is an offer made for one epoch of one circle by a member
    /// of it. Sending it again once that is no longer so tells a relay who
    /// was leaving which circle, and tells no member anything:
    ///
    /// * this device's copy of the circle is marked removed — it was
    ///   evicted, or its leave completed. MDK still lists the records of
    ///   such a copy (`cgka-engine/src/engine.rs` 2605-2618 gates only a
    ///   quarantined or unhydrated group);
    /// * the circle has left the epoch the proposal was stored under. The
    ///   engine proposes a leave again for each epoch the circle reaches,
    ///   so this is also what ends a leave a later one has replaced.
    ///
    /// What cannot be read ends nothing: a store that is busy must not end
    /// a leave that is still wanted.
    fn proposal_is_spent(
        &self,
        session: &AccountDeviceSession,
        group_id: &GroupId,
        proposal: &OutboundFanout,
    ) -> bool {
        // A left circle's row is gone: nothing of it is sent again.
        let removed = session
            .group_record(group_id)
            .is_ok_and(|group| group.removed)
            || matches!(self.commit_notes.circle_stands(group_id), Some(false));
        let stored = self.message_store.get_message(proposal.message_id());
        let epoch_left = matches!(
            (&stored, session.epoch(group_id)),
            (Ok(stored), Ok(now)) if now > stored.epoch
        );
        removed || epoch_left
    }

    /// Where the commit an applied record names stands now. Applying is not
    /// final: branch selection can set an applied commit aside, provisionally
    /// (`ConvergenceDeferred`) or for good (`EpochInvalidated`; `Failed` is
    /// Haven's own retirement).
    fn applied_commit(
        session: &AccountDeviceSession,
        fanout: &OutboundFanout,
    ) -> Result<AppliedCommit> {
        let Some(origin) = fanout.pending_origin_message_id() else {
            return Ok(AppliedCommit::Provisional);
        };
        Ok(
            match session.stored_message_state(origin).map_err(map_mls_err)? {
                Some(MessageState::Processed) => AppliedCommit::Canonical,
                Some(MessageState::EpochInvalidated | MessageState::Failed) => AppliedCommit::Lost,
                _ => AppliedCommit::Provisional,
            },
        )
    }

    /// Stores `fanout`'s target states. MDK's storage refuses an update that
    /// is not a monotonic successor of the stored row.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted.
    pub(crate) async fn put_fanout(&self, fanout: &StoredFanout) -> Result<()> {
        Self::update_fanout(&*self.reading().await, fanout.as_mdk_fanout())
    }

    /// [`Self::put_fanout`] if what its caller decided `still` holds, read
    /// with the engine held; whether the row was written.
    pub(crate) async fn put_fanout_while(
        &self,
        fanout: &StoredFanout,
        still: Still<'_>,
    ) -> Result<bool> {
        let session = self.reading().await;
        if !still.holds() {
            return Ok(false);
        }
        Self::update_fanout(&session, fanout.as_mdk_fanout())?;
        drop(session);
        Ok(true)
    }

    /// Lets `mark` choose which of `fanout`'s targets an attempt begins for,
    /// with every stored fanout of the session before it, and stores the row
    /// if it marked any — one hold, so two drives of different rows can never
    /// both find one relay free.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted; nothing was marked in
    /// the store, and nothing may be sent.
    pub(crate) async fn begin_fanout_attempts(
        &self,
        fanout: &mut StoredFanout,
        mark: impl FnOnce(&[OutboundFanout], &mut OutboundFanout) -> bool + Send,
    ) -> Result<()> {
        let session = self.reading().await;
        let all = commit_side(session.outbound_fanouts().map_err(map_mls_err)?);
        if mark(&all, fanout.as_mdk_fanout_mut()) {
            Self::update_fanout(&session, fanout.as_mdk_fanout())?;
        }
        drop(session);
        Ok(())
    }

    /// The handles of the stored fanouts a drive takes up — `group_id`'s, or
    /// every live group's: commits and bare proposals, those that still owe a
    /// relay its first attempt first, in staging order, then the rest, least
    /// recently called first; and within one circle, its commits ahead of its
    /// proposals.
    ///
    /// Within a circle a commit still pending holds back everything staged
    /// after it, as MDK's host holds a group's later fanouts behind its first
    /// incomplete one (`marmot-account/src/runtime.rs` 2757-2765): only a
    /// PENDING one here, never an applied commit or a proposal that merely
    /// owes a relay.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted.
    pub(crate) async fn stored_fanouts(&self, group_id: Option<&GroupId>) -> Result<Vec<FanoutId>> {
        let session = self.reading().await;
        let rows = group_id
            .map_or_else(
                || session.outbound_fanouts(),
                |group_id| session.outbound_fanouts_for_group(group_id),
            )
            .map_err(map_mls_err)?;
        drop(session);
        let mut held_back: Vec<&GroupId> = Vec::new();
        let rows: Vec<&OutboundFanout> = rows
            .iter()
            .filter(|row| row.application_message().is_none())
            .filter(|row| {
                let Some(group_id) = row.group_id() else {
                    return false;
                };
                if held_back.contains(&group_id) {
                    return false;
                }
                if row.pending_ref().is_some() {
                    held_back.push(group_id);
                }
                true
            })
            .collect();
        // A relay's next call goes to an event it has not been sent yet
        // before one it is being asked again for; and among those, to the
        // one that has waited longest since its last call — a relay that is
        // called once per wait would otherwise always be called for the
        // same event, and the others waiting on it never. Stable, so
        // staging order holds wherever that does not decide.
        let (first, mut again): (Vec<_>, Vec<_>) = rows.into_iter().partition(|row| {
            row.target_statuses()
                .contains(&FanoutTargetStatus::NotAttempted)
        });
        again.sort_by_key(|row| {
            (0..row.target_statuses().len())
                .filter_map(|index| row.target_last_attempt_at_ms(index))
                .max()
        });
        // And, within ONE circle, a commit before a proposal: a relay allows
        // one call per wait, and a leave — proposed again at every epoch,
        // which any member can move — must not take that call from a removal
        // of its own circle waiting on the same relay. Never across circles:
        // a commit one circle cannot get a relay to take would otherwise keep
        // every other circle's leave from a relay that would take it, for as
        // long as that commit stays pending. Each circle's rows keep the
        // places the order above gave that circle.
        let mut ordered: Vec<&OutboundFanout> = first.into_iter().chain(again).collect();
        let mut circles: Vec<&GroupId> = Vec::new();
        for row in &ordered {
            if let Some(circle) = row.group_id().filter(|circle| !circles.contains(circle)) {
                circles.push(circle);
            }
        }
        for circle in circles {
            let places: Vec<usize> = (0..ordered.len())
                .filter(|place| ordered[*place].group_id() == Some(circle))
                .collect();
            let (commits, proposals): (Vec<_>, Vec<_>) = places
                .iter()
                .map(|place| ordered[*place])
                .partition(|row| !is_proposal_record(row));
            for (place, row) in places.into_iter().zip(commits.into_iter().chain(proposals)) {
                ordered[place] = row;
            }
        }
        Ok(ordered
            .into_iter()
            .filter_map(|row| {
                Some(FanoutId::new(
                    row.group_id()?.clone(),
                    row.message_id().clone(),
                ))
            })
            .collect())
    }

    /// Confirms the commit `fanout` holds, which at least one relay has
    /// acknowledged: the engine merges it and stores the row `Confirmed` in
    /// one transaction (`cgka-engine/src/publish.rs` 120-257). Staging mode:
    /// what the call emitted gets its own row in this hold, whether or not it
    /// succeeded. An error does not say whether the merge happened: the
    /// stored row does.
    pub(crate) async fn confirm_fanout(
        &self,
        fanout: &mut StoredFanout,
        now_ms: u64,
        mode: DriveMode,
        still: Still<'_>,
    ) -> Option<FanoutSettlement> {
        let Some(pending) = fanout.as_mdk_fanout().pending_ref() else {
            return Some(FanoutSettlement::refused(NostrError::MdkError(
                "the fanout holds no pending commit",
            )));
        };
        let mut session = match self.engine().await {
            Ok(session) => session,
            Err(held) => return Some(FanoutSettlement::refused(held)),
        };
        // Read again with the engine held: the wait for it is where the
        // lifecycle a pass decided under ends.
        if !still.holds() {
            return None;
        }
        // MDK's host's rule, by value (`marmot-account/src/runtime.rs`
        // 3113-3135): only an error the store calls transient is asked
        // again. That does not say the commit was not applied — a store that
        // is busy inside the replay, after the merge, is transient too; the
        // next ask is then refused by the engine's own check and THAT error
        // is what comes back. Either way the stored row says what was left.
        let mut attempts = 1;
        let result = loop {
            match self
                .confirm_attempt(&mut session, pending, fanout.as_mdk_fanout_mut())
                .await
            {
                Err(e) if e.is_transient() && attempts < crate::relay::fanout::CONFIRM_ATTEMPTS => {
                    attempts += 1;
                }
                settled => break settled.map_err(map_mls_err),
            }
        };
        // Applied, by the row's own word: whatever the queue still holds of
        // this change is retired here too. The staging hold retires it; a
        // kill between the record's write and that, a retirement that
        // failed, and a record the open wrote all arrive here with the
        // change still queued, where it could never be made again and would
        // fail the circle's queue for good.
        if fanout.applied() {
            if let Some(group_id) = fanout.as_mdk_fanout().group_id() {
                let id = FanoutId::new(
                    group_id.clone(),
                    fanout.as_mdk_fanout().message_id().clone(),
                );
                // Who a commit removed the engine announces from memory it
                // does not rebuild at an open, so a removal confirmed after a
                // restart says only that the epoch moved. The intent the
                // engine keeps for the commit outlives its confirm and names
                // them.
                if let Some(SendIntent::RemoveMembers { members, .. }) =
                    self.retire_released_change(&mut session, &id)
                {
                    self.dropped_removals
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .extend(members.iter().map(|member| hex::encode(member.as_slice())));
                }
            }
        }
        self.look_for_stranded(&session);
        let result = self.noted(&session, result);
        let (staged, error) = self.settled(&mut session, result, now_ms, mode).await;
        drop(session);
        Some(FanoutSettlement {
            staged,
            error,
            unretired: false,
        })
    }

    /// One ask of the engine to confirm `fanout`'s commit.
    async fn confirm_attempt(
        &self,
        session: &mut AccountDeviceSession,
        pending: PendingStateRef,
        fanout: &mut OutboundFanout,
    ) -> std::result::Result<SessionEffects, SessionError> {
        if let Some(fault) = self.confirm_fault() {
            return Err(fault);
        }
        Box::pin(session.confirm_published_fanout(pending, fanout)).await
    }

    /// The error the next confirm is to fail with in place of asking the
    /// engine, when a test has queued one.
    #[cfg(any(test, feature = "test-utils"))]
    fn confirm_fault(&self) -> Option<SessionError> {
        self.confirm_faults
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .pop_front()
    }

    #[cfg(not(any(test, feature = "test-utils")))]
    #[allow(clippy::unused_self)]
    const fn confirm_fault(&self) -> Option<SessionError> {
        None
    }

    /// Finishes a confirm the engine stored and did not complete
    /// ([`FanoutStanding::Confirmed`] with a ref): the commit is merged and
    /// its row `Confirmed`, so the plain confirm has nothing left to merge
    /// and only takes the group out of `PendingPublish` and replays what was
    /// buffered behind it. Staging mode, as [`Self::confirm_fanout`].
    pub(crate) async fn finish_confirmed_fanout(
        &self,
        pending: PendingStateRef,
        now_ms: u64,
        mode: DriveMode,
    ) -> FanoutSettlement {
        let mut session = match self.engine().await {
            Ok(session) => session,
            Err(held) => return FanoutSettlement::refused(held),
        };
        // MDK's host's `confirm_published_retrying`, by value
        // (`marmot-account/src/runtime.rs` 3090-3111): asked again only for
        // an error the store calls transient, four asks in all.
        let mut asks = 1;
        let result = loop {
            let asked = match self.confirm_fault() {
                Some(fault) => Err(fault),
                None => Box::pin(session.confirm_published(pending)).await,
            };
            match asked {
                Err(e) if e.is_transient() && asks < crate::relay::fanout::CONFIRM_ATTEMPTS => {
                    asks += 1;
                }
                settled => break settled.map_err(map_mls_err),
            }
        };
        self.look_for_stranded(&session);
        let result = self.noted(&session, result);
        let (staged, error) = self.settled(&mut session, result, now_ms, mode).await;
        drop(session);
        FanoutSettlement {
            staged,
            error,
            unretired: false,
        }
    }

    /// Hands over the Welcomes an applied invite's record still holds, each
    /// to a delivery record of its own.
    ///
    /// What is handed over is the engine's own copy of each — the row it
    /// promoted to an outstanding delivery in the transaction that applied
    /// the commit (`cgka-engine/src/publish.rs` 163-177) — never the
    /// record's, and only while the commit is this device's canonical one:
    /// an invite whose commit has lost to a rival branch would welcome its
    /// recipient into an epoch the circle never reached (Security Rule 3).
    ///
    /// Each goes into MDK's own durable record for an exact signed event and
    /// the relays it is owed to (`DurableTransportFanout`, as MDK's host
    /// keeps one for each Welcome it publishes: `marmot-account/src/runtime.rs`
    /// 4181-4221), with the route kept for its invitee before the invite was
    /// staged ([`CommitNotes::welcome_route`]) and the commit it belongs to.
    /// From then the record, not this one, says what is owed
    /// ([`Self::welcome_records`]), across restarts, and the circle is told a
    /// Welcome is still owed ([`ChangeNote::WelcomeOwed`]).
    ///
    /// A Welcome the engine holds whose invitee has no kept route, or one
    /// the engine neither holds for delivery nor has seen delivered — it
    /// applied this commit by a path of its own, not by the confirm — leaves
    /// its invitee on the roster with no way in, and that is said:
    /// [`ChangeNote::ReinviteOwed`].
    ///
    /// A commit lost for good ends its Welcomes as failed, never as
    /// delivered, and forgets their routes. While the commit is only
    /// provisionally set aside nothing is handed over: taken up again, it
    /// still owes its Welcomes.
    ///
    /// # Errors
    ///
    /// Returns the storage error, redacted; nothing was handed over and the
    /// record still holds its Welcomes.
    pub(crate) async fn hand_over_welcomes(
        &self,
        fanout: &mut StoredFanout,
        now_ms: u64,
        still: Still<'_>,
    ) -> Result<Option<WelcomeHandOver>> {
        let session = self.reading().await;
        if !still.holds() {
            return Ok(None);
        }
        let record = fanout.as_mdk_fanout();
        let mut handed = WelcomeHandOver::default();
        let commit = record.pending_origin_message_id().cloned();
        let fate = Self::applied_commit(&session, record)?;
        let Some(group_id) = record.group_id().cloned() else {
            return Ok(None);
        };
        match (fate, &commit) {
            (AppliedCommit::Canonical, Some(commit)) => {
                for frozen in record.pending_post_confirmation_welcomes() {
                    let welcome = match welcome_standing(
                        &self.message_store,
                        &session,
                        &frozen.id,
                        self.engine_answers_welcomes(),
                    ) {
                        WelcomeStanding::Owed(welcome) => welcome,
                        WelcomeStanding::Done => continue,
                        WelcomeStanding::Undeliverable => {
                            handed.reinvite = true;
                            continue;
                        }
                        // The row keeps its Welcomes for the next drive.
                        WelcomeStanding::Unknown => {
                            return Err(NostrError::StorageError(
                                "a Welcome's standing was not read".into(),
                            ));
                        }
                    };
                    let recipient = welcome_recipient_hex(&welcome);
                    if session
                        .transport_fanout(&welcome.id)
                        .map_err(map_mls_err)?
                        .is_some()
                    {
                        // A pass that stopped, or a kill, after the record's
                        // write: its route is left, and its note may be.
                        if let Some(recipient) = &recipient {
                            self.commit_notes.forget_welcome_route(&group_id, recipient);
                        }
                        handed.opened = true;
                        continue;
                    }
                    let Some(recipient) = recipient else {
                        handed.reinvite = true;
                        continue;
                    };
                    // An unread route is not a missing one: the row keeps its
                    // Welcomes for the next drive.
                    let Some((relays, not_after)) = self
                        .commit_notes
                        .welcome_route(&group_id, &recipient)
                        .map_err(|_| {
                            NostrError::StorageError("a Welcome's route was not read".into())
                        })?
                    else {
                        handed.reinvite = true;
                        continue;
                    };
                    session
                        .put_transport_fanout(&welcome_record(
                            &group_id,
                            Some(commit),
                            welcome,
                            &recipient,
                            &relays,
                            not_after,
                            now_ms,
                        ))
                        .map_err(map_mls_err)?;
                    // Said at once: a later Welcome of this pass can stop it.
                    handed.opened = true;
                    let _ = self.commit_notes.note(&group_id, ChangeNote::WelcomeOwed);
                    self.commit_notes
                        .forget_welcome_route(&group_id, &recipient);
                }
            }
            (AppliedCommit::Provisional, _) => {
                handed.withheld = true;
                return Ok(Some(handed));
            }
            (AppliedCommit::Lost, _) => self.fail_lost_welcomes(&session, record, &group_id)?,
            (AppliedCommit::Canonical, None) => {}
        }
        if handed.opened {
            // Again for a record an earlier pass wrote and did not say.
            let _ = self.commit_notes.note(&group_id, ChangeNote::WelcomeOwed);
        }
        if handed.reinvite {
            // Best-effort, and said once: the Welcomes are released below, so
            // a note that is not written is not written again.
            let _ = self.commit_notes.note(&group_id, ChangeNote::ReinviteOwed);
        }
        fanout
            .as_mdk_fanout_mut()
            .mark_post_confirmation_welcomes_released();
        Self::update_fanout(&session, fanout.as_mdk_fanout())?;
        drop(session);
        Ok(Some(handed))
    }

    /// Ends as failed every Welcome of `record`, whose commit lost for good:
    /// nothing a later drive reads can tell them from Welcomes still owed once
    /// the record is gone, so they end here, as MDK ends a rolled-back
    /// invite's (`publish.rs` 431-441).
    fn fail_lost_welcomes(
        &self,
        session: &AccountDeviceSession,
        record: &OutboundFanout,
        group_id: &GroupId,
    ) -> Result<()> {
        for frozen in record.pending_post_confirmation_welcomes() {
            if session.stored_sent_welcome(&frozen.id).is_ok() {
                self.message_store
                    .update_message_state(&frozen.id, MessageState::Failed)
                    .map_err(map_storage_err)?;
            }
            session
                .delete_transport_fanout(&frozen.id)
                .map_err(map_mls_err)?;
            if let Some(recipient) = welcome_recipient_hex(frozen) {
                self.commit_notes.forget_welcome_route(group_id, &recipient);
            }
        }
        Ok(())
    }

    /// Forgets the routes kept for the invitees of `fanout`'s Welcomes: its
    /// invite was undone, and MDK failed those Welcomes with it
    /// (`publish.rs` 431-441; decision 68).
    pub(crate) fn forget_undone_welcome_routes(&self, fanout: &OutboundFanout) {
        if let Some(group_id) = fanout.group_id() {
            for frozen in fanout.pending_post_confirmation_welcomes() {
                if let Some(recipient) = welcome_recipient_hex(frozen) {
                    self.commit_notes.forget_welcome_route(group_id, &recipient);
                }
            }
        }
    }

    /// Writes the delivery record of each of `group_id`'s founding Welcomes
    /// ([`welcome_record`], naming no commit: a founding create is canonical
    /// on return), before any is sent, and tells the circle a Welcome is
    /// owed. Each is then a retryable delivery obligation of its own
    /// (`protocol-core/publish-lifecycle.md` 68-75), sent as an invite's is.
    ///
    /// Returns the transport id of each.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted: the caller abandons the
    /// group, which takes any record written with it.
    pub(crate) async fn record_founding_welcomes(
        &self,
        group_id: &GroupId,
        welcomes: Vec<FoundingWelcome>,
        now_ms: u64,
    ) -> Result<Vec<MessageId>> {
        let session = self.reading().await;
        let ids: Vec<MessageId> = welcomes
            .iter()
            .map(|welcome| welcome.message.id.clone())
            .collect();
        for welcome in welcomes {
            session
                .put_transport_fanout(&welcome_record(
                    group_id,
                    None,
                    welcome.message,
                    &welcome.recipient,
                    &welcome.relays,
                    welcome.not_after,
                    now_ms,
                ))
                .map_err(map_mls_err)?;
        }
        drop(session);
        if !ids.is_empty() {
            let _ = self.commit_notes.note(group_id, ChangeNote::WelcomeOwed);
        }
        Ok(ids)
    }

    /// How many of the founding Welcomes `ids` of `group_id` are delivered
    /// ([`Self::welcomes_delivered`]), and the invitees, as lowercase hex,
    /// whose Welcome to it a record still holds: read in one hold, so a drive
    /// completing a Welcome between two reads cannot leave it out of both.
    pub(crate) async fn founding_welcomes_standing(
        &self,
        group_id: &GroupId,
        ids: &[MessageId],
    ) -> (usize, Vec<String>) {
        let session = self.reading().await;
        let owed = session
            .transport_fanouts()
            .unwrap_or_default()
            .into_iter()
            .filter(|record| record.group_id.as_ref() == Some(group_id))
            .filter_map(|record| match record.target {
                TransportPublishTarget::Inbox { recipient, .. } => {
                    Some(hex::encode(recipient.as_slice()))
                }
                TransportPublishTarget::Group { .. } => None,
            })
            .collect();
        let delivered = Self::delivered_in(&session, ids);
        drop(session);
        (delivered, owed)
    }

    /// How many of the Welcomes `ids` are delivered: read from the engine's
    /// row ([`Self::welcome_delivered`]), which outlives the record, so a
    /// Welcome counts whichever drive delivered it and whenever its record
    /// ended.
    pub(crate) async fn welcomes_delivered(&self, ids: &[MessageId]) -> usize {
        Self::delivered_in(&*self.reading().await, ids)
    }

    /// Every Welcome still owed a delivery that this device keeps a record
    /// for: an invite's ([`Self::hand_over_welcomes`]) or a founding one's
    /// ([`Self::record_founding_welcomes`]). A Welcome the engine holds with
    /// no such record — one made before records were kept — is not one of
    /// them: it is never sent from here.
    pub(crate) async fn welcome_records(&self) -> Vec<WelcomeRecord> {
        let session = self.reading().await;
        session
            .transport_fanouts()
            .unwrap_or_default()
            .into_iter()
            .filter(|record| {
                matches!(record.target, TransportPublishTarget::Inbox { .. })
                    && matches!(
                        record.exact_message.envelope,
                        cgka_traits::transport::TransportEnvelope::Welcome { .. }
                    )
            })
            .map(WelcomeRecord)
            .collect()
    }

    /// Where `record`'s Welcome stands, read immediately before each send:
    /// a release is not a promise that its commit is still canonical, nor
    /// that the engine still owes the Welcome, nor that anyone is still to
    /// be welcomed — a founding Welcome has no commit, and every other
    /// check holds for it too.
    pub(crate) async fn welcome_fate(&self, record: &WelcomeRecord) -> WelcomeFate {
        let session = self.reading().await;
        if let Some(commit) = record.0.evolution_id.as_ref() {
            match session.stored_message_state(commit) {
                Ok(Some(MessageState::Processed)) => {}
                Ok(Some(MessageState::EpochInvalidated | MessageState::Failed) | None) => {
                    return WelcomeFate::Lost;
                }
                _ => return WelcomeFate::Waiting,
            }
        }
        match welcome_still_wanted(&session, &record.0) {
            Some(true) => {}
            Some(false) => return WelcomeFate::Lost,
            None => return WelcomeFate::Waiting,
        }
        let standing = welcome_standing(
            &self.message_store,
            &session,
            &record.0.id,
            self.engine_answers_welcomes(),
        );
        drop(session);
        match standing {
            WelcomeStanding::Owed(_) => WelcomeFate::Owed,
            WelcomeStanding::Done => WelcomeFate::Done,
            WelcomeStanding::Undeliverable => WelcomeFate::Undeliverable,
            WelcomeStanding::Unknown => WelcomeFate::Waiting,
        }
    }

    /// Stores what `relay` answered for `record`'s Welcome at `now_ms`, and
    /// on an acknowledgement — from a relay of the invitee's inbox, the only
    /// ones a record is owed to — completes the Welcome's delivery in the
    /// engine and ends its record. Returns whether it was delivered.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted: the answer is not kept,
    /// and the relay is due again.
    pub(crate) async fn note_welcome_answer(
        &self,
        record: &mut WelcomeRecord,
        relay: usize,
        accepted: bool,
        now_ms: u64,
    ) -> Result<bool> {
        let session = self.reading().await;
        let Some(target) = record.0.targets.get_mut(relay) else {
            return Ok(false);
        };
        target.attempt_count = target.attempt_count.saturating_add(1);
        target.last_attempt_at = Some(cgka_traits::transport::Timestamp(now_ms / 1_000));
        target.state = if accepted {
            TransportFanoutAttemptState::Accepted
        } else {
            TransportFanoutAttemptState::AttemptedFailed
        };
        // An update, never an upsert: a record another drive ended stays
        // ended — and the Welcome counts as delivered if that drive
        // delivered it.
        if session
            .transport_fanout(&record.0.id)
            .map_err(map_mls_err)?
            .is_none()
        {
            return Ok(Self::welcome_delivered_in(&session, record));
        }
        session
            .put_transport_fanout(&record.0)
            .map_err(map_mls_err)?;
        if !accepted {
            return Ok(false);
        }
        // A mark that fails leaves the Welcome outstanding and its record
        // holding the acknowledgement: the next drive completes it without a
        // send ([`Self::complete_acknowledged_welcome`]).
        session
            .mark_sent_welcome_delivered(&record.0.id)
            .map_err(map_mls_err)?;
        self.end_welcome_record_in(&session, record, WelcomeEnd::Delivered);
        drop(session);
        Ok(true)
    }

    /// Whether `record`'s Welcome is delivered: the engine holds its delivery
    /// complete (`mark_sent_welcome_delivered` leaves the row `Processed`),
    /// whichever drive completed it.
    pub(crate) async fn welcome_delivered(&self, record: &WelcomeRecord) -> bool {
        Self::welcome_delivered_in(&*self.reading().await, record)
    }

    fn welcome_delivered_in(session: &AccountDeviceSession, record: &WelcomeRecord) -> bool {
        Self::delivered_in(session, std::slice::from_ref(&record.0.id)) == 1
    }

    fn delivered_in(session: &AccountDeviceSession, ids: &[MessageId]) -> usize {
        ids.iter()
            .filter(|id| {
                matches!(
                    session.stored_message_state(id),
                    Ok(Some(MessageState::Processed))
                )
            })
            .count()
    }

    /// Completes the delivery of `record`'s Welcome, whose acknowledgement by
    /// an inbox relay is stored and whose completion is not: no send.
    /// Returns whether it was completed.
    pub(crate) async fn complete_acknowledged_welcome(&self, record: &WelcomeRecord) -> bool {
        let session = self.reading().await;
        if session.mark_sent_welcome_delivered(&record.0.id).is_err() {
            return false;
        }
        self.end_welcome_record_in(&session, record, WelcomeEnd::Delivered);
        drop(session);
        true
    }

    /// Ends `record` without a delivery: its Welcome is no longer owed
    /// (`Done`), the engine neither owes it nor saw it delivered under a
    /// canonical commit (`Undeliverable`, which tells the circle its invitee
    /// must be invited again: [`ChangeNote::ReinviteOwed`]), its commit is
    /// lost for good (`Lost`, which ends the Welcome as failed), or its bound
    /// passed with no inbox relay acknowledging it (`Expired`: the Welcome
    /// stays the engine's outstanding one and the circle's note that it is
    /// still owed stands).
    pub(crate) async fn end_welcome_record(&self, record: &WelcomeRecord, end: WelcomeEnd) {
        let session = self.reading().await;
        if end == WelcomeEnd::Lost && session.stored_sent_welcome(&record.0.id).is_ok() {
            let _ = self
                .message_store
                .update_message_state(&record.0.id, MessageState::Failed);
        }
        if end == WelcomeEnd::Undeliverable {
            if let Some(group_id) = record.0.group_id.as_ref() {
                let _ = self.commit_notes.note(group_id, ChangeNote::ReinviteOwed);
            }
        }
        if end == WelcomeEnd::Expired {
            // Kept, inert, so no other record's end clears the circle's note
            // while this Welcome is still owed; said again, in case it was
            // acknowledged while the record was still sending.
            let mut inert = record.0.clone();
            for target in &mut inert.targets {
                target.state = TransportFanoutAttemptState::PolicyProhibited;
            }
            if session
                .transport_fanout(&inert.id)
                .is_ok_and(|kept| kept.is_some())
                && session.put_transport_fanout(&inert).is_ok()
            {
                if let Some(group_id) = inert.group_id.as_ref() {
                    let _ = self.commit_notes.note(group_id, ChangeNote::WelcomeOwed);
                }
            }
            drop(session);
            return;
        }
        self.end_welcome_record_in(&session, record, end);
        drop(session);
    }

    fn end_welcome_record_in(
        &self,
        session: &AccountDeviceSession,
        record: &WelcomeRecord,
        end: WelcomeEnd,
    ) {
        if session.delete_transport_fanout(&record.0.id).is_err() || end == WelcomeEnd::Shown {
            return;
        }
        let Some(group_id) = record.0.group_id.as_ref() else {
            return;
        };
        let owed = session.transport_fanouts().is_ok_and(|records| {
            records
                .iter()
                .any(|other| other.group_id.as_ref() == Some(group_id) && other.id != record.0.id)
        });
        if !owed {
            self.commit_notes.clear(group_id, ChangeNote::WelcomeOwed);
        }
    }

    /// Ends an applied commit's record: the last thing its driver does with
    /// it.
    ///
    /// # Errors
    ///
    /// Returns the storage error, redacted; the row is kept.
    ///
    /// `kept` is shown every stored fanout in the same hold and says whether
    /// this one must stay: returns whether the row was deleted.
    pub(crate) async fn end_fanout(
        &self,
        fanout: &StoredFanout,
        kept: impl FnOnce(&[OutboundFanout]) -> bool + Send,
    ) -> Result<bool> {
        let id = fanout.as_mdk_fanout().message_id();
        let session = self.reading().await;
        if kept(&commit_side(
            session.outbound_fanouts().map_err(map_mls_err)?,
        )) {
            return Ok(false);
        }
        session.delete_outbound_fanout(id).map_err(map_mls_err)?;
        drop(session);
        // A record that ends still holding Welcomes delivers none of them.
        self.forget_undone_welcome_routes(fanout.as_mdk_fanout());
        crate::relay::fanout::release(id);
        Ok(true)
    }

    /// Whether `group_id`'s queue holds an invite of `recipient` (hex): one
    /// the circle's next full advance stages, whose Welcome needs its route.
    pub(crate) fn invite_is_queued(&self, group_id: &GroupId, recipient: &str) -> bool {
        queued_group_changes(&self.message_store, group_id)
            .iter()
            .any(|queued| match &queued.intent {
                SendIntent::Invite { key_packages, .. } => key_packages.iter().any(|package| {
                    cgka_engine::key_package_metadata(package)
                        .is_ok_and(|metadata| metadata.credential_identity_hex == recipient)
                }),
                _ => false,
            })
    }

    /// Every stored fanout of a live circle, read in one hold, for `read`.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted.
    pub(crate) async fn with_fanouts<R>(
        &self,
        read: impl FnOnce(&[OutboundFanout]) -> R + Send,
    ) -> Result<R> {
        let all = commit_side(
            self.reading()
                .await
                .outbound_fanouts()
                .map_err(map_mls_err)?,
        );
        Ok(read(&all))
    }

    /// MDK's `OutboundFanout::wake_retryable_unavailable_targets`
    /// (`traits/src/transport_adapter.rs` 471-486) over every stored fanout
    /// of a live circle: a relay that could not be reached is due again at
    /// once. A record with a relay that answered `rate-limited:` is skipped
    /// whole — MDK's call wakes those too, and that relay was reached.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted.
    pub(crate) async fn wake_unreachable_fanout_targets(&self) -> Result<()> {
        let session = self.reading().await;
        for mut fanout in session.outbound_fanouts().map_err(map_mls_err)? {
            let rate_limited = (0..fanout.target_statuses().len()).any(|index| {
                fanout.target_status(index) == Some(FanoutTargetStatus::RetryableUnavailable)
                    && fanout
                        .target_failure(index)
                        .is_some_and(|failure| failure.rejection_category.is_some())
            });
            if !rate_limited && fanout.wake_retryable_unavailable_targets() > 0 {
                session.put_outbound_fanout(&fanout).map_err(map_mls_err)?;
            }
        }
        drop(session);
        Ok(())
    }

    /// Rolls back the commit `fanout` holds, which every relay proved it did
    /// not take: the engine discards it and stores the row `RolledBack` in one
    /// transaction (`publish.rs` 421-496), then the commit's own stored row is
    /// retired and the fanout row deleted ([`Self::finish_rolled_back`]).
    /// Staging mode, as [`Self::confirm_fanout`].
    ///
    /// The ROW says whether the rewind happened, never the call's result: the
    /// engine can fail after it (`publish.rs` 499, 531-536), and a rewound
    /// commit whose own row is left `Sent` is merged by the next convergence
    /// pass (T-ROLLBACK-RESURRECT).
    pub(crate) async fn roll_back_fanout(
        &self,
        fanout: &mut StoredFanout,
        now_ms: u64,
        still: Still<'_>,
    ) -> Option<FanoutSettlement> {
        let Some(pending) = fanout.as_mdk_fanout().pending_ref() else {
            return Some(FanoutSettlement::refused(NostrError::MdkError(
                "the fanout holds no pending commit",
            )));
        };
        let mut session = match self.engine().await {
            Ok(session) => session,
            Err(held) => return Some(FanoutSettlement::refused(held)),
        };
        if !still.holds() {
            return None;
        }
        // Raised before the rewind and lowered by the next engine call, which
        // finds no rolled-back row left: a rewind whose retirement below
        // fails, or whose future is dropped before it, is finished there.
        self.session.owe_finish(&session);
        let result = Box::pin(session.publish_failed_fanout(pending, fanout.as_mdk_fanout_mut()))
            .await
            .map_err(map_mls_err);
        let mut unretired = false;
        if fanout.as_mdk_fanout().mls_state() == FanoutMlsState::RolledBack {
            // Not fatal: the rewind stands, its batch must still be handed
            // back, and the stored `RolledBack` row makes the next drive or
            // the next open finish what failed here.
            if let Err(e) = self.finish_rolled_back_in(&session, fanout.as_mdk_fanout()) {
                log::warn!(
                    "[Fanout] a rolled-back commit's row was not retired; the next drive \
                     finishes it: {}",
                    e.code()
                );
                unretired = true;
            }
            // MDK re-arms a rolled-back eviction; a receive pass must not
            // re-stage it against the relays that just refused it, and no
            // later pass may before its wait is over.
            if let Some(group_id) = fanout.as_mdk_fanout().group_id() {
                self.hold_eviction_retick(&session, group_id.clone());
                self.hold_restaging(group_id, now_ms);
            }
            self.forget_undone_welcome_routes(fanout.as_mdk_fanout());
        }
        self.look_for_stranded(&session);
        let result = self.noted(&session, result);
        let (staged, error) = self
            .settled(&mut session, result, now_ms, DriveMode::Full)
            .await;
        drop(session);
        Some(FanoutSettlement {
            staged,
            error,
            unretired,
        })
    }

    /// Finishes a rollback the engine has already stored: retires the
    /// commit's row, then deletes the fanout row.
    ///
    /// # Errors
    ///
    /// Returns the storage error, redacted. The row is kept on any failure,
    /// so the next drive finds it `RolledBack` and finishes.
    pub(crate) async fn finish_rolled_back(&self, fanout: &StoredFanout) -> Result<()> {
        let session = self.reading().await;
        self.finish_rolled_back_in(&session, fanout.as_mdk_fanout())
    }

    /// MDK's rollback leaves the commit's own row `Sent`, and a later
    /// convergence pass can select it and merge a commit no relay accepted
    /// (T-ROLLBACK-RESURRECT). The stored `RolledBack` fanout is the durable
    /// marker that says which row: it is deleted only once that row is
    /// retired.
    fn finish_rolled_back_in(
        &self,
        session: &AccountDeviceSession,
        fanout: &OutboundFanout,
    ) -> Result<()> {
        // First, and while the stored row still says a commit was undone:
        // the drive that undid it may be one nobody is waiting on, and a
        // process that dies after the row is gone would leave no trace of
        // it. Written again by whichever finisher gets here; a note is a
        // bit, and setting it twice is setting it.
        if let Some(group_id) = fanout.group_id() {
            // A note that was not written keeps the row, and whoever
            // finishes next tries again.
            if !self
                .commit_notes
                .note(group_id, undone_note(self.commit_notes.as_ref(), fanout))
            {
                return Err(NostrError::MdkError(UNNOTED));
            }
        }
        if let Some(origin) = fanout.pending_origin_message_id() {
            retire_commit(&self.message_store, origin).map_err(map_storage_err)?;
        }
        session
            .delete_outbound_fanout(fanout.message_id())
            .map_err(map_mls_err)?;
        crate::relay::fanout::release(fanout.message_id());
        Ok(())
    }

    /// Settles a pending fanout whose commit some other path resolved and
    /// under whose ref the engine holds nothing ([`FanoutStanding::Stale`],
    /// not bound): kept, confirmed, when the commit ended applied here;
    /// removed otherwise ([`Self::settle_stale_row`]).
    ///
    /// # Errors
    ///
    /// Returns the storage error, redacted; the row is kept.
    pub(crate) async fn discard_stale_fanout(&self, id: &FanoutId) -> Result<()> {
        let session = self.reading().await;
        let rows = session
            .outbound_fanouts_for_group(id.group())
            .map_err(map_mls_err)?;
        let settled = match rows.iter().find(|row| row.message_id() == id.message()) {
            // Read again in this hold: only a row that is still pending,
            // still stale and still not bound is settled.
            Some(row)
                if row.pending_ref().is_some()
                    && !Self::origin_is_sent(&session, row)?
                    && !Self::holds(&session, row) =>
            {
                self.settle_stale_row(&session, row)
            }
            _ => Ok(()),
        };
        drop(session);
        settled
    }

    /// Ends a pending fanout the engine no longer holds
    /// ([`FanoutStanding::Unheld`]) when no attempt was ever begun under it:
    /// nothing was sent, so the preparation is abandoned
    /// (`protocol-core/durability.md`, "Prepared with no possible external
    /// publish") — its commit's row retired, so no convergence pass merges a
    /// commit nobody was sent, and the row deleted. Returns whether it did;
    /// a row with an attempt begun is kept.
    ///
    /// # Errors
    ///
    /// Returns the storage error, redacted; the row is kept.
    pub(crate) async fn abandon_unsent_fanout(&self, id: &FanoutId) -> Result<bool> {
        let session = self.reading().await;
        let Some(fanout) = session
            .outbound_fanouts_for_group(id.group())
            .map_err(map_mls_err)?
            .into_iter()
            .find(|row| row.message_id() == id.message())
        else {
            return Ok(false);
        };
        if fanout.pending_ref().is_none()
            || Self::holds(&session, &fanout)
            || !never_attempted(&fanout)
        {
            return Ok(false);
        }
        // Read again in THIS hold: a pass that ran since the driver looked
        // may have applied the commit, and a commit applied here keeps its
        // record for the relays it still owes.
        if !Self::origin_is_sent(&session, &fanout)? {
            return self.settle_stale_row(&session, &fanout).map(|()| true);
        }
        // A record frozen for no relay is a trial an open wrote for a commit
        // it found staged and the engine did not adopt. Its history is not
        // the commit's — whoever staged that commit may have published it —
        // so the record goes and the commit's own row stays as it was found.
        let ended = if fanout.request().target.endpoints().is_empty() {
            session
                .delete_outbound_fanout(fanout.message_id())
                .map(|()| crate::relay::fanout::release(fanout.message_id()))
                .map_err(map_mls_err)
        } else {
            self.finish_rolled_back_in(&session, &fanout)
        };
        drop(session);
        if ended.is_ok() {
            log::warn!(
                "[Fanout] a commit record with nothing staged behind it and nothing sent was \
                 removed"
            );
        }
        ended.map(|()| true)
    }

    /// Whether a row of the commit's own group names the commit the engine
    /// tracks under `pending`.
    fn has_fanout(session: &AccountDeviceSession, pending: PendingStateRef) -> Result<bool> {
        let Ok(group_id) = session.pending_group_id(pending) else {
            return Ok(false);
        };
        Ok(session
            .outbound_fanouts_for_group(&group_id)
            .map_err(map_mls_err)?
            .iter()
            .any(|fanout| match fanout.mls_state() {
                FanoutMlsState::Pending(of_row) => {
                    of_row == pending && Self::holds(session, fanout)
                }
                // Merged and stored, and the engine has not yet left
                // `PendingPublish`: still the driver's, which finishes it. A
                // plain rollback here would rewind the engine's own epoch
                // state under a commit the store has applied.
                FanoutMlsState::Confirmed => {
                    Self::unfinished_confirm(session, fanout) == Some(pending)
                }
                FanoutMlsState::RolledBack | FanoutMlsState::NotApplicable => false,
            }))
    }

    /// Refuses a legacy resolver the commit `pending` names when that commit
    /// has a fanout row: resolved here it would leave the row `Pending`, and
    /// MDK's next hydrate binds a pending row to whatever commit is then
    /// staged (T-STALE-FANOUT). Fails closed: a row that cannot be read is
    /// treated as present.
    #[cfg(any(test, feature = "test-utils"))]
    fn refuse_fanout_owned(session: &AccountDeviceSession, pending: PendingStateRef) -> Result<()> {
        match Self::has_fanout(session, pending) {
            Ok(false) => Ok(()),
            Ok(true) | Err(_) => Err(NostrError::FanoutOwned),
        }
    }

    /// Whether `group_id` has a pending commit record whose commit is still
    /// stored as sent and which the engine no longer holds staged: a relay
    /// may hold that commit, and nothing on this device can confirm or
    /// discard it any more. No new change of the circle is staged beside it —
    /// MDK's hydrate would bind its ref to that change
    /// (`protocol-core/durability.md`: such an uncertainty is never discarded
    /// and never replaced). It ends when the engine's own convergence has
    /// disposed of the commit, after which the record reads stale.
    fn blocked_by_unheld_fanout(session: &AccountDeviceSession, group_id: &GroupId) -> bool {
        !matches!(
            session.epoch_state(group_id),
            Some(EpochState::PendingPublish(_))
        ) && Self::has_unresolved_fanout(session, group_id)
    }

    /// Whether `group_id` has a pending commit record whose commit is still
    /// stored as sent.
    fn has_unresolved_fanout(session: &AccountDeviceSession, group_id: &GroupId) -> bool {
        session
            .outbound_fanouts_for_group(group_id)
            .is_ok_and(|rows| {
                rows.iter().any(|row| {
                    row.pending_ref().is_some()
                        && Self::origin_is_sent(session, row).unwrap_or(true)
                })
            })
    }

    /// The one rule of a hold that records nothing — a send's preflight, a
    /// leave, a receive advance outside the fanout driver — for what it
    /// stages: it makes no commit. What each rollback hands back joins the
    /// batch.
    ///
    /// The engine's own commit — an eviction a preflight or an advance
    /// stages — is undone in the hold, unsent: it has no record, so nothing
    /// could send or resolve it, and left staged it would hold its circle at
    /// a commit no relay ever saw. The engine arms the eviction again, for a
    /// plane that records it.
    ///
    /// And "one pending commit record per circle": any commit staged in a
    /// circle that has such a record is rolled back in the hold, exactly as
    /// staging mode refuses to record it ([`Self::put_commit_fanout`]).
    async fn unstaged_beside_a_fanout(
        &self,
        session: &mut AccountDeviceSession,
        effects: SessionEffects,
    ) -> SessionEffects {
        let now_ms = self.legacy_now_ms();
        let beside = |session: &AccountDeviceSession, item: &PublishWork| match item {
            PublishWork::GroupEvolution { pending, .. }
            | PublishWork::AutoPublish { pending, .. } => session
                .pending_group_id(*pending)
                .ok()
                .filter(|group_id| {
                    matches!(item, PublishWork::AutoPublish { .. })
                        || Self::has_unresolved_fanout(session, group_id)
                })
                .map(|group_id| (*pending, Self::has_unresolved_fanout(session, &group_id))),
            _ => None,
        };
        if !effects
            .publish
            .iter()
            .any(|item| beside(session, item).is_some())
        {
            return effects;
        }
        let SessionEffects {
            mut events,
            publish,
            mut queued,
            mut pending_convergence,
        } = effects;
        let mut kept = Vec::new();
        for item in publish {
            let Some((pending, beside_a_record)) = beside(session, &item) else {
                kept.push(item);
                continue;
            };
            if beside_a_record {
                log::warn!(
                    "[Fanout] a change staged beside an unresolved pending one is rolled back"
                );
            } else if self.restaging_held(session, pending, now_ms) {
                said_undone_inside_a_wait();
            } else {
                say_undone_in_its_hold(None, DriveMode::FinishOnly);
            }
            match self.publish_failed_in(session, pending, true).await {
                Ok(undone) => {
                    events.extend(undone.events);
                    kept.extend(undone.publish);
                    queued.extend(undone.queued);
                    pending_convergence.extend(undone.pending_convergence);
                }
                Err(_) => kept.push(item),
            }
        }
        SessionEffects {
            events,
            publish: kept,
            queued,
            pending_convergence,
        }
    }

    /// [`Self::abandon_unsent_fanout`], called as the driver calls it once it
    /// has read a record as one the engine no longer holds: how a test puts a
    /// convergence pass between that read and this call.
    ///
    /// # Errors
    ///
    /// As [`Self::abandon_unsent_fanout`].
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn abandon_unsent_fanout_for_test(&self, id: &FanoutId) -> Result<bool> {
        self.abandon_unsent_fanout(id).await
    }

    /// Resolves `pending` with the engine's plain confirm, past the refusal a
    /// commit under a fanout row meets: how a test leaves a row behind a
    /// commit it no longer describes.
    ///
    /// # Errors
    ///
    /// Returns any engine error, redacted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn confirm_published_past_its_fanout_for_test(
        &self,
        pending: PendingStateRef,
    ) -> Result<SessionEffects> {
        let mut session = self.engine().await?;
        let result = Box::pin(session.confirm_published(pending))
            .await
            .map_err(map_mls_err);
        let result = self.noted(&session, result);
        drop(session);
        result
    }

    /// [`Self::confirm_published_past_its_fanout_for_test`] for the plain
    /// rollback, as a process that died right after it leaves the store: a
    /// retirement that failed is not tried again by this session.
    ///
    /// # Errors
    ///
    /// Returns any engine error, redacted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn publish_failed_past_its_fanout_for_test(
        &self,
        pending: PendingStateRef,
    ) -> Result<SessionEffects> {
        let mut session = self.engine().await?;
        let result = self.publish_failed_in(&mut session, pending, false).await;
        drop(session);
        // As a new process: what this session would retire before its next
        // engine call is forgotten, so the row a failed retirement left as
        // sent stays as a kill would leave it.
        self.unretired
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clear();
        result
    }

    /// [`Self::send`] past the refusal a circle with an unresolved pending
    /// record meets: how a test stages the commit that refusal exists to
    /// prevent.
    ///
    /// # Errors
    ///
    /// Returns any engine error, redacted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn send_past_a_pending_fanout_for_test(
        &self,
        intent: SendIntent,
    ) -> Result<SessionEffects> {
        let mut session = self.engine().await?;
        let result = Box::pin(session.send(intent)).await.map_err(map_mls_err);
        let result = self.noted(&session, result);
        drop(session);
        result
    }

    /// The engine's full advance of `group_id`, with nothing done about what
    /// it stages: what a process that died inside a staging hold — between
    /// the engine's staging and the record's write — leaves. How a test has
    /// a commit staged with no record, which nothing in the product leaves on
    /// cue.
    ///
    /// # Errors
    ///
    /// Returns any engine error, redacted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn stage_unrecorded_for_test(&self, group_id: &GroupId) -> Result<SessionEffects> {
        let mut session = self.engine().await?;
        let result = Box::pin(session.advance_convergence(group_id))
            .await
            .map_err(map_mls_err);
        let result = self.noted(&session, result);
        drop(session);
        result
    }

    /// Runs `effects` through the legacy calls' check for a commit staged
    /// beside an unresolved pending record, under the session lock: how a test
    /// hands that check a commit no receive plane can be made to stage on cue.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn unstaged_beside_a_fanout_for_test(
        &self,
        effects: SessionEffects,
    ) -> SessionEffects {
        let Ok(mut session) = self.engine().await else {
            return effects;
        };
        self.unstaged_beside_a_fanout(&mut session, effects).await
    }

    /// [`Self::send_location_staging`], with no departure check ahead of it:
    /// how a test puts a due eviction in front of the send's own hold, which
    /// in the product only a race between that check and the send can.
    ///
    /// # Errors
    ///
    /// As [`Self::send_location_staging`].
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn send_location_staging_for_test(
        &self,
        group_id: &GroupId,
        content: String,
        now_ms: u64,
        mode: DriveMode,
    ) -> Result<Staged> {
        self.send_location_staging(group_id, content, now_ms, Still::new(&mode, mode), false)
            .await
            .map(|(staged, _)| staged)
    }

    /// [`Self::process_event_staging`] in the mode `source` reads now, asked
    /// again of `source` after the hand-back.
    ///
    /// # Errors
    ///
    /// As [`Self::process_event_staging`].
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn process_event_staging_for_test(
        &self,
        event: &Event,
        now_ms: u64,
        source: &dyn crate::relay::fanout::ModeSource,
    ) -> Result<(ScreenedIngest, Vec<FanoutId>)> {
        self.process_event_staging(event, now_ms, Still::new(source, source.mode()))
            .await
    }

    /// [`Self::leave_group_staging`] in the mode `source` reads now, asked
    /// again of `source` after the hand-back.
    ///
    /// # Errors
    ///
    /// As [`Self::leave_group_staging`].
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn leave_group_staging_for_test(
        &self,
        group_id: &GroupId,
        now_ms: u64,
        source: &dyn crate::relay::fanout::ModeSource,
    ) -> Result<Option<Staged>> {
        self.leave_group_staging(group_id, now_ms, Still::new(source, source.mode()))
            .await
    }

    /// [`Self::departure_holds_a_send`] in the mode `source` reads now, asked
    /// again of `source` after the hand-back: whether the send is held, or
    /// `None` when nothing stands in its way.
    ///
    /// # Errors
    ///
    /// As [`Self::departure_holds_a_send`].
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn departure_holds_a_send_for_test(
        &self,
        group_id: &GroupId,
        now_ms: u64,
        source: &dyn crate::relay::fanout::ModeSource,
    ) -> Result<Option<bool>> {
        self.departure_holds_a_send(group_id, Some(now_ms), Still::new(source, source.mode()))
            .await
            .map(|held| held.map(|(_, held)| held))
    }

    /// What the driver's engine calls do when the engine fails them, without
    /// the failure: takes whatever the engine holds emitted and gives every
    /// commit in it its row, in one hold. How a test shows that nothing a
    /// failed call left behind stays in the engine's buffer.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn settle_a_failed_call_for_test(&self, now_ms: u64) -> Staged {
        let Ok(mut session) = self.engine().await else {
            return Staged {
                effects: empty_effects(),
                fanouts: Vec::new(),
                welcomes: Vec::new(),
                proposals: Vec::new(),
                unrecorded: Vec::new(),
                waiting: Vec::new(),
            };
        };
        let failed = Err(NostrError::MdkError("a failed engine call"));
        self.settled(&mut session, failed, now_ms, DriveMode::Full)
            .await
            .0
    }

    /// Runs `effects` through [`Self::stage_commits`] under the session lock:
    /// how a test hands the staging step a commit the engine staged in some
    /// other call.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn stage_commits_for_test(&self, effects: SessionEffects, now_ms: u64) -> Staged {
        let Ok(mut session) = self.engine().await else {
            return Staged {
                effects,
                fanouts: Vec::new(),
                welcomes: Vec::new(),
                proposals: Vec::new(),
                unrecorded: Vec::new(),
                waiting: Vec::new(),
            };
        };
        self.stage_commits(&mut session, effects, now_ms, None, false, DriveMode::Full)
            .await
    }

    /// Makes the next fanout resolution, leave, staging ingest or location
    /// seal find `effects` beside its own batch, as it finds whatever an
    /// earlier engine call left in the engine's one-shot buffers: how a test hands the driver a commit
    /// staged with a live ref and no record, or another circle's re-minted
    /// proposal, which no engine call can be made to leave on cue.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn strand_effects_for_test(&self, effects: SessionEffects) {
        *self
            .stranded
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(effects);
    }

    /// `effects` with what [`Self::strand_effects_for_test`] left, as the
    /// engine's next collection would hand it on.
    #[cfg(any(test, feature = "test-utils"))]
    fn beside_stranded_for_test(&self, effects: SessionEffects) -> SessionEffects {
        let stranded = self
            .stranded
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        match stranded {
            Some(stranded) => chain_effects(effects, stranded),
            None => effects,
        }
    }

    /// Makes the next confirms of a fanout's commit fail without asking the
    /// engine, one per entry: `true` as a store that was busy — the error MDK
    /// calls transient — and `false` as one that failed outright.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn fail_next_confirms_for_test(&self, transient: &[bool]) {
        use cgka_traits::StorageError as Fault;
        self.confirm_faults
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .extend(transient.iter().map(|transient| {
                SessionError::Storage(if *transient {
                    Fault::Busy("injected".to_owned())
                } else {
                    Fault::Backend("injected".to_owned())
                })
            }));
    }

    /// How many of [`Self::fail_next_confirms_for_test`]'s failures no
    /// confirm has met yet.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn confirm_faults_left_for_test(&self) -> usize {
        self.confirm_faults
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .len()
    }

    /// Deletes the stored fanout `id` names from under whatever is driving
    /// it: how a test shows that an answer arriving after its row has ended
    /// does not write the row back.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn end_fanout_for_test(&self, id: &FanoutId) -> Result<()> {
        self.reading()
            .await
            .delete_outbound_fanout(id.message())
            .map_err(map_mls_err)?;
        crate::relay::fanout::release(id.message());
        Ok(())
    }

    /// How many times the epoch-stall detector armed a walk of a circle's
    /// history in this session.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn stall_arms_for_test(&self) -> usize {
        self.stall_arms.load(Ordering::SeqCst)
    }

    /// Whether `group_id` reads `Stalled` ([`Self::stalled`]).
    #[cfg(any(test, feature = "test-utils"))]
    pub fn stalled_for_test(&self, group_id: &GroupId) -> bool {
        self.stalled(group_id)
    }

    /// How many times this session asked the engine for a self-update.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn self_update_asks_for_test(&self) -> usize {
        self.self_update_asks.load(Ordering::SeqCst)
    }

    /// The hash of this device's own leaf in `group_id`.
    ///
    /// # Errors
    ///
    /// The engine's error, redacted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn own_leaf_hash_for_test(&self, group_id: &GroupId) -> Result<Vec<u8>> {
        self.reading()
            .await
            .own_leaf_hash(group_id)
            .map_err(map_mls_err)
    }

    /// The phase of each of `group_id`'s maintenance obligations, by
    /// trigger: `("post_join", "catch_up")`.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn obligations_for_test(
        &self,
        group_id: &GroupId,
    ) -> Vec<(&'static str, &'static str)> {
        self.reading()
            .await
            .maintenance_obligations_for_group(group_id)
            .unwrap_or_default()
            .iter()
            .map(|obligation| {
                let trigger = match obligation.trigger {
                    MaintenanceTrigger::PostJoin => "post_join",
                    MaintenanceTrigger::Periodic => "periodic",
                    MaintenanceTrigger::Manual => "manual",
                };
                (trigger, obligation.phase.as_str())
            })
            .collect()
    }

    /// Leaves the repair's mark standing, as a process that died inside a
    /// repair's staging hold leaves it.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn mark_repair_for_test(&self, group_id: &GroupId) -> bool {
        self.commit_notes.mark_repair(group_id, true)
    }

    /// Whether a repair's mark stands.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn repair_marked_for_test(&self, group_id: &GroupId) -> Option<bool> {
        self.commit_notes.repair_marked(group_id)
    }

    /// The jitter MDK sampled for `group_id`'s post-join obligation.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn post_join_jitter_for_test(&self, group_id: &GroupId) -> Option<u64> {
        self.reading()
            .await
            .maintenance_obligations_for_group(group_id)
            .ok()?
            .iter()
            .find(|obligation| obligation.trigger == MaintenanceTrigger::PostJoin)
            .map(|obligation| obligation.sampled_jitter_ms)
    }

    /// [`Self::post_join_due`] at `now_ms`, for a test.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn post_join_due_for_test(&self, now_ms: u64) -> (Vec<GroupId>, Option<u64>) {
        self.post_join_due(now_ms).await
    }

    /// Queues a self-update of `group_id`, as the engine's own
    /// `queue_outbound_intent` would for one it could not make now.
    ///
    /// # Errors
    ///
    /// Returns an error if the message store cannot be written.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn queue_self_update_intent_for_test(&self, group_id: &GroupId) -> Result<()> {
        self.queue_intent_for_test(
            group_id,
            SendIntent::SelfUpdate {
                group_id: group_id.clone(),
            },
        )
        .await
    }

    /// How many self-updates of `group_id` the engine holds queued.
    ///
    /// # Errors
    ///
    /// Returns an error if the message store cannot be read.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn queued_self_update_count_for_test(&self, group_id: &GroupId) -> Result<usize> {
        let _session = self.reading().await;
        Ok(self
            .message_store
            .list_queued_outbound_intents(group_id)
            .map_err(map_storage_err)?
            .iter()
            .filter(|queued| matches!(queued.intent, SendIntent::SelfUpdate { .. }))
            .count())
    }

    /// How many durable group evolutions the engine holds: the records its
    /// own maintenance writes for a self-update.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn group_evolution_count_for_test(&self) -> Result<usize> {
        self.reading()
            .await
            .group_evolutions()
            .map(|evolutions| evolutions.len())
            .map_err(map_mls_err)
    }

    /// The ids of the Welcomes the engine holds as outstanding deliveries.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn outstanding_welcome_ids_for_test(&self) -> Result<Vec<MessageId>> {
        self.reading()
            .await
            .outstanding_sent_welcomes()
            .map(|welcomes| {
                welcomes
                    .into_iter()
                    .map(|(_, welcome)| welcome.id)
                    .collect()
            })
            .map_err(map_mls_err)
    }

    /// The delivery record of Welcome `welcome`, as a test may read it: the
    /// commit it belongs to, the relays it is owed to, and how often each was
    /// attempted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn welcome_record_for_test(
        &self,
        welcome: &MessageId,
    ) -> Option<(MessageId, Vec<String>, Vec<u32>)> {
        let record = self.reading().await.transport_fanout(welcome).ok()??;
        Some((
            record.evolution_id?,
            record
                .targets
                .iter()
                .map(|target| target.endpoint.0.clone())
                .collect(),
            record
                .targets
                .iter()
                .map(|target| target.attempt_count)
                .collect(),
        ))
    }

    /// The ids of every Welcome delivery record of `group_id`.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn welcome_record_ids_for_test(&self, group_id: &GroupId) -> Result<Vec<MessageId>> {
        Ok(self
            .reading()
            .await
            .transport_fanouts()
            .map_err(map_mls_err)?
            .into_iter()
            .filter(|record| record.group_id.as_ref() == Some(group_id))
            .map(|record| record.id)
            .collect())
    }

    /// Welcome `welcome`'s delivery record in full, as a test may read it.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn welcome_record_probe_for_test(
        &self,
        welcome: &MessageId,
    ) -> Option<WelcomeRecordProbe> {
        let record = self.reading().await.transport_fanout(welcome).ok()??;
        let TransportPublishTarget::Inbox {
            recipient,
            endpoints,
        } = &record.target
        else {
            return None;
        };
        Some(WelcomeRecordProbe {
            commit: record.evolution_id.clone(),
            group: record.group_id.clone(),
            recipient: hex::encode(recipient.as_slice()),
            endpoints: endpoints
                .iter()
                .map(|endpoint| endpoint.0.clone())
                .collect(),
            attempts: record
                .targets
                .iter()
                .map(|target| target.attempt_count)
                .collect(),
            required_acks: record.required_acks,
            bounded_until_secs: record.bounded_until.map(|until| until.0),
            payload: record.exact_message.payload.clone(),
        })
    }

    /// The `created_at` of Welcome `welcome`'s gift wrap as the engine stores
    /// it, staged or owed.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn welcome_created_at_for_test(&self, welcome: &MessageId) -> Option<u64> {
        use cgka_traits::storage::MessageStorage as _;
        let _session = self.reading().await;
        let row = self.message_store.get_message(welcome).ok()?;
        let payload = StoredMessagePayload::decode(&row.payload).ok()?;
        let message = payload
            .as_staged_invite_welcome()
            .map(|(message, _)| message.clone())
            .or_else(|| payload.as_outbound_welcome().cloned())?;
        Some(
            Self::transport_message_to_event(&message)
                .ok()?
                .created_at
                .as_secs(),
        )
    }

    /// Deletes Welcome `welcome`'s delivery record, as another drive's end of
    /// it would.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn delete_welcome_record_for_test(&self, welcome: &MessageId) {
        let _ = self.reading().await.delete_transport_fanout(welcome);
    }

    /// The route kept for `recipient`'s Welcome to `group_id` until its
    /// commit's confirm hands it to a record.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn welcome_route_for_test(
        &self,
        group_id: &GroupId,
        recipient: &str,
    ) -> Option<Vec<String>> {
        self.commit_notes
            .welcome_route(group_id, recipient)
            .ok()
            .flatten()
            .map(|(relays, _)| relays)
    }

    /// What a test may read of the stored fanout `id` names.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn fanout_probe_for_test(&self, id: &FanoutId) -> Result<Option<FanoutProbe>> {
        Ok(self
            .reading()
            .await
            .outbound_fanouts()
            .map_err(map_mls_err)?
            .iter()
            .find(|fanout| fanout.message_id() == id.message())
            .and_then(FanoutProbe::of))
    }

    /// The handles of `group_id`'s stored commit and proposal fanouts, in
    /// staging order.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn fanout_ids_for_test(&self, group_id: &GroupId) -> Result<Vec<FanoutId>> {
        Ok(self
            .reading()
            .await
            .outbound_fanouts_for_group(group_id)
            .map_err(map_mls_err)?
            .iter()
            .filter(|fanout| fanout.application_message().is_none())
            .map(|fanout| FanoutId::new(group_id.clone(), fanout.message_id().clone()))
            .collect())
    }

    /// What a test may read of `group_id`'s stored application records, in
    /// staging order.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn location_records_for_test(&self, group_id: &GroupId) -> Result<Vec<FanoutProbe>> {
        Ok(self
            .reading()
            .await
            .outbound_fanouts_for_group(group_id)
            .map_err(map_mls_err)?
            .iter()
            .filter(|fanout| fanout.application_message().is_some())
            .filter_map(FanoutProbe::of)
            .collect())
    }

    /// How many Welcomes the engine holds as sent and not yet delivered: the
    /// ones a confirmed invite's commit promoted.
    ///
    /// # Errors
    ///
    /// Returns the engine's storage error, redacted.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn outstanding_welcome_count_for_test(&self) -> Result<usize> {
        self.reading()
            .await
            .outstanding_sent_welcomes()
            .map(|welcomes| welcomes.len())
            .map_err(map_mls_err)
    }

    /// Whether `group_id` holds a commit staged with no fanout row — the state
    /// a restart cannot recover. Read in one hold.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn staged_without_fanout_for_test(&self, group_id: &GroupId) -> bool {
        let session = self.reading().await;
        let Some(EpochState::PendingPublish(staged)) = session.epoch_state(group_id) else {
            return false;
        };
        !session
            .outbound_fanouts_for_group(group_id)
            .is_ok_and(|rows| {
                rows.iter()
                    .any(|fanout| fanout.pending_ref() == Some(staged.pending_ref()))
            })
    }

    /// When the engine's re-armed `SelfRemove` eviction for `group_id` falls
    /// due, whatever [`Self::eviction_retick_held`] says: the deadline a test
    /// waits out before the advance that stages it again.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn eviction_due_after_for_test(
        &self,
        group_id: &GroupId,
    ) -> Option<std::time::Duration> {
        self.engine()
            .await
            .ok()?
            .scheduled_self_remove_auto_commit_delay_ms(group_id)
            .ok()
            .flatten()
            .map(std::time::Duration::from_millis)
    }

    /// Whether some call holds the session lock now
    /// ([`Self::hold_session_for_test`]).
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn session_is_held_for_test(&self) -> bool {
        self.session.is_held()
    }

    /// Holds the session lock until the guard is dropped, so a test can queue
    /// two calls behind it in a known order.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn hold_session_for_test(&self) -> impl Drop + '_ {
        self.reading().await.held()
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
        let Ok(mut session) = self.engine().await else {
            return empty_effects();
        };
        let effects = session.drain();
        self.note_effects(&session, &effects);
        effects
    }

    /// Hands `result` back after [`Self::note_effects`] has seen it.
    fn noted<B: EngineBatch>(&self, held: &AccountDeviceSession, result: Result<B>) -> Result<B> {
        if let Ok(batch) = &result {
            self.note_effects(held, batch);
        }
        result
    }

    /// What every engine batch Haven receives is owed: [`Self::note_batch`]
    /// over its events, and the groups it names owed an advance
    /// ([`Self::owe_advance`]) — the engine hands each name out once, so a
    /// batch whose names were dropped would leave its group to nobody.
    /// `held` is the session guard: the message store is touched only under
    /// it (see `message_store`).
    fn note_effects<B: EngineBatch>(&self, held: &AccountDeviceSession, batch: &B) {
        self.note_batch(held, batch.events());
        self.owe_advance(batch.pending());
        self.note_state_inputs(batch.events(), batch.proposals());
        self.note_stall_evidence(held, batch.events());
        for event in batch.events() {
            if let GroupEvent::GroupStateRevalidated {
                group_id,
                revalidated_commit_id,
                ..
            } = event
            {
                self.note_revalidated_removal(held, group_id, revalidated_commit_id);
            }
        }
        self.sync_mesh_keys(held, batch.events(), batch.proposals());
    }

    /// Restarts the post-join quiet window of each circle `events` move to
    /// a new epoch or `proposals` names (MDK's "authenticated commit or
    /// proposal", `marmot-account/src/runtime.rs` 1424-1449, 2567-2580).
    fn note_state_inputs(&self, events: &[GroupEvent], proposals: &[GroupId]) {
        let moved = events.iter().filter_map(|event| match event {
            GroupEvent::EpochChanged { group_id, .. } => Some(group_id),
            _ => None,
        });
        let mut inputs = moved.chain(proposals).peekable();
        if inputs.peek().is_none() {
            return;
        }
        let now_ms = self.legacy_now_ms();
        let mut at = self
            .state_input_at
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        for group_id in inputs {
            at.insert(group_id.clone(), now_ms);
        }
    }

    /// What Haven owes every engine batch it receives the moment it sees it:
    /// the refused objects it must refetch, an end to the wait a circle
    /// whose epoch has moved was serving ([`Self::restaging_held`]), and
    /// another try at what it keeps of that circle's stranded input.
    fn note_batch(&self, _held: &AccountDeviceSession, events: &[GroupEvent]) {
        // A member the convergence diff announces as added because this
        // batch withdraws the commit that had taken them out is restored, not
        // re-invited: the withdrawal brings them back keyed (decision 227).
        let withdrawn: Vec<&MessageId> = events
            .iter()
            .filter_map(|event| match event {
                GroupEvent::GroupStateInvalidated {
                    invalidated_commit_id,
                    ..
                } => Some(invalidated_commit_id),
                _ => None,
            })
            .collect();
        let mut refused: HashMap<GroupId, Vec<nostr::EventId>> = HashMap::new();
        for event in events {
            match event {
                GroupEvent::EpochChanged { group_id, .. }
                    if self.commit_notes.restage_wait(group_id).is_some() =>
                {
                    self.commit_notes.set_restage_wait(group_id, None);
                }
                // The engine's hydrate cleared a commit it found staged with
                // no record. Nothing sends a commit without one, so it never
                // left the device, and its row is retired before any pass
                // can apply it (`cleared_at_open`): the change was undone.
                GroupEvent::PendingCommitRecovered { group_id, .. }
                    if !self
                        .unasked_clears
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .remove(group_id) =>
                {
                    let _ = self.commit_notes.note(group_id, ChangeNote::ChangeUndone);
                }
                GroupEvent::GroupStateChanged {
                    group_id,
                    epoch,
                    change:
                        GroupStateChange::MemberRemoved { member }
                        | GroupStateChange::MemberLeft { member },
                    origin_commit_id,
                    ..
                } => self.note_taken_out(group_id, member, epoch.0, origin_commit_id.as_ref()),
                // A re-invite is the circle's choice, whoever made it and
                // whatever batch it arrives in (decision 230): nobody it adds
                // is removed unattended — held and told, never asked for.
                GroupEvent::GroupStateChanged {
                    group_id,
                    change: GroupStateChange::MemberAdded { member },
                    ..
                } if !self
                    .commit_notes
                    .taken_out_by(group_id, member)
                    .is_some_and(|by| withdrawn.contains(&&by)) =>
                {
                    let _ = self.commit_notes.spend_target_asks(
                        group_id,
                        std::slice::from_ref(member),
                        MAX_REQUEUE_ATTEMPTS,
                    );
                }
                GroupEvent::GroupStateInvalidated {
                    group_id,
                    invalidated_commit_id,
                    ..
                } => self.note_withdrawn_removal(group_id, invalidated_commit_id),
                _ => {}
            }
            // A circle whose epoch has moved may now open, or have room for,
            // what the engine erred on or refused when Haven last handed it
            // back: a look, at which each is tried once more.
            if let GroupEvent::EpochChanged { group_id, from, .. } = event {
                // From the tip before the pass: one that rewinds announces
                // its withdrawals after this, and may bring back a target
                // taken out at any epoch it rewound.
                self.commit_notes.forget_gone_removal_targets(
                    group_id,
                    from.0.saturating_sub(max_rewind_commits()),
                );
                self.refused_ledger.moved(group_id);
                let kept = self.commit_notes.kept(group_id).unwrap_or_default();
                if !kept.is_empty() {
                    let mut tried = self
                        .tried
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    for kept in &kept {
                        tried.remove(&kept.id);
                    }
                    drop(tried);
                    self.flag_stranded(group_id);
                }
            }
            if let GroupEvent::TransportObjectResourceRefused {
                group_id,
                message_id,
                ..
            } = event
            {
                // A transport message id is the Nostr event id's bytes
                // (MDK v0.10.4 `transport-nostr-peeler/src/event.rs:40`).
                if let Ok(id) = nostr::EventId::from_slice(message_id.as_slice()) {
                    refused.entry(group_id.clone()).or_default().push(id);
                }
            }
        }
        // After the fold above: a target this same batch brought back is
        // spent with the rest (decision 230).
        for group_id in passes_of_several_commits(events) {
            let _ = self
                .commit_notes
                .spend_removal_asks(&group_id, MAX_REQUEUE_ATTEMPTS);
        }
        let now = self.ledger_now_secs();
        for (group_id, ids) in refused {
            // The engine keeps nothing of these and neither does Haven: a
            // write that fails here costs the id its refetch, and is said.
            let _ = self.refused_ledger.record(&group_id, &ids, now);
        }
    }

    /// What every batch tells the epoch-stall detector, from any plane
    /// (MDK's `observe_recovery_evidence`, `marmot-app/src/client/sync.rs`
    /// 697-790): an epoch passage, a fork branch selection settled, and the
    /// two things that end a stall run — a join, and a message this device
    /// read at its circle's current epoch. Nothing here arms.
    fn note_stall_evidence(&self, held: &AccountDeviceSession, events: &[GroupEvent]) {
        for event in events {
            match event {
                GroupEvent::EpochChanged { group_id, from, to } => {
                    self.moving_stall(group_id, |stall| {
                        stall.observe_epoch_passage(group_id, *from, *to);
                    });
                }
                GroupEvent::GroupStateInvalidated {
                    group_id,
                    reason: GroupStateInvalidationReason::SupersededByBranchSelection,
                    ..
                } => self.stall().observe_convergence_reorg(group_id),
                GroupEvent::GroupJoined { group_id, .. } => self.clear_stall(group_id),
                GroupEvent::MessageReceived {
                    group_id, epoch, ..
                } if held.epoch(group_id).is_ok_and(|current| current == *epoch) => {
                    self.peer_heard(group_id);
                }
                _ => {}
            }
        }
    }

    /// A member a commit this device applied took out no longer holds the
    /// circle for a removal set aside unmade, and is not asked for again,
    /// whoever removed them — so one removed and invited back is not removed
    /// twice. With the last of them the note is taken back.
    fn note_taken_out(
        &self,
        group_id: &GroupId,
        member: &MemberId,
        epoch: u64,
        by: Option<&MessageId>,
    ) {
        if self.commit_notes.take_out_removal_targets(
            group_id,
            std::slice::from_ref(member),
            epoch,
            by,
        ) && self
            .commit_notes
            .removal_targets(group_id)
            .is_some_and(|held| held.is_empty())
        {
            self.commit_notes.settle_removal(group_id);
        }
    }

    /// The members a commit branch selection withdrew had taken out are back
    /// (`GroupStateInvalidated`: what it announced did not happen): they
    /// hold the circle again, and the note that explains the hold is said
    /// again. Every member any applied commit took out comes back, not only
    /// the ones keyed to this commit: one taken out with no commit named — a
    /// pass of several commits, or the roster read — may have gone with the
    /// same reorg. Those come back with their asks spent (decision 227): held
    /// and told, never removed unattended, since the circle may have kept
    /// them.
    fn note_withdrawn_removal(&self, group_id: &GroupId, commit: &MessageId) {
        if self
            .commit_notes
            .bring_back_removal_targets(group_id, commit, MAX_REQUEUE_ATTEMPTS)
        {
            let _ = self
                .commit_notes
                .note(group_id, ChangeNote::QueuedRemovalDropped);
        }
    }

    /// Branch selection re-adopted `commit`. When it is a removal of the
    /// user's that was dropped with its members held
    /// ([`Self::drop_withdrawn_removal`]), the removal stands after all: each
    /// member it held who is no longer listed is taken out by it, the hold
    /// ends with the last of them, and the withdrawal is no longer told — a
    /// note already shown is gone and needs nothing. What MDK re-announces of
    /// the commit is not relied on: the roster says who is gone.
    fn note_revalidated_removal(
        &self,
        held: &AccountDeviceSession,
        group_id: &GroupId,
        commit: &MessageId,
    ) {
        if self.commit_notes.take_dropped_removal(group_id, commit) != Some(true) {
            return;
        }
        let (Ok(members), Some(kept)) = (
            held.members(group_id),
            self.commit_notes.removal_targets(group_id),
        ) else {
            return;
        };
        let gone: Vec<MemberId> = kept
            .into_iter()
            .filter(|target| members.iter().all(|listed| &listed.id != target))
            .collect();
        let epoch = held.epoch(group_id).map_or(0, |epoch| epoch.0);
        let _ = self
            .commit_notes
            .take_out_removal_targets(group_id, &gone, epoch, Some(commit));
        if self
            .commit_notes
            .removal_targets(group_id)
            .is_some_and(|left| left.is_empty())
        {
            self.commit_notes.settle_removal(group_id);
        }
        self.commit_notes
            .clear(group_id, ChangeNote::ChangeWithdrawn);
    }

    /// Now, in the seconds the refused ledger's waits are written in.
    fn ledger_now_secs(&self) -> i64 {
        i64::try_from(self.legacy_now_ms() / 1_000).unwrap_or(i64::MAX)
    }

    // ── Stranded input (T-PARKED-REPLAY) ─────────────────────────────────────

    /// Looks at every circle for stranded input ([`find_stranded`]) and
    /// remembers which hold some that may be taken over. Called with the
    /// session held, after every confirm and every rollback the engine was
    /// asked for, whatever it answered: those are the calls whose replay
    /// reads what is parked, and the ones that leave it behind when the
    /// replay does not finish. A look: what the engine would not take since
    /// the last one is tried once more.
    fn look_for_stranded(&self, session: &AccountDeviceSession) {
        let mut tried = self
            .tried
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        tried.clear();
        self.told_at_redelivery
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clear();
        let found = find_stranded(
            &self.message_store,
            self.commit_notes.as_ref(),
            session,
            &tried,
            &self.examined,
        );
        drop(tried);
        *self
            .holding_stranded
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = found;
    }

    /// Hands back to the engine what it left stranded, and returns what it
    /// made of it — for the caller to put AHEAD of its own batch
    /// ([`Self::behind_what_was_handed_back`]), so that whoever folds that
    /// batch folds this exactly as it folds a relay's delivery, in the
    /// lifecycle and disposition it is in.
    ///
    /// Called with the engine held at the top of every call that hands the
    /// engine an event, advances a circle, or seals or stages for one. The
    /// circle the call is `first` for is seen to before any other: nothing
    /// new of a circle is taken, sealed or staged ahead of what that circle
    /// was owed. One call hands back [`HAND_BACK_WHOLE`] of its own circle's
    /// events at most — [`HAND_BACK_SLICE`] with `whole` off, for a caller
    /// that makes no commit inside a wake, and for any caller beside a live
    /// plane that makes none — and every other circle shares
    /// one slice between them: each event is an ingest, made with the engine
    /// held, and anyone who knows a routing tag decides how many there are.
    ///
    /// With nothing flagged it reads no store.
    ///
    /// # Errors
    ///
    /// Returns [`NostrError::EngineHeld`] while `first` holds input the
    /// hand-back can still take and has not: the call's room ran out, the
    /// circle's cap stands, the engine's store refused a release, or a store
    /// could not be read or written before a row was taken over. The
    /// caller's own work for that circle is not begun, the circle stays
    /// flagged, and its next call carries on; what had been handed back is
    /// kept for the next batch. Each such hold ends by something that
    /// happens: room, at the next call; the cap, when an entry ends — and
    /// nothing a sender can produce stays an entry ([`Self::hand_back`]),
    /// so each call ends as many as it had room for; a store, when it
    /// answers. What can never be handed back holds nothing — a row that is
    /// not a verifiable event, a session with no store to keep one in — and
    /// neither does an event the engine erred on with no record of its own,
    /// which is tried once more at each look.
    async fn hand_back_stranded(
        &self,
        session: &mut AccountDeviceSession,
        first: Option<&GroupId>,
        whole: bool,
    ) -> Result<SessionEffects> {
        #[cfg(any(test, feature = "test-utils"))]
        {
            let act = self
                .during_hand_back
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .take();
            if let Some(act) = act {
                act();
            }
        }
        #[cfg(any(test, feature = "test-utils"))]
        if self.hand_back_ended() {
            return Ok(empty_effects());
        }
        let mut handed = self
            .handed_back
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
            .unwrap_or_else(empty_effects);
        let mut circles = std::mem::take(
            &mut *self
                .holding_stranded
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
        );
        circles.sort_by_key(|circle| Some(circle) != first);
        // Sixteen beside a burst or a pause, whoever calls: a sweep in a
        // background task holds the engine for the whole of what it hands
        // back, and the operating system's budget for it is seconds.
        let whole = whole && !self.beside_a_plane_that_makes_none();
        let mut room = HAND_BACK_SLICE;
        let mut waits = false;
        for group_id in circles {
            let own = first == Some(&group_id);
            let mut all = HAND_BACK_WHOLE;
            let room = if own && whole { &mut all } else { &mut room };
            if *room == 0 {
                self.flag_stranded(&group_id);
                continue;
            }
            let drain =
                Box::pin(self.hand_back_circle(session, &group_id, room, &mut handed, whole)).await;
            #[cfg(any(test, feature = "test-utils"))]
            if drain.died {
                // A death hands nothing on.
                return Ok(empty_effects());
            }
            // Told from what stands now.
            let tried = self
                .tried
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            tell_of_stranded(
                &self.message_store,
                self.commit_notes.as_ref(),
                session,
                &group_id,
                &tried,
                &self.examined,
            );
            drop(tried);
            // What this call did not reach is the next call's. What the
            // engine erred on waits for the next look, not for the next
            // event.
            if drain.more {
                self.flag_stranded(&group_id);
                waits |= own && drain.holds;
            }
        }
        if waits {
            if handed != empty_effects() {
                *self
                    .handed_back
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(handed);
            }
            return Err(NostrError::EngineHeld);
        }
        Ok(handed)
    }

    /// The flagged circle the transport message `msg` is addressed to, by
    /// its routing tag: the one a hand-back sees to first when that message
    /// is the call's own. `None` with nothing flagged, at no cost.
    fn flagged_circle_of(
        &self,
        session: &AccountDeviceSession,
        msg: &cgka_traits::transport::TransportMessage,
    ) -> Option<GroupId> {
        let TransportEnvelope::GroupMessage { transport_group_id } = &msg.envelope else {
            return None;
        };
        let flagged = self
            .holding_stranded
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        flagged.into_iter().find(|group_id| {
            session
                .app_component(group_id, NOSTR_ROUTING_COMPONENT_ID)
                .ok()
                .flatten()
                .and_then(|raw| cgka_traits::app_components::decode_nostr_routing_v1(&raw).ok())
                .is_some_and(|routing| {
                    routing.nostr_group_id.as_slice() == transport_group_id.as_slice()
                })
        })
    }

    /// Keeps what a hand-back returned for the next batch that comes back,
    /// for a call that has none of its own to put it ahead of.
    fn keep_handed_back(&self, ahead: SessionEffects) {
        if ahead != empty_effects() {
            let mut held = self
                .handed_back
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            *held = Some(match held.take() {
                Some(earlier) => chain_effects(earlier, ahead),
                None => ahead,
            });
        }
    }

    /// Marks `group_id` as holding something the next call may hand back.
    fn flag_stranded(&self, group_id: &GroupId) {
        let mut flagged = self
            .holding_stranded
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if !flagged.contains(group_id) {
            flagged.push(group_id.clone());
        }
    }

    /// Records that `id` was handed to the engine, or could not be, in this
    /// look: it is not tried again before the next.
    fn note_tried(&self, id: &MessageId) {
        self.tried
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(id.clone());
    }

    /// One circle's share of [`Self::hand_back_stranded`], while `room`
    /// lasts and the circle holds no commit of this device's own pending —
    /// read again before EACH event, because a handed-back commit or leave
    /// can make this device stage one, and what is left is then the engine's
    /// own replay's, in the order it holds it.
    ///
    /// Three things, in this order. What an earlier hold took over and the
    /// engine was never asked for — a process died between the keep and the
    /// answer — which arrived before every row still standing. Then the
    /// engine's stranded rows, in arrival order: each kept durably, released
    /// through MDK's own `release_message_for_replay`, and handed back. Last,
    /// what the engine erred on, once per look.
    ///
    /// A stop — the circle's cap, or a store that refused — ends the taking
    /// over of rows for this call and nothing else: what the engine erred on
    /// is still tried behind it, so entries that end there make the room the
    /// next call takes rows into.
    ///
    /// A store that cannot be read or written says nothing about what
    /// stands, and is taken as holding: the circle stays flagged and its
    /// call waits, rather than seal or take anything ahead of rows nobody
    /// could look at.
    async fn hand_back_circle(
        &self,
        session: &mut AccountDeviceSession,
        group_id: &GroupId,
        room: &mut usize,
        handed: &mut SessionEffects,
        observe: bool,
    ) -> Drain {
        let mut drain = Drain::default();
        let nothing = replays_nothing(&self.message_store, session, group_id);
        #[cfg(any(test, feature = "test-utils"))]
        let nothing = self.unless_faulted(StoreFault::Group, nothing);
        match nothing {
            Some(true) => {}
            Some(false) => return drain,
            None => return Drain::held(),
        }
        let Some((kept, rows, beyond)) = self.owed_a_hand_back(group_id, *room) else {
            return Drain::held();
        };
        let untried = |id: &MessageId| {
            !self
                .tried
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .contains(id)
        };
        let mut used = Used {
            entries: kept.len(),
            bytes: kept.iter().map(|kept| kept.event.len()).sum(),
        };
        if beyond {
            drain = Drain::held();
        }
        let owed = kept
            .iter()
            .filter(|kept| !kept.asked)
            .map(Owed::Kept)
            .chain(rows.into_iter().map(|row| Owed::Row(Box::new(row))))
            .chain(kept.iter().filter(|kept| kept.asked).map(Owed::Kept));
        let mut stopped = false;
        let mut full = false;
        for owed in owed {
            let id = match &owed {
                Owed::Kept(kept) => kept.id.clone(),
                Owed::Row(row) => row.0.id.clone(),
            };
            let never_asked = !matches!(&owed, Owed::Kept(kept) if kept.asked);
            if !untried(&id) || (stopped && never_asked) {
                continue;
            }
            match replays_nothing(&self.message_store, session, group_id) {
                Some(true) => {}
                Some(false) => break,
                None => return Drain::held(),
            }
            if *room == 0 {
                drain.more = true;
                drain.holds |= never_asked;
                break;
            }
            let before = used.bytes;
            let taken = match owed {
                Owed::Kept(kept) => self.take_up_kept(group_id, kept),
                Owed::Row(row) => self.take_over(group_id, *row, &mut used),
            };
            let event = match taken {
                TakenOver::Event(event) => *event,
                TakenOver::Left => {
                    self.note_tried(&id);
                    continue;
                }
                TakenOver::Stopped { holds, cap } => {
                    stopped = true;
                    full |= cap;
                    drain.more |= holds;
                    drain.holds |= holds;
                    continue;
                }
                #[cfg(any(test, feature = "test-utils"))]
                TakenOver::Died => {
                    drain.died = true;
                    return drain;
                }
            };
            *room -= 1;
            match self
                .hand_back(session, group_id, &id, event, handed, observe)
                .await
            {
                #[cfg(any(test, feature = "test-utils"))]
                HandedBack::Died => {
                    drain.died = true;
                    return drain;
                }
                HandedBack::Answered => {
                    used.entries = used.entries.saturating_sub(1);
                    used.bytes = before;
                }
                HandedBack::Unanswered => self.note_tried(&id),
            }
        }
        if full {
            self.try_again_at_the_next_call(&kept);
        }
        drain
    }

    /// Lets `kept` be handed back again at the next CALL, not only at the
    /// next look: the cap holds the circle's own calls, so nothing but an
    /// entry ending can end that hold, and what the engine erred on is what
    /// fills it.
    fn try_again_at_the_next_call(&self, kept: &[KeptEvent]) {
        let mut tried = self
            .tried
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        for kept in kept {
            tried.remove(&kept.id);
        }
    }

    /// What a hand-back of `group_id` starts from — what Haven keeps for the
    /// circle, and up to `room` of its rows still parked with whether more
    /// stand beyond them — or `None` when either store cannot say, which a
    /// hand-back reads as holding.
    #[allow(clippy::type_complexity)]
    fn owed_a_hand_back(
        &self,
        group_id: &GroupId,
        room: usize,
    ) -> Option<(
        Vec<KeptEvent>,
        Vec<(MessageRecord, cgka_traits::transport::TransportMessage)>,
        bool,
    )> {
        let kept = self.commit_notes.kept(group_id);
        #[cfg(any(test, feature = "test-utils"))]
        let kept = self.unless_faulted(StoreFault::Kept, kept);
        let kept = kept?;
        // No more rows than this call has room for, and one past that to
        // know whether more stand.
        let rows = stranded_rows(&self.message_store, group_id, &kept, room, &self.examined).ok();
        #[cfg(any(test, feature = "test-utils"))]
        let rows = self.unless_faulted(StoreFault::Rows, rows);
        let (rows, beyond) = rows?;
        Some((kept, rows, beyond))
    }

    /// An event Haven already keeps, ready to be handed back: parsed and
    /// verified as a relay's delivery is (Security Rule 16) and found to be
    /// the event its entry names, and only then is the engine's row for it
    /// released, when one stands — a death between the keep and the release
    /// left it beside the copy.
    ///
    /// A copy that is no longer that event can be handed back to nobody, and
    /// does not stay: beside the engine's row it is ended, and the row —
    /// which is the event — is taken over afresh, in its place, at the next
    /// call; with no row left, the event is in neither store, and its id is
    /// owed its refetch as one the engine refused is.
    fn take_up_kept(&self, group_id: &GroupId, kept: &KeptEvent) -> TakenOver {
        let held = TakenOver::Stopped {
            holds: true,
            cap: false,
        };
        let beside = match self.message_store.get_message(&kept.id) {
            Ok(record) => match stranded_row(&self.message_store, record, &self.examined) {
                Ok(row) => row,
                Err(_) => return held,
            },
            Err(StorageError::NotFound) => None,
            Err(_) => return held,
        };
        let Some(event) = Event::from_json(&kept.event).ok().filter(|event| {
            event.verify().is_ok() && event.id.as_bytes().as_slice() == kept.id.as_slice()
        }) else {
            if beside.is_some() {
                self.commit_notes.end(&kept.id);
                return held;
            }
            if nostr::EventId::from_slice(kept.id.as_slice()).is_ok_and(|id| {
                self.refused_ledger
                    .record(group_id, &[id], self.ledger_now_secs())
            }) {
                self.commit_notes.end(&kept.id);
            }
            return TakenOver::Left;
        };
        if let Some((record, _)) = beside {
            if self
                .message_store
                .release_message_for_replay(&record)
                .is_err()
            {
                return held;
            }
        }
        TakenOver::Event(Box::new(event))
    }

    /// Takes one stranded row over from the engine: its event is rebuilt,
    /// verified and found to carry the row's id, kept durably, and only then
    /// is the row released, through MDK's own `release_message_for_replay`.
    fn take_over(
        &self,
        group_id: &GroupId,
        (record, message): (MessageRecord, cgka_traits::transport::TransportMessage),
        used: &mut Used,
    ) -> TakenOver {
        // A row that is not a signed event, or not the one it is stored as,
        // is not released: nothing could hand it back. Its circle's note
        // stands.
        let Some(event) = Self::transport_message_to_event(&message)
            .ok()
            .filter(|event| event.id.as_bytes().as_slice() == record.id.as_slice())
        else {
            return TakenOver::Left;
        };
        let json = event.as_json();
        // Past the cap nothing more is taken over until what is kept has
        // ended; what is left stays the engine's, and holds its circle.
        if used.entries >= KEPT_EVENTS_PER_CIRCLE || used.bytes + json.len() > KEPT_BYTES_PER_CIRCLE
        {
            return TakenOver::Stopped {
                holds: true,
                cap: true,
            };
        }
        #[cfg(any(test, feature = "test-utils"))]
        let refused = self.unless_faulted(StoreFault::Keep, Some(())).is_none();
        #[cfg(not(any(test, feature = "test-utils")))]
        let refused = false;
        if refused
            || !self
                .commit_notes
                .keep(group_id, &record.id, reads_as_change(&event), &json)
        {
            // A store that would not take the write may take the next, and
            // the row can be handed back then: its circle waits. A session
            // with no store never can keep one, and no call waits for that.
            return TakenOver::Stopped {
                holds: self.commit_notes.durable(),
                cap: false,
            };
        }
        #[cfg(any(test, feature = "test-utils"))]
        if self.stops_at(HandBackStop::Kept) {
            return TakenOver::Died;
        }
        if self
            .message_store
            .release_message_for_replay(&record)
            .is_err()
        {
            // The release is one transaction, so the row stands: the event
            // is still the engine's, and a copy beside it would be handed
            // back while the store goes on refusing. The next call asks
            // again.
            self.commit_notes.end(&record.id);
            return TakenOver::Stopped {
                holds: true,
                cap: false,
            };
        }
        #[cfg(any(test, feature = "test-utils"))]
        if self.stops_at(HandBackStop::Released) {
            return TakenOver::Died;
        }
        used.entries += 1;
        used.bytes += json.len();
        TakenOver::Event(Box::new(event))
    }

    /// Hands one kept event back to the engine through the screen and the
    /// ingest a relay's delivery takes, and ends its entry on an answer that
    /// says the engine judged the event or holds it again — as an object it
    /// cannot open yet included: the row is the engine's once more, and
    /// what it later does with it is announced like any other row's.
    ///
    /// An event the engine has no room for ends here too, once its id is
    /// durably owed its refetch exactly as one a relay delivered is
    /// (Security Rule 12; [`RefusedRedeliveryLedger`]): kept instead, such
    /// events — which anyone who knows a routing tag can produce without
    /// number — would fill the circle's cap and stand in front of every row
    /// behind them. An id the ledger could not take stays kept: the event
    /// would otherwise be in neither store.
    ///
    /// An error is an answer too when the engine holds the event's id as
    /// processed: it wrote its own record of the event and then failed to
    /// open it (MDK v0.10.4 `cgka-engine/src/message_processor/ingest.rs`
    /// 1206-1219, 1345-1347), and a redelivery is a duplicate to it from
    /// then on. Anyone holding one of the circle's epoch keys can send such
    /// an event — a member, or one since removed — so it ends, and holds
    /// nothing. Only an error that left the engine with no record keeps the
    /// entry: its own store failed, and Haven's copy is then the only one.
    /// It stays, marked as asked for, and is asked for again at each look.
    ///
    /// Whatever the event's tags say. A NIP-40 expiration is unauthenticated
    /// and decides nothing here (Marmot `transports/nostr.md` 190-192): the
    /// engine reads none when it replays its own rows.
    async fn hand_back(
        &self,
        session: &mut AccountDeviceSession,
        group_id: &GroupId,
        id: &MessageId,
        event: Event,
        handed: &mut SessionEffects,
        observe: bool,
    ) -> HandedBack {
        let answered = match Self::screen_before_auth(&event) {
            Ok(msg) => {
                let taken = msg.id.clone();
                let route = transport_route(&msg);
                let result = Box::pin(session.ingest(msg)).await.map_err(map_mls_err);
                self.note_ingested(session, &event, route, &taken, &result, observe);
                self.noted(session, result).ok()
            }
            Err(_) => None,
        };
        #[cfg(any(test, feature = "test-utils"))]
        if self.stops_at(HandBackStop::Ingested) {
            return HandedBack::Died;
        }
        let Some(ingested) = answered else {
            if self
                .message_store
                .has_processed_transport_id(id)
                .unwrap_or(false)
            {
                self.commit_notes.end(id);
                return HandedBack::Answered;
            }
            self.commit_notes.unanswered(id);
            return HandedBack::Unanswered;
        };
        // An unknown route is dropped without a trace by design, and no
        // redelivery changes that: nothing is owed for it.
        let refused = matches!(ingested.outcome, IngestOutcome::ResourceRefused { .. })
            || (ingested.left_object_unpersisted
                && !matches!(ingested.outcome, IngestOutcome::Ignored { .. }));
        #[cfg(any(test, feature = "test-utils"))]
        let unrecorded = self.unless_faulted(StoreFault::Ledger, Some(())).is_none();
        #[cfg(not(any(test, feature = "test-utils")))]
        let unrecorded = false;
        let taken = if refused {
            !unrecorded
                && self
                    .refused_ledger
                    .record(group_id, &[event.id], self.ledger_now_secs())
        } else {
            match &ingested.outcome {
                // Durable only if the engine's own row says so.
                IngestOutcome::Buffered { .. } => {
                    self.message_store.get_message(id).is_ok()
                        || self
                            .message_store
                            .has_processed_transport_id(id)
                            .unwrap_or(false)
                }
                _ => true,
            }
        };
        if taken {
            self.commit_notes.end(id);
        } else {
            self.commit_notes.unanswered(id);
        }
        // A proposal the engine accepted is announced beside the batch, and
        // an advance has no place for that: its circle is owed one.
        let mut effects = ingested.effects;
        effects
            .pending_convergence
            .extend(ingested.valid_proposal_groups);
        *handed = chain_effects(std::mem::replace(handed, empty_effects()), effects);
        if taken {
            HandedBack::Answered
        } else {
            HandedBack::Unanswered
        }
    }

    /// Puts what [`Self::hand_back_stranded`] returned ahead of `result`'s
    /// own batch. When the call failed, it is kept for the next batch that
    /// comes back instead: the engine has applied it.
    fn behind_what_was_handed_back<B: Effects>(
        &self,
        ahead: SessionEffects,
        mut result: Result<B>,
    ) -> Result<B> {
        match &mut result {
            Ok(batch) => {
                let own = std::mem::replace(batch.effects_mut(), empty_effects());
                *batch.effects_mut() = chain_effects(ahead, own);
            }
            Err(_) => self.keep_handed_back(ahead),
        }
        result
    }

    /// Whether the event `id`, which the engine has just answered `Buffered`
    /// for `group_id`, is one it holds stranded: stored as it arrived, in a
    /// circle that holds no commit of this device's own pending. Such an
    /// answer comes from the engine's stored row, not from anything the
    /// event is waiting for, and is the same at every redelivery — so no
    /// cursor is held for it. One row is read. Its circle is told by a scan
    /// of its own where no look has flagged it — once between two looks,
    /// however often a relay serves the event again.
    pub(crate) async fn holds_stranded(&self, group_id: &GroupId, id: &nostr::EventId) -> bool {
        let id = MessageId::new(id.as_bytes().to_vec());
        let session = self.reading().await;
        let stranded = replays_nothing(&self.message_store, &session, group_id) == Some(true)
            && self.message_store.get_message(&id).is_ok_and(|record| {
                matches!(
                    stranded_row(&self.message_store, record, &self.examined),
                    Ok(Some(_))
                )
            });
        let known = self
            .holding_stranded
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(group_id);
        if stranded
            && !known
            && self
                .told_at_redelivery
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(group_id.clone())
        {
            let tried = self
                .tried
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let takeable = tell_of_stranded(
                &self.message_store,
                self.commit_notes.as_ref(),
                &session,
                group_id,
                &tried,
                &self.examined,
            );
            drop(tried);
            if takeable {
                self.flag_stranded(group_id);
            }
        }
        drop(session);
        stranded
    }

    /// Whether the engine is asked for the Welcomes it owes; not while a test
    /// has it refusing ([`StoreFault::SentWelcome`]).
    fn engine_answers_welcomes(&self) -> bool {
        #[cfg(any(test, feature = "test-utils"))]
        return self
            .unless_faulted(StoreFault::SentWelcome, Some(()))
            .is_some();
        #[cfg(not(any(test, feature = "test-utils")))]
        true
    }

    /// `read`, or `None` while a test has the store failing at `at`: what
    /// the store's own error leaves its caller with.
    #[cfg(any(test, feature = "test-utils"))]
    fn unless_faulted<T>(&self, at: StoreFault, read: Option<T>) -> Option<T> {
        let faulted = self
            .store_faults
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(&at);
        read.filter(|_| !faulted)
    }

    /// Makes the store fail at `at` from now on, or with `failing` off stop
    /// failing there: the engine's own store and Haven's are real ones, and
    /// neither can be made to refuse one read on demand.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn fail_store_for_test(&self, at: StoreFault, failing: bool) {
        let mut faults = self
            .store_faults
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        faults.retain(|fault| *fault != at);
        if failing {
            faults.push(at);
        }
    }

    /// Has [`proposal_stands`] read at most `cap` rows.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn cap_proposal_scan_for_test(&self, cap: usize) {
        self.proposal_scan_cap.store(cap, Ordering::SeqCst);
    }

    /// Whether a test ends the hand-back at `point`, as a process that died
    /// there.
    #[cfg(any(test, feature = "test-utils"))]
    fn stops_at(&self, point: HandBackStop) -> bool {
        let mut stop = self
            .hand_back_stop
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match &mut *stop {
            Some((None, _)) => true,
            Some((at, 0)) if *at == Some(point) => {
                *at = None;
                true
            }
            Some((at, passes)) if *at == Some(point) => {
                *passes -= 1;
                false
            }
            _ => false,
        }
    }

    /// Whether a test has already ended the hand-back.
    #[cfg(any(test, feature = "test-utils"))]
    fn hand_back_ended(&self) -> bool {
        matches!(
            *self
                .hand_back_stop
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
            Some((None, _))
        )
    }

    /// Whether each entry kept for `group_id` is one the engine was asked
    /// for and would not take, in the order kept.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn kept_input_for_test(&self, group_id: &GroupId) -> Vec<bool> {
        self.commit_notes
            .kept(group_id)
            .unwrap_or_default()
            .into_iter()
            .map(|kept| kept.asked)
            .collect()
    }

    /// How many reads of the engine's store looking for stranded input has
    /// made since the session opened: one for each listing of a circle's
    /// rows, and one for each row examined — a decode and a read of the
    /// engine's processed ids.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn stranded_rows_examined_for_test(&self) -> usize {
        self.examined.0.load(Ordering::Relaxed)
    }

    /// Ends every hand-back of stranded input at `point`, once it has been
    /// passed `after` times, exactly as a process death there would: nothing
    /// after it runs, in this call or any later one of this session.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn stop_hand_back_for_test(&self, point: HandBackStop, after: usize) {
        *self
            .hand_back_stop
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some((Some(point), after));
    }

    /// Acknowledges application outputs Haven has durably handled, so MDK stops
    /// holding them for redelivery.
    ///
    /// MDK v0.10.4 keeps each `MessageReceived` (a decrypted inner event) and
    /// `GroupJoined` in a durable table until the host acknowledges it, and
    /// re-emits every unacknowledged one at the next open
    /// (`cgka-engine/src/engine.rs:573-626`). The contract is to acknowledge
    /// only once the application's own record of it has committed
    /// (`cgka-traits/src/storage.rs:362-363`; `marmot-app/src/client/sync.rs:2297-2302`),
    /// so a process killed in between gets the output again instead of losing
    /// it. A failed acknowledgement only costs a redelivery.
    pub async fn acknowledge_outputs(&self, outputs: &[MessageId]) {
        if outputs.is_empty() {
            return;
        }
        let _session = self.reading().await;
        if let Err(e) = self
            .message_store
            .delete_pending_application_events(outputs)
        {
            log::warn!("application outputs not acknowledged: {}", e.kind());
        }
    }

    /// Installs the durable store refused ids wait in. Called once, by the
    /// `CircleManager` that owns this session, before the session is shared.
    pub fn install_refused_ledger(&mut self, ledger: Arc<dyn RefusedRedeliveryLedger>) {
        self.refused_ledger = ledger;
    }

    /// Installs the store the epoch-stall detector's evidence is kept in, and
    /// restores what an earlier process kept: the relays' verdicts on its
    /// history walks, and the instant of the last arm, so a restart neither
    /// erases the evidence nor becomes the re-arm clock.
    pub(crate) fn install_stall_evidence(&mut self, evidence: Arc<dyn StallEvidence>) {
        self.stall()
            .restore_wedge_evidence(evidence.stall_evidence());
        self.stall_evidence = evidence;
    }

    /// Installs the store the mesh keys are kept in and restores what an
    /// earlier process kept, if mesh is still on; with mesh off, stored keys
    /// an earlier process left are deleted, and so are those of a circle
    /// whose row is gone.
    pub(crate) fn install_mesh_keys(&mut self, at_rest: Arc<dyn MeshKeyStore>) {
        let now_ms = self.legacy_now_ms();
        let notes = Arc::clone(&self.commit_notes);
        let stands = |group: &GroupId| notes.circle_stands(group) == Some(true);
        self.mesh_keys.install(at_rest, now_ms, &stands);
    }

    /// Turns the Bluetooth mesh's keys on until `until_ms`, wall-clock
    /// milliseconds, and never for longer than [`MESH_ON_MAX_MS`] from now: a
    /// deadline, not a flag, so keys an app that was never opened again left
    /// behind end by themselves. From here each circle's packet keys are
    /// kept, in memory and in the circle store, for the epoch it stands on
    /// and the [`DEFAULT_MAX_PAST_EPOCHS`] before it, and a location's own
    /// send leaves a packet for the mesh engine ([`Self::mesh_handoff`]).
    /// Called again, it moves the deadline.
    ///
    /// Returns whether mesh is on: not for a deadline that is not ahead of
    /// the clock, nor when the store did not take it — either is mesh off.
    pub async fn mesh_on_until(&self, until_ms: u64) -> bool {
        let session = self.reading().await;
        let groups = session.live_group_ids().unwrap_or_default();
        self.turn_mesh_on(&*session, until_ms, &groups)
    }

    /// Turns the mesh's keys off: every key is dropped, in memory and in the
    /// store, with the deadline, and every packet left for the engine is
    /// withdrawn. Returns whether the store took the delete; one it did not
    /// take is asked again at the next engine call.
    pub async fn mesh_off(&self) -> bool {
        self.turn_mesh_off(&*self.reading().await)
    }

    fn stall(&self) -> std::sync::MutexGuard<'_, EpochStallDetector> {
        self.epoch_stall
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Feeds the epoch-stall detector one ingest's answer, as MDK's app does
    /// on every ingest that moves its cursor (`marmot-app/src/client/sync.rs`
    /// 2800-2880): a deferral of either lineage is evidence the circle fell
    /// behind — unless the event predates this copy's Welcome, which only
    /// lands the epoch — and a want of room arms at once. A terminal copy, or
    /// one the engine does not hold live, is not tracked. An arm owes the
    /// circle a walk of its own history (`RefusedRedeliveryLedger::owe_range`),
    /// keeps its evidence, and asks the live plane for a refetch.
    ///
    /// Only a full drive's ingest feeds it: a plane that only finishes moves
    /// no cursor of the foreground's, and opens no walk.
    fn observe_stall(
        &self,
        session: &AccountDeviceSession,
        created_at_secs: u64,
        id: &MessageId,
        result: &Result<IngestEffects>,
    ) {
        let Ok(ingested) = result else {
            return;
        };
        let mut observed: Vec<(GroupId, StallInput)> = stall_input(&ingested.outcome)
            .map(|(group_id, input)| (group_id.clone(), input))
            .into_iter()
            .collect();
        for event in &ingested.effects.events {
            if let GroupEvent::TransportObjectResourceRefused { group_id, .. } = event {
                observed.push((group_id.clone(), StallInput::Refused));
            }
        }
        let now_ms = self.legacy_now_ms();
        for (group_id, input) in observed {
            let Ok(record) = session.group_record(&group_id) else {
                continue;
            };
            if record.is_terminal() {
                continue;
            }
            let decision = {
                let mut stall = self.stall();
                match input {
                    StallInput::Undecryptable
                        if !record.transport_message_predates_local_copy(
                            cgka_traits::transport::Timestamp(created_at_secs),
                        ) =>
                    {
                        stall.observe_undecryptable(
                            group_id.clone(),
                            hex::encode(id.as_slice()),
                            record.epoch,
                            now_ms,
                        )
                    }
                    StallInput::Refused => {
                        stall.observe_resource_refusal(group_id.clone(), record.epoch, now_ms)
                    }
                    StallInput::Undecryptable | StallInput::Landing => {
                        drop(stall);
                        self.moving_stall(&group_id, |stall| {
                            stall.observe_group_epoch(&group_id, record.epoch);
                        });
                        BackfillDecision::Skip
                    }
                }
            };
            if decision.arms_backfill() {
                #[cfg(any(test, feature = "test-utils"))]
                self.stall_arms.fetch_add(1, Ordering::SeqCst);
                let now_secs = i64::try_from(now_ms / 1_000).unwrap_or(i64::MAX);
                let _ = self.refused_ledger.owe_range(&group_id, now_secs);
                self.keep_stall_evidence(&group_id);
                self.stall_armed.store(true, Ordering::Release);
            }
        }
    }

    /// Stores what the detector holds of `group_id` across a restart.
    fn keep_stall_evidence(&self, group_id: &GroupId) {
        let evidence = self.stall().wedge_evidence(group_id);
        if let Some(evidence) = evidence {
            let _ = self.stall_evidence.keep_stall_evidence(group_id, evidence);
        }
    }

    /// Moves `group_id`'s stall state by `observe` — an epoch passage or a
    /// landing — and stores what that leaves of its evidence when it changed
    /// it: kept, or forgotten once none is left, so a stall that ended does
    /// not come back with the next open.
    fn moving_stall(&self, group_id: &GroupId, observe: impl FnOnce(&mut EpochStallDetector)) {
        let mut stall = self.stall();
        if !stall.tracks(group_id) {
            return;
        }
        let before = stall.wedge_evidence(group_id);
        observe(&mut stall);
        let after = stall.wedge_evidence(group_id);
        drop(stall);
        if before == after {
            return;
        }
        match after {
            Some(evidence) => {
                let _ = self.stall_evidence.keep_stall_evidence(group_id, evidence);
            }
            None => self.stall_evidence.forget_stall_evidence(group_id),
        }
    }

    /// A peer's message at `group_id`'s current epoch was read: the stall
    /// run and its evidence end, its arm pacing stays
    /// (`EpochStallDetector::observe_peer_heard`). The stored evidence is
    /// rewritten only when there was some to end.
    fn peer_heard(&self, group_id: &GroupId) {
        let mut stall = self.stall();
        let had = stall
            .wedge_evidence(group_id)
            .is_some_and(|evidence| evidence.parts().1 > 0 || evidence.parts().2);
        stall.observe_peer_heard(group_id);
        drop(stall);
        if had {
            self.keep_stall_evidence(group_id);
        }
    }

    /// Ends `group_id`'s stall run for good: a join (the detector's own
    /// contract, `epoch_stall.rs` `clear_recovered_group`). Its stored
    /// evidence goes with it.
    fn clear_stall(&self, group_id: &GroupId) {
        let mut stall = self.stall();
        if !stall.tracks(group_id) {
            return;
        }
        stall.clear_recovered_group(group_id);
        drop(stall);
        self.stall_evidence.forget_stall_evidence(group_id);
    }

    /// A walk of `group_id`'s owed history range ended having asked every
    /// relay down to the circle's start (`RangePass::Whole`): `owing` that
    /// something it brought back was not taken in, which re-arms the walk
    /// (`rearm_refused_groups`); otherwise the relays confirmed they hold
    /// nothing that moves this device, one fruitless completion
    /// (`observe_fruitless_completion` — skipped by the detector itself for a
    /// circle that has left the epoch it armed at).
    pub(crate) fn history_walk_settled(&self, group_id: &GroupId, owing: bool) {
        {
            let mut stall = self.stall();
            if owing {
                stall.rearm_refused_groups(&HashSet::from([group_id.clone()]));
            } else {
                let _ = stall.observe_fruitless_completion([group_id]);
            }
        }
        self.keep_stall_evidence(group_id);
    }

    /// Whether `group_id` reads `Stalled`: relay-confirmed fruitless walks
    /// have reached the detector's report threshold, whether or not the arm
    /// run escalated first — never a count of arms, which a minted flood can
    /// drive ([`super::epoch_stall::EPOCH_STALL_ESCALATION_ARM_THRESHOLD`]'s
    /// doc).
    pub(crate) fn stalled(&self, group_id: &GroupId) -> bool {
        self.stall().fruitless_threshold_reached(group_id)
    }

    /// Whether an arm owed a refetch since the last ask, clearing it.
    pub(crate) fn take_stall_armed(&self) -> bool {
        self.stall_armed.swap(false, Ordering::AcqRel)
    }

    /// Takes what `group_id` has not been told about its changes, leaving
    /// nothing: a test's peek and acknowledge in one.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn take_change_notes(&self, group_id: &GroupId) -> Vec<ChangeNote> {
        let notice = self.change_notice(group_id);
        self.acknowledge_change_notice(group_id, &notice);
        notice.notes
    }

    /// Who a removal the user asked for named, dropped unmade
    /// ([`ChangeNote::QueuedRemovalDropped`] still standing), that the
    /// circle still lists, as lowercase hex: the members a "Remove again" is
    /// offered for. A member kept from an earlier copy of the circle, or one
    /// a commit took out, is not one of them. `None` when the store cannot
    /// say — never an empty list that would hide one.
    #[must_use]
    pub fn unmade_removal_members(&self, group_id: &GroupId) -> Option<Vec<String>> {
        if !self
            .commit_notes
            .stands(group_id, ChangeNote::QueuedRemovalDropped)?
        {
            return Some(Vec::new());
        }
        let listed = match self.message_store.get_group(group_id) {
            Ok(group) => group.members,
            Err(StorageError::NotFound) => Vec::new(),
            Err(_) => return None,
        };
        Some(
            self.commit_notes
                .removal_targets(group_id)?
                .iter()
                .filter(|target| listed.iter().any(|member| &member.id == *target))
                .map(|member| hex::encode(member.as_slice()))
                .collect(),
        )
    }

    /// What `group_id` has not been told about its changes, left as it is.
    /// To show them, read [`Self::change_notice`] instead.
    #[must_use]
    pub fn peek_change_notes(&self, group_id: &GroupId) -> Vec<ChangeNote> {
        self.commit_notes.peek(group_id)
    }

    /// What `group_id` has not been told about its changes, read to be
    /// shown: show it, then [`Self::acknowledge_change_notice`]. A process
    /// that dies between the two is handed the same notes again.
    #[must_use]
    pub fn change_notice(&self, group_id: &GroupId) -> ChangeNotice {
        self.commit_notes.notice(group_id)
    }

    /// Drops what `notice` read from what `group_id` has not been told: its
    /// user has now been shown it. Only while nothing was written for the
    /// circle since the read: a note raised or a member held after it is
    /// not dropped unseen, and the next notice shows it. Again for the same
    /// notice, it drops nothing more. Returns `false` when a write since the
    /// read superseded the notice.
    ///
    /// The notes that say what IS are not dropped here, and end when it
    /// does: the two for input the engine holds unread
    /// ([`ChangeNote::UnreadChange`]), and the one for what a background
    /// pass left for the foreground ([`ChangeNote::AwaitsForeground`]).
    pub fn acknowledge_change_notice(&self, group_id: &GroupId, notice: &ChangeNotice) -> bool {
        self.commit_notes.acknowledge(group_id, notice)
    }

    /// Says that a change of `group_id`'s relays is applied away from the
    /// foreground ([`ChangeNote::AwaitsForeground`]); whether it is durably
    /// said.
    pub(crate) fn await_foreground(&self, group_id: &GroupId) -> bool {
        self.commit_notes
            .note(group_id, ChangeNote::AwaitsForeground)
            || self.awaits_foreground(group_id)
    }

    /// Records on each of `groups` that its routing id is another's too
    /// ([`ChangeNote::RoutingCollision`]).
    ///
    /// # Errors
    ///
    /// [`NostrError::StorageError`] when a note could not be written: the
    /// caller follows nothing, and the next reconcile tries again.
    pub(crate) fn note_routing_collision(&self, groups: &[&GroupId]) -> Result<()> {
        if self
            .commit_notes
            .note_all(groups, ChangeNote::RoutingCollision)
        {
            Ok(())
        } else {
            Err(NostrError::StorageError(
                "a routing collision was not recorded".to_string(),
            ))
        }
    }

    /// How many re-invites MDK owes in `group_id` ([`Self::owed_reinvites`]).
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn owed_reinvite_count_for_test(&self, group_id: &GroupId) -> usize {
        self.owed_reinvites()
            .await
            .iter()
            .filter(|owed| &owed.group_id == group_id)
            .count()
    }

    /// [`Self::note_routing_collision`] for `group_id` alone, as a rotation or
    /// a Welcome onto another circle's routing id leaves it.
    ///
    /// # Errors
    ///
    /// As [`Self::note_routing_collision`].
    #[cfg(any(test, feature = "test-utils"))]
    pub fn note_routing_collision_for_test(&self, group_id: &GroupId) -> Result<()> {
        self.note_routing_collision(&[group_id])
    }

    /// The oldest transport `created_at` (seconds) of what the engine keeps
    /// of `group_id` at or after `from_epoch`, or `None` when it keeps
    /// nothing, or anything it cannot read ([`oldest_transport_secs`]).
    pub(crate) async fn oldest_kept_transport_secs(
        &self,
        group_id: &GroupId,
        from_epoch: u64,
    ) -> Option<u64> {
        use cgka_traits::storage::MessageStorage as _;
        let _session = self.reading().await;
        let records = self
            .message_store
            .list_messages(group_id, EpochId(from_epoch))
            .ok()?;
        oldest_transport_secs(records.iter().map(|record| record.payload.as_slice()))
    }

    /// Whether `group_id` is waiting for a full drive in the foreground
    /// ([`ChangeNote::AwaitsForeground`]). A store that cannot say answers
    /// that it is.
    pub(crate) fn awaits_foreground(&self, group_id: &GroupId) -> bool {
        self.commit_notes
            .stands(group_id, ChangeNote::AwaitsForeground)
            != Some(false)
    }

    /// A full drive has completed, and what `still` says it ran under was a
    /// claimed foreground from its first act to this one: no circle waits
    /// for one any longer ([`ChangeNote::AwaitsForeground`]) — but a circle
    /// in `erred`, whose own record the drive ended on an error in.
    ///
    /// Asked again for each circle with the engine held, and nothing is
    /// awaited between the answer and the write: a pause that landed while
    /// this waited for the engine clears nothing, and one that lands
    /// mid-way leaves the rest waiting.
    pub(crate) async fn foreground_drove(&self, still: Still<'_>, erred: &HashSet<GroupId>) {
        let Ok(_session) = self.engine().await else {
            return;
        };
        for group_id in self.message_store.list_groups().unwrap_or_default() {
            if !still.holds() || self.plane_standing() != PlaneStanding::Foreground as u64 {
                return;
            }
            if !erred.contains(&group_id) && self.awaits_foreground(&group_id) {
                self.commit_notes
                    .clear(&group_id, ChangeNote::AwaitsForeground);
            }
        }
    }

    /// Drops `note` from what `group_id` has not been told: its author was
    /// just told it, in the outcome of the call that made the change.
    pub(crate) fn clear_change_note(&self, group_id: &GroupId, note: ChangeNote) {
        self.commit_notes.clear(group_id, note);
    }

    /// Whether `group_id`'s recorded pending commit is known to remove
    /// nobody; `false` whenever that is not known.
    pub(crate) fn commit_removes_nobody(&self, group_id: &GroupId) -> bool {
        self.commit_notes.removes_nobody(group_id)
    }

    /// [`Self::commit_removes_nobody`], for a test of a record whose mark
    /// nothing else shows: one stored as possibly exposed is never undone
    /// whatever its mark says.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn commit_removes_nobody_for_test(&self, group_id: &GroupId) -> bool {
        self.commit_removes_nobody(group_id)
    }

    /// Every id `group_id` owes a refetch of, due or not: the NIP-77 pass
    /// leaves them to the ledger's own schedule.
    pub(crate) fn refused_owes(&self, group_id: &GroupId) -> HashSet<nostr::EventId> {
        self.refused_ledger.owed_ids(group_id)
    }

    /// [`Self::refused_owes`].
    #[cfg(any(test, feature = "test-utils"))]
    pub fn refused_owes_for_test(&self, group_id: &GroupId) -> HashSet<nostr::EventId> {
        self.refused_owes(group_id)
    }

    /// The event ids of `group_id`'s transport objects that the engine deferred
    /// and then retired for a local resource bound.
    ///
    /// The engine keeps nothing of such an object and the cursor has usually
    /// passed it (a deferral advances it), so a refetch by id is its one way
    /// back: Marmot `transports/nostr.md` requires the client to give it
    /// another delivery opportunity, and forbids recording it as seen (Security
    /// Rule 12). Reading discharges nothing — see
    /// [`Self::resolve_refused_redeliveries`].
    ///
    /// At most `limit` of those whose wait is over, least recently asked for
    /// first, so a sweep's share rotates through a backlog bigger than one
    /// sweep may ask for, and an id a sweep could not discharge is not asked
    /// for again until the wait that earned has passed
    /// ([`refetch_spacing_secs`]).
    #[must_use]
    pub fn refused_redeliveries(&self, group_id: &GroupId, limit: usize) -> Vec<nostr::EventId> {
        self.refused_ledger
            .owed(group_id, limit, self.ledger_now_secs())
    }

    /// Records that `ids` were asked for and are still owed; `wholesale`
    /// when the engine refused again everything the sweep brought back
    /// ([`RefusedRedeliveryLedger::tried`]).
    pub fn refused_redeliveries_tried(
        &self,
        group_id: &GroupId,
        ids: &[nostr::EventId],
        wholesale: bool,
    ) {
        if !ids.is_empty() {
            self.refused_ledger
                .tried(group_id, ids, self.ledger_now_secs(), wholesale);
        }
    }

    /// Discharges refused ids that were delivered again, or that every relay
    /// asked answered without.
    pub fn resolve_refused_redeliveries(&self, group_id: &GroupId, ids: &[nostr::EventId]) {
        if !ids.is_empty() {
            self.refused_ledger.resolve(group_id, ids);
        }
    }

    /// The history range `group_id` owes a refetch of, once its refused ids
    /// outgrew [`MAX_REFUSED_IDS_PER_GROUP`] — whether or not its wait is
    /// over ([`Self::refused_range_to_ask`]).
    #[must_use]
    pub fn refused_range(&self, group_id: &GroupId) -> Option<OwedRange> {
        self.refused_ledger.owed_range(group_id)
    }

    /// [`Self::refused_range`] when a pass may ask for it now, marked as
    /// asked: a pass that carries the walk no further makes the next wait
    /// twice as long, so a relay is not walked through a circle's history at
    /// every sweep while the engine has no room for what comes back.
    #[must_use]
    pub fn refused_range_to_ask(&self, group_id: &GroupId) -> Option<OwedRange> {
        let now_secs = self.ledger_now_secs();
        self.refused_ledger
            .owed_range(group_id)
            .filter(|range| range.is_due(now_secs))?;
        self.refused_ledger.range_tried(group_id, now_secs);
        // Read again: the walk stands where this pass will be held to.
        self.refused_ledger.owed_range(group_id)
    }

    /// Whether `group_id` owes the refetch of anything the engine refused.
    #[must_use]
    pub fn owes_refetch(&self, group_id: &GroupId) -> bool {
        !self.refused_ledger.owed(group_id, 1, i64::MAX).is_empty()
            || self.refused_ledger.owed_range(group_id).is_some()
    }

    /// Whether the engine recorded `event` as processed — so an ingest of it
    /// that then erred left its verdict behind, and nothing of it is owed.
    #[must_use]
    pub fn engine_processed(&self, event: &nostr::EventId) -> bool {
        self.message_store
            .has_processed_transport_id(&MessageId::new(event.as_bytes().to_vec()))
            .unwrap_or(false)
    }

    /// Records how far the pass that read `read` got
    /// ([`RefusedRedeliveryLedger::settle_owed_range`]).
    pub fn settle_refused_range(&self, group_id: &GroupId, read: OwedRange, pass: RangePass) {
        self.refused_ledger.settle_owed_range(group_id, read, pass);
    }

    /// Runs `act` once, inside the next hand-back of stranded input — which
    /// every entry runs, holding the engine, before it asks for anything.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn during_next_hand_back_for_test(&self, act: impl FnOnce() + Send + 'static) {
        *self
            .during_hand_back
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Box::new(act));
    }

    /// Whether MDK still retains the intent of this device's commit
    /// `commit` (its own-commit record, mdk#1734).
    #[cfg(any(test, feature = "test-utils"))]
    pub fn own_commit_intent_retained_for_test(&self, commit: &nostr::EventId) -> bool {
        self.message_store
            .own_commit_intent(&MessageId::new(commit.as_bytes().to_vec()))
            .is_ok_and(|record| record.is_some())
    }

    /// Marks `group_id` caught up, as a sweep or the live plane would.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn mark_caught_up_for_test(&self, group_id: &GroupId) {
        self.mark_caught_up(group_id);
    }

    /// Forgets that `group_id` is caught up, as a sweep of it that begins
    /// does.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn forget_caught_up_for_test(&self, group_id: &GroupId) {
        self.forget_caught_up(Some(group_id));
    }

    /// Waits until `group_id` is caught up in this session: on the marks
    /// themselves, never on a clock.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn until_caught_up_for_test(&self, group_id: &GroupId) {
        let mut marks = self.caught_up_marks.subscribe();
        while !self.caught_up_for_test(group_id) {
            if marks.changed().await.is_err() {
                return;
            }
        }
    }

    /// Whether `group_id` is caught up in this session.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn caught_up_for_test(&self, group_id: &GroupId) -> bool {
        self.caught_up
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(group_id)
    }

    /// [`Self::away_from_the_foreground`] and [`Self::bridge_may_commit`], as
    /// another caller in the process reads them now.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn foreground_reads_for_test(&self) -> (bool, bool) {
        (self.away_from_the_foreground(), self.bridge_may_commit())
    }

    /// Whether `group_id` holds received input the engine has not resolved.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn has_pending_inputs_for_test(&self, group_id: &GroupId) -> bool {
        let Ok(session) = self.engine().await else {
            return true;
        };
        !matches!(session.has_pending_convergence_inputs(group_id), Ok(false))
    }

    /// Whether this device's copy of `group_id` is recorded as removed.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn removed_for_test(&self, group_id: &GroupId) -> bool {
        self.removed(group_id).await
    }

    /// How many replacement offers MDK holds for `group_id`, as a test may
    /// read them ([`Self::rejoin_offers`]).
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn rejoin_offers_for_test(&self, group_id: &GroupId) -> Vec<RejoinOffer> {
        self.rejoin_offers(group_id).await
    }

    /// Whether the engine holds this device's leave proposal for `group_id`
    /// as minted ([`Self::leave_proposed`]).
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn leave_proposed_for_test(&self, group_id: &GroupId) -> bool {
        self.leave_proposed(group_id)
    }

    /// Whether the engine has ever minted this device's leave proposal for
    /// `group_id` (MDK's `LeaveRequest.last_proposed_epoch`). A store that
    /// cannot say reads as "it has": the leave's first instant stands.
    pub(crate) fn leave_proposed(&self, group_id: &GroupId) -> bool {
        use cgka_traits::storage::LeaveRequestStorage as _;
        self.message_store
            .leave_request(group_id)
            .map_or(true, |request| {
                request.is_some_and(|request| request.last_proposed_epoch.is_some())
            })
    }

    /// The epoch of this device's latest leave proposal for `group_id` the
    /// engine minted (MDK's `LeaveRequest.last_proposed_epoch`), or `None`
    /// for none, or a store that cannot say.
    pub(crate) fn leave_proposed_epoch(&self, group_id: &GroupId) -> Option<u64> {
        use cgka_traits::storage::LeaveRequestStorage as _;
        self.message_store
            .leave_request(group_id)
            .ok()
            .flatten()
            .and_then(|request| request.last_proposed_epoch)
            .map(|epoch| epoch.0)
    }

    /// Whether this device's copy of `group_id` is recorded as removed: a
    /// peer committed its leave, or an admin removed it.
    pub(crate) async fn removed(&self, group_id: &GroupId) -> bool {
        self.reading()
            .await
            .group_record(group_id)
            .is_ok_and(|group| group.removed)
    }

    /// Records `ids` as refused in `group_id` now, as an engine announcement
    /// would.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn record_refused_for_test(&self, group_id: &GroupId, ids: &[nostr::EventId]) {
        let _ = self
            .refused_ledger
            .record(group_id, ids, self.ledger_now_secs());
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
        let _session = self.reading().await;
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
        let _session = self.reading().await;
        scan_group_inputs(
            &self.message_store,
            group_id,
            now_secs,
            ScanMode::RetireUnresolvable,
        )
        .map_err(map_storage_err)
    }

    /// Whether the engine's own send gate is closed for `group_id`: it holds
    /// convergence input still to resolve (`has_pending_convergence_inputs`,
    /// v0.10.4 `cgka-session/src/lib.rs:1082`). A store that cannot say reads
    /// as open — the fail-safe direction for its readers: a wrong "open"
    /// costs one more deferral at the next tick, a wrong "gated" would park a
    /// working circle behind a repair banner.
    pub async fn send_gated(&self, group_id: &GroupId) -> bool {
        matches!(
            self.reading()
                .await
                .has_pending_convergence_inputs(group_id),
            Ok(true)
        )
    }

    /// How many stored inputs still gate outbound sends for a group, WITHOUT
    /// writing anything: zero exactly when the engine's own send gate is open.
    ///
    /// The honest way to answer "will the next send encrypt?" after something
    /// else has already changed the state — running a second full sweep to find
    /// out would silently retire rows and report the count of a pass nobody
    /// asked for.
    ///
    /// # Errors
    ///
    /// Returns an error if the engine or the message store cannot be read.
    // The message store is read only under the session lock (see `message_store`).
    #[allow(clippy::significant_drop_tightening)]
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn gating_input_count(&self, group_id: &GroupId) -> Result<usize> {
        let session = self.reading().await;
        // The engine's predicate decides (`has_pending_convergence_inputs`,
        // v0.10.4 `cgka-session/src/lib.rs:1082`); the scan only sizes it, and
        // cannot see a gating convergence pass, so a gate it finds no row for
        // still counts as one.
        if !session
            .has_pending_convergence_inputs(group_id)
            .map_err(map_mls_err)?
        {
            return Ok(0);
        }
        // `now_secs` is unused in `CountOnly` mode (nothing is aged out), so the
        // caller is not asked for a clock it would have no use for.
        scan_group_inputs(&self.message_store, group_id, 0, ScanMode::CountOnly)
            .map(|scan| scan.gating_rows.max(1))
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
        let _session = self.reading().await;
        pending_proposal_in_window(&self.message_store, group_id).map_err(map_storage_err)
    }

    /// The `admin-policy.v1` encoding of `admins`, as
    /// [`Self::update_admin_policy`] would produce it.
    ///
    /// Test-only. Exposes the codec (which stays private) so a test can queue
    /// a real change of the circle's admins.
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
    /// reachable only by driving a send the gate refuses, which cannot be
    /// produced on demand in a circle whose state reads stable.
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
        self.queue_intent_for_test(
            group_id,
            SendIntent::UpdateAppComponents {
                group_id: group_id.clone(),
                updates: vec![AppComponentData {
                    component_id: GROUP_ADMIN_POLICY_COMPONENT_ID,
                    data,
                }],
            },
        )
        .await
    }

    /// Queues a removal of `member_pubkeys`, as the engine's own
    /// `queue_outbound_intent` would.
    ///
    /// Test-only: a removal the gate queued cannot be produced on demand in
    /// a circle whose state reads stable.
    ///
    /// # Errors
    ///
    /// Returns an error if no key parses or the message store cannot be
    /// written.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn queue_removal_intent_for_test(
        &self,
        group_id: &GroupId,
        member_pubkeys: &[String],
    ) -> Result<()> {
        self.queue_intent_for_test(group_id, Self::removal_intent(group_id, member_pubkeys)?)
            .await
    }

    #[cfg(any(test, feature = "test-utils"))]
    async fn queue_intent_for_test(&self, group_id: &GroupId, intent: SendIntent) -> Result<()> {
        use cgka_traits::storage::QueuedOutboundIntent;

        let _session = self.reading().await;
        let mut id = [0u8; 32];
        OsRng.fill_bytes(&mut id);
        self.message_store
            .put_queued_outbound_intent(&QueuedOutboundIntent {
                id: cgka_traits::types::MessageId::new(id.to_vec()),
                group_id: group_id.clone(),
                intent,
                created_at_ms: 0,
                reissue_attempts: 0,
            })
            .map_err(map_storage_err)
    }

    /// The admin-policy payload of every queued `UpdateAppComponents` intent for
    /// a group.
    ///
    /// Test-only. Lets a test show that a real change parked behind a gate
    /// survived, WITHOUT reading the engine's private queue shape.
    ///
    /// # Errors
    ///
    /// Returns an error if the message store cannot be read.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn queued_admin_policy_payloads_for_test(
        &self,
        group_id: &GroupId,
    ) -> Result<Vec<Vec<u8>>> {
        let _session = self.reading().await;
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
        let _session = self.reading().await;
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
        let _session = self.reading().await;
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

    /// How many stored convergence inputs this device holds for `group_id` whose
    /// source epoch is ABOVE its own tip: the engine's convergence buffer,
    /// counted.
    ///
    /// There is no per-group cap and no eviction API upstream (mdk#757), so the
    /// only honest instrument is a count a harness can watch grow.
    /// [`Self::gating_input_count`] is not it: [`scan_group_inputs`] skips rows
    /// above the future horizon, so a buffered future-epoch row is provably
    /// invisible there.
    ///
    /// A `PeelDeferred` row is a raw transport row that never peeled: it is
    /// stored as raw transport, not openmls-wire, so [`gating_projection`]
    /// cannot read it and it is never counted here. The count therefore sees the
    /// `buffer_openmls_convergence_message` store alone, which is the #757
    /// buffer — the negative half of this seam's own test is what pins that.
    ///
    /// # Errors
    ///
    /// Returns an error if the message store cannot be read.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn convergence_buffer_len_for_test(&self, group_id: &GroupId) -> Result<usize> {
        let _session = self.reading().await;
        let tip = match self.message_store.get_group(group_id) {
            Ok(group) => group.epoch.0,
            // A missing group holds nothing; the gating scan reads it the same.
            Err(StorageError::NotFound) => return Ok(0),
            Err(e) => return Err(map_storage_err(e)),
        };
        Ok(self
            .message_store
            .list_messages(group_id, EpochId(0))
            .map_err(map_storage_err)?
            .into_iter()
            .filter(|record| {
                gating_projection(&record.payload).is_some_and(|(_, projection)| {
                    projection.source_epoch.is_some_and(|epoch| epoch > tip)
                })
            })
            .count())
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
    /// The record's `epoch` column is stamped with the message's own MLS source
    /// epoch, which is what MDK v0.10.4 stamps on a row it receives (pinned by
    /// `tests/test_utils_seams.rs`
    /// `the_probe_reports_the_branch_the_engine_discarded`).
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

        let _session = self.reading().await;
        let group = self
            .message_store
            .get_group(&source.group_id)
            .map_err(map_storage_err)?;

        let source_epoch = gating_projection(&source.payload)
            .and_then(|(_, projection)| projection.source_epoch)
            .map_or(group.epoch, EpochId);
        let decoded = StoredMessagePayload::decode(&source.payload)
            .map_err(|_| NostrError::StorageError("stored payload decode".to_string()))?;
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
        .map_err(|_| NostrError::StorageError("stored payload encode".to_string()))?;

        self.message_store
            .put_message(&MessageRecord {
                id: id.clone(),
                group_id: source.group_id.clone(),
                epoch: source_epoch,
                state,
                payload,
                deferred_peel: None,
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
        let _session = self.reading().await;
        match self.message_store.get_message(id) {
            Ok(record) => Ok(Some(StoredMessageProbe {
                epoch: record.epoch,
                state: record.state,
            })),
            Err(StorageError::NotFound) => Ok(None),
            Err(e) => Err(map_storage_err(e)),
        }
    }

    /// Every row of `group_id` the engine still means to try again, in arrival
    /// order: the `Created`, `Retryable` and `PeelDeferred` rows its replay
    /// lists (v0.10.4 `cgka-engine/src/message_processor/mod.rs` 3551-3559).
    ///
    /// # Errors
    ///
    /// Returns an error if the store cannot be read.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn held_rows_for_test(
        &self,
        group_id: &GroupId,
    ) -> Result<Vec<super::types::HeldRowProbe>> {
        use super::types::{HeldRowKind, HeldRowProbe};

        let _session = self.reading().await;
        Ok(self
            .message_store
            .list_messages_in_states(
                group_id,
                &[
                    MessageState::Created,
                    MessageState::Retryable,
                    MessageState::PeelDeferred,
                ],
                EpochId(0),
            )
            .map_err(map_storage_err)?
            .into_iter()
            .map(|record| HeldRowProbe {
                epoch: record.epoch,
                state: record.state,
                keeps: match StoredMessagePayload::decode(&record.payload) {
                    Ok(payload) if payload.as_raw_transport().is_some() => HeldRowKind::Unopened,
                    Ok(_) => gating_projection(&record.payload)
                        .map_or(HeldRowKind::Other, |(_, projection)| {
                            HeldRowKind::Opened(projection.kind)
                        }),
                    Err(_) => HeldRowKind::Other,
                },
            })
            .collect())
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
        let _session = self.reading().await;
        self.message_store
            .list_queued_outbound_intents(group_id)
            .map(|queued| queued.len())
            .map_err(map_storage_err)
    }

    /// Takes every queued change of `group_id` out of the engine's queue
    /// through MDK's own delete (`confirm_regenerated_queued_intent`).
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn take_back_queued_changes_for_test(&self, group_id: &GroupId) {
        if let Ok(mut session) = self.engine().await {
            for queued in queued_group_changes(&self.message_store, group_id) {
                let _ = session.confirm_regenerated_queued_intent(&QueuedIntentRef {
                    group_id: queued.group_id,
                    intent_id: queued.id,
                });
            }
        }
    }

    /// How many application outputs (decrypted `MessageReceived`, and
    /// `GroupJoined`) the engine still holds for redelivery at the next open.
    ///
    /// # Errors
    ///
    /// Returns an error if the store cannot be read.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn pending_application_output_count_for_test(&self) -> Result<usize> {
        let _session = self.reading().await;
        self.message_store
            .list_pending_application_events()
            .map(|events| events.len())
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
    pub async fn accept_welcome(&self, gift_wrap: &Event) -> Result<WelcomeAcceptance> {
        let msg = Self::event_to_transport_message(gift_wrap)?;
        let mut session = self.engine().await?;
        let before = (
            session.outbound_fanouts().unwrap_or_default(),
            session.transport_fanouts().unwrap_or_default(),
        );
        let accepted = Box::pin(session.ingest(msg)).await;
        if let Ok(ingest) = &accepted {
            self.note_effects(&session, ingest);
            for event in &ingest.effects.events {
                if let GroupEvent::GroupJoined { group_id, .. } = event {
                    self.drop_rows_of_replaced_copy(&session, group_id, &before.0, &before.1);
                    // A group joined anew starts at the epoch its Welcome
                    // names: a commit the pager held back for an earlier copy
                    // of it is one it will never take in. Cleared here, at
                    // the join itself, and never where a `GroupJoined` is
                    // read later: MDK announces a consented rejoin's in the
                    // NEXT batch, which can arrive after a hold the new copy
                    // took.
                    self.unread().pager.remove(group_id);
                }
            }
        }
        drop(session);
        // MDK answers every terminal Welcome failure — a missing KeyPackage
        // bundle, an invalid or wrongly addressed Welcome, a repeat — with
        // `Ignored`, not an error (v0.10.4 `message_processor/ingest.rs:282-341`),
        // and a Welcome that would replace a group this device still holds with
        // `RejoinConfirmationRequired`, which only explicit consent can act on
        // (`:293-315`; `group_lifecycle.rs:1172-1197`).
        // A repeat (`Duplicate`, MDK's `WelcomeAlreadyProcessed`) of a Welcome
        // whose join this device still holds is an accept whose circle rows
        // never committed: the join's transport record names the group
        // (`ingest.rs:283-285` writes it under the Welcome's id).
        match accepted {
            Ok(ingest) => Ok(match ingest.outcome {
                IngestOutcome::Ignored {
                    category: cgka_traits::ingest::InputRejectionCategory::Duplicate,
                } => match self.live_group_joined_by(&gift_wrap.id).await {
                    Some(group_id) => WelcomeAcceptance::AlreadyJoined {
                        group_id,
                        effects: ingest.effects,
                    },
                    None => WelcomeAcceptance::NeedsNewInvite,
                },
                IngestOutcome::Ignored { .. } => WelcomeAcceptance::NeedsNewInvite,
                IngestOutcome::LocalState {
                    state: LocalIngestState::RejoinConfirmationRequired,
                } => WelcomeAcceptance::RejoinConfirmationRequired,
                _ => WelcomeAcceptance::Ingested(ingest),
            }),
            Err(e) => Err(map_mls_err(e)),
        }
    }

    /// Deletes the records `group_id` held before this device joined it
    /// again: MDK's replacement join clears the discarded copy's live
    /// `OpenMLS` state and keeps its records (`cgka-engine/src/engine.rs`
    /// 2402-2423), and what they would send — a commit, a proposal, a
    /// Welcome — belongs to a branch the circle no longer has (Security
    /// Rule 3). Only rows listed before the join, in the same hold: none the
    /// join or anything after it wrote. A delete that fails leaves its row
    /// to the dead-group end and the drive's own checks.
    fn drop_rows_of_replaced_copy(
        &self,
        session: &AccountDeviceSession,
        group_id: &GroupId,
        outbound: &[OutboundFanout],
        welcomes: &[cgka_traits::maintenance::DurableTransportFanout],
    ) {
        for row in outbound
            .iter()
            .filter(|row| row.group_id() == Some(group_id))
        {
            if session.delete_outbound_fanout(row.message_id()).is_ok() {
                self.forget_undone_welcome_routes(row);
                crate::relay::fanout::release(row.message_id());
            }
        }
        let mut ended = false;
        for record in welcomes
            .iter()
            .filter(|record| record.group_id.as_ref() == Some(group_id))
        {
            ended |= session.delete_transport_fanout(&record.id).is_ok();
        }
        if ended {
            self.commit_notes.clear(group_id, ChangeNote::WelcomeOwed);
        }
    }

    /// The replacement Welcomes MDK holds for `group_id` awaiting the user's
    /// consent (`AccountDeviceSession::pending_group_rejoins_for`), each with
    /// the token of the local branch the consent would discard; none when the
    /// store cannot say.
    pub(crate) async fn rejoin_offers(&self, group_id: &GroupId) -> Vec<RejoinOffer> {
        self.reading()
            .await
            .pending_group_rejoins_for(group_id)
            .unwrap_or_default()
            .into_iter()
            .filter_map(|pending| {
                let rejoin = pending.rejoin?;
                Some(RejoinOffer {
                    welcome_id: pending.message_id,
                    group_id: pending.group_id,
                    welcomer: rejoin.welcomer,
                    local_state_token: rejoin.local_state_token,
                })
            })
            .collect()
    }

    /// Confirms the replacement Welcome `offer` with the token the user saw
    /// (`AccountDeviceSession::confirm_group_rejoin`, which re-checks it in
    /// the replacement's own transaction), and in the same hold deletes the
    /// records the discarded copy held ([`Self::drop_rows_of_replaced_copy`]).
    /// MDK's stale-token answer is told by its static fields alone, never its
    /// reason (Security Rule 8).
    ///
    /// # Errors
    ///
    /// Any other engine error, redacted.
    pub(crate) async fn confirm_rejoin(
        &self,
        offer: &RejoinOffer,
        token: &[u8],
    ) -> Result<RejoinConfirmation> {
        let mut session = self.engine().await?;
        let before = (
            session.outbound_fanouts().unwrap_or_default(),
            session.transport_fanouts().unwrap_or_default(),
        );
        let confirmed = Box::pin(session.confirm_group_rejoin(&offer.welcome_id, token)).await;
        let answer = match confirmed {
            Ok(group_id) => {
                self.drop_rows_of_replaced_copy(&session, &group_id, &before.0, &before.1);
                // What the pager held back belonged to the discarded copy.
                self.unread().pager.remove(&group_id);
                Ok(RejoinConfirmation::Joined)
            }
            Err(SessionError::Engine(EngineError::InvalidTransition(transition)))
                if transition.from == "ActiveMember" && transition.to == "JoinWelcome" =>
            {
                Ok(RejoinConfirmation::Stale)
            }
            Err(SessionError::Engine(EngineError::InvalidWelcome)) => Ok(RejoinConfirmation::Gone),
            Err(e) => Err(map_mls_err(e)),
        };
        drop(session);
        answer
    }

    /// Declines the replacement Welcome `welcome_id`
    /// (`AccountDeviceSession::decline_group_rejoin`): redelivery cannot open
    /// it again.
    ///
    /// # Errors
    ///
    /// The engine's error, redacted.
    pub(crate) async fn decline_rejoin(&self, welcome_id: &MessageId) -> Result<()> {
        self.engine()
            .await?
            .decline_group_rejoin(welcome_id)
            .map_err(map_mls_err)
    }

    /// Whether MDK holds a leave request of this device's for `group_id`; a
    /// store that cannot say reads as one.
    pub(crate) fn leave_requested(&self, group_id: &GroupId) -> bool {
        use cgka_traits::storage::LeaveRequestStorage as _;
        self.message_store
            .leave_request(group_id)
            .map_or(true, |request| request.is_some())
    }

    /// The group a processed Welcome joined, if this device still holds it
    /// live — not removed, unrecoverable or disbanded.
    async fn live_group_joined_by(&self, gift_wrap_id: &nostr::EventId) -> Option<GroupId> {
        let message_id = MessageId::new(gift_wrap_id.to_bytes().to_vec());
        let group_id = {
            let _session = self.reading().await;
            self.message_store.get_message(&message_id).ok()?.group_id
        };
        self.group_is_live(&group_id).await.then_some(group_id)
    }

    /// Whether this device holds `group_id` as a live member.
    pub async fn group_is_live(&self, group_id: &GroupId) -> bool {
        self.find_group(group_id)
            .await
            .ok()
            .flatten()
            .is_some_and(|group| {
                !group.removed && !group.unrecoverable && group.disbanded.is_none()
            })
    }

    // ── KeyPackages ──────────────────────────────────────────────────────────

    /// Mints a `KeyPackage` outside the lifecycle record: a fixture for tests
    /// that need raw package bytes. The product mints through
    /// [`Self::stage_key_package`].
    ///
    /// # Errors
    ///
    /// Returns an error if generation fails.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn fresh_key_package(&self) -> Result<KeyPackage> {
        self.engine()
            .await?
            .fresh_key_package()
            .await
            .map_err(map_mls_err)
    }

    /// Deletes a [`Self::fresh_key_package`] fixture's bundle through MDK's
    /// own delete, which refuses a package whose lifetime has ended.
    ///
    /// # Errors
    ///
    /// Returns an error if deletion fails.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn delete_key_package(&self, key_package: &KeyPackage) -> Result<()> {
        self.engine()
            .await?
            .delete_key_package(key_package)
            .await
            .map_err(map_mls_err)
    }

    /// Admits one `KeyPackage` maintenance tick at a time; a tick holds the
    /// guard from its expiry sweep to its promotion.
    ///
    /// Two ticks that overlap each read the record before the other stages.
    /// Both then mint, MDK moves the first staged package into its retained
    /// list (`cgka-engine/src/maintenance.rs:58-70`), and the promotion of
    /// the second deletes the first's private material while a relay goes on
    /// serving it: a package peers can select and this device cannot open.
    /// Always taken before the session lock, never while holding it.
    pub async fn key_package_tick(&self) -> tokio::sync::MutexGuard<'_, ()> {
        self.key_package_tick.lock().await
    }

    /// Whether a maintenance tick holds [`Self::key_package_tick`] right now.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn key_package_tick_held_for_test(&self) -> bool {
        self.key_package_tick.try_lock().is_err()
    }

    /// The `KeyPackage` this device tracks, read from MDK's durable lifecycle
    /// record, or `None` before any slot is known.
    ///
    /// # Errors
    ///
    /// Returns an error if the record cannot be read.
    pub async fn tracked_key_package(&self) -> Result<Option<TrackedKeyPackage>> {
        let session = self.reading().await;
        let Some(state) = session.key_package_lifecycle().map_err(map_mls_err)? else {
            return Ok(None);
        };
        // The engine writes a slotless record when a Welcome is joined before
        // any package was tracked (`cgka-engine/src/group_lifecycle.rs:1463-1470`).
        if state.stable_slot_id.is_empty() {
            return Ok(None);
        }
        let package = state
            .current_key_package
            .as_ref()
            .map(|package| package.bytes().to_vec())
            .unwrap_or_default();
        let consumed = state.current_key_package_ref.is_some()
            && state.current_key_package_ref == state.last_consumed_key_package_ref;
        let owned = session
            .durably_owned_key_packages()
            .map_err(map_mls_err)?
            .iter()
            .any(|owned| owned.bytes() == package);
        drop(session);
        Ok(Some(TrackedKeyPackage {
            adopted: state.authored_event_id.is_none() && package.is_empty(),
            created_at: state.authored_event_created_at.map(|at| at.0),
            published: state.authored_signed_event.as_ref().and_then(frozen_event),
            pending: state
                .pending_replacement
                .as_ref()
                .and_then(|pending| pending.signed_event.as_ref())
                .and_then(frozen_event),
            replacement_owed: !package.is_empty() && (consumed || !owned),
            consumed_but_held: !package.is_empty() && consumed && owned,
            package,
            slot: state.stable_slot_id,
        }))
    }

    /// Records a slot adopted from the relays: nothing is minted, and the next
    /// event in it must be stamped after `created_at`.
    ///
    /// # Errors
    ///
    /// Returns an error if the record cannot be written.
    pub async fn adopt_key_package_slot(&self, slot: &str, created_at: u64) -> Result<()> {
        let session = self.reading().await;
        let mut state = session
            .key_package_lifecycle()
            .map_err(map_mls_err)?
            .unwrap_or_else(|| KeyPackageLifecycleState::slot_only(String::new()));
        slot.clone_into(&mut state.stable_slot_id);
        state.authored_event_created_at = Some(cgka_traits::transport::Timestamp(created_at));
        session
            .put_key_package_lifecycle(&state)
            .map_err(map_mls_err)
    }

    /// Mints a replacement `KeyPackage` into `slot` and freezes its signed
    /// kind-30443.
    ///
    /// MDK mints the private bundle and persists the replacement intent in one
    /// transaction (`stage_key_package_replacement`, v0.10.4
    /// `cgka-engine/src/maintenance.rs:47-94`), so a kill can never leave a
    /// bundle nothing tracks. `sign` is then handed the package's wire bytes
    /// and the `created_at` MDK recorded, and its event is stored as the
    /// replacement's `signed_event`: every publish of this package, the first
    /// and every retry, sends those exact bytes. A replacement a kill left
    /// unsigned is signed, not re-minted.
    ///
    /// # Errors
    ///
    /// Returns an error if minting, signing or the write fails.
    pub async fn stage_key_package(
        &self,
        slot: &str,
        created_at: u64,
        relays: &[String],
        sign: impl FnOnce(&KeyPackage, u64) -> Option<Event>,
    ) -> Result<(KeyPackage, Event)> {
        let mut session = self.engine().await?;
        let mut state = session
            .key_package_lifecycle()
            .map_err(map_mls_err)?
            .unwrap_or_else(|| KeyPackageLifecycleState::slot_only(String::new()));
        let unsigned = state.stable_slot_id == slot
            && state
                .pending_replacement
                .as_ref()
                .is_some_and(|pending| pending.signed_event.is_none());
        slot.clone_into(&mut state.stable_slot_id);
        if !unsigned {
            let targets = relays
                .iter()
                .map(|relay| TransportFanoutTarget {
                    endpoint: TransportEndpoint(relay.clone()),
                    state: TransportFanoutAttemptState::Unattempted,
                    attempt_count: 0,
                    last_attempt_at: None,
                    failure_code: None,
                })
                .collect();
            session
                .stage_key_package_replacement(
                    &mut state,
                    cgka_traits::transport::Timestamp(created_at),
                    KEY_PACKAGE_REFRESH_LEAD_SECS,
                    targets,
                )
                .map_err(map_mls_err)?;
        }
        let pending = state
            .pending_replacement
            .as_mut()
            .ok_or(NostrError::MdkError("key_package_not_staged"))?;
        let signing = || NostrError::InvalidEvent("key package event".to_owned());
        let event =
            sign(&pending.key_package, pending.authored_created_at.0).ok_or_else(signing)?;
        let frozen = NostrTransportEvent::from_nostr_event(&event).map_err(map_mls_err)?;
        pending.signed_event = Some(SignedPublicationArtifact {
            id: MessageId::new(event.id.to_bytes().to_vec()),
            created_at: pending.authored_created_at,
            bytes: serde_json::to_vec(&frozen).map_err(|_| signing())?,
        });
        let key_package = pending.key_package.clone();
        session
            .put_key_package_lifecycle(&state)
            .map_err(map_mls_err)?;
        drop(session);
        Ok((key_package, event))
    }

    /// Makes the staged replacement whose frozen event is `acked` the current
    /// package — call it only once a relay acknowledged that event — and
    /// deletes the private material of every package it supersedes.
    ///
    /// `foundation/key-packages.md:89-106`: a last-resort package's `init_key`
    /// is deleted at confirmed publication of a replacement, and "local
    /// retention policy MUST NOT extend" that. MDK's own runtime keeps the
    /// superseded material until `not_after`
    /// (`marmot-account/src/runtime.rs:1006-1023`) and its stage keeps a
    /// re-staged one (`cgka-engine/src/maintenance.rs:58-70`); Haven hands
    /// both to `promote_key_package_lifecycle` as retired
    /// (`docs/MDK_UPSTREAM_TRACKER.md` T-KP-RETENTION). A superseded package
    /// whose lifetime has already ended is deleted separately, because MDK's
    /// promotion aborts on one (T-KP-EXPIRED-DELETE).
    ///
    /// Returns whether a replacement was promoted: `false` when the staged
    /// replacement is no longer the one `acked` names.
    ///
    /// # Errors
    ///
    /// Returns an error if the promotion or a deletion fails; nothing is
    /// promoted then.
    pub async fn promote_key_package(&self, acked: &nostr::EventId) -> Result<bool> {
        let mut session = self.engine().await?;
        let Some(mut state) = session.key_package_lifecycle().map_err(map_mls_err)? else {
            return Ok(false);
        };
        let Some(replacement) = state.pending_replacement.take().filter(|pending| {
            pending
                .signed_event
                .as_ref()
                .is_some_and(|event| event.id.as_slice() == acked.as_bytes())
        }) else {
            return Ok(false);
        };

        let mut superseded = Vec::new();
        if let (Some(package), Some(key_package_ref)) = (
            state.current_key_package.take(),
            state.current_key_package_ref.take(),
        ) {
            superseded.push((package, key_package_ref));
        }
        superseded.extend(
            state
                .retained_private_material
                .drain(..)
                .map(|kept| (kept.key_package, kept.key_package_ref)),
        );
        let (retired, lapsed): (Vec<_>, Vec<_>) = superseded
            .into_iter()
            .partition(|(package, _)| cgka_engine::key_package_metadata(package).is_ok());
        let retired: Vec<KeyPackage> = retired.into_iter().map(|(package, _)| package).collect();

        state.current_key_package = Some(replacement.key_package);
        state.current_key_package_ref = Some(replacement.key_package_ref);
        state.current_not_before = Some(replacement.not_before);
        state.current_not_after = Some(replacement.not_after);
        state.authored_event_id = replacement.signed_event.as_ref().map(|e| e.id.clone());
        state.authored_event_created_at = Some(replacement.authored_created_at);
        state.authored_signed_event = replacement.signed_event;
        state.publication_targets = replacement.targets;
        state.refresh_at = Some(replacement.refresh_at);
        state.phase = MaintenancePhase::Complete;
        state.upgrade_rotation_recorded = true;
        state.generation_revision = replacement.generation_revision;
        // A Welcome may have consumed the replacement while its publish was
        // still unacknowledged; that one is still owed a replacement.
        if state.last_consumed_key_package_ref != state.current_key_package_ref {
            state.last_consumed_key_package_ref = None;
            state.last_consumed_at = None;
        }

        for (_, key_package_ref) in &lapsed {
            delete_key_package_bundle(&self.message_store, key_package_ref)
                .map_err(map_storage_err)?;
        }
        session
            .promote_key_package_lifecycle(&retired, &state)
            .map_err(map_mls_err)?;
        drop(session);
        Ok(true)
    }

    /// Records `event` — already acknowledged by a relay — as the current
    /// package's publication in `slot`: the same package, moved to another
    /// slot or found there.
    ///
    /// # Errors
    ///
    /// Returns an error if the record cannot be written.
    pub async fn repoint_key_package_slot(&self, slot: &str, event: &Event) -> Result<()> {
        let session = self.reading().await;
        let mut state = session
            .key_package_lifecycle()
            .map_err(map_mls_err)?
            .ok_or(NostrError::MdkError("key_package_not_tracked"))?;
        let frozen = NostrTransportEvent::from_nostr_event(event).map_err(map_mls_err)?;
        let created_at = cgka_traits::transport::Timestamp(event.created_at.as_secs());
        let id = MessageId::new(event.id.to_bytes().to_vec());
        slot.clone_into(&mut state.stable_slot_id);
        state.authored_event_id = Some(id.clone());
        state.authored_event_created_at = Some(created_at);
        state.authored_signed_event = Some(SignedPublicationArtifact {
            id,
            created_at,
            bytes: serde_json::to_vec(&frozen)
                .map_err(|_| NostrError::InvalidEvent("key package event".to_owned()))?,
        });
        session
            .put_key_package_lifecycle(&state)
            .map_err(map_mls_err)
    }

    /// Deletes the private material of every tracked `KeyPackage` whose
    /// `Lifetime.not_after` is at or before `now_secs` — the current package,
    /// a staged replacement, anything retained — and reports whether the
    /// current package was one of them.
    ///
    /// `foundation/key-packages.md:89-94`: the second, transport-independent
    /// deletion bound. The slot is kept, so the replacement reuses it. MDK's
    /// own delete validates the lifetime first and so refuses exactly these
    /// packages (`cgka-engine/src/key_package.rs:412-435,516-525`); they are
    /// deleted by reference instead (T-KP-EXPIRED-DELETE).
    ///
    /// The maintenance tick's sweep of what has expired, so it also ends the
    /// mesh keys of a deadline that has passed ([`Self::mesh_on_until`]).
    ///
    /// # Errors
    ///
    /// Returns an error if a deletion or the write fails; the record is left
    /// as it was, so the next call retries.
    pub async fn sweep_expired_key_packages(&self, now_secs: u64) -> Result<bool> {
        let session = self.reading().await;
        // The tick's other expiry: mesh keys whose deadline passed with no
        // engine batch to see it (Security Rule 5).
        self.sync_mesh_keys(&*session, &[], &[]);
        let Some(mut state) = session.key_package_lifecycle().map_err(map_mls_err)? else {
            return Ok(false);
        };
        let mut lapsed = Vec::new();
        let current_lapsed = state
            .current_not_after
            .is_some_and(|not_after| not_after.0 <= now_secs)
            && state.current_key_package.take().is_some();
        if current_lapsed {
            lapsed.extend(state.current_key_package_ref.take());
            state.current_not_before = None;
            state.current_not_after = None;
            state.authored_signed_event = None;
            state.publication_targets.clear();
            state.refresh_at = None;
            state.phase = MaintenancePhase::Retry;
        }
        if let Some(pending) = state
            .pending_replacement
            .take_if(|pending| pending.not_after.0 <= now_secs)
        {
            lapsed.push(pending.key_package_ref);
        }
        state.retained_private_material.retain(|kept| {
            let keep = kept.not_after.0 > now_secs;
            if !keep {
                lapsed.push(kept.key_package_ref.clone());
            }
            keep
        });
        if lapsed.is_empty() {
            return Ok(false);
        }
        for key_package_ref in &lapsed {
            delete_key_package_bundle(&self.message_store, key_package_ref)
                .map_err(map_storage_err)?;
        }
        session
            .put_key_package_lifecycle(&state)
            .map_err(map_mls_err)?;
        drop(session);
        Ok(current_lapsed)
    }

    /// Makes `package` the tracked current package in `slot`, published as
    /// `published` (or under an id no relay serves) at `created_at`.
    ///
    /// Test-only: the states a maintenance tick must repair — a slot of the
    /// pre-width-fix shape, a package whose bytes no longer read — are ones no
    /// current build writes, so a test plants them. The package's private
    /// bundle is whatever the store already holds for it.
    ///
    /// # Errors
    ///
    /// Returns an error if the record cannot be written.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn track_key_package_for_test(
        &self,
        slot: &str,
        package: &[u8],
        published: Option<&Event>,
        created_at: u64,
    ) -> Result<()> {
        let session = self.reading().await;
        let mut state = KeyPackageLifecycleState::slot_only(slot.to_owned());
        let key_package =
            KeyPackage::new(package.to_vec()).with_protocol_profile(ProtocolProfile::Current);
        if let Ok(meta) = cgka_engine::key_package_metadata(&key_package) {
            state.current_key_package_ref = hex::decode(&meta.key_package_ref_hex).ok();
            state.current_not_before = Some(cgka_traits::transport::Timestamp(meta.not_before));
            state.current_not_after = Some(cgka_traits::transport::Timestamp(meta.not_after));
        }
        state.current_key_package = Some(key_package);
        state.authored_event_id = Some(MessageId::new(
            published.map_or_else(|| vec![0; 32], |event| event.id.to_bytes().to_vec()),
        ));
        state.authored_event_created_at = Some(cgka_traits::transport::Timestamp(created_at));
        if let Some(event) = published {
            let frozen = NostrTransportEvent::from_nostr_event(event).map_err(map_mls_err)?;
            state.authored_signed_event = Some(SignedPublicationArtifact {
                id: MessageId::new(event.id.to_bytes().to_vec()),
                created_at: cgka_traits::transport::Timestamp(created_at),
                bytes: serde_json::to_vec(&frozen)
                    .map_err(|_| NostrError::InvalidEvent("key package event".to_owned()))?,
            });
        }
        session
            .put_key_package_lifecycle(&state)
            .map_err(map_mls_err)
    }

    /// How many `KeyPackage` private bundles the store holds, usable or not.
    ///
    /// Test-only: the one reading that sees a bundle MDK no longer reports
    /// because its lifetime ended. Compared in process, never rendered.
    ///
    /// # Errors
    ///
    /// Returns an error if the store cannot be read.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn key_package_bundle_count_for_test(&self) -> Result<usize> {
        let _session = self.reading().await;
        self.message_store
            .stored_key_package_bundles()
            .map(|bundles| bundles.len())
            .map_err(map_storage_err)
    }

    // ── Inspection ───────────────────────────────────────────────────────────

    /// The engine's record for a group (id, name, description, epoch, members,
    /// required capabilities, removed flag, join epoch).
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown.
    pub async fn group_record(&self, group_id: &GroupId) -> Result<Group> {
        self.reading()
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
        let record = self.reading().await.group_record(group_id);
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

    /// Re-attempts hydrating one quarantined group
    /// (`AccountDeviceSession::retry_hydrate_quarantined_group`): `true` when it
    /// is live again, `false` when it stays quarantined. Non-destructive.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is not quarantined.
    pub async fn retry_quarantined_group(&self, group_id: &GroupId) -> Result<bool> {
        let mut session = self.engine().await?;
        // A pending fanout row carries a ref the engine's counter has not
        // seen in this session — the group was not hydrated at the open —
        // and hydrating it now would restore that ref beside whatever the
        // counter has since handed out (`cgka-engine/src/epoch_manager.rs`
        // 196-204 inserts without looking). It stays quarantined until the
        // next open, which settles the row before any ref exists. So does
        // a circle with a rolled-back row: its commit may not be retired
        // yet, and the engine's own list, which is what retires one in a
        // live session, hides a quarantined group's rows — hence the
        // store's own list here, a read.
        let pending = self
            .message_store
            .list_outbound_fanouts()
            .map_err(map_storage_err)?
            .iter()
            .any(|row| {
                row.group_id() == Some(group_id)
                    && (row.pending_ref().is_some()
                        || row.mls_state() == FanoutMlsState::RolledBack)
            });
        if pending {
            return Ok(false);
        }
        session
            .retry_hydrate_quarantined_group(group_id)
            .map_err(map_mls_err)
    }

    /// The group's members.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown.
    pub async fn members(&self, group_id: &GroupId) -> Result<Vec<Member>> {
        self.reading().await.members(group_id).map_err(map_mls_err)
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
        self.reading()
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
        self.reading()
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
    /// "Quarantined" means *until a retry*, not for ever: entries are added
    /// only at session open and cleared by [`Self::retry_quarantined_group`]
    /// (the user's "Try again") or by the next open, which re-attempts
    /// hydration from scratch, so a transiently-bad group heals.
    ///
    /// The upstream `GroupHydrationQuarantineReason` is dropped: the one
    /// recovery surface offers the same non-destructive retry whatever the
    /// reason, and every other consumer needs only the identity of the groups
    /// it must skip.
    pub async fn quarantined_group_ids(&self) -> Vec<GroupId> {
        self.reading()
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
    /// * MDK's typed `epoch_state` must be `Stable`: `PendingPublish` and
    ///   `Merging` mean the roster is the engine's projection of a staged
    ///   commit, and `Recovering`, `Unrecoverable` and `Disbanded` mean no
    ///   roster is settled at all.
    /// * `has_pending_convergence_inputs` reports whether a stored
    ///   `Created`/`Retryable` message record inside the rewind window projects
    ///   to a commit or an application message. It FAILS OPEN — a row it cannot
    ///   decode or project is skipped, and an absent group reads `false` — so
    ///   `false` means "nothing resolvable is outstanding", never "clean slate".
    ///   That is why it is paired with the epoch state instead of trusted
    ///   alone.
    ///
    /// # Errors
    ///
    /// Returns an error for any engine failure other than an absent or
    /// quarantined group, both of which are [`ConvergedRoster::Absent`].
    pub async fn converged_member_pubkeys(&self, group_id: &GroupId) -> Result<ConvergedRoster> {
        let session = self.reading().await;
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
            .reading()
            .await
            .app_component(group_id, NOSTR_ROUTING_COMPONENT_ID)
            .map_err(map_mls_err)?
            .ok_or(NostrError::MdkError("group has no nostr routing component"))?;
        let routing = cgka_traits::app_components::decode_nostr_routing_v1(&raw)
            .map_err(|_| NostrError::MdkError("routing decode failed"))?;
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
            .reading()
            .await
            .app_component(group_id, GROUP_MESSAGE_RETENTION_COMPONENT_ID)
            .map_err(map_mls_err)?;
        let Some(bytes) = raw else { return Ok(None) };
        let encoded: [u8; 8] = bytes
            .as_slice()
            .try_into()
            .map_err(|_| NostrError::MdkError("message-retention component must be 8 bytes"))?;
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
            .reading()
            .await
            .exporter_secret(group_id, DEFAULT_EXPORTER_LABEL, 32)
            .is_ok())
    }

    /// Seals a kind-445 whose OUTER layer a co-member at this device's epoch can
    /// peel, but whose CLEARTEXT inner `PrivateMessage` header claims
    /// `inner_epoch`.
    ///
    /// This is the one wire shape that grows the engine's uncapped convergence
    /// buffer (mdk#757): decision 0.4(b)'s `member-future-header-flood` vector.
    /// It cannot be minted at a relay plane, which holds no group key — only a
    /// member does — so the sealing lives here, at the co-member's own session.
    ///
    /// It works in three genuine steps and one edit:
    /// 1. a real application message is sent, giving real inner MLS bytes sealed
    ///    at the current epoch (the side effect is one recorded send on THIS
    ///    device — the minting co-member, never the subject the arm grades);
    /// 2. that outer layer is peeled back to the inner bytes;
    /// 3. the cleartext epoch in the inner `PrivateMessage` header is overwritten
    ///    with `inner_epoch` — the field `ingest.rs` reads without decrypting;
    /// 4. the edited inner bytes are re-sealed under the SAME current-epoch key,
    ///    so a co-member at this epoch peels the result and reads the future
    ///    header.
    ///
    /// The inner ciphertext no longer authenticates at `inner_epoch`, which is
    /// exactly the point: a future-epoch application message is buffered on its
    /// header alone and never decrypted while it stays ahead of the tip.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown, the send is refused, or the
    /// engine cannot peel or re-seal.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn forge_future_header_445_for_test(
        &self,
        group_id: &GroupId,
        inner_epoch: u64,
    ) -> Result<Event> {
        self.forge_445_for_test(group_id, |inner| {
            overwrite_private_message_epoch(inner, inner_epoch)
        })
        .await
    }

    /// As [`Self::forge_future_header_445_for_test`], with the inner MLS bytes
    /// past the `PrivateMessage` header replaced by garbage: an outer layer a
    /// co-member peels, around an inner message no member can open.
    ///
    /// # Errors
    ///
    /// As [`Self::forge_future_header_445_for_test`].
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn forge_malformed_inner_445_for_test(&self, group_id: &GroupId) -> Result<Event> {
        self.forge_445_for_test(group_id, |inner| {
            let keep = inner.len().min(48);
            for byte in &mut inner[keep..] {
                *byte = 0x5a;
            }
            Ok(())
        })
        .await
    }

    /// `event`, a commit or proposal at `group_id`'s current epoch, wrapped
    /// again under a fresh ephemeral key and dated now: what a sender whose
    /// clock runs ahead of the committer's would have published.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is unknown or `event` does not peel at
    /// its current epoch.
    #[cfg(any(test, feature = "test-utils"))]
    pub async fn rewrap_handshake_for_test(
        &self,
        group_id: &GroupId,
        event: &Event,
    ) -> Result<Event> {
        let (nostr_group_id, _relays) = self.group_routing(group_id).await?;
        let ctx = {
            let (epoch, mut secret) = {
                let session = self.reading().await;
                session
                    .exporter_secret_with_epoch(group_id, DEFAULT_EXPORTER_LABEL, 32)
                    .map_err(map_mls_err)?
            };
            let mut secrets = HashMap::new();
            secrets.insert(
                DEFAULT_EXPORTER_LABEL.to_string(),
                std::mem::take(&mut *secret),
            );
            GroupContextSnapshot::new(epoch, secrets, Some(nostr_group_id.to_vec()))
        };
        let msg = Self::event_to_transport_message(event)?;
        let peeled = self
            .preview_peeler
            .peel_group_message(&msg, &ctx)
            .await
            .map_err(map_mls_err)?;
        let PeeledContent::MlsMessage { bytes } = peeled.content else {
            return Err(NostrError::MdkError(
                "outer layer did not peel to an inner MLS message",
            ));
        };
        let wrapped = self
            .preview_peeler
            .wrap_group_message_with_metadata(
                &EncryptedPayload {
                    ciphertext: bytes,
                    aad: Vec::new(),
                },
                &ctx,
                &GroupMessageMetadata::commit_or_proposal(),
            )
            .await
            .map_err(map_mls_err)?;
        Self::transport_message_to_event(&wrapped)
    }

    #[cfg(any(test, feature = "test-utils"))]
    async fn forge_445_for_test(
        &self,
        group_id: &GroupId,
        edit: impl FnOnce(&mut Vec<u8>) -> Result<()>,
    ) -> Result<Event> {
        let effects = self
            .send_location(group_id, "forge-future-header".to_string())
            .await?;
        let outer = effects
            .publish
            .into_iter()
            .find_map(|work| match work {
                PublishWork::ApplicationMessage { msg, .. } => Some(msg),
                _ => None,
            })
            .ok_or(NostrError::MdkError(
                "send produced no application message to reseal",
            ))?;

        let (nostr_group_id, _relays) = self.group_routing(group_id).await?;
        // The group's declared retention, read before the lock so no accessor is
        // called while it is held.
        let retention = self.group_message_retention_secs(group_id).await?;
        // The group key belongs in `ctx` only. Take it under the lock, drop the
        // lock, copy it into `ctx`, then drop the `Zeroizing` secret — all before
        // the two awaits below, rather than holding either to the end of the call
        // (Security Rule 9).
        let ctx = {
            let (epoch, secret) = {
                let session = self.reading().await;
                session
                    .exporter_secret_with_epoch(group_id, DEFAULT_EXPORTER_LABEL, 32)
                    .map_err(map_mls_err)?
            };
            let mut secrets = HashMap::new();
            secrets.insert(DEFAULT_EXPORTER_LABEL.to_string(), secret.to_vec());
            drop(secret);
            GroupContextSnapshot::new(epoch, secrets, Some(nostr_group_id.to_vec()))
        };

        let peeled = self
            .preview_peeler
            .peel_group_message(&outer, &ctx)
            .await
            .map_err(map_mls_err)?;
        let PeeledContent::MlsMessage { bytes } = peeled.content else {
            return Err(NostrError::MdkError(
                "outer layer did not peel to an inner MLS message",
            ));
        };
        let mut inner = bytes;
        edit(&mut inner)?;

        // Re-seal through the application-message metadata wrap Haven uses for a
        // real location, so the forged event carries the NIP-40 `expiration`
        // (= created_at + the group's 0x8005 window, bounded by the peeler) and
        // reads as an APPLICATION message on the wire — not, like a metadata-less
        // wrap, as a commit.
        let metadata = GroupMessageMetadata::application(Timestamp::now().as_secs(), retention);
        let wrapped = self
            .preview_peeler
            .wrap_group_message_with_metadata(
                &EncryptedPayload {
                    ciphertext: inner,
                    aad: Vec::new(),
                },
                &ctx,
                &metadata,
            )
            .await
            .map_err(map_mls_err)?;
        Self::transport_message_to_event(&wrapped)
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
                ..
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
            // `GroupStateRevalidated` restores notifications a branch
            // selection withdrew, so the circle refreshes exactly as for the
            // withdrawal. `GroupHydrationQuarantined` stays `None` — the group
            // is NOT live, so a resync would find nothing to catch up;
            // `CommitRolledBack` also stays `None` (its accompanying
            // `GroupStateInvalidated` drives the refresh).
            GroupEvent::GroupStateChanged { group_id, .. }
            | GroupEvent::EpochChanged { group_id, .. }
            | GroupEvent::PendingCommitRecovered { group_id, .. }
            | GroupEvent::GroupHydrationRecovered { group_id, .. }
            | GroupEvent::GroupStateRevalidated { group_id, .. } => {
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
            // Exhaustive on purpose: a variant a future MDK adds must be a
            // compile error here, never a silent `None`. A resource-refused
            // object is a receive-plane cursor/refetch concern
            // (`crate::relay::cursor`), not a location-visible one.
            GroupEvent::GroupCreated { .. }
            | GroupEvent::GroupHydrationQuarantined { .. }
            | GroupEvent::CommitRolledBack { .. }
            | GroupEvent::TransportObjectResourceRefused { .. } => None,
        }
    }
}

/// Maps a `storage-sqlite` failure into Haven's redacted storage-error bucket.
///
/// Generic over the error type for the same reason [`map_mls_err`] is: it is
/// used both as a `map_err` argument (by value) and on a formatted message.
#[allow(clippy::needless_pass_by_value)] // by value so it can be a `map_err` argument
pub fn map_storage_err(e: StorageError) -> NostrError {
    NostrError::StorageError(e.kind().to_string())
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

/// Overwrites the cleartext `epoch` of a serialized MLS `PrivateMessage` in
/// place.
///
/// `ingest.rs` reads a group message's epoch and content type off this cleartext
/// framing before it decrypts anything, so a co-member that seals the outer
/// layer at an epoch the receiver holds while writing a far-future epoch here
/// produces the one shape that grows the uncapped convergence buffer (mdk#757).
/// Reached only by [`SessionManager::forge_future_header_445_for_test`].
#[cfg(any(test, feature = "test-utils"))]
fn overwrite_private_message_epoch(bytes: &mut [u8], epoch: u64) -> Result<()> {
    // MLSMessage = version(u16) || wire_format(u16) || PrivateMessage, and a
    // PrivateMessage begins group_id<V> || epoch(u64) || content_type(u8).
    const GROUP_ID_AT: usize = 4;
    // `WireFormat::PrivateMessage = 2` (openmls framing/mod.rs). The seam only
    // ever hands us a peeled application message, but a wire whose format field
    // is anything else means the layout below does not hold — refuse rather than
    // edit bytes at the wrong offset.
    let wire_format = bytes
        .get(2..4)
        .map(|w| u16::from_be_bytes([w[0], w[1]]))
        .ok_or(NostrError::MdkError("MLS wire too short for its header"))?;
    if wire_format != 2 {
        return Err(NostrError::MdkError("MLS wire is not a PrivateMessage"));
    }
    let (group_id_len, header) = tls_vector_len(bytes, GROUP_ID_AT)
        .ok_or(NostrError::MdkError("MLS wire too short for its group id"))?;
    // At most 30 bits of length (the 8-byte form is refused), so the offset
    // arithmetic cannot overflow.
    let epoch_at = GROUP_ID_AT + header + group_id_len;
    bytes
        .get_mut(epoch_at..epoch_at + 8)
        .ok_or(NostrError::MdkError("MLS wire too short for its epoch"))?
        .copy_from_slice(&epoch.to_be_bytes());
    Ok(())
}

/// The value and header length of a TLS variable-length vector at `at`: the two
/// high bits of the first byte give the count of length bytes (1, 2, or 4).
///
/// The 8-byte form (prefix `0b11`) is refused: a group id never needs it, and
/// accepting it would read a 64-bit length out of a message this seam is
/// supposed to have peeled from a real group.
#[cfg(any(test, feature = "test-utils"))]
fn tls_vector_len(bytes: &[u8], at: usize) -> Option<(usize, usize)> {
    let first = *bytes.get(at)?;
    let header = 1usize << (first >> 6);
    if header > 4 {
        return None;
    }
    let mut len = usize::from(first & 0x3f);
    for offset in 1..header {
        len = (len << 8) | usize::from(*bytes.get(at.checked_add(offset)?)?);
    }
    Some((len, header))
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
    /// Count what gates. Writes nothing; `now_secs` is unused. A test's and
    /// the soak oracles' measure: no product decision reads the count.
    #[cfg(any(test, feature = "test-utils"))]
    CountOnly,
}

/// One group's pass over the stored convergence inputs.
///
/// The GATING count is `cgka_engine`'s per-row classifier
/// (`any_gating_convergence_input`, v0.10.4 `message_processor/mod.rs:1694`,
/// with `ConvergenceInputContext::gates_outbound`, `convergence_input.rs`): the
/// same `[tip - max_rewind, tip + max_rewind]` window and `Created`/`Retryable`
/// states; a commit always gates; an application message gates only while an
/// EARLIER source epoch holds two or more distinct commit edges, because
/// unresolved delivery alone does not make group state ambiguous. The engine's
/// non-row gates (an active convergence pass, a pending disband) are invisible
/// here, which is why [`SessionManager::gating_input_count`] asks the engine's
/// own predicate first.
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
    let rewind = max_rewind_commits();
    let anchor = EpochId(group.epoch.0.saturating_sub(rewind));
    let ceiling = group.epoch.0.saturating_add(rewind);
    let retiring = mode == ScanMode::RetireUnresolvable;

    let mut sweep = ConvergenceSweep::default();
    let mut commit_edges: BTreeMap<u64, BTreeSet<[u8; 32]>> = BTreeMap::new();
    let mut candidates: Vec<(OpenMlsContentKind, u64)> = Vec::new();
    for record in store.list_messages(group_id, anchor)? {
        // The engine builds its commit-edge context from every retained state
        // it classifies (`GATE_CLASSIFIER_STATES`), not only the gating ones.
        let classified = matches!(
            record.state,
            MessageState::Sent
                | MessageState::Created
                | MessageState::Retryable
                | MessageState::ConvergenceDeferred
                | MessageState::Processed
        );
        if !classified {
            continue;
        }
        let Some((created_at, projection)) = gating_projection(&record.payload) else {
            continue;
        };
        let may_gate = matches!(
            record.state,
            MessageState::Created | MessageState::Retryable
        );
        if retiring
            && may_gate
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
        let Some(source_epoch) = projection.source_epoch.filter(|epoch| *epoch <= ceiling) else {
            continue;
        };
        if projection.kind == OpenMlsContentKind::Commit {
            commit_edges
                .entry(source_epoch)
                .or_default()
                .insert(projection.message_digest);
        }
        if may_gate {
            candidates.push((projection.kind, source_epoch));
        }
    }
    sweep.gating_rows = candidates
        .into_iter()
        .filter(|(kind, source_epoch)| match kind {
            OpenMlsContentKind::Commit => true,
            OpenMlsContentKind::Application => commit_edges
                .range(..*source_epoch)
                .any(|(_, edges)| edges.len() > 1),
            _ => false,
        })
        .count();

    if !retiring {
        return Ok(sweep);
    }

    sweep.discarded_intents = discard_queued_location_intents(store, group_id)?;
    Ok(sweep)
}

/// How many stranded events one call hands back for a circle it may not
/// wait long for: each is an ingest of its own, made inside a call a plane
/// is waiting on.
pub const HAND_BACK_SLICE: usize = 16;

/// How many of its own circle's stranded events a call that makes commits
/// hands back before it answers held and leaves the rest to the next.
///
/// The engine takes back up to 2048 rows a circle it cannot open
/// (`cgka-engine/src/message_processor/mod.rs` 89) and whoever parked them
/// chose how many more there are, so a drain with no bound of its own would
/// hold the engine through the first seal for as long as an outsider liked.
pub const HAND_BACK_WHOLE: usize = 256;

/// A point in the hand-back of one stranded event at which a test ends it.
#[cfg(any(test, feature = "test-utils"))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HandBackStop {
    /// The event is kept in Haven's store; the engine's row still stands.
    Kept,
    /// The engine's row is released; the event has not been handed back.
    Released,
    /// The engine has answered; the entry has not been ended.
    Ingested,
}

/// A read or a write of a store that a test makes fail
/// (`SessionManager::fail_store_for_test`): each is one of the exits at
/// which a store that cannot say must be taken as holding.
#[cfg(any(test, feature = "test-utils"))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreFault {
    /// The engine's group row, read to learn whether anything will replay
    /// what is parked.
    Group,
    /// What Haven keeps of the circle's stranded input.
    Kept,
    /// The engine's rows still parked unopened.
    Rows,
    /// The write that keeps a row's event before the row is released.
    Keep,
    /// The write that owes a refused event its refetch.
    Ledger,
    /// The engine's rows, read for a departure nobody has committed.
    Departure,
    /// The engine's answer for a Welcome it owes, refused as it is while
    /// the Welcome's group is not live.
    SentWelcome,
    /// The records of this device's pending commits and queued changes,
    /// read for a save that may be already so.
    OwnCommit,
}

/// How the hand-back of one kept event went.
enum HandedBack {
    /// The engine judged the event or holds it again: Haven's part in it is
    /// over.
    Answered,
    /// The engine erred on it, or the copy is no longer the event its entry
    /// names: it is still Haven's.
    Unanswered,
    /// A test ended the hand-back here, as a process death would.
    #[cfg(any(test, feature = "test-utils"))]
    Died,
}

/// How one circle's share of a hand-back ended.
#[derive(Default)]
struct Drain {
    /// Something this call did not reach is left for the next.
    more: bool,
    /// Something the hand-back can still take is left — the call's room ran
    /// out, the cap stands, or a store refused a release: nothing new of
    /// its circle may go ahead of it.
    holds: bool,
    /// A test ended the hand-back, as a process death would.
    #[cfg(any(test, feature = "test-utils"))]
    died: bool,
}

impl Drain {
    /// Something stands, or may stand, that this call did not reach: its
    /// circle stays flagged and its call waits.
    const fn held() -> Self {
        Self {
            more: true,
            holds: true,
            #[cfg(any(test, feature = "test-utils"))]
            died: false,
        }
    }
}

/// One thing a circle is owed a hand-back of.
enum Owed<'a> {
    /// An event Haven already keeps.
    Kept(&'a KeptEvent),
    /// A row the engine still holds.
    Row(Box<(MessageRecord, cgka_traits::transport::TransportMessage)>),
}

/// What Haven keeps for one circle, against its cap.
struct Used {
    entries: usize,
    bytes: usize,
}

/// What became of a row Haven set out to take over.
enum TakenOver {
    /// Kept, and no row of the engine's stands beside it: Haven's to hand
    /// back.
    Event(Box<Event>),
    /// Nothing to hand back, for this look: a row that is not a verifiable
    /// event is left with the engine, and a kept copy that was no longer
    /// its event is gone.
    Left,
    /// No row more is taken over in this call. `holds` when the next call
    /// can take what is left — the cap stands (`cap`), or a store refused a
    /// write or could not be read — and not when the session has no store
    /// to keep anything in.
    Stopped { holds: bool, cap: bool },
    /// A test ended the hand-back here, as a process death would.
    #[cfg(any(test, feature = "test-utils"))]
    Died,
}

/// What looking for stranded input has cost: counted for tests, nothing in
/// a shipped build.
#[derive(Default)]
struct Examined(#[cfg(any(test, feature = "test-utils"))] std::sync::atomic::AtomicUsize);

impl Examined {
    #[cfg(any(test, feature = "test-utils"))]
    fn one(&self) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }

    #[cfg(not(any(test, feature = "test-utils")))]
    #[allow(clippy::unused_self)]
    const fn one(&self) {}
}

/// Whether the engine holds no commit of this device's own pending for
/// `group_id`, in a circle this device is still in and whose state is not
/// halted: the one state in which nothing will replay what is parked. `None`
/// when the store cannot say, which a caller reads as "it may".
///
/// Read from the OPEN engine. Nothing stored says it: hydrate restores a
/// pending commit only where a pending record and an attached commit both
/// exist (v0.10.4 `cgka-engine/src/engine.rs` 1894-1946). A circle still
/// pending replays its rows at its confirm or rollback; a halted one, or one
/// this device was removed from, at the join that repairs it.
fn replays_nothing(
    store: &SqliteAccountStorage,
    session: &AccountDeviceSession,
    group_id: &GroupId,
) -> Option<bool> {
    if !matches!(
        session.epoch_state(group_id),
        Some(EpochState::Stable { .. })
    ) {
        return Some(false);
    }
    match store.get_group(group_id) {
        Ok(group) => Some(!group.is_terminal() && !group.unrecoverable),
        Err(StorageError::NotFound) => Some(false),
        Err(_) => None,
    }
}

/// The event `record` keeps, when it is a group event exactly as it arrived,
/// awaiting a retry, with nothing of it opened: MDK's own test of a row
/// nobody opened (`cgka-engine/src/message_processor/store.rs` 560-561), in
/// the one state it writes such a row in. One decode, and no read.
fn unopened_event(record: &MessageRecord) -> Option<cgka_traits::transport::TransportMessage> {
    if record.state != MessageState::Retryable {
        return None;
    }
    StoredMessagePayload::decode(&record.payload)
        .ok()
        .and_then(|payload| payload.as_raw_transport().cloned())
        .filter(|message| matches!(message.envelope, TransportEnvelope::GroupMessage { .. }))
}

/// `record` with the event it keeps, when it is an [`unopened_event`] whose
/// transport id the engine does not hold as processed: it opened an event it
/// holds so, and a redelivery of it is a duplicate (`store.rs` 174-178).
/// Nothing is verified.
///
/// # Errors
///
/// Returns the store's error when it cannot say whether the id is processed.
fn stranded_row(
    store: &SqliteAccountStorage,
    record: MessageRecord,
    examined: &Examined,
) -> StorageResult<Option<(MessageRecord, cgka_traits::transport::TransportMessage)>> {
    let Some(message) = unopened_event(&record) else {
        return Ok(None);
    };
    examined.one();
    Ok((!store.has_processed_transport_id(&record.id)?).then_some((record, message)))
}

/// Up to `limit` of `group_id`'s stranded rows that Haven does not already
/// keep, in arrival order, and whether more stand beyond them.
///
/// MDK's replay alone reads these again (`message_processor/mod.rs`
/// 3544-3559), so in a circle that [`replays_nothing`] the unopened ones are
/// STRANDED, however they came to be there: a replay that did not run or did
/// not finish, a sweep or a replay that failed on the row (`mod.rs`
/// 2823-2827, 3700-3704), a replay the engine had no room for the row in
/// (`mod.rs` 3634-3655). The epoch column says nothing — it is the circle's
/// own when the event arrived.
///
/// Read with MDK's own streaming call, which filters by state in SQL, visits
/// in insert order and stops when told to
/// (`storage-sqlite/src/storage/messages.rs` 481-515): whoever parks rows
/// decides how many there are, and a call reads no more of them than it can
/// use. The visitor may not call back into the store, so whether the engine
/// has since opened a row is asked afterwards; rows it has are passed over,
/// and the visit is made again that much further when they stood in the way.
///
/// # Errors
///
/// Returns the store's error; a caller takes that as "rows may stand".
fn stranded_rows(
    store: &SqliteAccountStorage,
    group_id: &GroupId,
    kept: &[KeptEvent],
    limit: usize,
    examined: &Examined,
) -> StorageResult<(
    Vec<(MessageRecord, cgka_traits::transport::TransportMessage)>,
    bool,
)> {
    let mut wanted = limit.saturating_add(1);
    loop {
        examined.one();
        let mut read = Vec::new();
        store.visit_messages_in_states(
            group_id,
            &[MessageState::Retryable],
            EpochId(0),
            &mut |record| {
                if !kept.iter().any(|kept| kept.id == record.id) {
                    if let Some(message) = unopened_event(&record) {
                        read.push((record, message));
                    }
                }
                read.len() < wanted
            },
        )?;
        let cut_short = read.len() == wanted;
        let mut rows = Vec::with_capacity(read.len());
        for (record, message) in read {
            examined.one();
            if !store.has_processed_transport_id(&record.id)? {
                rows.push((record, message));
            }
        }
        if rows.len() > limit || !cut_short {
            let beyond = rows.len() > limit;
            rows.truncate(limit);
            return Ok((rows, beyond));
        }
        wanted = wanted.saturating_add(wanted - rows.len());
    }
}

/// Whether an event nobody opened reads, by its tags alone, as a commit or a
/// proposal: a `kind:445` carries a NIP-40 expiration exactly when it is an
/// application message (see `location::ttl`). Nothing about an unopened
/// event is authenticated, so this is what it claims, never what it is —
/// and it chooses the words of a note, never what is kept or handed back.
fn reads_as_change(event: &Event) -> bool {
    event.tags.expiration().is_none()
}

/// [`reads_as_change`] of a stored row's event, read from its tags as stored
/// and with nothing verified.
fn claims_change(message: &cgka_traits::transport::TransportMessage) -> bool {
    NostrTransportEvent::from_transport_message(message).map_or(true, |event| {
        !event
            .tags
            .iter()
            .any(|tag| tag.first().is_some_and(|name| name == "expiration"))
    })
}

/// Says, durably, what `group_id` holds stranded — and that it holds
/// nothing, when it does not — and returns whether something stands that
/// may still be taken over or handed back in this look.
///
/// Two notes, by what the event claims to be: a commit or proposal this
/// device has not applied ([`ChangeNote::UnreadChange`]), a location it was
/// not shown ([`ChangeNote::UnreadLocation`]). What stands is the engine's
/// stranded rows and what Haven took over of them and has not had an answer
/// for. Nothing is said of a circle that still holds a pending commit. A
/// circle whose store could not be read keeps its notes as they are and is
/// answered for as holding something: nobody could look.
///
/// No more rows are read than one past what the circle may have kept
/// ([`KEPT_EVENTS_PER_CIRCLE`]): anyone who knows a circle's routing tag can
/// park rows without number while a commit is pending. A note for a kind
/// first found beyond that is written when the hand-back has reached it.
fn tell_of_stranded(
    store: &SqliteAccountStorage,
    notes: &dyn CommitNotes,
    session: &AccountDeviceSession,
    group_id: &GroupId,
    tried: &HashSet<MessageId>,
    examined: &Examined,
) -> bool {
    match replays_nothing(store, session, group_id) {
        Some(true) => {}
        Some(false) => return false,
        None => return true,
    }
    let Some(kept) = notes.kept(group_id) else {
        return true;
    };
    let Ok((rows, _)) = stranded_rows(store, group_id, &kept, KEPT_EVENTS_PER_CIRCLE, examined)
    else {
        return true;
    };
    let mut unread = [false; 2];
    let mut takeable = false;
    for kept in &kept {
        takeable |= !tried.contains(&kept.id);
        unread[usize::from(!kept.change)] = true;
    }
    for (record, message) in &rows {
        takeable |= !tried.contains(&record.id);
        unread[usize::from(!claims_change(message))] = true;
    }
    let told = notes.peek(group_id);
    for (note, stands) in super::commit_notes::UNREAD.into_iter().zip(unread) {
        if stands == told.contains(&note) {
            continue;
        }
        if !stands {
            notes.clear(group_id, note);
        } else if notes.note(group_id, note) {
            log::warn!(
                "[Stranded] a circle holds input the engine left parked and will not read \
                 again by itself"
            );
        }
    }
    takeable
}

/// [`tell_of_stranded`] for every circle the store holds; the circles in
/// which something stands that may be taken over. What Haven kept for a
/// circle this device is no longer in, or that is gone, is destroyed here
/// with its notes: nothing could be handed back to it.
fn find_stranded(
    store: &SqliteAccountStorage,
    notes: &dyn CommitNotes,
    session: &AccountDeviceSession,
    tried: &HashSet<MessageId>,
    examined: &Examined,
) -> Vec<GroupId> {
    let mut stranded = store.list_groups().unwrap_or_default();
    stranded.retain(|group_id| {
        if store
            .get_group(group_id)
            .is_ok_and(|group| group.is_terminal())
        {
            notes.forget(group_id);
            for note in super::commit_notes::UNREAD {
                notes.clear(group_id, note);
            }
            return false;
        }
        tell_of_stranded(store, notes, session, group_id, tried, examined)
    });
    stranded
}

/// Marks this device's own commit `origin` `Failed` if it is still stored as
/// sent, so no convergence pass selects it (T-ROLLBACK-RESURRECT). That row
/// and no other: a second unresolved own commit of the same epoch may be one
/// a relay holds.
fn retire_commit(store: &SqliteAccountStorage, origin: &MessageId) -> StorageResult<()> {
    match store.get_message(origin) {
        Ok(record) if record.state == MessageState::Sent => {
            store.update_message_state(origin, MessageState::Failed)
        }
        Ok(_) | Err(StorageError::NotFound) => Ok(()),
        Err(e) => Err(e),
    }
}

/// How a test makes a plain rollback go wrong.
#[cfg_attr(not(any(test, feature = "test-utils")), allow(dead_code))]
#[derive(Clone, Copy)]
enum RollbackFault {
    /// The engine is not asked: nothing is rewound, and the call errors.
    Refused,
    /// The engine rewinds, and the call errors all the same.
    ErrorsAfterTheRewind,
    /// The engine rewinds, and the call never returns.
    ParksAfterTheRewind,
    /// The engine is not asked, and the call never returns.
    ParksBeforeTheRewind,
}

/// The one line for an eviction undone in the hold that staged it because its
/// circle is waiting out a refusal ([`SessionManager::restaging_held`]).
fn said_undone_inside_a_wait() {
    log::info!(
        "[Fanout] a commit the engine staged again while its circle waits out a refusal is \
         undone unsent"
    );
}

/// Says why a commit a staging hold found staged is undone in that hold:
/// its record could not be written, the hold's drive makes no commit, or a
/// refused eviction's wait is running.
fn say_undone_in_its_hold(unrecorded: Option<&NostrError>, mode: DriveMode) {
    match unrecorded {
        Some(e) => log::warn!(
            "[Fanout] a staged commit could not be recorded and is rolled back: {}",
            e.code()
        ),
        None if mode == DriveMode::FinishOnly => {
            log::info!(
                "[Fanout] a commit found staged by a drive that makes none is undone unsent"
            );
        }
        None => said_undone_inside_a_wait(),
    }
}

/// The own commits the open engine's hydrate cleared: in each circle it holds
/// no commit staged in, its own `Sent` commit rows from the epoch it is at
/// that no record names. Hydrate clears a commit with no record, and nothing
/// sends a commit without a record, so such a row never left the device; one
/// a record still names may be held by a relay, and stays. Owed their
/// retirement ([`SessionManager::finish_rollbacks`]). A store that cannot be
/// read names none, and the circle's next pass is what is risked.
fn cleared_at_open(
    store: &SqliteAccountStorage,
    session: &AccountDeviceSession,
) -> Option<Vec<MessageId>> {
    #[cfg(any(test, feature = "test-utils"))]
    if CLEARED_READ_FAULTS.with(|left| left.replace(left.get().saturating_sub(1)) > 0) {
        return None;
    }
    let records = session.outbound_fanouts().ok()?;
    let mut cleared = Vec::new();
    for group_id in store.list_groups().ok()? {
        if SessionManager::staged_ref_of(session, &group_id).is_some() {
            continue;
        }
        // A circle the engine no longer holds at an epoch has nothing a pass
        // could merge.
        let Ok(epoch) = session.epoch(&group_id) else {
            continue;
        };
        let group = store.get_group(&group_id).ok()?;
        for (origin, source, _) in own_sent_commits(store, &group).ok()? {
            if source == epoch.0
                && !cleared.contains(&origin)
                && !records.iter().any(|record| record.message_id() == &origin)
            {
                cleared.push(origin);
            }
        }
    }
    Some(cleared)
}

#[cfg(any(test, feature = "test-utils"))]
thread_local! {
    /// How many of this thread's next reads for the commits an open cleared
    /// fail ([`SessionManager::fail_cleared_reads_for_test`]).
    static CLEARED_READ_FAULTS: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

/// This device's own unresolved commits in `group`, oldest first, each with
/// the epoch it was staged from and its exact signed event: the `Sent` commit
/// rows from the epoch before the record's on. The record's epoch is the
/// commit's source epoch, or one past it when an eviction's staging already
/// projected it forward.
fn own_sent_commits(
    store: &SqliteAccountStorage,
    group: &Group,
) -> StorageResult<
    Vec<(
        MessageId,
        u64,
        Option<cgka_traits::transport::TransportMessage>,
    )>,
> {
    let floor = group.epoch.0.saturating_sub(1);
    let mut commits = Vec::new();
    for record in store.list_messages(&group.id, EpochId(floor))? {
        if record.state != MessageState::Sent {
            continue;
        }
        let Ok(payload) = StoredMessagePayload::decode(&record.payload) else {
            continue;
        };
        let source = payload
            .as_openmls_wire()
            .and_then(|wire| project_mls_message(&wire.payload).ok())
            .filter(|projection| projection.kind == OpenMlsContentKind::Commit)
            .and_then(|projection| projection.source_epoch);
        if let Some(source) = source.filter(|source| *source >= floor) {
            commits.push((record.id, source, payload.as_exact_transport().cloned()));
        }
    }
    Ok(commits)
}

/// Puts the stored fanouts in the one shape MDK's hydrate reads correctly,
/// and tells the relay layer which events are theirs, BEFORE the engine opens.
///
/// Hydrate restores a group's pending state from its FIRST `Pending` fanout
/// row around whatever commit it finds staged, checking only that the row's
/// origin message decodes (v0.10.4 `cgka-engine/src/engine.rs` 1894-1946). So
/// each group is left with at most one such row, and only the row of the
/// group's newest unresolved own commit, which is the only one a staged commit
/// can be:
///
/// * a `RolledBack` row is finished — its commit's row retired, then the row
///   deleted — before any convergence pass can select that commit;
/// * a `Pending` row whose commit is no longer stored as sent, or is not the
///   group's newest unresolved own commit, stops being pending: bound to a
///   later commit, its acknowledgement would confirm a commit no relay was
///   sent. One whose commit ended applied on this device is kept, confirmed,
///   for the relays it still owes; any other is deleted — a recorded
///   exposure with it, in the one case of a commit still stored as sent
///   behind a newer one, which no call can stage;
/// * a circle's one unresolved removal the user asked for that has NO row —
///   a process died between the engine's staging and the row's write, or the
///   commit was staged by a call that writes none — is given one. Without a
///   row hydrate leaves a removal attached with no pending ref (1962-1979),
///   where nothing can publish, confirm or discard it and the circle stops
///   working on this device; with one, hydrate restores it like any other
///   pending commit. The row is a trial — nothing here can see whether a
///   commit is attached — frozen for no relay;
///   [`settle_fanouts_after_open`] keeps it or takes it back. An eviction is
///   left as hydrate leaves it: attached, the circle stable, and healed by
///   another member's commit for the same departure. Any other commit
///   hydrate CLEARS while leaving its stored row as sent, and that row is a
///   convergence input: the circle's next pass applies the commit on this
///   device ALONE, with no relay's acknowledgement — after a relay change,
///   publishing to and reading from relays the other members may not use; in
///   a quiet circle, silently not sharing until somebody commits
///   (T-KILL-WINDOW, open until a foreground drive exists). The circle is
///   told it may be out of step when the engine announces the clear
///   (`SessionManager::note_batch`). A record would close that, and is
///   withheld until something the app calls drives stored records
///   ([`try_recordless_removals`]). A commit a process died inside the
///   staging of, before its sent row was written, shows nothing here and is
///   given none.
///
/// And a self-update the engine left staged with no row — a process died
/// between the engine's staging and the record's write — has its durable
/// evolution deleted ([`clear_unrecorded_self_updates`]), so hydrate clears
/// the commit like any recordless commit instead of restoring it under a
/// pending ref of its own. The circles whose cleared self-update was not the
/// user's repair are added to `unasked`: nobody asked for it, so nobody is
/// told it was undone.
fn settle_fanouts_before_open(
    store: &SqliteAccountStorage,
    own_identity: &[u8],
    notes: &dyn CommitNotes,
    notes_are_kept: bool,
    unasked: &mut HashSet<GroupId>,
) -> StorageResult<()> {
    // What cannot be said durably is not deleted: the row stays, the pass
    // fails, and the engine gate finishes it or holds the engine.
    let unnoted = || StorageError::Backend(UNNOTED.to_owned());
    let fanouts = store.list_outbound_fanouts()?;
    // First, and whatever fails below: no publish path may send these.
    for fanout in &fanouts {
        crate::relay::fanout::own(fanout.message_id());
    }
    let mut highest_ref = 0;
    let mut settled_groups: Vec<GroupId> = Vec::new();
    for fanout in &fanouts {
        match fanout.mls_state() {
            FanoutMlsState::RolledBack => {
                // As `SessionManager::finish_rolled_back_in`: said, durably,
                // before the row goes.
                if let Some(group_id) = fanout.group_id() {
                    if !notes.note(group_id, undone_note(notes, fanout)) {
                        return Err(unnoted());
                    }
                }
                if let Some(origin) = fanout.pending_origin_message_id() {
                    retire_commit(store, origin)?;
                }
                store.delete_outbound_fanout(fanout.message_id())?;
                crate::relay::fanout::release(fanout.message_id());
                log::info!("[Fanout] a rollback an earlier session began was finished at the open");
            }
            FanoutMlsState::Pending(pending) => {
                let Some(group_id) = fanout.group_id() else {
                    continue;
                };
                let newest = match store.get_group(group_id) {
                    Ok(group) => own_sent_commits(store, &group)?.pop().map(|(id, _, _)| id),
                    Err(StorageError::NotFound) => None,
                    Err(e) => return Err(e),
                };
                if newest.as_ref() == fanout.pending_origin_message_id() {
                    highest_ref = highest_ref.max(pending.as_u64());
                    settled_groups.push(group_id.clone());
                    continue;
                }
                let state = match fanout.pending_origin_message_id() {
                    Some(origin) => match store.get_message(origin) {
                        Ok(record) => Some(record.state),
                        Err(StorageError::NotFound) => None,
                        Err(e) => return Err(e),
                    },
                    None => None,
                };
                let applied = state == Some(MessageState::Processed);
                // As `SessionManager::settle_stale_row` says it: a commit a
                // relay may hold that ended for good without being applied.
                let ended_for_good = matches!(
                    state,
                    Some(MessageState::EpochInvalidated | MessageState::Failed)
                );
                if ended_for_good && !never_attempted(fanout) {
                    if !notes.note(group_id, ChangeNote::MayBeOutOfStep) {
                        return Err(unnoted());
                    }
                    log::warn!(
                        "[Fanout] a commit a relay may hold was set aside for good; its circle \
                         may be out of step"
                    );
                }
                if let Some(confirmed) = confirmed_copy(fanout).filter(|_| applied) {
                    store.put_outbound_fanout(&confirmed)?;
                    log::info!(
                        "[Fanout] a pending fanout whose commit was applied by another path \
                         was kept for its relays at the open"
                    );
                } else {
                    store.delete_outbound_fanout(fanout.message_id())?;
                    crate::relay::fanout::release(fanout.message_id());
                    log::warn!(
                        "[Fanout] a pending fanout that no longer describes its circle's \
                         staged commit was removed at the open"
                    );
                }
            }
            FanoutMlsState::Confirmed | FanoutMlsState::NotApplicable => {}
        }
    }

    clear_unrecorded_self_updates(store, notes, unasked)?;
    let repaired =
        try_recordless_removals(store, own_identity, &settled_groups, highest_ref, notes);
    // After the repair, and whatever became of it. After: a queued removal
    // whose commit has just been given its record is that commit's twin, not
    // a change that was dropped. Whatever: neither may keep the other from
    // running. And only where a note outlives the process: a change is never
    // deleted behind one that dies with it.
    let swept = if notes_are_kept {
        retire_queued_group_changes(store, notes)
    } else {
        Ok(())
    };
    repaired.and(swept)
}

/// Deletes each durable self-update evolution the engine holds that no
/// `Pending` fanout row records and that no relay could have confirmed:
/// Haven writes a commit's row in the hold that staged it, before any byte
/// can leave (Rule 13.1), so a self-update with no row never left the
/// device. Without this, hydrate restores it with a pending ref of its own
/// and hands it out to be published (`cgka-engine/src/engine.rs` 1970-1975,
/// 2183-2283) — a commit no record holds, beside a ref a later row may
/// carry. Deleted, the commit is cleared like any recordless one, and the
/// post-join obligation it was made for stays open, so a later full drive
/// makes a fresh one.
///
/// A repair's mark ([`CommitNotes::mark_repair`]) says whose it was: the
/// circle of one the user asked for is told it was undone
/// ([`ChangeNote::ChangeUndone`]) before the evolution goes; any other
/// circle goes into `unasked`, and the hydrate's announcement of the clear
/// is not told. A mark that cannot be read is taken as the user's, so
/// nothing they asked for is undone untold.
fn clear_unrecorded_self_updates(
    store: &SqliteAccountStorage,
    notes: &dyn CommitNotes,
    unasked: &mut HashSet<GroupId>,
) -> StorageResult<()> {
    let recorded: HashSet<MessageId> = store
        .list_outbound_fanouts()?
        .iter()
        .filter(|fanout| matches!(fanout.mls_state(), FanoutMlsState::Pending(_)))
        .filter_map(|fanout| fanout.pending_origin_message_id().cloned())
        .collect();
    for evolution in store.list_group_evolutions()? {
        let orphan = matches!(
            evolution.semantic,
            GroupEvolutionSemantic::SelfUpdate { .. }
        ) && !matches!(
            evolution.phase,
            GroupEvolutionPhase::Confirmed | GroupEvolutionPhase::SupersededByConvergence
        ) && evolution
            .signed_message_id
            .as_ref()
            .is_none_or(|signed| !recorded.contains(signed));
        if !orphan {
            continue;
        }
        // Told from what is stored, before the engine opens, as an undone
        // change of the user's always is (`try_recordless_removals`): a
        // process that ends before the hydrate's announcement is read has
        // told it all the same. What cannot be told is not deleted.
        if notes.repair_marked(&evolution.group_id) == Some(false) {
            unasked.insert(evolution.group_id.clone());
        } else if !notes.note(&evolution.group_id, ChangeNote::ChangeUndone) {
            return Err(StorageError::Backend(UNNOTED.to_owned()));
        }
        store.delete_group_evolution(&evolution.id)?;
        log::info!("[Fanout] a self-update left with no record was cleared at the open");
    }
    Ok(())
}

/// Why a finisher kept a row it was about to delete.
const UNNOTED: &str = "a change's outcome could not be recorded";

/// Whether a circle's stored convergence pass is the one the engine holds
/// its one-attempt reservation on: completed, with its fairness slot still
/// available. A read that failed is not that answer.
fn reservation_held<E>(
    pass: &std::result::Result<Option<cgka_traits::DurableConvergencePass>, E>,
) -> bool {
    matches!(
        pass,
        Ok(Some(pass)) if pass.phase == cgka_traits::ConvergencePassPhase::Completed
            && pass.fairness_slot_available
    )
}

/// Whether `intent` is a change of the group: the six kinds the engine
/// reserves a circle's next convergence pass for while one is queued, as
/// MDK's own `is_admin_group_state_intent` lists them
/// (`cgka-engine/src/message_processor/mod.rs` 3766-3776). Haven sends the
/// first three.
const fn changes_group(intent: &SendIntent) -> bool {
    matches!(
        intent,
        SendIntent::Invite { .. }
            | SendIntent::RemoveMembers { .. }
            | SendIntent::UpdateAppComponents { .. }
            | SendIntent::UpdateGroupData { .. }
            | SendIntent::EnableDisbanding { .. }
            | SendIntent::Disband { .. }
    )
}

/// `group_id`'s queued changes of the group, oldest first; none when the
/// queue cannot be read.
fn queued_group_changes(
    store: &SqliteAccountStorage,
    group_id: &GroupId,
) -> Vec<cgka_traits::storage::QueuedOutboundIntent> {
    let mut queue = store
        .list_queued_outbound_intents(group_id)
        .unwrap_or_default();
    queue.retain(|queued| changes_group(&queued.intent));
    queue
}

/// Retires every change of a group found queued when a session opens, each
/// circle told first ([`ChangeNote::QueuedChangeDropped`]; for a removal
/// [`ChangeNote::QueuedRemovalDropped`], with everybody it names kept
/// beside it); one whose circle cannot be told is kept, with everything
/// queued behind it, and one that could not be deleted is not said to have
/// been.
///
/// No roster can be read here — the engine is not open — so a removal is
/// said as one whoever it names, and the open reads it again as soon as the
/// engine can say who is listed ([`removal_unmade`]): a removal of nobody
/// still in the circle is then a change that could no longer be made, and
/// holds nothing.
///
/// Nothing the app calls leaves such a change queued on purpose: each entry
/// that can queue one reports it as not made and takes it back in the hold
/// that queued it (`SessionManager::take_back_queued`), and the entries that
/// would answer "queued" are called by nothing
/// (`no_product_path_leaves_a_group_change_queued`). One found here is what a
/// take-back the store refused, or a process that died between the engine's
/// queue write and the take-back, left behind an answer that said "not
/// made" — and left queued it holds its circle at its epoch on every plane
/// that does not make the engine's full advance, and is made, days later and
/// unasked, on one that does.
///
/// The copy of a change that IS being made — a commit of this device's under
/// a record carries the same intent — or that was made — a confirmed own
/// commit carries it — goes without a word: its confirm would retire it, or
/// has retired its twin (`SessionManager::retire_released_change`).
fn retire_queued_group_changes(
    store: &SqliteAccountStorage,
    notes: &dyn CommitNotes,
) -> StorageResult<()> {
    let recorded = store.list_outbound_fanouts()?;
    for group_id in store.list_groups()? {
        let mut being_made = Vec::new();
        for origin in recorded
            .iter()
            .filter(|row| row.group_id() == Some(&group_id))
            .filter_map(OutboundFanout::pending_origin_message_id)
        {
            being_made.extend(store.own_commit_intent(origin)?.map(|own| own.intent));
        }
        // And the copy of a change already made — a confirmed commit's
        // intent is kept through the rewind horizon (`own_commit_intent.rs`
        // 345-369) — but never of a removal: one asked again for a member
        // invited back since is a new removal, and a removal whose members
        // are all gone takes its note back at the open by itself
        // ([`removal_unmade`]).
        for own in store.list_own_commit_intents(Some(&group_id))? {
            if !matches!(own.intent, SendIntent::RemoveMembers { .. })
                && matches!(
                    store.get_message(&own.commit_id).map(|stored| stored.state),
                    Ok(MessageState::Processed)
                )
            {
                being_made.push(own.intent);
            }
        }
        let set_aside_epoch = store.get_group(&group_id)?.epoch.0;
        for queued in queued_group_changes(store, &group_id) {
            let told = !being_made.contains(&queued.intent);
            let named: &[MemberId] = match &queued.intent {
                SendIntent::RemoveMembers { members, .. } => members,
                _ => &[],
            };
            let dropped = if named.is_empty() {
                ChangeNote::QueuedChangeDropped
            } else {
                ChangeNote::QueuedRemovalDropped
            };
            // Unreadable is "may have stood": one bit per circle cannot say
            // afterwards which open wrote it.
            let told_before = notes.stands(&group_id, dropped) != Some(false);
            if told
                && ((!named.is_empty()
                    && !notes.keep_removal_targets(
                        &group_id,
                        named,
                        set_aside_epoch,
                        asks_spent(&queued),
                    ))
                    || !notes.note(&group_id, dropped))
            {
                break;
            }
            if let Err(e) = store.delete_queued_outbound_intent(&queued.id) {
                // Still queued, so not dropped: the note written ahead of the
                // retirement is taken back unless an earlier one stands.
                if told && !told_before {
                    notes.clear(&group_id, dropped);
                }
                return Err(e);
            }
            // A retired invite stages no Welcome: the routes kept for it go.
            if let SendIntent::Invite { key_packages, .. } = &queued.intent {
                for package in key_packages {
                    if let Ok(metadata) = cgka_engine::key_package_metadata(package) {
                        notes.forget_welcome_route(&group_id, &metadata.credential_identity_hex);
                    }
                }
            }
        }
    }
    Ok(())
}

/// Whether a removal set aside unmade is asked for again by a full drive on
/// its own (decision 180).
///
/// "Offered" (decision 233): no drive asks, the note and the hold stand
/// until the user acts on the W14 screen, and that screen's "remove again"
/// calls the driver's `remove_members` for the members still listed. The
/// owner may still choose automatic (`OWNER_ITEMS` 179).
pub const REQUEUE_SET_ASIDE_REMOVALS: bool = false;

/// How often each member of a removal set aside unmade is asked for again.
///
/// Haven's own bound, the same number as MDK's on re-issuing a withdrawn
/// change (`MAX_OWN_COMMIT_REISSUE_ATTEMPTS`, held equal by a test).
pub const MAX_REQUEUE_ATTEMPTS: u32 = 2;

/// A change MDK queued again in a circle being left, taken back in this
/// hold through MDK's own delete: the one queued id not in `before`.
/// `Queued` when there is not exactly one, or it could not be taken back.
fn taken_back_for_leave(
    store: &SqliteAccountStorage,
    session: &mut AccountDeviceSession,
    group_id: &GroupId,
    before: &[MessageId],
) -> WithdrawnOutcome {
    let requeued: Vec<QueuedIntentRef> = queued_group_changes(store, group_id)
        .into_iter()
        .filter(|queued| !before.contains(&queued.id))
        .map(|queued| QueuedIntentRef {
            group_id: queued.group_id,
            intent_id: queued.id,
        })
        .collect();
    match requeued.as_slice() {
        [one] if session.confirm_regenerated_queued_intent(one).is_ok() => {
            WithdrawnOutcome::RetiredForLeave
        }
        _ => WithdrawnOutcome::Queued,
    }
}

/// The circles in which one convergence pass of `events` accepted more than
/// one commit (decision 227).
///
/// Such a pass names no origin commit and announces only the NET membership
/// change of its tips (`cgka-engine/src/distributed_convergence.rs`
/// 1845-1895, 2380-2385), so a member removed and invited back inside it is
/// never announced as removed. MDK announces a pass as `EpochChanged` from
/// the tip before it to the tip it selected (1759-1765), followed by a
/// `GroupStateInvalidated` for each commit it set aside: the commits it
/// accepted number at least the epochs it moved plus the commits it rewound.
/// That over-counts a rival it set aside without this device ever applying
/// it — which errs toward spending an ask.
fn passes_of_several_commits(events: &[GroupEvent]) -> Vec<GroupId> {
    let mut passes: Vec<(GroupId, u64)> = Vec::new();
    for event in events {
        match event {
            GroupEvent::EpochChanged { group_id, from, to } => {
                passes.push((group_id.clone(), to.0.saturating_sub(from.0)));
            }
            GroupEvent::GroupStateInvalidated { group_id, .. } => {
                match passes.iter_mut().rev().find(|(group, _)| group == group_id) {
                    Some((_, accepted)) => *accepted += 1,
                    None => passes.push((group_id.clone(), 1)),
                }
            }
            _ => {}
        }
    }
    let mut several: Vec<GroupId> = Vec::new();
    for (group_id, accepted) in passes {
        if accepted >= 2 && !several.contains(&group_id) {
            several.push(group_id);
        }
    }
    several
}

/// Where the engine stands on Welcome `id`.
enum WelcomeStanding {
    /// Owed a delivery: its exact bytes.
    Owed(cgka_traits::transport::TransportMessage),
    /// Delivered: the engine no longer owes it.
    Done,
    /// Never deliverable as it is stored: no longer an outbound row (failed,
    /// or any state but `Sent`), or still as its invite's staging wrote it
    /// under an applied commit — a payload MDK refuses to deliver for good
    /// (`cgka-engine/src/engine.rs` 3071-3101).
    Undeliverable,
    /// Not known now: the store did not answer, or the engine refused for a
    /// reason that can pass (its group not live or not hydrated, `:3076`).
    Unknown,
}

/// Reads where the engine stands on Welcome `id`, telling MDK's refusals
/// apart by the stored row, never by the error's text.
fn welcome_standing(
    store: &SqliteAccountStorage,
    session: &AccountDeviceSession,
    id: &MessageId,
    engine_answers: bool,
) -> WelcomeStanding {
    use cgka_traits::storage::MessageStorage as _;
    if let Some(Ok((_, welcome))) = engine_answers.then(|| session.stored_sent_welcome(id)) {
        return WelcomeStanding::Owed(welcome);
    }
    match store.get_message(id) {
        Ok(row) if row.state == MessageState::Processed => WelcomeStanding::Done,
        Ok(row) if row.state != MessageState::Sent => WelcomeStanding::Undeliverable,
        Ok(row)
            if StoredMessagePayload::decode(&row.payload)
                .is_ok_and(|payload| payload.as_staged_invite_welcome().is_some()) =>
        {
            WelcomeStanding::Undeliverable
        }
        _ => WelcomeStanding::Unknown,
    }
}

/// Whether `record`'s Welcome is still wanted: this device's copy of its
/// circle is neither removed nor disbanded, and its invitee is on the
/// roster. `None` when that cannot be told now — the engine cannot say, or
/// the circle holds a commit of its own unpublished, whose roster is only
/// what that commit would make it.
fn welcome_still_wanted(
    session: &AccountDeviceSession,
    record: &cgka_traits::maintenance::DurableTransportFanout,
) -> Option<bool> {
    let group_id = record.group_id.as_ref()?;
    let group = match session.group_record(group_id) {
        Ok(group) => group,
        Err(SessionError::Engine(EngineError::Storage(
            cgka_traits::storage::StorageError::NotFound,
        ))) => return Some(false),
        Err(_) => return None,
    };
    if group.is_terminal() {
        return Some(false);
    }
    if matches!(
        session.epoch_state(group_id),
        Some(EpochState::PendingPublish(_))
    ) {
        return None;
    }
    let TransportPublishTarget::Inbox { recipient, .. } = &record.target else {
        return Some(true);
    };
    Some(group.members.iter().any(|member| &member.id == recipient))
}

/// The circles holding fetched input not yet taken in
/// ([`SessionManager::holds_unread_input`]).
#[derive(Default)]
struct UnreadInput {
    /// The commits the pager held back for each, by event id, until an
    /// ingest on any plane takes each in or the engine's record shows one
    /// already did.
    pager: HashMap<GroupId, HashSet<Vec<u8>>>,
    /// How many live REQs hold stored replay for each.
    live: HashMap<GroupId, usize>,
}

/// The invitee a gift-wrapped Welcome is addressed to, as lowercase hex: its
/// one `p` tag (`transports/nostr.md` 71).
fn welcome_recipient_hex(welcome: &cgka_traits::transport::TransportMessage) -> Option<String> {
    let event = SessionManager::transport_message_to_event(welcome).ok()?;
    let mut recipients = event
        .tags
        .iter()
        .filter(|tag| tag.as_slice().first().is_some_and(|name| name == "p"));
    let only = recipients.next()?.as_slice().get(1)?.clone();
    recipients.next().is_none().then_some(only)
}

/// A new delivery record for `welcome` of `commit` — none for a founding
/// Welcome — in `group_id`, owed to `relays` of `recipient`'s inbox, as MDK's
/// host writes one before its first send (`marmot-account/src/runtime.rs`
/// 4181-4221): one acknowledgement completes it, and it is driven for
/// [`WELCOME_RECORD_BOUND_SECS`], never past the `not_after` of the
/// `KeyPackage` it was made for. Unlike MDK's host, a founding record names
/// its group: the disband settle and the forget end a group's records by
/// it, and the circle's note that a Welcome is owed is kept by it.
fn welcome_record(
    group_id: &GroupId,
    commit: Option<&MessageId>,
    welcome: cgka_traits::transport::TransportMessage,
    recipient: &str,
    relays: &[String],
    not_after: Option<u64>,
    now_ms: u64,
) -> cgka_traits::maintenance::DurableTransportFanout {
    let endpoints: Vec<TransportEndpoint> = relays.iter().cloned().map(TransportEndpoint).collect();
    let now = cgka_traits::transport::Timestamp(now_ms / 1_000);
    // A day from the hand-over, and never past an hour before a Haven
    // invitee's inbox window would lose the wrap: its `created_at` is backdated
    // up to two days (decision 231).
    let visible_until = SessionManager::transport_message_to_event(&welcome)
        .ok()
        .and_then(|event| {
            let lookback = u64::try_from(crate::relay::INBOX_RESUBSCRIBE_LOOKBACK_SECS).ok()?;
            Some(
                event
                    .created_at
                    .as_secs()
                    .saturating_add(lookback)
                    .saturating_sub(3_600),
            )
        })
        .unwrap_or(u64::MAX);
    let bound = now
        .0
        .saturating_add(WELCOME_RECORD_BOUND_SECS)
        .min(visible_until)
        .min(not_after.unwrap_or(u64::MAX));
    cgka_traits::maintenance::DurableTransportFanout {
        id: welcome.id.clone(),
        group_id: Some(group_id.clone()),
        evolution_id: commit.cloned(),
        exact_message: welcome,
        target: TransportPublishTarget::Inbox {
            recipient: MemberId::new(hex::decode(recipient).unwrap_or_default()),
            endpoints: endpoints.clone(),
        },
        targets: endpoints
            .into_iter()
            .map(|endpoint| TransportFanoutTarget {
                endpoint,
                state: TransportFanoutAttemptState::Unattempted,
                attempt_count: 0,
                last_attempt_at: None,
                failure_code: None,
            })
            .collect(),
        required_acks: 1,
        evolution_confirmed: true,
        possible_exposure: false,
        created_at: now,
        bounded_until: Some(cgka_traits::transport::Timestamp(bound)),
    }
}

/// The asks decision 180 counts as already spent on a removal set aside from
/// `queued`: all of them for a copy MDK had itself re-issued, which has had
/// MDK's own attempts — so one removal makes at most Haven's two asks, each
/// re-issued by MDK at most twice.
const fn asks_spent(queued: &cgka_traits::storage::QueuedOutboundIntent) -> u32 {
    if queued.reissue_attempts > 0 {
        MAX_REQUEUE_ATTEMPTS
    } else {
        0
    }
}

/// What a full drive is to do with one removal set aside unmade.
///
/// No `Debug`: it names members.
pub enum RemovalRequeue {
    /// Ask for the removal of these members again.
    Remove(Vec<MemberId>),
    /// Nobody it named is listed any more.
    AlreadyMade,
    /// Every member still listed was asked for as often as it may be.
    Abandoned,
    /// Every member still listed was set aside past MDK's rewind horizon.
    Expired,
}

/// Whether the roster the engine reports for `group_id` is the applied one:
/// with a commit of this device's own left staged — under a record or, after
/// a process died inside an eviction's staging, under none — it is that
/// commit's, and a member it omits is still in the circle. A store that
/// cannot say answers that it is not.
fn roster_is_applied(store: &SqliteAccountStorage, group_id: &GroupId) -> bool {
    store
        .get_group(group_id)
        .and_then(|group| own_sent_commits(store, &group))
        .is_ok_and(|unresolved| unresolved.is_empty())
}

/// The oldest transport `created_at` (seconds) among `payloads`, MDK-local
/// stored payloads (`traits/src/message.rs`; no MDK accessor gives it:
/// `docs/MDK_UPSTREAM_TRACKER.md` T-RETAINED-TIMESTAMPS). `None` when there
/// are none, and when any one does not decode: the oldest of the rest could
/// be later than the one unread, and a floor too late skips what was sent
/// before it, where no floor is the stream's cold start.
fn oldest_transport_secs<'a>(payloads: impl Iterator<Item = &'a [u8]>) -> Option<u64> {
    payloads
        .map(|payload| {
            StoredMessagePayload::decode(payload)
                .ok()
                .map(|stored| stored.into_message().timestamp.0)
        })
        .try_fold(None, |oldest: Option<u64>, secs| {
            secs.map(|secs| Some(oldest.map_or(secs, |oldest| oldest.min(secs))))
        })
        .flatten()
}

/// What the circle store alone says of a circle's holds
/// ([`SessionManager::stored_hold`]).
enum StoredHold {
    /// This holds it.
    Held(AwayHold),
    /// Nothing holds it.
    Clear,
    /// A removal's kept targets leave the answer to the engine's roster.
    AskTheRoster,
}

/// Whether a removal set aside unmade still holds `group_id`'s sends:
/// somebody it named is still listed
/// ([`CommitNotes::keep_removal_targets`]). A store or an engine that cannot
/// say answers that somebody is.
///
/// A member a commit took out is marked so at the fold
/// (`SessionManager::note_taken_out`); one the applied roster no longer
/// lists although no fold said so — its batch was lost with a process — is
/// marked here. With the last of them the note is taken back: what the user
/// asked for is so, by this device's ask or another's, and nothing is left to
/// say. The targets are kept while a reorg could still bring one back.
fn removal_unmade(
    store: &SqliteAccountStorage,
    notes: &dyn CommitNotes,
    session: &AccountDeviceSession,
    group_id: &GroupId,
) -> bool {
    let Some(targets) = notes.removal_targets(group_id) else {
        return true;
    };
    if targets.is_empty() {
        return false;
    }
    let Ok(members) = session.members(group_id) else {
        return true;
    };
    if targets
        .iter()
        .any(|target| members.iter().any(|member| &member.id == target))
    {
        return true;
    }
    let stable = matches!(
        session.epoch_state(group_id),
        Some(EpochState::Stable { .. })
    );
    if !stable || !roster_is_applied(store, group_id) {
        return true;
    }
    let epoch = session.epoch(group_id).map_or(0, |epoch| epoch.0);
    let _ = notes.take_out_removal_targets(group_id, &targets, epoch, None);
    notes.settle_removal(group_id);
    false
}

/// How a withdrawn removal of this device's is dropped
/// (`SessionManager::drop_withdrawn_removal`).
#[derive(Clone, Copy)]
enum Dropping<'a> {
    /// In a circle held for: these members, named at this epoch, are kept.
    Held(&'a [MemberId], u64),
    /// In a circle held for, none of these members, named at this epoch, is
    /// on the applied, stable roster ([`removal_satisfied`]).
    AlreadySo(&'a [MemberId], u64),
    /// In a circle this device left or no longer keeps.
    NobodyToHold,
}

/// Whether a withdrawn removal of `members` is already so: nobody it named
/// is on `group_id`'s applied roster, read in a stable epoch — MDK's own
/// `AlreadySatisfied` (`own_commit_intent.rs` 203-216), so the race of two
/// admins removing the same member says nothing to anyone. A roster that
/// cannot be read says it is not.
fn removal_satisfied(
    store: &SqliteAccountStorage,
    session: &AccountDeviceSession,
    group_id: &GroupId,
    members: &[MemberId],
) -> bool {
    matches!(
        session.epoch_state(group_id),
        Some(EpochState::Stable { .. })
    ) && roster_is_applied(store, group_id)
        && session.members(group_id).is_ok_and(|listed| {
            !members
                .iter()
                .any(|named| listed.iter().any(|member| &member.id == named))
        })
}

/// What is said of the commit a rolled-back record names: a change KNOWN to
/// have removed nobody, and otherwise a removal — the careful reading of a
/// commit whose kind nothing recorded.
fn undone_note(notes: &dyn CommitNotes, fanout: &OutboundFanout) -> ChangeNote {
    match fanout.group_id() {
        Some(group_id) if notes.removes_nobody(group_id) => ChangeNote::ChangeUndone,
        _ => ChangeNote::RemovalUndone,
    }
}

/// The last part of [`settle_fanouts_before_open`]: a trial record for the
/// one unresolved removal THE USER asked for in a circle that has no pending
/// record (`settled`). Each takes a ref past `highest_ref`, the highest any stored pending record carries.
///
/// An admin's own removal only, while the live plane's foreground is the
/// one thing the app calls that drives a stored record
/// (`the_live_planes_foreground_is_the_one_product_driver_and_the_open_repairs_a_removal_only`).
/// Hydrate keeps such a commit attached with or without a record, and with
/// none every convergence pass of its circle then fails on this device: the
/// circle is dead here either way, so the record costs it nothing. That is
/// not true of anything else. An eviction with no record leaves a circle
/// that reads stable and is healed by another member's eviction commit; any
/// other commit hydrate clears. A record would hold either circle's sends
/// and its unread traffic behind a commit that, in the poll configuration
/// and on a device that is only ever in the background, no call the app
/// makes can resolve.
fn try_recordless_removals(
    store: &SqliteAccountStorage,
    own_identity: &[u8],
    settled: &[GroupId],
    mut highest_ref: u64,
    notes: &dyn CommitNotes,
) -> StorageResult<()> {
    let now_ms = u64::try_from(chrono::Utc::now().timestamp_millis()).unwrap_or(0);
    for group_id in store.list_groups()? {
        if settled.contains(&group_id) {
            continue;
        }
        let group = store.get_group(&group_id)?;
        if group.is_terminal() || group.unrecoverable {
            continue;
        }
        let mut unresolved = own_sent_commits(store, &group)?;
        let Some((origin, source, message)) = unresolved.pop() else {
            continue;
        };
        // Exactly one, or nothing says which of them is attached.
        if !unresolved.is_empty() {
            log::warn!(
                "[Fanout] a circle holds more than one unresolved commit of its own and no \
                 record; none is given one"
            );
            continue;
        }
        // The engine stores an own commit with its exact signed event
        // (`cgka-engine/src/message_processor/store.rs` 342). A row without
        // one is not this build's, and there is nothing to freeze for it.
        let Some(message) = message else {
            continue;
        };
        // A removal the user asked for is known by the intent the engine
        // keeps for it; one a process died inside the staging of, before the
        // intent was written, cannot be told from a commit that removes
        // nobody, and is left to the engine like one. An EVICTION is left to
        // the engine too: with no record the circle reads stable, and the
        // eviction another member commits for the same departure is applied
        // here and ends the state; under a record nothing drives, that
        // commit would be held unread behind it.
        let removes = source == group.epoch.0
            && store
                .own_commit_intent(&origin)?
                .is_some_and(|intent| matches!(intent.intent, SendIntent::RemoveMembers { .. }));
        if !removes {
            // A change of this device's own that removes nobody: the engine
            // is about to clear it, and its row is retired once it has
            // (`cleared_at_open`), so the change was undone. The engine says
            // so once, in memory; the circle is told from what is stored,
            // before the engine opens, so a process that ends before that
            // announcement is read has told it all the same.
            if store.own_commit_intent(&origin)?.is_some() {
                let _ = notes.note(&group_id, ChangeNote::ChangeUndone);
            }
            continue;
        }
        highest_ref += 1;
        // Refused only for a message that is not a group message, which a
        // stored commit never is: no record then, and the engine decides.
        let Ok(trial) = commit_fanout(
            MemberId::new(own_identity.to_vec()),
            &group_id,
            message,
            &[],
            (
                PendingStateRef::new(highest_ref),
                origin,
                FanoutPendingKind::GroupEvolution,
            ),
            Vec::new(),
            now_ms,
        ) else {
            continue;
        };
        // As every recorded commit: the circle's mark is cleared before the
        // record is written, so a removal never reads as a change a day
        // without relays may undo. A mark that cannot be cleared: no record.
        if !notes.set_removes_nobody(&group_id, false) {
            continue;
        }
        store.put_outbound_fanout(&trial)?;
        crate::relay::fanout::own(trial.message_id());
    }
    Ok(())
}

/// What the open's own hydrate decides about each pending commit row, read
/// back the moment the engine is open and before anything else can run.
///
/// * The engine holds the row's commit: the row stands. One frozen for no
///   relay is the trial [`settle_fanouts_before_open`] wrote and hydrate
///   adopted, so the commit it found IS attached: it is re-frozen for the
///   relays of the epoch it leaves, which only the open engine can read —
///   each of them stored as POSSIBLY EXPOSED. Whoever staged that commit
///   without a record may have published it before the process died, and the
///   store cannot say: a relay that holds it answers `duplicate:` and the
///   commit is confirmed, and no refusal, and no bound, can ever roll back a
///   commit a relay may hold. The price is a repaired commit no relay ever
///   takes: it stays staged.
/// * It does not, and the row is frozen for no relay: a trial for a commit
///   that was not attached. The row goes; the commit's own row is left as it
///   was found, since the trial knows nothing of what was done with it.
/// * It does not, and no attempt was ever begun under the row's relays:
///   nothing was sent and nothing is staged, so the preparation is abandoned
///   (`protocol-core/durability.md`, "Prepared with no possible external
///   publish") — the commit's row retired, the row deleted.
/// * It does not, and an attempt was begun: a relay may hold a commit this
///   device can no longer confirm or discard. The row is kept, and the
///   circle takes no new change beside it
///   (`SessionManager::blocked_by_unheld_fanout`), until the engine's own
///   convergence has disposed of the commit and the row reads stale.
fn settle_fanouts_after_open(store: &SqliteAccountStorage, session: &AccountDeviceSession) {
    let Ok(fanouts) = session.outbound_fanouts() else {
        return;
    };
    for fanout in &fanouts {
        crate::relay::fanout::own(fanout.message_id());
        let (Some(pending), Some(group_id)) = (fanout.pending_ref(), fanout.group_id()) else {
            continue;
        };
        let trial = fanout.request().target.endpoints().is_empty();
        if SessionManager::holds(session, fanout) {
            if !trial {
                continue;
            }
            let refrozen = fanout_targets(session, group_id)
                .ok()
                .zip(fanout.pending_origin_message_id())
                .and_then(|(endpoints, origin)| {
                    let mut refrozen = commit_fanout(
                        session.self_id(),
                        group_id,
                        fanout.request().message.clone(),
                        &endpoints,
                        (pending, origin.clone(), FanoutPendingKind::GroupEvolution),
                        Vec::new(),
                        fanout.created_at_ms(),
                    )
                    .ok()?;
                    // The attempt is dated at the start of time: it says an
                    // attempt may have been made, not when, and leaves the
                    // relay due at once. And it is stored as one that never
                    // returned, because none of THIS record's has: each relay
                    // is still owed an attempt that runs to an answer before
                    // the record may end (`transports/nostr.md`, "Publish
                    // targets and acknowledgements").
                    for (index, endpoint) in endpoints.iter().enumerate() {
                        refrozen.mark_attempt_started_at(index, 0).ok()?;
                        refrozen
                            .record_target_failure(
                                index,
                                crate::relay::fanout::interrupted(endpoint),
                            )
                            .ok()?;
                    }
                    Some(refrozen)
                });
            // Without a relay to freeze it for, or with the trial still in
            // the way, the row stays as it is — never rolled back — and the
            // next open tries again.
            match refrozen
                .filter(|_| session.delete_outbound_fanout(fanout.message_id()).is_ok())
                .map(|refrozen| session.put_outbound_fanout(&refrozen))
            {
                Some(Ok(())) => log::warn!(
                    "[Fanout] a commit found staged with no record at the open was given one"
                ),
                Some(Err(_)) => log::error!(
                    "[Fanout] a staged commit's record was lost while it was being given its \
                     relays; the next open gives it one again"
                ),
                None => log::warn!(
                    "[Fanout] a commit found staged with no record could not be given its \
                     relays at this open; it stays staged"
                ),
            }
        } else if trial {
            if session.delete_outbound_fanout(fanout.message_id()).is_ok() {
                crate::relay::fanout::release(fanout.message_id());
                log::info!(
                    "[Fanout] a record written for a commit the engine does not hold staged \
                     was taken back at the open"
                );
            }
        } else if never_attempted(fanout) {
            let retired = fanout
                .pending_origin_message_id()
                .is_none_or(|origin| retire_commit(store, origin).is_ok());
            if retired && session.delete_outbound_fanout(fanout.message_id()).is_ok() {
                crate::relay::fanout::release(fanout.message_id());
                log::info!(
                    "[Fanout] a commit record with nothing staged behind it was removed at the open"
                );
            }
        } else {
            log::warn!(
                "[Fanout] a pending commit a relay may hold is no longer staged; its circle \
                 takes no new change"
            );
        }
    }
}

/// `fanout` with its commit marked applied, when it is still pending.
fn confirmed_copy(fanout: &OutboundFanout) -> Option<OutboundFanout> {
    let mut confirmed = fanout.clone();
    confirmed.mark_mls_confirmed().ok()?.then_some(confirmed)
}

/// How many stored rows in [`UNRESOLVED`] at or above a circle's epoch
/// [`proposal_stands`] reads before it answers "it stands" unread: a bound on
/// the rows a send decodes while MDK's departure timer reads due with nothing
/// behind it.
const PROPOSAL_SCAN_CAP: usize = 4_096;

/// The states a proposal still to be committed is stored in. MDK marks one
/// `Processed` only where a commit consumes it, in the transaction that moves
/// the group past its epoch (`openmls_projection.rs` 565-615 called from
/// `publish.rs` 150-162, written with the record at 175-200; a convergence
/// pass's acceptance, `canonicalization.rs` 895-898, written with the record
/// at `openmls_projection.rs` 3229-3234) — and `Processed` is where every
/// location a circle receives ends. An envelope no epoch key opens is stored
/// `PeelDeferred` under MDK's own flood cap, or not at all
/// (`ingest.rs` 715-770, 868-890).
const UNRESOLVED: [MessageState; 3] = [
    MessageState::Created,
    MessageState::Retryable,
    MessageState::ConvergenceDeferred,
];

/// Whether a scheduled departure holds a send, from what the engine
/// announces of it: `due_in_ms` until the eviction is due, `None` when none
/// is scheduled.
///
/// Held inside the wait a refused eviction earned; after it, while the
/// engine still announces the eviction ahead and the refusal stands — the
/// member who left is still in the circle, and a send's preflight stages
/// nothing until the deadline (MDK re-arms it 10–50 ms of monotonic time
/// out); and at the deadline only for a call that makes no commit, since a
/// full call's preflight then stages the eviction ahead of its location.
fn departure_held(
    due_in_ms: Option<u64>,
    wait_runs: bool,
    refusal_stands: bool,
    makes_none: bool,
    departure_stands: impl FnOnce() -> bool,
) -> bool {
    due_in_ms.is_some_and(|due_in_ms| {
        wait_runs
            || (due_in_ms > 0 && refusal_stands)
            || (makes_none && due_in_ms == 0 && departure_stands())
    })
}

/// Whether a departure may still be to be committed in `group_id`: it holds
/// a proposal made for the epoch it is at.
///
/// What MDK's own re-arm of its departure timers reads
/// (`cgka-engine/src/message_processor/mod.rs` 1366-1399). The timer itself
/// says less: it is an in-memory entry per proposal, dropped where the engine
/// applies a commit directly and NOT where a convergence pass applies one
/// (`distributed_convergence.rs` 1589-1593), so after another member's
/// eviction it reads due until a full advance or a send's preflight looks
/// and prunes it (`ingest.rs` 2012-2059) — and a plane that makes no commit
/// calls neither (`docs/MDK_UPSTREAM_TRACKER.md` T-STALE-DEPARTURE-TIMER).
///
/// Any proposal, as MDK's does: a leave is not told from another kind here,
/// so a proposal of another kind beside a timer left stale reads as a
/// departure too — a hold with nothing behind it, which ends when the epoch
/// moves or a full advance prunes the timer.
///
/// Only rows in [`UNRESOLVED`] are read, so a busy circle's locations and an
/// outsider's junk on its routing tag count for nothing (`OWNER_ITEMS`
/// 178/186). MDK's indexed existence probe answers first
/// (`storage-sqlite/src/storage/messages.rs` 349-372): with no such row at or
/// above the epoch, nothing stands and no row is walked — MDK's streaming
/// read orders by insertion, and `SQLite` serves that by walking the group's
/// rows. Otherwise the streaming read goes no further than the first such
/// row (`messages.rs` 481-515), nor than `cap` rows: past them it answers "it
/// stands" unread, as a store that cannot be read does. What can still fill
/// those states is a member's traffic for a future epoch (mdk#757) — a
/// member can hold a send with one proposal anyway — or this device being
/// behind a commit.
///
/// # Errors
///
/// Returns the store's error; [`SessionManager::departure_stands`] reads
/// that as "it stands".
fn proposal_stands(
    store: &SqliteAccountStorage,
    group_id: &GroupId,
    cap: usize,
) -> StorageResult<bool> {
    let group = match store.get_group(group_id) {
        Ok(group) => group,
        Err(StorageError::NotFound) => return Ok(false),
        Err(e) => return Err(e),
    };
    if !store.has_messages_in_states(group_id, &UNRESOLVED, group.epoch)? {
        return Ok(false);
    }
    let mut stands = false;
    let mut read = 0_usize;
    store.visit_messages_in_states(group_id, &UNRESOLVED, group.epoch, &mut |record| {
        read += 1;
        stands = read > cap
            || (record.epoch == group.epoch
                && gating_projection(&record.payload).is_some_and(|(_, projection)| {
                    projection.kind == OpenMlsContentKind::Proposal
                        && projection.source_epoch == Some(group.epoch.0)
                }));
        !stands
    })?;
    Ok(stands)
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
    let rewind = max_rewind_commits();
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
    // A staged commit's roster is the engine's optimistic projection; MDK's
    // typed epoch state says so directly (the projected and stored epochs no
    // longer differ while a commit is pending at v0.10.4).
    if !matches!(
        session.epoch_state(group_id),
        Some(EpochState::Stable { .. })
    ) || session.has_pending_convergence_inputs(group_id)?
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

/// The shape of a new Haven circle, for MDK's creation admission check: only
/// the component ids and required features reach the requirements
/// (`creation_key_package_capabilities`), so no routing or retention data is
/// carried.
fn haven_circle_request() -> CreateGroupRequest {
    CreateGroupRequest {
        name: String::new(),
        description: String::new(),
        members: Vec::new(),
        required_features: Vec::new(),
        app_components: [
            NOSTR_ROUTING_COMPONENT_ID,
            GROUP_MESSAGE_RETENTION_COMPONENT_ID,
        ]
        .into_iter()
        .map(|component_id| AppComponentData {
            component_id,
            data: Vec::new(),
        })
        .collect(),
        initial_admins: Vec::new(),
    }
}

/// The app components every Haven `KeyPackage` advertises and every Haven circle
/// requires: MDK's defaults — profile 0x8001, admin policy 0x8003 and the
/// mandatory lifecycle 0x800c — plus Nostr routing 0x8004 and message retention
/// 0x8005, the pattern MDK's own app uses
/// (`marmot-app/src/lib.rs:6249-6262`). Retention drives the NIP-40
/// `expiration` on kind-445 application messages, so location ciphertext never
/// lingers on relays. Never 0x8006, 0xF2D1 or 0x800b.
fn haven_app_components() -> BTreeSet<AppComponentId> {
    let mut components = default_group_components();
    components.insert(NOSTR_ROUTING_COMPONENT_ID);
    components.insert(GROUP_MESSAGE_RETENTION_COMPONENT_ID);
    components
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

/// What the mesh key ring reads of the engine, and all it reads.
impl self::mesh::Held for AccountDeviceSession {
    fn stable_epoch(&self, group_id: &GroupId) -> Option<u64> {
        match self.epoch_state(group_id) {
            Some(EpochState::Stable { epoch }) => Some(epoch.0),
            _ => None,
        }
    }

    // The fixed label (Rule 11): the secret the kind-445 outer layer is
    // keyed by, read and never re-derived under another.
    fn exporter(&self, group_id: &GroupId) -> Option<(u64, zeroize::Zeroizing<Vec<u8>>)> {
        self.exporter_secret_with_epoch(group_id, DEFAULT_EXPORTER_LABEL, 32)
            .ok()
            .map(|(epoch, secret)| (epoch.0, secret))
    }

    fn routing_id(&self, group_id: &GroupId) -> Option<[u8; 32]> {
        let raw = self
            .app_component(group_id, NOSTR_ROUTING_COMPONENT_ID)
            .ok()??;
        cgka_traits::app_components::decode_nostr_routing_v1(&raw)
            .ok()
            .map(|routing| routing.nostr_group_id)
    }
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

/// The routing component a group with `relays` carries: MDK's own validator
/// decides its bounds (`NostrRoutingV1::new`: one to 16 relays, each a
/// bounded `ws`/`wss` URL with a host and no credentials or fragment, which
/// the NIP-59 welcome wrap also needs), and Haven's policy adds that every
/// relay is one another member's client may dial ([`may_dial_all`]). The
/// refusal is fixed text: MDK's names the count.
fn routing_of(nostr_group_id: [u8; 32], relays: Vec<String>) -> Result<NostrRoutingV1> {
    may_dial_all(&relays)?;
    NostrRoutingV1::new(nostr_group_id, relays)
        .map_err(|_| NostrError::InvalidEvent("invalid group routing".to_string()))
}

/// Refuses a relay set naming a relay that is not `wss` to a public host
/// ([`crate::relay::foreign_relay_dialable`]): the routing component
/// advertises these to every member's client, and other clients dial what it
/// names.
fn may_dial_all(relays: &[String]) -> Result<()> {
    if relays
        .iter()
        .all(|relay| crate::relay::foreign_relay_dialable(relay))
    {
        Ok(())
    } else {
        Err(NostrError::InvalidEvent(
            "group relay is not a wss URL on a public host".to_string(),
        ))
    }
}

/// `rows` without the application records: a commit's pacing, its bound and
/// its end are read from commits' and proposals' records alone, so that a
/// location neither delays a commit nor keeps one's record alive.
fn commit_side(mut rows: Vec<OutboundFanout>) -> Vec<OutboundFanout> {
    rows.retain(|row| row.application_message().is_none());
    rows
}

/// A location's record, as the hold that sealed it wrote it.
pub struct RecordedLocation {
    /// The record.
    pub id: FanoutId,
    /// The relays it is frozen for: where the location is sent, and nowhere
    /// else.
    pub relays: Vec<String>,
}

/// What a location's own send reads of its record
/// ([`SessionManager::location_to_send`]).
pub struct LocationToSend {
    /// The relays the record is frozen for.
    pub relays: Vec<String>,
    /// When its event expires, unix seconds.
    pub expires_at_secs: u64,
    /// Whether it may be sent now
    /// (`SessionManager::location_may_be_sent`).
    pub may_be_sent: bool,
    /// Whether it was sealed for the mesh alone
    /// (`Publishing::seal_for_mesh`): its send hands it to no relay.
    pub(crate) mesh_only: bool,
    /// What the mesh hand-off needs of the check that read this
    /// ([`SessionManager::mesh_offer`]); `None` when it may not be sent, mesh
    /// is off or its circle has no key.
    mesh_turn: Option<self::mesh::Turn>,
}

/// One stored application record, as a drive reads it.
pub struct LocationRecord {
    /// The record.
    pub id: FanoutId,
    /// When its event expires, unix seconds.
    pub expires_at_secs: u64,
    /// Whether this session sealed it: its own send is under way or still
    /// to come. Otherwise a process died with that send unfinished.
    pub here: bool,
}

/// When the event an application record froze expires, unix seconds: its
/// NIP-40 `expiration`, which every location Haven seals carries
/// ([`RetentionBoundPeeler`](super::retention::RetentionBoundPeeler)). A
/// record whose event cannot be read, or carries none, has expired.
fn location_expiry_secs(fanout: &OutboundFanout) -> u64 {
    SessionManager::transport_message_to_event(&fanout.request().message)
        .ok()
        .and_then(|event| event.tags.expiration().map(Timestamp::as_secs))
        .unwrap_or(0)
}

/// The relays a fanout for `group_id` is frozen for: the routing component's
/// entries this device may dial ([`crate::relay::foreign_relay_dialable`]), in
/// the component's order and spelling. An entry Haven's relay policy refuses is
/// another client's to have written; frozen, it could only ever answer
/// "refused before the hand-over", or reach a host inside this device's own
/// network.
///
/// An error when the component cannot be read or decoded, and when it names no
/// relay this device may dial: frozen for nobody, a commit could only be rolled
/// back, and the caller does that in the hold that staged it.
fn fanout_targets(
    session: &AccountDeviceSession,
    group_id: &GroupId,
) -> Result<Vec<TransportEndpoint>> {
    let raw = session
        .app_component(group_id, NOSTR_ROUTING_COMPONENT_ID)
        .map_err(map_mls_err)?
        .ok_or(NostrError::MdkError("the circle has no routing component"))?;
    let endpoints: Vec<TransportEndpoint> =
        cgka_traits::app_components::decode_nostr_routing_v1(&raw)
            .map_err(|_| NostrError::MdkError("the routing component does not decode"))?
            .relays
            .into_iter()
            .filter(|relay| crate::relay::foreign_relay_dialable(relay))
            .map(TransportEndpoint)
            .collect();
    if endpoints.is_empty() {
        return Err(NostrError::MdkError(
            "the circle names no relay this device may dial",
        ));
    }
    Ok(endpoints)
}

/// The durable fanout of one commit: its exact signed event, frozen for
/// `endpoints`, nothing attempted.
fn commit_fanout(
    account_id: MemberId,
    group_id: &GroupId,
    message: cgka_traits::transport::TransportMessage,
    endpoints: &[TransportEndpoint],
    (pending, origin, kind): (PendingStateRef, MessageId, FanoutPendingKind),
    welcomes: Vec<cgka_traits::transport::TransportMessage>,
    now_ms: u64,
) -> Result<OutboundFanout> {
    let TransportEnvelope::GroupMessage { transport_group_id } = &message.envelope else {
        return Err(NostrError::MdkError("a commit is not a group message"));
    };
    OutboundFanout::stage_with_post_confirmation_welcomes(
        TransportPublishRequest {
            account_id,
            target: TransportPublishTarget::Group {
                group_id: group_id.clone(),
                transport_group_id: transport_group_id.clone(),
                endpoints: endpoints.to_vec(),
            },
            required_acks: required_acks(endpoints),
            message,
        },
        Some(pending),
        Some(group_id.clone()),
        now_ms,
        Some(origin),
        Some(kind),
        welcomes,
    )
    .map_err(|_| NostrError::MdkError("the fanout record was refused"))
}

/// Whether `fanout` is a bare proposal's record: no MLS change of its own,
/// and not an application message.
fn is_proposal_record(fanout: &OutboundFanout) -> bool {
    fanout.mls_state() == FanoutMlsState::NotApplicable && fanout.application_message().is_none()
}

/// Whether no attempt was ever begun under `fanout` and nothing says a relay
/// may hold its event: nothing was sent under this record.
fn never_attempted(fanout: &OutboundFanout) -> bool {
    !fanout.possible_exposure()
        && fanout
            .target_statuses()
            .iter()
            .all(|status| *status == FanoutTargetStatus::NotAttempted)
}

/// The circle a send is for.
const fn intent_group(intent: &SendIntent) -> &GroupId {
    match intent {
        SendIntent::Invite { group_id, .. }
        | SendIntent::RemoveMembers { group_id, .. }
        | SendIntent::SelfUpdate { group_id }
        | SendIntent::UpdateAppComponents { group_id, .. }
        | SendIntent::UpdateGroupData { group_id, .. }
        | SendIntent::EnableDisbanding { group_id }
        | SendIntent::Disband { group_id }
        | SendIntent::AppMessage { group_id, .. }
        | SendIntent::Leave { group_id } => group_id,
    }
}

/// The circle a send would stage a commit in, if it stages one.
#[cfg(any(test, feature = "test-utils"))]
const fn group_change_of(intent: &SendIntent) -> Option<&GroupId> {
    match intent {
        SendIntent::Invite { group_id, .. }
        | SendIntent::RemoveMembers { group_id, .. }
        | SendIntent::SelfUpdate { group_id }
        | SendIntent::UpdateAppComponents { group_id, .. }
        | SendIntent::UpdateGroupData { group_id, .. }
        | SendIntent::EnableDisbanding { group_id }
        | SendIntent::Disband { group_id } => Some(group_id),
        SendIntent::AppMessage { .. } | SendIntent::Leave { .. } => None,
    }
}

const fn empty_effects() -> SessionEffects {
    SessionEffects {
        events: Vec::new(),
        publish: Vec::new(),
        queued: Vec::new(),
        pending_convergence: Vec::new(),
    }
}

/// How many acknowledgements a fanout asks for before it stops retrying:
/// two, or its one relay's. Relays are counted as parsed URLs — a routing
/// component is unique by bytes only, so one relay can be spelled twice in it.
fn required_acks(endpoints: &[TransportEndpoint]) -> usize {
    endpoints
        .iter()
        .filter_map(|endpoint| RelayUrl::parse(endpoint.as_str()).ok())
        .collect::<BTreeSet<_>>()
        .len()
        .min(2)
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
/// the inner event's kind is [`KIND_LOCATION_UPDATE`]**; otherwise the empty
/// string. The kind-9 + `["t","location"]` pair pre-cutover builds sent is not
/// read: no build that emits it can decrypt a v0.10.4 group.
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
    inner.get("kind").and_then(serde_json::Value::as_u64) == Some(u64::from(KIND_LOCATION_UPDATE))
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
    /// MDK's two rules for what an ingest answer tells the stall detector:
    /// a deferral of EITHER lineage is evidence the circle fell behind (a
    /// fork that never resolves is the wedge that most needs reporting,
    /// `marmot-app/src/client/sync.rs` 2840-2852), a want of room arms at
    /// once, a buffered answer only lands the epoch, and an answer that
    /// names no circle tells it nothing.
    #[test]
    fn a_contested_fork_deferral_still_counts() {
        use super::{stall_input, StallInput};
        use cgka_traits::ingest::{DeferralLineage, InboundResourceLimit};
        let group = GroupId::new(vec![7; 16]);
        for lineage in [DeferralLineage::Uncontested, DeferralLineage::ContestedFork] {
            assert_eq!(
                stall_input(&IngestOutcome::TransportDeferred {
                    group_id: group.clone(),
                    lineage,
                }),
                Some((&group, StallInput::Undecryptable)),
                "a deferral of lineage {lineage:?} is stall evidence"
            );
        }
        assert_eq!(
            stall_input(&IngestOutcome::ResourceRefused {
                group_id: group.clone(),
                resource: InboundResourceLimit::TransportDeferredCapacity,
            }),
            Some((&group, StallInput::Refused))
        );
        assert_eq!(
            stall_input(&IngestOutcome::Buffered {
                group_id: group.clone(),
                epoch: EpochId(3),
            }),
            Some((&group, StallInput::Landing))
        );
        assert_eq!(stall_input(&IngestOutcome::Processed), None);
    }

    #[test]
    fn a_departure_holds_a_send_by_its_truth_table() {
        use super::departure_held;
        // (due_in_ms, wait runs, refusal stands, makes none, departure stands) -> held
        let cases: [(Option<u64>, bool, bool, bool, bool, bool); 12] = [
            (None, true, true, true, true, false),
            (Some(30), true, false, false, false, true),
            (Some(0), true, false, false, false, true),
            (Some(30), false, true, false, false, true),
            (Some(30), false, false, false, true, false),
            (Some(30), false, false, true, true, false),
            (Some(0), false, true, false, true, false),
            (Some(0), false, true, true, true, true),
            (Some(0), false, false, true, true, true),
            (Some(0), false, false, true, false, false),
            (Some(0), false, false, false, true, false),
            (Some(30), false, true, true, false, true),
        ];
        for (due, wait, refusal, none, stands, held) in cases {
            assert!(
                departure_held(due, wait, refusal, none, || stands) == held,
                "departure_held({due:?}, {wait}, {refusal}, {none}, {stands}) != {held}"
            );
        }
    }

    use super::*;

    /// A Welcome's record is driven a day from its hand-over, never past an
    /// hour before its wrap leaves a Haven invitee's inbox window, and never
    /// past the `not_after` of the `KeyPackage` it was made for — once that
    /// is sooner, it is the bound, and the record's ordinary end at its
    /// bound ends it. A founding record names its circle and no commit.
    #[test]
    fn a_welcomes_bound_is_its_key_packages_not_after_when_sooner() {
        let invitee = nostr::Keys::generate().public_key().to_hex();
        let now_secs = nostr::Timestamp::now().as_secs();
        let wrap = nostr::EventBuilder::new(nostr::Kind::GiftWrap, "sealed")
            .tag(nostr::Tag::parse(["p", &invitee]).expect("a p tag"))
            .sign_with_keys(&nostr::Keys::generate())
            .expect("signed");
        let message = SessionManager::event_to_transport_message(&wrap).expect("a Welcome");
        let group = GroupId::new(vec![0x4e; 32]);
        let relays = ["wss://inbox.bound.example.com".to_string()];
        let bound = |not_after| {
            welcome_record(
                &group,
                None,
                message.clone(),
                &invitee,
                &relays,
                not_after,
                now_secs * 1_000,
            )
            .bounded_until
            .expect("bounded")
            .0
        };

        assert_eq!(bound(None), now_secs + WELCOME_RECORD_BOUND_SECS);
        assert_eq!(bound(Some(now_secs + 3_600)), now_secs + 3_600);
        assert_eq!(
            bound(Some(now_secs + 2 * WELCOME_RECORD_BOUND_SECS)),
            now_secs + WELCOME_RECORD_BOUND_SECS
        );
        let founding = welcome_record(&group, None, message, &invitee, &relays, None, 0);
        assert!(founding.evolution_id.is_none() && founding.group_id == Some(group));
    }

    /// The oldest transport instant of what the engine keeps is read from
    /// every stored row or not at all: one row that does not decode gives no
    /// floor, never the oldest of the rest.
    #[test]
    fn the_oldest_kept_instant_is_read_from_every_row_or_none() {
        let stored = |secs: u64| {
            let event = nostr::EventBuilder::new(nostr::Kind::Custom(445), "ciphertext")
                .tag(nostr::Tag::parse(["h", &"ab".repeat(32)]).expect("an h tag"))
                .custom_created_at(nostr::Timestamp::from(secs))
                .sign_with_keys(&nostr::Keys::generate())
                .expect("signed");
            StoredMessagePayload::raw_transport(
                SessionManager::event_to_transport_message(&event).expect("converts"),
            )
            .encode()
            .expect("encodes")
        };
        let (late, early) = (stored(2_000), stored(1_000));
        assert_eq!(
            oldest_transport_secs([late.as_slice(), early.as_slice()].into_iter()),
            Some(1_000)
        );
        assert_eq!(
            oldest_transport_secs([late.as_slice(), b"not a payload".as_slice()].into_iter()),
            None,
            "a row that does not decode left the oldest of the rest as the floor",
        );
        assert_eq!(oldest_transport_secs(std::iter::empty()), None);
    }

    /// The freeze's last leg answers yes only for the pass the engine holds
    /// its reservation on — completed, its fairness slot still available.
    /// No pass, one still collecting, one whose slot is spent, and a read
    /// that failed are not that: a change the user asked for is never
    /// retired because the store was busy.
    #[test]
    fn only_a_completed_pass_with_its_slot_left_is_a_reservation_and_a_failed_read_never() {
        use cgka_traits::{ConvergencePassPhase, DurableConvergencePass};
        let pass = |phase, fairness_slot_available| -> std::result::Result<_, ()> {
            Ok(Some(DurableConvergencePass {
                group_id: GroupId::new(vec![7; 32]),
                generation: 1,
                phase,
                base_epoch: EpochId(3),
                clock_instance_id: 0,
                opened_monotonic_ms: 0,
                quiescence_deadline_monotonic_ms: 0,
                absolute_deadline_monotonic_ms: 0,
                opened_wall_ms: 0,
                quiescence_deadline_wall_ms: 0,
                absolute_deadline_wall_ms: 0,
                members: Vec::new(),
                frozen_at_wall_ms: None,
                cutoff_cause: None,
                fairness_slot_available,
            }))
        };
        assert!(reservation_held(&pass(
            ConvergencePassPhase::Completed,
            true
        )));
        assert!(!reservation_held(&pass(
            ConvergencePassPhase::Completed,
            false
        )));
        assert!(!reservation_held(&pass(
            ConvergencePassPhase::Collecting,
            true
        )));
        assert!(!reservation_held::<()>(&Ok(None)));
        assert!(
            !reservation_held(&Err(())),
            "a failed read was taken as the engine holding its reservation",
        );
    }

    /// A change of the group is each of the six kinds MDK reserves a
    /// circle's next pass for (`is_admin_group_state_intent`), and nothing
    /// else: not a location, a leave or a self-update.
    #[test]
    fn a_change_of_the_group_is_each_kind_the_engine_reserves_a_pass_for() {
        let group_id = GroupId::new([0x6b; 32]);
        let reserved = [
            // Through the one place Haven builds an invite.
            SessionManager::invite_intent(&group_id, Vec::new()),
            SendIntent::RemoveMembers {
                group_id: group_id.clone(),
                members: Vec::new(),
            },
            SendIntent::UpdateAppComponents {
                group_id: group_id.clone(),
                updates: Vec::new(),
            },
            SendIntent::UpdateGroupData {
                group_id: group_id.clone(),
                name: None,
                description: None,
            },
            SendIntent::EnableDisbanding {
                group_id: group_id.clone(),
            },
            SendIntent::Disband {
                group_id: group_id.clone(),
            },
        ];
        assert!(reserved.iter().all(changes_group));
        let unreserved = [
            SendIntent::Leave {
                group_id: group_id.clone(),
            },
            SendIntent::SelfUpdate { group_id },
        ];
        assert!(!unreserved.iter().any(changes_group));
    }

    /// A proposal is recorded for the circle MDK's own record of it names,
    /// and for no circle without one: never by the address it is sent to,
    /// which can name two circles, and never by the call that handed it back,
    /// which can be another circle's.
    #[test]
    fn a_proposal_is_recorded_for_the_circle_mdks_record_names_and_no_other() {
        let source = include_str!("manager.rs");
        let body = |signature: &str, end: &str| -> String {
            let from = &source[source.find(signature).expect("the function is here")..];
            from[..from.find(end).expect("its end is here")]
                .chars()
                .filter(|c| !c.is_whitespace())
                .collect()
        };
        let lookup = body(
            "    fn put_proposal_fanout(",
            "let endpoints = fanout_targets(",
        );
        let circle = body("    fn proposal_circle(", "\n    }\n");
        assert!(
            lookup.contains("letgroup_id=self.proposal_circle(session,msg).ok_or(")
                && !lookup.contains("live_group_ids")
                && !lookup.contains("app_component")
                && circle.contains("self.message_store.get_message(&msg.id).ok()?.group_id;")
                && circle.contains(".is_ok_and(|group|!group.removed)"),
            "a proposal's circle is no longer the one MDK's own record of it names",
        );
    }

    // ── The in-memory refused ledger keeps the durable one's promises ─────────

    fn refused_ids(seeds: std::ops::Range<u16>) -> Vec<nostr::EventId> {
        seeds
            .map(|seed| {
                let mut bytes = [0u8; 32];
                bytes[..2].copy_from_slice(&seed.to_be_bytes());
                nostr::EventId::from_byte_array(bytes)
            })
            .collect()
    }

    /// What a call handed back before its own engine call failed is not
    /// lost with that failure — the engine has applied it — and comes with
    /// the next batch that does come back, once.
    #[tokio::test]
    async fn what_a_call_handed_back_before_it_failed_comes_with_the_next_batch() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let storage = Arc::new(crate::circle::CircleStorage::in_memory().expect("store"));
        let session = SessionManager::new_unencrypted_with_notes(
            dir.path(),
            &Keys::generate(),
            Some(storage),
        )
        .expect("session");
        let mut handed = empty_effects();
        handed
            .pending_convergence
            .push(GroupId::new(vec![0x4c; 32]));

        let failed: Result<SessionEffects> = Err(NostrError::StorageError(String::new()));
        assert!(session
            .behind_what_was_handed_back(handed.clone(), failed)
            .is_err());
        let mut engine = session.engine().await.expect("the engine");
        assert!(
            session
                .hand_back_stranded(&mut engine, None, true)
                .await
                .is_ok_and(|ahead| ahead == handed),
            "what a failed call had handed back did not come with the next batch",
        );
        assert!(
            session
                .hand_back_stranded(&mut engine, None, true)
                .await
                .is_ok_and(|ahead| ahead == empty_effects()),
            "what a failed call had handed back came twice",
        );
    }

    /// A circle whose relays confirmed three fruitless walks reads `Stalled`
    /// even when its arm run escalated first: three refusals each re-armed by
    /// an owing walk raise MDK's one report off the arm count, and a minted
    /// flood can drive exactly that. The report itself is still made once.
    #[test]
    fn three_fruitless_walks_name_a_circle_stalled_after_its_arm_run_escalated() {
        use crate::nostr::mls::epoch_stall::{
            BackfillDecision, EPOCH_STALL_ESCALATION_ARM_THRESHOLD,
            EPOCH_STALL_FRUITLESS_COMPLETION_THRESHOLD,
        };
        let dir = tempfile::TempDir::new().expect("temp dir");
        let session =
            SessionManager::new_unencrypted(dir.path(), &Keys::generate()).expect("session");
        let circle = GroupId::new(vec![0x5e; 32]);
        let now_ms = 1_700_000_000_000;
        let mut escalated = false;
        for arm in 1..=EPOCH_STALL_ESCALATION_ARM_THRESHOLD {
            let decision =
                session
                    .stall()
                    .observe_resource_refusal(circle.clone(), EpochId(7), now_ms);
            escalated |= matches!(decision, BackfillDecision::ArmAndEscalate { .. });
            assert!(decision.arms_backfill(), "refusal {arm} did not arm");
            session.history_walk_settled(&circle, true);
        }
        assert!(escalated, "premise: the arm run escalated");
        for _ in 0..EPOCH_STALL_FRUITLESS_COMPLETION_THRESHOLD {
            assert!(
                !session.stalled(&circle),
                "a circle read Stalled before its walks earned it"
            );
            session.history_walk_settled(&circle, false);
        }
        assert!(
            session.stalled(&circle),
            "a circle whose arm run escalated first was never named Stalled",
        );
        assert!(
            session
                .stall()
                .observe_fruitless_completion([&circle])
                .is_empty(),
            "the run reported twice",
        );
    }

    /// A passage that ends a stall run forgets the evidence stored for it, so
    /// a stall that ended does not come back with the next open. A
    /// convergence reorg can pass two epochs in one event: off the epoch the
    /// run armed at, and off the next.
    #[tokio::test]
    async fn a_passage_that_ends_a_stall_run_forgets_its_stored_evidence() {
        use crate::nostr::mls::epoch_stall::EpochStallEvidence;
        let dir = tempfile::TempDir::new().expect("temp dir");
        let storage = Arc::new(crate::circle::CircleStorage::in_memory().expect("store"));
        let keys = Keys::generate();
        let circle = GroupId::new(vec![0x4d; 32]);
        assert!(storage.keep_stall_evidence(
            &circle,
            EpochStallEvidence {
                stalled_epoch: 10,
                fruitless_completions: 3,
                fruitless_reported: true,
                last_arm_at_ms: 1_700_000_000_000,
            },
        ));
        let open = || {
            let mut session = SessionManager::new_unencrypted_with_notes(
                dir.path(),
                &keys,
                Some(storage.clone()),
            )
            .expect("session");
            session.install_stall_evidence(storage.clone());
            session
        };
        let session = open();
        assert!(
            session.stalled_for_test(&circle),
            "premise: the stored stall is restored"
        );
        let engine = session.engine().await.expect("the engine");
        session.note_stall_evidence(
            &engine,
            &[GroupEvent::EpochChanged {
                group_id: circle.clone(),
                from: EpochId(10),
                to: EpochId(12),
            }],
        );
        drop(engine);
        assert!(
            !session.stalled_for_test(&circle),
            "premise: the passage ended the run"
        );
        drop(session);
        assert!(
            storage.stall_evidence().is_empty(),
            "an ended run's evidence was kept"
        );
        assert!(
            !open().stalled_for_test(&circle),
            "a stall that ended came back with the next open"
        );
    }

    /// A removal set aside holds its circle's sends whenever something that
    /// would say whether its members have gone cannot be read: who it named,
    /// or who the engine lists. Nothing is forgotten on such an answer.
    #[tokio::test]
    async fn a_removal_set_aside_holds_when_its_names_or_its_circle_cannot_be_read() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let storage = Arc::new(crate::circle::CircleStorage::in_memory().expect("store"));
        let session = SessionManager::new_unencrypted_with_notes(
            dir.path(),
            &Keys::generate(),
            Some(storage.clone()),
        )
        .expect("session");
        // A circle the engine cannot list the members of.
        let circle = GroupId::new(vec![0x4c; 32]);
        let named = MemberId::new(vec![0x11; 32]);
        let engine = session.engine().await.expect("the engine");
        let held = || session.away_hold(&engine, &circle, DriveMode::FinishOnly);
        assert!(
            held().is_none(),
            "control: a circle no removal was set aside in is held",
        );
        assert!(
            storage.note(&circle, ChangeNote::QueuedRemovalDropped)
                && storage.keep_removal_targets(&circle, std::slice::from_ref(&named), 0, 0)
        );
        // `assert!`, not `assert_eq!`: a member id is never formatted
        // (Security Rule 15).
        assert!(
            held() == Some(AwayHold::RemovalUnmade)
                && storage.removal_targets(&circle) == Some(vec![named])
                && storage.peek(&circle) == [ChangeNote::QueuedRemovalDropped],
            "a removal whose circle's members cannot be listed held nothing, or forgot who \
             it named",
        );
        storage
            .conn()
            .lock()
            .expect("the store")
            .execute_batch("DROP TABLE removal_targets")
            .expect("the names can no longer be read");
        assert!(
            held() == Some(AwayHold::RemovalUnmade),
            "a removal whose names cannot be read held nothing",
        );
    }

    /// Whether a departure still stands is read from the engine's store, and
    /// a store that cannot be read is not one in which it has ended: the
    /// hold built on that read stands.
    #[tokio::test]
    async fn a_departure_reads_as_standing_when_its_circles_record_cannot_be_read() {
        use crate::nostr::mls::storage::{set_group_read_fault_for_test, StorageConfig};

        let dir = tempfile::TempDir::new().expect("temp dir");
        let session =
            SessionManager::new_unencrypted_with_notes(dir.path(), &Keys::generate(), None)
                .expect("session");
        let circle = GroupId::new(vec![0x4c; 32]);
        assert!(
            !session.departure_stands(&circle),
            "a circle the engine has no record of was read as holding a departure",
        );
        let (db, key) = (
            StorageConfig::new(dir.path()).database_path(),
            StorageConfig::test_sqlcipher_key().expect("test key"),
        );
        set_group_read_fault_for_test(&db, &key, true).expect("the fault is armed");
        assert!(
            session.departure_stands(&circle),
            "a store that cannot be read was taken as one in which no departure stands",
        );
    }

    /// A store that cannot say whether this device asked to leave a circle
    /// is read as one in which it did: nothing is sealed for the circle. It
    /// says so by its storage code alone.
    #[tokio::test(flavor = "current_thread")]
    async fn a_leave_intent_that_cannot_be_read_reads_as_leaving_and_names_nobody() {
        let (_dir, storage, session) = session_over_a_store();
        let circle = GroupId::new(vec![0xa7; 32]);
        assert!(!session.leaving(&circle), "premise: nothing asked to leave");
        storage
            .conn()
            .lock()
            .expect("the store")
            .execute_batch("DROP TABLE user_settings")
            .expect("the intent can no longer be read");
        let lines = crate::test_log::capture_log_lines(async {
            assert!(
                session.leaving(&circle),
                "a store that cannot say was taken as one in which no leave was asked",
            );
        })
        .await;
        assert!(lines
            .iter()
            .any(|line| line.contains("a leave intent was not read")));
        let needle = hex::encode(circle.as_slice());
        assert!(
            lines
                .iter()
                .all(|line| !line.contains(&needle[..8])
                    && !line.contains(&needle[needle.len() - 8..])),
            "a line about a leave intent carries the circle",
        );
    }

    /// A session over a durable circle store, for a test that feeds the fold
    /// events of its own.
    fn session_over_a_store() -> (
        tempfile::TempDir,
        Arc<crate::circle::CircleStorage>,
        SessionManager,
    ) {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let storage = Arc::new(crate::circle::CircleStorage::in_memory().expect("store"));
        let session = SessionManager::new_unencrypted_with_notes(
            dir.path(),
            &Keys::generate(),
            Some(storage.clone()),
        )
        .expect("session");
        (dir, storage, session)
    }

    fn taken_out(
        circle: &GroupId,
        member: &MemberId,
        epoch: u64,
        by: Option<&MessageId>,
    ) -> GroupEvent {
        GroupEvent::GroupStateChanged {
            group_id: circle.clone(),
            epoch: EpochId(epoch),
            actor: None,
            change: GroupStateChange::MemberRemoved {
                member: member.clone(),
            },
            origin_commit_id: by.cloned(),
        }
    }

    fn withdrawn(circle: &GroupId, commit: &MessageId) -> GroupEvent {
        GroupEvent::GroupStateInvalidated {
            group_id: circle.clone(),
            epoch: EpochId(3),
            invalidated_commit_id: commit.clone(),
            reason: cgka_traits::engine::GroupStateInvalidationReason::SupersededByBranchSelection,
        }
    }

    fn moved(circle: &GroupId, from: u64, to: u64) -> GroupEvent {
        GroupEvent::EpochChanged {
            group_id: circle.clone(),
            from: EpochId(from),
            to: EpochId(to),
        }
    }

    fn asks_of(
        storage: &crate::circle::CircleStorage,
        circle: &GroupId,
        member: &MemberId,
    ) -> Option<u32> {
        storage
            .kept_removals(circle)
            .expect("read")
            .into_iter()
            .find(|kept| &kept.member == member)
            .map(|kept| kept.asks)
    }

    /// Any withdrawal brings back every member an applied commit took out —
    /// with the ask the circle owes them only for the one keyed to the commit
    /// withdrawn; one taken out with no commit named comes back held and
    /// told, its asks spent, never to be removed unattended (decision 227).
    #[tokio::test]
    async fn a_withdrawal_brings_back_every_target_and_spends_the_asks_of_those_it_cannot_key() {
        let (_dir, storage, session) = session_over_a_store();
        let circle = GroupId::new(vec![0x4c; 32]);
        let (keyed, unkeyed) = (MemberId::new(vec![0x11; 32]), MemberId::new(vec![0x22; 32]));
        let commit = MessageId::new(vec![0x33; 32]);
        assert!(
            storage.note(&circle, ChangeNote::QueuedRemovalDropped)
                && storage.keep_removal_targets(&circle, &[keyed.clone(), unkeyed.clone()], 3, 0)
        );
        let held = session.reading().await;
        session.note_batch(
            &held,
            &[
                taken_out(&circle, &keyed, 4, Some(&commit)),
                taken_out(&circle, &unkeyed, 4, None),
            ],
        );
        assert!(
            storage
                .removal_targets(&circle)
                .is_some_and(|held| held.is_empty())
                && !storage
                    .peek(&circle)
                    .contains(&ChangeNote::QueuedRemovalDropped),
            "premise: both were taken out, and the hold and its note ended",
        );
        session.note_batch(&held, &[withdrawn(&circle, &commit)]);
        drop(held);
        assert!(
            storage
                .removal_targets(&circle)
                .is_some_and(|held| held.len() == 2)
                && storage
                    .peek(&circle)
                    .contains(&ChangeNote::QueuedRemovalDropped)
                && asks_of(&storage, &circle, &keyed) == Some(0)
                && asks_of(&storage, &circle, &unkeyed) == Some(MAX_REQUEUE_ATTEMPTS),
            "a withdrawal did not bring back every member taken out, or did not say so, or \
             spent the asks of the one keyed to it, or kept those of one it cannot key",
        );
    }

    /// A pass that accepted more than one commit — the epochs it moved and
    /// the commits it rewound number two or more — spends the asks of every
    /// target that holds: the membership it announces is a net change, which
    /// can hide a member removed and invited back. A pass of one commit
    /// spends nothing.
    #[tokio::test]
    async fn a_pass_of_several_commits_spends_every_held_targets_asks() {
        let (_dir, storage, session) = session_over_a_store();
        let member = MemberId::new(vec![0x11; 32]);
        let circles: Vec<GroupId> = (1..=4).map(|seed| GroupId::new(vec![seed; 32])).collect();
        for circle in &circles {
            assert!(storage.keep_removal_targets(circle, std::slice::from_ref(&member), 3, 0));
        }
        let other = MessageId::new(vec![0x44; 32]);
        let held = session.reading().await;
        session.note_batch(&held, &[moved(&circles[0], 4, 6)]);
        session.note_batch(
            &held,
            &[moved(&circles[1], 4, 5), withdrawn(&circles[1], &other)],
        );
        session.note_batch(&held, &[moved(&circles[2], 4, 5)]);
        session.note_batch(&held, &[moved(&circles[3], 4, 5), moved(&circles[3], 5, 6)]);
        drop(held);
        assert!(
            asks_of(&storage, &circles[0], &member) == Some(MAX_REQUEUE_ATTEMPTS)
                && asks_of(&storage, &circles[1], &member) == Some(MAX_REQUEUE_ATTEMPTS),
            "a pass of several commits — two epochs, or one epoch and a rewound commit — left \
             a held target's asks unspent",
        );
        assert!(
            asks_of(&storage, &circles[2], &member) == Some(0)
                && asks_of(&storage, &circles[3], &member) == Some(0),
            "a pass of one commit, or two passes of one commit each, spent an ask",
        );
    }

    /// This device's own removal X took a member out, keyed. A pass of
    /// several commits sets X aside — the co-admin's removal of the same
    /// member and their invitation back, announced as a net diff that names
    /// nobody — and brings the member back keyed to X in the same batch.
    /// The spend runs after that bring-back, so the member comes back with
    /// their asks spent and is never removed again unattended (decision
    /// 230).
    #[tokio::test]
    async fn a_member_brought_back_by_the_pass_that_spends_is_spent_with_the_rest() {
        let (_dir, storage, session) = session_over_a_store();
        let circle = GroupId::new(vec![0x4c; 32]);
        let member = MemberId::new(vec![0x11; 32]);
        let own = MessageId::new(vec![0x33; 32]);
        assert!(storage.keep_removal_targets(&circle, std::slice::from_ref(&member), 3, 1));
        let held = session.reading().await;
        session.note_batch(&held, &[taken_out(&circle, &member, 4, Some(&own))]);
        session.note_batch(&held, &[moved(&circle, 4, 5), withdrawn(&circle, &own)]);
        drop(held);
        assert_eq!(
            asks_of(&storage, &circle, &member),
            Some(MAX_REQUEUE_ATTEMPTS),
            "a member the pass of several commits brought back kept an ask",
        );
        assert_eq!(
            storage.removal_targets(&circle),
            Some(vec![member]),
            "the member brought back does not hold the circle",
        );
    }

    /// An applied commit that adds a kept target — a re-invite by anyone, in
    /// any batch, on any plane — spends that target's asks, held or taken
    /// out, and no other's: the circle chose to keep them (decision 230).
    #[tokio::test]
    async fn a_target_any_applied_commit_adds_is_never_asked_for_again() {
        let (_dir, storage, session) = session_over_a_store();
        let circle = GroupId::new(vec![0x4c; 32]);
        let (added, other, gone) = (
            MemberId::new(vec![0x11; 32]),
            MemberId::new(vec![0x22; 32]),
            MemberId::new(vec![0x33; 32]),
        );
        assert!(storage.keep_removal_targets(
            &circle,
            &[added.clone(), other.clone(), gone.clone()],
            3,
            1
        ));
        let keyed = MessageId::new(vec![0x44; 32]);
        let held = session.reading().await;
        session.note_batch(&held, &[taken_out(&circle, &gone, 4, Some(&keyed))]);
        let added_event = |member: &MemberId| GroupEvent::GroupStateChanged {
            group_id: circle.clone(),
            epoch: EpochId(5),
            actor: None,
            change: GroupStateChange::MemberAdded {
                member: member.clone(),
            },
            origin_commit_id: None,
        };
        session.note_batch(&held, &[added_event(&added), added_event(&gone)]);
        // Brought back keyed to its own commit, a target keeps the asks it
        // held when it went: the add's spend shows here.
        session.note_batch(&held, &[withdrawn(&circle, &keyed)]);
        drop(held);
        assert!(
            asks_of(&storage, &circle, &added) == Some(MAX_REQUEUE_ATTEMPTS)
                && asks_of(&storage, &circle, &gone) == Some(MAX_REQUEUE_ATTEMPTS),
            "a target an applied commit added kept an ask",
        );
        assert_eq!(
            asks_of(&storage, &circle, &other),
            Some(1),
            "another target's ask was spent"
        );
    }

    /// A change MDK queued again counts as released only into a record that
    /// carries it: one no record carries — retired as moot, or never staged
    /// — is not "released", and neither is one the store cannot list.
    #[tokio::test]
    async fn a_change_no_record_carries_is_never_said_to_be_released() {
        let (_dir, _storage, session) = session_over_a_store();
        let circle = GroupId::new(vec![0x4c; 32]);
        let intent = SendIntent::SelfUpdate {
            group_id: circle.clone(),
        };
        assert!(!session.released_into_record(&circle, &intent, &[]).await);
    }

    /// A reorg deeper than the rewind horizon past its own tip still brings
    /// back what it undid: what is forgotten is measured from the tip before
    /// the pass, not the one it reached, and the pass announces its
    /// withdrawals after its epoch change.
    #[tokio::test]
    async fn a_deep_reorg_brings_back_a_target_before_anything_forgets_it() {
        let (_dir, storage, session) = session_over_a_store();
        let circle = GroupId::new(vec![0x4c; 32]);
        let member = MemberId::new(vec![0x11; 32]);
        let commit = MessageId::new(vec![0x33; 32]);
        assert!(storage.keep_removal_targets(&circle, std::slice::from_ref(&member), 3, 0));
        let rewind = max_rewind_commits();
        let held = session.reading().await;
        session.note_batch(&held, &[taken_out(&circle, &member, 11, Some(&commit))]);
        session.note_batch(
            &held,
            &[
                moved(&circle, 11 + rewind - 1, 11 + rewind + 2),
                withdrawn(&circle, &commit),
            ],
        );
        drop(held);
        assert!(
            storage.removal_targets(&circle) == Some(vec![member.clone()]),
            "a reorg past the horizon from the tip it reached forgot a target before its \
             withdrawal could bring it back",
        );
    }

    /// An object the engine lets go for want of room is owed its refetch
    /// (Security Rule 12) whoever handed it to the engine: one Haven had
    /// handed back, and still keeps a copy of, like any other. Nothing
    /// Haven keeps suppresses the refetch, and the refusal ends no entry.
    #[tokio::test]
    async fn an_event_the_engine_lets_go_is_owed_its_refetch_whether_or_not_haven_handed_it_back() {
        use crate::nostr::mls::kept_input::KeptInput as _;
        use crate::nostr::mls::types::InboundResourceLimit;

        let dir = tempfile::TempDir::new().expect("temp dir");
        let storage = Arc::new(crate::circle::CircleStorage::in_memory().expect("store"));
        let session = SessionManager::new_unencrypted_with_notes(
            dir.path(),
            &Keys::generate(),
            Some(storage.clone()),
        )
        .expect("session");
        let circle = GroupId::new(vec![0x4c; 32]);
        let handed_back = MessageId::new(vec![0x11; 32]);
        let other = MessageId::new(vec![0x22; 32]);
        assert!(storage.keep(&circle, &handed_back, false, "{}"));
        let refusal = |id: &MessageId| GroupEvent::TransportObjectResourceRefused {
            group_id: circle.clone(),
            message_id: id.clone(),
            resource: InboundResourceLimit::TransportDeferredCapacity,
        };

        let held = session.reading().await;
        session.note_batch(&held, &[refusal(&handed_back), refusal(&other)]);
        drop(held);
        // `assert!`, not `assert_eq!`: an id is never formatted (Security Rule 15).
        let owed = session.refused_redeliveries(&circle, 8);
        assert!(
            owed.len() == 2
                && [&handed_back, &other]
                    .iter()
                    .all(|id| owed
                        .contains(&nostr::EventId::from_slice(id.as_slice()).expect("an id"))),
            "an object the engine let go was not owed its refetch",
        );
        assert!(
            storage.kept(&circle).expect("read").len() == 1,
            "a refusal ended an entry Haven keeps",
        );
    }

    #[test]
    fn a_bare_sessions_refused_id_backs_off_and_is_never_forgotten() {
        super::super::ledger_test_support::assert_a_refused_id_backs_off_and_is_never_forgotten(
            &InMemoryRefusedLedger::default(),
        );
    }

    #[test]
    fn a_bare_sessions_wholesale_refusal_makes_only_the_asked_wait() {
        super::super::ledger_test_support::assert_a_wholesale_refusal_makes_only_the_asked_wait(
            &InMemoryRefusedLedger::default(),
        );
    }

    #[test]
    fn a_bare_sessions_ledger_lets_no_id_be_minted_to_the_front_of_the_queue() {
        super::super::ledger_test_support::assert_no_id_can_be_minted_to_the_front_of_the_queue(
            &InMemoryRefusedLedger::default(),
        );
    }

    #[test]
    fn a_bare_sessions_ledger_leaves_nothing_waiting_on_a_clock_stepped_back() {
        super::super::ledger_test_support::assert_a_clock_stepped_back_leaves_nothing_waiting(
            &InMemoryRefusedLedger::default(),
        );
    }

    #[test]
    fn a_bare_sessions_owed_range_keeps_its_own_schedule() {
        super::super::ledger_test_support::assert_the_owed_range_keeps_its_own_schedule(
            &InMemoryRefusedLedger::default(),
        );
    }

    #[test]
    fn a_bare_sessions_refused_ledger_rotates_caps_and_never_drops_an_owed_id() {
        let ledger = InMemoryRefusedLedger::default();
        let circle = GroupId::new(vec![1; 32]);
        let cap = u16::try_from(MAX_REFUSED_IDS_PER_GROUP).unwrap();

        ledger.record(&circle, &refused_ids(0..3), 100);
        assert_eq!(ledger.owed(&circle, 2, 100), refused_ids(0..2));
        ledger.tried(&circle, &refused_ids(0..2), 200, false);
        assert_eq!(
            ledger.owed(&circle, 2, 200 + REFETCH_SPACING_BASE_SECS)[0],
            refused_ids(2..3)[0],
            "the id that waited longest goes first"
        );

        ledger.record(&circle, &refused_ids(3..cap + 2), 300);
        assert_eq!(
            ledger.owed(&circle, usize::MAX, i64::MAX).len(),
            MAX_REFUSED_IDS_PER_GROUP
        );
        assert!(
            ledger
                .owed_range(&circle)
                .is_some_and(|range| range.until_secs == 300),
            "the overflow is not owed as the history up to its refusal",
        );
        ledger.resolve(&circle, &refused_ids(0..cap));
        assert!(ledger.owed(&circle, usize::MAX, i64::MAX).is_empty());
    }

    #[test]
    fn a_bare_sessions_range_ends_only_when_a_whole_walk_owes_nothing() {
        crate::nostr::mls::ledger_test_support::assert_a_range_ends_only_when_a_whole_walk_owes_nothing(
            &InMemoryRefusedLedger::default(),
        );
    }

    #[test]
    fn a_bare_sessions_ledger_never_lets_a_stale_read_settle_a_later_range() {
        crate::nostr::mls::ledger_test_support::assert_a_stale_read_never_settles_a_later_range(
            &InMemoryRefusedLedger::default(),
        );
    }

    // ── The future-header wire edit is robust against malformed input ─────────

    /// A minimal `PrivateMessage`-shaped MLS wire: version, `WireFormat = 2`, a
    /// 1-byte-prefixed 32-byte group id, an 8-byte epoch, and a content type.
    fn private_message_wire() -> Vec<u8> {
        let mut wire = vec![0x00, 0x01, 0x00, 0x02]; // version 1, wire_format PrivateMessage
        wire.push(0x20); // group_id length 32 (1-byte varint)
        wire.extend_from_slice(&[0u8; 32]); // group_id
        wire.extend_from_slice(&[0u8; 8]); // epoch
        wire.push(0x01); // content_type application
        wire
    }

    #[test]
    fn overwrite_private_message_epoch_edits_the_cleartext_epoch_in_place() {
        let mut wire = private_message_wire();
        overwrite_private_message_epoch(&mut wire, 0x0102_0304_0506_0708)
            .expect("a well-formed PrivateMessage wire edits");
        assert_eq!(
            &wire[37..45],
            &0x0102_0304_0506_0708u64.to_be_bytes(),
            "the epoch must be written at group_id's end, big-endian"
        );
        assert_eq!(wire[45], 0x01, "the content type after it is untouched");
    }

    #[test]
    fn overwrite_private_message_epoch_rejects_a_non_private_wire_format() {
        let mut wire = private_message_wire();
        wire[2..4].copy_from_slice(&1u16.to_be_bytes()); // PublicMessage
        assert!(
            overwrite_private_message_epoch(&mut wire, 9).is_err(),
            "a wire format other than PrivateMessage must be refused, not edited"
        );
    }

    #[test]
    fn overwrite_private_message_epoch_rejects_an_eight_byte_length_prefix() {
        let mut wire = private_message_wire();
        wire[4] = 0xC0; // prefix 0b11 => the 8-byte varint form
        assert!(
            overwrite_private_message_epoch(&mut wire, 9).is_err(),
            "a group id never needs the 8-byte length form; it must be refused"
        );
    }

    #[test]
    fn overwrite_private_message_epoch_rejects_a_wire_truncated_before_its_epoch() {
        let mut wire = private_message_wire();
        wire.truncate(37 + 3); // group id ends at 37; only 3 of 8 epoch bytes remain
        assert!(
            overwrite_private_message_epoch(&mut wire, 9).is_err(),
            "a wire too short to hold the epoch must be refused, never sliced out of bounds"
        );
    }

    #[test]
    fn overwrite_private_message_epoch_rejects_a_wire_shorter_than_its_header() {
        let mut wire = private_message_wire();
        wire.truncate(3); // version and half a wire_format
        assert!(
            overwrite_private_message_epoch(&mut wire, 9).is_err(),
            "a wire with no complete wire_format field must be refused, not read past its end"
        );
    }

    #[test]
    fn overwrite_private_message_epoch_rejects_a_wire_with_no_group_id_length_prefix() {
        let mut wire = private_message_wire();
        wire.truncate(4); // the header alone; the group id's length byte is missing
        assert!(
            overwrite_private_message_epoch(&mut wire, 9).is_err(),
            "a wire that ends where the group id's length should begin must be refused"
        );
    }

    #[test]
    fn overwrite_private_message_epoch_rejects_a_group_id_length_past_the_wire() {
        let mut wire = private_message_wire();
        // A 4-byte prefix (0b10) claiming the largest length the form can carry,
        // then far too few bytes: the epoch offset is computed, not overflowed,
        // and the read past the end is what is refused.
        wire[4] = 0xBF;
        wire[5..8].copy_from_slice(&[0xFF, 0xFF, 0xFF]);
        assert!(
            overwrite_private_message_epoch(&mut wire, 9).is_err(),
            "a group id longer than the wire must be refused, never indexed"
        );
    }

    // ── Gate 2: the epoch-state token match ──────────────────────────────────

    #[test]
    fn every_epoch_state_is_classified_exactly_once() {
        use cgka_traits::engine_state::{PendingStateRef, StagedCommitHandle};

        // Real states, built through the public transition API.
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
        let disbanded = EpochState::disbanded(EpochId(7));

        // An exhaustive match, so a NEW upstream `EpochState` variant breaks
        // compilation here instead of reaching a send unclassified.
        for state in [
            &stable,
            &pending,
            &merging,
            &recovering,
            &unrecoverable,
            &disbanded,
        ] {
            let expected = match state {
                EpochState::Stable { .. } => None,
                EpochState::PendingPublish(_)
                | EpochState::Merging(_)
                | EpochState::Recovering(_) => Some("epoch-not-stable"),
                EpochState::Unrecoverable(_) | EpochState::Disbanded(_) => {
                    Some("epoch-unrecoverable")
                }
            };
            assert_eq!(
                epoch_state_refusal(Some(state))
                    .as_ref()
                    .map(NostrError::code),
                expected,
                "'{}' must be classified as {expected:?}",
                state.name()
            );
        }
        // An unknown group is the send's to report, never guessed at here.
        assert!(epoch_state_refusal(None).is_none());
    }

    #[test]
    fn the_two_published_convergence_bounds_are_the_installed_policys_own() {
        // Haven installs no policy — MDK accepts only its pinned v1 — so both
        // accessors must answer the ENGINE's default. A caller that restated
        // either number would keep agreeing with itself after an engine bump
        // moved it.
        let engine = CanonicalizationPolicy::default();
        assert_eq!(
            app_message_past_epoch_limit(),
            engine.app_message_past_epoch_limit
        );
        assert_eq!(
            max_rewind_commits(),
            engine.convergence.max_rewind_commits,
            "the rewind window must be read from the policy the session installs"
        );
        assert!(
            max_rewind_commits() > 0,
            "a zero rewind window would make a sibling branch unconvergeable, and would make \
             any bound derived from it vacuous"
        );
    }

    #[test]
    fn the_requeue_bound_is_the_number_mdk_bounds_its_own_reissue_by() {
        // Haven's bound, kept at MDK's number: an MDK bump that moves its own
        // turns this red, and the documents that say "the same number" with
        // it.
        assert_eq!(
            MAX_REQUEUE_ATTEMPTS,
            cgka_engine::own_commit_intent::MAX_OWN_COMMIT_REISSUE_ATTEMPTS,
        );
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
            for needle in [
                "PendingPublish",
                "Merging",
                "Recovering",
                "Unrecoverable",
                "Disbanded",
            ] {
                assert!(
                    !rendered.contains(needle),
                    "the surfaced message must not name the epoch state"
                );
            }
        }
    }

    /// Every rendering a log line or an FFI error string makes of a mapped MDK
    /// error: `NostrError`'s own, and `CircleError`'s, which is what the FFI
    /// hands Dart. Panics naming the rendering that carries any `planted` text,
    /// or a hex run of eight or more.
    fn assert_no_mdk_error_sink_carries(mapped: NostrError, planted: &[String]) {
        let mut renders = vec![
            mapped.to_string(),
            format!("{mapped:?}"),
            mapped.code().to_owned(),
        ];
        let surfaced = crate::circle::CircleError::from(mapped);
        renders.extend([surfaced.to_string(), format!("{surfaced:?}")]);
        for rendered in renders {
            for needle in planted {
                assert!(
                    !rendered.contains(needle.as_str()),
                    "{rendered:?} carries {needle:?}"
                );
            }
            let longest_hex_run = rendered
                .split(|c: char| !c.is_ascii_hexdigit())
                .map(str::len)
                .max()
                .unwrap_or(0);
            assert!(longest_hex_run < 8, "{rendered:?} carries a hex run");
        }
    }

    /// Absolute epochs are Rule-15 identifiers, and at this pin MDK prints them
    /// in `Display`: `ForkedEpoch` and `PeelerError::StaleEpoch` do, and
    /// `Backend`/`Other`/`Serialize` and storage failures carry free text that
    /// can quote an epoch beside a group id (#864). None of it may reach a sink.
    #[test]
    fn mdk_errors_reach_no_sink_with_an_epoch() {
        const LAST: u64 = 918_273;
        const CONFLICTING: u64 = 918_274;
        let group = GroupId::new(vec![0xA7; 32]);
        let group_hex = hex::encode(group.as_slice());
        let quoted = format!("group {group_hex} at epoch {LAST}");
        let planted = [
            LAST.to_string(),
            CONFLICTING.to_string(),
            group_hex[..8].to_owned(),
            "167, 167".to_owned(),
        ];
        let stale = || cgka_traits::error::PeelerError::StaleEpoch {
            message_epoch: EpochId(LAST),
            context_epoch: EpochId(CONFLICTING),
        };
        let engine = |e: EngineError| map_mls_err(SessionError::Engine(e));
        for mapped in [
            engine(EngineError::ForkedEpoch {
                group_id: group,
                last_stable: EpochId(LAST),
                conflicting_epoch: EpochId(CONFLICTING),
            }),
            engine(EngineError::Peeler(stale())),
            map_mls_err(stale()),
            engine(EngineError::AppMessageEpochMismatch {
                expected: EpochId(LAST),
                current: EpochId(CONFLICTING),
            }),
            engine(EngineError::AppMessageEpochUnsettled {
                expected: EpochId(LAST),
            }),
            engine(EngineError::Backend(quoted.clone())),
            engine(EngineError::Other(quoted.clone())),
            engine(EngineError::Serialize(quoted.clone())),
            map_mls_err(SessionError::Storage(StorageError::SnapshotMissing(
                quoted.clone(),
            ))),
            map_storage_err(StorageError::Backend(quoted)),
        ] {
            assert_no_mdk_error_sink_carries(mapped, &planted);
        }
    }

    /// `StorageError` has no upstream `privacy_safe_kind` (tracker
    /// T-STORAGE-KIND): every variant must cross as its own fixed code, so a
    /// busy database stays distinguishable from a durable fault, and none may
    /// carry the free text MDK's storage layer puts beside it.
    /// The store-open failure crosses as its storage code alone: the MDK error
    /// behind it names the database path, which carries the user's data
    /// directory (Rule 15).
    #[test]
    fn a_store_open_failure_carries_no_path() {
        let parent = tempfile::TempDir::new().expect("temp dir");
        let dir = parent.path().join("NeedleStoreDirQuux9");
        // A directory where the database file should be: no store can open it.
        std::fs::create_dir_all(StorageConfig::new(&dir).database_path()).expect("plant");
        let Err(err) = SessionManager::new_unencrypted(&dir, &Keys::generate()) else {
            panic!("a directory is not a database");
        };
        let NostrError::StorageError(payload) = &err else {
            panic!("an open failure is a storage error: {err:?}");
        };
        assert!(
            payload.starts_with("storage_") && !payload.contains("Quux9"),
            "only the fixed code crosses: {payload}"
        );
    }

    #[test]
    fn every_storage_error_crosses_as_its_own_fixed_code() {
        let quoted = "group a7a7a7a7a7a7 at epoch 918273".to_owned();
        let variants = [
            StorageError::NotFound,
            StorageError::AlreadyExists,
            StorageError::SnapshotMissing(quoted.clone()),
            StorageError::TimelineCursorExpired,
            StorageError::Busy(quoted.clone()),
            StorageError::Corruption(quoted.clone()),
            StorageError::Capacity(quoted.clone()),
            StorageError::Closed(quoted.clone()),
            StorageError::UnsupportedSchemaVersion {
                found: 918_273,
                latest_supported: 918_272,
            },
            StorageError::Backend(quoted.clone()),
            StorageError::Serialization(quoted),
        ];
        let count = variants.len();
        let mut codes = std::collections::BTreeSet::new();
        for variant in variants {
            let code = variant.kind();
            assert!(code.starts_with("storage_"), "{code}");
            assert!(!code.chars().any(|c| c.is_ascii_digit()), "{code}");
            codes.insert(code);
            assert!(matches!(
                map_mls_err(SessionError::Engine(EngineError::Storage(variant))),
                NostrError::MdkError(engine_code) if engine_code == code
            ));
        }
        assert_eq!(codes.len(), count, "two variants share a code");
    }

    /// A member is a pubkey, and at this pin MDK's `InvalidCredentialIdentity`
    /// quotes free text that can carry one; it may not reach a sink.
    /// `UnknownMember` also holds a member, but its `Display` is the fixed
    /// "member is not in the group" and `map_mls_err` formats only `Display`,
    /// so it has no rendering here that could carry one and is not asserted.
    #[test]
    fn an_mdk_error_naming_a_member_never_formats_the_member() {
        let keys = Keys::generate();
        let member_hex = keys.public_key().to_hex();
        let planted = [member_hex[..8].to_owned()];
        assert_no_mdk_error_sink_carries(
            map_mls_err(SessionError::Engine(
                EngineError::InvalidCredentialIdentity(format!("identity {member_hex}")),
            )),
            &planted,
        );
    }

    /// MDK v0.10.4 rejects an invitee whose `KeyPackage` advertises RFC 9420's
    /// forbidden default capabilities, carrying the invitee's member id.
    #[test]
    fn invalid_key_package_capabilities_never_formats_the_member() {
        let keys = Keys::generate();
        let member_hex = keys.public_key().to_hex();
        let planted = [member_hex[..8].to_owned()];
        let mapped = map_mls_err(SessionError::Engine(
            EngineError::InvalidKeyPackageCapabilities {
                member: MemberId::new(keys.public_key().to_bytes().to_vec()),
            },
        ));
        assert!(
            matches!(
                mapped,
                NostrError::MdkError("invalid_key_package_capabilities")
            ),
            "the typed kind survives the boundary, so a caller can still route on it"
        );
        assert_no_mdk_error_sink_carries(mapped, &planted);
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

    /// The NIP-77 funnel records nothing for a group the engine does not
    /// know, so a relay sending events under made-up routing ids grows no
    /// inventory and no memory; and the screen alone judges nothing: a
    /// refused event is judged only by a plane that fetched it, under that
    /// plane's routing.
    #[tokio::test]
    async fn an_event_for_a_group_nobody_knows_is_not_recorded_for_negentropy() {
        let (manager, dir) = open_manager();
        let route = [0x5a; 32];
        let other = [0x11; 32];
        let stranger = nostr::EventBuilder::new(Kind::Custom(445), "b3BhcXVl")
            .tags([nostr::Tag::parse(["h", &hex::encode(route)]).unwrap()])
            .sign_with_keys(&Keys::generate())
            .unwrap();
        let ingested = manager.process_event(&stranger).await;
        assert!(
            matches!(
                &ingested,
                Ok(ScreenedIngest::Ingested(effects)) if matches!(
                    effects.outcome,
                    IngestOutcome::Ignored {
                        category: cgka_traits::ingest::InputRejectionCategory::UnknownGroup
                    }
                )
            ),
            "premise: the engine knows no such group"
        );
        assert!(!manager.neg_memo().is_resolved(&route, &stranger.id));
        assert!(manager
            .neg_inventory(&route, Timestamp::now().as_secs())
            .await
            .expect("the inventory reads")
            .is_empty());
        let refused = nostr::EventBuilder::new(Kind::Custom(445), "b3BhcXVl")
            .tags([
                nostr::Tag::parse(["h", &hex::encode(route)]).unwrap(),
                nostr::Tag::parse(["h", &hex::encode(other)]).unwrap(),
            ])
            .sign_with_keys(&Keys::generate())
            .unwrap();
        assert!(matches!(
            manager.process_event(&refused).await,
            Ok(ScreenedIngest::RejectedBeforeAuth(_))
        ));
        assert_eq!(
            manager.neg_memo().judged_routings(),
            0,
            "the screen judged an event no plane fetched for a routing"
        );
        manager.neg_judge_refused(&route, &refused);
        let memo = manager.neg_memo();
        assert!(
            memo.is_resolved(&route, &refused.id) && !memo.is_resolved(&other, &refused.id),
            "a refused event is judged under the routing it was fetched for, and no other"
        );
        drop(memo);
        drop(manager);
        let _ = std::fs::remove_dir_all(dir);
    }

    /// An event naming any number of routing ids grows the NIP-77 memory by
    /// one routing at most: the many tags an outsider can sign cost nothing.
    #[test]
    fn an_event_with_many_routing_tags_is_judged_under_one_routing() {
        let (manager, dir) = open_manager();
        let tags: Vec<nostr::Tag> = (0..200u8)
            .map(|seed| nostr::Tag::parse(["h", &hex::encode([seed; 32])]).unwrap())
            .collect();
        let many = nostr::EventBuilder::new(Kind::Custom(445), "bWFueQ")
            .tags(tags)
            .sign_with_keys(&Keys::generate())
            .unwrap();
        manager.neg_judge_refused(&[7; 32], &many);
        assert_eq!(manager.neg_memo().judged_routings(), 1);
        drop(manager);
        let _ = std::fs::remove_dir_all(dir);
    }

    /// The open's recovery is owed once per session; an advance is owed once
    /// per naming, however often a group is named before a plane takes it.
    #[test]
    fn the_open_recovery_is_claimed_once_and_an_owed_advance_is_taken_once_per_naming() {
        let (manager, dir) = open_manager();
        assert!(manager.take_open_recovery(), "a fresh session owes it");
        assert!(
            !manager.take_open_recovery(),
            "a second claim in the same session must be refused"
        );
        let (a, b) = (GroupId::new(vec![0xa1; 32]), GroupId::new(vec![0xb2; 32]));
        assert!(
            manager.take_owed_advance().is_empty(),
            "nothing named, nothing owed"
        );
        manager.owe_advance(&[a.clone(), b.clone()]);
        manager.owe_advance(std::slice::from_ref(&a));
        assert_eq!(
            manager.take_owed_advance(),
            vec![a, b.clone()],
            "a group named twice is owed one advance",
        );
        assert!(
            manager.take_owed_advance().is_empty(),
            "a taken group is owed again only when named again"
        );
        manager.owe_advance(std::slice::from_ref(&b));
        assert_eq!(
            manager.take_owed_advance(),
            vec![b],
            "a group named again is owed again"
        );
        let _ = std::fs::remove_dir_all(&dir);
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
        // `CircleManager::propose_self_demote_staging` refusing to drop the last
        // admin.
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
    async fn the_session_writes_no_forensic_audit_log() {
        // MDK's forensic recorder writes raw group ids and relay URLs; Haven
        // installs none (`check_no_forensic_recorder.sh`), and the session's own
        // getter proves the default no-op recorder is what runs (PLAN §8 V6).
        let dir = temp_dir();
        let manager = SessionManager::new_unencrypted(&dir, &Keys::generate()).expect("open");
        assert!(manager.reading().await.audit_log_path().is_none());
    }

    #[test]
    fn the_session_opens_with_the_pinned_policy() {
        // MDK v0.10.4 refuses to open a session under any convergence policy
        // but its pinned v1 (`ensure_acceptable`, `NotPinnedV1`) — the
        // `settlement_quiescence_ms: 0` Haven installed before the bump would
        // fail every open. The session opens, and the bounds Haven publishes
        // are v1's own constants.
        use cgka_engine::canonicalization::V1_APP_MESSAGE_PAST_EPOCH_LIMIT;
        let dir = temp_dir();
        let keys = Keys::generate();
        SessionManager::new_unencrypted(&dir, &keys)
            .expect("a session opens under the pinned convergence policy");
        assert_eq!(
            app_message_past_epoch_limit(),
            V1_APP_MESSAGE_PAST_EPOCH_LIMIT
        );
        assert_eq!(
            app_message_past_epoch_limit(),
            u64::try_from(DEFAULT_MAX_PAST_EPOCHS).expect("small constant"),
            "Rule 5: the app-message window is the MLS past-epoch window"
        );
        assert_eq!(
            max_rewind_commits(),
            5,
            "Rule 5: convergence policy v1 rewinds 5 commits"
        );
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

    /// A routing component is an advertisement to every member's client, and
    /// other clients dial what it names. Haven never writes a plaintext relay
    /// into one, however the scheme is spelled.
    #[test]
    fn a_routing_component_haven_writes_never_names_a_plaintext_relay() {
        for plaintext in [
            "ws://relay.example",
            "WS://relay.example",
            "ws:relay.example",
        ] {
            assert!(
                routing_of(
                    [0; 32],
                    vec!["wss://relay.example.com".to_string(), plaintext.to_string()]
                )
                .is_err(),
                "a group relay set naming a plaintext relay passed validation",
            );
        }
    }

    /// Nor a relay on a loopback, private or link-local host: other members'
    /// clients would dial it inside their own networks. The refusal names no
    /// host.
    #[test]
    fn a_routing_component_haven_writes_never_names_a_non_public_host() {
        for host in [
            "wss://127.0.0.1",
            "wss://10.0.0.1",
            "wss://192.168.1.1",
            "wss://169.254.169.254",
            "wss://[fe80::1]",
            "wss://[::1]",
            "wss://localhost",
        ] {
            let Err(NostrError::InvalidEvent(text)) = routing_of(
                [0; 32],
                vec!["wss://relay.example.com".to_string(), host.to_string()],
            ) else {
                panic!("a group relay set naming a non-public host passed validation");
            };
            let bare = host.trim_start_matches("wss://");
            assert!(
                !text.contains(bare.trim_matches(['[', ']'])),
                "the refusal names the host",
            );
        }
    }

    #[test]
    fn routing_bounds() {
        assert!(routing_of([0; 32], Vec::new()).is_err());
        assert!(routing_of([0; 32], vec!["wss://relay.example.com".to_string()]).is_ok());
        assert!(routing_of([0; 32], vec!["not a url".to_string()]).is_err());
        let too_many: Vec<String> = (0..17).map(|i| format!("wss://r{i}.example")).collect();
        assert!(routing_of([0; 32], too_many.clone()).is_err());
        assert!(routing_of([0; 32], too_many[..16].to_vec()).is_ok());
        let long = format!("wss://{}.example", "r".repeat(512));
        assert!(routing_of([0; 32], vec![long]).is_err());
    }

    /// The refusal travels as an error string (`CircleError::Mls`), so it says
    /// that the set is too large and never how large (Security Rule 15).
    #[test]
    fn an_oversized_relay_set_is_refused_without_its_count() {
        for count in [17_usize, 23, 119] {
            let relays: Vec<String> = (0..count).map(|i| format!("wss://r{i}.example")).collect();
            let Err(NostrError::InvalidEvent(text)) = routing_of([0; 32], relays) else {
                panic!("an oversized relay set was accepted");
            };
            assert!(
                !text.contains(&count.to_string()),
                "the refusal carries the exact size of the relay set",
            );
        }
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
            message_id: MessageId::new(vec![0x5A; 32]),
            sender: sender.clone(),
            epoch: EpochId(4),
            payload,
            retention: None,
            authority: None,
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
                explicitly_confirmed: false,
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
    fn a_revalidated_group_refreshes_the_circle() {
        // MDK v0.10.4 re-adopts a commit a branch selection had withdrawn
        // (`GroupStateRevalidated`); the circle must refresh exactly as it did
        // for the withdrawal, or its roster stays on the losing branch.
        assert!(matches!(
            SessionManager::location_result_from_event(&GroupEvent::GroupStateRevalidated {
                group_id: GroupId::new(vec![3]),
                epoch: EpochId(4),
                revalidated_commit_id: MessageId::new(vec![0x6B; 32]),
            }),
            Some(LocationMessageResult::GroupUpdate { .. })
        ));
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

    /// MDK's chat kind (`MARMOT_APP_EVENT_KIND_CHAT`), which Haven must never
    /// emit and no longer reads.
    const MDK_CHAT_KIND: u16 = 9;

    #[test]
    fn the_location_rumor_is_minted_at_the_location_kind_and_never_the_chat_kind() {
        let rumor = location_rumor(Keys::generate().public_key(), "{}".to_string());
        assert_eq!(rumor.kind, Kind::Custom(KIND_LOCATION_UPDATE));
        assert_ne!(
            rumor.kind,
            Kind::Custom(MDK_CHAT_KIND),
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
            message_id: MessageId::new(vec![0x5A; 32]),
            sender: MemberId::new(vec![0xAB; 32]),
            epoch: EpochId(4),
            payload: rumor.as_json().into_bytes(),
            retention: None,
            authority: None,
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
    fn a_pre_cutover_kind_9_rumor_is_no_longer_folded_as_a_location() {
        // What v0.1.11 / v0.1.12 put in the tunnel: kind 9 WITH the
        // `["t","location"]` hashtag. Those builds pin MDK v0.9.x and cannot
        // decrypt a v0.10.4 group at all, so the transitional arm that kept
        // them on the map is gone — and with it the one sender-forgeable pair
        // (any client lifting `#location` into a `t` tag) the gate admitted.
        let payload = location_payload();
        let rumor = nostr::EventBuilder::new(Kind::Custom(MDK_CHAT_KIND), payload)
            .tags([Tag::hashtag("location")])
            .build(Keys::generate().public_key());
        let content = folded_location_content(&rumor);
        assert!(
            content.is_empty() && !parses_as_a_marker(&content),
            "kind 9 wearing the old hashtag must carry no content out of the gate"
        );
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
        // Including under the chat kind: that is a White Noise chat message,
        // not a Haven rumor.
        let chat = nostr::EventBuilder::new(Kind::Custom(MDK_CHAT_KIND), payload).build(sender);
        assert!(folded_location_content(&chat).is_empty());
    }

    #[test]
    fn a_foreign_kind_carrying_the_location_hashtag_is_not_a_location() {
        // The hashtag qualifies NOTHING: read at all, it would restore the exact
        // hole the kind gate closes — one sender-chosen tag admitting any
        // authenticated inner event to the map.
        let payload = location_payload();
        let sender = Keys::generate().public_key();
        for kind in [MDK_CHAT_KIND, 7u16, 1210, 25443] {
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
             parse may reject before authentication"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
