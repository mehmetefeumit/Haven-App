//! The transport half of the durable fanout: one signed event, one relay, and
//! what that relay did with it.
//!
//! A fanout decision — confirm, retry, roll back — reads nothing but
//! [`TransportEndpointFailureKind`], so this is where each kind gets its one
//! meaning:
//!
//! * **`TerminalRejected`** and **`RetryableUnavailable` with a category** are
//!   a relay's own words, and are returned only when the relay's `OK` frames
//!   for this event prove it answered EVERY attempt of the call `OK false`.
//!   MDK's relay client makes several attempts in one call and reports the
//!   last; an attempt that went unanswered may have been stored.
//! * **`NotExposed`** is Haven's own refusal, made before anything was handed
//!   to MDK's client.
//! * **`RetryableUnavailable` with no category** is MDK's client failing to
//!   reach the relay before it sent anything.
//! * **`PossiblyExposed`** is everything else. Nothing proved the relay does
//!   not hold the event, so nothing may roll it back.
//!
//! # The driver (Security Rule 13)
//!
//! [`drive_one`] takes one stored fanout of a staged commit through one pass:
//! it sends the frozen event to each relay that is still owed an attempt and
//! due one, records what each did, confirms the commit on an acknowledgement,
//! and rolls it back only when every relay proved it did not take it and none
//! was ever possibly exposed. One call makes at most one transport call per
//! distinct relay and retries nothing; what is still owed afterwards is left
//! for the next call. It does wait: for every relay it called to answer —
//! MDK's relay client gives up on one after twenty seconds — and, once the
//! commit is resolved, for the deadlines the engine announces while what the
//! resolution released is folded.
//!
//! [`drive_due`] is the same for every stored commit fanout, read from the
//! store: after a restart, the rows MDK's hydrate restored pending commits
//! from.
//!
//! [`Publishing`] is what calls them. Each send-side change — a removal, an
//! invite, a relay update, an admin's hand-over and step-down, the
//! epoch-rotation repair — is one call that first resumes its circle's older
//! records, stages the change under its record, drives it, and answers
//! [`EvolutionStatus`]: applied, awaiting relays, undone, queued, set aside
//! by the engine, or staged with no record. Only "undone" says every relay
//! refused the change. [`Publishing::resume`] is the session's drive of
//! everything stored. [`Publishing::settle_staged`] is what a receive
//! plane that drives calls with what its own engine call recorded: the
//! catch-up sweep [`run_catchup_in_foreground`](super::catchup::run_catchup_in_foreground).
//!
//! A bare proposal — the user's own leave, minted again by the engine for
//! each epoch its circle reaches — rides a record too, with no commit behind
//! it: nothing to confirm and nothing to roll back, only relays that are
//! still owed its event. It is driven as an applied commit's record is and
//! ends the same way — and sooner, once nothing can act on it: its circle
//! has left the epoch it was proposed for, or this device is no longer in
//! the circle. A commit's record is driven ahead of a proposal's, and a
//! proposal makes no call outside a relay's wait. Within a circle nothing
//! staged after a commit that is still pending is sent before that commit is
//! resolved.
//!
//! A LOCATION has a record too, and it is neither a commit's nor a retry
//! ([`Publishing::seal_location`], [`Publishing::publish_location`],
//! `docs/MDK_UPSTREAM_TRACKER.md` T-APP-TRANSPORT). It is written in the
//! engine hold that seals the event, sent once through Haven's own location
//! transport, and deleted with that send's answer, whatever it is. The send
//! is made only if a fresh location would be sealed for the circle then. A
//! record this session did not seal — one a process died before deleting —
//! is deleted unsent by the next drive, and no record is sent within a
//! send's window of its event's expiration; any drive deletes one that has
//! reached it. A commit's driver reads none of it: a location paces no
//! relay, holds no change, and is taken up after every commit and proposal.
//!
//! An APPLIED commit's row is not a hold on its circle: it is what the device
//! still owes the relays that have not taken the commit. It is driven like a
//! pending one until two distinct relays hold the commit or a day has passed
//! since the later of its staging and its first acknowledgement
//! ([`FANOUT_BOUND_MS`]) — never before each frozen relay has answered one
//! attempt. From then on it makes no call, and it is deleted once that
//! changes no relay's wait. Only a commit still pending holds its circle's
//! next change. A pending commit that was never possibly exposed, that
//! removes nobody, and that no relay took within that day is undone through
//! the engine; one a relay may hold never is, and neither is one that removes
//! a member.
//!
//! What a drive did to a change with nobody waiting on it is recorded for the
//! circle as a [`ChangeNote`], typed and durable, until the app acknowledges
//! it.
//!
//! A confirm that returns an error is not a failed publish. The engine may
//! have applied the commit already, so the STORED ROW says what is true and
//! the next drive reads it; what the failed call had delivered comes back
//! beside the error, never instead of it.
//!
//! An invite's Welcomes are handed to the caller once their commit is
//! applied — the engine's own promoted copies — and to nobody before. The
//! record keeps them, and so keeps which commit each belongs to, until each
//! delivery is completed in the engine: a process that dies in between hands
//! them over again.
//!
//! What a relay's refusal proves rests on this module being the only sender
//! of a fanout row's event on the publish client, and on every call's outcome
//! being stored before the next call to that relay:
//!
//! * an event that has a row is refused by every other publish path of
//!   [`RelayManager`](super::RelayManager) ([`is_owned`]); the rows are read
//!   into that registry before the engine opens;
//! * one drive per row at a time (`Driving`), and one call per relay at a
//!   time across rows (chosen under the session lock, and the transport's
//!   own gate, which a plain publish to that relay also takes);
//! * a target is stored `Attempting` before its call and resolved after it,
//!   and one found `Attempting` — its call never returned — is stored
//!   possibly exposed before it is tried again.
//!
//! # Pacing
//!
//! A relay is sent a fanout's event again only when [`relay_due`] says so:
//! per relay across every row that owes it, with MDK's schedule after an
//! ambiguous answer and Haven's own after an unreachable or rate-limited one
//! (`docs/MDK_UPSTREAM_TRACKER.md` T-ADAPTER-ATTEMPTS). The most a relay is
//! called is ten times in the hour after its first failure and once an hour
//! after that, however many rows are waiting on it. Four things add one call
//! each: a commit newly staged meanwhile, whose first call is never held
//! back; an older row the relay still owes when it acknowledges a newer one;
//! a stored attempt further ahead of the clock than the longest wait; and a
//! relay that could not be reached, when [`wake_unreachable`] is called. A
//! relay another send holds is not attempted at all ([`FanoutSend::take`]):
//! nothing is stored for it and nothing is counted.
//! After its first day a pending commit a relay may hold asks for no wake of
//! its own and goes to a relay once an hour at most ([`hourly_floor`]).

use std::collections::{BTreeSet, HashSet, VecDeque};
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use cgka_traits::{
    FanoutMlsState, FanoutTargetStatus, OutboundFanout, TransportAdapterError, TransportEndpoint,
    TransportEndpointFailure, TransportEndpointFailureKind, TransportEndpointRejectionCategory,
};
use nostr::message::MachineReadablePrefix;
use nostr::{EventId, PublicKey, RelayMessage, RelayUrl};
use nostr_sdk::pool::relay::RelayNotification;
use tokio::sync::broadcast::{error::TryRecvError, Receiver};
use transport_nostr_adapter::NostrRelayClient;
use transport_nostr_peeler::NostrTransportEvent;

use crate::circle::{
    CircleError, CircleManager, DecryptedIngest, FanoutResolution, LeavePlan, LeaveStep,
    MemberKeyPackage, SkipReason, StagedChange, StagedPostJoin, StagedRepair, StagedSeal,
};
use crate::location::LocationMessage;
use crate::nostr::mls::types::LocationMessageResult;
use crate::nostr::mls::types::{
    AppliedCommit, FanoutEndpointFailure, FanoutId, FanoutStanding, GroupId, MessageId,
    MessageState, StoredFanout, TransportMessage, WelcomeEnd, WelcomeFate, WelcomeRecord,
    WithdrawnChange, WithdrawnOutcome,
};
use crate::nostr::mls::types::{RequeueOutcome, RequeuedRemoval};
use crate::nostr::mls::AwayHold;
use crate::nostr::mls::ChangeNote;
use crate::nostr::mls::RemovalRequeue;
use crate::nostr::mls::SessionManager;
use crate::relay::catchup::ReceiveOnlyOutcome;
use crate::relay::{PublishResult, RelayResult};

/// How many times MDK's relay client sends an event to a relay that keeps
/// refusing it, inside one `publish_event`.
///
/// `SDK_RELAY_PUBLISH_ATTEMPTS`, private to `transport-nostr-adapter`
/// `src/sdk_client.rs`; read back from MDK's source by
/// `mdks_in_call_attempt_count_is_the_one_the_transport_counts_against`.
pub const MDK_ATTEMPTS_PER_CALL: usize = 3;

/// The longest one call of MDK's relay client waits for a relay, in seconds.
///
/// `SDK_RELAY_PUBLISH_OVERALL_WAIT`, private to `transport-nostr-adapter`
/// `src/sdk_client.rs` and read back from MDK's source by
/// `mdks_call_ceiling_is_the_one_a_drive_is_said_to_wait`. It is what a drive
/// waits when a relay it called never answers.
pub const MDK_CALL_CEILING_SECS: u64 = 20;

/// What one relay did with one fanout publish.
#[derive(Debug)]
pub enum FanoutTargetOutcome {
    /// The relay said it holds the event: `OK true`, or `OK false` with the
    /// `duplicate:` prefix, whether MDK's client or this module's own listener
    /// heard it.
    Accepted,
    /// It did not: [`FanoutEndpointFailure::kind`] says what is known instead.
    Failed(FanoutEndpointFailure),
}

/// Sends `message`'s signed event to `target` alone and returns what that
/// relay did with it.
///
/// `now_secs` is the caller's clock, which the event's age is read off for a
/// refusal's clock verdict ([`crate::relay::clock_skew::on_this_clock`]).
///
/// `heard` is the target relay's own notification stream, taken before this
/// call: every `OK` it sends for the event is counted there, whichever of MDK's
/// attempts it answers and whether or not MDK was still waiting for it. Without
/// it no relay-spoken refusal can be proven, and none is returned. An `OK`
/// names an event, not an attempt, so the count is a proof only while no other
/// frame for this event is outstanding on `target`: none in flight from
/// another sender, and none an earlier send left queued for the next
/// connection to write. The fanout driver keeps that true and records every
/// call's outcome, a call that never returned included, before the next.
///
/// One relay per call, one acknowledgement required: a call that names several
/// and misses its quorum comes back as an error with the receipts it did
/// collect thrown away (v0.10.4 `transport-nostr-adapter/src/sdk_client.rs`
/// 1276-1316), which would read an accepted commit as failed everywhere.
pub(crate) async fn publish_to_target(
    relay_client: &dyn NostrRelayClient,
    target: &TransportEndpoint,
    message: &TransportMessage,
    mut heard: Option<Receiver<RelayNotification>>,
    now_secs: u64,
) -> FanoutTargetOutcome {
    // The frozen bytes are sent as the signed event they are, or not at all:
    // MDK's client signs an unsigned event with whatever signer its client has.
    let Some((event, id, signed_at)) = NostrTransportEvent::from_transport_message(message)
        .ok()
        .and_then(|event| {
            let verified = event.to_verified_nostr_event().ok()?;
            Some((event, verified.id, verified.created_at.as_secs()))
        })
    else {
        return not_exposed(target);
    };
    let age_secs = now_secs.saturating_sub(signed_at);
    let result = relay_client
        .publish_event(std::slice::from_ref(target), &event, 1)
        .await;
    let answers = heard
        .as_mut()
        .map_or(Answers::UNHEARD, |heard| Answers::drain(heard, &id));

    let (accepted, failed) = match &result {
        Ok(outcome) => (outcome.accepted.as_slice(), outcome.failed.as_slice()),
        Err(error) => (&[][..], error.publish_endpoint_failures()),
    };
    // Acked means acked (Security Rule 13): an `OK true` for this event from
    // this relay is its acknowledgement whether or not MDK's client was still
    // waiting when it arrived, and no later answer takes it back.
    if answers.accepted
        || accepted
            .iter()
            .any(|receipt| same_relay(&receipt.endpoint, target))
    {
        return FanoutTargetOutcome::Accepted;
    }
    let Some(failure) = failed
        .iter()
        .find(|failure| same_relay(&failure.endpoint, target))
    else {
        log::warn!("[Fanout] a relay client's answer classified nothing for its relay");
        return failed_as(target, possibly_exposed(target));
    };
    match failed_as(target, proven(failure.clone(), answers)) {
        FanoutTargetOutcome::Failed(failed) => {
            FanoutTargetOutcome::Failed(failed.blaming_the_clock(answers.clock.and_then(
                |complaint| crate::relay::clock_skew::on_this_clock(complaint, age_secs),
            )))
        }
        accepted @ FanoutTargetOutcome::Accepted => accepted,
    }
}

/// The target relay's `OK` frames for one event across one call.
#[derive(Clone, Copy)]
struct Answers {
    /// It said it holds the event at least once: `OK true`, or `OK false`
    /// with `duplicate:`.
    accepted: bool,
    /// How many times it said `OK false`.
    refusals: usize,
    /// Nothing it said can have been missed.
    complete: bool,
    /// What a refusal blamed on this device's clock, its words discarded.
    clock: Option<crate::relay::clock_skew::DeviceClockComplaint>,
}

impl Answers {
    /// No stream to listen on: the relay was not in the pool.
    const UNHEARD: Self = Self {
        accepted: false,
        refusals: 0,
        complete: false,
        clock: None,
    };

    /// Everything `heard` holds, without waiting: MDK's client learns of an
    /// `OK` from this same broadcast, so whatever it acted on is already here.
    fn drain(heard: &mut Receiver<RelayNotification>, id: &EventId) -> Self {
        let mut answers = Self {
            accepted: false,
            refusals: 0,
            complete: true,
            clock: None,
        };
        loop {
            match heard.try_recv() {
                Ok(RelayNotification::Message {
                    message:
                        RelayMessage::Ok {
                            event_id,
                            status,
                            message,
                        },
                }) if event_id == *id => {
                    // `duplicate:` is the relay saying it already holds the
                    // event, as MDK's client reads it (`sdk_client.rs`
                    // 1621-1630) when its own wait is the one that hears it.
                    if status
                        || MachineReadablePrefix::parse(&message)
                            == Some(MachineReadablePrefix::Duplicate)
                    {
                        answers.accepted = true;
                    } else {
                        answers.refusals += 1;
                        if let Some(complaint) =
                            crate::relay::clock_skew::classify_clock_refusal(&message)
                        {
                            answers.clock = Some(
                                answers
                                    .clock
                                    .map_or(complaint, |seen| seen.merge(complaint)),
                            );
                        }
                    }
                }
                Ok(_) => {}
                Err(TryRecvError::Empty) => return answers,
                // Frames were dropped: keep reading for an `OK true`, which
                // still counts, but nothing can be proven from a count.
                Err(TryRecvError::Lagged(_)) => answers.complete = false,
                Err(TryRecvError::Closed) => {
                    answers.complete = false;
                    return answers;
                }
            }
        }
    }

    /// Whether the relay answered every one of MDK's attempts `OK false`. One
    /// answer short is an attempt that may have been stored; one too many is a
    /// relay whose answers cannot be matched to attempts.
    const fn prove_every_attempt_refused(self) -> bool {
        self.complete && !self.accepted && self.refusals == MDK_ATTEMPTS_PER_CALL
    }
}

/// MDK's classification of the call's LAST attempt, as far as the relay's own
/// answers bear it out for every attempt.
fn proven(failure: TransportEndpointFailure, answers: Answers) -> TransportEndpointFailure {
    use TransportEndpointFailureKind::{
        NotExposed, PossiblyExposed, RetryableUnavailable, TerminalRejected,
    };
    let relay_spoken = match (failure.kind, failure.rejection_category) {
        (TerminalRejected, _) | (RetryableUnavailable, Some(_)) => true,
        // Nothing was sent (MDK could not reach the relay), or nothing is
        // claimed: neither rests on what the relay said.
        (RetryableUnavailable, None) | (NotExposed | PossiblyExposed, _) => false,
    };
    if !relay_spoken {
        return failure;
    }
    if !answers.prove_every_attempt_refused() {
        log::warn!("[Fanout] a relay's refusal was not proven for every attempt");
        return TransportEndpointFailure {
            kind: PossiblyExposed,
            ..failure
        };
    }
    // The publish client holds no signer and never authenticates, so this
    // answer cannot change: it is a refusal, not an outage to wait out.
    if failure.rejection_category == Some(TransportEndpointRejectionCategory::AuthRequired) {
        return TransportEndpointFailure {
            kind: TerminalRejected,
            ..failure
        };
    }
    failure
}

/// Whether two endpoints name one relay. MDK answers with the URL as it parsed
/// it, which need not be the caller's spelling.
fn same_relay(a: &TransportEndpoint, b: &TransportEndpoint) -> bool {
    matches!(
        (RelayUrl::parse(a.as_str()), RelayUrl::parse(b.as_str())),
        (Ok(a), Ok(b)) if a == b
    )
}

/// `failure` under the caller's own spelling of `target`: a stored fanout
/// accepts a failure only for the exact endpoint it froze
/// (`traits/src/transport_adapter.rs` 578-582).
fn failed_as(target: &TransportEndpoint, failure: TransportEndpointFailure) -> FanoutTargetOutcome {
    FanoutTargetOutcome::Failed(FanoutEndpointFailure::new(TransportEndpointFailure {
        endpoint: target.clone(),
        ..failure
    }))
}

/// MDK's own shape for an answer that says nothing about the relay
/// (`marmot-account/src/runtime.rs` 4468-4475).
pub(crate) fn possibly_exposed(target: &TransportEndpoint) -> TransportEndpointFailure {
    TransportEndpointFailure {
        endpoint: target.clone(),
        reason: "publish acknowledgement unknown".to_owned(),
        kind: TransportEndpointFailureKind::PossiblyExposed,
        rejection_category: None,
    }
}

/// What a target is stored with when no attempt at it has run to an answer
/// and one may have been made.
///
/// A call that never returned ([`record_interrupted`]), and a relay of a
/// commit the open found staged with no record. Haven's own words, replaced
/// by the next attempt's answer.
///
/// MDK's record has no status for this, so the text is what says it; that is
/// sound only while nothing else writes it there, which
/// `every_failure_reason_mdks_relay_client_writes_is_fixed_and_none_is_the_drivers_marker`
/// re-reads from MDK's source.
pub const INTERRUPTED: &str = "the attempt never returned";

pub(crate) fn interrupted(target: &TransportEndpoint) -> TransportEndpointFailure {
    TransportEndpointFailure {
        reason: INTERRUPTED.to_owned(),
        ..possibly_exposed(target)
    }
}

/// The answer for a publish Haven itself refused before anything was handed to
/// MDK's client: a target its relay policy will not dial, or bytes that are not
/// a signed event. Nothing left the device.
pub(super) fn not_exposed(target: &TransportEndpoint) -> FanoutTargetOutcome {
    log::warn!("[Fanout] a publish was refused before anything was handed to a relay");
    failed_as(
        target,
        TransportEndpointFailure {
            endpoint: target.clone(),
            reason: "refused before the hand-over".to_owned(),
            kind: TransportEndpointFailureKind::NotExposed,
            rejection_category: None,
        },
    )
}

// ── The driver ───────────────────────────────────────────────────────────────

/// What a drive may do with the records it finds (Security Rule 13).
///
/// Mandatory wherever a drive is asked for: there is no default, because the
/// two differ in exactly what must not happen while the operating system may
/// end the process at any moment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DriveMode {
    /// Everything this module describes: records are written for what the
    /// engine stages, sent, confirmed, rolled back on every relay's proven
    /// refusal, undone at their bound; the user's queue is drained and
    /// Welcomes are delivered. For a caller that knows the app is in front
    /// of its user.
    Full,
    /// Finishes what was begun and a relay has decided, and begins nothing:
    /// for a caller the operating system may end at any moment — a
    /// background burst, a session nobody has claimed the foreground for, a
    /// pass the foreground ended under.
    ///
    /// A pending commit's record that has been sent before and that the
    /// engine holds is sent again — the same bytes — to each relay that is
    /// due, and each answer is stored. And a pending commit whose STORED
    /// record holds a relay's acknowledgement is confirmed, with no relay
    /// called for it: the acknowledgement is what releases
    /// publish-before-apply (`marmot/protocol-core/publish-lifecycle.md`
    /// 57-59), and MDK's host confirms a stored one before it calls any
    /// relay, in every app state (`marmot-account/src/runtime.rs` 3824,
    /// 4029-4040). Left unconfirmed, the circle neither sends nor reads on
    /// this device, and everything it receives is stored unopened behind the
    /// commit. Only while the wake has a whole fold's budget left
    /// ([`FOLD_BUDGET_MS`]); and never for a change of the circle's relays,
    /// whose confirm moves where the circle is heard — the session's
    /// subscriptions are the app's to move, so that one waits for a full
    /// drive.
    ///
    /// Never, in this mode: a rollback of a record, on any proof; the bound;
    /// a record for a new commit; the full advance, so nothing queued is
    /// made and no eviction is staged; a first send of a record no relay
    /// has been sent; a Welcome; a publish of anything that has no record; a
    /// relay call the wake has not a whole row's budget left for
    /// ([`ROW_BUDGET_MS`]); anything at all for a record once its commit is
    /// applied — its other relays, its Welcomes and its end are a full
    /// drive's.
    ///
    /// The fold of such a confirm is inputs-only: what the engine replays is
    /// applied and stored, and nothing new is made. Four things can come of
    /// it. A confirm whose transaction an earlier call landed and whose
    /// engine half then failed is finished the same way. A leave the engine
    /// has minted again is given the one record nothing else would keep; a
    /// full drive sends it. A commit found staged with no record — handed
    /// to nobody — is rolled back through the engine. And a
    /// queued change of the group is retired, its circle told first, where
    /// it is what holds the circle at its epoch.
    ///
    /// A process that dies between a confirm's transaction and the engine's
    /// replay leaves what was stored behind the commit stranded
    /// (`docs/MDK_UPSTREAM_TRACKER.md` T-PARKED-REPLAY). That is detected at
    /// the next open and after every confirm, said to the circle, and handed
    /// back to the engine ahead of anything else of that circle
    /// (`SessionManager::hand_back_stranded`); a confirm made here ends with
    /// that hand-back made, or with its circle told.
    FinishOnly,
}

/// Where a call reads its [`DriveMode`], each time it decides something.
///
/// A [`DriveMode`] is its own source. One that can change during a call may
/// only narrow, from [`DriveMode::Full`] to [`DriveMode::FinishOnly`]: the
/// live plane's does when the foreground ends under a pass.
pub trait ModeSource: Send + Sync {
    /// The mode now.
    fn mode(&self) -> DriveMode;

    /// Whether what this call began under still stands. A call it has ended
    /// under — the live plane's pass, once its lifecycle has changed — has
    /// no budget left for anything it had not begun ([`budget`]): it stores
    /// what its calls answer, and the next call decides.
    fn stands(&self) -> bool {
        true
    }

    /// What counts each relay call this source's pass marks as begun, until
    /// its answer: what a pause waits on before it closes the socket the
    /// call rides (Security Rule 13). `None` counts nothing.
    fn in_flight(&self) -> Option<&InFlight> {
        None
    }
}

impl ModeSource for DriveMode {
    fn mode(&self) -> DriveMode {
        *self
    }
}

/// How many of something are under way, and a wait for none.
///
/// Counted `SeqCst`, against a pause that writes the lifecycle and then
/// reads this: what counts itself and then reads the lifecycle either is
/// waited for or sees the pause.
#[derive(Default)]
pub struct InFlight {
    count: AtomicUsize,
    drained: tokio::sync::Notify,
}

impl InFlight {
    /// Counts one more, until the guard drops.
    pub(crate) fn count(&self) -> Counted<'_> {
        self.count.fetch_add(1, Ordering::SeqCst);
        Counted(self)
    }

    /// How many are counted now.
    pub(crate) fn now(&self) -> usize {
        self.count.load(Ordering::SeqCst)
    }

    /// Completes once none is counted. No cap of its own: what it waits for
    /// is bounded by whoever counted it.
    pub(crate) async fn drained(&self) {
        loop {
            let notified = self.drained.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.now() == 0 {
                return;
            }
            notified.await;
        }
    }
}

/// One count on an [`InFlight`], given back on drop: what panics, is
/// cancelled or returns early never leaves the count above zero, which would
/// hold an uncapped wait on it for good.
#[must_use]
pub struct Counted<'a>(&'a InFlight);

impl Drop for Counted<'_> {
    fn drop(&mut self) {
        if self.0.count.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.0.drained.notify_waiters();
        }
    }
}

/// The mode of a call the app makes through the bridge.
///
/// The full one only while its caller says the app is in front of its user
/// AND, where a live plane shares the session, that plane's own lifecycle is
/// the claimed foreground; the one that only finishes otherwise.
///
/// Beside a live plane the plane's lifecycle — set by its own claim, in Rust
/// — decides, and the caller's word can only narrow it: a stale `true` from a
/// caller that has since gone to the background widens nothing. The word
/// alone is what a process with no live plane has — Android's background
/// service passes `false`. Read again at each decision, so it can only
/// narrow: a pause that lands under the call ends what it had not begun.
pub struct Claimed<'a> {
    session: &'a SessionManager,
    began: DriveMode,
    /// Whether this call holds the claim of a process with no live plane.
    holds_claim: bool,
}

impl<'a> Claimed<'a> {
    /// The mode `circle`'s call is made in, `foreground` being its caller's
    /// word. In a process with no live plane the word is also the claim the
    /// away-holds read, for as long as the call lasts.
    #[must_use]
    pub fn new(circle: &'a CircleManager, foreground: bool) -> Self {
        let session = circle.session();
        let began = if foreground && session.bridge_may_commit() {
            DriveMode::Full
        } else {
            DriveMode::FinishOnly
        };
        let holds_claim = began == DriveMode::Full && session.count_bridge_claim();
        Self {
            session,
            began,
            holds_claim,
        }
    }
}

impl Drop for Claimed<'_> {
    fn drop(&mut self) {
        if self.holds_claim {
            self.session.release_claim();
        }
    }
}

impl ModeSource for Claimed<'_> {
    fn mode(&self) -> DriveMode {
        if self.began == DriveMode::Full && self.session.bridge_may_commit() {
            DriveMode::Full
        } else {
            DriveMode::FinishOnly
        }
    }

    fn stands(&self) -> bool {
        self.mode() == self.began
    }
}

/// What a pass decided something under, for the place the thing is done to
/// read again.
///
/// A pass reads its mode, decides, and then waits for the engine — for as
/// long as whatever holds it takes, a whole hand-back of stranded input
/// included. The lifecycle it decided under can end in that wait. So each
/// act that may not outlive it asks again with the engine held: a rollback,
/// the bound, a confirm, a Welcome's hand-over, a full advance. One that no
/// longer holds is not made, and its record stays as it is stored.
#[derive(Clone, Copy)]
pub(crate) struct Still<'a> {
    source: &'a dyn ModeSource,
    decided: DriveMode,
}

impl<'a> Still<'a> {
    pub(crate) const fn new(source: &'a dyn ModeSource, decided: DriveMode) -> Self {
        Self { source, decided }
    }

    /// For a caller whose mode cannot change under it.
    pub(crate) const fn always(mode: &'a DriveMode) -> Self {
        Self {
            source: mode,
            decided: *mode,
        }
    }

    /// Whether what was decided may still be done: the call's lifecycle
    /// stands, and its mode is the one the decision was made in.
    pub(crate) fn holds(&self) -> bool {
        self.source.stands() && self.source.mode() == self.decided
    }

    /// The mode the decision was made in.
    pub(crate) const fn decided(&self) -> DriveMode {
        self.decided
    }
}

/// Transport message ids — relay-visible event ids — that have a stored
/// fanout row. Process-wide: a row belongs to one session, and every relay
/// manager of the process must refuse its event.
static OWNED: Mutex<BTreeSet<Vec<u8>>> = Mutex::new(BTreeSet::new());

/// Rows a drive is under way for.
static DRIVING: Mutex<BTreeSet<Vec<u8>>> = Mutex::new(BTreeSet::new());

/// Woken each time a drive lets go of a row.
static RELEASED: std::sync::LazyLock<tokio::sync::Notify> =
    std::sync::LazyLock::new(tokio::sync::Notify::new);

/// Records that `message` has a stored fanout row.
pub(crate) fn own(message: &MessageId) {
    OWNED
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .insert(message.as_slice().to_vec());
}

/// Records that `message`'s fanout row is gone.
pub(crate) fn release(message: &MessageId) {
    OWNED
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .remove(message.as_slice());
}

/// Whether the event `id` names has a stored fanout row, so only
/// [`drive_one`] may send it.
///
/// A relay's `OK` names an event and nothing else. A second sender of a
/// fanout's event on the publish client — at any time, since a send made
/// while a socket is down is queued and written by the next connection —
/// would have its answers counted as the fanout's own, and three refusals
/// would stop proving that every attempt was refused.
#[must_use]
pub fn is_owned(id: &EventId) -> bool {
    OWNED
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .contains(id.as_bytes().as_slice())
}

/// The one drive a row may have at a time, released on drop.
struct Driving(Vec<u8>);

impl Driving {
    fn claim(id: &FanoutId) -> Option<Self> {
        Self::claim_message(id.message())
    }

    fn claim_message(message: &MessageId) -> Option<Self> {
        let key = message.as_slice().to_vec();
        let free = DRIVING
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(key.clone());
        // Built only when the claim is this one's: dropping a `Driving`
        // releases the row.
        free.then(|| Self(key))
    }

    /// Whether a drive of the row `message` names is under way in this
    /// process.
    fn under_way(message: &MessageId) -> bool {
        DRIVING
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains(message.as_slice())
    }

    /// Completes once no drive of the row `message` names is under way.
    async fn let_go(message: &MessageId) {
        loop {
            let released = RELEASED.notified();
            tokio::pin!(released);
            // Registered before the read, so a release between the two wakes it.
            released.as_mut().enable();
            if !Self::under_way(message) {
                return;
            }
            #[cfg(any(test, feature = "test-utils"))]
            ROW_WAITED.notify_one();
            released.await;
        }
    }
}

impl Drop for Driving {
    fn drop(&mut self) {
        DRIVING
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&self.0);
        RELEASED.notify_waiters();
    }
}

/// Woken when a call starts waiting for a row another drive holds.
#[cfg(any(test, feature = "test-utils"))]
static ROW_WAITED: std::sync::LazyLock<tokio::sync::Notify> =
    std::sync::LazyLock::new(tokio::sync::Notify::new);

/// What [`hold_fanout_row_for_test`] holds: the row is another drive's until
/// this is dropped.
#[cfg(any(test, feature = "test-utils"))]
pub struct RowHoldForTest(#[allow(dead_code)] Driving);

/// Holds `id`'s row as a drive under way does, if no drive holds it.
#[cfg(any(test, feature = "test-utils"))]
#[must_use]
pub fn hold_fanout_row_for_test(id: &FanoutId) -> Option<RowHoldForTest> {
    Driving::claim(id).map(RowHoldForTest)
}

/// Completes once a call starts waiting for a row another drive holds.
#[cfg(any(test, feature = "test-utils"))]
pub async fn a_row_is_waited_for_test() {
    ROW_WAITED.notified().await;
}

/// Completes once no drive of `id`'s row is under way: what a test seam that
/// drives a record beside a live plane waits on instead of the clock.
#[cfg(any(test, feature = "test-utils"))]
pub async fn fanout_row_let_go_for_test(id: &FanoutId) {
    Driving::let_go(id.message()).await;
}

/// Called with a change's own row just before its call first drives it.
#[cfg(any(test, feature = "test-utils"))]
type ChangeDriveHook = Box<dyn FnOnce(&FanoutId) + Send>;

#[cfg(any(test, feature = "test-utils"))]
static BEFORE_CHANGE_DRIVE: Mutex<Vec<(GroupId, ChangeDriveHook)>> = Mutex::new(Vec::new());

/// Runs `hook` with the row of `group_id`'s next change just before its call
/// drives it.
#[cfg(any(test, feature = "test-utils"))]
pub fn before_next_change_drive_for_test(
    group_id: &GroupId,
    hook: impl FnOnce(&FanoutId) + Send + 'static,
) {
    BEFORE_CHANGE_DRIVE
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .push((group_id.clone(), Box::new(hook)));
}

/// What a drive sends through: one fanout's signed event to one relay,
/// answered with what that relay did. [`FanoutTransport`](super::FanoutTransport)
/// in the product.
#[async_trait::async_trait]
pub trait FanoutSend: Send + Sync {
    /// Takes `target`'s relay for one call, waiting no longer than
    /// [`GATE_WAIT_SECS`] for whoever has it. `None` when it could not be
    /// had: the driver then begins no attempt for that relay.
    async fn take(&self, target: &str) -> Option<Taken>;

    /// Sends `message`'s event to `target`, a relay URL exactly as the fanout
    /// froze it, under `taken`, which is held until the call has returned.
    async fn publish(
        &self,
        target: &str,
        message: &TransportMessage,
        taken: Taken,
    ) -> FanoutTargetOutcome;

    /// Offers a location's `event` to every one of `targets` — relay URLs
    /// exactly as its record froze them — once, inside the location window,
    /// and answers what the transport did, unchanged: one relay's `OK` is a
    /// success, and when no relay took it and a relay's `invalid:`,
    /// `blocked:` or unprefixed refusal blamed the timestamp it is
    /// [`RelayError::DeviceClockRejected`](crate::relay::RelayError::DeviceClockRejected)
    /// (`clock_skew::classify_publish_outcome`).
    ///
    /// Haven's own transport, not MDK's relay client: one attempt a relay
    /// where that client makes up to three, and the relay's words kept for
    /// the clock verdict where it discards them
    /// (`docs/MDK_UPSTREAM_TRACKER.md` T-APP-TRANSPORT). No relay is taken
    /// for it ([`Self::take`]): a location never waits behind a commit's
    /// call, and never makes one wait.
    async fn publish_location(
        &self,
        event: &nostr::Event,
        targets: &[String],
    ) -> RelayResult<PublishResult>;
}

/// A relay held for one fanout call ([`FanoutSend::take`]): nothing else is
/// sent to it through the same transport until this is dropped.
///
/// It is taken BEFORE the attempt is stored, because MDK's record counts an
/// attempt from the moment it is marked as begun
/// (`traits/src/transport_adapter.rs` 553-557) and that count is what paces
/// the relay: a call that waited behind another send and never left the
/// device must not be stored at all.
pub struct Taken {
    _gates: Vec<tokio::sync::OwnedMutexGuard<()>>,
}

impl Taken {
    /// Holding `gates`.
    pub(super) const fn holding(gates: Vec<tokio::sync::OwnedMutexGuard<()>>) -> Self {
        Self { _gates: gates }
    }

    /// For a transport, or a target, with nothing to hold.
    #[must_use]
    pub const fn nothing() -> Self {
        Self { _gates: Vec::new() }
    }
}

/// The clock a fanout's staging and attempt times are read from.
pub trait FanoutClock: Send + Sync {
    /// Milliseconds since the Unix epoch.
    fn now_ms(&self) -> u64;

    /// Completes once this clock reads `at_ms`: how a call's budget ends a
    /// wait on a relay. The device's clock waits the difference out; a clock
    /// a test sets completes when the test moves it there.
    fn until<'a>(&'a self, at_ms: u64) -> Pin<Box<dyn Future<Output = ()> + Send + 'a>> {
        let wait = Duration::from_millis(at_ms.saturating_sub(self.now_ms()));
        Box::pin(tokio::time::sleep(wait))
    }
}

/// The device's wall clock.
pub struct WallClock;

impl FanoutClock for WallClock {
    fn now_ms(&self) -> u64 {
        u64::try_from(chrono::Utc::now().timestamp_millis()).unwrap_or(0)
    }
}

// ── Pacing: when a relay may be sent to again ────────────────────────────────

/// The first wait before an event is sent again to a relay whose answer left
/// nothing proven: a timeout, a lost `OK`, an interrupted call.
///
/// MDK's `FROZEN_FANOUT_AMBIGUOUS_RETRY_BASE_MS`, by value (v0.10.4
/// `marmot-account/src/runtime.rs` 71).
pub const AMBIGUOUS_RETRY_BASE_MS: u64 = 30_000;

/// The longest wait between two calls to one relay. MDK's
/// `FROZEN_FANOUT_AMBIGUOUS_RETRY_MAX_MS`, by value (`runtime.rs` 72).
pub const RETRY_MAX_MS: u64 = 3_600_000;

/// The wait after a call that could not reach the relay at all, for the first
/// [`UNAVAILABLE_PROMPT_CALLS`] such calls. MDK's
/// `FROZEN_FANOUT_UNAVAILABLE_RETRY_DELAY_MS`, by value (`runtime.rs` 76).
pub const UNAVAILABLE_RETRY_DELAY_MS: u64 = 5_000;

/// How many unreachable calls in a row are retried promptly.
///
/// Each of them at [`UNAVAILABLE_RETRY_DELAY_MS`]; after that the waits
/// double from [`AMBIGUOUS_RETRY_BASE_MS`]. Haven's: MDK's host retries an
/// unreachable relay at five seconds without end.
pub const UNAVAILABLE_PROMPT_CALLS: u32 = 3;

/// The first wait after a relay answered `rate-limited:`; it doubles from
/// there. Haven's: MDK's host retries such a relay after five seconds.
pub const RATE_LIMITED_RETRY_BASE_MS: u64 = 60_000;

/// A rate-limited wait is stretched by up to one part in this many.
pub const RATE_LIMITED_JITTER_DIVISOR: u64 = 4;

/// How many times one drive asks the engine to confirm an acknowledged
/// commit when the store answers that it is busy.
///
/// MDK's host's `MAX_CONFIRM_ATTEMPTS`, by value (`runtime.rs` 3118): the
/// confirm is idempotent, and its durable transaction either lands whole or
/// not at all.
pub const CONFIRM_ATTEMPTS: u32 = 4;

/// How long after it was staged a fanout is still retried.
///
/// Haven's bound, with two uses: an applied commit's record ends then, and a
/// pending commit that was never possibly exposed is undone then. The figure
/// is MDK's `TRANSPORT_FANOUT_RETENTION_SECS` (`runtime.rs` 70), which MDK
/// applies to its Welcome records only: its host retries a commit's fanout
/// without end (`docs/MDK_UPSTREAM_TRACKER.md` T-FANOUT).
pub const FANOUT_BOUND_MS: u64 = 24 * 60 * 60 * 1_000;

/// The first wait before the engine's own commit for a circle — the eviction
/// of a member who left — is staged again after the driver rolled one back.
///
/// It doubles with each rollback in a row, to [`RETRY_MAX_MS`]
/// (`SessionManager::restaging_held`). Haven's: MDK re-arms a rolled-back
/// eviction for its next pass.
pub const RESTAGE_BASE_MS: u64 = 60_000;

/// How long a drive waits for a relay another send holds before it leaves
/// that relay for its next pass ([`FanoutSend::take`]).
///
/// The other send is another record's call, a location send, or a plain
/// publish of an event with no record (a Welcome, a relay list). Nothing has
/// been begun by then, and nothing is stored.
pub const GATE_WAIT_SECS: u64 = 5;

/// The longest one row can take in a drive, and so what a wake must still
/// have left for a row to be begun in it.
///
/// The wait for its relays, MDK's client's own ceiling for a call, and every
/// deadline the fold of its resolution may wait out.
pub const ROW_BUDGET_MS: u64 = (GATE_WAIT_SECS + MDK_CALL_CEILING_SECS) * 1_000 + FOLD_BUDGET_MS;

/// The longest the fold of one resolution waits for the engine's own
/// deadlines.
pub const FOLD_BUDGET_MS: u64 = crate::relay::retick::MAX_CONVERGENCE_RETICKS as u64
    * cgka_engine::canonicalization::V1_SETTLEMENT_QUIESCENCE_MS;

/// What a wake must still have left for a publish of something with no
/// record to be begun.
///
/// A Welcome sent from its record, or a proposal no record could be
/// written for: the figure is that publisher's own longest run against
/// relays that never answer.
pub const PUBLISHER_BUDGET_MS: u64 = crate::relay::manager::PUBLISH_LADDER_MS;

/// What a drive asks to be woken after when a relay it wants was not free.
///
/// The relay is being called for another record, or was held by another
/// send for the whole of [`GATE_WAIT_SECS`]: that call ends within MDK's
/// ceiling, and a zero would have a scheduler spin until it does.
pub const BUSY_RETRY_MS: u64 = UNAVAILABLE_RETRY_DELAY_MS;

/// What a relay's last unresolved answer was, which decides how long it is
/// left alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Backoff {
    /// Nothing was proven: MDK's schedule for a possibly exposed target.
    Ambiguous,
    /// The relay could not be reached and nothing was sent.
    Unreachable,
    /// The relay said to slow down.
    RateLimited,
}

/// How long a relay is left alone after its `calls`-th unresolved call in a
/// row, the last of which ended as `backoff`. `seed` spreads a rate-limited
/// wait: devices a relay limited at one moment must not all return at one
/// moment.
fn retry_delay_ms(backoff: Backoff, calls: u32, seed: u64) -> u64 {
    let doubling = |base: u64, doublings: u32| {
        base.saturating_mul(1_u64 << doublings.min(7))
            .min(RETRY_MAX_MS)
    };
    match backoff {
        // MDK's rule, by value (`runtime.rs` 4491-4500).
        Backoff::Ambiguous => doubling(AMBIGUOUS_RETRY_BASE_MS, calls.saturating_sub(1)),
        Backoff::Unreachable if calls <= UNAVAILABLE_PROMPT_CALLS => UNAVAILABLE_RETRY_DELAY_MS,
        Backoff::Unreachable => doubling(
            AMBIGUOUS_RETRY_BASE_MS,
            calls - UNAVAILABLE_PROMPT_CALLS - 1,
        ),
        Backoff::RateLimited => {
            let wait = doubling(RATE_LIMITED_RETRY_BASE_MS, calls.saturating_sub(1));
            wait.saturating_add(seed % (wait / RATE_LIMITED_JITTER_DIVISOR + 1))
                .min(RETRY_MAX_MS)
        }
    }
}

/// When one relay may next be sent a fanout's event, from every stored fanout
/// that still owes it one.
///
/// Per RELAY, never per row: several rows can owe one relay, and a relay that
/// is failing is failing for all of them. Every unresolved call to it —
/// whichever row made it — lengthens the wait, so the calls a relay receives
/// follow one schedule however many rows are waiting on it. MDK's host paces
/// each row on its own (`marmot-account/src/runtime.rs` 4481-4512).
///
/// An acknowledgement from the relay that is later than its latest unresolved
/// call ends the wait: a newer commit it has just taken is followed by the
/// older ones it still owes in the same pass, in staging order. And what
/// failed BEFORE that acknowledgement is history, not part of the relay's
/// present trouble: only unresolved calls begun since count towards its
/// wait, so a record kept long after it ended does not leave a relay that
/// has since proved itself at the longest wait after one new failure.
///
/// A stored instant ahead of `now_ms` is not read at all: the clock was
/// stepped back since it was written. Its own row is then due and is stamped
/// again by the call that follows; but a row that is never stamped again — a
/// finished record kept inert, one the engine no longer holds — would
/// otherwise make every other row owing that relay due on every drive, for
/// the size of the step. Until the clock passes it, that row's part of the
/// relay's history is simply not counted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RelayDue {
    /// Nothing unresolved is on record: it may be sent to now.
    Now,
    /// A call to it is under way for another row.
    Busy,
    /// Not before this instant, in the fanout clock's milliseconds.
    At(u64),
}

fn relay_due(
    all: &[OutboundFanout],
    driven: &OutboundFanout,
    relay: &RelayUrl,
    now_ms: u64,
) -> RelayDue {
    let readable = |at: u64| at <= now_ms;
    let names_relay = |endpoint: &TransportEndpoint| {
        RelayUrl::parse(endpoint.as_str()).ok().as_ref() == Some(relay)
    };
    // The most recent call the relay acknowledged, for any row.
    let acknowledged: Option<u64> = all
        .iter()
        .map(|row| {
            if row.message_id() == driven.message_id() {
                driven
            } else {
                row
            }
        })
        .flat_map(|row| {
            row.request()
                .target
                .endpoints()
                .iter()
                .enumerate()
                .filter(|(index, endpoint)| {
                    names_relay(endpoint)
                        && row.target_status(*index) == Some(FanoutTargetStatus::Accepted)
                })
                .filter_map(|(index, _)| row.target_last_attempt_at_ms(index))
                .collect::<Vec<_>>()
        })
        .filter(|at| readable(*at))
        .max();
    let mut calls = 0_u32;
    // The most recent unresolved call: when it began, how it ended, and the
    // row it was made for.
    let mut latest: Option<(u64, Backoff, u64)> = None;
    for row in all {
        // The driven row is read from the drive's own copy, which already
        // carries what this drive recorded.
        let is_driven = row.message_id() == driven.message_id();
        let row = if is_driven { driven } else { row };
        let mut row_calls = 0_u32;
        for (index, endpoint) in row.request().target.endpoints().iter().enumerate() {
            if !names_relay(endpoint) {
                continue;
            }
            let began = row.target_last_attempt_at_ms(index).unwrap_or(0);
            if !readable(began) {
                continue;
            }
            let backoff = match row.target_status(index) {
                Some(FanoutTargetStatus::Attempting) if !is_driven => {
                    if Driving::under_way(row.message_id()) {
                        return RelayDue::Busy;
                    }
                    // Left by a call that never returned.
                    Backoff::Ambiguous
                }
                Some(FanoutTargetStatus::PossiblyExposed) => Backoff::Ambiguous,
                Some(FanoutTargetStatus::RetryableUnavailable) => {
                    if row
                        .target_failure(index)
                        .is_some_and(|failure| failure.rejection_category.is_some())
                    {
                        Backoff::RateLimited
                    } else {
                        Backoff::Unreachable
                    }
                }
                _ => continue,
            };
            // Failed before the relay last took something: over.
            if acknowledged.is_some_and(|at| at > began) {
                continue;
            }
            // Two spellings of one relay in one row are one call.
            row_calls = row_calls.max(row.target_attempt_count(index));
            if latest.is_none_or(|(at, _, _)| began >= at) {
                let seed = row
                    .message_id()
                    .as_slice()
                    .iter()
                    .take(8)
                    .fold(0_u64, |seed, byte| (seed << 8) | u64::from(*byte));
                latest = Some((began, backoff, seed));
            }
        }
        calls = calls.saturating_add(row_calls);
    }
    // With nothing unresolved since the relay last took an event, what it is
    // still owed follows at once rather than waiting out a back-off it has
    // just shown to be over.
    latest.map_or(RelayDue::Now, |(began, backoff, seed)| {
        RelayDue::At(began.saturating_add(retry_delay_ms(backoff, calls, seed)))
    })
}

/// Where one drive left a commit's fanout.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FanoutStatus {
    /// A relay acknowledged the commit and the engine applied it — in this
    /// drive or an earlier one. Its record lives on while a relay is still
    /// owed an attempt or a retry, and is gone when this drive ended it.
    Confirmed,
    /// Every relay proved it did not take the commit and none was ever
    /// possibly exposed: the engine discarded it.
    RolledBack,
    /// No relay has acknowledged it, and at least one may hold it or could
    /// not be reached. The commit stays staged.
    Unresolved,
    /// The row no longer described a commit the engine holds, and was
    /// removed: its commit had been discarded by some other path (a
    /// different commit the engine held under its ref was rolled back), or
    /// nothing was staged behind it and nothing had been sent under it.
    Stale,
    /// Another drive of this row is under way.
    Busy,
    /// The row is a bare proposal's: there is nothing to confirm or roll
    /// back. It was sent to each relay that was due, and is gone once enough
    /// of them hold it, its day is over, or nothing can act on it any more:
    /// its circle has left its epoch, or this device is no longer in the
    /// circle.
    Proposal,
    /// The row is an application message's: not this function's to drive.
    NotACommit,
    /// No such row: it has ended, or its group is not live.
    Gone,
}

/// What one [`drive_one`] did.
///
/// **No `Debug`, deliberately**: it carries handles, Welcomes and a folded
/// engine batch.
#[must_use]
pub struct DriveOutcome {
    /// Where the commit stands.
    pub status: FanoutStatus,
    /// What resolving the commit released: the locations the engine
    /// replayed, and a proposal whose record could not be written, to be
    /// published once as it is. Never a commit: whatever the resolution and
    /// the advances after it staged is in [`Self::staged`].
    pub replayed: DecryptedIngest,
    /// Fanouts staged while resolving this one: the next eviction of a
    /// cascade, a change the user had queued, a leave proposed again.
    pub staged: Vec<FanoutId>,
    /// The record holds Welcomes that were NOT handed over because their
    /// invite's commit is provisionally set aside. They wait with it.
    pub welcomes_withheld: bool,
    /// The record's commit is still stored as sent, a relay may hold it, and
    /// the engine no longer holds it staged: nothing here can resolve it. The
    /// engine disposes of it in its next convergence pass, which it opens
    /// only when a plane asks for the circle's deadline.
    pub unheld: bool,
    /// What this drive did that its circle must be told whoever was waiting:
    /// each is also kept durably until it is acknowledged
    /// (`SessionManager::change_notice`, `acknowledge_change_notice`).
    pub notes: Vec<ChangeNote>,
    /// How long until a relay this row still owes a call may be sent to
    /// again, or until its bound could end it, when the row is still stored
    /// and something can be done for it then. Nothing for a pending commit a
    /// relay may hold once a day has passed since it was staged: it is sent
    /// again only on a wake the device has for some other reason, so that an
    /// unanswering relay is not handed a timetable of where the device is.
    /// Relative, and never logged.
    pub retry_after_ms: Option<u64>,
    /// What a relay's refusal during this drive blamed on this device's
    /// clock: evidence for the clock check, never the relay's words.
    pub clock_rejected: Option<crate::relay::clock_skew::DeviceClockComplaint>,
    /// The error that cut the drive short after it had already collected
    /// what is above. It is never a reason to roll anything back: the stored
    /// row says where the commit stands.
    pub error: Option<CircleError>,
}

impl DriveOutcome {
    fn of(status: FanoutStatus) -> Self {
        Self {
            status,
            replayed: DecryptedIngest::default(),
            staged: Vec::new(),
            welcomes_withheld: false,
            unheld: false,
            notes: Vec::new(),
            retry_after_ms: None,
            clock_rejected: None,
            error: None,
        }
    }

    /// Takes in what a resolution left, whether or not it failed. `status`
    /// is where the commit stands if it did not.
    fn resolved(
        &mut self,
        status: FanoutStatus,
        resolution: FanoutResolution,
    ) -> Result<(), CircleError> {
        self.replayed.results.extend(resolution.replayed.results);
        self.replayed
            .proposals
            .extend(resolution.replayed.proposals);
        self.staged.extend(resolution.staged);
        match resolution.error {
            None => {
                self.status = status;
                Ok(())
            }
            Some(e) => Err(e),
        }
    }

    /// Whether an error may still be returned in this outcome's place.
    fn carries_nothing(&self) -> bool {
        self.status == FanoutStatus::Unresolved
            && self.replayed.results.is_empty()
            && self.replayed.proposals.is_empty()
            && self.staged.is_empty()
            && !self.welcomes_withheld
            && self.notes.is_empty()
            && self.clock_rejected.is_none()
    }
}

/// What Security Rule 13 lets a drive do with a commit's fanout.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Decision {
    Confirm,
    RollBack,
    Leave,
}

/// Confirm on the first acknowledgement and never before. Roll back only when
/// every frozen target is terminal, none accepted, and none was EVER possibly
/// exposed — read from the record's sticky exposure flags, which outlive a
/// later refusal, never from the targets' current statuses. The engine checks
/// the first two (v0.10.4 `cgka-engine/src/publish.rs` 393-411) and not the
/// third; MDK's host does (`marmot-account/src/runtime.rs` 4041-4044).
///
/// A record frozen for no relay proves nothing about its commit — it is the
/// trial an open wrote for a removal it found staged, not yet given the
/// relays it may already be on — and is never rolled back.
///
/// Only [`DriveMode::Full`] rolls a commit back: [`DriveMode::FinishOnly`]
/// leaves a record every relay refused exactly as it is stored. Either mode
/// confirms on an acknowledgement — whether a drive that only finishes has
/// the room to is [`settle`]'s to say.
fn decide(fanout: &OutboundFanout, mode: DriveMode) -> Decision {
    let outcome = fanout.outcome();
    if outcome.mls_confirmation_required {
        Decision::Confirm
    } else if mode == DriveMode::FinishOnly {
        Decision::Leave
    } else if fanout.pending_ref().is_some()
        && !fanout.request().target.endpoints().is_empty()
        && outcome.fanout_complete
        && outcome.accepted_targets == 0
        && !fanout.possible_exposure()
    {
        Decision::RollBack
    } else {
        Decision::Leave
    }
}

/// One relay a drive sends to: every frozen target that names it, the first
/// being the spelling it is sent under.
struct Attempt {
    spellings: Vec<usize>,
}

/// The relays `fanout` still owes an attempt and that may be sent to at
/// `now_ms`, each once, and how long until the soonest of the others may be.
///
/// A routing component is unique by bytes only, so two of its entries can
/// spell one relay: a second call would be answered `duplicate:` and count
/// one operator's acknowledgement twice.
///
/// Two things are due whatever the schedule says. A wait longer than any the
/// schedule gives means the stored attempt lies ahead of the clock — the
/// clock was stepped back — and waiting it out would leave a pending removal
/// unsent for the size of the step. And a commit nothing has yet been sent
/// for is not left behind a back-off some other commit earned: when none of
/// its relays is free, its first drive calls the soonest one anyway — one
/// call per commit, ever.
fn due_attempts(
    all: &[OutboundFanout],
    fanout: &OutboundFanout,
    now_ms: u64,
) -> (Vec<Attempt>, Option<u64>) {
    let (due, retry_after_ms, _) = due_or_busy(all, fanout, now_ms);
    (due, retry_after_ms)
}

/// [`due_attempts`], and whether a relay `fanout` still owes an attempt is
/// being called for another row: owed, not due only because it is taken, and
/// so not tried by a drive that finds it so.
fn due_or_busy(
    all: &[OutboundFanout],
    fanout: &OutboundFanout,
    now_ms: u64,
) -> (Vec<Attempt>, Option<u64>, bool) {
    let mut owed: Vec<(Option<RelayUrl>, Attempt)> = Vec::new();
    for (index, endpoint) in fanout.request().target.endpoints().iter().enumerate() {
        if !fanout
            .target_status(index)
            .is_some_and(FanoutTargetStatus::is_outstanding)
        {
            continue;
        }
        let relay = RelayUrl::parse(endpoint.as_str()).ok();
        match owed
            .iter_mut()
            .find(|(known, _)| relay.is_some() && *known == relay)
        {
            Some((_, attempt)) => attempt.spellings.push(index),
            None => owed.push((
                relay,
                Attempt {
                    spellings: vec![index],
                },
            )),
        }
    }
    let mut retry_after_ms: Option<u64> = None;
    let mut due = Vec::new();
    let mut soonest: Option<(u64, Attempt)> = None;
    let mut a_relay_is_busy = false;
    for (relay, attempt) in owed {
        // A target that parses as no relay is refused by the transport before
        // anything is handed over: nothing to pace.
        let wait = match relay.map_or(RelayDue::Now, |relay| {
            relay_due(all, fanout, &relay, now_ms)
        }) {
            RelayDue::Now => None,
            RelayDue::At(at) => {
                let at = at.max(hourly_floor(fanout, &attempt, now_ms));
                (at > now_ms && at - now_ms <= RETRY_MAX_MS).then(|| (at - now_ms, false))
            }
            // The other row's call ends within the transport's own ceiling;
            // this row asks again on its next drive.
            RelayDue::Busy => Some((BUSY_RETRY_MS, true)),
        };
        match wait {
            None => due.push(attempt),
            Some((wait, busy)) => {
                a_relay_is_busy |= busy;
                retry_after_ms = Some(retry_after_ms.map_or(wait, |least| least.min(wait)));
                if !busy && soonest.as_ref().is_none_or(|(least, _)| wait < *least) {
                    soonest = Some((wait, attempt));
                }
            }
        }
    }
    // A commit only. A leave is proposed again at every epoch its circle
    // reaches, and any member can move the epoch: a first call that ignored
    // the relay's wait would be a call per epoch to a relay that is backing
    // off.
    let a_commit_nothing_was_sent_for = fanout.mls_state() != FanoutMlsState::NotApplicable
        && fanout
            .target_statuses()
            .iter()
            .all(|status| *status == FanoutTargetStatus::NotAttempted);
    if due.is_empty() && a_commit_nothing_was_sent_for {
        due.extend(soonest.map(|(_, attempt)| attempt));
    }
    (due, retry_after_ms, a_relay_is_busy)
}

/// Whether `fanout` is a pending commit a relay may hold whose first day is
/// over: one that is sent again only on wakes the app has anyway
/// ([`wake_after_ms`]), and to a relay at most once an hour
/// ([`hourly_floor`]).
fn exposed_past_its_first_day(fanout: &OutboundFanout, now_ms: u64) -> bool {
    fanout.pending_ref().is_some()
        && fanout.possible_exposure()
        && now_ms.saturating_sub(fanout.created_at_ms()) >= FANOUT_BOUND_MS
}

/// The earliest `fanout` may next be sent to the relay `attempt` names when
/// it is [`exposed_past_its_first_day`]: an hour after its own last call
/// there. Zero for every other record.
///
/// The schedule's waits grow with the calls a relay has been made, so a
/// commit whose device was off for its first day would otherwise be sent
/// every few minutes of the second — the same bytes, from wherever the
/// device then is, to a relay that may be answering nothing on purpose.
fn hourly_floor(fanout: &OutboundFanout, attempt: &Attempt, now_ms: u64) -> u64 {
    if !exposed_past_its_first_day(fanout, now_ms) {
        return 0;
    }
    attempt
        .spellings
        .iter()
        .filter_map(|index| fanout.target_last_attempt_at_ms(*index))
        .max()
        .map_or(0, |last| last.saturating_add(RETRY_MAX_MS))
}

/// A stored fanout refused an update the driver built from its own targets.
fn refused(_: TransportAdapterError) -> CircleError {
    CircleError::Mls("the stored fanout refused an update".to_string())
}

/// Stores a target found `Attempting` as possibly exposed: its call never
/// returned — the process died, or the drive's future was dropped — and the
/// frame it may have queued or sent is still out there to be answered.
fn record_interrupted(fanout: &mut OutboundFanout) -> Result<bool, CircleError> {
    let endpoints = fanout.request().target.endpoints().to_vec();
    let mut any = false;
    for (index, endpoint) in endpoints.iter().enumerate() {
        if fanout.target_status(index) == Some(FanoutTargetStatus::Attempting) {
            fanout
                .record_target_failure(index, interrupted(endpoint))
                .map_err(refused)?;
            any = true;
        }
    }
    Ok(any)
}

/// Records one relay's answer on every frozen target that spells it.
fn record(
    fanout: &mut OutboundFanout,
    attempt: &Attempt,
    answer: FanoutTargetOutcome,
) -> Result<(), CircleError> {
    let failure = match answer {
        FanoutTargetOutcome::Accepted => None,
        FanoutTargetOutcome::Failed(failure) => Some(failure.into_mdk_failure()),
    };
    for &index in &attempt.spellings {
        match &failure {
            None => fanout.mark_target_accepted(index).map_err(refused)?,
            Some(failure) => {
                let endpoint = fanout.request().target.endpoints()[index].clone();
                fanout
                    .record_target_failure(
                        index,
                        TransportEndpointFailure {
                            endpoint,
                            ..failure.clone()
                        },
                    )
                    .map_err(refused)?
            }
        };
    }
    Ok(())
}

// ── When a fanout ends ───────────────────────────────────────────────────────

/// How many distinct relays have acknowledged `fanout`'s event. Two frozen
/// spellings of one relay are one acknowledgement, as they were one call.
fn accepted_relays(fanout: &OutboundFanout) -> usize {
    let mut relays: Vec<RelayUrl> = Vec::new();
    for (index, endpoint) in fanout.request().target.endpoints().iter().enumerate() {
        if fanout.target_status(index) != Some(FanoutTargetStatus::Accepted) {
            continue;
        }
        if let Ok(relay) = RelayUrl::parse(endpoint.as_str()) {
            if !relays.contains(&relay) {
                relays.push(relay);
            }
        }
    }
    relays.len()
}

/// Whether a frozen relay has not had one attempt run to an answer: never
/// begun, or begun and never returned. Such a target is owed that attempt
/// whatever else is true of the record (`transports/nostr.md`, "Publish
/// targets and acknowledgements": every snapshotted relay is attempted).
fn owes_an_attempt(fanout: &OutboundFanout) -> bool {
    (0..fanout.target_statuses().len()).any(|index| match fanout.target_status(index) {
        Some(FanoutTargetStatus::NotAttempted) => true,
        Some(FanoutTargetStatus::PossiblyExposed) => fanout
            .target_failure(index)
            .is_some_and(|failure| failure.reason == INTERRUPTED),
        _ => false,
    })
}

/// The instant an APPLIED commit's day of retries is counted from: when it
/// was staged, or when the first relay that holds it was sent it, whichever
/// is later. A commit a relay took only after a long silence would otherwise
/// end in the pass that applied it, held by that one relay.
fn retried_since_ms(fanout: &OutboundFanout) -> u64 {
    let first_held = (0..fanout.target_statuses().len())
        .filter(|index| fanout.target_status(*index) == Some(FanoutTargetStatus::Accepted))
        .filter_map(|index| fanout.target_last_attempt_at_ms(index))
        .min();
    fanout.created_at_ms().max(first_held.unwrap_or(0))
}

/// Whether an APPLIED commit's record has nothing left to do: every frozen
/// relay has answered an attempt, and either none is left to retry, or two
/// distinct relays hold the commit (one, when one is all it was frozen for:
/// the count frozen at staging), or the bound has passed
/// ([`retried_since_ms`]).
///
/// The bound is read off the device's clock, so a clock may end a record
/// early: that costs retries, never the commit. A stored instant that lies
/// AHEAD of the clock by more than the schedule's longest wait means the
/// clock was stepped back and the record's age can no longer be known; it
/// ends then too, rather than live on for the size of the step. A smaller
/// difference is an ordinary correction and ends nothing.
fn finished(fanout: &OutboundFanout, now_ms: u64) -> bool {
    if owes_an_attempt(fanout) {
        return false;
    }
    let stepped_back = far_ahead(fanout.created_at_ms(), now_ms)
        || (0..fanout.target_statuses().len()).any(|index| {
            fanout
                .target_last_attempt_at_ms(index)
                .is_some_and(|instant| far_ahead(instant, now_ms))
        });
    fanout.outcome().fanout_complete
        || accepted_relays(fanout) >= fanout.request().required_acks
        || stepped_back
        || now_ms.saturating_sub(retried_since_ms(fanout)) >= FANOUT_BOUND_MS
}

/// Whether a stored `instant` lies ahead of the clock by more than the
/// schedule's longest wait: the clock was stepped back, and an age read off
/// it can no longer be known.
const fn far_ahead(instant: u64, now_ms: u64) -> bool {
    instant.saturating_sub(now_ms) > RETRY_MAX_MS
}

/// Ends the record of a group finished on this device
/// ([`FanoutStanding::GroupGone`]) as a finished record ends, and sends
/// nothing of it: the commit or proposal it holds belongs to a copy that is
/// removed, disbanded or gone.
async fn end_dead(
    session: &crate::nostr::mls::SessionManager,
    fanout: &StoredFanout,
    clock: &dyn FanoutClock,
    out: &mut DriveOutcome,
) -> Result<Option<(StoredFanout, bool)>, CircleError> {
    let (record, now_ms) = (fanout.as_mdk_fanout(), clock.now_ms());
    session
        .end_fanout(fanout, |all| changes_a_wait(all, record, now_ms))
        .await?;
    out.status = FanoutStatus::Gone;
    Ok(None)
}

/// Whether deleting `fanout` would change when some relay is next called for
/// a record that still has calls to make.
///
/// A relay's wait is worked out from what is on record for it across every
/// stored fanout ([`relay_due`]): its unanswered calls, and its latest
/// acknowledgement. A record that ends takes its part of that with it — the
/// records that remain would start a failing relay's schedule over, or lose
/// sight of a relay that has just shown it is back. So a finished record is
/// kept — inert: it makes no call — until its end changes no such wait.
fn changes_a_wait(all: &[OutboundFanout], fanout: &OutboundFanout, now_ms: u64) -> bool {
    let rest: Vec<OutboundFanout> = all
        .iter()
        .filter(|row| row.message_id() != fanout.message_id())
        .cloned()
        .collect();
    let mut relays: Vec<RelayUrl> = Vec::new();
    for (index, endpoint) in fanout.request().target.endpoints().iter().enumerate() {
        let on_record = matches!(
            fanout.target_status(index),
            Some(
                FanoutTargetStatus::Accepted
                    | FanoutTargetStatus::PossiblyExposed
                    | FanoutTargetStatus::RetryableUnavailable
                    | FanoutTargetStatus::Attempting
            )
        );
        if let Some(relay) = RelayUrl::parse(endpoint.as_str())
            .ok()
            .filter(|relay| on_record && !relays.contains(relay))
        {
            relays.push(relay);
        }
    }
    relays.iter().any(|relay| {
        rest.iter().any(|other| {
            // A record that has itself ended makes no call to wait for.
            let calls = other.pending_ref().is_some() || !finished(other, now_ms);
            let owes =
                other
                    .request()
                    .target
                    .endpoints()
                    .iter()
                    .enumerate()
                    .any(|(index, endpoint)| {
                        other
                            .target_status(index)
                            .is_some_and(FanoutTargetStatus::is_outstanding)
                            && RelayUrl::parse(endpoint.as_str()).ok().as_ref() == Some(relay)
                    });
            calls
                && owes
                && relay_due(all, other, relay, now_ms) != relay_due(&rest, other, relay, now_ms)
        })
    })
}

/// Whether a PENDING commit has reached the end Haven gives a change no relay
/// took: the bound has passed on the device's clock, nothing was ever
/// possibly exposed, and every relay still outstanding has answered an
/// attempt with "could not be reached" or "not now".
///
/// This says only what the record shows. Whether the commit may be undone at
/// all is its caller's question: one that removes a member never is
/// (`SessionManager::commit_removes_nobody`).
///
/// Ending it is a rollback, so the clock is believed only in the direction
/// that keeps the commit: a clock that reads before the bound — stepped back,
/// or never past it — undoes nothing, however long that keeps the commit
/// pending. A clock stepped forward by more than the schedule's longest wait
/// finds every relay due, and each is tried once more before this is asked.
fn unreachable_past_the_bound(fanout: &OutboundFanout, now_ms: u64) -> bool {
    let outstanding = fanout.outstanding_target_indexes();
    fanout.pending_ref().is_some()
        && !outstanding.is_empty()
        && !fanout.possible_exposure()
        && fanout.outcome().accepted_targets == 0
        && now_ms
            .checked_sub(fanout.created_at_ms())
            .is_some_and(|age| age >= FANOUT_BOUND_MS)
        && outstanding.iter().all(|index| {
            fanout.target_status(*index) == Some(FanoutTargetStatus::RetryableUnavailable)
        })
}

/// How long until `fanout`'s driver has something to do for it: the soonest
/// relay it still owes a call, across every stored fanout, or the bound that
/// could end it. `None` when no wake of its own is wanted.
///
/// `undoable` says a pending commit may be undone at its bound.
fn wake_after_ms(
    all: &[OutboundFanout],
    fanout: &OutboundFanout,
    now_ms: u64,
    undoable: bool,
) -> Option<u64> {
    let pending = fanout.pending_ref().is_some();
    if exposed_past_its_first_day(fanout, now_ms) {
        return None;
    }
    let relays = due_attempts(all, fanout, now_ms).1;
    let age = now_ms.saturating_sub(fanout.created_at_ms());
    let bound = if pending {
        (undoable && !fanout.possible_exposure()).then(|| FANOUT_BOUND_MS.saturating_sub(age))
    } else {
        Some(
            retried_since_ms(fanout)
                .saturating_add(FANOUT_BOUND_MS)
                .saturating_sub(now_ms),
        )
    }
    // A bound already past that did not end the record in this drive cannot:
    // a relay is still owed its attempt, and that relay's wait is the hint.
    .filter(|wait| *wait > 0);
    match (relays, bound) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    }
}

/// Where [`settle`] left a row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Settled {
    /// The row is gone.
    Gone,
    /// The row has nothing left to do and is kept, making no call, so that
    /// its end does not restart a relay's schedule ([`changes_a_wait`]).
    Inert,
    /// The row may still have a relay to call.
    Open,
}

/// One step of [`settle`]: what the drive has done so far, the mode it is
/// in at that moment, and when its wake ends.
#[derive(Clone, Copy)]
struct Step<'a> {
    /// Whether this drive has tried every relay that was due.
    tried: bool,
    /// The mode, read at this step.
    mode: DriveMode,
    /// Where it was read, for each act to read again where it is made.
    source: &'a dyn ModeSource,
    /// The end of the wake's budget, an instant on the drive's clock.
    deadline_ms: Option<u64>,
}

/// Whether a wake that ends at `deadline_ms` still has `needs_ms` left. A
/// drive that only finishes begins nothing outside a known budget.
fn has_room(
    clock: &dyn FanoutClock,
    deadline_ms: Option<u64>,
    needs_ms: u64,
    mode: DriveMode,
) -> bool {
    deadline_ms.map_or(mode == DriveMode::Full, |deadline| {
        clock.now_ms().saturating_add(needs_ms) <= deadline
    })
}

/// Whether this step may confirm `id`'s acknowledged commit. A full drive
/// may. A drive that only finishes may not confirm a change of the circle's
/// relays, which is a full drive's — a record whose intent cannot be read is
/// taken for one — and confirms anything else only in a wake that can see
/// the fold through, which waits out the engine's own deadlines: without,
/// the call asks to be driven again.
fn may_confirm(
    session: &SessionManager,
    id: &FanoutId,
    clock: &dyn FanoutClock,
    step: Step<'_>,
    out: &mut DriveOutcome,
) -> bool {
    if step.mode == DriveMode::Full {
        return true;
    }
    if session.changes_routing(id) {
        return false;
    }
    let room = has_room(clock, step.deadline_ms, FOLD_BUDGET_MS, step.mode);
    if !room {
        out.retry_after_ms = Some(0);
    }
    room
}

/// The wake's end as a step may count on it: already past, once what the
/// call began under has ended. Nothing that needs room is then begun — no
/// confirm of a stored acknowledgement, no further call.
fn budget(mode: &dyn ModeSource, deadline_ms: Option<u64>) -> Option<u64> {
    if mode.stands() {
        deadline_ms
    } else {
        Some(0)
    }
}

/// Does what the stored answers allow.
///
/// A pending commit is confirmed on an acknowledgement, rolled back on proof,
/// and — `after_attempts`, once this drive has tried what was due — undone
/// when it is [`unreachable_past_the_bound`] and known to remove nobody. An
/// applied commit's Welcomes are released, and once it is [`finished`] its
/// record makes no further call and is deleted as soon as that shortens no
/// relay's wait.
async fn settle(
    circle: &CircleManager,
    id: &FanoutId,
    fanout: &mut StoredFanout,
    clock: &dyn FanoutClock,
    out: &mut DriveOutcome,
    applied: &mut bool,
    step: Step<'_>,
) -> Result<Settled, CircleError> {
    let mode = step.mode;
    let still = Still::new(step.source, mode);
    let session = circle.session();
    if !*applied {
        // Known only from a mark written in the hold that staged the commit;
        // anything else reads as a commit that removes a member, which is
        // never undone for want of a relay: it shares nothing with anybody
        // while it waits, and undone it would let the circle's queued
        // locations go out to the member just removed.
        let removes_nobody = session.commit_removes_nobody(id.group());
        let at_its_bound = mode == DriveMode::Full
            && step.tried
            && removes_nobody
            && unreachable_past_the_bound(fanout.as_mdk_fanout(), clock.now_ms());
        if at_its_bound && !end_untaken_targets(session, fanout, clock, still).await? {
            return Ok(Settled::Inert);
        }
        match decide(fanout.as_mdk_fanout(), mode) {
            Decision::Confirm => {
                if !may_confirm(session, id, clock, step, out) {
                    return Ok(Settled::Inert);
                }
                let Some(resolution) = circle
                    .confirm_fanout(fanout, clock.now_ms(), mode, still)
                    .await
                else {
                    return Ok(Settled::Inert);
                };
                if let Err(e) = out.resolved(FanoutStatus::Confirmed, resolution) {
                    // The stored row says whether the commit was applied; the
                    // error does not. Applied beside an error is applied.
                    if matches!(
                        session.fanout_standing(id).await,
                        Ok(FanoutStanding::Confirmed { .. })
                    ) {
                        out.status = FanoutStatus::Confirmed;
                    }
                    return Err(e);
                }
                *applied = true;
            }
            Decision::RollBack => {
                let Some(resolution) = circle.roll_back_fanout(fanout, clock.now_ms(), still).await
                else {
                    return Ok(Settled::Inert);
                };
                let rolled_back = fanout.rolled_back();
                if rolled_back {
                    out.status = FanoutStatus::RolledBack;
                    out.notes.push(if removes_nobody {
                        ChangeNote::ChangeUndone
                    } else {
                        ChangeNote::RemovalUndone
                    });
                    if at_its_bound {
                        log::warn!("[Fanout] a change no relay took within its bound was undone");
                    }
                }
                out.resolved(FanoutStatus::RolledBack, resolution)?;
                return Ok(Settled::Gone);
            }
            Decision::Leave => return Ok(Settled::Open),
        }
    }
    // An applied commit's record is a full drive's: its Welcomes, the relays
    // it still owes and its end. A leave's proposal is driven in either mode
    // ([`take_up_to_finish`]).
    if mode == DriveMode::FinishOnly
        && fanout.as_mdk_fanout().mls_state() != FanoutMlsState::NotApplicable
    {
        return Ok(Settled::Inert);
    }
    if !fanout
        .as_mdk_fanout()
        .pending_post_confirmation_welcomes()
        .is_empty()
    {
        let Some(handed) = session
            .hand_over_welcomes(fanout, clock.now_ms(), still)
            .await?
        else {
            return Ok(Settled::Inert);
        };
        out.welcomes_withheld |= handed.withheld;
        if handed.reinvite {
            out.notes.push(ChangeNote::ReinviteOwed);
        }
    }
    if !finished(fanout.as_mdk_fanout(), clock.now_ms()) {
        return Ok(Settled::Open);
    }
    // A record still holding a Welcome — its hand-over left it there: an
    // unread route, an engine that could not answer — keeps it for the next
    // drive's hand-over: it makes no call, and stays.
    if !fanout
        .as_mdk_fanout()
        .pending_post_confirmation_welcomes()
        .is_empty()
    {
        return Ok(Settled::Inert);
    }
    let record = fanout.as_mdk_fanout();
    let now_ms = clock.now_ms();
    let ended = session
        .end_fanout(fanout, |all| changes_a_wait(all, record, now_ms))
        .await?;
    Ok(if ended { Settled::Gone } else { Settled::Inert })
}

/// Ends, at the bound, every target `fanout` still owes as one no relay
/// took. Answers `false`, with nothing stored, when what the pass decided
/// under no longer holds once the engine is had.
///
/// `RetryableUnavailable` reaches `Failed` only through `Attempting`, and
/// the store checks each step (`traits/src/transport_adapter.rs` 784-802).
/// Nothing is sent between the two: a row found between them reads as an
/// interrupted attempt, possibly exposed, and is kept.
async fn end_untaken_targets(
    session: &SessionManager,
    fanout: &mut StoredFanout,
    clock: &dyn FanoutClock,
    still: Still<'_>,
) -> Result<bool, CircleError> {
    let endpoints = fanout.as_mdk_fanout().request().target.endpoints().to_vec();
    let outstanding = fanout.as_mdk_fanout().outstanding_target_indexes();
    for index in &outstanding {
        fanout
            .as_mdk_fanout_mut()
            .mark_attempt_started_at(*index, clock.now_ms())
            .map_err(refused)?;
    }
    if !session.put_fanout_while(fanout, still).await? {
        return Ok(false);
    }
    for index in outstanding {
        fanout
            .as_mdk_fanout_mut()
            .record_target_failure(index, not_taken(&endpoints[index]))
            .map_err(refused)?;
    }
    session.put_fanout(fanout).await?;
    Ok(true)
}

/// A target no relay took, ended at the bound: nothing was sent under this
/// failure. Not "not reached": a relay that answered `rate-limited:` was.
fn not_taken(target: &TransportEndpoint) -> TransportEndpointFailure {
    TransportEndpointFailure {
        endpoint: target.clone(),
        reason: "not taken within the bound".to_owned(),
        kind: TransportEndpointFailureKind::NotExposed,
        rejection_category: None,
    }
}

/// Whether a relay may already hold `fanout`'s event: one acknowledged it,
/// an attempt may have exposed it, or one was begun and never returned.
/// Not an attempt that found its relay unreachable: nothing left the device.
fn a_relay_may_hold(fanout: &OutboundFanout) -> bool {
    fanout.outcome().accepted_targets > 0
        || fanout.possible_exposure()
        || fanout
            .target_statuses()
            .contains(&FanoutTargetStatus::Attempting)
}

/// Whether no spelling of the relay `attempt` names has had an attempt.
fn never_attempted(fanout: &OutboundFanout, attempt: &Attempt) -> bool {
    attempt
        .spellings
        .iter()
        .all(|index| fanout.target_status(*index) == Some(FanoutTargetStatus::NotAttempted))
}

/// [`take_up`] for a drive that only finishes. One record alone is taken
/// up: a pending commit the engine holds that a relay may already hold
/// ([`a_relay_may_hold`]) — a first transmission the operating system cut
/// would leave a commit nobody held stored as possibly exposed for good, and
/// so never undone. A confirm the engine stored and did not finish is
/// finished. Everything else is left exactly as it is stored.
async fn take_up_to_finish(
    circle: &CircleManager,
    clock: &dyn FanoutClock,
    id: &FanoutId,
    standing: FanoutStanding,
    out: &mut DriveOutcome,
) -> Result<Option<(StoredFanout, bool)>, CircleError> {
    match standing {
        FanoutStanding::Staged(fanout) if a_relay_may_hold(fanout.as_mdk_fanout()) => {
            Ok(Some((fanout, false)))
        }
        FanoutStanding::Confirmed {
            unfinished: Some(pending),
            ..
        } => {
            out.status = FanoutStatus::Confirmed;
            // Finished, this device seals at the new epoch for the circle's
            // new relays while its subscriptions are still on the set the
            // app last gave it: it would miss a later removal and seal for
            // whoever was removed. So a change of the relays is finished
            // here only once its circle is durably waiting for the
            // foreground, which is what holds its background sends.
            if circle.session().changes_routing(id)
                && !circle.session().await_foreground(id.group())
            {
                return Ok(None);
            }
            let resolution = circle
                .finish_confirmed_fanout(
                    pending,
                    clock.now_ms(),
                    Still::always(&DriveMode::FinishOnly),
                )
                .await;
            out.resolved(FanoutStatus::Confirmed, resolution)?;
            Ok(None)
        }
        FanoutStanding::Confirmed { .. } => {
            out.status = FanoutStatus::Confirmed;
            Ok(None)
        }
        // A leave the user asked for in front of the app is sent from the
        // background too, its first attempt included (`send_what_is_due`),
        // and so is the engine's own proposal for a later epoch: holding it
        // would keep them in a circle they asked to leave. Its record ends
        // as in the full mode.
        FanoutStanding::Proposal {
            fanout,
            spent: false,
        } => {
            out.status = FanoutStatus::Proposal;
            Ok(Some((fanout, true)))
        }
        FanoutStanding::Proposal {
            fanout,
            spent: true,
        } => {
            out.status = FanoutStatus::Proposal;
            let (record, now_ms) = (fanout.as_mdk_fanout(), clock.now_ms());
            circle
                .session()
                .end_fanout(&fanout, |all| changes_a_wait(all, record, now_ms))
                .await?;
            Ok(None)
        }
        // Local, and nothing sent: a background drive may end it too.
        FanoutStanding::GroupGone(fanout) => end_dead(circle.session(), &fanout, clock, out).await,
        _ => Ok(None),
    }
}

/// Drives one commit's stored fanout through one pass.
///
/// Reads the STORED row, never a copy from an earlier call — after a restart
/// that is the row MDK's hydrate restored the staged commit from, so what is
/// sent is the frozen event, byte for byte, never a commit staged again.
/// Calls `transport` at most once per distinct relay that is both still owed
/// an attempt and due one ([`relay_due`]), with the session lock released;
/// when every such call has answered, stores the answers and resolves.
/// Nothing is retried inside the call.
///
/// Every answer is collected before anything is stored or resolved, as MDK's
/// host does (`marmot-account/src/runtime.rs` 3864-3927): a call holds its
/// relay's gate until it returns, and a drive that stopped to store or to
/// fold after the first answer would leave the others unpolled behind a held
/// gate, where their own timeouts turn a prompt answer into an ambiguous one.
///
/// An applied commit's record is driven the same way for the relays it still
/// owes: each frozen relay gets one attempt that runs to an answer, and the
/// rest are retried on the same schedule until two distinct relays hold the
/// commit or [`FANOUT_BOUND_MS`] has passed ([`retried_since_ms`]). From then
/// on it makes no call, and it is deleted once that would have no relay
/// called sooner ([`changes_a_wait`]) — the last thing a drive does with a
/// row, so no answer can be stored after it; and the store refuses an update
/// of a row it no longer holds, so nothing can bring one back. The commit's
/// stored state is read for one thing only: a record no relay holds and none
/// may hold is not sent at all once its commit has lost to a rival branch.
///
/// # Errors
///
/// Returns the engine's or the store's error when the drive collected
/// nothing; once it has — a resolution's replay, a staged handle, a released
/// Welcome, a commit applied or discarded — the error is in
/// [`DriveOutcome::error`] beside it. A failed confirm is never a reason to
/// roll back: the stored row says whether the commit was applied, and
/// [`DriveOutcome::status`] reads it. Whatever the error, a target whose
/// answer was not stored stays `Attempting`, and the next drive records it
/// possibly exposed.
pub async fn drive_one<T: FanoutSend + ?Sized>(
    circle: &CircleManager,
    transport: &T,
    clock: &dyn FanoutClock,
    id: &FanoutId,
    mode: &dyn ModeSource,
) -> Result<DriveOutcome, CircleError> {
    drive_one_until(circle, transport, clock, id, None, mode).await
}

/// [`drive_one`] inside a wake that ends at `deadline_ms` on `clock`: a relay
/// that has not answered by then is no longer waited for. Its target stays
/// stored as begun, which the next drive records as possibly exposed —
/// exactly what a call the operating system cut off leaves, and never a
/// reason to roll anything back.
async fn drive_one_until<T: FanoutSend + ?Sized>(
    circle: &CircleManager,
    transport: &T,
    clock: &dyn FanoutClock,
    id: &FanoutId,
    deadline_ms: Option<u64>,
    mode: &dyn ModeSource,
) -> Result<DriveOutcome, CircleError> {
    let Some(_driving) = Driving::claim(id) else {
        return Ok(DriveOutcome::of(FanoutStatus::Busy));
    };
    let mut out = DriveOutcome::of(FanoutStatus::Unresolved);
    match drive(circle, transport, clock, id, deadline_ms, mode, &mut out).await {
        Ok(()) => Ok(out),
        // The record went with its group under the drive — the settle of a
        // disband deleted it: nothing more of it is sent, nothing is written
        // back, and that is no error. A record that ended while its group
        // lives is still the error below.
        Err(_) if circle.session().fanout_ended(id).await => {
            out.status = FanoutStatus::Gone;
            Ok(out)
        }
        Err(e) if out.carries_nothing() => Err(e),
        Err(e) => {
            out.error = Some(e);
            Ok(out)
        }
    }
}

/// Reads where `id`'s record stands and does what needs no relay: `None`
/// when that was all there was to do for it, else the record and whether its
/// commit is applied.
///
/// In [`DriveMode::FinishOnly`] see [`take_up_to_finish`].
#[allow(clippy::too_many_lines)]
async fn take_up(
    circle: &CircleManager,
    clock: &dyn FanoutClock,
    id: &FanoutId,
    source: &dyn ModeSource,
    out: &mut DriveOutcome,
) -> Result<Option<(StoredFanout, bool)>, CircleError> {
    let session = circle.session();
    let mode = source.mode();
    let mut discarded = false;
    loop {
        let standing = session.fanout_standing(id).await?;
        if mode == DriveMode::FinishOnly {
            return take_up_to_finish(circle, clock, id, standing, out).await;
        }
        match standing {
            FanoutStanding::Staged(fanout) => return Ok(Some((fanout, false))),
            FanoutStanding::Confirmed {
                fanout,
                unfinished,
                commit,
            } => {
                // Applied, whatever follows: the row says so.
                out.status = FanoutStatus::Confirmed;
                if let Some(pending) = unfinished {
                    // The engine merged the commit and stored this row, and
                    // an error then kept it from leaving `PendingPublish`
                    // (`cgka-engine/src/publish.rs` 257-272). The fanout
                    // form needs a pending row; the plain confirm finishes.
                    log::warn!(
                        "[Fanout] a confirm the engine stored but did not finish is finished"
                    );
                    let resolution = circle
                        .finish_confirmed_fanout(pending, clock.now_ms(), Still::new(source, mode))
                        .await;
                    out.resolved(FanoutStatus::Confirmed, resolution)?;
                }
                match unsent_and_set_aside(session, fanout, commit, clock.now_ms(), out).await? {
                    Some(fanout) => return Ok(Some((fanout, true))),
                    None => return Ok(None),
                }
            }
            FanoutStanding::Absent => {
                if !discarded {
                    out.status = FanoutStatus::Gone;
                }
                return Ok(None);
            }
            FanoutStanding::GroupGone(fanout) => {
                return end_dead(session, &fanout, clock, out).await
            }
            // Nothing can act on it any more: no relay is sent it again, and
            // its record goes as a finished one does, once that changes no
            // relay's wait.
            FanoutStanding::Proposal {
                fanout,
                spent: true,
            } => {
                out.status = FanoutStatus::Proposal;
                let (record, now_ms) = (fanout.as_mdk_fanout(), clock.now_ms());
                session
                    .end_fanout(&fanout, |all| changes_a_wait(all, record, now_ms))
                    .await?;
                return Ok(None);
            }
            // Driven as an applied commit's record is, for the relays it
            // still owes: nothing about it waits on the engine.
            FanoutStanding::Proposal {
                fanout,
                spent: false,
            } => {
                out.status = FanoutStatus::Proposal;
                return Ok(Some((fanout, true)));
            }
            FanoutStanding::NoCommit => {
                out.status = FanoutStatus::NotACommit;
                return Ok(None);
            }
            FanoutStanding::Unread => {
                out.status = FanoutStatus::Proposal;
                return Ok(None);
            }
            FanoutStanding::RolledBack(fanout) => {
                session.finish_rolled_back(&fanout).await?;
                out.status = FanoutStatus::RolledBack;
                return Ok(None);
            }
            FanoutStanding::Unheld { unsent: true } => {
                if !session.abandon_unsent_fanout(id).await? {
                    return Ok(None);
                }
                // Read again, as below: between the read above and that hold
                // a pass may have applied the commit, and then the record
                // was kept, confirmed, for the relays it still owes.
                out.status = FanoutStatus::Stale;
                discarded = true;
            }
            // A relay may hold the commit and nothing here can resolve it;
            // the open that found it said so once. The engine's own next
            // convergence pass disposes of it, and the row then reads stale.
            FanoutStanding::Unheld { unsent: false } => {
                out.unheld = true;
                return Ok(None);
            }
            // The engine holds some other commit under this record's ref — a
            // failed pass before the open let its hydrate bind them. Nothing
            // says whether a relay holds THAT commit: whoever staged it
            // without a record may have published it. So it is neither
            // rolled back nor retired; the next open settles this record
            // before the engine can bind it and gives the commit one of its
            // own, stored as possibly exposed.
            FanoutStanding::Stale { bound: true } => {
                log::warn!(
                    "[Fanout] a commit found staged under another commit's record is left \
                     staged; the next open gives it its own"
                );
                return Ok(None);
            }
            FanoutStanding::Stale { bound: false } => {
                log::warn!(
                    "[Fanout] a pending fanout's commit was resolved elsewhere; the fanout is \
                     settled to match"
                );
                session.discard_stale_fanout(id).await?;
                out.status = FanoutStatus::Stale;
                // Read again: a commit this device applied keeps its record,
                // now confirmed, for the relays it still owes.
                discarded = true;
            }
        }
    }
}

async fn drive<T: FanoutSend + ?Sized>(
    circle: &CircleManager,
    transport: &T,
    clock: &dyn FanoutClock,
    id: &FanoutId,
    deadline_ms: Option<u64>,
    mode: &dyn ModeSource,
    out: &mut DriveOutcome,
) -> Result<(), CircleError> {
    let session = circle.session();
    let Some((mut fanout, mut applied)) = take_up(circle, clock, id, mode, out).await? else {
        return Ok(());
    };

    if record_interrupted(fanout.as_mdk_fanout_mut())? {
        log::warn!("[Fanout] an attempt that never returned is recorded as possibly exposed");
        session.put_fanout(&fanout).await?;
    }
    let before = mode.mode();
    match settle(
        circle,
        id,
        &mut fanout,
        clock,
        out,
        &mut applied,
        Step {
            tried: false,
            mode: before,
            source: mode,
            deadline_ms: budget(mode, deadline_ms),
        },
    )
    .await?
    {
        Settled::Open => {}
        Settled::Gone | Settled::Inert => return Ok(()),
    }

    // A drive that only finishes calls a relay only in a wake that could
    // wait the call out and fold what its answer allows: a call the wake cut
    // would be stored possibly exposed for good.
    if before == DriveMode::FinishOnly
        && !has_room(
            clock,
            budget(mode, deadline_ms),
            ROW_BUDGET_MS,
            DriveMode::FinishOnly,
        )
    {
        out.retry_after_ms = Some(0);
        return Ok(());
    }
    // What the calls answer is stored before it is acted on
    // (`send_what_is_due` ends in the record's write, or in an error): the
    // settlement below reads a stored acknowledgement, never one in hand.
    let (sent, clock_blamed) = send_what_is_due(
        circle,
        transport,
        clock,
        deadline_ms,
        mode,
        before,
        &mut fanout,
    )
    .await?;
    out.clock_rejected = out.clock_rejected.or(clock_blamed);
    if sent == Sent::Cut {
        log::warn!("[Fanout] a wake ended before a relay answered; its attempt stays begun");
        out.retry_after_ms = Some(0);
        return Ok(());
    }
    // The bound is asked only of a drive that tried every relay that was
    // due: one another send held is owed its try first.
    // The mode is read again: the calls above are where a drive waits, and
    // what it may do with their answers is decided by what is true now.
    let tried = sent == Sent::All;
    let after = mode.mode();
    match settle(
        circle,
        id,
        &mut fanout,
        clock,
        out,
        &mut applied,
        Step {
            tried,
            mode: after,
            source: mode,
            deadline_ms: budget(mode, deadline_ms),
        },
    )
    .await?
    {
        Settled::Open => {}
        Settled::Gone | Settled::Inert => return Ok(()),
    }
    // When there is next something to do for this row, read against every
    // stored row: its relays' waits are shared with the other rows' calls.
    let now_ms = clock.now_ms();
    let undoable = session.commit_removes_nobody(id.group());
    let record = fanout.as_mdk_fanout();
    out.retry_after_ms = session
        .with_fanouts(|all| wake_after_ms(all, record, now_ms, undoable))
        .await?;
    // A relay that was due and could not be had is still due: the stored
    // record says "now", and a scheduler told that would spin.
    if sent == Sent::NotAll && out.status != FanoutStatus::Gone {
        out.retry_after_ms = Some(
            out.retry_after_ms
                .filter(|wait| *wait > 0)
                .map_or(BUSY_RETRY_MS, |wait| wait.min(BUSY_RETRY_MS)),
        );
    }
    Ok(())
}

/// Decides whether an applied commit's record is driven at all, handing it
/// back when it is.
///
/// A commit no relay holds and none may is this device's alone to send.
/// While it has lost to a rival branch it is not sent — that would hand the
/// circle a rival this device has itself set aside — and once it has lost
/// for good its record ends unsent, with whatever the engine still owed its
/// Welcomes. A commit some relay holds or may hold keeps its one attempt per
/// relay whatever becomes of it: other members may have built on it.
async fn unsent_and_set_aside(
    session: &crate::nostr::mls::SessionManager,
    mut fanout: StoredFanout,
    commit: AppliedCommit,
    now_ms: u64,
    out: &mut DriveOutcome,
) -> Result<Option<StoredFanout>, CircleError> {
    let record = fanout.as_mdk_fanout();
    let unheld = record.outcome().accepted_targets == 0 && !record.possible_exposure();
    match commit {
        AppliedCommit::Provisional if unheld => Ok(None),
        AppliedCommit::Lost if unheld => {
            if !record.pending_post_confirmation_welcomes().is_empty() {
                // Nothing is delivered here: a commit lost for good ends its
                // Welcomes as failed with its record.
                session
                    .hand_over_welcomes(&mut fanout, now_ms, Still::always(&DriveMode::Full))
                    .await?;
            }
            session.end_fanout(&fanout, |_| false).await?;
            out.status = FanoutStatus::Stale;
            Ok(None)
        }
        _ => Ok(Some(fanout)),
    }
}

/// What became of the calls a drive had to make.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Sent {
    /// Every relay that was due was called and answered, or none was due.
    All,
    /// A relay that was due was held by another send for the whole of the
    /// transport's wait ([`GATE_WAIT_SECS`]), or a relay this record still
    /// owes was being called for another row: no attempt was begun for it and
    /// nothing was stored. Every other one was called and answered.
    NotAll,
    /// The wake's budget ended before every call had answered: nothing was
    /// stored, and each target stays as it was marked before its call.
    Cut,
}

/// Sends `fanout`'s event to each relay that is owed an attempt, due one and
/// free to be called, and stores what each answered.
///
/// A relay is taken for the call BEFORE its attempt is stored
/// ([`FanoutSend::take`]): one that another send holds for the whole of the
/// transport's wait is left exactly as it was, so a call that never left the
/// device is no attempt, counts towards nothing and lengthens no wait.
///
/// The takes are where a drive waits, and `mode` may narrow there. A record
/// never sent to any relay is then not sent by this call at all: nothing is
/// marked, nothing is called and every relay taken is given back — a first
/// send the operating system cut would leave a commit nobody may hold stored
/// as possibly exposed for good.
#[allow(clippy::too_many_lines)]
async fn send_what_is_due<T: FanoutSend + ?Sized>(
    circle: &CircleManager,
    transport: &T,
    clock: &dyn FanoutClock,
    deadline_ms: Option<u64>,
    mode: &dyn ModeSource,
    began: DriveMode,
    fanout: &mut StoredFanout,
) -> Result<(Sent, Option<crate::relay::clock_skew::DeviceClockComplaint>), CircleError> {
    let session = circle.session();
    let first_send = fanout
        .as_mdk_fanout()
        .target_statuses()
        .iter()
        .all(|status| *status == FanoutTargetStatus::NotAttempted);
    // A leave's proposal is the user's own act: any drive may begin it.
    let a_leave = fanout.as_mdk_fanout().mls_state() == FanoutMlsState::NotApplicable;
    let may_begin = || a_leave || !first_send || mode.mode() == DriveMode::Full;
    let request = fanout.as_mdk_fanout().request().clone();
    let target = |attempt: &Attempt| request.target.endpoints()[attempt.spellings[0]].as_str();
    // Read first, to know which relays to take. Nothing is marked here.
    let stored = fanout.as_mdk_fanout();
    let (mut wanted, busy) = session
        .with_fanouts(|all| {
            let (due, _, busy) = due_or_busy(all, stored, clock.now_ms());
            (due, busy)
        })
        .await?;
    // A drive that only finishes sends again what a relay was sent before,
    // and gives no relay its first attempt: that is a full drive's.
    if began == DriveMode::FinishOnly && !a_leave {
        wanted.retain(|attempt| !never_attempted(stored, attempt));
    }
    if wanted.is_empty() {
        // A relay this record still owes that another row's call has taken
        // was not tried: the bound is not asked of this drive.
        return Ok((if busy { Sent::NotAll } else { Sent::All }, None));
    }
    let mut taken: Vec<(usize, Taken)> = Vec::new();
    for (attempt, held) in wanted.iter().zip(
        futures::future::join_all(wanted.iter().map(|attempt| transport.take(target(attempt))))
            .await,
    ) {
        if let Some(held) = held {
            taken.push((attempt.spellings[0], held));
        }
    }
    if !may_begin() {
        return Ok((Sent::NotAll, None));
    }
    let mut all_taken = taken.len() == wanted.len();
    // Chosen and stored in one hold, with every other row before it: two
    // drives can never both find one relay free, and a call that never
    // returns is found `Attempting`, which is how the next drive knows it
    // was made. Chosen AGAIN, since the wait above let other rows move: only
    // a relay that is still due and that this call holds is marked — and
    // the mode is read again there, where nothing can fall between the read
    // and the mark.
    let now_ms = clock.now_ms();
    let mut attempts: Vec<(Attempt, Taken)> = Vec::new();
    let mut marked = Ok(());
    let mut admitted = None;
    session
        .begin_fanout_attempts(fanout, |all, fanout| {
            // Counted under the store, before the lifecycle is read: a pause
            // that closes this call's socket waits for it or finds none begun.
            admitted = mode.in_flight().map(InFlight::count);
            let ended = admitted.is_some() && !mode.stands();
            let full = a_leave || mode.mode() == DriveMode::Full;
            if (first_send && !full) || ended {
                all_taken = false;
                return false;
            }
            let (due, _, busy) = due_or_busy(all, fanout, now_ms);
            all_taken &= !busy;
            for attempt in due {
                if !full && never_attempted(fanout, &attempt) {
                    continue;
                }
                let Some(held) = taken
                    .iter()
                    .position(|(first, _)| *first == attempt.spellings[0])
                else {
                    continue;
                };
                for index in &attempt.spellings {
                    if let Err(e) = fanout.mark_attempt_started_at(*index, now_ms) {
                        marked = Err(refused(e));
                        return false;
                    }
                }
                attempts.push((attempt, taken.swap_remove(held).1));
            }
            !attempts.is_empty()
        })
        .await?;
    marked?;
    drop(taken);
    let not_all = if all_taken { Sent::All } else { Sent::NotAll };
    if attempts.is_empty() {
        return Ok((not_all, None));
    }
    let (attempts, held): (Vec<Attempt>, Vec<Taken>) = attempts.into_iter().unzip();
    let calls = futures::future::join_all(
        attempts
            .iter()
            .zip(held)
            .map(|(attempt, held)| transport.publish(target(attempt), &request.message, held)),
    );
    let Some(answers) = within(clock, deadline_ms, calls).await else {
        return Ok((Sent::Cut, None));
    };
    // Before the store: a pause waits for the calls, never for the store.
    drop(admitted);
    let mut clock_blamed: Option<crate::relay::clock_skew::DeviceClockComplaint> = None;
    for (attempt, answer) in attempts.iter().zip(answers) {
        if let FanoutTargetOutcome::Failed(failed) = &answer {
            if let Some(complaint) = failed.clock_blamed() {
                clock_blamed = Some(clock_blamed.map_or(complaint, |seen| seen.merge(complaint)));
            }
        }
        record(fanout.as_mdk_fanout_mut(), attempt, answer)?;
    }
    session.put_fanout(fanout).await?;
    // As the plain publish's verdict (`clock_skew::classify_publish_outcome`):
    // a commit some relay holds is no clock alarm.
    let held = accepted_relays(fanout.as_mdk_fanout()) > 0;
    Ok((not_all, clock_blamed.filter(|_| !held)))
}

/// `work`, for no longer than the wake lasts: `None` when `deadline_ms` came
/// first, and `work` is then dropped where it stood.
async fn within<F: Future>(
    clock: &dyn FanoutClock,
    deadline_ms: Option<u64>,
    work: F,
) -> Option<F::Output> {
    let Some(deadline_ms) = deadline_ms else {
        return Some(work.await);
    };
    // Polled first, so an answer that is already there is never read as cut.
    match futures::future::select(std::pin::pin!(work), clock.until(deadline_ms)).await {
        futures::future::Either::Left((done, _)) => Some(done),
        futures::future::Either::Right(((), _)) => None,
    }
}

/// What one [`drive_due`] did.
///
/// **No `Debug`, deliberately**, as [`DriveOutcome`].
#[must_use]
pub struct DueOutcome {
    /// Every commit fanout it took up, in the order it took them, with what
    /// its drive did.
    pub driven: Vec<(FanoutId, DriveOutcome)>,
    /// How long until the soonest relay any of them still owes a call may be
    /// sent to again; zero when rows were left for the next wake. Relative,
    /// and never logged.
    pub retry_after_ms: Option<u64>,
    /// The first error a row's drive ended on. Everything driven is still in
    /// [`Self::driven`]: what those drives released is never dropped with
    /// another row's failure.
    pub error: Option<CircleError>,
    /// The circles a row's drive ended on an error in; `None` when an error
    /// could not be placed in one (the rows could not be listed).
    pub erred: Option<Vec<GroupId>>,
}

/// Drives every stored commit and proposal fanout — `group_id`'s, or every
/// circle's — each through one [`drive_one`].
///
/// The rows that still owe a relay its first attempt go first, then the
/// rest, each in staging order; within a circle nothing staged after a
/// commit that is still pending is taken up before that commit is resolved.
/// A row a commit's resolution staged is driven in the same call.
///
/// This is how a commit a kill interrupted is resumed: the rows are read from
/// the store, and a row MDK's hydrate restored a pending commit from is
/// driven like any other. It waits for nothing: a relay that is not due is
/// left for a later call, [`DueOutcome::retry_after_ms`] saying how much
/// later.
///
/// `deadline_ms` is the end of the wake's budget, an instant on `clock`. A
/// row is taken up only while [`ROW_BUDGET_MS`] of it remain: a call the wake
/// cannot wait out would be cut off unanswered, and an unanswered attempt is
/// stored possibly exposed for good. The rows left are untouched.
///
/// A row whose drive ends on an error stops the rest of ITS circle's rows,
/// which were staged after it, and no other circle's.
pub async fn drive_due<T: FanoutSend + ?Sized>(
    circle: &CircleManager,
    transport: &T,
    clock: &dyn FanoutClock,
    group_id: Option<&GroupId>,
    deadline_ms: Option<u64>,
    mode: &dyn ModeSource,
) -> DueOutcome {
    let due = match circle.session().stored_fanouts(group_id).await {
        Ok(rows) => {
            let wake = Wake {
                deadline_ms,
                mode,
                follow: true,
            };
            Box::pin(drive_rows(circle, transport, clock, rows.into(), &wake)).await
        }
        Err(e) => DueOutcome {
            driven: Vec::new(),
            retry_after_ms: None,
            error: Some(CircleError::Mls(e.code().to_string())),
            erred: group_id.map(|group_id| vec![group_id.clone()]),
        },
    };
    // After every commit and proposal: a location never comes before one.
    Box::pin(settle_locations(circle, clock, group_id)).await;
    due
}

/// The longest one location send holds the radio — the connect and the
/// acknowledgement window, once: what a location's record must have left
/// before its event expires for a send of it to be begun.
pub const LOCATION_SEND_MS: u64 = crate::relay::manager::LOCATION_SEND_MS;

/// Whether a location whose event expires at `expires_at_secs` can no
/// longer be sent at `now_ms`: a send begun now could still be on its way
/// to a relay ([`LOCATION_SEND_MS`]) at or after the instant the relays and
/// every member drop the event.
const fn location_is_spent(expires_at_secs: u64, now_ms: u64) -> bool {
    now_ms.saturating_add(LOCATION_SEND_MS) >= expires_at_secs.saturating_mul(1_000)
}

/// What became of a location handed to [`Publishing::publish_location`].
///
/// **No `Debug`**: the transport's result names relays.
pub enum LocationPublish {
    /// It was offered to its record's relays once, and this is what the
    /// transport answered. The record is gone; nothing sends it again.
    Sent(RelayResult<PublishResult>),
    /// Not sent, and its record ended: the event had expired, or a send
    /// begun now could not have ended before it did.
    Expired,
    /// Not sent, and its record ended: a fresh seal would not be made for
    /// its circle now — this device was removed from it, it has left the
    /// epoch the location was sealed at, or a commit, a hold or a departure
    /// stands in the way (`SessionManager::location_may_be_sent`). A member
    /// removed since could still read it, and no relay that does not already
    /// hold it is handed it now.
    Superseded,
    /// Not sent: no record of it is stored — its one send was already made,
    /// or it was never sealed by this driver.
    Ended,
    /// Not sent by this call: a send of it is under way.
    InFlight,
}

/// Ends, unsent, every stored location record but one this session sealed
/// and has not yet sent while its event can still be sent; one whose send is
/// under way is not touched.
///
/// A record another process left is never sent (decision 212): the core
/// cannot tell whether its user still shares — they may have turned sharing
/// off, or stopped the app to stop it — and every change runs this first, so
/// a stale fix would go out just before a removal or to the relays being
/// left. The spec makes the obligation end at expiration and leaves the rest
/// to local policy (`transports/nostr.md` 346-355); the next tick seals a
/// fresher one.
async fn settle_locations(
    circle: &CircleManager,
    clock: &dyn FanoutClock,
    group_id: Option<&GroupId>,
) {
    let session = circle.session();
    let Ok(records) = session.location_fanouts(group_id).await else {
        return;
    };
    for record in records {
        // Its own send is under way or still to come, and is never made to
        // wait for this drive — not even for the instant of a claim — unless
        // its circle is being left.
        if record.here
            && !location_is_spent(record.expires_at_secs, clock.now_ms())
            && !session.leaving(record.id.group())
        {
            continue;
        }
        let Some(_driving) = Driving::claim(&record.id) else {
            continue;
        };
        let _ = session.end_location(record.id.message()).await;
    }
}

/// What bounds one pass over rows.
struct Wake<'a> {
    /// The end of the wake's budget, an instant on the drive's clock.
    deadline_ms: Option<u64>,
    /// What the pass may do, read before each row and again after its calls.
    mode: &'a dyn ModeSource,
    /// Whether a row a resolution records is taken up in the same pass. Never
    /// in [`DriveMode::FinishOnly`], whatever this says.
    follow: bool,
}

/// [`drive_due`] over `work`.
///
/// In [`DriveMode::FinishOnly`] a row is taken up only inside a known
/// budget, with a fold's worth of it left — what confirming a stored
/// acknowledgement needs — and a relay is called for it only with a whole
/// row's ([`drive`]): a pass with no deadline begins none.
async fn drive_rows<T: FanoutSend + ?Sized>(
    circle: &CircleManager,
    transport: &T,
    clock: &dyn FanoutClock,
    mut work: VecDeque<FanoutId>,
    wake: &Wake<'_>,
) -> DueOutcome {
    let deadline_ms = wake.deadline_ms;
    let mut due = DueOutcome {
        driven: Vec::new(),
        retry_after_ms: None,
        error: None,
        erred: None,
    };
    let mut stopped: Vec<GroupId> = Vec::new();
    while let Some(id) = work.pop_front() {
        if stopped.contains(id.group()) {
            continue;
        }
        let full = wake.mode.mode() == DriveMode::Full;
        let needs_ms = if full { ROW_BUDGET_MS } else { FOLD_BUDGET_MS };
        match deadline_ms {
            Some(deadline) if clock.now_ms().saturating_add(needs_ms) > deadline => {
                due.retry_after_ms = Some(0);
                break;
            }
            None if !full => break,
            _ => {}
        }
        let driven = drive_one_until(circle, transport, clock, &id, deadline_ms, wake.mode).await;
        let mut outcome = match driven {
            Ok(outcome) => outcome,
            Err(e) => {
                due.error.get_or_insert(e);
                stopped.push(id.group().clone());
                continue;
            }
        };
        // Read again: a pass that has become finish-only sends nothing it
        // has just recorded.
        let full = wake.mode.mode() == DriveMode::Full;
        for staged in &outcome.staged {
            if !full {
                break;
            }
            if !wake.follow {
                // Left for the next drive, which is due at once.
                due.retry_after_ms = Some(0);
                break;
            }
            if !work.contains(staged) && !due.driven.iter().any(|(driven, _)| driven == staged) {
                work.push_back(staged.clone());
            }
        }
        due.retry_after_ms = match (due.retry_after_ms, outcome.retry_after_ms) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        };
        if outcome.error.is_some() {
            stopped.push(id.group().clone());
            if due.error.is_none() {
                due.error = outcome.error.take();
            }
        }
        due.driven.push((id, outcome));
    }
    due.erred = Some(stopped);
    due
}

/// Makes every relay that could not be reached due again, now that the
/// device is back on a network.
///
/// MDK's own `OutboundFanout::wake_retryable_unavailable_targets`
/// (`traits/src/transport_adapter.rs` 471-486), which its host calls on that
/// edge. A record with a relay that answered `rate-limited:` is left as it
/// is: that relay was reached, and a network coming back says nothing new
/// about it.
///
/// # Errors
///
/// Returns the store's error, redacted.
pub async fn wake_unreachable(circle: &CircleManager) -> Result<(), CircleError> {
    circle
        .session()
        .wake_unreachable_fanout_targets()
        .await
        .map_err(|e| CircleError::Mls(e.code().to_string()))
}

// ── Send-side changes ────────────────────────────────────────────────────────

/// Where a send-side change stands when the call that made it returns.
///
/// Only [`Self::RolledBack`] says every relay refused the change and the
/// circle is as it was. A change no
/// relay has answered for yet is [`Self::Unresolved`] — awaiting relays —
/// however long the call waited: its commit is staged and durable, and every
/// later drive sends the same bytes again.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EvolutionStatus {
    /// A relay acknowledged the commit and the engine applied it.
    Confirmed,
    /// The circle already was as the change asks: nothing was staged and no
    /// relay was asked, so nothing here says any relay took anything.
    AlreadySo,
    /// Staged and recorded, and no relay has acknowledged it yet: awaiting
    /// relays. The circle's sends wait behind it.
    Unresolved,
    /// Every relay proved it refused the commit and none may hold it: the
    /// engine discarded it, and the circle is as it was.
    RolledBack,
    /// The engine accepted the change and queued it behind what the circle
    /// is still resolving. It is durable, and staged by a later advance.
    Queued,
    /// The engine set the commit aside by a path of its own before any relay
    /// answered for it, and its record was settled to match. It was not
    /// applied by this call. That is NOT "every relay refused it": a relay
    /// may have been sent it, and the circle is then told it may be out of
    /// step ([`ChangeNote::MayBeOutOfStep`]).
    Stale,
    /// The commit is staged on this device and could be neither recorded
    /// nor undone. It was not sent, and the circle's sends wait behind it.
    /// Its rollback is tried again at the next call that stages; failing
    /// that, the next start gives an admin's removal its record and MDK's
    /// hydrate clears any other change, whose stored row the open then
    /// retires before the first engine call, so no pass applies it on this
    /// device alone (`docs/MDK_UPSTREAM_TRACKER.md` T-KILL-WINDOW).
    /// [`ChangeNote::ChangeUnrecorded`] is kept until it is acknowledged.
    Unrecorded,
}

/// What a send-side change did.
#[must_use]
pub struct EvolutionOutcome {
    /// Where the change stands.
    pub status: EvolutionStatus,
    /// How many of this change's Welcomes a relay they were addressed to
    /// acknowledged during the call.
    pub welcomes_sent: usize,
    /// How many Welcomes this change carries: one per invitee.
    pub welcomes_total: usize,
    /// What the circle must be told about THIS change beyond its status: an
    /// invite applied with no Welcome left to deliver.
    pub notes: Vec<ChangeNote>,
    /// What resolving it handed back: the locations and group updates that
    /// had waited behind the commit. Every location is already stored.
    pub replayed: Vec<LocationMessageResult>,
    /// How long until there is next something to do for what this call left
    /// stored — a relay due again, a bound reached — when there is: when to
    /// call [`Publishing::resume`]. Relative, and never logged.
    pub retry_after_ms: Option<u64>,
    /// What a relay's refusal during the call blamed on this device's clock:
    /// evidence for the clock check, never the relay's words.
    pub clock_rejected: Option<crate::relay::clock_skew::DeviceClockComplaint>,
}

/// What a driven circle creation did ([`Publishing::create_circle`]).
///
/// **No `Debug`, deliberately**: it names the circle and its invitees, and
/// its counts are how many were invited (Security Rule 15).
#[must_use]
pub struct CreateOutcome {
    /// The circle, as stored.
    pub circle: crate::circle::Circle,
    /// How many of its founding Welcomes a relay of their invitee's inbox
    /// acknowledged during the call.
    pub welcomes_sent: usize,
    /// How many founding Welcomes it has: one per invitee.
    pub welcomes_total: usize,
    /// The invitees, as lowercase hex, whose founding Welcome is still owed:
    /// later foreground drives send it from its record.
    pub unsent_recipients: Vec<String>,
}

/// The status and nothing else: the two counts are how many people were
/// invited (Security Rule 15), and the rest names circles.
impl std::fmt::Debug for EvolutionOutcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EvolutionOutcome")
            .field("status", &self.status)
            .finish_non_exhaustive()
    }
}

/// What [`Publishing::repair_rotation`] did.
#[must_use]
pub enum RepairOutcome {
    /// The rotation commit was staged; where it stands.
    Rotated(EvolutionOutcome),
    /// A gate declined the repair; nothing was staged and nothing changed.
    Skipped(SkipReason),
    /// The circle is send-gated: the deferred-send repair ran instead, and
    /// what it handed back has been published or recorded.
    Deferred {
        /// What still holds the circle's sends, read after the repair.
        held_by: SendHeld,
        /// What the repair replayed.
        replayed: Vec<LocationMessageResult>,
    },
}

/// What holds a circle's location sends, read from what is stored when the
/// call that asked returns. Fieldless: what the user is told is fixed copy
/// chosen by the variant.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendHeld {
    /// A change of the circle is recorded and no relay has acknowledged it
    /// yet: awaiting relays. Each later drive sends the same bytes again.
    AwaitingRelays,
    /// A change of the circle is recorded and a relay HAS acknowledged it;
    /// what it awaits is the confirm, which this call did not make: its
    /// wake had no room left to fold what a confirm hands back, or the
    /// change moves the circle's relays and the call was one that only
    /// finishes. The next drive with room applies it without calling a
    /// relay — a full one, for a change of the relays.
    Acknowledged,
    /// A commit is staged in the circle with no record: one that could be
    /// neither recorded nor undone ([`ChangeNote::ChangeUnrecorded`]), or an
    /// eviction a process died inside the staging of, which hydrate keeps.
    /// Nothing here sends it.
    StagedWithoutRecord,
    /// The removal of a member who left is due and was not made by this
    /// call: every relay refused the last one and the wait that earned is
    /// still running, or the call's mode makes no new commit. Nothing is
    /// sealed for the circle meanwhile, so that member reads nothing new.
    DepartureDue,
    /// A change of the circle's relays was applied while the app was away,
    /// and the call is not a claimed foreground's. Nothing is sealed for the
    /// circle except by one until a full drive has completed in one
    /// ([`ChangeNote::AwaitsForeground`]).
    AwaitsForeground,
    /// A removal the user asked for was set aside or dropped unmade and a
    /// member it named is still in the circle. Nothing is sealed for the
    /// circle by any call, a claimed foreground's included, until that
    /// member is no longer listed or the user has acknowledged being told
    /// ([`ChangeNote::QueuedRemovalDropped`]).
    RemovalUnmade,
    /// This device asked to leave the circle: nothing is sealed for it, by
    /// any call, until the leave ends or is refused for good
    /// ([`Publishing::leave`]).
    Leaving,
    /// An admin disbanded the circle: nothing is sealed for it, by any call,
    /// ever again; it can only be left.
    Disbanded,
    /// The circle's routing id is another circle's on this device too, so
    /// one of the two hears none of its commits: nothing is sealed for
    /// either until the circle is left ([`ChangeNote::RoutingCollision`]).
    RoutingCollision,
    /// Stored input the engine cannot settle still gates the circle's sends,
    /// or retained rows MDK queues a send behind are still untried — a wake
    /// too short for the pre-send drain leaves them — or the engine could not
    /// be had for the send at all: input stranded in the circle is still
    /// owed to it, or a rolled-back commit is not yet retired. Or this device
    /// fetched input for the circle it has not taken in: a commit the
    /// catch-up pager held back, which no ingest took in and the engine does
    /// not record, or stored replay a live REQ holds until its relay's
    /// `EOSE` (`SessionManager::holds_unread_input`). The next call carries
    /// on from there.
    StoredInput,
    /// Nothing: whatever deferred the send was resolved in the call, and the
    /// next one is sealed.
    Nothing,
}

/// What a user needs to know first about a circle that is not sharing.
///
/// Worst first: the cause whose remedy comes first ([`worst_recovery`]).
/// Fieldless: what the user is told is fixed copy chosen by the variant.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecoveryCause {
    /// An admin disbanded the circle: nothing is ever sent for it again.
    Disbanded,
    /// MDK halted the circle at its last stable epoch: it is repaired when
    /// an admin adds this device again, or left.
    Unrecoverable,
    /// The circle failed to load at the open; a retry may bring it back.
    Quarantined,
    /// The circle's routing id is another circle's on this device too: it
    /// can only be left ([`SendHeld::RoutingCollision`]).
    RoutingCollision,
    /// This device asked to leave: every other remedy is moot.
    Leaving,
    /// This device cannot read its peers: walks of the circle's history the
    /// relays answered in full brought back nothing that moves it. A removal
    /// asked for now would be made from an epoch the circle has left.
    Stalled,
    /// See [`SendHeld::RemovalUnmade`].
    RemovalUnmade,
    /// See [`SendHeld::DepartureDue`].
    DepartureDue,
    /// See [`SendHeld::AwaitsForeground`].
    AwaitsForeground,
    /// See [`SendHeld::AwaitingRelays`].
    AwaitingRelays,
    /// See [`SendHeld::Acknowledged`].
    Acknowledged,
    /// See [`SendHeld::StagedWithoutRecord`].
    StagedWithoutRecord,
    /// See [`SendHeld::StoredInput`]: also what a store fault that does not
    /// clear reads as, since nothing without a timer tells it from a slow
    /// one; a relay-confirmed stall outranks it.
    StoredInput,
}

/// Everything [`worst_recovery`] weighs, read at one instant.
#[derive(Clone, Copy)]
#[allow(
    clippy::struct_excessive_bools,
    reason = "four independent facts of one instant, each read from its own store"
)]
pub struct RecoveryFacts {
    /// MDK's tombstone stands.
    pub disbanded: bool,
    /// MDK's persisted `unrecoverable` stands.
    pub unrecoverable: bool,
    /// The circle is quarantined.
    pub quarantined: bool,
    /// The epoch-stall detector reports the circle (`SessionManager::stalled`).
    pub stalled: bool,
    /// What holds its sends ([`Publishing::circle_recovery`]).
    pub held: SendHeld,
}

/// The worst of `facts`, in the order the user needs a remedy.
///
/// A circle that can never send again, then one that needs re-adding, one a
/// retry may bring back, one that can only be left, one being left, one
/// whose device cannot read its peers, and then what holds its sends, worst
/// first. `None` when nothing holds it.
#[must_use]
pub const fn worst_recovery(facts: RecoveryFacts) -> Option<RecoveryCause> {
    if facts.disbanded || matches!(facts.held, SendHeld::Disbanded) {
        return Some(RecoveryCause::Disbanded);
    }
    if facts.unrecoverable {
        return Some(RecoveryCause::Unrecoverable);
    }
    if facts.quarantined {
        return Some(RecoveryCause::Quarantined);
    }
    match facts.held {
        SendHeld::RoutingCollision => return Some(RecoveryCause::RoutingCollision),
        SendHeld::Leaving => return Some(RecoveryCause::Leaving),
        _ => {}
    }
    if facts.stalled {
        return Some(RecoveryCause::Stalled);
    }
    match facts.held {
        SendHeld::RemovalUnmade => Some(RecoveryCause::RemovalUnmade),
        SendHeld::DepartureDue => Some(RecoveryCause::DepartureDue),
        SendHeld::AwaitsForeground => Some(RecoveryCause::AwaitsForeground),
        SendHeld::AwaitingRelays => Some(RecoveryCause::AwaitingRelays),
        SendHeld::Acknowledged => Some(RecoveryCause::Acknowledged),
        SendHeld::StagedWithoutRecord => Some(RecoveryCause::StagedWithoutRecord),
        SendHeld::StoredInput => Some(RecoveryCause::StoredInput),
        SendHeld::Disbanded
        | SendHeld::RoutingCollision
        | SendHeld::Leaving
        | SendHeld::Nothing => None,
    }
}

/// How long a leave may stand before this device leaves its circle on its
/// own: a day from the intent, whatever the relays or the peers did.
pub const LEAVE_BOUND_MS: u64 = 24 * 3_600_000;

/// Where a leave stands ([`Publishing::leave`], [`Publishing::resume_leave`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LeaveStatus {
    /// The proposal is recorded and driven to the circle's relays; a peer
    /// commits it.
    Proposed,
    /// Not proposed yet — the circle is not stable, or an admin step awaits
    /// its relays. Nothing is shared with the circle, and the next call
    /// carries on.
    Pending,
    /// Left on this device: a peer committed the leave, or its bound passed.
    Completed,
    /// No leave was asked for.
    NotLeaving,
}

/// What a leave call did. **No `Debug`**: its wait is the driver's
/// schedule, which no rendering carries (as [`SealOutcome`]'s).
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct LeaveOutcome {
    /// Where the leave stands.
    pub status: LeaveStatus,
    /// How long until a record the call drove next has something to do.
    pub retry_after_ms: Option<u64>,
    /// What a relay's refusal during the call blamed on this device's clock:
    /// evidence for the clock check, never the relay's words.
    pub clock_rejected: Option<crate::relay::clock_skew::DeviceClockComplaint>,
}

impl LeaveOutcome {
    const fn now(status: LeaveStatus) -> Self {
        Self {
            status,
            retry_after_ms: None,
            clock_rejected: None,
        }
    }
}

/// What [`Publishing::seal_location`] made of a location.
///
/// **No derived `Debug`**: the event is a relay-visible id and bytes.
pub enum LocationSeal {
    /// Encrypted for the circle's current epoch: publish `event` to `relays`.
    Sealed {
        /// The kind-445 event.
        event: Box<nostr::Event>,
        /// The circle's public routing id.
        nostr_group_id: [u8; 32],
        /// The circle's relays.
        relays: Vec<String>,
    },
    /// Not encrypted, and not kept: the fix is dropped, and the next one is
    /// sealed when it is asked for and nothing holds the circle.
    Deferred(SendHeld),
}

impl std::fmt::Debug for LocationSeal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Sealed { .. } => f.write_str("Sealed"),
            Self::Deferred(held_by) => f.debug_tuple("Deferred").field(held_by).finish(),
        }
    }
}

/// What one [`Publishing::seal_location`] did.
#[must_use]
pub struct SealOutcome {
    /// The location, or what holds it.
    pub seal: LocationSeal,
    /// What the call's drives and its repair handed back: every location is
    /// stored already.
    pub replayed: Vec<LocationMessageResult>,
    /// See [`ResumeOutcome::retry_after_ms`].
    pub retry_after_ms: Option<u64>,
    /// See [`ResumeOutcome::errored`].
    pub errored: bool,
    /// What a relay's refusal during the call blamed on this device's clock:
    /// evidence for the clock check, never the relay's words.
    pub clock_rejected: Option<crate::relay::clock_skew::DeviceClockComplaint>,
}

/// The seal and nothing else: what was replayed names circles.
impl std::fmt::Debug for SealOutcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SealOutcome")
            .field("seal", &self.seal)
            .finish_non_exhaustive()
    }
}

impl std::fmt::Debug for RepairOutcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Rotated(outcome) => f.debug_tuple("Rotated").field(&outcome.status).finish(),
            Self::Skipped(reason) => f.debug_tuple("Skipped").field(reason).finish(),
            Self::Deferred { held_by, .. } => f
                .debug_struct("Deferred")
                .field("held_by", held_by)
                .finish_non_exhaustive(),
        }
    }
}

/// What [`Publishing::resume`] did.
///
/// **No `Debug`, deliberately**: what it replayed names circles.
#[must_use]
pub struct ResumeOutcome {
    /// What the resolutions it made handed back; every location is stored.
    pub replayed: Vec<LocationMessageResult>,
    /// How many Welcomes a relay they were addressed to acknowledged.
    pub welcomes_sent: usize,
    /// How long until there is next something to do for a stored record:
    /// see [`DriveOutcome::retry_after_ms`] and [`DueOutcome::retry_after_ms`].
    pub retry_after_ms: Option<u64>,
    /// Whether a drive ended on an error. What it had done stands, and the
    /// stored records say where each commit is.
    pub errored: bool,
    /// The changes of this device's that branch selection withdrew and this
    /// drive asked MDK about, each with what became of it.
    pub withdrawn: Vec<WithdrawnChange>,
    /// The removals set aside unmade that this drive took up, each with
    /// what became of it (decision 180).
    pub requeued: Vec<RequeuedRemoval>,
    /// What a relay's refusal during the call blamed on this device's clock:
    /// evidence for the clock check, never the relay's words.
    pub clock_rejected: Option<crate::relay::clock_skew::DeviceClockComplaint>,
}

/// What became of one re-invite MDK owed ([`Publishing::reinvite`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReinviteResult {
    /// Asked for again with fresh key packages and staged under a record:
    /// awaiting its relays, not yet made. Its Welcomes go from records of
    /// their own once a relay takes the commit.
    Reissued,
    /// Asked for again and queued by MDK, not staged by this call: the
    /// circle's next full advance makes it.
    Queued,
    /// MDK's next lookup for it is not due yet.
    NotDue,
    /// Not looked for: its circle is not caught up, stable and settled, and
    /// an invite made from a stale epoch could fork it and spend the fresh
    /// key packages for nothing. No lookup is spent; a later drive looks.
    Unsettled,
    /// An invitee has no key package a relay serves that the circle can
    /// admit, or MDK refused the one found — one the withdrawn invite already
    /// spent, which an invitee keeps published while the invitation is
    /// unanswered: looked for again on MDK's schedule.
    KeyPackageMissing,
    /// An invitee lists no inbox relay Haven may dial, so no Welcome could
    /// reach them: looked for again on MDK's schedule.
    NoInbox,
    /// MDK has spent its lookups on it: the invite is the user's to make
    /// again ([`ChangeNote::ReinviteOwed`] stands).
    GaveUp,
    /// MDK ended it: this device is no member, the invitees are already in,
    /// or the winner touched the same thing.
    Ended,
    /// A lookup was spent and the re-invite was not made: MDK or the store
    /// failed. MDK still owes it, and its next due lookup tries again.
    Unmade,
}

/// One re-invite and what became of it. **No `Debug`**: it names its
/// circle.
pub struct Reinvite {
    /// The circle.
    pub group_id: GroupId,
    /// What became of it.
    pub result: ReinviteResult,
}

/// Where a re-invite finds a fresh `KeyPackage` for one invitee.
///
/// It also gives the relays the invitee's Welcome reaches. In the product:
/// the relay manager's own invite lookup ([`RelayManager`](super::RelayManager)).
pub trait ReinviteLookup: Send + Sync {
    /// The invitee `invitee` (hex) as an inviter of `group_id` holds them:
    /// `None` when no admissible package was found.
    fn member<'a>(
        &'a self,
        circle: &'a CircleManager,
        group_id: &'a GroupId,
        invitee: &'a str,
    ) -> Pin<Box<dyn Future<Output = Option<MemberKeyPackage>> + Send + 'a>>;
}

/// The invite lookup the app's own invite makes: the invitee's kind-10050
/// list, their NIP-65 list, and a `KeyPackage` from their write relays (the
/// read-only discovery relays as the fallback) that the circle admits.
impl ReinviteLookup for super::RelayManager {
    fn member<'a>(
        &'a self,
        circle: &'a CircleManager,
        group_id: &'a GroupId,
        invitee: &'a str,
    ) -> Pin<Box<dyn Future<Output = Option<MemberKeyPackage>> + Send + 'a>> {
        Box::pin(async move {
            let admit = circle
                .session()
                .key_package_admission_rule(Some(group_id))
                .await
                .ok()?;
            let (inbox, nip65) = tokio::join!(
                self.fetch_inbox_relays(invitee),
                self.fetch_nip65_relay_list(invitee),
            );
            let nip65 = nip65.unwrap_or_default();
            let event = self
                .fetch_keypackage_for_invite(invitee, &nip65.write, &admit)
                .await
                .ok()??;
            Some(MemberKeyPackage {
                key_package_event: event,
                inbox_relays: inbox.unwrap_or_default(),
                nip65_relays: nip65.read,
                nip65_write_relays: nip65.write,
            })
        })
    }
}

/// What [`Publishing::ingest_for_poll`] did with one polled event.
///
/// **No `Debug`, deliberately**, as [`ResumeOutcome`].
#[must_use]
pub struct PollOutcome {
    /// Whether a cursor may pass the event (Security Rule 12):
    /// [`ReceiveOnlyOutcome::Deferred`] holds it at or below the event, which
    /// is fetched again; the others do not. Nothing here moves a cursor
    /// forward: the event's own time is not bound to what the engine
    /// authenticated.
    pub verdict: ReceiveOnlyOutcome,
    /// See [`ResumeOutcome::replayed`].
    pub replayed: Vec<LocationMessageResult>,
    /// See [`ResumeOutcome::welcomes_sent`].
    pub welcomes_sent: usize,
    /// See [`ResumeOutcome::retry_after_ms`].
    pub retry_after_ms: Option<u64>,
    /// See [`ResumeOutcome::errored`].
    pub errored: bool,
    /// What a relay's refusal during the call blamed on this device's clock:
    /// evidence for the clock check, never the relay's words.
    pub clock_rejected: Option<crate::relay::clock_skew::DeviceClockComplaint>,
}

impl PollOutcome {
    fn of(verdict: ReceiveOnlyOutcome, pass: Pass) -> Self {
        Self {
            verdict,
            replayed: pass.replayed,
            welcomes_sent: pass.welcomes_sent,
            retry_after_ms: pass.retry_after_ms,
            errored: pass.errored,
            clock_rejected: pass.clock_rejected,
        }
    }
}

/// How long the product's own resume may run: two rows' worth
/// ([`ROW_BUDGET_MS`]), so one silent relay cannot use the whole of it.
pub const RESUME_BUDGET_MS: u64 = 2 * ROW_BUDGET_MS;

/// When a background burst's OS budget ends: on the driver's clock, and on
/// the monotonic one, so that a wall clock set back during the burst — an
/// NTP step on wake — cannot stretch it.
#[derive(Clone, Copy)]
pub struct BurstEnd {
    at_ms: u64,
    at: std::time::Instant,
}

impl BurstEnd {
    /// The end of a burst whose opener measured `budget_ms` of OS budget, now.
    pub(crate) fn after(clock: &dyn FanoutClock, budget_ms: u64) -> Self {
        Self {
            at_ms: clock.now_ms().saturating_add(budget_ms),
            at: std::time::Instant::now() + std::time::Duration::from_millis(budget_ms),
        }
    }

    /// The end on `clock`: the earlier of the two readings.
    pub(crate) fn on(self, clock: &dyn FanoutClock) -> u64 {
        let left = self.at.saturating_duration_since(std::time::Instant::now());
        self.at_ms.min(
            clock
                .now_ms()
                .saturating_add(u64::try_from(left.as_millis()).unwrap_or(u64::MAX)),
        )
    }
}

/// The deadline of a wake given `budget_ms` on `clock`, cut at the end of a
/// burst.
///
/// The burst is the one `circle`'s live plane is in: work begun inside it —
/// the plane's own drive or a call the bridge makes — never begins what the
/// OS would cut.
#[must_use]
pub fn wake_deadline(circle: &CircleManager, clock: &dyn FanoutClock, budget_ms: u64) -> u64 {
    let deadline = clock.now_ms().saturating_add(budget_ms);
    circle
        .session()
        .burst_end()
        .map_or(deadline, |ends| deadline.min(ends.on(clock)))
}

/// A relay plane that publishes an event no fanout record holds.
///
/// It sends a Welcome, or a proposal no record could be written for, and
/// reports whether at least one relay OK-acked it; never a commit (Security
/// Rule 13).
///
/// "Acked" means a relay returned OK, never merely "sent": a transport error
/// or a zero-ack outcome is `false`. A boxed future keeps the trait
/// object-safe without `async-trait`.
pub trait UnrecordedPublisher: Send + Sync {
    /// Publishes `event` to `relays`; resolves to `true` iff ≥1 relay OK-acked.
    fn publish_unrecorded<'a>(
        &'a self,
        event: &'a nostr::Event,
        relays: &'a [String],
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send + 'a>>;
}

/// The product's publisher of what has no record: `publish_event` already
/// holds the ≥1-relay OK-ack contract
/// ([`crate::relay::PublishResult::is_success`]) and refuses an event a
/// fanout record owns ([`is_owned`]).
impl UnrecordedPublisher for super::RelayManager {
    fn publish_unrecorded<'a>(
        &'a self,
        event: &'a nostr::Event,
        relays: &'a [String],
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send + 'a>> {
        Box::pin(async move {
            self.publish_event(event, relays)
                .await
                .is_ok_and(|result| result.is_success())
        })
    }
}

/// What a send-side change, a receive or send entry, or a resume publishes
/// through, and what it may do.
///
/// Two things leave the device in one of these calls, and each has its own
/// way out. A commit or proposal under a fanout record goes through
/// `fanout`, one relay per call, and through nothing else. A proposal no
/// record could be written for and a Welcome go through `publisher`, which
/// answers whether a relay it was given acknowledged that exact event. No
/// commit goes through it: every engine call these entries make records what
/// it stages. In the product both are the one
/// [`RelayManager`](super::RelayManager).
pub struct Publishing<'a, T: FanoutSend + ?Sized> {
    /// Where a recorded commit is sent.
    pub fanout: &'a T,
    /// Where everything without a record is sent. Acked means acked.
    pub publisher: &'a dyn UnrecordedPublisher,
    /// The clock records are staged, paced and bounded on.
    pub clock: &'a dyn FanoutClock,
    /// The end of the wake's budget, an instant on `clock`, when it has one.
    /// It bounds the whole call. Nothing is begun that the wake could not
    /// see through — a row ([`ROW_BUDGET_MS`]), the wait for an engine
    /// deadline ([`FOLD_BUDGET_MS`]), a publish of something with no record
    /// ([`PUBLISHER_BUDGET_MS`]) — and no relay is waited for past it. What
    /// is not begun stays stored as it was, for the next drive; an attempt
    /// the budget cuts off stays stored as begun, and is treated as
    /// possibly exposed from then on.
    pub deadline_ms: Option<u64>,
    /// What the call may do ([`DriveMode`]), read wherever something is
    /// decided. No default.
    pub mode: &'a dyn ModeSource,
}

/// What one call's drives have handed back so far.
#[derive(Default)]
struct Pass {
    replayed: Vec<LocationMessageResult>,
    welcomes_sent: usize,
    retry_after_ms: Option<u64>,
    errored: bool,
    /// The circles whose own record a drive of this call ended on an error
    /// in ([`DueOutcome::erred`]).
    erred: HashSet<GroupId>,
    /// An error this call could not place in a circle.
    unplaced: bool,
    withdrawn: Vec<WithdrawnChange>,
    requeued: Vec<RequeuedRemoval>,
    clock_rejected: Option<crate::relay::clock_skew::DeviceClockComplaint>,
}

impl From<Pass> for ResumeOutcome {
    fn from(pass: Pass) -> Self {
        Self {
            replayed: pass.replayed,
            welcomes_sent: pass.welcomes_sent,
            retry_after_ms: pass.retry_after_ms,
            clock_rejected: pass.clock_rejected,
            errored: pass.errored,
            withdrawn: pass.withdrawn,
            requeued: pass.requeued,
        }
    }
}

/// What the drive of a call's own commit left.
struct Own {
    status: FanoutStatus,
    notes: Vec<ChangeNote>,
}

impl<T: FanoutSend + ?Sized> Publishing<'_, T> {
    /// Whether the wake still has `needs_ms` left: nothing is begun that it
    /// could not wait out.
    fn allows(&self, needs_ms: u64) -> bool {
        self.deadline_ms
            .is_none_or(|deadline| self.clock.now_ms().saturating_add(needs_ms) <= deadline)
    }

    /// What bounds a pass of this call over rows.
    fn wake(&self, follow: bool) -> Wake<'_> {
        Wake {
            deadline_ms: self.deadline_ms,
            mode: self.mode,
            follow,
        }
    }

    /// Refuses a change asked of a drive that makes no new commit.
    fn makes_changes(&self) -> Result<(), CircleError> {
        match self.mode.mode() {
            DriveMode::Full => Ok(()),
            DriveMode::FinishOnly => Err(CircleError::ForegroundOnly),
        }
    }

    /// [`Self::makes_changes`] for a change of `group_id`'s membership,
    /// admins or relays: none is made for a circle whose routing id is
    /// another circle's on this device too, whose engine may not be applying
    /// its commits ([`CircleError::RoutingCollision`]). The leave, and the
    /// admin steps it takes, are made all the same: leaving is the one way out
    /// of the hold.
    fn changes_circle(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
    ) -> Result<(), CircleError> {
        self.makes_changes()?;
        if circle.session().routing_collided(group_id) {
            return Err(CircleError::RoutingCollision);
        }
        Ok(())
    }

    /// Hands `event` to the publisher of what has no record — in
    /// [`DriveMode::Full`] alone — when the wake
    /// has that publisher's longest run left, and for no longer than the
    /// wake lasts. `None` when it was not begun or the wake ended first:
    /// either way nothing says a relay took it.
    async fn send_unrecorded(&self, event: &nostr::Event, relays: &[String]) -> Option<bool> {
        if self.mode.mode() != DriveMode::Full || !self.allows(PUBLISHER_BUDGET_MS) {
            return None;
        }
        within(
            self.clock,
            self.deadline_ms,
            self.publisher.publish_unrecorded(event, relays),
        )
        .await
    }

    /// Removes `member_pubkeys` from the circle.
    ///
    /// # Errors
    ///
    /// Returns an error when the engine refuses the removal (the caller is
    /// not an admin, the group is unknown). Nothing was staged. A removal no
    /// relay has answered for is NOT an error: see [`EvolutionStatus`].
    pub async fn remove_members(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
        member_pubkeys: &[String],
    ) -> Result<EvolutionOutcome, CircleError> {
        self.changes_circle(circle, group_id)?;
        let pass = self.older(circle, group_id).await;
        let staged = circle
            .remove_members_staging(group_id, member_pubkeys, self.clock.now_ms())
            .await?;
        Ok(self.drive_change(circle, group_id, staged, 0, pass).await)
    }

    /// Replaces the circle's relay list.
    ///
    /// # Errors
    ///
    /// As [`CircleManager::update_circle_relays_staging`]; nothing was staged.
    pub async fn update_relays(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
        new_relays: &[String],
    ) -> Result<EvolutionOutcome, CircleError> {
        self.changes_circle(circle, group_id)?;
        let pass = self.older(circle, group_id).await;
        let staged = circle
            .update_circle_relays_staging(group_id, new_relays, self.clock.now_ms())
            .await?;
        Ok(self.drive_change(circle, group_id, staged, 0, pass).await)
    }

    /// Makes `successor` an admin beside the caller: the first step of an
    /// admin's leave.
    ///
    /// # Errors
    ///
    /// As `CircleManager::propose_admin_handoff_staging`; nothing was staged.
    pub async fn admin_handoff(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
        successor: &PublicKey,
    ) -> Result<EvolutionOutcome, CircleError> {
        self.changes_circle(circle, group_id)?;
        self.hand_over(circle, group_id, successor).await
    }

    /// [`Self::admin_handoff`] as a step of the user's leave.
    async fn hand_over(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
        successor: &PublicKey,
    ) -> Result<EvolutionOutcome, CircleError> {
        self.makes_changes()?;
        let pass = self.older(circle, group_id).await;
        let staged = circle
            .propose_admin_handoff_staging(
                group_id,
                successor,
                self.clock.now_ms(),
                Still::new(self.mode, DriveMode::Full),
            )
            .await?;
        Ok(self.drive_change(circle, group_id, staged, 0, pass).await)
    }

    /// Drops the caller from the circle's admins.
    ///
    /// # Errors
    ///
    /// As `CircleManager::propose_self_demote_staging`; nothing was staged.
    pub async fn self_demote(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
    ) -> Result<EvolutionOutcome, CircleError> {
        self.changes_circle(circle, group_id)?;
        self.step_down(circle, group_id).await
    }

    /// [`Self::self_demote`] as a step of the user's leave.
    async fn step_down(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
    ) -> Result<EvolutionOutcome, CircleError> {
        self.makes_changes()?;
        let pass = self.older(circle, group_id).await;
        let staged = circle
            .propose_self_demote_staging(
                group_id,
                self.clock.now_ms(),
                Still::new(self.mode, DriveMode::Full),
            )
            .await?;
        Ok(self.drive_change(circle, group_id, staged, 0, pass).await)
    }

    /// Leaves `group_id`: the intent is written first, on this driver's
    /// clock, and from that instant no location of the circle is sealed or
    /// sent on any plane ([`SendHeld::Leaving`], [`CircleError::LeaveInProgress`]);
    /// then the leave's plan runs as [`Self::resume_leave`] runs it. The
    /// bound runs from the first press, or from the latest press that found
    /// no proposal ever minted (MDK holds no `LeaveRequest` with
    /// `last_proposed_epoch`; one it cannot read counts as minted).
    ///
    /// # Errors
    ///
    /// The store's error when the intent cannot be written — nothing was
    /// asked of the engine — and as [`Self::resume_leave`].
    pub async fn leave(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
        self_pubkey: &PublicKey,
    ) -> Result<LeaveOutcome, CircleError> {
        let at_secs = i64::try_from(self.clock.now_ms() / 1_000).unwrap_or(i64::MAX);
        // The bound limits the wait once a proposal can exist: a press that
        // finds none ever minted is the user's renewed request (decision 218).
        let renewed = !circle.session().leave_proposed(group_id);
        circle.mark_leave_intent(group_id, at_secs, renewed)?;
        self.resume_leave(circle, group_id, self_pubkey).await
    }

    /// Carries a leave on from where it stands: what a restart calls, and
    /// what every later attempt is.
    ///
    /// A leave whose copy this call finds marked removed or held
    /// unrecoverable by MDK — which refuses every outbound intent on a halted
    /// group, so neither a proposal nor a hand-over can ever leave — or one
    /// [`LEAVE_BOUND_MS`] past its intent — or whose intent lies more than an
    /// hour ([`RETRY_MAX_MS`]) ahead of the clock, which was stepped back —
    /// ends here, on this device ([`CircleManager::complete_leave`]). Nothing
    /// calls this on a timer. At the bound the circle is left whether or not
    /// anybody committed the proposal, and its members keep this device on
    /// their roster until a member commits a `SelfRemove` they hold, or an
    /// admin removes it. Otherwise the plan runs: an admin hands the circle
    /// on and steps down first (each a change, in the full mode only); then
    /// the engine's own leave proposal is recorded and driven. Within an
    /// epoch the retry is that frozen record, byte for byte — the engine
    /// refuses a second proposal for one epoch — and for a later epoch the
    /// engine mints the next proposal itself, recorded by whichever hold it
    /// hands it to, while the stale epoch's record ends. A circle that is not
    /// stable is proposed for on a later call; its sharing stays off.
    ///
    /// # Errors
    ///
    /// [`CircleError::NotFound`] — the leave is refused for good and its
    /// intent ends; [`CircleError::ForegroundOnly`] for an admin step asked
    /// of a drive that makes no new commit; and the store's or engine's
    /// error otherwise, the intent standing. A proposal the engine refuses
    /// because this device is an admin again — its own preflight can settle
    /// a promotion inside the call — is planned again with the intent kept,
    /// so the driver never answers
    /// [`CircleError::AdminSelfDemoteRequired`]; three plans that never reach
    /// a proposal stand pending.
    pub async fn resume_leave(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
        self_pubkey: &PublicKey,
    ) -> Result<LeaveOutcome, CircleError> {
        let Some(since_secs) = circle.leave_intent_at(group_id)? else {
            return Ok(LeaveOutcome::now(LeaveStatus::NotLeaving));
        };
        let now_ms = self.clock.now_ms();
        let since_ms = u64::try_from(since_secs).unwrap_or(0).saturating_mul(1_000);
        // An intent far ahead of the clock means the clock was stepped back
        // and the leave's age is unknown: it ends, as a record does
        // ([`finished`]).
        let stepped_back = far_ahead(since_ms, now_ms);
        if now_ms >= since_ms.saturating_add(LEAVE_BOUND_MS)
            || stepped_back
            || circle.session().removed(group_id).await
            || circle.session().unrecoverable(group_id).await == Some(true)
        {
            return self.left(circle, group_id).await;
        }
        let waits = |retry_after_ms| LeaveOutcome {
            status: LeaveStatus::Pending,
            retry_after_ms,
            clock_rejected: None,
        };
        // Inside the wait a refused eviction earned, every step the plan
        // asks for would have the engine stage that eviction first, the hold
        // undo it and queue the step behind it, once per call: the leave
        // waits the wait out, its intent standing and its circle's sends held.
        if circle
            .session()
            .refused_eviction_waits(group_id, now_ms)
            .await
        {
            return Ok(waits(
                circle.session().restage_wait_left_ms(group_id, now_ms),
            ));
        }
        for _ in 0..3 {
            let step = match circle.plan_leave(group_id, self_pubkey).await? {
                LeavePlan::OrphanLocalOnly | LeavePlan::Abandon => {
                    return self.left(circle, group_id).await
                }
                LeavePlan::AdminHandoff { successor } => {
                    self.hand_over(circle, group_id, &successor).await?
                }
                LeavePlan::AdminDemote => self.step_down(circle, group_id).await?,
                // The engine's own preflight can re-admit this device between
                // the plan's read and the proposal (it settles its inputs
                // first): the plan is read again, the intent kept.
                LeavePlan::NonAdmin => match self.propose_leave(circle, group_id).await {
                    Err(CircleError::AdminSelfDemoteRequired) => continue,
                    other => return other,
                },
            };
            if !matches!(
                step.status,
                EvolutionStatus::Confirmed | EvolutionStatus::AlreadySo
            ) {
                return Ok(waits(Some(0)));
            }
        }
        Ok(waits(Some(BUSY_RETRY_MS)))
    }

    /// The leave's proposal, recorded and driven.
    async fn propose_leave(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
    ) -> Result<LeaveOutcome, CircleError> {
        let mut pass = self.older(circle, group_id).await;
        let (status, rows) = match circle
            .propose_leave_staging(
                group_id,
                self.clock.now_ms(),
                Still::new(self.mode, self.mode.mode()),
            )
            .await?
        {
            LeaveStep::Recorded(rows) => (LeaveStatus::Proposed, rows),
            LeaveStep::AlreadyProposed => (LeaveStatus::Proposed, Vec::new()),
            LeaveStep::AwaitsStable(rows) | LeaveStep::Unrecorded(rows) => {
                (LeaveStatus::Pending, rows)
            }
        };
        let due = drive_rows(
            circle,
            self.fanout,
            self.clock,
            rows.into(),
            &self.wake(true),
        )
        .await;
        let _ = self.absorb(circle, due, None, &mut pass).await;
        Ok(LeaveOutcome {
            status,
            retry_after_ms: pass.retry_after_ms,
            clock_rejected: pass.clock_rejected,
        })
    }

    async fn left(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
    ) -> Result<LeaveOutcome, CircleError> {
        let now_secs = i64::try_from(self.clock.now_ms() / 1_000).unwrap_or(i64::MAX);
        circle.complete_leave(group_id, now_secs).await?;
        Ok(LeaveOutcome::now(LeaveStatus::Completed))
    }

    /// Repairs a circle whose sender ratchets are exhausted
    /// (`CircleManager::repair_epoch_rotation_staging`).
    ///
    /// # Errors
    ///
    /// As `CircleManager::repair_epoch_rotation_staging`; nothing was staged.
    pub async fn repair_rotation(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
    ) -> Result<RepairOutcome, CircleError> {
        self.changes_circle(circle, group_id)?;
        let mut pass = self.older(circle, group_id).await;
        let now_ms = self.clock.now_ms();
        match circle
            .repair_epoch_rotation_staging(
                group_id,
                now_ms / 1_000,
                now_ms,
                Still::new(self.mode, DriveMode::Full),
            )
            .await?
        {
            StagedRepair::Skipped(reason) => Ok(RepairOutcome::Skipped(reason)),
            StagedRepair::Rotated(staged) => Ok(RepairOutcome::Rotated(
                self.drive_change(circle, group_id, staged, 0, pass).await,
            )),
            StagedRepair::Deferred {
                recorded,
                handed_back,
            } => {
                self.settle(circle, recorded, handed_back, true, &mut pass)
                    .await;
                Ok(RepairOutcome::Deferred {
                    held_by: self.send_held(circle, group_id, false).await,
                    replayed: pass.replayed,
                })
            }
        }
    }

    /// Creates a circle with `members` and sends each of its founding
    /// Welcomes from the delivery record the create wrote for it before
    /// returning ([`CircleManager::create_circle`]): the exact stored event,
    /// to its invitee's inbox relays alone, completed only on one of them
    /// acknowledging that event. A Welcome no relay took stays owed, and the
    /// foreground drives that follow send it on its relay's schedule for a
    /// day. In the full mode only: nothing is created otherwise.
    ///
    /// # Errors
    ///
    /// [`CircleError::ForegroundOnly`] outside the full mode, and as
    /// [`CircleManager::create_circle`]: then nothing was created.
    pub async fn create_circle(
        &self,
        circle: &CircleManager,
        sender_keys: &nostr::Keys,
        members: Vec<MemberKeyPackage>,
        config: &crate::circle::CircleConfig,
    ) -> Result<CreateOutcome, CircleError> {
        self.makes_changes()?;
        let welcomes_total = members.len();
        let created = circle
            .create_circle_at(sender_keys, members, config, self.clock.now_ms())
            .await?;
        self.deliver_welcomes(circle).await;
        // Counted by the Welcomes' own rows: the live plane's drive may have
        // delivered one and ended its record before this drive listed it.
        let (welcomes_sent, unsent_recipients) = circle
            .session()
            .founding_welcomes_standing(&created.circle.mls_group_id, &created.founding_welcomes)
            .await;
        Ok(CreateOutcome {
            circle: created.circle,
            welcomes_sent,
            welcomes_total,
            unsent_recipients,
        })
    }

    /// Invites `members` to the circle.
    ///
    /// Each Welcome is sent only once its invite's commit is applied on this
    /// device and still its canonical one, to the relays resolved for that
    /// invitee before anything was staged, and counted as sent only when one
    /// of them acknowledged that exact event. An invite still awaiting
    /// relays keeps its Welcomes; they go out with the drive that confirms
    /// it, while this session lasts.
    ///
    /// # Errors
    ///
    /// As [`CircleManager::add_members_staging`]; nothing was staged.
    pub async fn add_members(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
        members: &[MemberKeyPackage],
    ) -> Result<EvolutionOutcome, CircleError> {
        self.changes_circle(circle, group_id)?;
        let pass = self.older(circle, group_id).await;
        let staged = circle
            .add_members_staging(group_id, members, self.clock.now_ms())
            .await?;
        Ok(self
            .drive_change(circle, group_id, staged, members.len(), pass)
            .await)
    }

    /// Drives every stored record that has something due, in every circle:
    /// what a session does at its first foreground tick and at each one
    /// after it, so that a commit a kill interrupted — or one the open
    /// itself found staged with no record — is sent again without the user
    /// doing anything.
    ///
    /// A relay that is not due is not called. A circle whose record the
    /// engine no longer holds staged is served the engine's own deadline
    /// here, because nothing else asks for it: the engine disposes of such a
    /// commit only in a convergence pass, and opens one only when asked.
    ///
    /// The wake's budget bounds the whole call: no row, no deadline to wait
    /// out, no Welcome and no other publish is begun unless the wake has its
    /// longest run left, and no relay is waited for past the wake's end. A
    /// record still unheld when the call returns asks to be resumed when the
    /// engine's own deadline for its circle falls due.
    ///
    /// In [`DriveMode::Full`] it first gives the full advance to each circle
    /// whose eviction of a member who left is due and not made — a plane
    /// that makes no commit left it so, or every relay refused the last one
    /// and the wait that earned is over
    /// (`SessionManager::evictions_left_due`) — so that the eviction is
    /// staged under a record and sent in this pass: nothing else stages it
    /// for a device that is not sending. A wait still running is part of
    /// what the call asks to be resumed for
    /// ([`ResumeOutcome::retry_after_ms`]). In [`DriveMode::FinishOnly`]
    /// neither that nor the engine's deadline is served: both make the
    /// advance that can make a commit.
    pub async fn resume(&self, circle: &CircleManager) -> ResumeOutcome {
        let mut pass = Pass::default();
        let now_ms = self.clock.now_ms();
        if self.mode.mode() == DriveMode::Full {
            circle.forget_left_groups().await;
            self.reissue_withdrawn(circle, now_ms, &mut pass).await;
            self.requeue_set_aside_removals(circle, &mut pass).await;
            for group_id in circle.session().evictions_left_due(now_ms).await {
                if self.mode.mode() != DriveMode::Full || !self.allows(FOLD_BUDGET_MS) {
                    break;
                }
                if !circle.session().may_stage_left_due(&group_id).await {
                    continue;
                }
                let (served, _recorded) = circle
                    .stage_due_eviction(&group_id, now_ms, Still::new(self.mode, DriveMode::Full))
                    .await;
                self.dispose(circle, served, &mut pass.replayed).await;
            }
        }
        let due = drive_due(
            circle,
            self.fanout,
            self.clock,
            None,
            self.deadline_ms,
            self.mode,
        )
        .await;
        let unheld: Vec<FanoutId> = due
            .driven
            .iter()
            .filter(|(_, outcome)| outcome.unheld)
            .map(|(id, _)| id.clone())
            .collect();
        self.absorb(circle, due, None, &mut pass).await;
        for id in unheld {
            if self.mode.mode() != DriveMode::Full {
                break;
            }
            let mut work = VecDeque::from([id.clone()]);
            if self.allows(FOLD_BUDGET_MS) {
                let (served, staged) = circle
                    .serve_deadlines(
                        id.group(),
                        self.clock.now_ms(),
                        Still::new(self.mode, DriveMode::Full),
                    )
                    .await;
                self.dispose(circle, served, &mut pass.replayed).await;
                work = staged.into_iter().chain(work).collect();
            }
            let again = drive_rows(circle, self.fanout, self.clock, work, &self.wake(true)).await;
            let still_unheld = again
                .driven
                .iter()
                .any(|(driven, outcome)| *driven == id && outcome.unheld);
            self.absorb(circle, again, None, &mut pass).await;
            if still_unheld {
                // Nothing here can resolve it: the engine's next pass does,
                // and the engine says when that is due. Never sooner than a
                // busy relay is asked again, so a scheduler does not spin.
                if let Some(due) = circle.session().receive_retick_after(id.group()).await {
                    let wait = u64::try_from(due.as_millis())
                        .unwrap_or(u64::MAX)
                        .max(BUSY_RETRY_MS);
                    pass.retry_after_ms =
                        Some(pass.retry_after_ms.map_or(wait, |least| least.min(wait)));
                }
            }
        }
        // Last, once every stored record has been driven and every deadline
        // served: a circle a resolution in this call settled is read as it
        // now stands.
        if self.mode.mode() == DriveMode::Full {
            self.post_join(circle, &mut pass).await;
        }
        // The drive a circle was left waiting for is this one, once it has
        // run to its end: not cut short by its wake, and not on an error of
        // the circle's own record — one circle's error holds no other's.
        if self.mode.mode() == DriveMode::Full && !pass.unplaced && self.allows(ROW_BUDGET_MS) {
            circle
                .session()
                .foreground_drove(Still::new(self.mode, DriveMode::Full), &pass.erred)
                .await;
        }
        // A wait a refused eviction earned is something to come back for:
        // nothing else stages that eviction again for a device that is not
        // sending, and only a full drive does.
        if self.mode.mode() == DriveMode::Full {
            let soonest = circle
                .session()
                .restage_due_after_ms(self.clock.now_ms())
                .await;
            if let Some(wait) = soonest.map(|wait| wait.max(BUSY_RETRY_MS)) {
                pass.retry_after_ms =
                    Some(pass.retry_after_ms.map_or(wait, |least| least.min(wait)));
            }
        }
        pass.into()
    }

    /// Makes at most one post-join self-update MDK's obligation owes
    /// (`SessionManager::post_join_due`), under a record, and drives it:
    /// one per call, so no two circles' commits leave in one second. When
    /// a circle waits only for its windows, the call asks to be resumed then
    /// ([`ResumeOutcome::retry_after_ms`]), and no timer is armed here.
    /// Never in [`DriveMode::FinishOnly`]: the caller runs it in a full
    /// block alone, after every record and deadline of the call.
    async fn post_join(&self, circle: &CircleManager, pass: &mut Pass) {
        let session = circle.session();
        let (due, wait) = session.post_join_due(session.legacy_now_ms()).await;
        if let Some(wait) = wait {
            pass.retry_after_ms = Some(pass.retry_after_ms.map_or(wait, |least| least.min(wait)));
        }
        let Some(group_id) = due.first() else {
            return;
        };
        if self.mode.mode() != DriveMode::Full || !self.allows(FOLD_BUDGET_MS) {
            return;
        }
        let made_at = session.legacy_now_ms();
        match circle
            .post_join_self_update_staging(
                group_id,
                self.clock.now_ms(),
                Still::new(self.mode, DriveMode::Full),
            )
            .await
        {
            StagedPostJoin::Made(change) => {
                if change.commit.is_some() {
                    session.post_join_made(made_at);
                }
                let outcome = self
                    .drive_change(circle, group_id, change, 0, Pass::default())
                    .await;
                pass.replayed.extend(outcome.replayed);
                pass.clock_rejected = pass.clock_rejected.or(outcome.clock_rejected);
                pass.retry_after_ms = match (pass.retry_after_ms, outcome.retry_after_ms) {
                    (Some(a), Some(b)) => Some(a.min(b)),
                    (a, b) => a.or(b),
                };
            }
            StagedPostJoin::NotMade(recorded, handed_back) => {
                self.settle(circle, recorded, handed_back, true, pass).await;
            }
        }
        // Read again: the obligation the drive confirmed is completed, and
        // the next circle due waits out its spacing after this one.
        let (_, wait) = session.post_join_due(session.legacy_now_ms()).await;
        if let Some(wait) = wait {
            pass.retry_after_ms = Some(pass.retry_after_ms.map_or(wait, |least| least.min(wait)));
        }
    }

    /// Drives the re-invites MDK owes (`docs/MDK_UPSTREAM_TRACKER.md`
    /// T-REINVITE-DRIVER): for each, MDK reserves a lookup — its own budget
    /// and pacing, kept durably (5 s, 30 s, 2 min, 10 min, 1 h, 6 h, then a
    /// day, eight lookups in all) — fresh key packages are looked up for its
    /// invitees through `lookup`, where each Welcome is to go is kept, and
    /// MDK queues the invite again; the advance that stages the circle's
    /// queue is made in the same call, under a record.
    ///
    /// Only in [`DriveMode::Full`]: it makes a change. Each lookup asks the
    /// relays of one invitee for three lists (10050, 10002, 30443).
    pub async fn reinvite(
        &self,
        circle: &CircleManager,
        lookup: &dyn ReinviteLookup,
    ) -> Vec<Reinvite> {
        let mut out = Vec::new();
        for owed in circle.session().owed_reinvites().await {
            if self.mode.mode() != DriveMode::Full || !self.allows(ROW_BUDGET_MS) {
                break;
            }
            // An invite into a circle whose engine may not be applying its
            // commits waits, owed, for the hold to end with the circle.
            if circle.session().routing_collided(&owed.group_id) {
                continue;
            }
            let result = self.reinvite_one(circle, &owed, lookup).await;
            out.push(Reinvite {
                group_id: owed.group_id,
                result,
            });
        }
        out
    }

    async fn reinvite_one(
        &self,
        circle: &CircleManager,
        owed: &crate::nostr::mls::types::OwedReinvite,
        lookup: &dyn ReinviteLookup,
    ) -> ReinviteResult {
        use crate::nostr::mls::types::{ReinviteRefusal, ReinviteReservation, ReinviteStanding};
        if owed.standing == ReinviteStanding::Unsettled {
            return ReinviteResult::Unsettled;
        }
        let now_ms = self.clock.now_ms();
        match circle
            .session()
            .reserve_reinvite(&owed.commit_id, now_ms)
            .await
        {
            ReinviteReservation::Reserved => {}
            ReinviteReservation::NotDue => return ReinviteResult::NotDue,
            ReinviteReservation::GaveUp => return ReinviteResult::GaveUp,
        }
        // A circle that ends it names nobody: no relay is asked, and MDK
        // ends it on no key packages.
        let mut members = Vec::with_capacity(owed.invitees.len());
        for invitee in &owed.invitees {
            match lookup.member(circle, &owed.group_id, invitee).await {
                Some(member) if member.key_package_event.pubkey.to_hex() == *invitee => {
                    members.push(member);
                }
                _ => return ReinviteResult::KeyPackageMissing,
            }
        }
        let Ok(routes) = crate::circle::welcome_routes_of(&members) else {
            return ReinviteResult::NoInbox;
        };
        let Ok(packages) = crate::circle::key_packages_of(&members) else {
            return ReinviteResult::KeyPackageMissing;
        };
        // Kept before MDK queues the invite: the advance that stages it hands
        // its Welcomes to records with these routes.
        let Ok(prior) = circle.keep_welcome_routes(&owed.group_id, &routes) else {
            return ReinviteResult::Unmade;
        };
        let reissued = circle
            .session()
            .reissue_invite(&owed.commit_id, packages)
            .await;
        let (change, queued) = match reissued {
            Ok(Some((change, queued))) if change.outcome == WithdrawnOutcome::Reissued => {
                (change, queued)
            }
            other => {
                circle.restore_welcome_routes(&owed.group_id, &prior);
                return match other {
                    Err(ReinviteRefusal::KeyPackage) => ReinviteResult::KeyPackageMissing,
                    Err(ReinviteRefusal::Failed) => ReinviteResult::Unmade,
                    Ok(_) => ReinviteResult::Ended,
                };
            }
        };
        let (served, recorded) = circle
            .stage_due_eviction(
                &change.group_id,
                now_ms,
                Still::new(self.mode, DriveMode::Full),
            )
            .await;
        let released = match &queued {
            Some(queued) => {
                circle
                    .session()
                    .released_into_record(&change.group_id, queued, &recorded)
                    .await
            }
            None => false,
        };
        let mut replayed = Vec::new();
        self.dispose(circle, served, &mut replayed).await;
        if released {
            ReinviteResult::Reissued
        } else {
            ReinviteResult::Queued
        }
    }

    /// Hands MDK this device's withdrawn changes one at a time
    /// (`SessionManager::reissue_next_withdrawn`), each only while the drive
    /// may still make what MDK queues again, and makes it under a record in
    /// the same drive: left queued it would hold its circle. `Reissued` only
    /// when the advance released MDK's new queued copy into a record; one it
    /// did not is returned `Queued`: the circle's next full advance makes it,
    /// or the next open retires it, saying it was dropped.
    async fn reissue_withdrawn(&self, circle: &CircleManager, now_ms: u64, pass: &mut Pass) {
        while self.mode.mode() == DriveMode::Full && self.allows(FOLD_BUDGET_MS) {
            let Some((mut change, requeued)) = circle.session().reissue_next_withdrawn().await
            else {
                break;
            };
            if change.outcome == WithdrawnOutcome::Reissued {
                let (served, recorded) = circle
                    .stage_due_eviction(
                        &change.group_id,
                        now_ms,
                        Still::new(self.mode, DriveMode::Full),
                    )
                    .await;
                let released = match &requeued {
                    Some(queued) => {
                        circle
                            .session()
                            .released_into_record(&change.group_id, queued, &recorded)
                            .await
                    }
                    None => false,
                };
                if !released {
                    change.outcome = WithdrawnOutcome::Queued;
                }
                self.dispose(circle, served, &mut pass.replayed).await;
            }
            pass.withdrawn.push(change);
        }
    }

    /// Takes up each removal set aside unmade that the session says to ask
    /// for again (`SessionManager::removals_to_requeue`): through this
    /// driver's own change entry, so it is staged under a record and driven
    /// on every relay's own schedule like any removal the user asks for. An
    /// ask is spent before the removal is asked for — one whose spend cannot
    /// be written is not asked for — and given back when nothing was staged
    /// under a record; one the engine queued instead is taken back in its
    /// hold.
    async fn requeue_set_aside_removals(&self, circle: &CircleManager, pass: &mut Pass) {
        for (group_id, decided) in circle.session().removals_to_requeue().await {
            let outcome = match decided {
                RemovalRequeue::AlreadyMade => RequeueOutcome::AlreadyMade,
                RemovalRequeue::Abandoned => RequeueOutcome::Abandoned,
                RemovalRequeue::Expired => RequeueOutcome::Expired,
                RemovalRequeue::Remove(members) => {
                    if self.mode.mode() != DriveMode::Full || !self.allows(ROW_BUDGET_MS) {
                        continue;
                    }
                    let Some(counted) = circle.session().spend_requeue_ask(&group_id, &members)
                    else {
                        continue;
                    };
                    let named: Vec<String> = members
                        .iter()
                        .map(|member| hex::encode(member.as_slice()))
                        .collect();
                    let outcome = match self.requeue_removal(circle, &group_id, &named).await {
                        Ok(made) => match made.status {
                            EvolutionStatus::Confirmed | EvolutionStatus::AlreadySo => {
                                RequeueOutcome::Made
                            }
                            EvolutionStatus::Unresolved => RequeueOutcome::Pending,
                            EvolutionStatus::RolledBack | EvolutionStatus::Stale => {
                                RequeueOutcome::Undone
                            }
                            EvolutionStatus::Queued | EvolutionStatus::Unrecorded => {
                                RequeueOutcome::NotMade
                            }
                        },
                        Err(_) => RequeueOutcome::NotMade,
                    };
                    if outcome == RequeueOutcome::NotMade {
                        circle.session().refund_requeue_ask(&group_id, &counted);
                    }
                    outcome
                }
            };
            pass.requeued.push(RequeuedRemoval { group_id, outcome });
        }
    }

    /// [`Self::remove_members`] for decision 180's ask: a removal the engine
    /// queues rather than stages is taken back in the hold that queued it.
    async fn requeue_removal(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
        member_pubkeys: &[String],
    ) -> Result<EvolutionOutcome, CircleError> {
        self.changes_circle(circle, group_id)?;
        let pass = self.older(circle, group_id).await;
        let staged = circle
            .requeue_removal_staging(group_id, member_pubkeys, self.clock.now_ms())
            .await?;
        Ok(self.drive_change(circle, group_id, staged, 0, pass).await)
    }

    /// Drives what a receive plane's own engine call recorded — `staged`,
    /// each in the hold that released it — and publishes once what it could
    /// write no record for (`handed_back`).
    pub async fn settle_staged(
        &self,
        circle: &CircleManager,
        staged: Vec<FanoutId>,
        handed_back: DecryptedIngest,
    ) -> ResumeOutcome {
        let mut pass = Pass::default();
        self.settle(circle, staged, handed_back, true, &mut pass)
            .await;
        pass.into()
    }

    /// [`Self::settle_staged`] into `pass`. With `follow` off, a record a
    /// resolution makes in turn is left for the next drive: how an entry
    /// that is not itself a drive keeps to one row per record it made.
    async fn settle(
        &self,
        circle: &CircleManager,
        recorded: Vec<FanoutId>,
        handed_back: DecryptedIngest,
        follow: bool,
        pass: &mut Pass,
    ) {
        self.dispose(circle, handed_back, &mut pass.replayed).await;
        if !recorded.is_empty() {
            let wake = self.wake(follow);
            let due = drive_rows(circle, self.fanout, self.clock, recorded.into(), &wake).await;
            self.absorb(circle, due, None, pass).await;
        }
    }

    /// Drives `group_id`'s pending commit record, when it has one, through
    /// one row: what a receive or send entry does before its own engine
    /// call. A commit still pending holds its circle's sends and leaves what
    /// the circle receives unread, so an acknowledgement that is due
    /// unblocks the very call that asked. Nothing else of the circle is
    /// driven here — an applied commit's remaining relays and a proposal are
    /// [`Self::resume`]'s — so a circle with no pending commit costs one
    /// read of the store and no relay is called for it.
    async fn unblock(&self, circle: &CircleManager, group_id: &GroupId, pass: &mut Pass) {
        match circle.session().pending_commit_fanout(group_id).await {
            Ok(Some(id)) => {
                let wake = self.wake(false);
                let due = drive_rows(circle, self.fanout, self.clock, [id].into(), &wake).await;
                self.absorb(circle, due, None, pass).await;
            }
            Ok(None) => {}
            Err(_) => {
                pass.errored = true;
                pass.erred.insert(group_id.clone());
            }
        }
    }

    /// What the user needs to know first about `group_id`, read now, worst
    /// first ([`worst_recovery`]); `None` when nothing holds it. What holds
    /// its sends is [`Self::send_held`]'s one definition, read in this call's
    /// mode. A quarantined circle reads as such, and its other facts are not
    /// asked of an engine that does not hold it.
    ///
    /// # Errors
    ///
    /// [`CircleError::NotFound`] when no circle row names `group_id`, or a
    /// redacted storage error.
    pub async fn circle_recovery(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
    ) -> Result<Option<RecoveryCause>, CircleError> {
        if circle
            .storage
            .get_circle(group_id)
            .map_err(|e| crate::circle::redact_storage_error(&e))?
            .is_none()
        {
            return Err(CircleError::NotFound(
                "Circle not found: <redacted>".to_string(),
            ));
        }
        let session = circle.session();
        let quarantined = session.quarantined_group_ids().await.contains(group_id);
        let facts = if quarantined {
            RecoveryFacts {
                disbanded: false,
                unrecoverable: false,
                quarantined,
                stalled: false,
                held: SendHeld::Nothing,
            }
        } else {
            RecoveryFacts {
                disbanded: session.disbanded(group_id).await,
                unrecoverable: session.unrecoverable(group_id).await == Some(true),
                quarantined,
                stalled: session.stalled(group_id),
                held: self.send_held(circle, group_id, false).await,
            }
        };
        Ok(worst_recovery(facts))
    }

    /// What holds `group_id`'s sends now. `departure_due` says the call
    /// itself held a send back for a departure it could not make.
    async fn send_held(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
        departure_due: bool,
    ) -> SendHeld {
        let session = circle.session();
        if session.leaving(group_id) {
            return SendHeld::Leaving;
        }
        match session.staged_commit(group_id).await {
            Some(true) if session.pending_commit_acknowledged(group_id).await => {
                SendHeld::Acknowledged
            }
            Some(true) => SendHeld::AwaitingRelays,
            Some(false) => SendHeld::StagedWithoutRecord,
            None => match session.held_away(group_id, self.mode.mode()).await {
                Some(AwayHold::RelayChange) => SendHeld::AwaitsForeground,
                Some(AwayHold::RemovalUnmade) => SendHeld::RemovalUnmade,
                Some(AwayHold::Leaving) => SendHeld::Leaving,
                Some(AwayHold::RoutingCollision) => SendHeld::RoutingCollision,
                // A refused commit's wait holds sends only while the engine
                // announces an eviction: a refused self-update holds none.
                None if departure_due
                    || session
                        .refused_eviction_waits(group_id, self.clock.now_ms())
                        .await =>
                {
                    SendHeld::DepartureDue
                }
                None if session.holds_unread_input(group_id)
                    || session.send_gated(group_id).await
                    || session.deferred_peels_due(group_id).await =>
                {
                    SendHeld::StoredInput
                }
                None => SendHeld::Nothing,
            },
        }
    }

    /// One polled `kind:445`, for a receive plane that polls: ingested in
    /// staging mode, with what it staged driven in the same call.
    ///
    /// The circle the event is addressed to has its pending commit driven
    /// first ([`Self::unblock`]). The event is then ingested with every
    /// commit and proposal the engine hands back recorded in the hold that
    /// took it, and the circles it leaves owing an advance are advanced as a
    /// plane that drives advances them. In [`DriveMode::Full`] that is the
    /// full advance, and every circle that holds a queued change of the
    /// group is given it too, so no such change keeps its circle from
    /// applying what it receives past one polled event; in
    /// [`DriveMode::FinishOnly`] it is the inputs-only advance, and nothing
    /// new is made. What was recorded is driven, one row each.
    ///
    /// What comes back is every location and group update the call produced
    /// — ingested, released by an advance, or replayed by a confirm — each
    /// already stored and stamped as arrived — and whether the caller's
    /// cursor may pass the event ([`PollOutcome::verdict`], Security Rule
    /// 12): the classification the catch-up sweep makes of the same engine
    /// answer, by the same function. An event Haven's own screen rejected
    /// before authentication yields nothing and is no evidence either way.
    ///
    /// The advances wait out the engine's own deadlines, so they are made
    /// only with [`FOLD_BUDGET_MS`] of the wake left; without, the event is
    /// ingested, nothing is advanced, and [`PollOutcome::retry_after_ms`] is
    /// zero.
    ///
    /// # Errors
    ///
    /// Returns the ingest's error, typed where the caller must tell it apart
    /// ([`CircleError::EngineHeld`]), when nothing had been collected; after
    /// that it is [`PollOutcome::errored`], and the event is held.
    pub async fn ingest_for_poll(
        &self,
        circle: &CircleManager,
        event: &nostr::Event,
    ) -> Result<PollOutcome, CircleError> {
        let mut pass = Pass::default();
        if let Some(group_id) = circle.group_of_event(event) {
            self.unblock(circle, &group_id, &mut pass).await;
        }
        let (mode, now_ms) = (self.mode.mode(), self.clock.now_ms());
        let session = circle.session();
        let (screened, mut recorded) = match session
            .process_event_staging(event, now_ms, Still::new(self.mode, mode))
            .await
        {
            Ok(ingested) => ingested,
            Err(e) if pass.replayed.is_empty() && !pass.errored => {
                return Err(CircleError::from_session(e));
            }
            Err(_) => {
                pass.errored = true;
                return Ok(PollOutcome::of(ReceiveOnlyOutcome::Deferred, pass));
            }
        };
        let Some(ingest) = screened.ingested() else {
            return Ok(PollOutcome::of(ReceiveOnlyOutcome::NoEvidence, pass));
        };
        let mut owing = SessionManager::groups_owing_service(&ingest);
        if mode == DriveMode::Full {
            owing.extend(session.groups_holding_queued_changes().await);
        }
        let (answer, unpersisted) = (ingest.outcome, ingest.left_object_unpersisted);
        let mut effects = ingest.effects;
        for group_id in owing {
            if !effects.pending_convergence.contains(&group_id) {
                effects.pending_convergence.push(group_id);
            }
        }
        let advance = self.allows(FOLD_BUDGET_MS);
        let (handed_back, further) = circle
            .fold_staged(effects, advance, now_ms, Still::new(self.mode, mode))
            .await;
        recorded.extend(further);
        self.settle(circle, recorded, handed_back, false, &mut pass)
            .await;
        if !advance {
            pass.retry_after_ms = Some(0);
        }
        // After the advances, as the sweep classifies: they may have carried
        // the circle past what the engine had only buffered.
        let verdict = super::catchup::cursor_verdict(circle, &event.id, answer, unpersisted).await;
        Ok(PollOutcome::of(verdict, pass))
    }

    /// Encrypts `location` for the circle, for a plane whose commits ride
    /// durable fanouts.
    ///
    /// The circle's pending commit is driven first ([`Self::unblock`]): a
    /// relay's acknowledgement that is due applies it, and this very send is
    /// then sealed at the epoch it leaves. The send is made in staging mode:
    /// an eviction the engine's preflight commits ahead of the location is
    /// recorded in that hold and driven here, one row — never handed back to
    /// a ladder — and the send it queued is answered as deferred, its fix
    /// discarded. A deferral with nothing staged behind it runs the
    /// deferred-send repair as a plane that drives runs it
    /// (`CircleManager::repair_deferred_send_staging`). Nothing is retried:
    /// the next send carries a fresher fix.
    ///
    /// Inside the wait a refused eviction earned, and in
    /// [`DriveMode::FinishOnly`] while an eviction is due, the send is not
    /// made at all and nothing is staged: the answer is
    /// [`SendHeld::DepartureDue`].
    ///
    /// The repair waits out the engine's own deadlines, so it is begun only
    /// with [`FOLD_BUDGET_MS`] of the wake left, and only when the pre-send
    /// drain was not cut short at the wake's end ([`wake_deadline`]: a burst
    /// ends it); otherwise nothing is folded, the answer is what the store
    /// shows still holds the circle, and [`SealOutcome::retry_after_ms`] is
    /// zero.
    ///
    /// # Errors
    ///
    /// Returns [`CircleError::EngineHeld`] and
    /// [`CircleError::SendBlockedByDeparture`] as the send met them, once —
    /// nothing here retries either — and any other failure of the send by
    /// its kind. A deferral is not an error: see [`LocationSeal::Deferred`].
    pub async fn seal_location(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
        location: &LocationMessage,
    ) -> Result<SealOutcome, CircleError> {
        let mut pass = Pass::default();
        if circle.session().disbanded(group_id).await {
            return Ok(SealOutcome {
                seal: LocationSeal::Deferred(SendHeld::Disbanded),
                replayed: pass.replayed,
                retry_after_ms: None,
                errored: pass.errored,
                clock_rejected: pass.clock_rejected,
            });
        }
        if circle.session().leaving(group_id) {
            return Ok(SealOutcome {
                seal: LocationSeal::Deferred(SendHeld::Leaving),
                replayed: pass.replayed,
                retry_after_ms: None,
                errored: pass.errored,
                clock_rejected: pass.clock_rejected,
            });
        }
        self.unblock(circle, group_id, &mut pass).await;
        // Read after the hand-back: a commit this device fetched and has not
        // taken in may remove a member, who would read what is sealed now.
        if circle.session().holds_unread_input(group_id) {
            return Ok(SealOutcome {
                seal: LocationSeal::Deferred(SendHeld::StoredInput),
                replayed: pass.replayed,
                retry_after_ms: None,
                errored: pass.errored,
                clock_rejected: pass.clock_rejected,
            });
        }
        let (mode, now_ms) = (self.mode.mode(), self.clock.now_ms());
        let StagedSeal {
            sealed,
            mut recorded,
            mut handed_back,
            departure_due,
            drain_cut,
        } = match circle
            .seal_location_staging(
                group_id,
                location,
                now_ms,
                Still::new(self.mode, mode),
                self.clock,
                self.deadline_ms,
            )
            .await
        {
            Ok(seal) => seal,
            // Stranded input still owed to the circle, or a rolled-back
            // commit not yet retired: nothing is sealed, and the next call —
            // at once — carries on. What the settle ahead of the send took in
            // is stored already, and any commit it recorded is that call's
            // to drive.
            Err(CircleError::EngineHeld) => {
                return Ok(SealOutcome {
                    seal: LocationSeal::Deferred(SendHeld::StoredInput),
                    replayed: pass.replayed,
                    retry_after_ms: Some(0),
                    errored: pass.errored,
                    clock_rejected: pass.clock_rejected,
                });
            }
            Err(e) => return Err(e),
        };
        let staged_here = recorded.iter().any(|id| id.group() == group_id);
        // The repair waits out the engine's deadlines: not begun in a wake
        // that could not see it through, nor in one with no room left for
        // the drain it would continue.
        let unrepaired = sealed.is_none()
            && !staged_here
            && !departure_due
            && (drain_cut || !self.allows(FOLD_BUDGET_MS));
        if sealed.is_none() && !staged_here && !departure_due && !unrepaired {
            let (repaired, further) = circle
                .repair_deferred_send_staging(
                    group_id,
                    now_ms / 1_000,
                    now_ms,
                    Still::new(self.mode, mode),
                )
                .await;
            handed_back.results.extend(repaired.results);
            handed_back.proposals.extend(repaired.proposals);
            recorded.extend(further);
        }
        self.settle(circle, recorded, handed_back, false, &mut pass)
            .await;
        if unrepaired {
            pass.retry_after_ms = Some(0);
        }
        let seal = match sealed {
            Some((event, nostr_group_id, relays)) => LocationSeal::Sealed {
                event: Box::new(event),
                nostr_group_id,
                relays,
            },
            None => LocationSeal::Deferred(self.send_held(circle, group_id, departure_due).await),
        };
        Ok(SealOutcome {
            seal,
            replayed: pass.replayed,
            retry_after_ms: pass.retry_after_ms,
            errored: pass.errored,
            clock_rejected: pass.clock_rejected,
        })
    }

    /// Sends a location [`Self::seal_location`] sealed — `event` — to the
    /// relays its record was frozen for, ONCE, and ends the record whatever
    /// the transport answers: a location that missed is superseded by the
    /// next, never retried.
    ///
    /// The record was written in the hold that sealed the event; this is
    /// its first relay write, and the delete that follows is its last store
    /// write — two for a send. A process that dies between them leaves the
    /// record for [`drive_due`], which ends it unsent. A second call for the
    /// same event finds no record and sends nothing; so does a call for an
    /// event that has expired, or that could not be sent before it does, and
    /// one a fresh seal would no longer be made for — however long the caller
    /// took between the seal and this.
    ///
    /// Made in any mode: a burst exists to send the location it has just
    /// sealed. No relay is taken and no commit's call is waited for.
    pub async fn publish_location(
        &self,
        circle: &CircleManager,
        event: &nostr::Event,
    ) -> LocationPublish {
        let message = MessageId::new(event.id.as_bytes().to_vec());
        let Some(_driving) = Driving::claim_message(&message) else {
            return LocationPublish::InFlight;
        };
        let session = circle.session();
        let now_ms = self.clock.now_ms();
        let record = match session
            .location_to_send(&message, now_ms, self.mode.mode())
            .await
        {
            Ok(Some(record)) => record,
            Ok(None) => return LocationPublish::Ended,
            // What it would be sent past cannot be read: not sent.
            Err(_) => {
                let _ = session.end_location(&message).await;
                return LocationPublish::Superseded;
            }
        };
        if location_is_spent(record.expires_at_secs, now_ms) {
            let _ = session.end_location(&message).await;
            return LocationPublish::Expired;
        }
        if !record.may_be_sent {
            let _ = session.end_location(&message).await;
            return LocationPublish::Superseded;
        }
        let sent = self.fanout.publish_location(event, &record.relays).await;
        let _ = session.end_location(&message).await;
        LocationPublish::Sent(sent)
    }

    /// The circle's older records first, as MDK's host resumes a group's
    /// frozen fanouts before it produces newer work for it
    /// (`marmot-account/src/runtime.rs` 2397-2402).
    async fn older(&self, circle: &CircleManager, group_id: &GroupId) -> Pass {
        let mut pass = Pass::default();
        let due = drive_due(
            circle,
            self.fanout,
            self.clock,
            Some(group_id),
            self.deadline_ms,
            self.mode,
        )
        .await;
        self.absorb(circle, due, None, &mut pass).await;
        pass
    }

    /// Drives what a change staged and says where the change stands.
    async fn drive_change(
        &self,
        circle: &CircleManager,
        group_id: &GroupId,
        staged: StagedChange,
        welcomes_total: usize,
        mut pass: Pass,
    ) -> EvolutionOutcome {
        let StagedChange {
            commit,
            also,
            welcomes,
            unrecorded,
            already,
        } = staged;
        // What the circle had not been told before this change was driven
        // is an earlier change's, and stays untold.
        let untold_before = circle.session().peek_change_notes(group_id);
        // Read while the record is stored: another drive may end it before
        // this call's own drive reads it, and then only the commit's own row
        // says how it ended.
        let origin = match &commit {
            Some(id) => circle.session().fanout_origin(id).await,
            None => None,
        };
        #[cfg(any(test, feature = "test-utils"))]
        if let Some(id) = commit.as_ref() {
            let hook = {
                let mut hooks = BEFORE_CHANGE_DRIVE
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner);
                hooks
                    .iter()
                    .position(|(group, _)| group == id.group())
                    .map(|at| hooks.remove(at).1)
            };
            if let Some(hook) = hook {
                hook(id);
            }
        }
        let work: VecDeque<FanoutId> = commit.iter().cloned().chain(also).collect();
        let due = drive_rows(circle, self.fanout, self.clock, work, &self.wake(true)).await;
        let mut own = self.absorb(circle, due, commit.as_ref(), &mut pass).await;
        // Another drive held the change's row — the live plane's, say — and
        // a busy row asks for no wake: driven once more when that drive lets
        // go, within a row's budget, so the user's change is not left for
        // the next trigger.
        if let (Some(id), Some(FanoutStatus::Busy)) = (&commit, own.as_ref().map(|own| own.status))
        {
            if self.allows(ROW_BUDGET_MS) {
                let cap = self.clock.now_ms().saturating_add(ROW_BUDGET_MS);
                tokio::select! {
                    () = Driving::let_go(id.message()) => {}
                    () = self.clock.until(cap) => {}
                }
                let again = drive_rows(
                    circle,
                    self.fanout,
                    self.clock,
                    [id.clone()].into(),
                    &self.wake(true),
                )
                .await;
                own = self
                    .absorb(circle, again, Some(id), &mut pass)
                    .await
                    .or(own);
            }
        }
        // Another drive ended the record first: the commit's own row is
        // `Processed` once applied here (`cgka-engine/src/publish.rs`
        // 226-237), and `Failed` once retired rewound (`retire_commit`) — or,
        // in a chain no change call reaches in practice, set aside by MDK's
        // canonicalisation, which that drive notes as out of step. Anything
        // else proves neither.
        let ended = match (&origin, own.as_ref().map(|own| own.status)) {
            (Some(origin), Some(FanoutStatus::Gone)) => circle.session().commit_state(origin).await,
            _ => None,
        };
        // The row decides, never an error beside it: a commit applied
        // beside an error is applied, and one not yet resolved is awaiting
        // relays, not failed.
        let status = match (&commit, own.as_ref().map(|own| own.status)) {
            (None, _) if already => EvolutionStatus::AlreadySo,
            (None, _) if unrecorded => EvolutionStatus::Unrecorded,
            (None, _) => EvolutionStatus::Queued,
            (Some(_), Some(FanoutStatus::Confirmed)) => EvolutionStatus::Confirmed,
            (Some(_), Some(FanoutStatus::RolledBack)) => EvolutionStatus::RolledBack,
            (Some(_), Some(FanoutStatus::Stale)) => EvolutionStatus::Stale,
            (Some(_), _) => match ended {
                Some(MessageState::Processed) => EvolutionStatus::Confirmed,
                Some(MessageState::Failed) => EvolutionStatus::RolledBack,
                _ => EvolutionStatus::Unresolved,
            },
        };
        // This call is the one being told, here: what its own drive noted
        // need not wait to be read.
        let mut notes = Vec::new();
        for note in own.iter().flat_map(|own| &own.notes) {
            if !untold_before.contains(note) {
                circle.session().clear_change_note(group_id, *note);
            }
            if *note == ChangeNote::ReinviteOwed {
                notes.push(*note);
            }
        }
        EvolutionOutcome {
            status,
            // Its own Welcomes, by their rows: another drive may have
            // delivered one and ended its record before this call listed it.
            welcomes_sent: circle.session().welcomes_delivered(&welcomes).await,
            welcomes_total,
            notes,
            replayed: pass.replayed,
            retry_after_ms: pass.retry_after_ms,
            clock_rejected: pass.clock_rejected,
        }
    }

    /// Takes in what a round of drives handed back: every replayed batch
    /// goes through [`Self::dispose`] and every released Welcome is
    /// sent, whether or not a drive ended on an error. Returns what the
    /// drive of `own` left, when it was driven.
    async fn absorb(
        &self,
        circle: &CircleManager,
        due: DueOutcome,
        own: Option<&FanoutId>,
        pass: &mut Pass,
    ) -> Option<Own> {
        let DueOutcome {
            driven,
            retry_after_ms,
            error,
            erred,
        } = due;
        match erred {
            Some(erred) => pass.erred.extend(erred),
            None => pass.unplaced = true,
        }
        pass.retry_after_ms = match (pass.retry_after_ms, retry_after_ms) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        };
        let mut errored = error.is_some();
        let mut found = None;
        for (id, outcome) in driven {
            let DriveOutcome {
                status,
                replayed,
                notes,
                error,
                clock_rejected,
                ..
            } = outcome;
            errored |= error.is_some();
            pass.clock_rejected = pass.clock_rejected.or(clock_rejected);
            self.dispose(circle, replayed, &mut pass.replayed).await;
            if own == Some(&id) {
                found = Some(Own { status, notes });
            }
        }
        pass.welcomes_sent += self.deliver_welcomes(circle).await.len();
        if errored {
            pass.errored = true;
            log::warn!(
                "[Fanout] a drive ended on an error; what it had done stands and its records \
                 say where each commit is"
            );
        }
        found
    }

    /// The disposition of what was handed back WITHOUT a record
    /// (Security Rule 13): only a proposal no record could be written for,
    /// which is published once — in [`DriveMode::Full`] alone; in any other
    /// mode it is not sent, and the engine proposes it again at its circle's
    /// next epoch. Never a commit: every engine call behind these entries
    /// records what it stages in its hold, and a fold of such a batch leaves
    /// a commit it finds there staged and unsent
    /// (`CircleManager::dispose_publish_work`).
    async fn dispose(
        &self,
        circle: &CircleManager,
        handed_back: DecryptedIngest,
        results: &mut Vec<LocationMessageResult>,
    ) {
        let DecryptedIngest {
            results: replayed,
            proposals,
        } = handed_back;
        results.extend(replayed);
        for proposal in proposals {
            let relays = circle
                .relays_for_commit_event(&proposal)
                .unwrap_or_default();
            if !relays.is_empty() {
                // Nothing to confirm and nothing to roll back: an unacked
                // proposal is minted again by the next commit applied.
                let _ = self.send_unrecorded(&proposal, &relays).await;
            }
        }
    }

    /// Sends every Welcome still owed from its delivery record
    /// (`SessionManager::welcome_records`): the exact stored event, byte for
    /// byte, to each relay of its invitee's inbox that is due by MDK's own
    /// schedule for such a record — at once, then 30 seconds after an
    /// unanswered attempt, the wait doubling to an hour — until one of those
    /// relays acknowledges that event, which completes the Welcome in the
    /// engine and ends the record. Returns the circle of each Welcome
    /// delivered.
    ///
    /// Asked again immediately before each send whether the invite's commit
    /// is still this device's canonical one and the engine still owes the
    /// Welcome: a Welcome into an epoch the circle never reached must not go
    /// out (Security Rule 3). One whose commit lost for good ends as failed;
    /// one past its bound (a day) is no longer sent, and its circle's note
    /// that a Welcome is still owed stands. A send that was not begun — the
    /// mode narrowed, or the wake has no room — is no send, and its relay
    /// stays due.
    async fn deliver_welcomes(&self, circle: &CircleManager) -> Vec<GroupId> {
        let mut delivered = Vec::new();
        if self.mode.mode() != DriveMode::Full {
            return delivered;
        }
        for mut record in circle.session().welcome_records().await {
            if !self.allows(PUBLISHER_BUDGET_MS) {
                break;
            }
            if !still_owed(circle, &record).await {
                // Another drive — the live plane's, beside this call — may
                // have delivered it from the same record.
                if circle.session().welcome_delivered(&record).await {
                    delivered.extend(record.group().cloned());
                }
                continue;
            }
            if record.inert() {
                // Kept for the circle's note alone: gone once it was shown.
                let shown = record.group().is_some_and(|group_id| {
                    !circle
                        .session()
                        .peek_change_notes(group_id)
                        .contains(&ChangeNote::WelcomeOwed)
                });
                if shown {
                    circle
                        .session()
                        .end_welcome_record(&record, WelcomeEnd::Shown)
                        .await;
                }
                continue;
            }
            if record.acknowledged() {
                if circle
                    .session()
                    .complete_acknowledged_welcome(&record)
                    .await
                {
                    if let Some(group_id) = record.group() {
                        delivered.push(group_id.clone());
                    }
                }
                continue;
            }
            let now_ms = self.clock.now_ms();
            if record.expired(now_ms) {
                circle
                    .session()
                    .end_welcome_record(&record, WelcomeEnd::Expired)
                    .await;
                continue;
            }
            let Ok(event) = SessionManager::transport_message_to_event(record.welcome()) else {
                continue;
            };
            for (index, (relay, url)) in record.due(now_ms).into_iter().enumerate() {
                // Read again before each send after the first: a relay's
                // answer takes seconds, and the commit or the engine's
                // obligation can change under it.
                if index > 0 && !still_owed(circle, &record).await {
                    if circle.session().welcome_delivered(&record).await {
                        delivered.extend(record.group().cloned());
                    }
                    break;
                }
                let relays = [url];
                if !circle.record_welcome_relays(&relays) {
                    continue;
                }
                let Some(accepted) = self.send_unrecorded(&event, &relays).await else {
                    break;
                };
                // An answer that is not stored leaves the relay due again:
                // the same bytes go to it at its next turn, which a relay that
                // took them answers `duplicate:`.
                let answered = circle
                    .session()
                    .note_welcome_answer(&mut record, relay, accepted, self.clock.now_ms())
                    .await;
                if answered.unwrap_or(false) {
                    if let Some(group_id) = record.group() {
                        delivered.push(group_id.clone());
                    }
                    break;
                }
            }
        }
        delivered
    }
}

/// Whether `record`'s Welcome is still owed a send, read now; one that is
/// not is ended as its fate says.
async fn still_owed(circle: &CircleManager, record: &WelcomeRecord) -> bool {
    let end = match circle.session().welcome_fate(record).await {
        WelcomeFate::Owed => return true,
        WelcomeFate::Waiting => return false,
        WelcomeFate::Done => WelcomeEnd::Done,
        WelcomeFate::Lost => WelcomeEnd::Lost,
        WelcomeFate::Undeliverable => WelcomeEnd::Undeliverable,
    };
    circle.session().end_welcome_record(record, end).await;
    false
}

/// A fanout transport that sends nothing: it answers each relay as a test
/// scripted it and records what the driver asked of it.
#[cfg(any(test, feature = "test-utils"))]
pub mod scripted {
    use std::collections::{HashMap, VecDeque};
    use std::sync::{Mutex, PoisonError};

    use cgka_traits::{
        TransportEndpoint, TransportEndpointFailure, TransportEndpointFailureKind,
        TransportEndpointRejectionCategory,
    };
    use nostr::{EventId, RelayUrl};
    use tokio::sync::Semaphore;

    use crate::relay::{PublishResult, RelayResult};

    use super::{FanoutSend, FanoutTargetOutcome, Taken};
    use crate::nostr::mls::types::{FanoutEndpointFailure, TransportMessage};

    /// What a scripted relay does with one fanout publish, as the transport
    /// reports it.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum Answer {
        /// It said it holds the event.
        Accepted,
        /// It answered every attempt `OK false blocked:` — a proven refusal.
        Refused,
        /// It answered every attempt `OK false invalid:` — a proven refusal,
        /// and what a relay says of an event whose timestamp it will not
        /// take, as when the device's clock is wrong.
        Invalid,
        /// Haven refused before anything was handed over.
        NotExposed,
        /// It could not be reached; nothing was sent.
        Unreachable,
        /// It answered every attempt `OK false rate-limited:`.
        RateLimited,
        /// Nothing proved what it did: an `OK` that never came, or an answer
        /// that classified nothing.
        Silent,
        /// It could not be taken for the call: another send held it for the
        /// whole of the transport's wait, and it is not called.
        Busy,
    }

    /// One call the driver made.
    pub struct Call {
        /// The relay URL exactly as the driver passed it.
        pub target: String,
        /// The id of the event it was asked to send.
        pub event_id: EventId,
        /// The event's exact bytes.
        pub payload: Vec<u8>,
    }

    /// What the transport answers a location's send.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
    pub enum LocationAnswer {
        /// Every relay acknowledged it.
        #[default]
        Accepted,
        /// No relay acknowledged it.
        Unanswered,
        /// Every relay that answered blamed this device's clock.
        ClockRejected,
    }

    /// One location send the driver made.
    pub struct LocationCall {
        /// The relay URLs exactly as the driver passed them.
        pub targets: Vec<String>,
        /// The event it was asked to send.
        pub event: nostr::Event,
    }

    #[derive(Default)]
    struct Script {
        location_answer: LocationAnswer,
        location_calls: Vec<LocationCall>,
        locations_to_park: usize,
        answers: HashMap<String, VecDeque<Answer>>,
        calls: Vec<Call>,
        in_flight: HashMap<(EventId, String), usize>,
        most_at_once: usize,
        parking: bool,
    }

    /// See the module.
    pub struct ScriptedFanout {
        script: Mutex<Script>,
        parked: Semaphore,
        released: Semaphore,
    }

    impl Default for ScriptedFanout {
        fn default() -> Self {
            Self {
                script: Mutex::new(Script::default()),
                parked: Semaphore::new(0),
                released: Semaphore::new(0),
            }
        }
    }

    impl ScriptedFanout {
        fn script(&self) -> std::sync::MutexGuard<'_, Script> {
            self.script.lock().unwrap_or_else(PoisonError::into_inner)
        }

        /// Scripts `target`'s answers, one per call; the last one repeats. A
        /// relay never scripted answers [`Answer::Silent`].
        pub fn answer(&self, target: &str, answers: impl IntoIterator<Item = Answer>) {
            self.script()
                .answers
                .insert(target.to_owned(), answers.into_iter().collect());
        }

        /// Every call made so far, in order.
        pub fn calls(&self) -> Vec<Call> {
            std::mem::take(&mut self.script().calls)
        }

        /// Makes the NEXT location send wait, after it is recorded, until
        /// [`Self::release`] lets it answer. A commit's call is not held, and
        /// neither is a location send after that one: a send that should
        /// never have been made is then seen in the calls, not in a test
        /// that never ends.
        pub fn park_next_location(&self) {
            self.script().locations_to_park += 1;
        }

        /// How many location sends have been made and not yet taken by
        /// [`Self::location_calls`].
        pub fn location_call_count(&self) -> usize {
            self.script().location_calls.len()
        }

        /// Scripts what every later location send is answered.
        pub fn answer_locations(&self, answer: LocationAnswer) {
            self.script().location_answer = answer;
        }

        /// Every location send made so far, in order.
        pub fn location_calls(&self) -> Vec<LocationCall> {
            std::mem::take(&mut self.script().location_calls)
        }

        /// How many calls have been made and not yet taken by [`Self::calls`].
        pub fn call_count(&self) -> usize {
            self.script().calls.len()
        }

        /// The most calls that were ever under way at once for one event to
        /// one relay.
        pub fn most_at_once(&self) -> usize {
            self.script().most_at_once
        }

        /// Makes every later call wait, after it is recorded, until
        /// [`Self::release`] lets it answer.
        pub fn park(&self) {
            self.script().parking = true;
        }

        /// Stops parking and lets every waiting call answer.
        pub fn unpark(&self) {
            self.script().parking = false;
            self.released.add_permits(Semaphore::MAX_PERMITS / 2);
        }

        /// Waits until one more call is parked.
        pub async fn parked(&self) {
            self.parked
                .acquire()
                .await
                .unwrap_or_else(|_| unreachable!("the semaphore is never closed"))
                .forget();
        }

        /// Lets `calls` parked calls answer.
        pub fn release(&self, calls: usize) {
            self.released.add_permits(calls);
        }

        fn next_answer(&self, target: &str) -> Answer {
            let mut script = self.script();
            let answer = script.answers.get_mut(target).and_then(|queue| {
                if queue.len() > 1 {
                    queue.pop_front()
                } else {
                    queue.front().copied()
                }
            });
            drop(script);
            answer.unwrap_or(Answer::Silent)
        }
    }

    fn failed(
        target: &str,
        kind: TransportEndpointFailureKind,
        category: Option<TransportEndpointRejectionCategory>,
    ) -> FanoutTargetOutcome {
        FanoutTargetOutcome::Failed(FanoutEndpointFailure::new(TransportEndpointFailure {
            endpoint: TransportEndpoint(target.to_owned()),
            reason: "scripted".to_owned(),
            kind,
            rejection_category: category,
        }))
    }

    /// A clock that reads one instant, ms since the Unix epoch.
    pub struct FixedClock(pub u64);

    impl super::FanoutClock for FixedClock {
        fn now_ms(&self) -> u64 {
            self.0
        }
    }

    /// A transport, and a publisher of what has no record, on which every
    /// relay accepts: what each was handed is kept, in order. How a test
    /// lands a change.
    #[derive(Default)]
    pub struct Accepting {
        sent: Mutex<Vec<nostr::Event>>,
        handed: Mutex<Vec<nostr::Event>>,
    }

    impl Accepting {
        /// Each event sent under a record, once, in the order first sent.
        pub fn sent(&self) -> Vec<nostr::Event> {
            self.sent
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
        }

        /// What was published with no record — a Welcome, a proposal — in
        /// order.
        pub fn handed(&self) -> Vec<nostr::Event> {
            self.handed
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
        }
    }

    #[async_trait::async_trait]
    impl FanoutSend for Accepting {
        async fn take(&self, _target: &str) -> Option<Taken> {
            Some(Taken::nothing())
        }

        async fn publish(
            &self,
            _target: &str,
            message: &TransportMessage,
            _taken: Taken,
        ) -> FanoutTargetOutcome {
            if let Ok(event) = <nostr::Event as nostr::JsonUtil>::from_json(&message.payload) {
                let mut sent = self.sent.lock().unwrap_or_else(PoisonError::into_inner);
                if !sent.iter().any(|kept| kept.id == event.id) {
                    sent.push(event);
                }
            }
            FanoutTargetOutcome::Accepted
        }

        async fn publish_location(
            &self,
            event: &nostr::Event,
            targets: &[String],
        ) -> RelayResult<PublishResult> {
            Ok(PublishResult {
                event_id: event.id,
                accepted_by: targets.to_vec(),
                rejected_by: Vec::new(),
                failed: Vec::new(),
            })
        }
    }

    impl crate::relay::fanout::UnrecordedPublisher for Accepting {
        fn publish_unrecorded<'a>(
            &'a self,
            event: &'a nostr::Event,
            _relays: &'a [String],
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send + 'a>> {
            self.handed
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(event.clone());
            Box::pin(async { true })
        }
    }

    /// A transport, and a publisher of what has no record, on which every
    /// relay refuses — `OK false blocked:`, a proven refusal — and nothing is
    /// kept.
    pub struct Refusing;

    #[async_trait::async_trait]
    impl FanoutSend for Refusing {
        async fn take(&self, _target: &str) -> Option<Taken> {
            Some(Taken::nothing())
        }

        async fn publish(
            &self,
            target: &str,
            _message: &TransportMessage,
            _taken: Taken,
        ) -> FanoutTargetOutcome {
            failed(
                target,
                TransportEndpointFailureKind::TerminalRejected,
                Some(TransportEndpointRejectionCategory::Blocked),
            )
        }

        async fn publish_location(
            &self,
            _event: &nostr::Event,
            _targets: &[String],
        ) -> RelayResult<PublishResult> {
            Err(crate::relay::RelayError::AllRelaysFailed)
        }
    }

    impl crate::relay::fanout::UnrecordedPublisher for Refusing {
        fn publish_unrecorded<'a>(
            &'a self,
            _event: &'a nostr::Event,
            _relays: &'a [String],
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send + 'a>> {
            Box::pin(async { false })
        }
    }

    /// A transport that takes no relay.
    ///
    /// The driver begins no attempt, every record stays as it was, and a
    /// location reaches nobody: what a test seals or reads through when it
    /// wants a plane's answer and no relay call.
    pub struct Inert;

    #[async_trait::async_trait]
    impl FanoutSend for Inert {
        async fn take(&self, _target: &str) -> Option<Taken> {
            None
        }

        async fn publish(
            &self,
            target: &str,
            _message: &TransportMessage,
            _taken: Taken,
        ) -> FanoutTargetOutcome {
            failed(target, TransportEndpointFailureKind::NotExposed, None)
        }

        async fn publish_location(
            &self,
            _event: &nostr::Event,
            _targets: &[String],
        ) -> RelayResult<PublishResult> {
            Err(crate::relay::RelayError::AllRelaysFailed)
        }
    }

    impl crate::relay::fanout::UnrecordedPublisher for Inert {
        fn publish_unrecorded<'a>(
            &'a self,
            _event: &'a nostr::Event,
            _relays: &'a [String],
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send + 'a>> {
            Box::pin(async { false })
        }
    }

    #[async_trait::async_trait]
    impl FanoutSend for ScriptedFanout {
        async fn take(&self, target: &str) -> Option<Taken> {
            let mut script = self.script();
            let Some(queue) = script.answers.get_mut(target) else {
                return Some(Taken::nothing());
            };
            if queue.front() != Some(&Answer::Busy) {
                return Some(Taken::nothing());
            }
            if queue.len() > 1 {
                queue.pop_front();
            }
            None
        }

        async fn publish(
            &self,
            target: &str,
            message: &TransportMessage,
            _taken: Taken,
        ) -> FanoutTargetOutcome {
            use TransportEndpointFailureKind as Class;
            let event_id =
                EventId::from_slice(message.id.as_slice()).unwrap_or_else(|_| EventId::all_zeros());
            let relay =
                RelayUrl::parse(target).map_or_else(|_| target.to_owned(), |u| u.to_string());
            let key = (event_id, relay);
            let parking = {
                let mut script = self.script();
                script.calls.push(Call {
                    target: target.to_owned(),
                    event_id,
                    payload: message.payload.clone(),
                });
                let under_way = {
                    let count = script.in_flight.entry(key.clone()).or_insert(0);
                    *count += 1;
                    *count
                };
                script.most_at_once = script.most_at_once.max(under_way);
                script.parking
            };
            if parking {
                self.parked.add_permits(1);
                if let Ok(permit) = self.released.acquire().await {
                    permit.forget();
                }
            }
            if let Some(count) = self.script().in_flight.get_mut(&key) {
                *count -= 1;
            }
            match self.next_answer(target) {
                Answer::Accepted => FanoutTargetOutcome::Accepted,
                Answer::Refused => failed(
                    target,
                    Class::TerminalRejected,
                    Some(TransportEndpointRejectionCategory::Blocked),
                ),
                Answer::Invalid => failed(
                    target,
                    Class::TerminalRejected,
                    Some(TransportEndpointRejectionCategory::Invalid),
                ),
                Answer::NotExposed => failed(target, Class::NotExposed, None),
                Answer::Unreachable => failed(target, Class::RetryableUnavailable, None),
                Answer::RateLimited => failed(
                    target,
                    Class::RetryableUnavailable,
                    Some(TransportEndpointRejectionCategory::RateLimited),
                ),
                // A relay that could not be taken is never called.
                Answer::Silent | Answer::Busy => failed(target, Class::PossiblyExposed, None),
            }
        }

        async fn publish_location(
            &self,
            event: &nostr::Event,
            targets: &[String],
        ) -> RelayResult<PublishResult> {
            let (parking, answer) = {
                let mut script = self.script();
                script.location_calls.push(LocationCall {
                    targets: targets.to_vec(),
                    event: event.clone(),
                });
                let parks = script.locations_to_park > 0;
                script.locations_to_park = script.locations_to_park.saturating_sub(1);
                (script.parking || parks, script.location_answer)
            };
            if parking {
                self.parked.add_permits(1);
                if let Ok(permit) = self.released.acquire().await {
                    permit.forget();
                }
            }
            match answer {
                LocationAnswer::Accepted => Ok(PublishResult {
                    event_id: event.id,
                    accepted_by: targets.to_vec(),
                    rejected_by: Vec::new(),
                    failed: Vec::new(),
                }),
                LocationAnswer::Unanswered => Err(crate::relay::RelayError::AllRelaysFailed),
                LocationAnswer::ClockRejected => {
                    Err(crate::relay::RelayError::DeviceClockRejected {
                        complaint: crate::relay::DeviceClockComplaint::Ahead,
                    })
                }
            }
        }
    }
}

/// A fanout transport behind an address map.
///
/// For a rig whose devices each reach a relay at an address of their own
/// while their circles store the relay's canonical one: each frozen target is
/// sent to the address `route` gives for it, through `inner` — the product's
/// transport, so the pool, the classifier and the per-relay gate are
/// production's. The driver records every answer under the target's frozen
/// spelling whatever address answered.
#[cfg(any(test, feature = "test-utils"))]
pub struct RelayMappedFanout<T> {
    inner: T,
    route: Box<dyn Fn(&str) -> String + Send + Sync>,
}

#[cfg(any(test, feature = "test-utils"))]
impl<T> RelayMappedFanout<T> {
    /// `inner`, with every target sent to `route(target)`.
    pub fn new(inner: T, route: impl Fn(&str) -> String + Send + Sync + 'static) -> Self {
        Self {
            inner,
            route: Box::new(route),
        }
    }
}

#[cfg(any(test, feature = "test-utils"))]
#[async_trait::async_trait]
impl<T: FanoutSend> FanoutSend for RelayMappedFanout<T> {
    async fn take(&self, target: &str) -> Option<Taken> {
        self.inner.take(&(self.route)(target)).await
    }

    async fn publish(
        &self,
        target: &str,
        message: &TransportMessage,
        taken: Taken,
    ) -> FanoutTargetOutcome {
        self.inner
            .publish(&(self.route)(target), message, taken)
            .await
    }

    async fn publish_location(
        &self,
        event: &nostr::Event,
        targets: &[String],
    ) -> RelayResult<PublishResult> {
        let routed: Vec<String> = targets.iter().map(|target| (self.route)(target)).collect();
        self.inner.publish_location(event, &routed).await
    }
}

/// Forgets that `id` has a stored fanout row, as a new process has before its
/// session opens.
#[cfg(any(test, feature = "test-utils"))]
pub fn disown_for_test(id: &EventId) {
    OWNED
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .remove(id.as_bytes().as_slice());
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use cgka_traits::engine_state::PendingStateRef;
    use cgka_traits::transport::TransportEnvelope;
    use cgka_traits::{
        GroupId, MemberId, TransportEndpointReceipt, TransportPublishFailure,
        TransportPublishRequest, TransportPublishTarget,
    };
    use tokio::sync::broadcast;
    use transport_nostr_adapter::{NostrPublishOutcome, NostrSubscription};

    use super::*;

    /// The recovery read's order, exhaustively over its facts: the cause
    /// whose remedy comes first wins, and nothing holds a healthy circle.
    #[test]
    fn circle_recovery_names_the_worst_cause_first() {
        use super::{worst_recovery, RecoveryCause as C, RecoveryFacts, SendHeld as H};
        let helds = [
            H::AwaitingRelays,
            H::Acknowledged,
            H::StagedWithoutRecord,
            H::DepartureDue,
            H::AwaitsForeground,
            H::RemovalUnmade,
            H::Leaving,
            H::Disbanded,
            H::RoutingCollision,
            H::StoredInput,
            H::Nothing,
        ];
        // The order the user is told in, worst first.
        let order = [
            C::Disbanded,
            C::Unrecoverable,
            C::Quarantined,
            C::RoutingCollision,
            C::Leaving,
            C::Stalled,
            C::RemovalUnmade,
            C::DepartureDue,
            C::AwaitsForeground,
            C::AwaitingRelays,
            C::Acknowledged,
            C::StagedWithoutRecord,
            C::StoredInput,
        ];
        let rank = |cause: C| order.iter().position(|c| *c == cause).expect("ranked");
        let of_held = |held: H| match held {
            H::AwaitingRelays => Some(C::AwaitingRelays),
            H::Acknowledged => Some(C::Acknowledged),
            H::StagedWithoutRecord => Some(C::StagedWithoutRecord),
            H::DepartureDue => Some(C::DepartureDue),
            H::AwaitsForeground => Some(C::AwaitsForeground),
            H::RemovalUnmade => Some(C::RemovalUnmade),
            H::Leaving => Some(C::Leaving),
            H::Disbanded => Some(C::Disbanded),
            H::RoutingCollision => Some(C::RoutingCollision),
            H::StoredInput => Some(C::StoredInput),
            H::Nothing => None,
        };
        for bits in 0..16_u8 {
            for held in helds {
                let facts = RecoveryFacts {
                    disbanded: bits & 1 != 0,
                    unrecoverable: bits & 2 != 0,
                    quarantined: bits & 4 != 0,
                    stalled: bits & 8 != 0,
                    held,
                };
                let present: Vec<C> = [
                    facts.disbanded.then_some(C::Disbanded),
                    facts.unrecoverable.then_some(C::Unrecoverable),
                    facts.quarantined.then_some(C::Quarantined),
                    facts.stalled.then_some(C::Stalled),
                    of_held(held),
                ]
                .into_iter()
                .flatten()
                .collect();
                let worst = present.iter().copied().min_by_key(|cause| rank(*cause));
                assert_eq!(
                    worst_recovery(facts),
                    worst,
                    "facts {bits:04b} with {held:?}"
                );
            }
        }
        assert_eq!(
            worst_recovery(RecoveryFacts {
                disbanded: false,
                unrecoverable: false,
                quarantined: false,
                stalled: false,
                held: H::Nothing,
            }),
            None,
            "nothing holds a healthy circle"
        );
    }
    use crate::nostr::mls::SessionManager;
    use crate::nostr::KIND_GROUP_MESSAGE;
    use crate::relay::scripted_relay::{ScriptedRelay, Verdict};
    use crate::relay::RelayManager;
    use crate::test_log::capture_log_lines;

    type Answer = Result<NostrPublishOutcome, TransportAdapterError>;
    type Answering = Box<dyn Fn() -> Answer + Send + Sync>;

    /// A relay client that answers every publish as scripted and records what
    /// it was asked for.
    struct Scripted {
        answer: Answering,
        asked: Mutex<Vec<(Vec<TransportEndpoint>, usize)>>,
    }

    impl Scripted {
        fn answering(answer: impl Fn() -> Answer + Send + Sync + 'static) -> Self {
            Self {
                answer: Box::new(answer),
                asked: Mutex::new(Vec::new()),
            }
        }
    }

    #[async_trait::async_trait]
    impl NostrRelayClient for Scripted {
        async fn subscribe(&self, _: NostrSubscription) -> Result<(), TransportAdapterError> {
            Err(TransportAdapterError::Closed)
        }

        async fn unsubscribe(&self, _: NostrSubscription) -> Result<(), TransportAdapterError> {
            Err(TransportAdapterError::Closed)
        }

        async fn unsubscribe_account(&self, _: &MemberId) -> Result<(), TransportAdapterError> {
            Err(TransportAdapterError::Closed)
        }

        async fn publish_event(
            &self,
            endpoints: &[TransportEndpoint],
            _event: &NostrTransportEvent,
            required_acks: usize,
        ) -> Answer {
            self.asked
                .lock()
                .expect("asked lock")
                .push((endpoints.to_vec(), required_acks));
            (self.answer)()
        }
    }

    /// A signed kind-445 event in the shape the engine's are, as the transport
    /// message a fanout row freezes.
    /// A clock reading from before any event here was signed, which reads
    /// each as just signed.
    const BEFORE_EVERY_SIGNING: u64 = 0;

    fn fanout_message() -> TransportMessage {
        let event = nostr::EventBuilder::new(nostr::Kind::Custom(KIND_GROUP_MESSAGE), "ciphertext")
            .tag(nostr::Tag::parse(["h", &"ab".repeat(32)]).expect("an h tag"))
            .sign_with_keys(&nostr::Keys::generate())
            .expect("sign");
        SessionManager::event_to_transport_message(&event).expect("a kind-445 event converts")
    }

    fn id_of(message: &TransportMessage) -> EventId {
        EventId::from_slice(message.id.as_slice()).expect("a 32-byte event id")
    }

    fn endpoint(url: &str) -> TransportEndpoint {
        TransportEndpoint(url.to_string())
    }

    const RELAY: &str = "wss://relay.example.com";

    fn failure_of(
        url: &str,
        kind: TransportEndpointFailureKind,
        category: Option<TransportEndpointRejectionCategory>,
    ) -> TransportEndpointFailure {
        TransportEndpointFailure {
            endpoint: endpoint(url),
            reason: "relay rejected event".to_string(),
            kind,
            rejection_category: category,
        }
    }

    fn failure(url: &str, kind: TransportEndpointFailureKind) -> TransportEndpointFailure {
        failure_of(url, kind, Some(TransportEndpointRejectionCategory::Blocked))
    }

    /// A relay client whose every publish ends in `failure` for [`RELAY`].
    fn failing(
        kind: TransportEndpointFailureKind,
        category: Option<TransportEndpointRejectionCategory>,
    ) -> Scripted {
        Scripted::answering(move || {
            Ok(NostrPublishOutcome {
                message_id: None,
                accepted: Vec::new(),
                failed: vec![failure_of(RELAY, kind, category)],
            })
        })
    }

    fn receipt(url: &str) -> TransportEndpointReceipt {
        TransportEndpointReceipt {
            endpoint: endpoint(url),
            accepted_at: None,
        }
    }

    /// A relay's notification stream on which it has said `oks`, each an `OK`
    /// for the event named beside it. The sender is returned because a stream
    /// whose relay is gone proves nothing.
    fn heard(
        oks: &[(EventId, bool)],
    ) -> (
        broadcast::Sender<RelayNotification>,
        Receiver<RelayNotification>,
    ) {
        let (said, heard) = broadcast::channel(64);
        for (id, status) in oks {
            said.send(RelayNotification::Message {
                message: RelayMessage::ok(*id, *status, ""),
            })
            .unwrap_or_else(|_| panic!("the stream has its listener"));
        }
        (said, heard)
    }

    fn classified(
        outcome: &FanoutTargetOutcome,
    ) -> Option<(
        TransportEndpointFailureKind,
        Option<TransportEndpointRejectionCategory>,
    )> {
        match outcome {
            FanoutTargetOutcome::Accepted => None,
            FanoutTargetOutcome::Failed(failure) => {
                Some((failure.kind(), failure.rejection_category()))
            }
        }
    }

    fn is_unclassified(outcome: &FanoutTargetOutcome) -> bool {
        classified(outcome) == Some((TransportEndpointFailureKind::PossiblyExposed, None))
    }

    #[tokio::test]
    async fn one_relay_and_one_acknowledgement_are_asked_for_per_call() {
        let client = Scripted::answering(|| Ok(NostrPublishOutcome::default()));
        let target = endpoint(RELAY);
        let _ = publish_to_target(
            &client,
            &target,
            &fanout_message(),
            None,
            BEFORE_EVERY_SIGNING,
        )
        .await;

        let asked = client.asked.lock().expect("asked lock").clone();
        assert!(
            asked == [(vec![target], 1)],
            "a fanout publish names its one target and requires its one ack: a \
             call that names more and misses the quorum loses the receipts it got",
        );
    }

    /// MDK's client answers with the relay URL as it parsed it. Another client
    /// may have written the routing entry with a different spelling of the same
    /// relay, and the answer still has to be read as that target's.
    #[tokio::test]
    async fn mdks_answer_is_read_under_the_callers_own_spelling_of_the_relay() {
        let target = endpoint("wss://Relay.Example.com:443");
        let message = fanout_message();

        let accepting = Scripted::answering(|| {
            Ok(NostrPublishOutcome {
                message_id: None,
                accepted: vec![receipt(RELAY)],
                failed: Vec::new(),
            })
        });
        assert!(
            matches!(
                publish_to_target(&accepting, &target, &message, None, BEFORE_EVERY_SIGNING).await,
                FanoutTargetOutcome::Accepted
            ),
            "an acceptance for the same relay under MDK's spelling was not \
             taken: that commit would stay pending for ever",
        );

        let refusing = Scripted::answering(|| {
            Err(TransportAdapterError::PublishEndpoints(
                TransportPublishFailure::with_endpoint_failures(
                    "relay rejected event (blocked)",
                    vec![failure(
                        RELAY,
                        TransportEndpointFailureKind::TerminalRejected,
                    )],
                ),
            ))
        });
        let id = id_of(&message);
        let (_said, refusals) = heard(&[(id, false); MDK_ATTEMPTS_PER_CALL]);
        let refused = publish_to_target(
            &refusing,
            &target,
            &message,
            Some(refusals),
            BEFORE_EVERY_SIGNING,
        )
        .await;
        assert!(
            classified(&refused)
                == Some((
                    TransportEndpointFailureKind::TerminalRejected,
                    Some(TransportEndpointRejectionCategory::Blocked)
                )),
            "MDK's classification did not come through as it was given",
        );
    }

    /// A verdict about some other relay, or about none, proves nothing about
    /// this one.
    #[tokio::test]
    async fn an_answer_that_classifies_some_other_relay_is_possibly_exposed() {
        const OTHER: &str = "wss://other.example.com";
        let answers: [(&str, Answering); 4] = [
            (
                "an acceptance by another relay",
                Box::new(|| {
                    Ok(NostrPublishOutcome {
                        message_id: None,
                        accepted: vec![receipt(OTHER)],
                        failed: Vec::new(),
                    })
                }),
            ),
            (
                "another relay's terminal rejection",
                Box::new(|| {
                    Ok(NostrPublishOutcome {
                        message_id: None,
                        accepted: Vec::new(),
                        failed: vec![failure(
                            OTHER,
                            TransportEndpointFailureKind::TerminalRejected,
                        )],
                    })
                }),
            ),
            (
                "an outcome naming nobody",
                Box::new(|| Ok(NostrPublishOutcome::default())),
            ),
            (
                "an error carrying another relay's rejection",
                Box::new(|| {
                    Err(TransportAdapterError::PublishEndpoints(
                        TransportPublishFailure::with_endpoint_failures(
                            "relay rejected event (blocked)",
                            vec![failure(OTHER, TransportEndpointFailureKind::NotExposed)],
                        ),
                    ))
                }),
            ),
        ];
        for (shape, answer) in answers {
            let client = Scripted::answering(answer);
            let outcome = publish_to_target(
                &client,
                &endpoint(RELAY),
                &fanout_message(),
                None,
                BEFORE_EVERY_SIGNING,
            )
            .await;
            assert!(
                is_unclassified(&outcome),
                "{shape} was read as a verdict on a relay it does not name",
            );
        }
    }

    #[tokio::test]
    async fn a_whole_call_error_naming_no_relay_is_possibly_exposed_whatever_it_says() {
        let errors: [fn() -> TransportAdapterError; 6] = [
            || TransportAdapterError::Publish("invalid signed event".to_string()),
            || TransportAdapterError::Subscription("publish: invalid relay endpoint".to_string()),
            || TransportAdapterError::Closed,
            || TransportAdapterError::Backend("backend".to_string()),
            || TransportAdapterError::Other("other".to_string()),
            || {
                TransportAdapterError::PublishEndpoints(
                    TransportPublishFailure::with_endpoint_failures("nothing listed", Vec::new()),
                )
            },
        ];
        for error in errors {
            let client = Scripted::answering(move || Err(error()));
            let outcome = publish_to_target(
                &client,
                &endpoint(RELAY),
                &fanout_message(),
                None,
                BEFORE_EVERY_SIGNING,
            )
            .await;
            assert!(
                is_unclassified(&outcome),
                "an error that names no relay was read as a relay's refusal",
            );
        }
    }

    /// `message` with one field of its event replaced, or removed.
    fn with_field(
        message: &TransportMessage,
        name: &str,
        value: Option<serde_json::Value>,
    ) -> TransportMessage {
        let mut event: serde_json::Value =
            serde_json::from_slice(&message.payload).expect("event json");
        let fields = event.as_object_mut().expect("an event object");
        match value {
            Some(value) => fields.insert(name.to_string(), value),
            None => fields.remove(name),
        };
        let mut changed = message.clone();
        changed.payload = serde_json::to_vec(&event).expect("event json");
        changed
    }

    /// The frozen bytes go to MDK's client as the signed event they are, or
    /// not at all: MDK's client signs an unsigned event with whatever signer
    /// the client it holds has. What Haven refuses here never left the device.
    #[tokio::test]
    async fn only_a_verifiable_signed_event_is_handed_to_the_relay_client() {
        let message = fanout_message();
        let borrowed: serde_json::Value =
            serde_json::from_slice(&fanout_message().payload).expect("event json");
        let mut not_json = message.clone();
        not_json.payload = b"not an event".to_vec();
        let refused = [
            ("bytes that are not an event", not_json),
            ("an unsigned event", with_field(&message, "sig", None)),
            (
                "an event under another event's signature",
                with_field(&message, "sig", Some(borrowed["sig"].clone())),
            ),
            (
                "an event whose content was changed under its id",
                with_field(&message, "content", Some("other".into())),
            ),
        ];
        for (shape, payload) in refused {
            let client = Scripted::answering(|| Ok(NostrPublishOutcome::default()));
            let outcome = publish_to_target(
                &client,
                &endpoint(RELAY),
                &payload,
                None,
                BEFORE_EVERY_SIGNING,
            )
            .await;
            assert!(
                classified(&outcome) == Some((TransportEndpointFailureKind::NotExposed, None)),
                "{shape}: what Haven refused to hand over was not returned as not exposed",
            );
            assert!(
                client.asked.lock().expect("asked lock").is_empty(),
                "{shape} went to the relay client",
            );
        }

        let client = Scripted::answering(|| Ok(NostrPublishOutcome::default()));
        let _ = publish_to_target(
            &client,
            &endpoint(RELAY),
            &message,
            None,
            BEFORE_EVERY_SIGNING,
        )
        .await;
        assert!(
            client.asked.lock().expect("asked lock").len() == 1,
            "the signed event itself was refused: the check refuses everything",
        );
    }

    /// Security Rule 13's "proven non-acceptance", in the one place it is
    /// decided. MDK's client makes three attempts in a call and reports the
    /// last; a relay's refusal is returned only when the relay answered every
    /// one of them `OK false`.
    #[tokio::test]
    async fn a_relay_spoken_refusal_is_returned_only_when_every_attempt_was_answered_ok_false() {
        use TransportEndpointFailureKind::{
            PossiblyExposed, RetryableUnavailable, TerminalRejected,
        };
        use TransportEndpointRejectionCategory::{Blocked, RateLimited};
        let message = fanout_message();
        let (id, other) = (id_of(&message), id_of(&fanout_message()));
        let spoken = [
            (TerminalRejected, Blocked),
            (RetryableUnavailable, RateLimited),
        ];

        for (kind, category) in spoken {
            let client = failing(kind, Some(category));
            let run = |oks: Vec<(EventId, bool)>| {
                let (client, message) = (&client, &message);
                async move {
                    let (_said, stream) = heard(&oks);
                    classified(
                        &publish_to_target(
                            client,
                            &endpoint(RELAY),
                            message,
                            Some(stream),
                            BEFORE_EVERY_SIGNING,
                        )
                        .await,
                    )
                }
            };

            assert!(
                run(vec![(id, false); 3]).await == Some((kind, Some(category))),
                "three attempts, three refusals: the relay's answer was not returned",
            );
            let unproven = [
                ("one attempt went unanswered", vec![(id, false); 2]),
                ("no attempt was answered", Vec::new()),
                ("more answers than attempts", vec![(id, false); 4]),
                (
                    "one of three answers names another event",
                    vec![(id, false), (other, false), (id, false)],
                ),
            ];
            for (shape, oks) in unproven {
                assert!(
                    run(oks).await == Some((PossiblyExposed, Some(category))),
                    "{shape}, and the relay's refusal was still returned as proven",
                );
            }

            // No stream at all: the relay was not in the pool.
            let unheard = publish_to_target(
                &client,
                &endpoint(RELAY),
                &message,
                None,
                BEFORE_EVERY_SIGNING,
            )
            .await;
            assert!(
                classified(&unheard) == Some((PossiblyExposed, Some(category))),
                "a refusal nobody listened for was returned as proven",
            );

            // A stream that dropped a frame: three refusals are still there to
            // count, and what was dropped may be what answered — or did not
            // answer — an attempt. (The channel holds four; five were said.)
            let (said, lagged) = broadcast::channel(4);
            for named in [other, other, id, id, id] {
                said.send(RelayNotification::Message {
                    message: RelayMessage::ok(named, false, ""),
                })
                .unwrap_or_else(|_| panic!("the stream has its listener"));
            }
            let outcome = publish_to_target(
                &client,
                &endpoint(RELAY),
                &message,
                Some(lagged),
                BEFORE_EVERY_SIGNING,
            )
            .await;
            assert!(
                classified(&outcome) == Some((PossiblyExposed, Some(category))),
                "a count taken from a stream that dropped frames was believed",
            );

            // A stream whose relay is gone.
            let (said, closed) = heard(&[(id, false); 3]);
            drop(said);
            let outcome = publish_to_target(
                &client,
                &endpoint(RELAY),
                &message,
                Some(closed),
                BEFORE_EVERY_SIGNING,
            )
            .await;
            assert!(
                classified(&outcome) == Some((PossiblyExposed, Some(category))),
                "a count taken from a relay that is no longer there was believed",
            );
        }
    }

    // ── The driver's rule ────────────────────────────────────────────────────

    /// [`staged_fanout`] for another commit.
    fn other_fanout(targets: &[&str]) -> OutboundFanout {
        let mut message = fanout_message();
        message.id = MessageId::new(vec![9; 32]);
        fanout_of(message, targets)
    }

    /// A commit's fanout frozen for `targets`, nothing attempted.
    fn staged_fanout(targets: &[&str]) -> OutboundFanout {
        fanout_of(fanout_message(), targets)
    }

    fn fanout_of(message: TransportMessage, targets: &[&str]) -> OutboundFanout {
        let group = GroupId::new(vec![7; 16]);
        let TransportEnvelope::GroupMessage { transport_group_id } = message.envelope.clone()
        else {
            panic!("a kind-445 event is a group message");
        };
        OutboundFanout::stage(
            TransportPublishRequest {
                account_id: MemberId::new(vec![1; 32]),
                message,
                target: TransportPublishTarget::Group {
                    group_id: group.clone(),
                    transport_group_id,
                    endpoints: targets.iter().map(|target| endpoint(target)).collect(),
                },
                required_acks: 1,
            },
            Some(PendingStateRef::new(1)),
            Some(group),
            0,
        )
        .expect("a commit's fanout stages")
    }

    /// Records `answers`, one per target, as the driver does.
    fn answered(
        targets: &[&str],
        answers: &[Option<TransportEndpointFailureKind>],
    ) -> OutboundFanout {
        let mut fanout = staged_fanout(targets);
        for (index, answer) in answers.iter().enumerate() {
            fanout.mark_attempt_started(index).expect("attempt");
            let attempt = Attempt {
                spellings: vec![index],
            };
            let answer = answer.map_or(FanoutTargetOutcome::Accepted, |kind| {
                failed_as(
                    &endpoint(targets[index]),
                    failure_of(targets[index], kind, None),
                )
            });
            record(&mut fanout, &attempt, answer).expect("the answer is recorded");
        }
        fanout
    }

    const SECOND: &str = "wss://second.example.com";

    /// A record with `id`'s message, frozen for `RELAY`, whose one target was
    /// called at each of `at` and never answered.
    fn unanswered(id: u8, at: &[u64]) -> OutboundFanout {
        let mut message = fanout_message();
        message.id = MessageId::new(vec![id; 32]);
        let mut fanout = fanout_of(message, &[RELAY]);
        for began in at {
            fanout.mark_attempt_started_at(0, *began).expect("attempt");
            let attempt = Attempt { spellings: vec![0] };
            let silent = failed_as(
                &endpoint(RELAY),
                failure_of(RELAY, TransportEndpointFailureKind::PossiblyExposed, None),
            );
            record(&mut fanout, &attempt, silent).expect("recorded");
        }
        fanout
    }

    /// A stored attempt that lies ahead of a clock stepped back is read by
    /// nobody. The record it is on is due once and stamped again; a record
    /// that is never stamped again — one kept after it ended — must not make
    /// every other record owing that relay due on every drive for the size of
    /// the step. A drive a minute for three hours calls the relay exactly as
    /// often with such a record beside it as without.
    #[test]
    fn a_stamp_ahead_of_a_stepped_back_clock_makes_no_other_record_due() {
        const NOW: u64 = 100 * RETRY_MAX_MS;
        let relay = relay_url(RELAY);
        // Stamped three hours ahead of the clock as it now reads.
        let kept = applied(unanswered(8, &[NOW + 3 * RETRY_MAX_MS]));
        let waiting = unanswered(9, &[NOW - 10_000]);
        assert_eq!(
            relay_due(&[kept.clone(), waiting.clone()], &waiting, &relay, NOW),
            relay_due(std::slice::from_ref(&waiting), &waiting, &relay, NOW),
            "a stamp ahead of the clock decided when another record's relay is due",
        );

        let calls_in_three_hours = |beside: Option<&OutboundFanout>| {
            let mut waiting = waiting.clone();
            let mut calls = 0;
            for minute in 0..180 {
                let now_ms = NOW + minute * 60_000;
                let all: Vec<OutboundFanout> = beside
                    .into_iter()
                    .cloned()
                    .chain([waiting.clone()])
                    .collect();
                if due_attempts(&all, &waiting, now_ms).0.is_empty() {
                    continue;
                }
                calls += 1;
                waiting.mark_attempt_started_at(0, now_ms).expect("attempt");
                let attempt = Attempt { spellings: vec![0] };
                let silent = failed_as(
                    &endpoint(RELAY),
                    failure_of(RELAY, TransportEndpointFailureKind::PossiblyExposed, None),
                );
                record(&mut waiting, &attempt, silent).expect("recorded");
            }
            calls
        };
        let alone = calls_in_three_hours(None);
        assert!(alone <= 9, "premise: the schedule itself, {alone} calls");
        assert_eq!(calls_in_three_hours(Some(&kept)), alone);
    }

    /// What failed at a relay before it last took an event is over. A record
    /// kept long after it ended, with many unanswered calls to a relay that
    /// has since acknowledged another commit, does not put that relay at the
    /// longest wait when one new commit then fails there once.
    #[test]
    fn what_failed_before_a_relays_last_acknowledgement_does_not_lengthen_its_wait() {
        let relay = relay_url(RELAY);
        let stamps: Vec<u64> = (1..=11).map(|call| call * 10).collect();
        let kept = applied(unanswered(7, &stamps));
        let mut taken = unanswered(8, &[]);
        taken.mark_attempt_started_at(0, 2_000).expect("attempt");
        let attempt = Attempt { spellings: vec![0] };
        record(&mut taken, &attempt, FanoutTargetOutcome::Accepted).expect("recorded");
        let fresh = unanswered(9, &[3_000]);

        assert_eq!(
            relay_due(
                &[kept.clone(), taken.clone(), fresh.clone()],
                &fresh,
                &relay,
                3_000
            ),
            RelayDue::At(3_000 + AMBIGUOUS_RETRY_BASE_MS),
            "calls that failed before the relay's last acknowledgement were counted \
             against it",
        );
        // And the kept record's own relay is not waited for at all.
        assert_eq!(
            relay_due(&[kept.clone(), taken], &kept, &relay, 3_000),
            RelayDue::Now
        );
        // Premise: without the acknowledgement between them, they do count.
        let RelayDue::At(at) = relay_due(&[kept, fresh.clone()], &fresh, &relay, 3_000) else {
            panic!("an unanswered relay is waited for");
        };
        assert!(at > 3_000 + AMBIGUOUS_RETRY_BASE_MS);
    }

    /// Security Rule 13, over every pair of answers two relays can give.
    #[test]
    fn a_commit_is_confirmed_on_an_acknowledgement_and_rolled_back_only_on_proof() {
        use TransportEndpointFailureKind::{
            NotExposed, PossiblyExposed, RetryableUnavailable, TerminalRejected,
        };
        let answers = [
            None,
            Some(TerminalRejected),
            Some(NotExposed),
            Some(PossiblyExposed),
            Some(RetryableUnavailable),
        ];
        let proves_refusal = |answer: Option<TransportEndpointFailureKind>| {
            matches!(answer, Some(TerminalRejected | NotExposed))
        };
        for one in answers {
            for two in answers {
                let expected = if one.is_none() || two.is_none() {
                    Decision::Confirm
                } else if proves_refusal(one) && proves_refusal(two) {
                    Decision::RollBack
                } else {
                    Decision::Leave
                };
                assert_eq!(
                    decide(&answered(&[RELAY, SECOND], &[one, two]), DriveMode::Full),
                    expected,
                    "for the answers {one:?} and {two:?}",
                );
            }
        }
        // Nothing attempted yet, and one relay still to answer.
        assert_eq!(
            decide(&staged_fanout(&[RELAY, SECOND]), DriveMode::Full),
            Decision::Leave
        );
        assert_eq!(
            decide(
                &answered(&[RELAY, SECOND], &[Some(TerminalRejected)]),
                DriveMode::Full
            ),
            Decision::Leave,
            "a relay that has not answered has not refused",
        );
        // A record frozen for no relay proves nothing about its commit: it
        // is the trial an open wrote for a removal that may already be on a
        // relay, and is never rolled back.
        assert_eq!(
            decide(&staged_fanout(&[]), DriveMode::Full),
            Decision::Leave
        );
    }

    // ── When a fanout ends ───────────────────────────────────────────────────

    /// A confirmed copy of `fanout`.
    fn applied(mut fanout: OutboundFanout) -> OutboundFanout {
        fanout.mark_mls_confirmed().expect("a pending commit");
        fanout
    }

    /// The frozen count is met by DISTINCT relays: two spellings of one relay
    /// that both took the commit are one acknowledgement.
    #[test]
    fn two_spellings_of_one_relay_are_one_acknowledgement() {
        let spelled_twice = "wss://Relay.Example.com:443";
        let one_relay = answered(&[RELAY, spelled_twice, SECOND], &[None, None]);
        assert_eq!(one_relay.outcome().accepted_targets, 2);
        assert_eq!(accepted_relays(&one_relay), 1);
        let two_relays = answered(&[RELAY, spelled_twice, SECOND], &[None, None, None]);
        assert_eq!(accepted_relays(&two_relays), 2);
        assert_eq!(accepted_relays(&staged_fanout(&[RELAY])), 0);
    }

    /// An applied commit's record ends when nothing is left to retry, when
    /// its frozen count of distinct relays hold the commit, or at the bound —
    /// and in none of those cases while a relay has yet to answer one attempt.
    #[test]
    fn an_applied_commits_record_ends_by_count_or_bound_and_never_before_each_relay_was_asked() {
        use TransportEndpointFailureKind::{RetryableUnavailable, TerminalRejected};
        let now = 1_000;
        // The frozen count (here one) is met, a relay still failing.
        let met = applied(answered(
            &[RELAY, SECOND],
            &[None, Some(RetryableUnavailable)],
        ));
        assert!(finished(&met, now));
        // Not met, a relay still to retry: only the bound ends it.
        let mut unmet = answered(&[RELAY, SECOND], &[None, Some(RetryableUnavailable)]);
        let request = serde_json::to_value(&unmet).expect("the record serializes");
        let mut request = request;
        request["request"]["required_acks"] = serde_json::json!(2);
        unmet = serde_json::from_value(request).expect("the record deserializes");
        let unmet = applied(unmet);
        assert!(!finished(&unmet, now));
        assert!(!finished(&unmet, FANOUT_BOUND_MS - 1));
        assert!(finished(&unmet, FANOUT_BOUND_MS));
        // Nothing left to retry: ended, though the count is not met.
        let mut complete =
            serde_json::to_value(answered(&[RELAY, SECOND], &[None, Some(TerminalRejected)]))
                .expect("the record serializes");
        complete["request"]["required_acks"] = serde_json::json!(2);
        let complete: OutboundFanout =
            serde_json::from_value(complete).expect("the record deserializes");
        assert!(finished(&applied(complete), now));

        // Two acknowledgements from two spellings of ONE relay are one: the
        // count of two is not met, and the relay still failing is retried.
        let spelled_twice = "wss://Relay.Example.com:443";
        let mut one_relay = serde_json::to_value(answered(
            &[RELAY, spelled_twice, SECOND],
            &[None, None, Some(RetryableUnavailable)],
        ))
        .expect("the record serializes");
        one_relay["request"]["required_acks"] = serde_json::json!(2);
        let one_relay: OutboundFanout =
            serde_json::from_value(one_relay).expect("the record deserializes");
        assert!(!finished(&applied(one_relay), now));

        // A relay never asked keeps the record, met or past its bound.
        let never_asked = applied(answered(&[RELAY, SECOND], &[None]));
        assert!(owes_an_attempt(&never_asked));
        assert!(!finished(&never_asked, now) && !finished(&never_asked, 10 * FANOUT_BOUND_MS));
        // So does one whose only attempt never returned.
        let mut cut_off = answered(&[RELAY, SECOND], &[None]);
        cut_off.mark_attempt_started_at(1, 500).expect("attempt");
        assert!(record_interrupted(&mut cut_off).expect("recorded"));
        let cut_off = applied(cut_off);
        assert!(owes_an_attempt(&cut_off));
        assert!(!finished(&cut_off, 10 * FANOUT_BOUND_MS));
        // Once that relay has answered an attempt, it no longer does.
        let mut asked = cut_off;
        asked.mark_attempt_started_at(1, 600).expect("attempt");
        asked
            .record_target_failure(1, failure(SECOND, RetryableUnavailable))
            .expect("recorded");
        assert!(!owes_an_attempt(&asked));
        assert!(finished(&asked, 10 * FANOUT_BOUND_MS));
    }

    /// A stored instant far ahead of the clock — the clock was stepped back
    /// by more than the schedule's longest wait — ends an applied commit's
    /// record: its age can no longer be known. A smaller difference is an
    /// ordinary correction and ends nothing.
    #[test]
    fn only_a_clock_stepped_back_past_the_longest_wait_ends_an_applied_commits_record() {
        use TransportEndpointFailureKind::RetryableUnavailable;
        const STAGED: u64 = 10 * RETRY_MAX_MS;
        const ATTEMPTED: u64 = STAGED + 10_000;
        let mut record =
            serde_json::to_value(staged_fanout(&[RELAY, SECOND])).expect("the record serializes");
        record["request"]["required_acks"] = serde_json::json!(2);
        record["created_at_ms"] = serde_json::json!(STAGED);
        let mut record: OutboundFanout =
            serde_json::from_value(record).expect("the record deserializes");
        record
            .mark_attempt_started_at(0, ATTEMPTED)
            .expect("attempt");
        record.mark_target_accepted(0).expect("accepted");
        record
            .mark_attempt_started_at(1, ATTEMPTED)
            .expect("attempt");
        record
            .record_target_failure(1, failure(SECOND, RetryableUnavailable))
            .expect("recorded");
        let record = applied(record);
        assert!(!finished(&record, ATTEMPTED) && !finished(&record, ATTEMPTED + 10_000));
        assert!(
            !finished(&record, ATTEMPTED - 1) && !finished(&record, ATTEMPTED - RETRY_MAX_MS),
            "a clock corrected by no more than the longest wait ended a record",
        );
        assert!(
            finished(&record, ATTEMPTED - RETRY_MAX_MS - 1),
            "an attempt lies further ahead of the clock than any wait",
        );
        assert!(
            !finished(&record, STAGED - RETRY_MAX_MS)
                || ATTEMPTED - (STAGED - RETRY_MAX_MS) > RETRY_MAX_MS,
            "premise: the attempt, not the staging, is what lies ahead here",
        );
    }

    /// An applied commit's day of retries is counted from the later of its
    /// staging and the moment the first relay that holds it was sent it.
    #[test]
    fn an_applied_commits_bound_runs_from_its_first_acknowledged_attempt() {
        use TransportEndpointFailureKind::RetryableUnavailable;
        const ACKED: u64 = 30 * 60 * 60 * 1_000;
        let mut record =
            serde_json::to_value(staged_fanout(&[RELAY, SECOND])).expect("the record serializes");
        record["request"]["required_acks"] = serde_json::json!(2);
        let mut record: OutboundFanout =
            serde_json::from_value(record).expect("the record deserializes");
        record.mark_attempt_started_at(0, ACKED).expect("attempt");
        record.mark_target_accepted(0).expect("accepted");
        record.mark_attempt_started_at(1, ACKED).expect("attempt");
        record
            .record_target_failure(1, failure(SECOND, RetryableUnavailable))
            .expect("recorded");
        let record = applied(record);
        assert_eq!(
            record.created_at_ms(),
            0,
            "premise: staged thirty hours before"
        );
        assert_eq!(retried_since_ms(&record), ACKED);
        assert!(
            !finished(&record, ACKED) && !finished(&record, ACKED + FANOUT_BOUND_MS - 1),
            "a commit first acknowledged after its staging bound ended with one relay holding it",
        );
        assert!(finished(&record, ACKED + FANOUT_BOUND_MS));
        // Nobody has acknowledged it: the staging is all there is to count from.
        assert_eq!(retried_since_ms(&staged_fanout(&[RELAY])), 0);
    }

    /// A pending commit is undone at the bound only when nothing was ever
    /// possibly exposed, every relay still outstanding has answered "could
    /// not be reached" or "not now", and the clock reads at or past the
    /// bound — never before it, and never when it reads before the staging.
    #[test]
    fn a_pending_commit_is_undone_at_the_bound_only_when_no_relay_was_reached() {
        use TransportEndpointFailureKind::{
            PossiblyExposed, RetryableUnavailable, TerminalRejected,
        };
        let at = |created: u64, fanout: OutboundFanout| {
            let mut record = serde_json::to_value(fanout).expect("the record serializes");
            record["created_at_ms"] = serde_json::json!(created);
            serde_json::from_value::<OutboundFanout>(record).expect("the record deserializes")
        };
        let unreachable = at(
            10_000,
            answered(
                &[RELAY, SECOND],
                &[Some(RetryableUnavailable), Some(TerminalRejected)],
            ),
        );
        assert!(!unreachable_past_the_bound(
            &unreachable,
            10_000 + FANOUT_BOUND_MS - 1
        ));
        assert!(unreachable_past_the_bound(
            &unreachable,
            10_000 + FANOUT_BOUND_MS
        ));
        assert!(
            !unreachable_past_the_bound(&unreachable, 9_999)
                && !unreachable_past_the_bound(&at(2 * FANOUT_BOUND_MS, unreachable), 0),
            "a clock that reads before the staging undid a commit",
        );
        // A relay never asked, one that may hold the commit, one that took
        // it, and a commit already applied: none is undone.
        for kept in [
            answered(&[RELAY, SECOND], &[Some(RetryableUnavailable)]),
            answered(
                &[RELAY, SECOND],
                &[Some(RetryableUnavailable), Some(PossiblyExposed)],
            ),
            answered(&[RELAY, SECOND], &[Some(RetryableUnavailable), None]),
            applied(answered(
                &[RELAY, SECOND],
                &[Some(RetryableUnavailable), None],
            )),
        ] {
            assert!(!unreachable_past_the_bound(
                &at(0, kept),
                10 * FANOUT_BOUND_MS
            ));
        }
        // An attempt that never returned may have been sent.
        let mut cut_off = answered(&[RELAY], &[]);
        cut_off.mark_attempt_started_at(0, 5).expect("attempt");
        record_interrupted(&mut cut_off).expect("recorded");
        assert!(!unreachable_past_the_bound(
            &at(0, cut_off),
            10 * FANOUT_BOUND_MS
        ));
        // The exposure FLAG decides, as it does for any rollback: a record
        // whose statuses read "could not be reached" beside a set flag —
        // written by another version of the record — is never undone.
        let mut flagged = serde_json::to_value(answered(&[RELAY], &[Some(RetryableUnavailable)]))
            .expect("the record serializes");
        flagged["target_possible_exposure"] = serde_json::json!([true]);
        let flagged: OutboundFanout =
            serde_json::from_value(flagged).expect("the record deserializes");
        assert!(flagged.possible_exposure());
        assert!(!unreachable_past_the_bound(&flagged, 10 * FANOUT_BOUND_MS));
    }

    /// The wake a record asks for: its soonest relay across every stored
    /// record, or its bound where the bound can end it — and none of its own
    /// for a pending commit a relay may hold once a day has passed.
    #[test]
    fn a_record_asks_to_be_woken_only_when_something_can_be_done_for_it() {
        const LAST_CALL: u64 = FANOUT_BOUND_MS - RETRY_MAX_MS / 2;
        // Unreachable once at t = 0: due again five seconds later, and the
        // bound is offered only for a commit that may be undone.
        let mut unreachable = staged_fanout(&[RELAY]);
        failed_call(&mut unreachable, RELAY, 0, UNREACHABLE);
        let all = [unreachable.clone()];
        assert_eq!(
            wake_after_ms(&all, &unreachable, 1_000, true),
            Some(UNAVAILABLE_RETRY_DELAY_MS - 1_000)
        );
        let mut waited_out = unreachable.clone();
        for began in 1..=9 {
            failed_call(
                &mut waited_out,
                RELAY,
                LAST_CALL - (9 - began) * RETRY_MAX_MS,
                UNREACHABLE,
            );
        }
        let relay_due_at = LAST_CALL + retry_delay_ms(Backoff::Unreachable, 10, 0);
        let now = FANOUT_BOUND_MS - 60_000;
        let all = [waited_out.clone()];
        assert_eq!(wake_after_ms(&all, &waited_out, now, true), Some(60_000));
        assert_eq!(
            wake_after_ms(&all, &waited_out, now, false),
            Some(relay_due_at - now),
            "a removal has no bound to wake for: only its relay's wait",
        );
        // A bound already past that did not end the record cannot: no zero.
        assert_eq!(
            wake_after_ms(&all, &waited_out, FANOUT_BOUND_MS + 1, true),
            Some(relay_due_at - FANOUT_BOUND_MS - 1),
        );

        // A pending commit a relay may hold: its relay's wait for a day, and
        // after that no wake of its own.
        let mut exposed = staged_fanout(&[RELAY]);
        failed_call(&mut exposed, RELAY, 0, AMBIGUOUS);
        let all = [exposed.clone()];
        assert_eq!(
            wake_after_ms(&all, &exposed, 1_000, true),
            Some(AMBIGUOUS_RETRY_BASE_MS - 1_000)
        );
        assert_eq!(
            wake_after_ms(&all, &exposed, FANOUT_BOUND_MS - 1, true),
            None
        );
        let mut retried = exposed.clone();
        failed_call(&mut retried, RELAY, FANOUT_BOUND_MS - 10_000, AMBIGUOUS);
        let all = [retried.clone()];
        assert!(wake_after_ms(&all, &retried, FANOUT_BOUND_MS - 1, true).is_some());
        assert_eq!(
            wake_after_ms(&all, &retried, FANOUT_BOUND_MS, true),
            None,
            "a commit a relay may hold still asked for a wake of its own after a day",
        );

        // Two records owe one relay: the newer one's wait is the relay's,
        // not the five seconds its own single call would earn.
        let mut older = staged_fanout(&[RELAY]);
        for began in [0, 5_000, 10_000, 40_000] {
            failed_call(&mut older, RELAY, began, UNREACHABLE);
        }
        let mut newer = other_fanout(&[RELAY]);
        failed_call(&mut newer, RELAY, 41_000, UNREACHABLE);
        let all = [older.clone(), newer.clone()];
        assert_eq!(
            wake_after_ms(&all, &newer, 42_000, false),
            Some(41_000 + 2 * AMBIGUOUS_RETRY_BASE_MS - 42_000),
            "a record's wake ignored the calls another record made to its relay",
        );
        let alone = [newer.clone()];
        assert_eq!(
            wake_after_ms(&alone, &newer, 42_000, false),
            Some(41_000 + UNAVAILABLE_RETRY_DELAY_MS - 42_000),
            "premise: on its own it would be due in five seconds",
        );
    }

    /// What a change did says how many people were invited, and what it
    /// replayed names a circle, a member and where that member is: none of
    /// it is in its `Debug`, which a log line or an FFI error string could
    /// carry (Security Rule 15).
    #[test]
    #[allow(clippy::too_many_lines)]
    fn an_outcomes_debug_redacts_everything_but_where_the_change_stands() {
        use crate::nostr::mls::types::GroupIdExt as _;

        const SENDER: &str = "5e9de75e9de75e9de75e9de75e9de75e9de75e9de75e9de75e9de75e9de75e9d";
        const FIX: &str = "51.50735,-0.12776";
        const SEAL_RELAY: &str = "wss://seal-canary7a1c.example.com";
        let group = GroupId::from_slice(&[0xc1; 32]);
        let needles = [SENDER, FIX, &hex::encode(group.as_slice()), "31337"];
        let replayed = || {
            vec![LocationMessageResult::Location {
                sender_pubkey: SENDER.to_owned(),
                content: FIX.to_owned(),
                group_id: group.clone(),
                epoch: 4,
            }]
        };
        let outcome = || EvolutionOutcome {
            status: EvolutionStatus::Unresolved,
            welcomes_sent: 7,
            welcomes_total: 9,
            notes: vec![ChangeNote::ReinviteOwed],
            replayed: replayed(),
            retry_after_ms: Some(31_337),
            clock_rejected: None,
        };
        crate::assert_debug_redacted!(outcome(), "EvolutionOutcome", &needles);
        crate::assert_debug_redacted!(
            RepairOutcome::Rotated(outcome()),
            "RepairOutcome",
            marker = "Rotated",
            &needles
        );
        crate::assert_debug_redacted!(
            RepairOutcome::Deferred {
                held_by: SendHeld::AwaitingRelays,
                replayed: replayed(),
            },
            "RepairOutcome",
            marker = "Deferred",
            &needles
        );
        let event =
            SessionManager::transport_message_to_event(&fanout_message()).expect("a signed event");
        let event_id = event.id.to_hex();
        let ngid = hex::encode([0xC7_u8; 32]);
        let needles = [
            SENDER,
            FIX,
            &hex::encode(group.as_slice()),
            "31337",
            &event_id,
            &ngid,
            "seal-canary7a1c",
        ];
        crate::assert_debug_redacted!(
            LocationSeal::Sealed {
                event: Box::new(event.clone()),
                nostr_group_id: [0xC7; 32],
                relays: vec![SEAL_RELAY.to_owned()],
            },
            "LocationSeal",
            marker = "Sealed",
            &needles
        );
        crate::assert_debug_redacted!(
            SealOutcome {
                seal: LocationSeal::Sealed {
                    event: Box::new(event),
                    nostr_group_id: [0xC7; 32],
                    relays: vec![SEAL_RELAY.to_owned()],
                },
                replayed: replayed(),
                retry_after_ms: Some(31_337),
                clock_rejected: None,
                errored: false,
            },
            "SealOutcome",
            marker = "Sealed",
            &needles
        );
        crate::assert_debug_redacted!(
            SealOutcome {
                seal: LocationSeal::Deferred(SendHeld::DepartureDue),
                replayed: replayed(),
                retry_after_ms: None,
                clock_rejected: None,
                errored: true,
            },
            "SealOutcome",
            marker = "DepartureDue",
            &needles
        );
        // Every reason a send is held, by its name and nothing else.
        for held in [
            SendHeld::AwaitingRelays,
            SendHeld::Acknowledged,
            SendHeld::StagedWithoutRecord,
            SendHeld::DepartureDue,
            SendHeld::AwaitsForeground,
            SendHeld::RemovalUnmade,
            SendHeld::Leaving,
            SendHeld::Disbanded,
            SendHeld::RoutingCollision,
            SendHeld::StoredInput,
            SendHeld::Nothing,
        ] {
            let name = match held {
                SendHeld::AwaitingRelays => "AwaitingRelays",
                SendHeld::Acknowledged => "Acknowledged",
                SendHeld::StagedWithoutRecord => "StagedWithoutRecord",
                SendHeld::DepartureDue => "DepartureDue",
                SendHeld::AwaitsForeground => "AwaitsForeground",
                SendHeld::RemovalUnmade => "RemovalUnmade",
                SendHeld::Leaving => "Leaving",
                SendHeld::Disbanded => "Disbanded",
                SendHeld::RoutingCollision => "RoutingCollision",
                SendHeld::StoredInput => "StoredInput",
                SendHeld::Nothing => "Nothing",
            };
            assert_eq!(format!("{held:?}"), name);
            crate::assert_debug_redacted!(
                SealOutcome {
                    seal: LocationSeal::Deferred(held),
                    replayed: replayed(),
                    retry_after_ms: Some(31_337),
                    clock_rejected: None,
                    errored: false,
                },
                "SealOutcome",
                marker = name,
                &needles
            );
        }
        // The two counts are single digits no needle can carry.
        for rendered in [
            format!("{:?}", outcome()),
            format!("{:#?}", outcome()),
            format!("{:?}", RepairOutcome::Rotated(outcome())),
        ] {
            assert!(
                !rendered.contains(['7', '9']) && !rendered.contains("Reinvite"),
                "a count or a note is rendered: {rendered}",
            );
            assert!(rendered.contains("Unresolved"), "{rendered}");
        }
    }

    /// The schedule's waits grow with the calls a relay has been made, so a
    /// commit whose device was off for its first day would be sent every few
    /// minutes of its second. Past that day a pending commit a relay may
    /// hold goes to a relay once an hour at most; before it, and for a
    /// commit no relay can hold, the schedule alone decides.
    #[test]
    fn a_day_old_commit_a_relay_may_hold_is_sent_to_it_once_an_hour_at_most() {
        let due = |fanout: &OutboundFanout, now_ms: u64| {
            let (due, wait) = due_attempts(std::slice::from_ref(fanout), fanout, now_ms);
            (due.len(), wait)
        };
        let after = AMBIGUOUS_RETRY_BASE_MS + 1;

        let mut young = staged_fanout(&[RELAY]);
        failed_call(&mut young, RELAY, 1_000, AMBIGUOUS);
        assert_eq!(
            due(&young, 1_000 + after),
            (1, None),
            "control: in its first day the schedule's own wait decides",
        );

        let called = FANOUT_BOUND_MS + 1_000;
        let mut old = staged_fanout(&[RELAY]);
        failed_call(&mut old, RELAY, called, AMBIGUOUS);
        assert_eq!(
            due(&old, called + after),
            (0, Some(RETRY_MAX_MS - after)),
            "a day-old commit a relay may hold was sent again inside the hour",
        );
        assert_eq!(due(&old, called + RETRY_MAX_MS), (1, None));
        // A stored call that lies ahead of the clock by more than any wait
        // is a clock stepped back, and is not waited out.
        assert_eq!(due(&old, FANOUT_BOUND_MS + 10), (1, None));

        let mut unreachable = staged_fanout(&[RELAY]);
        failed_call(&mut unreachable, RELAY, called, UNREACHABLE);
        assert_eq!(
            due(&unreachable, called + UNAVAILABLE_RETRY_DELAY_MS),
            (1, None),
            "control: a commit no relay can hold keeps the schedule's own wait",
        );
    }

    /// A relay that acknowledges an event is there: what it is still owed
    /// follows at once, whatever wait its last failure earned.
    #[test]
    fn an_acknowledgement_ends_the_relays_wait_for_the_records_it_still_owes() {
        let mut older = staged_fanout(&[RELAY, SECOND]);
        for began in [0, 5_000, 10_000, 40_000] {
            failed_call(&mut older, RELAY, began, UNREACHABLE);
        }
        let all = [older.clone()];
        assert_eq!(
            relay_due(&all, &older, &relay_url(RELAY), u64::MAX),
            RelayDue::At(40_000 + AMBIGUOUS_RETRY_BASE_MS)
        );
        // A newer record the relay took BEFORE that last failure says
        // nothing new; one it took after it does.
        let mut newer = other_fanout(&[RELAY]);
        newer.mark_attempt_started_at(0, 39_999).expect("attempt");
        newer.mark_target_accepted(0).expect("accepted");
        let all = [older.clone(), newer];
        assert_eq!(
            relay_due(&all, &older, &relay_url(RELAY), u64::MAX),
            RelayDue::At(40_000 + AMBIGUOUS_RETRY_BASE_MS)
        );
        let mut newer = other_fanout(&[RELAY]);
        newer.mark_attempt_started_at(0, 40_001).expect("attempt");
        newer.mark_target_accepted(0).expect("accepted");
        let all = [older.clone(), newer];
        assert_eq!(
            relay_due(&all, &older, &relay_url(RELAY), u64::MAX),
            RelayDue::Now
        );
        // And a failure after the acknowledgement puts the wait back.
        failed_call(&mut older, RELAY, 40_002, UNREACHABLE);
        assert!(matches!(
            relay_due(&all, &older, &relay_url(RELAY), u64::MAX),
            RelayDue::At(_)
        ));
    }

    /// A finished record is kept while deleting it would have a relay called
    /// sooner, and only then.
    #[test]
    fn a_finished_record_is_kept_only_while_its_end_would_change_a_relays_wait() {
        const NOW: u64 = 40 * RETRY_MAX_MS;
        // Eleven unresolved calls to one relay on the older record; one on
        // the newer. Without the older, the relay's schedule starts over.
        let mut older = staged_fanout(&[RELAY]);
        let mut began = 0;
        for call in 0..11_u64 {
            began = call * RETRY_MAX_MS;
            failed_call(&mut older, RELAY, began, UNREACHABLE);
        }
        let mut newer = other_fanout(&[RELAY]);
        failed_call(&mut newer, RELAY, began + 1, UNREACHABLE);
        let all = [older.clone(), newer.clone()];
        assert!(changes_a_wait(&all, &older, NOW));
        // Nobody else owes that relay: nothing to shorten.
        assert!(!changes_a_wait(&[older.clone()], &older, NOW));
        let elsewhere = other_fanout(&[SECOND]);
        assert!(!changes_a_wait(&[older.clone(), elsewhere], &older, NOW));
        // The newer record's own calls have reached the longest wait: the
        // older one's count no longer changes anything.
        for call in 1..=10_u64 {
            failed_call(
                &mut newer,
                RELAY,
                began + 1 + call * RETRY_MAX_MS,
                UNREACHABLE,
            );
        }
        assert!(!changes_a_wait(
            &[older.clone(), newer.clone()],
            &older,
            NOW
        ));
        // A record whose relays all answered holds nothing a wait rests on.
        let mut answered_all = staged_fanout(&[RELAY]);
        answered_all.mark_attempt_started_at(0, 5).expect("attempt");
        answered_all.mark_target_accepted(0).expect("accepted");
        assert!(
            !changes_a_wait(&[answered_all.clone(), newer.clone()], &answered_all, NOW),
            "an acknowledgement older than the relay's last failure changed a wait",
        );
        // One the relay acknowledged AFTER its last failure is what makes it
        // due now for the record still waiting: kept until that call is made.
        let mut just_taken = staged_fanout(&[RELAY]);
        just_taken.mark_attempt_started_at(0, NOW).expect("attempt");
        just_taken.mark_target_accepted(0).expect("accepted");
        assert!(changes_a_wait(
            &[just_taken.clone(), newer.clone()],
            &just_taken,
            NOW
        ));
        // A record that has itself ended has no call to wait for.
        let ended = applied(newer);
        assert!(finished(&ended, NOW + 2 * FANOUT_BOUND_MS));
        assert!(!changes_a_wait(
            &[just_taken.clone(), ended],
            &just_taken,
            NOW + 2 * FANOUT_BOUND_MS
        ));
    }

    /// A wait longer than any the schedule gives is a stored attempt ahead of
    /// the clock: due now. And a commit nothing was ever sent for calls the
    /// soonest of its relays on its first drive, though none is free.
    #[test]
    fn a_relay_is_due_when_its_wait_exceeds_the_schedule_and_on_a_commits_first_drive() {
        use TransportEndpointFailureKind::PossiblyExposed;
        // Ten hours ahead of the clock.
        let mut ahead = staged_fanout(&[RELAY]);
        failed_call(&mut ahead, RELAY, 36_000_000, AMBIGUOUS);
        let all = [ahead.clone()];
        assert_eq!(due_attempts(&all, &ahead, 0).0.len(), 1);
        // One millisecond inside the schedule's longest wait: not due.
        let mut inside = staged_fanout(&[RELAY]);
        for began in [0, 1, 2, 3, 4, 5, 6, RETRY_MAX_MS] {
            failed_call(&mut inside, RELAY, began, AMBIGUOUS);
        }
        let all = [inside.clone()];
        let (due, wait) = due_attempts(&all, &inside, RETRY_MAX_MS + 1);
        assert!(due.is_empty());
        assert_eq!(wait, Some(RETRY_MAX_MS - 1));

        // A new commit behind two relays another commit left backing off.
        let mut older = staged_fanout(&[RELAY, SECOND]);
        failed_call(&mut older, RELAY, 1_000, UNREACHABLE);
        failed_call(&mut older, SECOND, 1_000, AMBIGUOUS);
        let new = staged_fanout(&[RELAY, SECOND]);
        let all = [older.clone(), new.clone()];
        let (due, _) = due_attempts(&all, &new, 2_000);
        assert_eq!(
            due.iter()
                .map(|attempt| attempt.spellings.clone())
                .collect::<Vec<_>>(),
            [vec![0]],
            "a commit's first drive called no relay, or not the soonest one",
        );
        // Once it has been sent to one relay, it waits like any other.
        let mut sent_once = new;
        sent_once
            .mark_attempt_started_at(0, 2_000)
            .expect("attempt");
        sent_once
            .record_target_failure(0, failure(RELAY, PossiblyExposed))
            .expect("recorded");
        let all = [older, sent_once.clone()];
        assert!(due_attempts(&all, &sent_once, 2_001).0.is_empty());
    }

    /// The rollback reads the record's exposure FLAG. Today's record keeps an
    /// exposed target outstanding, so its status says the same thing; a record
    /// whose statuses read "everything refused" beside a set flag — written by
    /// another version, or by a later change to how MDK records a refusal —
    /// must still never be rolled back.
    #[test]
    fn a_target_ever_possibly_exposed_forbids_the_rollback_whatever_its_status_says() {
        let refused = answered(
            &[RELAY],
            &[Some(TransportEndpointFailureKind::TerminalRejected)],
        );
        assert_eq!(
            decide(&refused, DriveMode::Full),
            Decision::RollBack,
            "premise"
        );

        let mut stored = serde_json::to_value(&refused).expect("a fanout serialises");
        assert_eq!(
            stored["target_possible_exposure"],
            serde_json::json!([false]),
            "premise: this is the flag the record keeps",
        );
        stored["target_possible_exposure"] = serde_json::json!([true]);
        let once_exposed: OutboundFanout =
            serde_json::from_value(stored).expect("the record deserialises");
        assert!(
            once_exposed.outcome().fanout_complete && once_exposed.outcome().accepted_targets == 0,
            "premise: by its statuses alone this fanout is complete and unaccepted",
        );
        assert_eq!(
            decide(&once_exposed, DriveMode::Full),
            Decision::Leave,
            "a commit a relay may hold was rolled back on its targets' statuses",
        );
    }

    /// One attempt per distinct relay, covering every frozen spelling of it;
    /// terminal targets are not attempted again.
    #[test]
    fn each_relay_is_attempted_once_however_often_it_is_spelled() {
        let spelled_twice = "wss://Relay.Example.com:443";
        let mut fanout = staged_fanout(&[RELAY, SECOND, spelled_twice, "not a relay"]);
        let spellings = |fanout: &OutboundFanout| -> Vec<Vec<usize>> {
            due_attempts(std::slice::from_ref(fanout), fanout, 0)
                .0
                .into_iter()
                .map(|attempt| attempt.spellings)
                .collect()
        };
        assert_eq!(spellings(&fanout), [vec![0, 2], vec![1], vec![3]]);

        // The answer to one spelling is the answer of both.
        for index in [0, 2] {
            fanout.mark_attempt_started(index).expect("attempt");
        }
        record(
            &mut fanout,
            &Attempt {
                spellings: vec![0, 2],
            },
            failed_as(
                &endpoint(RELAY),
                failure(RELAY, TransportEndpointFailureKind::TerminalRejected),
            ),
        )
        .expect("the refusal is recorded under each spelling");
        assert_eq!(
            [fanout.target_status(0), fanout.target_status(2)],
            [Some(FanoutTargetStatus::Failed); 2],
        );
        assert_eq!(spellings(&fanout), [vec![1], vec![3]]);
    }

    /// A target found `Attempting` was handed to the transport and never
    /// answered for: stored possibly exposed, and so it stays.
    #[test]
    fn an_attempt_found_begun_is_stored_possibly_exposed() {
        let mut fanout = staged_fanout(&[RELAY, SECOND]);
        assert!(!record_interrupted(&mut fanout).expect("nothing begun"));
        fanout.mark_attempt_started(0).expect("attempt");

        assert!(record_interrupted(&mut fanout).expect("recorded"));
        assert_eq!(
            [fanout.target_status(0), fanout.target_status(1)],
            [
                Some(FanoutTargetStatus::PossiblyExposed),
                Some(FanoutTargetStatus::NotAttempted)
            ],
        );
        assert!(fanout.possible_exposure());
        // A proven refusal afterwards does not clear it.
        fanout.mark_attempt_started(0).expect("retry");
        record(
            &mut fanout,
            &Attempt { spellings: vec![0] },
            failed_as(
                &endpoint(RELAY),
                failure(RELAY, TransportEndpointFailureKind::TerminalRejected),
            ),
        )
        .expect("recorded");
        assert_eq!(
            fanout.target_status(0),
            Some(FanoutTargetStatus::PossiblyExposed)
        );
    }

    /// `OK false duplicate:` is the relay saying it already holds the event.
    /// MDK's client reads it so only when its own wait is the one that heard
    /// it (`transport-nostr-adapter/src/sdk_client.rs` 1621-1630); an answer
    /// that lands between two of its attempts reaches this stream alone.
    #[tokio::test]
    async fn an_ok_false_duplicate_heard_from_the_relay_is_its_acknowledgement() {
        let message = fanout_message();
        let id = id_of(&message);
        for (kind, category) in [
            (
                TransportEndpointFailureKind::TerminalRejected,
                TransportEndpointRejectionCategory::Blocked,
            ),
            (
                TransportEndpointFailureKind::RetryableUnavailable,
                TransportEndpointRejectionCategory::RateLimited,
            ),
        ] {
            let (said, stream) = broadcast::channel(64);
            for text in ["duplicate: already have this event", "", ""] {
                said.send(RelayNotification::Message {
                    message: RelayMessage::ok(id, false, text),
                })
                .unwrap_or_else(|_| panic!("the stream has its listener"));
            }
            let outcome = publish_to_target(
                &failing(kind, Some(category)),
                &endpoint(RELAY),
                &message,
                Some(stream),
                BEFORE_EVERY_SIGNING,
            )
            .await;
            assert!(
                matches!(outcome, FanoutTargetOutcome::Accepted),
                "a relay that said it already holds the event was returned as \
                 having refused it three times",
            );
        }

        // Some other event's `duplicate:` says nothing about this one.
        let (said, stream) = broadcast::channel(64);
        for (named, text) in [
            (id_of(&fanout_message()), "duplicate: another event"),
            (id, ""),
            (id, ""),
            (id, ""),
        ] {
            said.send(RelayNotification::Message {
                message: RelayMessage::ok(named, false, text),
            })
            .unwrap_or_else(|_| panic!("the stream has its listener"));
        }
        let outcome = publish_to_target(
            &failing(
                TransportEndpointFailureKind::TerminalRejected,
                Some(TransportEndpointRejectionCategory::Blocked),
            ),
            &endpoint(RELAY),
            &message,
            Some(stream),
            BEFORE_EVERY_SIGNING,
        )
        .await;
        assert!(
            classified(&outcome)
                == Some((
                    TransportEndpointFailureKind::TerminalRejected,
                    Some(TransportEndpointRejectionCategory::Blocked)
                )),
            "another event's acknowledgement was taken for this one's",
        );
    }

    /// What does not rest on the relay's words needs no proof of them: MDK
    /// could not reach the relay, or claims nothing.
    #[tokio::test]
    async fn an_answer_that_is_not_the_relays_own_is_returned_as_mdk_gave_it() {
        use TransportEndpointFailureKind::{NotExposed, PossiblyExposed, RetryableUnavailable};
        let cases = [
            (RetryableUnavailable, None),
            (PossiblyExposed, None),
            (
                PossiblyExposed,
                Some(TransportEndpointRejectionCategory::Error),
            ),
            (NotExposed, None),
        ];
        for (kind, category) in cases {
            let outcome = publish_to_target(
                &failing(kind, category),
                &endpoint(RELAY),
                &fanout_message(),
                None,
                BEFORE_EVERY_SIGNING,
            )
            .await;
            assert!(
                classified(&outcome) == Some((kind, category)),
                "an answer that needs no proof was changed on the way",
            );
        }
    }

    /// Acked means acked: an `OK true` for this event from this relay is its
    /// acknowledgement whether or not MDK's client was still waiting when it
    /// arrived, and whatever MDK's last attempt was told afterwards.
    #[tokio::test]
    async fn an_ok_true_from_the_relay_is_its_acknowledgement_whatever_mdk_reports() {
        use TransportEndpointFailureKind::{PossiblyExposed, TerminalRejected};
        let message = fanout_message();
        let (id, other) = (id_of(&message), id_of(&fanout_message()));
        let blocked = Some(TransportEndpointRejectionCategory::Blocked);

        for reported in [(TerminalRejected, blocked), (PossiblyExposed, None)] {
            let client = failing(reported.0, reported.1);
            let (_said, stream) = heard(&[(id, true), (id, false), (id, false)]);
            assert!(
                matches!(
                    publish_to_target(
                        &client,
                        &endpoint(RELAY),
                        &message,
                        Some(stream),
                        BEFORE_EVERY_SIGNING
                    )
                    .await,
                    FanoutTargetOutcome::Accepted
                ),
                "the relay acknowledged the event and the publish was reported failed",
            );

            let (_said, stream) = heard(&[(other, true), (id, false), (id, false), (id, false)]);
            assert!(
                !matches!(
                    publish_to_target(
                        &client,
                        &endpoint(RELAY),
                        &message,
                        Some(stream),
                        BEFORE_EVERY_SIGNING
                    )
                    .await,
                    FanoutTargetOutcome::Accepted
                ),
                "an acknowledgement of some other event was taken for this one",
            );
        }

        // Even on a stream that dropped frames: what is still there is real.
        let (said, lagged) = broadcast::channel(2);
        for (named, status) in [(other, false), (other, false), (id, true)] {
            said.send(RelayNotification::Message {
                message: RelayMessage::ok(named, status, ""),
            })
            .unwrap_or_else(|_| panic!("the stream has its listener"));
        }
        let erring = Scripted::answering(|| Err(TransportAdapterError::Closed));
        assert!(
            matches!(
                publish_to_target(
                    &erring,
                    &endpoint(RELAY),
                    &message,
                    Some(lagged),
                    BEFORE_EVERY_SIGNING
                )
                .await,
                FanoutTargetOutcome::Accepted
            ),
            "an acknowledgement still on the stream was lost with the frames before it",
        );
    }

    /// The publish client can never authenticate, so `auth-required:` cannot
    /// change: once the relay has said it to every attempt it is a refusal, not
    /// an outage to wait out. Unproven, it is what every unproven refusal is.
    #[tokio::test]
    async fn auth_required_is_terminal_once_every_attempt_was_answered_with_it() {
        use TransportEndpointFailureKind::{
            PossiblyExposed, RetryableUnavailable, TerminalRejected,
        };
        let auth = Some(TransportEndpointRejectionCategory::AuthRequired);
        let client = failing(RetryableUnavailable, auth);
        let message = fanout_message();
        let id = id_of(&message);

        let (_said, proven) = heard(&[(id, false); 3]);
        let outcome = publish_to_target(
            &client,
            &endpoint(RELAY),
            &message,
            Some(proven),
            BEFORE_EVERY_SIGNING,
        )
        .await;
        assert!(
            classified(&outcome) == Some((TerminalRejected, auth)),
            "a demand this client can never meet was left retryable",
        );

        let (_said, unproven) = heard(&[(id, false); 2]);
        let outcome = publish_to_target(
            &client,
            &endpoint(RELAY),
            &message,
            Some(unproven),
            BEFORE_EVERY_SIGNING,
        )
        .await;
        assert!(
            classified(&outcome) == Some((PossiblyExposed, auth)),
            "an unproven demand for authentication was returned as a refusal",
        );
    }

    /// MDK's durable record of one group message frozen for `targets`.
    fn staged(message: &TransportMessage, targets: &[TransportEndpoint]) -> OutboundFanout {
        let cgka_traits::transport::TransportEnvelope::GroupMessage { transport_group_id } =
            message.envelope.clone()
        else {
            panic!("a kind-445 message is a group message");
        };
        OutboundFanout::stage(
            TransportPublishRequest {
                account_id: MemberId::new(vec![1; 32]),
                message: message.clone(),
                target: TransportPublishTarget::Group {
                    group_id: GroupId::new(vec![2; 16]),
                    transport_group_id,
                    endpoints: targets.to_vec(),
                },
                required_acks: 1,
            },
            None,
            None,
            0,
        )
        .unwrap_or_else(|_| panic!("the fanout stages"))
    }

    /// The hand-off the driver depends on: a stored fanout takes a failure
    /// only for the exact endpoint it froze, and what it records decides
    /// whether the target is still owed an attempt.
    #[tokio::test]
    async fn a_stored_fanout_takes_each_classification_for_the_target_it_froze() {
        use TransportEndpointFailureKind::{
            NotExposed, PossiblyExposed, RetryableUnavailable, TerminalRejected,
        };
        use TransportEndpointRejectionCategory::{AuthRequired, Blocked, RateLimited};
        // What MDK's client reports, and the status MDK's record gives Haven's
        // answer to it. Every relay-spoken one is proven: three refusals heard.
        let cases = [
            (
                Some((TerminalRejected, Some(Blocked))),
                FanoutTargetStatus::Failed,
            ),
            (
                Some((RetryableUnavailable, Some(AuthRequired))),
                FanoutTargetStatus::Failed,
            ),
            (Some((NotExposed, None)), FanoutTargetStatus::Failed),
            (
                Some((RetryableUnavailable, Some(RateLimited))),
                FanoutTargetStatus::RetryableUnavailable,
            ),
            (
                Some((RetryableUnavailable, None)),
                FanoutTargetStatus::RetryableUnavailable,
            ),
            (
                Some((PossiblyExposed, None)),
                FanoutTargetStatus::PossiblyExposed,
            ),
            (None, FanoutTargetStatus::PossiblyExposed),
        ];
        let message = fanout_message();
        let id = id_of(&message);
        // Each target spelled as another client might, never as MDK answers.
        let targets: Vec<TransportEndpoint> = (0..=cases.len())
            .map(|n| endpoint(&format!("wss://Relay{n}.Example.com:443")))
            .collect();
        let mut fanout = staged(&message, &targets);
        let mut record = |index: usize, outcome: FanoutTargetOutcome, recorded| {
            let FanoutTargetOutcome::Failed(failure) = outcome else {
                panic!("a failure read as an acceptance");
            };
            assert!(fanout
                .mark_attempt_started(index)
                .is_ok_and(|started| started));
            assert!(
                fanout
                    .record_target_failure(index, failure.into_mdk_failure())
                    .is_ok_and(|recorded| recorded),
                "the stored fanout refused the failure: it is not under the \
                 endpoint the fanout froze",
            );
            assert!(
                fanout.target_status(index) == Some(recorded),
                "MDK recorded a classification as another status than the one \
                 the driver's decisions assume",
            );
        };

        for (index, (reported, recorded)) in cases.into_iter().enumerate() {
            let client = Scripted::answering(move || {
                reported.map_or_else(
                    || Err(TransportAdapterError::Closed),
                    |(kind, category)| {
                        Ok(NostrPublishOutcome {
                            message_id: None,
                            accepted: Vec::new(),
                            failed: vec![failure_of(
                                &format!("wss://relay{index}.example.com"),
                                kind,
                                category,
                            )],
                        })
                    },
                )
            });
            let (_said, refusals) = heard(&[(id, false); 3]);
            let outcome = publish_to_target(
                &client,
                &targets[index],
                &message,
                Some(refusals),
                BEFORE_EVERY_SIGNING,
            )
            .await;
            record(index, outcome, recorded);
        }
        // Haven's own refusal before the hand-over completes its target too.
        let last = cases.len();
        record(
            last,
            not_exposed(&targets[last]),
            FanoutTargetStatus::Failed,
        );

        // A rate limit and an unreachable relay stay owed an attempt, so the
        // fanout is not complete; nothing above but the two ambiguous answers
        // counts as possible exposure.
        assert!(FanoutTargetStatus::RetryableUnavailable.is_outstanding());
        assert!(!fanout.outcome().fanout_complete);
        assert!(fanout.possible_exposure());
    }

    const CANARY: &str = "canary7f3a";

    /// Nothing a relay says, and nothing that names it, reaches a Haven log
    /// line or a rendering of what the transport returns — on any of the
    /// transport's own lines, each of which is made to speak here.
    ///
    /// The relay answers `OK false` with the canary in its text, the target's
    /// URL carries the canary in its path, one publish is refused before the
    /// hand-over, and a relay client that quotes the relay is driven beside
    /// MDK's. Each wrapper's own rendering over MDK values that carry a canary
    /// is proved beside its `Debug`, in `nostr::mls::types`.
    #[tokio::test(flavor = "current_thread")]
    async fn an_ok_false_reason_never_reaches_a_log() {
        let relay = ScriptedRelay::start();
        let text = std::sync::Arc::new(Mutex::new(format!("blocked: {CANARY}")));
        let scripted = std::sync::Arc::clone(&text);
        relay.on_publish(move |_| Verdict::Refuse(scripted.lock().expect("script lock").clone()));
        let target = format!("{}/{CANARY}", relay.url());
        let port = relay.url().rsplit(':').next().expect("a port").to_string();
        let transport = RelayManager::new().fanout_transport();

        let mut rendered = Vec::new();
        let lines = capture_log_lines(async {
            let refused = transport.call(&target, &fanout_message()).await;
            assert!(
                classified(&refused)
                    == Some((
                        TransportEndpointFailureKind::TerminalRejected,
                        Some(TransportEndpointRejectionCategory::Blocked)
                    )),
                "three clean refusals are still a proven refusal",
            );
            rendered.push(format!("{refused:?}"));

            *text.lock().expect("script lock") = format!("error: {CANARY}");
            let ambiguous = transport.call(&target, &fanout_message()).await;
            rendered.push(format!("{ambiguous:?}"));

            // Refused by Haven before the hand-over: an unsigned event.
            let unsigned = with_field(&fanout_message(), "sig", None);
            let refused_first = transport.call(&target, &unsigned).await;
            rendered.push(format!("{refused_first:?}"));

            // MDK's client keeps a relay's words out of what it returns. The
            // trait does not promise that, so a client that hands them back —
            // in a failure's reason, in an error's text — is driven too. Its
            // refusal is unproven (nobody heard the relay), its error
            // classifies nothing.
            let wordy = endpoint(&target);
            let quoting = Scripted::answering(move || {
                Err(TransportAdapterError::PublishEndpoints(
                    TransportPublishFailure::with_endpoint_failures(
                        format!("relay said {CANARY}"),
                        vec![TransportEndpointFailure {
                            endpoint: wordy.clone(),
                            reason: format!("blocked: {CANARY}"),
                            kind: TransportEndpointFailureKind::TerminalRejected,
                            rejection_category: Some(TransportEndpointRejectionCategory::Blocked),
                        }],
                    ),
                ))
            });
            let quoted = publish_to_target(
                &quoting,
                &endpoint(&target),
                &fanout_message(),
                None,
                BEFORE_EVERY_SIGNING,
            )
            .await;
            rendered.push(format!("{quoted:?}"));
            let erring = Scripted::answering(|| {
                Err(TransportAdapterError::Publish(format!(
                    "relay said {CANARY}"
                )))
            });
            let errored = publish_to_target(
                &erring,
                &endpoint(&target),
                &fanout_message(),
                None,
                BEFORE_EVERY_SIGNING,
            )
            .await;
            rendered.push(format!("{errored:?}"));
        })
        .await;

        assert!(
            relay.offers() >= 2,
            "the relay was never offered the events, so nothing it said was heard",
        );
        for own_line in [
            "[Fanout] a publish was refused before anything was handed to a relay",
            "[Fanout] a relay's refusal was not proven for every attempt",
            "[Fanout] a relay client's answer classified nothing for its relay",
        ] {
            assert!(
                lines.iter().any(|line| line == own_line),
                "one of the transport's own lines was not captured, so its \
                 silence about the relay means nothing",
            );
        }
        assert!(
            lines
                .iter()
                .any(|line| line.starts_with("[RelayManager] add_relay ")),
            "the registration's line names the relay, by a handle",
        );

        // The canary, and the relay's address: its port is the one part of a
        // loopback URL that tells two relays apart.
        for needle in [CANARY, port.as_str(), "127.0.0.1"] {
            assert!(
                !lines.iter().any(|line| line.contains(needle)),
                "a Haven log line carries what a relay said or what names it",
            );
            assert!(
                !rendered.iter().any(|text| text.contains(needle)),
                "a rendering of what the transport returned carries what a \
                 relay said or what names it",
            );
        }
        assert!(
            rendered.iter().all(|text| text.contains("Failed")),
            "every outcome has to render something for its silence to count",
        );
    }

    // ── Pacing ───────────────────────────────────────────────────────────────

    /// MDK's own host, `marmot-account/src/runtime.rs`, from the checkout
    /// cargo resolved the MDK crates this one links from. Haven does not
    /// depend on that crate; its source ships in the same repository.
    fn mdk_host_source() -> String {
        // For the host alone: the whole graph also needs every other platform's
        // crates, which a cache filled by building the tests for the host lacks.
        let version = std::process::Command::new(env!("CARGO"))
            .arg("-vV")
            .output()
            .expect("run cargo -vV");
        let version = String::from_utf8(version.stdout).expect("cargo -vV is UTF-8");
        let host = version
            .lines()
            .find_map(|line| line.strip_prefix("host: "))
            .expect("cargo names its host");
        let metadata = std::process::Command::new(env!("CARGO"))
            .args(["metadata", "--format-version", "1", "--offline"])
            .args(["--filter-platform", host])
            .current_dir(env!("CARGO_MANIFEST_DIR"))
            .output()
            .expect("run cargo metadata");
        assert!(metadata.status.success(), "cargo metadata failed");
        let metadata: serde_json::Value =
            serde_json::from_slice(&metadata.stdout).expect("cargo metadata JSON");
        let manifest = metadata["packages"]
            .as_array()
            .expect("packages")
            .iter()
            .find(|package| package["name"] == "transport-nostr-adapter")
            .and_then(|package| package["manifest_path"].as_str())
            .expect("the adapter is in the graph");
        let crates = std::path::Path::new(manifest)
            .parent()
            .and_then(std::path::Path::parent)
            .expect("the MDK crates directory");
        std::fs::read_to_string(crates.join("marmot-account/src/runtime.rs"))
            .expect("read MDK's host")
    }

    const SECOND_MS: u64 = 1_000;
    const HOUR_MS: u64 = 3_600 * SECOND_MS;

    /// Where Haven's pacing is MDK's, it is MDK's to the millisecond — read
    /// from MDK's source, so a bump that moves a value fails here — and where
    /// it is Haven's own, the difference is the one the tracker records
    /// (T-ADAPTER-ATTEMPTS).
    #[test]
    fn fanout_pacing_is_mdks_by_value() {
        let source = mdk_host_source();
        for (name, value, ours) in [
            (
                "FROZEN_FANOUT_AMBIGUOUS_RETRY_BASE_MS",
                "30 * 1_000",
                AMBIGUOUS_RETRY_BASE_MS,
            ),
            (
                "FROZEN_FANOUT_AMBIGUOUS_RETRY_MAX_MS",
                "60 * 60 * 1_000",
                RETRY_MAX_MS,
            ),
            (
                "FROZEN_FANOUT_UNAVAILABLE_RETRY_DELAY_MS",
                "5 * 1_000",
                UNAVAILABLE_RETRY_DELAY_MS,
            ),
        ] {
            assert!(
                source.contains(&format!("const {name}: u64 = {value};")),
                "MDK's host no longer paces a fanout by the value Haven copied",
            );
            let product: u64 = value
                .split(" * ")
                .map(|factor| factor.replace('_', "").parse::<u64>().expect("a factor"))
                .product();
            assert_eq!(ours, product);
        }

        // Kept: MDK's wait after an ambiguous answer.
        assert!(
            source.contains("let shift = attempt_count.saturating_sub(1).min(7);")
                && source.contains(".saturating_mul(1_u64 << shift)")
                && source.contains(".min(FROZEN_FANOUT_AMBIGUOUS_RETRY_MAX_MS);"),
            "MDK's rule for a possibly exposed target moved",
        );
        for calls in 1..=12_u32 {
            let mdk = (30 * SECOND_MS)
                .saturating_mul(1 << calls.saturating_sub(1).min(7))
                .min(HOUR_MS);
            assert_eq!(retry_delay_ms(Backoff::Ambiguous, calls, u64::MAX), mdk);
        }
        assert_eq!(
            (1..=8)
                .map(|calls| retry_delay_ms(Backoff::Ambiguous, calls, 0) / SECOND_MS)
                .collect::<Vec<_>>(),
            [30, 60, 120, 240, 480, 960, 1_920, 3_600],
        );

        // NOT kept: MDK retries every unavailable target — an unreachable
        // relay and one that said `rate-limited:` alike — after a flat five
        // seconds, for ever. The day MDK changes that, re-read the difference.
        assert!(
            source.contains("last.saturating_add(FROZEN_FANOUT_UNAVAILABLE_RETRY_DELAY_MS)"),
            "MDK's rule for an unavailable target moved: re-read Haven's difference",
        );
        assert_eq!(
            (1..=12)
                .map(|calls| retry_delay_ms(Backoff::Unreachable, calls, u64::MAX) / SECOND_MS)
                .collect::<Vec<_>>(),
            [5, 5, 5, 30, 60, 120, 240, 480, 960, 1_920, 3_600, 3_600],
            "five seconds for the first three unreachable calls, then doubling \
             from thirty to an hour",
        );
        for seed in [0, 1, 0x1234_5678_9abc_def0, u64::MAX] {
            for calls in 1..=12_u32 {
                let base = (60 * SECOND_MS)
                    .saturating_mul(1 << calls.saturating_sub(1).min(7))
                    .min(HOUR_MS);
                let wait = retry_delay_ms(Backoff::RateLimited, calls, seed);
                assert!(
                    wait >= base && wait <= (base + base / 4).min(HOUR_MS),
                    "a rate-limited relay is left alone for at least a minute, \
                     doubling, stretched by a quarter at most, never past an hour",
                );
            }
        }
        assert!(
            retry_delay_ms(Backoff::RateLimited, 1, 3)
                != retry_delay_ms(Backoff::RateLimited, 1, 4),
            "a rate-limited wait is not spread at all",
        );
    }

    /// When a relay is called, from its first unresolved call on, if every
    /// call ends the way `ends` says for the count so far.
    fn call_times(hours: u64, seed: u64, ends: impl Fn(u32) -> Backoff) -> Vec<u64> {
        let mut times = vec![0_u64];
        let mut calls = 1_u32;
        loop {
            let next = times[times.len() - 1] + retry_delay_ms(ends(calls), calls, seed);
            if next >= hours * HOUR_MS {
                return times;
            }
            times.push(next);
            calls += 1;
        }
    }

    /// The whole of what a relay that keeps failing is sent: ten calls at
    /// most in the hour after the first, one an hour after that — whichever
    /// way each call fails, and in whatever order.
    #[test]
    fn a_failing_relay_is_called_ten_times_in_its_first_hour_and_once_an_hour_after() {
        let quickest = |calls| {
            [
                Backoff::Ambiguous,
                Backoff::Unreachable,
                Backoff::RateLimited,
            ]
            .into_iter()
            .min_by_key(|backoff| retry_delay_ms(*backoff, calls, 0))
            .expect("three")
        };
        let schedules: [(&str, Vec<u64>, usize); 4] = [
            (
                "unreachable",
                call_times(6, 0, |_| Backoff::Unreachable),
                10,
            ),
            ("ambiguous", call_times(6, 0, |_| Backoff::Ambiguous), 7),
            (
                "rate-limited",
                call_times(6, 0, |_| Backoff::RateLimited),
                6,
            ),
            (
                "whichever is soonest each time",
                call_times(6, 0, quickest),
                10,
            ),
        ];
        for (shape, times, first_hour) in schedules {
            assert_eq!(
                times.iter().filter(|at| **at < HOUR_MS).count(),
                first_hour,
                "calls in the first hour when every call ends {shape}",
            );
            let later: Vec<u64> = times.iter().copied().filter(|at| *at >= HOUR_MS).collect();
            assert!(
                later.len() >= 4,
                "premise: the relay is still being tried, hours later"
            );
            assert!(
                later.windows(2).all(|pair| pair[1] - pair[0] >= HOUR_MS),
                "more than one call in an hour, after the first hour ({shape})",
            );
        }
        // Stretched to the limit, a rate-limited relay is called no sooner.
        assert!(call_times(6, u64::MAX, |_| Backoff::RateLimited).len() <= 6 + 5);
        assert!(call_times(1, u64::MAX, |_| Backoff::RateLimited)[1] >= 60 * SECOND_MS);
    }

    /// One call to `relay` for `fanout`, begun at `at_ms` and ended `how`.
    fn failed_call(
        fanout: &mut OutboundFanout,
        relay: &str,
        at_ms: u64,
        how: (
            TransportEndpointFailureKind,
            Option<TransportEndpointRejectionCategory>,
        ),
    ) {
        let endpoints = fanout.request().target.endpoints().to_vec();
        for (index, target) in endpoints.iter().enumerate() {
            if same_relay(target, &endpoint(relay)) {
                fanout
                    .mark_attempt_started_at(index, at_ms)
                    .expect("attempt");
                fanout
                    .record_target_failure(index, failure_of(target.as_str(), how.0, how.1))
                    .expect("the answer is recorded");
            }
        }
    }

    fn relay_url(url: &str) -> RelayUrl {
        RelayUrl::parse(url).expect("a relay url")
    }

    const UNREACHABLE: (
        TransportEndpointFailureKind,
        Option<TransportEndpointRejectionCategory>,
    ) = (TransportEndpointFailureKind::RetryableUnavailable, None);
    const RATE_LIMITED: (
        TransportEndpointFailureKind,
        Option<TransportEndpointRejectionCategory>,
    ) = (
        TransportEndpointFailureKind::RetryableUnavailable,
        Some(TransportEndpointRejectionCategory::RateLimited),
    );
    const AMBIGUOUS: (
        TransportEndpointFailureKind,
        Option<TransportEndpointRejectionCategory>,
    ) = (TransportEndpointFailureKind::PossiblyExposed, None);

    /// A relay is paced by every unresolved call made to it, whichever row
    /// made each: two rows owing one relay do not double what it is sent.
    #[test]
    fn a_relay_is_paced_across_every_row_that_owes_it() {
        let relay = relay_url(RELAY);
        let mut one = staged_fanout(&[RELAY, SECOND]);
        let mut two = staged_fanout(&[RELAY]);
        let due = |one: &OutboundFanout, two: &OutboundFanout| {
            let all = [one.clone(), two.clone()];
            (
                relay_due(&all, one, &relay, u64::MAX),
                relay_due(&all, two, &relay, u64::MAX),
            )
        };
        assert_eq!(due(&one, &two), (RelayDue::Now, RelayDue::Now));

        // Each row's call lengthens the wait for both.
        failed_call(&mut one, RELAY, 1_000, UNREACHABLE);
        assert_eq!(due(&one, &two), (RelayDue::At(6_000), RelayDue::At(6_000)));
        failed_call(&mut two, RELAY, 6_000, UNREACHABLE);
        assert_eq!(due(&one, &two).0, RelayDue::At(11_000));
        failed_call(&mut one, RELAY, 11_000, UNREACHABLE);
        assert_eq!(due(&one, &two).1, RelayDue::At(16_000));
        failed_call(&mut two, RELAY, 16_000, UNREACHABLE);
        assert_eq!(
            due(&one, &two),
            (RelayDue::At(46_000), RelayDue::At(46_000)),
            "the fourth unreachable call to a relay was not followed by the \
             longer wait because the calls were split between two rows",
        );
        // Another relay of the same row is not held back by this one.
        let all = [one.clone(), two.clone()];
        assert_eq!(
            relay_due(&all, &one, &relay_url(SECOND), u64::MAX),
            RelayDue::Now
        );

        // A target that has ended says nothing about the relay any more.
        let index = 0;
        one.mark_attempt_started_at(index, 46_000).expect("attempt");
        one.mark_target_accepted(index).expect("accepted");
        assert_eq!(
            due(&one, &two).1,
            RelayDue::Now,
            "a relay that has since acknowledged an event is still being waited out",
        );
    }

    /// How the most recent unresolved call ended decides the wait, and a
    /// second spelling of the relay in one row is the same call, not another.
    #[test]
    fn the_latest_answer_decides_how_long_a_relay_is_left_alone() {
        let relay = relay_url(RELAY);
        let spelled_twice = "wss://Relay.Example.com:443";
        let mut ambiguous = staged_fanout(&[RELAY, spelled_twice]);
        let mut limited = staged_fanout(&[RELAY]);
        failed_call(&mut ambiguous, RELAY, 10_000, AMBIGUOUS);
        let all = [ambiguous.clone(), limited.clone()];
        assert_eq!(
            relay_due(&all, &limited, &relay, u64::MAX),
            RelayDue::At(10_000 + 30_000),
            "one call under two spellings was counted as two",
        );

        failed_call(&mut limited, RELAY, 50_000, RATE_LIMITED);
        let all = [ambiguous.clone(), limited.clone()];
        let RelayDue::At(at) = relay_due(&all, &ambiguous, &relay, u64::MAX) else {
            panic!("a relay with unresolved calls is not free");
        };
        assert!(
            (50_000 + 120_000..=50_000 + 150_000).contains(&at),
            "after a second unresolved call, a rate limit, the relay was not \
             left alone for two minutes",
        );

        failed_call(&mut ambiguous, RELAY, 400_000, AMBIGUOUS);
        let all = [ambiguous.clone(), limited.clone()];
        assert_eq!(
            relay_due(&all, &limited, &relay, u64::MAX),
            RelayDue::At(400_000 + 120_000),
        );
    }

    /// A call under way for another row keeps its relay to itself — even
    /// from a commit's first drive; one whose drive is gone was never
    /// answered, and counts as the ambiguous outcome it will be recorded as.
    #[test]
    fn a_call_under_way_for_another_row_keeps_its_relay_busy() {
        let relay = relay_url(RELAY);
        let mut calling = staged_fanout(&[RELAY]);
        // A row that has been sent to another relay already: it waits its
        // turn. (One nothing was sent for yet does not: see the first-drive
        // rule.)
        let mut waiting = staged_fanout(&[RELAY, SECOND]);
        waiting.mark_attempt_started_at(1, 6_000).expect("attempt");
        waiting.mark_target_accepted(1).expect("accepted");
        let new = staged_fanout(&[RELAY]);
        calling.mark_attempt_started_at(0, 7_000).expect("attempt");
        let all = [calling.clone(), waiting.clone(), new.clone()];
        let calling_id = FanoutId::new(
            calling.group_id().expect("a group").clone(),
            calling.message_id().clone(),
        );

        let under_way = Driving::claim(&calling_id).expect("the row is free");
        assert_eq!(relay_due(&all, &waiting, &relay, u64::MAX), RelayDue::Busy);
        for row in [&waiting, &new] {
            assert!(
                due_attempts(&all, row, 7_001).0.is_empty(),
                "a second call was made to a relay while one was under way",
            );
        }
        drop(under_way);
        assert_eq!(
            relay_due(&all, &waiting, &relay, u64::MAX),
            RelayDue::At(7_000 + 30_000)
        );
        let (due, retry_after_ms) = due_attempts(&all, &waiting, 7_001);
        assert!(due.is_empty());
        assert_eq!(retry_after_ms, Some(29_999));
        assert_eq!(due_attempts(&all, &waiting, 37_000).0.len(), 1);
    }
}
