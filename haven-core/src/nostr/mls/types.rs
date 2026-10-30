//! Shared types for the Marmot "Dark Matter" MLS integration.
//!
//! This module re-exports the value types Haven's MLS surface needs from the
//! Dark Matter crate set (`cgka-traits` / `cgka-session`) and defines the
//! Haven-local location wrappers.
//!
//! # `GroupId` compatibility shim
//!
//! The Dark Matter [`GroupId`] (`cgka_traits::types::GroupId`) constructs from
//! bytes via `GroupId::new(bytes)` and reads via `as_slice()` / `into_bytes()`
//! — it does **not** expose the old MDK `from_slice` / `to_vec` pair. Haven has
//! many `GroupId::from_slice(&bytes)` call sites (circle storage, tests), so
//! [`GroupIdExt`] restores `from_slice` as an extension over the new type. The
//! byte contract is identical; bring [`GroupIdExt`] into scope to use it.

// ── Dark Matter re-exports (the DM-3 consumer surface) ───────────────────────
pub use cgka_engine::openmls_projection::OpenMlsContentKind;
pub use cgka_session::{
    CreateGroupEffects, IngestEffects, PublishWork, QueuedIntentRef, SessionEffects,
};
pub use cgka_traits::app_components::{AppComponentData, ACCOUNT_IDENTITY_PROOF_COMPONENT_ID};
pub use cgka_traits::engine::{
    CreateGroupRequest, GroupEvent, GroupStateChange, KeyPackage, KeyPackageSource, SendIntent,
    WelcomeMetadata,
};
pub use cgka_traits::engine_state::{EpochState, PendingStateRef};
pub use cgka_traits::group::{Group as MlsGroup, Member as MlsMember, ProtocolProfile};
pub use cgka_traits::ingest::{
    DeferralLineage, InboundResourceLimit, IngestOutcome, InputRejectionCategory, LocalIngestState,
    ProposalRejectionCategory, StaleReason,
};
pub use cgka_traits::message::{MessageRecord, MessageState};
pub use cgka_traits::transport::TransportMessage;
pub use cgka_traits::types::{EpochId, GroupId, MemberId, MessageId};
pub use cgka_traits::{
    FanoutTargetStatus, TransportEndpointFailureKind, TransportEndpointRejectionCategory,
};
pub use nostr::Event;

// ── Typed engine errors — MATCHED, NEVER FORMATTED ───────────────────────────
//
// Gated because these two are the one pair of Dark Matter types whose own
// renderings are Rule-15 identifiers: `EngineError::ForkedEpoch`'s derived
// `Debug` prints a real MLS group id, and its `#[error(…)]` Display prints two
// ABSOLUTE epochs. Production never sees them — every shipped path flattens
// through `map_mls_err`, which is and stays the redaction boundary. They exist
// here for exactly one consumer, `SessionManager::process_event_typed_for_test`,
// whose caller classifies an undecryptable event by MATCHING the variant.
//
// The consuming rule, which is not negotiable: match, never format. No `{:?}`,
// no `{e:?}`, no `.unwrap()`/`.expect()` on a `Result<_, SessionError>`, no
// `assert!(…, "{e}")` — a classification may carry only a value-free verdict.
#[cfg(any(test, feature = "test-utils"))]
pub use cgka_session::SessionError;
#[cfg(any(test, feature = "test-utils"))]
pub use cgka_traits::error::EngineError;

use cgka_traits::{FanoutMlsState, OutboundFanout, TransportEndpointFailure};

use crate::log_alias::{self, LogAliasClass};
use crate::nostr::NostrError;

// ── Haven-local ingest screening ─────────────────────────────────────────────

/// Why Haven's own receiver-side screen rejected an inbound event BEFORE the
/// MLS engine ever saw it.
///
/// Fieldless (`Copy`) — carries no timestamp, event id, group id, or ciphertext,
/// so its derived `Debug` is leak-free by construction (Security Rules 4/6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum PreAuthRejection {
    /// The PURE, pre-engine screen refused the event: it is not group traffic
    /// (any kind but 445 — a Welcome enters only through `accept_welcome`), or
    /// it could not be converted into a transport message
    /// ([`SessionManager::event_to_transport_message`](crate::nostr::mls::SessionManager::event_to_transport_message)):
    /// a missing, duplicated, valueless or wrong-width `h`/`p` routing tag, an
    /// unsupported kind, or a self-reported id that does not match the event's
    /// own hash.
    ///
    /// That screen reads only already-materialized envelope fields. It never
    /// touches key material, never looks at the base64 `content`, and never
    /// reaches the engine — so a failure here says how the event was *signed*,
    /// decided before anything authenticated anything.
    ///
    /// **Only that screen may produce this.** An engine-side or
    /// decryption-side failure MUST stay an `Err`: reclassifying it here would
    /// convert a hold into a skip for input that has already touched secrets,
    /// which is precisely the primitive the cursor design exists to deny (see
    /// [`ScreenedIngest::RejectedBeforeAuth`]).
    Malformed,
}

/// The disposition of one inbound Nostr event handed to
/// [`crate::nostr::mls::SessionManager::process_event`].
///
/// # Why this type exists
///
/// [`IngestOutcome`] and [`StaleReason`] are re-exported straight from the
/// upstream `cgka-traits` crate, so Haven cannot add a variant to either to
/// signal "my own local policy dropped this before the engine ran". Folding a
/// local drop into one of the engine's own outcomes is exactly the bug this type
/// removes: `Stale` means *the engine looked at the message and terminally
/// handled it*, which every receive plane reads as "safe to advance my sync
/// cursor past this event". A locally screened event has been AUTHENTICATED BY
/// NOTHING — not its signature, not its ephemeral author, not its ciphertext —
/// so its `created_at` is entirely attacker-chosen and must never become a
/// persisted cursor value.
///
/// Splitting the two dispositions into distinct variants makes the compiler,
/// not a code reviewer, responsible for every call site: there is no field to
/// forget to read and no default that means "advance".
pub enum ScreenedIngest {
    /// The event reached the engine. The carried [`IngestEffects`] holds the
    /// engine's own [`IngestOutcome`] (`Processed` / `Stale` / `Buffered`) and
    /// any drained events or publish work; the caller's normal cursor rules
    /// apply.
    Ingested(IngestEffects),
    /// Haven's local receiver-side screen rejected the event before any MLS
    /// authentication ran.
    ///
    /// Terminal — do not retry, do not surface, do not drain convergence — but
    /// **not evidence about the event**, in EITHER direction. Callers MUST NOT
    /// advance a sync cursor to (or past) this event's `created_at`: one forged
    /// event would otherwise push the persisted REQ floor forward and strand
    /// every legitimate event below it, permanently and across restarts. Nor may
    /// they hold a cursor back at it: there is no un-applied message to come
    /// back for, and a hold-back is the same denial bought from the other end —
    /// one forged event, minted for free by any observer of the circle's public
    /// `#h`, pinning the window open indefinitely.
    RejectedBeforeAuth(PreAuthRejection),
}

impl ScreenedIngest {
    /// The engine's [`IngestEffects`], or `None` when the local pre-auth screen
    /// rejected the event.
    ///
    /// Deliberately an [`Option`] and not a defaulting accessor: a caller that
    /// ignores the `None` arm loses the effects (fails safe) instead of
    /// inheriting a synthetic "engine said stale" (fails open).
    #[must_use]
    pub fn ingested(self) -> Option<IngestEffects> {
        match self {
            Self::Ingested(effects) => Some(effects),
            Self::RejectedBeforeAuth(_) => None,
        }
    }
}

// Presence-only: never prints the drained `GroupEvent`s (decrypted inner
// locations) or the publish work (whose `h` tag carries the `nostr_group_id`).
/// Whether a fetched `KeyPackage` event can be invited
/// ([`SessionManager::key_package_admission`](crate::nostr::mls::SessionManager::key_package_admission)).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyPackageAdmission {
    /// It passes MDK's admission check for the target (a new circle, or the
    /// named existing one).
    Admissible,
    /// It is a pre-migration package — a kind-443, or a Legacy-profile 30443:
    /// the person needs to update Haven before they can be invited.
    NeedsUpdate,
    /// It fails admission for any other reason (expired, missing a required
    /// capability, malformed).
    Unusable,
}

/// What a `KeyPackage` must be to be invited into one target: a new Haven
/// circle, or one existing circle.
///
/// MDK's own admission snapshot (`KeyPackageRequirements`, v0.10.4
/// `cgka-engine/src/key_package.rs:192-221`, "used to filter discovery
/// candidates before ranking"), read once by
/// [`SessionManager::key_package_admission_rule`](crate::nostr::mls::SessionManager::key_package_admission_rule).
///
/// `Debug` is hand-written: no MDK value is formatted (Security Rule 15).
#[derive(Clone)]
pub struct KeyPackageAdmissionRule(pub(crate) cgka_engine::key_package::KeyPackageRequirements);

impl KeyPackageAdmissionRule {
    /// Whether `package` passes MDK's admission check for the target:
    /// identity, lifetime, profile, ciphersuite and every capability the
    /// target requires. MDK's refusal carries a capability list and free
    /// text, so only the verdict leaves here.
    #[must_use]
    pub fn admits(&self, package: &KeyPackage) -> bool {
        self.0.validate(package).is_ok()
    }
}

impl std::fmt::Debug for KeyPackageAdmissionRule {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KeyPackageAdmissionRule")
            .finish_non_exhaustive()
    }
}

/// What accepting a held Welcome did
/// ([`SessionManager::accept_welcome`](crate::nostr::mls::SessionManager::accept_welcome)).
pub enum WelcomeAcceptance {
    /// The engine ingested it; the effects carry `GroupJoined` when it joined.
    Ingested(IngestEffects),
    /// The Welcome can never be processed on this device — its `KeyPackage`'s
    /// private bundle is gone, it is invalid, misaddressed or already
    /// processed: every `IngestOutcome::Ignored` MDK answers a Welcome with.
    /// Only a new invitation can add this device.
    NeedsNewInvite,
    /// The Welcome would replace a group this device still holds — a removal
    /// it never saw, or a fork — which MDK applies only on the user's explicit
    /// confirmation (`LocalIngestState::RejoinConfirmationRequired`).
    RejoinConfirmationRequired,
    /// This device already processed this Welcome and still holds the group it
    /// joined live: an earlier accept whose circle rows never committed. The
    /// effects carry whatever the engine handed back with the answer.
    AlreadyJoined {
        /// The group the earlier accept joined.
        group_id: GroupId,
        /// The batch the answer came with.
        effects: SessionEffects,
    },
}

/// The effects carry the joined group's id and its first events, so they never
/// render (Rule 15).
impl std::fmt::Debug for WelcomeAcceptance {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Ingested(_) => f.debug_tuple("Ingested").field(&"<redacted>").finish(),
            Self::NeedsNewInvite => f.write_str("NeedsNewInvite"),
            Self::RejoinConfirmationRequired => f.write_str("RejoinConfirmationRequired"),
            Self::AlreadyJoined { .. } => f.write_str("AlreadyJoined { .. }"),
        }
    }
}

impl std::fmt::Debug for ScreenedIngest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Ingested(_) => f.debug_tuple("Ingested").field(&"<redacted>").finish(),
            Self::RejectedBeforeAuth(reason) => {
                f.debug_tuple("RejectedBeforeAuth").field(reason).finish()
            }
        }
    }
}

/// A group's roster plus the verdict on whether it may be persisted.
///
/// Produced by
/// [`SessionManager::converged_member_pubkeys`](crate::nostr::mls::SessionManager::converged_member_pubkeys).
///
/// Deliberately three variants rather than `Option<Vec<String>>`, because the
/// two non-roster cases are opposite caller obligations: a group whose commit is
/// still in flight invalidates the WHOLE read (its roster is the engine's
/// optimistic projection, and a union built from it would record people who may
/// never become members), while a group the engine simply does not hold is
/// nothing to read and must be skipped. Collapsing them costs either a silently
/// wrong union or a reconcile that never runs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ConvergedRoster {
    /// The group is settled — the stored and projected epochs agree and no
    /// resolvable convergence input is outstanding — and this is its roster.
    Converged {
        /// `Member.id` (the Nostr identity key) hex-encoded, lowercase. Never
        /// `Member.credential`, which is the MLS leaf SIGNATURE key: upstream's
        /// own field doc calls `id` the "signature public key", but
        /// `marmot_members` fills `id` from `basic.identity()` and `credential`
        /// from `m.signature_key` (`cgka-engine/src/group_lifecycle.rs:946-951`).
        member_pubkeys_hex: Vec<String>,
        /// Whether THIS device has been removed from the group and the removal
        /// is still canonical. The listed people are then former co-members, not
        /// current ones — the flag clears on an authenticated re-join, or when
        /// branch selection supersedes the removal that set it.
        removed: bool,
    },
    /// A commit is staged, in flight, or buffered: any roster read now is the
    /// engine's optimistic post-merge projection, not applied state.
    NotConverged,
    /// The engine holds no live group under this id — never seen, deleted, or
    /// quarantined at session-open hydration (which is deliberately
    /// indistinguishable from unknown on every accessor).
    Absent,
}

/// Extension trait restoring the old MDK `GroupId::from_slice` constructor over
/// the Dark Matter [`GroupId`].
///
/// The new engine names the constructor `GroupId::new`; Haven's persistence and
/// test code call `GroupId::from_slice`. This trait maps one to the other with
/// no change in the byte contract. `GroupId::as_slice()` and `into_bytes()`
/// already exist natively, so only the constructor needs a shim.
pub trait GroupIdExt {
    /// Builds a [`GroupId`] from a byte slice (alias for `GroupId::new`).
    #[must_use]
    fn from_slice(bytes: &[u8]) -> Self;
}

impl GroupIdExt for GroupId {
    fn from_slice(bytes: &[u8]) -> Self {
        Self::new(bytes.to_vec())
    }
}

/// Configuration for creating a location sharing group.
///
/// This is a simplified configuration focused on location sharing use cases.
/// The name/description become the group's `marmot.group.profile.v1` component,
/// the relays become the `marmot.transport.nostr.routing.v1` component, and the
/// admins bootstrap the group's initial admin set (the creator is always an
/// admin implicitly).
#[derive(Debug, Clone)]
pub struct LocationGroupConfig {
    /// Name of the family/group (e.g., "Smith Family")
    pub name: String,
    /// Optional description
    pub description: String,
    /// Relay URLs for the group
    pub relays: Vec<String>,
    /// Admin public keys (hex-encoded)
    pub admins: Vec<String>,
}

impl LocationGroupConfig {
    /// Creates a new location group configuration.
    ///
    /// # Example
    ///
    /// ```
    /// use haven_core::nostr::mls::types::LocationGroupConfig;
    ///
    /// let config = LocationGroupConfig::new("Smith Family")
    ///     .with_description("Our family location sharing group")
    ///     .with_relay("wss://relay.example.com");
    /// ```
    #[must_use]
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            description: String::new(),
            relays: Vec::new(),
            admins: Vec::new(),
        }
    }

    /// Sets the group description.
    #[must_use]
    pub fn with_description(mut self, description: impl Into<String>) -> Self {
        self.description = description.into();
        self
    }

    /// Adds a relay URL.
    #[must_use]
    pub fn with_relay(mut self, relay: impl Into<String>) -> Self {
        self.relays.push(relay.into());
        self
    }

    /// Adds multiple relay URLs.
    #[must_use]
    pub fn with_relays(mut self, relays: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.relays.extend(relays.into_iter().map(Into::into));
        self
    }

    /// Adds an admin public key (hex-encoded).
    #[must_use]
    pub fn with_admin(mut self, admin_pubkey: impl Into<String>) -> Self {
        self.admins.push(admin_pubkey.into());
        self
    }
}

/// Information about a joined or created group.
///
/// A simplified, redaction-safe view of the group state suitable for the
/// location sharing use case. The `nostr_group_id` here is the transport
/// routing id (from the `marmot.transport.nostr.routing.v1` component), never
/// the real MLS `GroupId`.
#[derive(Clone)]
pub struct LocationGroupInfo {
    /// The MLS group ID (used for engine operations)
    pub mls_group_id: GroupId,
    /// The Nostr group ID (used in h-tags for relay routing)
    pub nostr_group_id: String,
    /// Group name
    pub name: String,
    /// Group description
    pub description: String,
    /// Current epoch number (for forward secrecy tracking)
    pub epoch: u64,
}

impl std::fmt::Debug for LocationGroupInfo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Name and description are user-authored text, the `nostr_group_id` is
        // the circle's public routing handle, and an absolute epoch pins how far
        // this circle has evolved — none of the four may render (Rule 15).
        f.debug_struct("LocationGroupInfo")
            .field("mls_group_id", &"<redacted>")
            .field(
                "circle",
                &log_alias::alias(LogAliasClass::Circle, self.nostr_group_id.as_bytes()),
            )
            .field("name", &"<redacted>")
            .field("description", &"<redacted>")
            .field("epoch", &"<redacted>")
            .finish()
    }
}

/// Result of interpreting an ordered engine [`GroupEvent`] for the location
/// sharing use case.
///
/// The Dark Matter engine emits a rich `GroupEvent` stream from `ingest` /
/// `advance_convergence`; Haven folds the location-relevant subset into this
/// enum. Unlike the old `MessageProcessingResult`-derived taxonomy, stale /
/// duplicate / out-of-order handling is entirely engine-internal (surfaced as
/// [`IngestOutcome::Stale`] / [`IngestOutcome::Buffered`] on the ingest call),
/// so this type carries only application-visible outcomes.
pub enum LocationMessageResult {
    /// A decrypted inner application message (a location update).
    Location {
        /// The sender's public key (hex-encoded, from the MLS-authenticated
        /// member id).
        sender_pubkey: String,
        /// The decrypted inner content (the location JSON payload).
        content: String,
        /// The MLS group ID this message belongs to.
        group_id: GroupId,
        /// The MLS epoch the message was authenticated at.
        epoch: u64,
    },
    /// The local client joined a group via an accepted welcome.
    Joined {
        /// The MLS group ID that was joined.
        group_id: GroupId,
    },
    /// A durable, MLS-authenticated change to group state (membership, admin,
    /// rename, retention) or an epoch advance the receiver should react to.
    GroupUpdate {
        /// The MLS group ID that was updated.
        group_id: GroupId,
    },
    /// A previously-surfaced application message or state change was withdrawn
    /// because branch selection superseded the commit that produced it. The
    /// caller must treat the earlier change as if it never happened.
    Invalidated {
        /// The MLS group ID whose prior output was withdrawn.
        group_id: GroupId,
    },
    /// The group entered the unrecoverable state; the UI must block send/mutate.
    Unrecoverable {
        /// The MLS group ID that is now unrecoverable.
        group_id: GroupId,
    },
}

impl LocationMessageResult {
    /// The circle this result is about.
    ///
    /// Exhaustive on purpose: a folded batch is not single-group (the engine's
    /// effect buffers are global), so every consumer that has to name a circle
    /// reads it from the RESULT, and a new variant without one breaks
    /// compilation here instead of silently inheriting an ambient id.
    #[must_use]
    pub const fn group_id(&self) -> &GroupId {
        match self {
            Self::Location { group_id, .. }
            | Self::Joined { group_id }
            | Self::GroupUpdate { group_id }
            | Self::Invalidated { group_id }
            | Self::Unrecoverable { group_id } => group_id,
        }
    }
}

impl std::fmt::Debug for LocationMessageResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            // The epoch goes with the rest: an absolute epoch number tells one
            // circle's history apart from another's (Rule 15).
            Self::Location { .. } => f
                .debug_struct("Location")
                .field("sender_pubkey", &"<redacted>")
                .field("content", &"<redacted>")
                .field("group_id", &"<redacted>")
                .field("epoch", &"<redacted>")
                .finish(),
            Self::Joined { .. } => f
                .debug_struct("Joined")
                .field("group_id", &"<redacted>")
                .finish(),
            Self::GroupUpdate { .. } => f
                .debug_struct("GroupUpdate")
                .field("group_id", &"<redacted>")
                .finish(),
            Self::Invalidated { .. } => f
                .debug_struct("Invalidated")
                .field("group_id", &"<redacted>")
                .finish(),
            Self::Unrecoverable { .. } => f
                .debug_struct("Unrecoverable")
                .field("group_id", &"<redacted>")
                .finish(),
        }
    }
}

// ── Stored-row probe (test-only) ─────────────────────────────────────────────

/// The two fields of a stored message row a test may read — and nothing else.
///
/// A deliberate projection of `MessageRecord`, never the record: the record also
/// carries the real MLS `group_id` (Security Rule 4) and the `payload`
/// ciphertext, and a caller that holds those can render them. This carries a
/// disposition and an epoch, both of which a caller needs to tell a branch loss
/// (`EpochInvalidated`) from an ordinary past-epoch drop (`Failed`) and to place
/// a row against the epoch that produced it.
///
/// **No `Debug`, deliberately.** `epoch` is an absolute epoch, which Rule 15
/// forbids in any rendering; a consumer reports it as a delta from its own
/// origin or not at all.
#[cfg(any(test, feature = "test-utils"))]
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct StoredMessageProbe {
    /// The epoch column the engine stamped on the row.
    pub epoch: EpochId,
    /// The row's disposition.
    pub state: MessageState,
}

/// One stored row of a circle the engine still means to try again, as a test
/// may read it: [`StoredMessageProbe`]'s two fields and what the row keeps.
///
/// **No `Debug`**, for [`StoredMessageProbe`]'s reason.
#[cfg(any(test, feature = "test-utils"))]
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct HeldRowProbe {
    /// The epoch column the engine stamped on the row.
    pub epoch: EpochId,
    /// The row's disposition.
    pub state: MessageState,
    /// What the row keeps.
    pub keeps: HeldRowKind,
}

/// What a stored row the engine still means to try again keeps.
///
/// **No `Debug`**: one variant carries an MDK value.
#[cfg(any(test, feature = "test-utils"))]
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum HeldRowKind {
    /// The transport bytes as they arrived: nobody opened them.
    Unopened,
    /// An MLS message the engine opened, of this content kind.
    Opened(OpenMlsContentKind),
    /// Anything else: a Welcome, or a payload this build cannot read.
    Other,
}

// ── Stuck convergence inputs (the outbound send gate) ────────────────────────

/// How old a stored convergence input must be before re-delivery can no longer
/// resolve it.
///
/// A kind-445 application message published by a current Haven build carries a
/// NIP-40 `expiration` of `created_at + LOCATION_MESSAGE_RETENTION_SECS`, so a
/// conformant relay has deleted the event by then, and `nostr-relay-pool` drops
/// a copy that is still served before any subscriber sees it; both judge by
/// their own clock, and [`RECEIVER_EXPIRATION_GRACE_SECS`] is the slack Haven
/// adds on top for a relay whose clock runs behind (the pool itself allows
/// none).
///
/// # This is a heuristic about the relay, not a proof about the event
///
/// A relay reads each event's OWN `expiration` tag; this constant reasons from
/// a message's `created_at` and Haven's own retention policy. Another
/// Marmot client in the same circle may declare a LONGER
/// `message-retention.v1` (0x8005), so its 445s can outlive
/// `created_at + 228 s` on a relay and still be redeliverable when this rule
/// calls them unresolvable. The cost of that mismatch is bounded and is not a
/// correctness risk: at worst one peer location update is dropped that could
/// have been re-fetched — the same outcome as any missed publish cycle, healed
/// by the sender's next one. It is emphatically NOT a fork risk, because the
/// rule is only ever applied to application messages, which change no group
/// state (see [`SessionManager::sweep_unresolvable_inputs`]).
///
/// [`RECEIVER_EXPIRATION_GRACE_SECS`]: crate::location::ttl::RECEIVER_EXPIRATION_GRACE_SECS
/// [`SessionManager::sweep_unresolvable_inputs`]: crate::nostr::mls::SessionManager::sweep_unresolvable_inputs
pub const UNRESOLVABLE_INPUT_MAX_AGE_SECS: u64 =
    crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS
        + crate::location::ttl::RECEIVER_EXPIRATION_GRACE_SECS;

/// Whether an event stamped `created_at_secs` is past the point where a relay
/// still holds it, as judged at `now_secs`.
///
/// STRICTLY greater: at precisely [`UNRESOLVABLE_INPUT_MAX_AGE_SECS`] the row is
/// still inside the slack, so the sweep must not have disposed of it yet.
/// Saturating, so a `created_at` in the future is simply never old.
#[must_use]
pub const fn beyond_relay_retention(created_at_secs: u64, now_secs: u64) -> bool {
    now_secs.saturating_sub(created_at_secs) > UNRESOLVABLE_INPUT_MAX_AGE_SECS
}

/// What one pass of
/// [`SessionManager::sweep_unresolvable_inputs`](crate::nostr::mls::SessionManager::sweep_unresolvable_inputs)
/// found and did.
///
/// Counts only — no group ids, message ids, epochs or payloads — so the derived
/// `Debug` is leak-free by construction (Security Rules 4/6/8) and the whole
/// struct can be surfaced to the UI and to logs unredacted.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ConvergenceSweep {
    /// Stored APPLICATION-message rows given the terminal
    /// [`MessageState::Failed`](cgka_traits::message::MessageState) disposition
    /// because the relay can no longer redeliver them.
    pub disposed_messages: usize,
    /// Durably queued outbound location intents deleted. A queued fix is
    /// always stale by the time anything reads it — it is queued only because
    /// the circle could not send — so the next cadence tick's position is
    /// strictly better. Membership intents are never counted here.
    pub discarded_intents: usize,
    /// Rows still gating outbound sends after the pass — the engine's own
    /// `Created`/`Retryable` commit-or-application predicate, mirrored.
    pub gating_rows: usize,
}

impl ConvergenceSweep {
    /// Whether no stored input still gates outbound sends.
    ///
    /// EXACTLY the engine's own `has_unresolved_convergence_inputs` predicate,
    /// negated — same states, same content kinds, same future horizon, and the
    /// same per-group rewind window the engine resolves (stored policy if one
    /// is persisted, else the session's). So `true` here means the next send
    /// will encrypt rather than queue, and it is safe for a UI to say so.
    #[must_use]
    pub const fn is_settled(&self) -> bool {
        self.gating_rows == 0
    }

    /// Accumulates another group's pass into this one.
    pub const fn absorb(&mut self, other: Self) {
        self.disposed_messages += other.disposed_messages;
        self.discarded_intents += other.discarded_intents;
        self.gating_rows += other.gating_rows;
    }
}

// ── Fanout transport values — HELD, NEVER FORMATTED ──────────────────────────
//
// MDK's own `Debug` on these prints a relay URL, free text or a transport
// event id, so each is held behind a wrapper whose `Debug` is hand-written and
// names a closed vocabulary only (Security Rule 15). The matches below carry
// no wildcard arm: a variant MDK adds has to be decided here before it builds.

/// One relay's failure to take a fanout publish, as MDK classified it.
///
/// Wraps `TransportEndpointFailure`: its `endpoint` is a relay URL and its
/// `reason` is free text, so neither is readable through this type. What the
/// relay's own `OK false` blamed on this device's clock is kept beside it,
/// classified, the words gone.
pub struct FanoutEndpointFailure(
    TransportEndpointFailure,
    Option<crate::relay::clock_skew::DeviceClockComplaint>,
);

impl FanoutEndpointFailure {
    pub(crate) const fn new(failure: TransportEndpointFailure) -> Self {
        Self(failure, None)
    }

    /// The same failure, with what the relay blamed on this device's clock.
    pub(crate) fn blaming_the_clock(
        self,
        complaint: Option<crate::relay::clock_skew::DeviceClockComplaint>,
    ) -> Self {
        Self(self.0, complaint)
    }

    /// What the relay's refusal blamed on this device's clock, when it did.
    #[must_use]
    pub const fn clock_blamed(&self) -> Option<crate::relay::clock_skew::DeviceClockComplaint> {
        self.1
    }

    /// MDK's own value, for the stored fanout record that takes nothing else
    /// (`OutboundFanout::record_target_failure`). The ONE way out of the
    /// wrapper: what it returns prints a relay URL and free text, so it goes
    /// to that record and is never formatted.
    pub(crate) fn into_mdk_failure(self) -> TransportEndpointFailure {
        self.0
    }

    /// MDK's exposure-and-retry class: the one field a fanout decision reads.
    #[must_use]
    pub const fn kind(&self) -> TransportEndpointFailureKind {
        self.0.kind
    }

    /// The machine-readable prefix of the relay's `OK false`, when it sent one.
    #[must_use]
    pub const fn rejection_category(&self) -> Option<TransportEndpointRejectionCategory> {
        self.0.rejection_category
    }
}

impl std::fmt::Debug for FanoutEndpointFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let kind = match self.0.kind {
            TransportEndpointFailureKind::TerminalRejected => "TerminalRejected",
            TransportEndpointFailureKind::NotExposed => "NotExposed",
            TransportEndpointFailureKind::PossiblyExposed => "PossiblyExposed",
            TransportEndpointFailureKind::RetryableUnavailable => "RetryableUnavailable",
        };
        let category = self.0.rejection_category.map(|category| match category {
            TransportEndpointRejectionCategory::Duplicate => "duplicate",
            TransportEndpointRejectionCategory::Pow => "pow",
            TransportEndpointRejectionCategory::Blocked => "blocked",
            TransportEndpointRejectionCategory::RateLimited => "rate-limited",
            TransportEndpointRejectionCategory::Invalid => "invalid",
            TransportEndpointRejectionCategory::Error => "error",
            TransportEndpointRejectionCategory::Unsupported => "unsupported",
            TransportEndpointRejectionCategory::AuthRequired => "auth-required",
            TransportEndpointRejectionCategory::Restricted => "restricted",
        });
        f.debug_struct("FanoutEndpointFailure")
            .field("kind", &kind)
            .field("category", &category)
            .finish_non_exhaustive()
    }
}

// ── Durable fanout records — HELD, NEVER FORMATTED ───────────────────────────

/// A handle to one durable fanout row.
///
/// Wraps the MLS group id and the transport message id the row is stored
/// under — the second is the relay-visible event id — so neither is readable
/// or printable through it.
#[derive(Clone, PartialEq, Eq)]
pub struct FanoutId {
    group: GroupId,
    message: MessageId,
}

impl FanoutId {
    pub(crate) const fn new(group: GroupId, message: MessageId) -> Self {
        Self { group, message }
    }

    pub(crate) const fn group(&self) -> &GroupId {
        &self.group
    }

    pub(crate) const fn message(&self) -> &MessageId {
        &self.message
    }
}

impl std::fmt::Debug for FanoutId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("FanoutId(..)")
    }
}

/// One durable fanout: an exact signed event, the relays it was frozen for and
/// where each of them stands.
///
/// Wraps `OutboundFanout`, whose `Debug` prints the event, every relay URL, the
/// group id and each relay's failure text; only its lifecycle renders here.
pub struct StoredFanout(OutboundFanout);

impl StoredFanout {
    pub(crate) const fn new(fanout: OutboundFanout) -> Self {
        Self(fanout)
    }

    /// MDK's own record, for the engine and storage calls that take nothing
    /// else. What it returns prints relay URLs and the signed event, so it is
    /// never formatted.
    pub(crate) const fn as_mdk_fanout(&self) -> &OutboundFanout {
        &self.0
    }

    /// [`Self::as_mdk_fanout`], to record an attempt or an answer.
    pub(crate) const fn as_mdk_fanout_mut(&mut self) -> &mut OutboundFanout {
        &mut self.0
    }

    /// Whether the record says its commit was applied.
    pub(crate) fn applied(&self) -> bool {
        self.0.mls_state() == FanoutMlsState::Confirmed
    }

    /// Whether the record says the engine rolled its commit back.
    pub(crate) fn rolled_back(&self) -> bool {
        self.0.mls_state() == FanoutMlsState::RolledBack
    }
}

impl std::fmt::Debug for StoredFanout {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mls = match self.0.mls_state() {
            FanoutMlsState::NotApplicable => "NotApplicable",
            FanoutMlsState::Pending(_) => "Pending",
            FanoutMlsState::Confirmed => "Confirmed",
            FanoutMlsState::RolledBack => "RolledBack",
        };
        f.debug_struct("StoredFanout")
            .field("mls", &mls)
            .field("complete", &self.0.outcome().fanout_complete)
            .field("possibly_exposed", &self.0.possible_exposure())
            .finish_non_exhaustive()
    }
}

/// What a session call made in staging mode hands back.
///
/// The engine's effects with every commit and every bare proposal taken out
/// of the publish work, and the durable fanout each of them became before the
/// session lock was released.
///
/// **No `Debug`, deliberately**: [`SessionEffects`] is MDK's, and its own
/// rendering prints group ids and events.
/// Which kind of change of this device's branch selection withdrew
/// (MDK's `SupersededIntentKind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WithdrawnKind {
    /// The circle's name or description.
    GroupProfile,
    /// An app component: the relays, the admins, a disband.
    AppComponents,
    /// A removal of members.
    RemoveMembers,
    /// An invite.
    Invite,
}

/// What became of a withdrawn change (MDK's `SupersededIntentOutcome`, and
/// one of Haven's).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WithdrawnOutcome {
    /// Still valid against the circle as it now is: queued again by MDK and
    /// staged under a record by the drive that found it — awaiting its
    /// relays, not yet made.
    Reissued,
    /// Queued again by MDK, and not staged by the drive that found it: the
    /// circle's next full advance makes it, or the queue's retirement says
    /// it was dropped (`ChangeNote::QueuedChangeDropped`).
    Queued,
    /// The winning change touched the same thing; its value stands. The
    /// user has to ask again (`ChangeNote::ChangeWithdrawn`).
    Conflict,
    /// What it asked for is already so — the members it removed are gone.
    AlreadySatisfied,
    /// An invite whose key packages are spent: invite again
    /// (`ChangeNote::ReinviteOwed`).
    ReinviteRequired,
    /// It lost more races than the engine retries, or the queue was full:
    /// the user has to ask again (`ChangeNote::ChangeWithdrawn`; a removal's
    /// targets are kept and hold the circle's sends).
    Abandoned,
    /// This device is no longer in the circle.
    NotMember,
    /// The circle is being left, and the engine sends nothing of it but the
    /// leave: the copy MDK queued again is taken back — not made, and not a
    /// failure.
    RetiredForLeave,
}

/// What a full drive did with a removal set aside unmade (decision 180).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequeueOutcome {
    /// Asked for again for the members still listed, and made.
    Made,
    /// Asked for again, staged under a record, and awaiting its relays: its
    /// record drives it.
    Pending,
    /// Asked for again under a record, and undone before it took effect:
    /// every relay refused it, or the engine set it aside. The ask is spent.
    Undone,
    /// Not staged under a record — the engine would have queued it (taken
    /// back), or the call failed: nothing was sent and no ask is spent.
    NotMade,
    /// Nobody it named is listed any more: already made, the note taken back.
    AlreadyMade,
    /// Asked for again as often as Haven's bound allows
    /// (`MAX_REQUEUE_ATTEMPTS`): not again. Its members stay held and the
    /// note stays for the user.
    Abandoned,
    /// The circle has moved past MDK's rewind horizon since the removal was
    /// set aside: not asked for again, since a removal made that late could
    /// remove someone the circle chose to keep. Its members stay held and
    /// the note stays for the user.
    Expired,
}

/// A removal set aside unmade, and what a full drive did with it. **No
/// `Debug`**: it names its circle.
#[derive(Clone, PartialEq, Eq)]
pub struct RequeuedRemoval {
    /// The circle.
    pub group_id: GroupId,
    /// What became of the removal.
    pub outcome: RequeueOutcome,
}

/// An invite of this device's that MDK holds owed a re-invite.
///
/// Branch selection withdrew it and the key packages it spent cannot be used
/// again (`cgka-engine/src/own_commit_intent.rs` 372-395). **No `Debug`**: it
/// names its circle and its invitees.
#[derive(Clone, PartialEq, Eq)]
pub struct OwedReinvite {
    /// The withdrawn invite's commit: MDK's key for the re-invite.
    pub commit_id: MessageId,
    /// The circle.
    pub group_id: GroupId,
    /// The identities, in hex, it invited and the circle does not list.
    pub invitees: Vec<String>,
    /// Where its circle stands for a re-invite.
    pub standing: ReinviteStanding,
}

/// Where a re-invite's circle stands ([`OwedReinvite`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReinviteStanding {
    /// Caught up in this session, stable, with no input unresolved: an
    /// invite made now is made from the epoch the circle stands on.
    Settled,
    /// Not settled yet: an invite made now could fork the circle, and lose
    /// its fresh key packages if it loses.
    Unsettled,
    /// Nothing is left to invite: this device is no member, or every
    /// invitee is in. MDK ends it on an empty set of key packages.
    Ends,
}

/// Why MDK refused a re-invite's fresh key packages
/// ([`crate::nostr::mls::SessionManager::reissue_invite`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReinviteRefusal {
    /// A package is one the withdrawn invite already spent, or names nobody
    /// it invited: MDK still owes the re-invite.
    KeyPackage,
    /// MDK or its store failed: it still owes the re-invite.
    Failed,
}

/// Whether MDK lets a re-invite look for fresh key packages now
/// (`reserve_reinvite_lookup`): its own budget and pacing, kept durably.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReinviteReservation {
    /// A lookup is reserved: look now.
    Reserved,
    /// Its next lookup is not due yet.
    NotDue,
    /// MDK has spent its lookups on it: the invite is the user's to make
    /// again.
    GaveUp,
}

/// A change of this device's that branch selection withdrew, and what
/// became of it. **No `Debug`**: it names its circle.
#[derive(Clone, PartialEq, Eq)]
pub struct WithdrawnChange {
    /// The circle.
    pub group_id: GroupId,
    /// What the change was.
    pub kind: WithdrawnKind,
    /// What became of it.
    pub outcome: WithdrawnOutcome,
}

pub struct Staged {
    /// The engine's effects. Its publish work carries no group evolution and
    /// no auto-commit — each is one of [`Self::fanouts`] — and a proposal
    /// only when its record could not be written.
    pub effects: SessionEffects,
    /// The fanouts written, in the order the engine handed the commits back.
    pub fanouts: Vec<FanoutId>,
    /// The Welcomes each group evolution among [`Self::fanouts`] carries, by
    /// transport id — an invite's: their records are written at its confirm,
    /// by whichever drive makes it, so only these say which Welcomes are its.
    pub welcomes: Vec<(FanoutId, Vec<MessageId>)>,
    /// The fanouts written for bare proposals, in the order the engine
    /// handed them back. Kept apart: a proposal is never the commit a caller
    /// asked for.
    pub proposals: Vec<FanoutId>,
    /// The circles in which this hold left a commit staged that it could
    /// neither record nor roll back: unsent, and told to its circle.
    pub unrecorded: Vec<GroupId>,
    /// The circles whose engine-made removal of a member who left this hold
    /// found staged and undid unsent, because it was not this hold's to
    /// make: the wait a refusal earned is still running, or the hold's mode
    /// makes no new commit. The engine stages it again at its next pass.
    /// And the circle a send was not made for at all, because the foreground
    /// that asked for it had ended and the circle was left waiting for one.
    pub waiting: Vec<GroupId>,
}

/// What the fanout driver finds when it takes up a row.
pub(crate) enum FanoutStanding {
    /// No row the engine will show: it has ended, or its group is not live.
    Absent,
    /// Its group is finished on this device — this copy removed or
    /// disbanded, or not held at all: the row ends as a finished one does,
    /// and nothing of it is sent.
    GroupGone(StoredFanout),
    /// The engine holds the row's own commit staged under the row's pending
    /// ref.
    Staged(StoredFanout),
    /// The row's commit was applied. `unfinished` is the engine's pending
    /// ref when it still holds this commit staged: it merged the commit and
    /// stored the row, and its own transition out of `PendingPublish` failed.
    Confirmed {
        fanout: StoredFanout,
        unfinished: Option<PendingStateRef>,
        /// Where the commit itself stands now.
        commit: AppliedCommit,
    },
    /// The row is a bare proposal's: nothing to confirm and nothing to roll
    /// back, only relays still owed its event. `spent` when nothing can act
    /// on that event any more, and no relay is to be sent it again.
    Proposal {
        /// The record.
        fanout: StoredFanout,
        /// Its circle has left the epoch it was proposed for, or this
        /// device's copy of the circle is marked removed.
        spent: bool,
    },
    /// The row is an application message's: not this driver's.
    NoCommit,
    /// A proposal's record whose circle's row cannot be read: nothing is
    /// done with it this pass — no send, no end.
    Unread,
    /// The engine rolled the commit back; the commit's own stored row may not
    /// be retired yet.
    RolledBack(StoredFanout),
    /// The row is still pending and its commit was resolved by some other
    /// path, so the row says nothing about what is staged now. `bound` when
    /// the engine holds the row's pending ref — around a commit that is
    /// therefore not the row's, and of which nothing here knows whether a
    /// relay holds it.
    Stale { bound: bool },
    /// The commit's stored row is still `Sent` and the engine does not hold
    /// it staged under this row. `unsent` when no attempt was ever begun
    /// under the row, so nothing was sent; otherwise a relay may hold a commit
    /// this device can no longer confirm or discard.
    Unheld { unsent: bool },
}

/// Where a commit this device applied stands now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AppliedCommit {
    /// It is this device's canonical commit.
    Canonical,
    /// Branch selection has set it aside and may take it up again.
    Provisional,
    /// It was set aside for good.
    Lost,
}

/// What a test may read of one Welcome's delivery record.
#[cfg(any(test, feature = "test-utils"))]
pub struct WelcomeRecordProbe {
    /// The invite commit it belongs to; `None` for a founding Welcome.
    pub commit: Option<MessageId>,
    /// Its circle.
    pub group: Option<GroupId>,
    /// Its invitee, as lowercase hex.
    pub recipient: String,
    /// The relays it is owed to.
    pub endpoints: Vec<String>,
    /// How often each was attempted.
    pub attempts: Vec<u32>,
    /// How many acknowledgements complete it.
    pub required_acks: usize,
    /// When it stops being sent, in seconds.
    pub bounded_until_secs: Option<u64>,
    /// The exact bytes it sends.
    pub payload: Vec<u8>,
}

/// A replacement Welcome MDK holds for the user's consent: it would discard
/// this device's still-active copy of its group.
///
/// **No `Debug`, deliberately**: it names a group, a Welcome and its author,
/// and carries the token.
#[derive(Clone)]
pub struct RejoinOffer {
    /// The Welcome's transport id, which MDK keys the offer by: the first
    /// gift wrap it arrived in.
    pub welcome_id: MessageId,
    /// The group it would join again.
    pub group_id: GroupId,
    /// Its MLS-authenticated author.
    pub welcomer: MemberId,
    /// The token of the local branch a consent discards.
    pub local_state_token: Vec<u8>,
}

/// What a consent to a replacement Welcome came to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RejoinConfirmation {
    /// The group was joined again.
    Joined,
    /// The local branch moved since the token was read: nothing changed.
    Stale,
    /// MDK no longer holds the offer.
    Gone,
}

/// A founding Welcome and where it goes, for the delivery record a create
/// writes for it.
///
/// **No `Debug`, deliberately**, as [`WelcomeRecord`].
pub(crate) struct FoundingWelcome {
    /// The engine's exact gift-wrapped Welcome.
    pub message: TransportMessage,
    /// Its invitee, as lowercase hex.
    pub recipient: String,
    /// The invitee's inbox relays.
    pub relays: Vec<String>,
    /// The `not_after` of the invitee's `KeyPackage`, when it could be read.
    pub not_after: Option<u64>,
}

/// Where a group whose circle has ended stands, for the forget that ends
/// its MLS state.
///
/// **No `Debug`, deliberately**: it names members.
pub(crate) enum LeftGroup {
    /// The engine holds nothing of it.
    Gone,
    /// It was disbanded: its tombstone must outlive the circle (MDK's forget
    /// deletes it, `storage-sqlite/src/account_projection.rs` 1510-1516).
    Disbanded,
    /// The engine holds it, with these members on its last roster.
    Held(Vec<MemberId>),
    /// The engine could not say: quarantined, not yet hydrated, or the store
    /// did not answer.
    Unread,
}

/// A join the engine still holds unacknowledged.
///
/// **No `Debug`, deliberately**: it names a group, a Welcome and its author.
pub(crate) struct OwedJoin {
    /// The group joined.
    pub group_id: GroupId,
    /// The Welcome's transport id: its gift wrap's event id.
    pub via_welcome: MessageId,
    /// The MLS-authenticated author of the Welcome.
    pub welcomer: Option<MemberId>,
}

/// One Welcome's delivery record: MDK's own durable record for an exact
/// signed event and the relays it is owed to (`DurableTransportFanout`),
/// kept beside the commit the Welcome belongs to (`evolution_id`), whose
/// target is the invitee's inbox (`TransportPublishTarget::Inbox`).
///
/// **No `Debug`, deliberately**: it holds the gift-wrapped event, the
/// invitee's id and relay URLs.
pub(crate) struct WelcomeRecord(pub(crate) cgka_traits::maintenance::DurableTransportFanout);

/// How long a Welcome's record is driven: MDK's host keeps one for a day
/// (`marmot-account/src/runtime.rs` 70, 4212-4216).
pub(crate) const WELCOME_RECORD_BOUND_SECS: u64 = 24 * 60 * 60;

impl WelcomeRecord {
    /// The Welcome's group.
    pub(crate) const fn group(&self) -> Option<&GroupId> {
        self.0.group_id.as_ref()
    }

    /// Whether it reached its bound unsent and was kept, inert, for the
    /// circle's note: every target stopped by Haven's policy
    /// ([`WelcomeEnd::Expired`]).
    pub(crate) fn inert(&self) -> bool {
        use cgka_traits::maintenance::TransportFanoutAttemptState as State;
        !self.0.targets.is_empty()
            && self
                .0
                .targets
                .iter()
                .all(|target| target.state == State::PolicyProhibited)
    }

    /// Whether an inbox relay's acknowledgement of it is stored: its
    /// delivery is completed without a send.
    pub(crate) fn acknowledged(&self) -> bool {
        use cgka_traits::maintenance::TransportFanoutAttemptState as State;
        self.0
            .targets
            .iter()
            .any(|target| target.state == State::Accepted)
    }

    /// Whether its bound has passed at `now_ms`.
    pub(crate) fn expired(&self, now_ms: u64) -> bool {
        self.0
            .bounded_until
            .is_some_and(|until| now_ms / 1_000 >= until.0)
    }

    /// The index and URL of each relay due a send at `now_ms`, by MDK's own
    /// rule for such a record (`marmot-account/src/runtime.rs` 4755-4767): a
    /// relay not yet acknowledging is due 30 seconds after its first attempt,
    /// the wait doubling to an hour.
    pub(crate) fn due(&self, now_ms: u64) -> Vec<(usize, String)> {
        let now = now_ms / 1_000;
        self.0
            .targets
            .iter()
            .enumerate()
            .filter(|(_, target)| {
                use cgka_traits::maintenance::TransportFanoutAttemptState as State;
                if matches!(target.state, State::Accepted | State::PolicyProhibited) {
                    return false;
                }
                let shift = target.attempt_count.saturating_sub(1).min(7);
                let wait = 30_u64.saturating_mul(1_u64 << shift).min(60 * 60);
                target
                    .last_attempt_at
                    .is_none_or(|last| now >= last.0.saturating_add(wait))
            })
            .map(|(index, target)| (index, target.endpoint.0.clone()))
            .collect()
    }

    /// The exact Welcome, as it is sent every time.
    pub(crate) const fn welcome(&self) -> &TransportMessage {
        &self.0.exact_message
    }
}

/// Where a Welcome's record stands, read immediately before a send.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum WelcomeFate {
    /// Its commit is canonical and the engine owes the Welcome: send it.
    Owed,
    /// Its commit is provisionally set aside, or the store cannot say: wait.
    Waiting,
    /// The engine no longer owes it: delivered.
    Done,
    /// Its commit is canonical and the engine neither owes it nor has seen
    /// it delivered: its invitee is on the roster with no way in.
    Undeliverable,
    /// Its commit lost for good: the Welcome ends as failed.
    Lost,
}

/// How a Welcome's record ends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum WelcomeEnd {
    /// An inbox relay acknowledged it.
    Delivered,
    /// The engine no longer owes it.
    Done,
    /// The engine neither owes it nor saw it delivered under a canonical
    /// commit: its invitee must be invited again.
    Undeliverable,
    /// Its commit lost for good.
    Lost,
    /// Its bound passed with no inbox relay acknowledging it: kept, inert,
    /// so the circle's note that a Welcome is owed stands.
    Expired,
    /// An inert record whose note the user has been shown.
    Shown,
}

/// What an applied invite's record handed over in one drive.
///
/// **No `Debug`, deliberately**, as [`WelcomeRecord`].
#[derive(Default)]
pub(crate) struct WelcomeHandOver {
    /// A delivery record was opened for at least one Welcome.
    pub opened: bool,
    /// The invite's commit is provisionally set aside: its Welcomes wait.
    pub withheld: bool,
    /// The invite was applied with a Welcome that cannot be delivered — the
    /// engine never held it, or its invitee has no kept route: its invitee
    /// must be invited again.
    pub reinvite: bool,
}

/// What one of the fanout driver's own engine calls left behind, whether or
/// not the call succeeded.
///
/// **No `Debug`, deliberately**, as [`Staged`].
pub(crate) struct FanoutSettlement {
    /// What the engine handed back — after a failure, what it had already
    /// emitted — with every commit in it recorded in the hold that made the
    /// call.
    pub staged: Staged,
    /// The engine's error. It does not say whether the commit was applied or
    /// discarded: the stored row does.
    pub error: Option<NostrError>,
    /// A rolled-back commit's own row is still stored as sent. No convergence
    /// pass may run for its group until a drive, or the next open, retires it.
    pub unretired: bool,
}

impl FanoutSettlement {
    /// A call that was never made, for the reason `error` gives.
    pub(crate) const fn refused(error: NostrError) -> Self {
        Self {
            staged: Staged {
                effects: SessionEffects {
                    events: Vec::new(),
                    publish: Vec::new(),
                    queued: Vec::new(),
                    pending_convergence: Vec::new(),
                },
                fanouts: Vec::new(),
                welcomes: Vec::new(),
                proposals: Vec::new(),
                unrecorded: Vec::new(),
                waiting: Vec::new(),
            },
            error: Some(error),
            unretired: false,
        }
    }
}

/// What a test may read of a stored fanout row.
///
/// **No `Debug`, deliberately**: `targets` are relay URLs and `event_id` is a
/// relay-visible id.
#[cfg(any(test, feature = "test-utils"))]
pub struct FanoutProbe {
    /// The frozen relay URLs, exactly as spelled in the routing component.
    pub targets: Vec<String>,
    /// Each target's stored status, aligned with [`Self::targets`].
    pub statuses: Vec<FanoutTargetStatus>,
    /// The acknowledgement count frozen at staging.
    pub required_acks: usize,
    /// The frozen event's id.
    pub event_id: nostr::EventId,
    /// The frozen signed event's exact transport bytes.
    pub payload: Vec<u8>,
    /// How many Welcomes the row holds for release on its confirm.
    pub held_welcomes: usize,
    /// The ids of those Welcomes.
    pub welcome_ids: Vec<MessageId>,
    /// How many times each target has been attempted, aligned with
    /// [`Self::targets`].
    pub attempts: Vec<u32>,
    /// Where the row's MLS half stands.
    pub mls: FanoutMls,
    /// When it was staged, on the staging call's clock.
    pub created_at_ms: u64,
}

/// A stored fanout's MLS half, without its pending ref.
#[cfg(any(test, feature = "test-utils"))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FanoutMls {
    /// It carries no MLS change (a proposal or an application message).
    NotApplicable,
    /// Its commit is staged and unresolved.
    Pending,
    /// Its commit was applied.
    Confirmed,
    /// Its commit was discarded.
    RolledBack,
}

#[cfg(any(test, feature = "test-utils"))]
impl FanoutProbe {
    pub(crate) fn of(fanout: &OutboundFanout) -> Option<Self> {
        Some(Self {
            targets: fanout
                .request()
                .target
                .endpoints()
                .iter()
                .map(|endpoint| endpoint.as_str().to_owned())
                .collect(),
            statuses: fanout.target_statuses().to_vec(),
            required_acks: fanout.request().required_acks,
            event_id: nostr::EventId::from_slice(fanout.message_id().as_slice()).ok()?,
            payload: fanout.request().message.payload.clone(),
            held_welcomes: fanout.pending_post_confirmation_welcomes().len(),
            welcome_ids: fanout
                .pending_post_confirmation_welcomes()
                .iter()
                .map(|welcome| welcome.id.clone())
                .collect(),
            attempts: (0..fanout.target_statuses().len())
                .map(|index| fanout.target_attempt_count(index))
                .collect(),
            mls: match fanout.mls_state() {
                FanoutMlsState::NotApplicable => FanoutMls::NotApplicable,
                FanoutMlsState::Pending(_) => FanoutMls::Pending,
                FanoutMlsState::Confirmed => FanoutMls::Confirmed,
                FanoutMlsState::RolledBack => FanoutMls::RolledBack,
            },
            created_at_ms: fanout.created_at_ms(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The rule wraps an MDK value whose derived `Debug` prints the profile,
    /// the ciphersuite and every required capability id.
    #[tokio::test]
    async fn key_package_admission_rule_debug_redacts_the_requirements() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let session = crate::nostr::mls::SessionManager::new_unencrypted(
            dir.path(),
            &nostr::Keys::generate(),
        )
        .expect("session");
        let rule = session
            .key_package_admission_rule(None)
            .await
            .expect("the rule for a new circle");
        crate::assert_debug_redacted!(
            &rule,
            "KeyPackageAdmissionRule",
            &["GroupCapabilities", "ciphersuite", "required", "Current"]
        );
    }

    /// A relay URL, the text a relay answered with, and an id, as MDK's
    /// transport values carry them.
    const RELAY: &str = "wss://relay-canary7f3a.example.com/inbox";
    const RELAY_TEXT: &str = "blocked: canary7f3a said no";

    fn endpoint_failure(kind: TransportEndpointFailureKind) -> TransportEndpointFailure {
        TransportEndpointFailure {
            endpoint: cgka_traits::TransportEndpoint(RELAY.to_string()),
            reason: RELAY_TEXT.to_string(),
            kind,
            rejection_category: Some(TransportEndpointRejectionCategory::Blocked),
        }
    }

    /// Every kind and every category MDK can hand over, each rendered as its
    /// own fixed name beside nothing of the relay's.
    #[test]
    fn fanout_endpoint_failure_debug_redacts_the_relay_and_its_words() {
        use TransportEndpointFailureKind as Kind;
        use TransportEndpointRejectionCategory as Category;
        let kinds = [
            (Kind::TerminalRejected, "TerminalRejected"),
            (Kind::NotExposed, "NotExposed"),
            (Kind::PossiblyExposed, "PossiblyExposed"),
            (Kind::RetryableUnavailable, "RetryableUnavailable"),
        ];
        let categories = [
            (Category::Duplicate, "\"duplicate\""),
            (Category::Pow, "\"pow\""),
            (Category::Blocked, "\"blocked\""),
            (Category::RateLimited, "\"rate-limited\""),
            (Category::Invalid, "\"invalid\""),
            (Category::Error, "\"error\""),
            (Category::Unsupported, "\"unsupported\""),
            (Category::AuthRequired, "\"auth-required\""),
            (Category::Restricted, "\"restricted\""),
        ];
        let needles = [RELAY, "relay-canary7f3a.example.com", RELAY_TEXT, "said no"];
        for (kind, name) in kinds {
            crate::assert_debug_redacted!(
                FanoutEndpointFailure::new(endpoint_failure(kind)),
                "FanoutEndpointFailure",
                marker = name,
                &needles
            );
        }
        for (category, name) in categories {
            let mut failure = endpoint_failure(Kind::TerminalRejected);
            failure.rejection_category = Some(category);
            crate::assert_debug_redacted!(
                FanoutEndpointFailure::new(failure),
                "FanoutEndpointFailure",
                marker = name,
                &needles
            );
        }
    }

    /// A stored fanout in MDK's own shape: a signed-event-sized payload, two
    /// relay targets, a group and a pending ref.
    fn stored_fanout() -> (OutboundFanout, GroupId, MessageId) {
        let group = GroupId::new(vec![0xAB; 16]);
        let id = MessageId::new(vec![0xC7; 32]);
        let request = cgka_traits::TransportPublishRequest {
            account_id: MemberId::new(vec![0x5E; 32]),
            message: TransportMessage {
                id: id.clone(),
                payload: RELAY_TEXT.as_bytes().to_vec(),
                timestamp: cgka_traits::transport::Timestamp(1_700_007_341),
                causal_deps: Vec::new(),
                source: cgka_traits::transport::TransportSource("nostr".to_owned()),
                envelope: cgka_traits::transport::TransportEnvelope::GroupMessage {
                    transport_group_id: vec![0x4D; 32],
                },
            },
            target: cgka_traits::TransportPublishTarget::Group {
                group_id: group.clone(),
                transport_group_id: vec![0x4D; 32],
                endpoints: vec![
                    cgka_traits::TransportEndpoint(RELAY.to_string()),
                    cgka_traits::TransportEndpoint("wss://second-canary7f3a.example.com".into()),
                ],
            },
            required_acks: 2,
        };
        let fanout = OutboundFanout::stage(
            request,
            Some(PendingStateRef::new(7341)),
            Some(group.clone()),
            1_700_007_341_000,
        )
        .expect("a commit's fanout stages");
        (fanout, group, id)
    }

    #[test]
    fn fanout_id_debug_redacts_the_group_and_the_event() {
        let (_, group, id) = stored_fanout();
        crate::assert_debug_redacted!(
            FanoutId::new(group.clone(), id.clone()),
            "FanoutId",
            &[
                hex::encode(group.as_slice()).as_str(),
                hex::encode(id.as_slice()).as_str()
            ]
        );
    }

    /// Every MLS state the record can be in, each beside nothing of the event,
    /// the relays, the group or the pending ref.
    #[test]
    fn stored_fanout_debug_redacts_the_event_the_relays_and_the_group() {
        let (pending, group, id) = stored_fanout();
        let mut exposed = pending.clone();
        exposed.mark_attempt_started(0).expect("first attempt");
        exposed
            .record_target_failure(
                0,
                endpoint_failure(TransportEndpointFailureKind::PossiblyExposed),
            )
            .expect("the failure is recorded");
        let mut confirmed = pending.clone();
        confirmed.mark_mls_confirmed().expect("confirm");
        let mut rolled_back = pending.clone();
        rolled_back.mark_mls_rolled_back().expect("roll back");
        let bare = OutboundFanout::stage(pending.request().clone(), None, None, 7)
            .expect("a proposal's fanout stages");
        let needles = [
            RELAY.to_string(),
            "canary7f3a".to_string(),
            RELAY_TEXT.to_string(),
            "said no".to_string(),
            hex::encode(group.as_slice()),
            hex::encode(id.as_slice()),
            hex::encode([0x4D; 32]),
            hex::encode([0x5E; 32]),
            "7341".to_string(),
            "1700007341".to_string(),
        ];
        let needles: Vec<&str> = needles.iter().map(String::as_str).collect();
        for (fanout, mls) in [
            (pending, "\"Pending\""),
            (exposed, "possibly_exposed: true"),
            (confirmed, "\"Confirmed\""),
            (rolled_back, "\"RolledBack\""),
            (bare, "\"NotApplicable\""),
        ] {
            crate::assert_debug_redacted!(
                StoredFanout::new(fanout),
                "StoredFanout",
                marker = mls,
                &needles
            );
        }
    }

    #[test]
    fn welcome_acceptance_debug_redacts_the_joined_group() {
        let group = GroupId::new(vec![0xAB; 32]);
        let accepted = WelcomeAcceptance::Ingested(IngestEffects {
            outcome: IngestOutcome::Processed,
            effects: SessionEffects {
                events: vec![GroupEvent::GroupCreated {
                    group_id: group.clone(),
                }],
                publish: Vec::new(),
                queued: Vec::new(),
                pending_convergence: vec![group.clone()],
            },
            left_object_unpersisted: false,
            valid_proposal_groups: vec![group.clone()],
        });
        crate::assert_debug_redacted!(
            accepted,
            "WelcomeAcceptance",
            marker = "Ingested",
            &[hex::encode(group.as_slice()).as_str()]
        );
        crate::assert_debug_redacted!(
            WelcomeAcceptance::NeedsNewInvite,
            "WelcomeAcceptance",
            marker = "NeedsNewInvite",
            &[hex::encode(group.as_slice()).as_str()]
        );
        crate::assert_debug_redacted!(
            WelcomeAcceptance::AlreadyJoined {
                group_id: group.clone(),
                effects: SessionEffects {
                    events: Vec::new(),
                    publish: Vec::new(),
                    queued: Vec::new(),
                    pending_convergence: vec![group.clone()],
                },
            },
            "WelcomeAcceptance",
            marker = "AlreadyJoined",
            &[hex::encode(group.as_slice()).as_str()]
        );
    }

    #[test]
    fn a_pre_auth_rejection_carries_no_engine_effects() {
        // The fail-safe accessor: a rejection cannot hand back a synthetic
        // engine result, which is what a defaulting accessor would do and what
        // the cursor planes would then read as "advance past this".
        let screened = ScreenedIngest::RejectedBeforeAuth(PreAuthRejection::Malformed);
        let rendered = format!("{screened:?}");
        assert!(
            screened.ingested().is_none(),
            "a pre-auth rejection must carry no engine effects"
        );
        assert!(rendered.contains("RejectedBeforeAuth"));
    }

    /// The `Ingested` arm carries the engine's drained `GroupEvent`s (decrypted
    /// inner locations) and the publish work whose `h` tag is the
    /// `nostr_group_id`; neither may render (Rule 15). The rejection arm carries
    /// a fieldless reason, which may.
    #[test]
    fn screened_ingest_debug_redacts_the_ingest_effects() {
        let screened = ScreenedIngest::RejectedBeforeAuth(PreAuthRejection::Malformed);
        let rendered = format!("{screened:?}");
        assert!(rendered.contains("RejectedBeforeAuth"));
        assert!(rendered.contains("Malformed"));

        // A POPULATED `Ingested`: a drained location payload and the group id
        // and sender it arrived under. None of the three may render.
        let ingested = ScreenedIngest::Ingested(IngestEffects {
            outcome: IngestOutcome::Processed,
            left_object_unpersisted: false,
            effects: SessionEffects {
                events: vec![GroupEvent::MessageReceived {
                    group_id: GroupId::from_slice(&[0xAB; 32]),
                    message_id: MessageId::new(vec![0xEF; 32]),
                    sender: MemberId::new(vec![0xCD; 32]),
                    epoch: EpochId(1_234_567),
                    payload: b"SECRET_COORDS_12.3456789".to_vec(),
                    retention: None,
                    authority: None,
                }],
                publish: Vec::new(),
                queued: Vec::new(),
                pending_convergence: Vec::new(),
            },
            valid_proposal_groups: vec![GroupId::from_slice(&[0xAB; 32])],
        });
        crate::assert_debug_redacted!(
            ingested,
            "ScreenedIngest",
            marker = "Ingested",
            &[
                "SECRET_COORDS_12.3456789",
                &"ab".repeat(32),
                &"cd".repeat(32),
                &"ef".repeat(32),
                "1234567"
            ]
        );
        // Premise, asserted AFTER the rendering (the accessor consumes the
        // value): the arm really carried effects, so the absences above are
        // attributable to the impl and not to an empty value.
        assert!(ingested.ingested().is_some());
    }

    #[test]
    fn group_id_ext_from_slice_matches_new() {
        let a = GroupId::from_slice(&[1, 2, 3, 4]);
        let b = GroupId::new(vec![1, 2, 3, 4]);
        assert_eq!(a, b);
        assert_eq!(a.as_slice(), &[1, 2, 3, 4]);
    }

    #[test]
    fn location_group_config_builder_pattern() {
        let config = LocationGroupConfig::new("Test Family")
            .with_description("Test description")
            .with_relay("wss://relay1.example.com")
            .with_relay("wss://relay2.example.com")
            .with_admin("abc123");

        assert_eq!(config.name, "Test Family");
        assert_eq!(config.description, "Test description");
        assert_eq!(config.relays.len(), 2);
        assert_eq!(config.admins.len(), 1);
    }

    #[test]
    fn location_group_config_with_relays() {
        let relays = vec!["wss://r1.com", "wss://r2.com"];
        let config = LocationGroupConfig::new("Test").with_relays(relays);
        assert_eq!(config.relays.len(), 2);
    }

    /// The circle's routing id becomes an alias handle, and the name, the
    /// description and the absolute epoch stop rendering at all (Rule 15); the
    /// MLS group id never rendered (Rule 4).
    #[test]
    fn location_group_info_debug_redacts_every_identifying_field() {
        let group_hex = "a".repeat(64);
        let info = LocationGroupInfo {
            mls_group_id: GroupId::from_slice(&[1, 2, 3, 4, 5]),
            nostr_group_id: group_hex.clone(),
            name: "Needle Circle Zephyr".to_string(),
            description: "A test group".to_string(),
            epoch: 1_234_567,
        };

        let debug_str = format!("{info:?}");
        assert!(debug_str.contains("circle#"), "expected an alias handle");
        assert!(
            !debug_str.contains("0102030405"),
            "MLS group ID bytes must not appear in Debug output"
        );
        crate::assert_debug_redacted!(
            info,
            "LocationGroupInfo",
            &[
                &group_hex,
                "Needle Circle Zephyr",
                "A test group",
                "1234567"
            ]
        );
    }

    #[test]
    fn location_message_result_debug_redacts_group_id_and_epoch() {
        let result = LocationMessageResult::Location {
            sender_pubkey: "b".repeat(64),
            content: r#"{"lat":12.3456789}"#.to_string(),
            group_id: GroupId::from_slice(&[9, 9, 9]),
            epoch: 7_654_321,
        };
        crate::assert_debug_redacted!(
            result,
            "LocationMessageResult",
            marker = "Location",
            &[&"b".repeat(64), "12.3456789", "090909", "7654321"]
        );
    }

    #[test]
    fn beyond_relay_retention_is_strict_at_the_boundary() {
        let created = 1_000_000_u64;
        let boundary = created + UNRESOLVABLE_INPUT_MAX_AGE_SECS;

        // One second before the boundary and AT it, the row is still inside the
        // clock-skew slack, so the sweep must not have disposed of it.
        assert!(!beyond_relay_retention(created, boundary - 1));
        assert!(!beyond_relay_retention(created, boundary));
        // One second past it, the row can never be resolved by re-delivery.
        assert!(beyond_relay_retention(created, boundary + 1));
    }

    #[test]
    fn beyond_relay_retention_never_fires_for_a_future_timestamp() {
        // An outer `created_at` is chosen by whoever signed the event, so a
        // forged future stamp must saturate rather than wrap into "ancient".
        assert!(!beyond_relay_retention(u64::MAX, 0));
        assert!(!beyond_relay_retention(2_000, 1_000));
    }

    #[test]
    fn unresolvable_input_max_age_is_relay_retention_plus_clock_skew_slack() {
        assert_eq!(
            UNRESOLVABLE_INPUT_MAX_AGE_SECS,
            crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS
                + crate::location::ttl::RECEIVER_EXPIRATION_GRACE_SECS,
            "the sweep's horizon is how long a relay may still serve the event, \
             plus clock-skew slack; shorter disposes of rows a redelivery could \
             still resolve"
        );
    }

    #[test]
    fn convergence_sweep_absorbs_and_reports_settlement() {
        let mut total = ConvergenceSweep::default();
        assert!(total.is_settled());

        total.absorb(ConvergenceSweep {
            disposed_messages: 2,
            discarded_intents: 1,
            gating_rows: 0,
        });
        assert!(total.is_settled());

        total.absorb(ConvergenceSweep {
            disposed_messages: 1,
            discarded_intents: 0,
            gating_rows: 3,
        });
        assert_eq!(total.disposed_messages, 3);
        assert_eq!(total.discarded_intents, 1);
        assert_eq!(total.gating_rows, 3);
        assert!(!total.is_settled());
    }

    #[test]
    fn convergence_sweep_debug_carries_no_identifiers() {
        let debug = format!(
            "{:?}",
            ConvergenceSweep {
                disposed_messages: 1,
                discarded_intents: 2,
                gating_rows: 3,
            }
        );
        assert!(debug.contains("disposed_messages: 1"));
        // Structural: the type has no id-bearing field to leak. Assert the shape
        // so a later field addition has to face this test.
        assert_eq!(
            debug,
            "ConvergenceSweep { disposed_messages: 1, discarded_intents: 2, gating_rows: 3 }"
        );
    }

    #[test]
    fn location_message_result_group_update_and_invalidated_redact() {
        for result in [
            LocationMessageResult::GroupUpdate {
                group_id: GroupId::from_slice(&[1]),
            },
            LocationMessageResult::Invalidated {
                group_id: GroupId::from_slice(&[2]),
            },
            LocationMessageResult::Joined {
                group_id: GroupId::from_slice(&[3]),
            },
            LocationMessageResult::Unrecoverable {
                group_id: GroupId::from_slice(&[4]),
            },
        ] {
            let debug_str = format!("{result:?}");
            assert!(debug_str.contains("<redacted>"));
        }
    }
}
