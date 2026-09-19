//! O5: why one event did not decrypt, answered from the engine's own typed
//! outcome rather than from prose.
//!
//! # One event, one ingest, one call
//!
//! [`classify`] calls exactly one ingest entry point —
//! `SessionManager::process_event_typed_for_test` — and never
//! `process_event` as well. The engine records every message's disposition and
//! answers a second ingest of the same MLS content with `Stale { AlreadySeen }`,
//! so a classifier that looked twice would report the SECOND look: a fork would
//! silently read as a duplicate. The seam is production's own body with one
//! substitution (the ingest error is not flattened through `map_mls_err`), so
//! both pre-authentication screens still run and the verdicts below are the ones
//! production would have produced.
//!
//! # Matched, never formatted (Security Rule 15)
//!
//! `SessionError` and `EngineError` reach this module only so their variants can
//! be MATCHED. `EngineError::ForkedEpoch`'s derived `Debug` prints a real MLS
//! group id and its `Display` prints two absolute epochs, so nothing here
//! renders either: no `{:?}`, no `{e}`, no `.expect()` on a
//! `Result<_, SessionError>`. Every [`Verdict`] is value-free by construction —
//! the only payload in the whole enum is one `bool`.
//!
//! # What the engine does NOT tell a caller, and how this module answers anyway
//!
//! * **A `Buffered` outcome carries no forward distance.** `IngestOutcome::Buffered`
//!   is built with the LOCAL epoch on the genuine buffering paths and with the
//!   STORED ROW's epoch on the short-circuit path, so `epoch − local` is either
//!   identically zero or an underflow (a panic, under `[profile.soak]`'s
//!   `overflow-checks`). [`Verdict::CommitGap`] therefore carries no distance;
//!   a scenario that wants one derives it from the PRODUCING epoch its own
//!   schedule knows, with `saturating_sub`.
//! * **A stored row is keyed by its CONTENT, not by the event.** The engine keys
//!   every row on `SHA-256` over the peeled MLS bytes, deliberately, so that one
//!   MLS message re-wrapped in a fresh kind-445 envelope collapses to a single
//!   duplicate. A caller holding only the signed event therefore CANNOT name the
//!   row its own ingest just wrote — which is why the row is an explicit
//!   argument ([`StoredRow`]) and why an unnamed row yields
//!   [`Cause::BranchLossUndetermined`] rather than a cheerful `branch_loss:
//!   false`. Guessing there would report a fork that never happened, or hide one
//!   that did.

use haven_core::circle::CircleError;
use haven_core::nostr::mls::types::{
    EngineError, IngestOutcome, MessageId, MessageState, ScreenedIngest, SessionError, StaleReason,
    StoredMessageProbe,
};
use haven_core::nostr::NostrError;
use nostr::Event;

use crate::rig::{RigError, SimDevice};

/// Why one event did not decrypt — or, for the send side, why one send produced
/// no event at all.
///
/// Every variant is value-free except `branch_loss`, which is a bool: a verdict
/// is a classification, and a classification that carried a group id or an epoch
/// would be the leak this whole taxonomy exists to avoid.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// The event's NIP-40 expiration, plus the receiver's clock-skew grace, is
    /// in the past. Haven's own screen, run before the engine.
    Expired,
    /// The pure pre-engine transport parse rejected the envelope. Also Haven's
    /// own screen, and equally pre-authentication.
    PreAuth,
    /// The engine applied it. Not an undecryptable outcome at all; carried so a
    /// caller never has to invent a verdict for the happy path.
    Applied,
    /// Buffered awaiting a commit this device has not seen. No distance: see
    /// the module docs.
    CommitGap,
    /// A stored `Retryable` row at or below the tip short-circuited to
    /// `Buffered` — a forward distance, not a gap.
    ForwardDistance,
    /// This MLS content has already been ingested.
    Duplicate,
    /// The message targets an epoch this device has left. `branch_loss` is true
    /// when fork recovery discarded that branch (`EpochInvalidated`) and false
    /// when the row is an ordinary terminal past-epoch drop (`Failed`).
    PastEpochOrBranchLoss {
        /// Whether a branch was discarded rather than a message merely being
        /// late.
        branch_loss: bool,
    },
    /// This device published it.
    OwnEcho,
    /// This device's own leaf was removed.
    SelfEvicted,
    /// The group is frozen by hydration quarantine for the life of this session.
    Quarantined,
    /// Addressed to another client, or to a group this device does not hold.
    Routing,
    /// The outer transport layer would not peel.
    PeelFailed,
    /// The engine detected a fork it could not resolve.
    Fork,
    /// The engine queued the send instead of encrypting it: a stored row is
    /// still gating this circle's outbound path.
    SendDeferred,
    /// The group's epoch state will not accept a commit right now. Transient.
    EpochNotStable,
    /// The engine has frozen this group at its last stable epoch. Terminal.
    EpochUnrecoverable,
    /// The classifier could not account for this outcome.
    Defect(Cause),
}

/// Why a [`Verdict::Defect`] was returned. Value-free, like everything here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cause {
    /// A hard engine failure that is not a fork. Deliberately not narrowed
    /// further: every other `EngineError` variant renders a group id, an epoch
    /// or remote-authored prose, so telling them apart would mean carrying one.
    EngineFailure,
    /// The message targets an epoch this device has left, but the caller could
    /// not name the stored row, so whether a branch was LOST is unknown. Never
    /// folded into `branch_loss: false` — that would under-report forks.
    BranchLossUndetermined,
    /// The named row could not be read out of the store.
    ProbeUnreadable,
    /// A send failed for a reason the shipped error surface expresses only as
    /// prose. Haven forbids classifying error text (it interpolates
    /// remote-authored strings), so this is where such a failure stops.
    OpaqueSendError,
}

/// The stored row an `AlreadyAtEpoch` classification must consult.
///
/// See the module docs for why this cannot be derived from the event.
#[derive(Clone, Copy)]
pub enum StoredRow<'a> {
    /// The engine's content-derived id for this event's MLS bytes — which a
    /// caller knows when it staged the row itself
    /// (`stage_convergence_input_for_test` returns the id it used) or when it
    /// located the row through `stored_convergence_input_for_test`.
    Named(&'a MessageId),
    /// The caller cannot name the row. An `AlreadyAtEpoch` then classifies as
    /// [`Cause::BranchLossUndetermined`], never as "no branch was lost".
    Unknown,
}

/// Ingests `event` on `device` exactly once and classifies the result.
///
/// # Errors
///
/// [`RigError::SessionNotLive`] if the device is between a kill and its reopen.
/// Nothing else: an engine failure is a [`Verdict`], because "the engine
/// refused this event" is an answer about the subject, not about the rig.
pub async fn classify(
    device: &SimDevice,
    event: &Event,
    row: StoredRow<'_>,
) -> Result<Verdict, RigError> {
    let session = device.session()?;
    let ingested = session.process_event_typed_for_test(event).await;
    // Read AFTER the ingest: the disposition this classification turns on is
    // the one the ingest just wrote.
    let probe = match row {
        StoredRow::Named(id) => session
            .stored_message_record_for_test(id)
            .await
            .map_or(Probe::Unreadable, Probe::Read),
        StoredRow::Unknown => Probe::Unnamed,
    };
    Ok(classify_ingest(&ingested, probe))
}

// Presence only. A `MessageId` is the engine's `SHA-256` over the peeled MLS
// bytes and its own `Debug` renders the whole hex run — which is both a value
// this run minted and exactly the shape a structural rule matches (Rule 15).
impl std::fmt::Debug for StoredRow<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let shape = match self {
            Self::Named(_) => "named",
            Self::Unknown => "unnamed",
        };
        f.debug_tuple("StoredRow").field(&shape).finish()
    }
}

/// What the classifier knows about the stored row.
#[derive(Clone, Copy)]
pub enum Probe {
    /// The row was looked up; `None` means no row carries that id.
    Read(Option<StoredMessageProbe>),
    /// The caller named no row.
    Unnamed,
    /// The store refused the read.
    Unreadable,
}

// Presence and disposition only. `StoredMessageProbe` carries an ABSOLUTE
// epoch and deliberately has no `Debug` of its own; deriving one here would
// hand that epoch straight back to every `{:?}` (Security Rule 15).
impl std::fmt::Debug for Probe {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let shape = match self {
            Self::Read(Some(_)) => "read",
            Self::Read(None) => "absent",
            Self::Unnamed => "unnamed",
            Self::Unreadable => "unreadable",
        };
        f.debug_tuple("Probe").field(&shape).finish()
    }
}

impl Probe {
    /// The row's disposition, when there is one.
    const fn state(self) -> Option<MessageState> {
        match self {
            Self::Read(Some(probe)) => Some(probe.state),
            Self::Read(None) | Self::Unnamed | Self::Unreadable => None,
        }
    }
}

/// The pure half: one typed ingest result plus what is known about the stored
/// row, in, one verdict out.
///
/// Separated from [`classify`] so the arms that only a constructed engine error
/// can reach — [`Verdict::Fork`] above all — are testable without pretending a
/// scenario produced them.
#[must_use]
pub fn classify_ingest(ingested: &Result<ScreenedIngest, SessionError>, probe: Probe) -> Verdict {
    let effects = match ingested {
        Err(SessionError::Engine(EngineError::ForkedEpoch { .. })) => return Verdict::Fork,
        Err(_) => return Verdict::Defect(Cause::EngineFailure),
        Ok(ScreenedIngest::RejectedBeforeAuth(reason)) => return pre_auth(*reason),
        Ok(ScreenedIngest::Ingested(effects)) => effects,
    };
    match &effects.outcome {
        IngestOutcome::Processed => Verdict::Applied,
        // The short-circuit path reports a stored `Retryable` row; the genuine
        // buffering paths have written no such row.
        IngestOutcome::Buffered { .. } => {
            if probe.state() == Some(MessageState::Retryable) {
                Verdict::ForwardDistance
            } else {
                Verdict::CommitGap
            }
        }
        IngestOutcome::Stale { reason } => stale(reason, probe),
    }
}

/// Haven's own pre-authentication screens.
const fn pre_auth(reason: haven_core::nostr::mls::types::PreAuthRejection) -> Verdict {
    use haven_core::nostr::mls::types::PreAuthRejection;
    match reason {
        PreAuthRejection::Expired => Verdict::Expired,
        PreAuthRejection::Malformed => Verdict::PreAuth,
        // `PreAuthRejection` is `#[non_exhaustive]`: a screen Haven adds later
        // is a real classification this module has not learned yet, and saying
        // so is more useful than folding it into `PreAuth`.
        _ => Verdict::Defect(Cause::EngineFailure),
    }
}

/// The engine's stale taxonomy.
const fn stale(reason: &StaleReason, probe: Probe) -> Verdict {
    match reason {
        StaleReason::AlreadySeen => Verdict::Duplicate,
        StaleReason::AlreadyAtEpoch { .. } => match probe.state() {
            // Written immediately before the `AlreadyAtEpoch` return when fork
            // recovery discards the inbound branch.
            Some(MessageState::EpochInvalidated) => {
                Verdict::PastEpochOrBranchLoss { branch_loss: true }
            }
            Some(MessageState::Failed) => Verdict::PastEpochOrBranchLoss { branch_loss: false },
            _ => Verdict::Defect(Cause::branch_loss_undetermined(probe)),
        },
        StaleReason::NotForThisClient | StaleReason::UnknownGroup => Verdict::Routing,
        StaleReason::OwnEcho => Verdict::OwnEcho,
        StaleReason::PeelFailed => Verdict::PeelFailed,
        StaleReason::SelfEvicted => Verdict::SelfEvicted,
        StaleReason::Quarantined => Verdict::Quarantined,
    }
}

impl Cause {
    /// Which undetermined-branch cause a probe state implies.
    const fn branch_loss_undetermined(probe: Probe) -> Self {
        match probe {
            Probe::Unreadable => Self::ProbeUnreadable,
            Probe::Read(_) | Probe::Unnamed => Self::BranchLossUndetermined,
        }
    }
}

/// The send side, as a circle-level caller sees it.
///
/// Only [`CircleError::SendDeferred`] is typed at this layer; every other send
/// failure arrives as `CircleError::Mls`, whose payload is redacted prose that
/// Haven forbids classifying (an error string interpolates remote-authored text,
/// so a substring match is a remotely-influenceable control channel). Use
/// [`classify_session_send`] where the session layer's typed errors are
/// available.
#[must_use]
pub const fn classify_send(error: &CircleError) -> Verdict {
    match error {
        CircleError::SendDeferred { .. } => Verdict::SendDeferred,
        _ => Verdict::Defect(Cause::OpaqueSendError),
    }
}

/// The send side, as a session-level caller sees it.
///
/// `update_admin_policy` and the relay-list commit deliberately bypass
/// `map_mls_err` for the epoch-state refusals, so these two are the only send
/// failures the product surfaces as matchable variants.
#[must_use]
pub const fn classify_session_send(error: &NostrError) -> Verdict {
    match error {
        NostrError::EpochNotStable => Verdict::EpochNotStable,
        NostrError::EpochUnrecoverable => Verdict::EpochUnrecoverable,
        _ => Verdict::Defect(Cause::OpaqueSendError),
    }
}
