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
pub use cgka_session::{CreateGroupEffects, IngestEffects, PublishWork, SessionEffects};
pub use cgka_traits::app_components::AppComponentData;
pub use cgka_traits::engine::{
    CreateGroupRequest, GroupEvent, GroupStateChange, KeyPackage, KeyPackageSource, SendIntent,
    WelcomeMetadata,
};
pub use cgka_traits::engine_state::PendingStateRef;
pub use cgka_traits::group::{Group as MlsGroup, Member as MlsMember};
pub use cgka_traits::ingest::{IngestOutcome, StaleReason};
pub use cgka_traits::message::{MessageRecord, MessageState};
pub use cgka_traits::transport::TransportMessage;
pub use cgka_traits::types::{EpochId, GroupId, MemberId, MessageId};
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

use crate::log_alias::{self, LogAliasClass};

// ── Haven-local ingest screening ─────────────────────────────────────────────

/// Why Haven's own receiver-side screen rejected an inbound event BEFORE the
/// MLS engine ever saw it.
///
/// Fieldless (`Copy`) — carries no timestamp, event id, group id, or ciphertext,
/// so its derived `Debug` is leak-free by construction (Security Rules 4/6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum PreAuthRejection {
    /// The event's NIP-40 `expiration` tag, plus
    /// [`crate::location::ttl::RECEIVER_EXPIRATION_GRACE_SECS`] of clock-skew
    /// grace, is in the past.
    Expired,
    /// The event could not be converted into a transport message by the PURE,
    /// pre-engine parse
    /// ([`SessionManager::event_to_transport_message`](crate::nostr::mls::SessionManager::event_to_transport_message)):
    /// a missing, duplicated, valueless or wrong-width `h`/`p` routing tag, an
    /// unsupported kind, or a self-reported id that does not match the event's
    /// own hash.
    ///
    /// That parse reads only already-materialized envelope fields. It never
    /// touches key material, never looks at the base64 `content`, and never
    /// reaches the engine — so a failure here says how the event was *signed*,
    /// decided before anything authenticated anything. Substantively the same
    /// class of judgement as [`Self::Expired`], and classified the same way.
    ///
    /// **Only that one parse may produce this.** An engine-side or
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

// ── Stuck convergence inputs (the outbound send gate) ────────────────────────

/// How old a stored convergence input must be before re-delivery can no longer
/// resolve it.
///
/// A kind-445 application message published by a current Haven build carries a
/// NIP-40 `expiration` of `created_at + LOCATION_MESSAGE_RETENTION_SECS`, so a
/// conformant relay has deleted the event by then and no receive plane can
/// fetch it again; [`RECEIVER_EXPIRATION_GRACE_SECS`] adds the same clock-skew
/// slack the receiver-side screen in
/// [`SessionManager::process_event`](crate::nostr::mls::SessionManager::process_event)
/// allows before it drops a replay.
///
/// # This is a heuristic about the relay, not a proof about the event
///
/// The screen reads each event's OWN `expiration` tag; this constant reasons
/// from a message's `created_at` and Haven's own retention policy. Another
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
/// STRICTLY greater, matching `process_event`'s `Timestamp::now() > grace`
/// comparison exactly: at precisely [`UNRESOLVABLE_INPUT_MAX_AGE_SECS`] the
/// receive screen still ACCEPTS the event, so the sweep must not have disposed
/// of it yet. Saturating, so a `created_at` in the future is simply never old.
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_pre_auth_rejection_carries_no_engine_effects() {
        // The fail-safe accessor, over EVERY reason. A future variant added
        // without an `ingested()` arm would not compile; this pins that no
        // existing one can hand back a synthetic engine result, which is what a
        // defaulting accessor would do and what the cursor planes would then
        // read as "advance past this".
        for reason in [PreAuthRejection::Expired, PreAuthRejection::Malformed] {
            let screened = ScreenedIngest::RejectedBeforeAuth(reason);
            let rendered = format!("{screened:?}");
            assert!(
                screened.ingested().is_none(),
                "{reason:?} must carry no engine effects"
            );
            assert!(rendered.contains("RejectedBeforeAuth"));
        }
    }

    /// The `Ingested` arm carries the engine's drained `GroupEvent`s (decrypted
    /// inner locations) and the publish work whose `h` tag is the
    /// `nostr_group_id`; neither may render (Rule 15). The rejection arm carries
    /// a fieldless reason, which may.
    #[test]
    fn screened_ingest_debug_redacts_the_ingest_effects() {
        let screened = ScreenedIngest::RejectedBeforeAuth(PreAuthRejection::Expired);
        let rendered = format!("{screened:?}");
        assert!(rendered.contains("RejectedBeforeAuth"));
        assert!(rendered.contains("Expired"));

        // A POPULATED `Ingested`: a drained location payload and the group id
        // and sender it arrived under. None of the three may render.
        let ingested = ScreenedIngest::Ingested(IngestEffects {
            outcome: IngestOutcome::Processed,
            effects: SessionEffects {
                events: vec![GroupEvent::MessageReceived {
                    group_id: GroupId::from_slice(&[0xAB; 32]),
                    sender: MemberId::new(vec![0xCD; 32]),
                    epoch: EpochId(1_234_567),
                    payload: b"SECRET_COORDS_12.3456789".to_vec(),
                }],
                publish: Vec::new(),
                queued: Vec::new(),
                pending_convergence: Vec::new(),
            },
        });
        crate::assert_debug_redacted!(
            ingested,
            "ScreenedIngest",
            marker = "Ingested",
            &[
                "SECRET_COORDS_12.3456789",
                &"ab".repeat(32),
                &"cd".repeat(32),
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

        // One second before the boundary and AT it, the receiver-side screen in
        // `process_event` still accepts a replay of this event, so the sweep
        // must not have disposed of it.
        assert!(!beyond_relay_retention(created, boundary - 1));
        assert!(!beyond_relay_retention(created, boundary));
        // One second past it, `Timestamp::now() > expires_at + grace` holds and
        // the row can never be resolved by re-delivery.
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
    fn unresolvable_input_max_age_is_the_receive_screen_window() {
        assert_eq!(
            UNRESOLVABLE_INPUT_MAX_AGE_SECS,
            crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS
                + crate::location::ttl::RECEIVER_EXPIRATION_GRACE_SECS,
            "the sweep's horizon must equal the receiver-side expiration screen's, \
             or the sweep disposes of rows the receive path would still accept"
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
