//! The group-event processor — the receive engine's ingest loop.
//!
//! For each incoming `kind:445`, the processor feeds the transport message to
//! the Dark Matter engine (`SessionManager::process_event`), which owns
//! convergence, out-of-order sequencing (buffering future-epoch messages), and
//! stale/duplicate rejection. The processor then drains the engine's emitted
//! `GroupEvent`s onto the fan-out bus.
//!
//! The hand-rolled settle-window / regime gate that used to live here is gone
//! (plan §5.3/§5.4): the engine's stored convergence replaces it.
//!
//! # No delivered event ever advances a cursor
//!
//! An inbound event's outer `created_at` is chosen by whoever signed the
//! envelope — a throwaway ephemeral key — and no receive-side check binds it to
//! the inner MLS message the engine authenticates. That is true for EVERY
//! ingest outcome, `Processed` and `Stale` included: the engine's re-wrap dedup
//! is content-derived, so an observer who re-wraps a circle's ciphertext under a
//! fresh key and a `created_at` of its choosing still gets a clean engine
//! verdict. A per-event cursor advance would therefore hand the persisted REQ
//! floor to any relay observer (the `#h` routing tag IS the public
//! `nostr_group_id`).
//!
//! So the advance comes from [`super::anchor`] instead, anchored on the relay's
//! `EOSE`: after end-of-stored-events on a REQ, everything the relay held has
//! been delivered as of the LOCAL instant the REQ was issued. Delivered events
//! contribute in one direction only — an event that could not be APPLIED
//! (engine `Buffered`, or a hard ingest failure) holds that generation's advance
//! at or below its own `created_at`, so it is re-requested.
//!
//! A "future-epoch message is `Buffered`, so the cursor stops at it" rule would
//! not have been enough even if the timestamps were trustworthy: the engine
//! reports a future-epoch APPLICATION message as `TransportDeferred` (it
//! keeps it as a deferred row and re-peels it once the commit lands), not as
//! `Buffered`. `Buffered` is reported when this device's own group state cannot
//! ingest at all — during a publish-before-apply transition — and for a
//! commit taken up for its pass. The EOSE anchor
//! covers both because it does not depend on per-event outcomes.
//!
//! # The inbox plane is the same rule, against a cheaper forgery
//!
//! A `kind:1059` gift wrap is routed by a `#p` tag holding the recipient's
//! PUBLIC key and is authored by a throwaway ephemeral key by construction, and
//! peeling one consults NIP-59 alone — no MLS state, and nothing binding the
//! outer `created_at` to the payload. So minting a wrap that a victim's client
//! peels cleanly, at any `created_at`, costs one NIP-44 encryption to a
//! published npub. The inbox cursor therefore advances on its own REQ's `EOSE`
//! (see [`super::anchor::InboxAnchor`]) and the wrapper timestamp is not even
//! forwarded to the consumer.
//!
//! # Per-circle cursor
//!
//! Each circle gets its own group cursor via `group_445:{hex(nostr_group_id)}`,
//! so a busy circle's cursor advance cannot bury a quiet co-multiplexed
//! circle's un-applied commit.

#![deny(clippy::wildcard_enum_match_arm)]

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use nostr::{Event, JsonUtil, RelayUrl, SubscriptionId};
use tokio::sync::{watch, Notify};
use tokio::time::Instant;

use crate::circle::{CircleManager, DecryptedIngest, DirectoryReconcile};
use crate::log_alias::bucket;
use crate::nostr::mls::types::{
    EpochState, FanoutId, GroupEvent, GroupId, IngestOutcome, LocationMessageResult, PublishWork,
    ScreenedIngest, SessionEffects,
};
use crate::nostr::mls::{ingest_disposition, Disposition, PlaneStanding, SessionManager};
use crate::nostr::NostrError;
pub(super) use crate::relay::fanout::BurstEnd;
use crate::relay::fanout::{
    Counted, DriveMode, FanoutClock, InFlight, ModeSource, Publishing, ResumeOutcome, Still,
    WallClock, BUSY_RETRY_MS, RESUME_BUDGET_MS,
};
use crate::relay::retick::{next_receive_retick, owe_unfinished, MAX_CONVERGENCE_RETICKS};

use super::anchor::{CursorAnchors, InboxAnchor};
use super::drive::{Leash, Leashed, LeashedPublisher, Lifecycle, LifecycleCell, LiveDriver};
use super::event::{LiveSyncEvent, SyncStatusReason};
use super::event_bus::EventBus;
use super::repair::RepairKey;

/// Per-circle group-cursor stream key (a distinct stream per
/// `hex(nostr_group_id)`).
#[must_use]
pub fn group_cursor_stream(group_id_hex: &str) -> String {
    format!("{}:{group_id_hex}", crate::relay::cursor::STREAM_GROUP_445)
}

/// What the processor did with one group event (returned for observability and
/// testing; the bus side effects are already applied).
///
/// **No variant advances a cursor.** The variants say what the ENGINE decided
/// and, through that, whether the event holds its generation's EOSE advance
/// back — see the module docs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupProcessOutcome {
    /// The engine APPLIED the message (`IngestOutcome::Processed`). Nothing is
    /// outstanding at this event's position, so it holds nothing back.
    Applied,
    /// The engine terminally handled the message without applying anything new
    /// (`IngestOutcome::Stale` / `Ignored` / `Rejected` / `LocalState` —
    /// duplicate, stale epoch, not-for-us, refused admission, a removed or
    /// quarantined copy). Holds nothing back: holding here would let one forged
    /// event pin the circle's cursor for the session.
    Stale,
    /// The engine RETAINED an object it cannot yet peel
    /// (`IngestOutcome::TransportDeferred`) and owns its retry: a later epoch
    /// or branch re-peels the stored row (Marmot `transports/nostr.md`,
    /// MDK `traits/src/ingest.rs` `TransportDeferred`). Holds nothing back —
    /// one undecryptable envelope must not pin the circle's cursor.
    Deferred,
    /// The engine refused to keep the object for a LOCAL resource bound
    /// (`IngestOutcome::ResourceRefused`), or kept no durable trace of it
    /// (`IngestEffects::left_object_unpersisted`). Relay redelivery is the only
    /// way back (Rule 12), so it holds this generation's advance at or below
    /// its `created_at` exactly like [`Self::Buffered`].
    Refused,
    /// The engine buffered the message (this device's own group state cannot
    /// ingest right now — a publish-before-apply transition). Un-applied, so it
    /// holds this generation's advance at or below its `created_at`; the engine
    /// also persists it durably, so nothing is lost across a restart.
    Buffered,
    /// The engine answered from a row it holds STRANDED — the event as it
    /// arrived, unopened, in a circle that holds no commit of this device's
    /// own pending — which Haven could not take over to hand back
    /// (`relay::catchup::ReceiveOnlyOutcome::Stranded`). Un-applied, and it
    /// holds nothing back: the answer is the stored row's and no redelivery
    /// changes it. Its circle is told.
    Stranded,
    /// Haven's local receiver-side screen rejected the event BEFORE any MLS
    /// authentication (see [`crate::nostr::mls::types::ScreenedIngest`]) — an
    /// envelope the pure pre-engine transport parse could not read at all.
    /// Nothing was routed and nothing was persisted. It
    /// holds nothing back either: there is no un-applied message to come back
    /// for, and letting it hold would sell an attacker a stall for the price of
    /// one forged event.
    RejectedBeforeAuth,
    /// The engine was not asked ([`NostrError::EngineHeld`]): a commit an
    /// earlier rollback rewound is not yet retired, and no engine call is
    /// made until it is; or the event's circle still holds stranded input
    /// the hand-back has not reached, and nothing new of it is taken ahead.
    /// Nothing about this event was decided — it is not an ingest verdict
    /// and nothing was published or failed — so it holds this generation's
    /// advance at or below its `created_at` and is asked for again.
    Held,
    /// The ENGINE could not ingest the message (hard failure). Treated like
    /// [`Self::Buffered`] for the cursor: something at this position is
    /// unresolved, so it holds the generation back.
    ///
    /// Reaching this means the envelope parsed and the engine took the message —
    /// it is the authenticated path failing, not a screen. An envelope that does
    /// not parse is [`Self::RejectedBeforeAuth`] instead, so an attacker cannot
    /// mint a hold-back here without producing ciphertext the engine will
    /// actually work on.
    Unprocessable,
}

/// When each live REQ last delivered ANYTHING — an event, or the relay's `EOSE`.
///
/// The liveness signal relay connection state cannot give. nostr-relay-pool
/// deletes a subscription on most `CLOSED` reasons and never re-issues it, so a
/// relay can keep the socket open — reading `Connected` to every connectivity
/// check — while the REQ that carried this device's circles no longer exists.
/// The only observable difference is that nothing arrives on it any more.
///
/// Keyed per `(relay, subscription)`, NOT per circle. A REQ is issued to several
/// relays and a repair re-issues to only the one that ended it, so a per-circle
/// clock would let one relay that re-subscribes every few seconds keep the
/// circle's clock fresh while the bucket's OTHER relays sat silent — masking
/// exactly the failure this exists to find.
///
/// Seeded when a subscription is issued, so silence is measured from the REQ and
/// not from process start, and written monotonically so an out-of-order note
/// cannot make a live REQ look silent.
///
/// Presence-only `Debug` (a count, never a relay or a sub-id) per Rules 4/6.
#[derive(Default)]
struct DeliveryLog {
    inner: Mutex<HashMap<RepairKey, i64>>,
}

impl std::fmt::Debug for DeliveryLog {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let len = self
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len();
        f.debug_struct("DeliveryLog")
            .field("reqs", &bucket(len))
            .finish()
    }
}

impl DeliveryLog {
    /// Starts this REQ's silence window at `at_secs` — the instant it was
    /// issued. Overwrites: a new REQ is a new observation window, and what the
    /// previous one delivered says nothing about whether this one is served.
    fn open(&self, key: &RepairKey, at_secs: i64) {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(key.clone(), at_secs);
    }

    /// Records a delivery on an ALREADY-OPEN window.
    ///
    /// Never creates one: a relay must not be able to conjure delivery state for
    /// a REQ this session does not have open.
    fn note(&self, key: &RepairKey, at_secs: i64) {
        if let Some(prev) = self
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_mut(key)
        {
            *prev = (*prev).max(at_secs);
        }
    }

    fn last(&self, key: &RepairKey) -> Option<i64> {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(key)
            .copied()
    }

    /// Drops every relay's window for one subscription (its REQ was closed).
    fn forget_sub(&self, sub_id: &SubscriptionId) {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .retain(|key, _| key.sub_id != *sub_id);
    }
}

/// How long a connected relay may owe a group REQ its `EOSE`.
///
/// Past it the relay is left out of the REQ's coverage, its debt recorded as a
/// floor. The burst's own backlog wait, so a burst and the foreground give a
/// relay the same time.
pub const EOSE_WAIT: Duration = Duration::from_secs(super::config::BURST_BACKLOG_WAIT_SECS);

/// The least time, on the driver's clock, between two network returns that
/// each make every unreachable relay of a pending record due at once
/// ([`EngineProcessor::network_back`]).
pub const NETWORK_BACK_FLOOR_MS: u64 = 60_000;

/// Which relays each live GROUP REQ still owes an `EOSE`, before the circles it
/// multiplexes may redeem their one cursor advance.
///
/// # The hole this closes
///
/// A bucket REQ is one filter issued to SEVERAL relays, while a circle has a
/// SINGLE cursor generation ([`super::anchor::CursorAnchors`]). Redeeming that
/// generation on the FIRST relay's `EOSE` advances the persisted cursor to the
/// REQ's open time on the word of a relay that may hold none of the window: a
/// co-bucketed relay still replaying — possibly the only one holding a peer's
/// event — has vouched for nothing. In the foreground the REQ stays open, so the
/// slow relay's replay still lands and only the cursor is optimistic; in a
/// background burst the socket CLOSES seconds later, the next burst's floor is
/// derived from that advanced cursor minus
/// [`crate::relay::cursor::GROUP_RESUBSCRIBE_BUFFER_SECS`] (60 s), and an event
/// older than that is never asked for again by any burst or catch-up sweep.
///
/// So the advance waits for every relay that accepted the REQ while CONNECTED.
/// Any other relay the REQ was issued to — one that refused it, or one the pool
/// only queued it for because it was not connected — is left out, and so is a
/// connected relay still owing an `EOSE` past [`EOSE_WAIT`] (released at a
/// burst's backlog wait, by the repair task's timer, or at a health tick;
/// one relay's re-issue leaves the others owing what they owed): each such relay
/// is recorded as owing the circle's history from the `since` it was asked
/// (`relay_floors`), and the next REQ to it asks from there until it has
/// answered one that reached back that far (Security Rule 12). A relay that
/// ends the REQ with `CLOSED` never appears in `seen`; it is released at the
/// same bound, with the same floor. A silent or unreachable relay therefore
/// delays an advance by at most the bound and loses the circle nothing it
/// held.
///
/// Presence-only `Debug` (a count, never a relay or a sub-id) per Rules 4/6.
#[derive(Default)]
struct EoseCoverage {
    inner: Mutex<HashMap<SubscriptionId, Coverage>>,
}

/// One REQ's coverage: who owes an `EOSE`, who has sent one, the `since`
/// each relay was asked from, and when the REQ was first issued.
#[derive(Debug)]
struct Coverage {
    expected: HashSet<RelayUrl>,
    seen: HashSet<RelayUrl>,
    since: HashMap<RelayUrl, i64>,
    issued: Instant,
}

impl Default for Coverage {
    fn default() -> Self {
        Self {
            expected: HashSet::new(),
            seen: HashSet::new(),
            since: HashMap::new(),
            issued: Instant::now(),
        }
    }
}

impl Coverage {
    fn complete(&self) -> bool {
        self.expected.iter().all(|relay| self.seen.contains(relay))
    }
}

impl std::fmt::Debug for EoseCoverage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let len = self
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len();
        f.debug_struct("EoseCoverage")
            .field("reqs", &bucket(len))
            .finish()
    }
}

impl EoseCoverage {
    /// Sets which of the `issued` relays owe this REQ an `EOSE` — `owing` —
    /// leaving what has already been seen alone, and every relay of the REQ
    /// that was not re-issued as it was: a single relay's re-issue must not
    /// drop a co-bucketed relay that is still replaying (Security Rule 12).
    ///
    /// Called TWICE per issue: once with `owing` the relays the REQ is issued
    /// to (so an `EOSE` racing the subscribe call cannot redeem an empty
    /// expectation), and once with the subset that accepted it while connected
    /// (so a relay that refused the REQ, or that the pool only queued it for,
    /// cannot pin the cursor). Each call restarts the [`EOSE_WAIT`]. `seen` is
    /// NOT reset here — that happens per endpoint in
    /// [`EngineProcessor::open_delivery_window`], because an answer landing
    /// between the two calls is a real answer to this generation.
    ///
    /// Whether this call completed the REQ: it was owed an `EOSE`, and now
    /// every relay it still expects, at least one, has answered. No further
    /// `EOSE` will redeem that advance, so the caller does.
    fn expect(&self, sub_id: &SubscriptionId, issued: &[RelayUrl], owing: &[RelayUrl]) -> bool {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let coverage = inner.entry(sub_id.clone()).or_default();
        let was_complete = coverage.complete();
        coverage.expected.retain(|relay| !issued.contains(relay));
        coverage.expected.extend(owing.iter().cloned());
        coverage.issued = Instant::now();
        let completed = !was_complete && !coverage.expected.is_empty() && coverage.complete();
        drop(inner);
        completed
    }

    /// Forgets one endpoint's answer: its REQ is being re-issued, so the
    /// previous generation's `EOSE` says nothing about this one.
    fn reopen(&self, key: &RepairKey) {
        if let Some(coverage) = self
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_mut(&key.sub_id)
        {
            coverage.seen.remove(&key.relay_url);
        }
    }

    /// Records `key`'s `EOSE` and answers whether every relay that owes one has
    /// now sent it.
    ///
    /// Permissive for a subscription with no recorded expectation: the router
    /// resolved this REQ, so the session issued it, and refusing to ever advance
    /// on a bookkeeping gap would wedge the cursor rather than protect it.
    fn note(&self, key: &RepairKey) -> bool {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let covered = inner.get_mut(&key.sub_id).is_none_or(|coverage| {
            coverage.seen.insert(key.relay_url.clone());
            coverage.complete()
        });
        drop(inner);
        covered
    }

    /// Records the `since` `key`'s relay was asked from.
    fn asked_from(&self, key: &RepairKey, since_secs: i64) {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entry(key.sub_id.clone())
            .or_default()
            .since
            .insert(key.relay_url.clone(), since_secs);
    }

    /// The `since` `key`'s relay was last asked from.
    fn since_of(&self, key: &RepairKey) -> Option<i64> {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&key.sub_id)
            .and_then(|coverage| coverage.since.get(&key.relay_url).copied())
    }

    /// When the first REQ still owed an `EOSE` will have waited `bound`.
    fn next_release(&self, bound: Duration) -> Option<Instant> {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .filter(|coverage| !coverage.complete())
            .map(|coverage| coverage.issued + bound)
            .min()
    }

    /// Starts `sub_id`'s wait again, for a relay kept in its coverage.
    fn restart(&self, sub_id: &SubscriptionId) {
        if let Some(coverage) = self
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_mut(sub_id)
        {
            coverage.issued = Instant::now();
        }
    }

    /// Every endpoint that still owes an `EOSE` to a REQ issued `bound` ago
    /// or longer, with the `since` its relay was asked from.
    fn owing_past(&self, bound: Duration) -> Vec<(RepairKey, i64)> {
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let mut owing = Vec::new();
        for (sub_id, coverage) in inner.iter() {
            if coverage.issued.elapsed() < bound {
                continue;
            }
            for relay in coverage.expected.difference(&coverage.seen) {
                let since = coverage.since.get(relay).copied().unwrap_or(0);
                owing.push((
                    RepairKey {
                        relay_url: relay.clone(),
                        sub_id: sub_id.clone(),
                    },
                    since,
                ));
            }
        }
        drop(inner);
        owing
    }

    /// Moves every REQ's issue back by `by`, as that much time passing would.
    #[cfg(any(test, feature = "test-utils"))]
    fn age(&self, by: Duration) {
        for coverage in self
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values_mut()
        {
            coverage.issued = coverage.issued.checked_sub(by).unwrap_or(coverage.issued);
        }
    }

    /// Forgets every REQ's coverage.
    fn clear(&self) {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clear();
    }

    /// Takes `key`'s relay out of its REQ's coverage, and answers whether
    /// every relay still in it has now answered.
    fn release(&self, key: &RepairKey) -> bool {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let covered = inner.get_mut(&key.sub_id).is_some_and(|coverage| {
            coverage.expected.remove(&key.relay_url);
            coverage.complete()
        });
        drop(inner);
        covered
    }

    /// Drops one subscription's coverage (its REQ was closed).
    fn forget_sub(&self, sub_id: &SubscriptionId) {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(sub_id);
    }
}

/// What a background burst's backlog wait observed.
///
/// Presence-only by construction — it names no relay, subscription or circle —
/// so a caller may surface it as a health counter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[must_use = "a TimedOut backlog wait means the burst is about to publish at a \
              possibly stale epoch; discarding it reports a settle that did not happen"]
pub enum BacklogOutcome {
    /// Every `(relay, subscription)` endpoint this burst issued answered — an
    /// `EOSE` (the relay handed over everything it stored) or a `CLOSED` (it
    /// will hand over nothing more). Because the ingest worker is SERIAL, a
    /// settled endpoint means every stored event that relay sent ahead of the
    /// answer has already been ingested and converged.
    Settled,
    /// The wait's budget elapsed with at least one endpoint still silent. The
    /// burst proceeds anyway — exactly as the foreground does with a slow REQ —
    /// so the location it publishes may be encrypted one epoch behind. Peers
    /// decrypt that from past-epoch keys and the next burst converges it.
    ///
    /// It leaves no cursor advance standing either, and that is a separate
    /// mechanism rather than a consequence of this one: a circle's advance is
    /// redeemed only once every relay that accepted its REQ has EOSE'd
    /// ([`EngineProcessor::note_eose_endpoint`]), so the window the silent
    /// endpoint never served is re-requested by the next burst.
    ///
    /// The session-level wait answers this for one more case, and it means the
    /// same thing to the caller: NO burst window is open (the open failed, or a
    /// pause has since closed every REQ), so nothing replayed and nothing may
    /// claim it did.
    TimedOut,
}

/// The least the session's drive task sleeps before a drive it wakes for
/// itself: what a drive answers when a relay it wanted was not free.
const DRIVE_TIMER_FLOOR_MS: u64 = BUSY_RETRY_MS;

/// One REQ's held events, each with the routing id it came under.
pub(super) type StoredBatch = Vec<(Vec<u8>, Event)>;

/// The stored events the live group REQs have sent and the worker holds:
/// each REQ's in arrival order, with the routing id it came under. No
/// formatter: it holds events, routing ids and subscription ids.
#[derive(Default)]
pub(super) struct StoredReplay {
    by_req: HashMap<SubscriptionId, StoredBatch>,
    /// The circles each REQ holds events of, each held unread on the
    /// session meanwhile ([`SessionManager::holds_unread_input`]).
    circles: HashMap<SubscriptionId, HashSet<GroupId>>,
    held: usize,
    bytes: usize,
}

/// What [`StoredReplay::hold`] answers.
pub(super) struct Held {
    /// How many events are held in all.
    pub count: usize,
    /// How many bytes of their content.
    pub bytes: usize,
    /// The circle the REQ began holding with this event, if it did.
    pub began: Option<GroupId>,
}

impl StoredReplay {
    /// Holds `event` for `sub_id`, of the circle `group` when it is known.
    pub(super) fn hold(
        &mut self,
        sub_id: &SubscriptionId,
        routing_id: Vec<u8>,
        event: Event,
        group: Option<GroupId>,
    ) -> Held {
        self.bytes += event.content.len();
        self.by_req
            .entry(sub_id.clone())
            .or_default()
            .push((routing_id, event));
        self.held += 1;
        let began = group.filter(|group| {
            self.circles
                .entry(sub_id.clone())
                .or_default()
                .insert(group.clone())
        });
        Held {
            count: self.held,
            bytes: self.bytes,
            began,
        }
    }

    /// Takes what `sub_id` holds, or what every REQ holds, with the circles
    /// they held.
    pub(super) fn take(
        &mut self,
        sub_id: Option<&SubscriptionId>,
    ) -> (Vec<StoredBatch>, Vec<GroupId>) {
        let (taken, circles): (Vec<StoredBatch>, Vec<GroupId>) = match sub_id {
            Some(sub_id) => (
                self.by_req.remove(sub_id).into_iter().collect(),
                self.circles.remove(sub_id).into_iter().flatten().collect(),
            ),
            None => (
                self.by_req.drain().map(|(_, batch)| batch).collect(),
                self.circles.drain().flat_map(|(_, held)| held).collect(),
            ),
        };
        self.held -= taken.iter().map(Vec::len).sum::<usize>();
        self.bytes -= taken
            .iter()
            .flatten()
            .map(|(_, event)| event.content.len())
            .sum::<usize>();
        (taken, circles)
    }
}

/// The receive engine's group/inbox event processor.
///
/// Holds the single MLS-state owner ([`CircleManager`], whose one process-global
/// [`SessionManager`] satisfies Rule 14) and the fan-out bus.
pub struct EngineProcessor {
    circle: Arc<CircleManager>,
    /// This plane's number among the planes of the process.
    plane: u64,
    bus: EventBus,
    /// Per-circle cursor anchors: one of the only two things in this module that
    /// may move a sync cursor forward, and it moves it to a local clock reading.
    anchors: CursorAnchors,
    /// The inbox (`kind:1059`) cursor anchor — the other one, and likewise a
    /// local clock reading. A gift wrap's own `created_at` reaches it in no
    /// direction; see [`InboxAnchor`].
    inbox_anchor: InboxAnchor,
    /// Per-REQ delivery liveness — the signal `RelayStatus` cannot give.
    delivery: DeliveryLog,
    /// `(relay, subscription)` endpoints whose stored replay is finished for the
    /// CURRENT generation: the relay sent an `EOSE`, or ended the REQ with a
    /// `CLOSED`. Cleared for an endpoint the moment its REQ is re-issued
    /// ([`Self::open_delivery_window`]), so a burst can never inherit the
    /// previous burst's answers.
    ///
    /// Per ENDPOINT, not per circle. A bucket REQ goes to several relays and
    /// [`CursorAnchors::note_eose`] consumes the circle's single generation on
    /// the FIRST relay's `EOSE` — while a slower relay, possibly the only one
    /// holding a peer's commit, is still replaying. A per-circle wait would call
    /// that burst settled and encrypt one epoch behind.
    settled_endpoints: Mutex<HashSet<RepairKey>>,
    /// Endpoints released from their REQ's coverage in the current
    /// generation ([`Self::release_from_coverage`]): what they send is no
    /// longer held as stored replay.
    released_endpoints: Mutex<HashSet<RepairKey>>,
    /// What each live group REQ's endpoints have sent ahead of their
    /// `EOSE`s, held to be ordered and taken in as one batch
    /// ([`super::supervisor::flush_stored`]). An async lock, held across the
    /// whole of a flush, so an `EOSE` that finds its REQ's batch taken waits
    /// for that batch's ingest before it anchors.
    pub(super) stored: tokio::sync::Mutex<StoredReplay>,
    /// Fired whenever an endpoint settles, so [`Self::wait_backlog_settled`]
    /// parks instead of polling.
    eose_notify: Notify,
    /// Fired whenever a group REQ's coverage is set
    /// ([`Self::coverage_changed`]).
    coverage_changed: Notify,
    /// Which relays each live GROUP REQ still owes an `EOSE` before its circles
    /// may advance their cursors. See [`EoseCoverage`].
    eose_coverage: EoseCoverage,
    /// The relay calls of this plane's passes under way: a drive's, each
    /// from just before its mark to its answer, and a NIP-77 pass's, from
    /// its dial to its end.
    ///
    /// Counted BEFORE the call reads the lifecycle, and given back by a drop
    /// guard. A pause MUST NOT close a socket while this is non-zero: a
    /// commit between SEND and OK would be cut, stored possibly exposed
    /// (Security Rule 13). Only the calls: a pass stalled in local work
    /// holds no pause, and so no lifecycle lock.
    in_flight: InFlight,
    /// The drive and NIP-77 passes under way, each from its start to its
    /// end: what a settle waits for, within the wake, so a confirm due on an
    /// answer just in is made before the pause ends the pass's lifecycle.
    passes: InFlight,
    /// Which lifecycle the session is serving ([`Lifecycle`]).
    ///
    /// Written by [`super::LiveSyncCore`]: from the typed `BurstKind` every
    /// open decides, by `start`, by a pause and a stop, and by a claim. It
    /// is the ONLY input to how this processor takes in what the engine
    /// hands it — recorded and driven, or settled with no commit made — and
    /// to whether and how it drives what is stored, so "a background burst makes no commit" is a
    /// state read rather than a convention: one processor serves every
    /// lifecycle over the same engine, and nothing else about a burst
    /// distinguishes them.
    lifecycle: LifecycleCell,
    /// What the session's drives are sent through. `None` for a processor
    /// with no transport: in the foreground it still records what it
    /// stages, and leaves each record for a plane that has one.
    driver: Option<LiveDriver>,
    /// The owning session's cancellation, so a drive gives its relays up
    /// when the session is stopped.
    halt: Option<watch::Receiver<bool>>,
    /// Fired when a drive is wanted; the session's drive task parks on it.
    drive_wanted: Notify,
    /// Whether an open has happened since the worker last came back for the
    /// advance a convergence drain handed back ([`Self::owe_come_back`]).
    come_back_owed: AtomicBool,
    /// Whether a foreground entry is owed its one NIP-77 pass
    /// ([`Self::owe_negentropy`]).
    negentropy_owed: AtomicBool,
    /// How many foreground passes the drive task has begun waiting for, and
    /// how many it has then run or given up (tests only).
    #[cfg(any(test, feature = "test-utils"))]
    negentropy_steps: (AtomicUsize, AtomicUsize),
    /// Whether the drive task may be taking or running an entry's pass, and
    /// its signal when that turn ends (tests only).
    #[cfg(any(test, feature = "test-utils"))]
    entry_pass_turn: (AtomicBool, Notify),
    /// Proposals staged in the foreground that no record could be written
    /// for, each awaiting its one publish by the next drive.
    unrecorded: Mutex<Vec<Event>>,
    /// How long after the last drive there is next something to do for a
    /// stored record, as that drive reported it. Relative, and never logged.
    drive_retry_after_ms: Mutex<Option<u64>>,
    /// The instant, on the driver's clock, at which the last drive's hint
    /// falls due: what the session's drive task sleeps to.
    drive_due_at_ms: Mutex<Option<u64>>,
    /// When, on the driver's clock, a network return last made the relays a
    /// pending record could not reach due again ([`Self::network_back`]).
    network_woken_at_ms: Mutex<Option<u64>>,
    /// How many engine deadlines this processor has waited out in its
    /// convergence drains: the bound on what one event or one drive can make
    /// it wait, observable.
    reticks: AtomicUsize,
    /// How many commit-shaped things this processor has observed since the
    /// counter was last reset, and when the last one was.
    ///
    /// "Commit activity" is a roster/epoch change routed by
    /// [`Self::route_events`] (`GroupUpdate`) or a commit the foreground
    /// recorded ([`Self::resolve`]) — the engine has no `EpochChanged`
    /// variant, so those two are the observable surface.
    /// `None` means "nothing has committed since the reset", which is what lets
    /// a settle pay zero.
    commit_activity: Mutex<CommitActivity>,
    /// The group events the worker has taken in, held or ingested, in the
    /// order they arrived.
    #[cfg(any(test, feature = "test-utils"))]
    taken_in: Mutex<Vec<nostr::EventId>>,
}

/// A plane that is gone holds no legacy send back — its own hold, never one
/// a plane made after it has raised.
impl Drop for EngineProcessor {
    fn drop(&mut self) {
        self.circle
            .session()
            .plane_stands(self.plane, PlaneStanding::Gone);
        self.circle.session().burst_ends(self.plane, None);
    }
}

/// Numbers the planes of this process in the order they are made
/// ([`SessionManager::plane_stands`]).
static PLANES: AtomicU64 = AtomicU64::new(1);

/// Commit-shaped activity observed since the last reset — a burst's own when a
/// burst opened, the foreground session's when none did.
#[derive(Debug, Clone, Copy, Default)]
struct CommitActivity {
    /// How many commit-shaped events have been observed since the last reset.
    count: u64,
    /// When the last one was observed, on the runtime clock (so a virtual-clock
    /// test drives the same code the burst does).
    last_at: Option<Instant>,
}

impl EngineProcessor {
    /// Creates a processor over the shared MLS state and bus, with NO relay
    /// plane: in the foreground it still records what it stages, and leaves
    /// each record for a plane that drives. For tests: a session builds its
    /// processor with [`Self::with_driver`].
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn new(circle: Arc<CircleManager>, bus: EventBus) -> Self {
        Self::assemble(circle, bus, None)
    }

    fn assemble(circle: Arc<CircleManager>, bus: EventBus, driver: Option<LiveDriver>) -> Self {
        Self {
            circle,
            plane: PLANES.fetch_add(1, Ordering::SeqCst),
            bus,
            anchors: CursorAnchors::default(),
            inbox_anchor: InboxAnchor::default(),
            delivery: DeliveryLog::default(),
            settled_endpoints: Mutex::new(HashSet::new()),
            released_endpoints: Mutex::new(HashSet::new()),
            stored: tokio::sync::Mutex::new(StoredReplay::default()),
            eose_notify: Notify::new(),
            coverage_changed: Notify::new(),
            eose_coverage: EoseCoverage::default(),
            in_flight: InFlight::default(),
            passes: InFlight::default(),
            lifecycle: LifecycleCell::new(),
            driver,
            halt: None,
            drive_wanted: Notify::new(),
            come_back_owed: AtomicBool::new(false),
            negentropy_owed: AtomicBool::new(false),
            #[cfg(any(test, feature = "test-utils"))]
            negentropy_steps: (AtomicUsize::new(0), AtomicUsize::new(0)),
            #[cfg(any(test, feature = "test-utils"))]
            entry_pass_turn: (AtomicBool::new(false), Notify::new()),
            unrecorded: Mutex::new(Vec::new()),
            drive_retry_after_ms: Mutex::new(None),
            drive_due_at_ms: Mutex::new(None),
            network_woken_at_ms: Mutex::new(None),
            reticks: AtomicUsize::new(0),
            commit_activity: Mutex::new(CommitActivity::default()),
            #[cfg(any(test, feature = "test-utils"))]
            taken_in: Mutex::new(Vec::new()),
        }
    }

    /// Creates a processor whose stored records are sent through `driver`.
    #[must_use]
    pub fn with_driver(circle: Arc<CircleManager>, bus: EventBus, driver: LiveDriver) -> Self {
        Self::assemble(circle, bus, Some(driver))
    }

    /// Opens a fresh cursor-anchor generation for `group_id_hex`, anchored at
    /// `opened_at_secs` — a LOCAL wall-clock reading taken when that circle's REQ
    /// was (re-)issued.
    ///
    /// The session MUST call this for every circle of every REQ it issues, before
    /// or as it issues it. Passing an open time EARLIER than the actual REQ is
    /// safe (it claims less); passing a later one is not, so callers reuse the
    /// same `now` they derived the REQ's `since` from.
    ///
    /// A circle with no open generation never advances its cursor — which is why
    /// a bare processor with no session wired is inert on the cursor.
    pub fn note_subscription_opened(&self, group_id_hex: &str, opened_at_secs: i64) {
        self.anchors.open_generation(group_id_hex, opened_at_secs);
    }

    /// Records the relay's end-of-stored-events for `group_id_hex` and advances
    /// that circle's persisted cursor to what the generation justifies.
    ///
    /// Returns whether an advance was issued (`false` when no generation is open
    /// or this generation already advanced). Best-effort: a storage failure is
    /// swallowed, because the cursor is an optimization and dropping the EOSE
    /// signal must never cost a delivered event.
    ///
    /// # Why EOSE and not the event
    ///
    /// EOSE is the relay saying "that was everything I had for this REQ". Paired
    /// with the local instant the REQ was issued, it is the only completeness
    /// claim this plane can make that no remote party can write. See the module
    /// docs.
    ///
    /// # Why ONE relay's EOSE is not enough to call it
    ///
    /// A bucket REQ goes to several relays and the circle has one generation, so
    /// the caller must first establish that every relay which accepted the REQ
    /// has answered — [`Self::note_eose_endpoint`]. One relay's `EOSE` is one
    /// relay's completeness claim; it says nothing about the window a slower
    /// co-bucketed relay is still replaying.
    pub fn note_end_of_stored_events(&self, group_id_hex: &str) -> bool {
        let now_secs = chrono::Utc::now().timestamp();
        let Some(ms) = self.anchors.note_eose(group_id_hex, now_secs) else {
            return false;
        };
        let _ = self
            .circle
            .advance_sync_cursor(&group_cursor_stream(group_id_hex), ms);
        true
    }

    /// Forgets every circle's caught-up mark: the plane that made them has
    /// paused or stopped, and stops hearing.
    pub fn drop_caught_up_marks(&self) {
        self.circle.session().forget_caught_up(None);
    }

    /// Forgets that the circle routed by `group_id_hex` is caught up: a REQ is
    /// being issued for it again — a reconnect, a repair, a change of its
    /// relays — and only that REQ's own end of stored events says so again.
    pub fn forget_caught_up(&self, group_id_hex: &str) {
        if let Some(ngid) = hex::decode(group_id_hex)
            .ok()
            .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
        {
            self.circle.forget_caught_up(&ngid);
        }
    }

    /// [`Self::note_caught_up`] again for the circle routed by `group_id_hex`
    /// when its own REQ has answered to its end: another id of the circle's,
    /// which it waited on, is no longer listed.
    pub fn recheck_caught_up(&self, group_id_hex: &str) {
        if self.anchors.answered(group_id_hex) {
            self.note_caught_up(group_id_hex);
        }
    }

    /// Records the circle routed by `group_id_hex` as caught up: every relay
    /// its subscription was issued to has sent its end of stored events, and
    /// so has every other REQ open for one of the circle's routing ids.
    pub fn note_caught_up(&self, group_id_hex: &str) {
        if let Some(ngid) = hex::decode(group_id_hex)
            .ok()
            .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
        {
            self.circle
                .note_caught_up(&ngid, |hex| self.anchors.awaits_eose(hex));
        }
    }

    /// Records which of the `issued` relays owe this GROUP REQ an `EOSE`
    /// before the circles it multiplexes may redeem their cursor advance; the
    /// REQ's other relays keep what they owed (see [`EoseCoverage`]).
    pub fn expect_eose_from(
        &self,
        sub_id: &SubscriptionId,
        issued: &[RelayUrl],
        owing: &[RelayUrl],
    ) {
        self.eose_coverage.expect(sub_id, issued, owing);
        self.coverage_changed.notify_waiters();
    }

    /// [`Self::expect_eose_from`], narrowing `issued` to `covering`, the relays
    /// that accepted the REQ while connected. Whether that completed the REQ:
    /// an `EOSE` that landed before the narrowing then redeems nothing by
    /// itself, and the caller redeems its circles' advance.
    #[must_use]
    pub fn narrow_eose_to(
        &self,
        sub_id: &SubscriptionId,
        issued: &[RelayUrl],
        covering: &[RelayUrl],
    ) -> bool {
        let completed = self.eose_coverage.expect(sub_id, issued, covering);
        self.coverage_changed.notify_waiters();
        completed
    }

    /// When the first group REQ still owed an `EOSE` will have waited out
    /// [`EOSE_WAIT`]: the foreground's release is due then.
    pub fn eose_wait_ends(&self) -> Option<std::time::Instant> {
        self.eose_coverage
            .next_release(EOSE_WAIT)
            .map(Instant::into_std)
    }

    /// Starts `sub_id`'s [`EOSE_WAIT`] again: a relay whose debt could not be
    /// written stays in its coverage, and is not tried again at once.
    pub fn restart_eose_wait(&self, sub_id: &SubscriptionId) {
        self.eose_coverage.restart(sub_id);
    }

    /// Completes when a group REQ's coverage was set, or the session was
    /// modelled ([`Self::note_modelled`]): either can bring
    /// [`Self::eose_wait_ends`] forward for the repair task. Armed when made,
    /// so a change between the read it guards and the wait is not lost.
    pub(super) fn coverage_changed(
        &self,
    ) -> std::pin::Pin<Box<tokio::sync::futures::Notified<'_>>> {
        let mut changed = Box::pin(self.coverage_changed.notified());
        changed.as_mut().enable();
        changed
    }

    /// Wakes whoever waits on [`Self::coverage_changed`]: the session that
    /// owns the REQs is modelled now, so a release that waited on it may be
    /// armed.
    pub(super) fn note_modelled(&self) {
        self.coverage_changed.notify_waiters();
    }

    /// Records one endpoint's `EOSE` and answers whether every relay that
    /// accepted this REQ has now finished its stored replay — the only condition
    /// under which [`Self::note_end_of_stored_events`] may be called.
    #[must_use]
    pub fn note_eose_endpoint(&self, key: &RepairKey) -> bool {
        self.eose_coverage.note(key)
    }

    /// Records the `since` `key`'s relay was asked from: an `EOSE` it later
    /// sends vouches for the circle's history from there.
    pub fn note_asked_from(&self, key: &RepairKey, since_secs: i64) {
        self.eose_coverage.asked_from(key, since_secs);
    }

    /// Ends what `key`'s relay owed each of `group_ids_hex` back to the `since`
    /// it was asked: its `EOSE` vouches for their history from there.
    pub fn settle_floors<'a>(
        &self,
        key: &RepairKey,
        group_ids_hex: impl Iterator<Item = &'a String>,
    ) {
        if let Some(since) = self.asked_from(key) {
            for hex in group_ids_hex {
                self.circle
                    .clear_relay_floor(hex, key.relay_url.as_str(), since);
            }
        }
    }

    /// The `since` `key`'s relay was last asked from, if this REQ recorded one.
    #[must_use]
    pub fn asked_from(&self, key: &RepairKey) -> Option<i64> {
        self.eose_coverage.since_of(key)
    }

    /// Every endpoint still owing an `EOSE` to a REQ issued [`EOSE_WAIT`] ago
    /// or longer, with the `since` its relay was asked from.
    #[must_use]
    pub fn eose_owing_past_the_wait(&self) -> Vec<(RepairKey, i64)> {
        self.eose_coverage.owing_past(EOSE_WAIT)
    }

    /// Has every REQ issued so far waited out [`EOSE_WAIT`], as that much
    /// time passing would.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn pass_the_eose_wait_for_test(&self) {
        self.eose_coverage.age(EOSE_WAIT);
    }

    /// Forgets what every group REQ owed: a pause has ended them all, and
    /// nothing they owed may be released after it. Their generations were
    /// never redeemed, so the next open asks from the stored cursor.
    pub(super) fn clear_eose_coverage(&self) {
        self.eose_coverage.clear();
    }

    /// Treats what `key`'s relay sends as never stored replay: it was left
    /// out of its REQ's coverage with its debt recorded, so no `EOSE` or
    /// release of it is waited for.
    pub(super) fn leave_out_of_stored_replay(&self, key: &RepairKey) {
        self.released_endpoints
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(key.clone());
    }

    /// Takes `key`'s relay out of its REQ's coverage — its debt is recorded
    /// as a floor by the caller — and answers whether every relay still in it
    /// has answered, which is when its circles may advance.
    #[must_use]
    pub fn release_from_coverage(&self, key: &RepairKey) -> bool {
        self.released_endpoints
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(key.clone());
        self.eose_coverage.release(key)
    }

    /// Drops a circle's anchor after its subscription is closed, so a later
    /// stray EOSE cannot advance a cursor for a circle we no longer follow.
    pub fn forget_subscription(&self, group_id_hex: &str) {
        self.anchors.forget(group_id_hex);
    }

    /// Records a `kind:445` the receive path dropped BEFORE the engine saw it —
    /// the Rule-12 intake queue ([`super::config::WORKER_QUEUE_CAP`]) was full —
    /// holding `group_id_hex`'s generation at or below `created_at_secs`.
    ///
    /// This is what makes the intake cap a throttle instead of a discard.
    /// Without it the dropped event leaves no trace, this generation's `EOSE`
    /// advances the persisted cursor over it, and — because the catch-up sweep
    /// derives its floor from that same cursor — nothing ever asks for it again.
    /// Overflow happens precisely while a relay is replaying an offline backlog,
    /// so that loss would be the one Rule 12 names.
    ///
    /// Cursor-safe in the same sense as every other hold-back: it can only lower
    /// this generation's advance, never raise it, and the cursor write is
    /// monotonic-max — so a flooder buys a re-fetch of a window we already hold,
    /// never a skip (see [`super::anchor`]). Sustained, that re-fetch repeats:
    /// for as long as a relay's stored replay can still overflow the queue, the
    /// cursor does not advance past it. Deliberate, and the same trade the
    /// catch-up sweep already makes on a window it could not drain — a stall
    /// costs bandwidth, a skip costs the backlog.
    pub fn note_dropped_before_ingest(&self, group_id_hex: &str, created_at_secs: i64) {
        self.anchors.note_unapplied(group_id_hex, created_at_secs);
    }

    /// Records that the receive path's notification stream SKIPPED an unknown
    /// set of deliveries, suppressing the pending advance of every subscription
    /// generation open at that moment — group buckets and the inbox alike.
    ///
    /// The coarse counterpart to [`Self::note_dropped_before_ingest`], for the
    /// loss that cannot be attributed: a skip is reported as a COUNT, so there
    /// is no `created_at` to hold at and no `#h` to hold, and the open
    /// generations' `EOSE`s would otherwise advance their cursors over events
    /// this process never saw — the Rule-12 loss again, one layer above the
    /// intake cap and just as permanent (the catch-up sweep re-derives its floor
    /// from the same per-circle cursor).
    ///
    /// One notification stream carries both planes, so the ignorance spans both;
    /// it also spans any generation opened between the skip and its observation,
    /// which the receive loop cannot order against it. Being wider than
    /// necessary here costs a re-fetch; being narrower costs the backlog.
    ///
    /// Writes no cursor at all, so it can only stall an advance, never lower
    /// one, and each suppression is scoped to the generation it hits. A party
    /// that could sustain a skip therefore buys a repeated re-fetch of a window
    /// we already hold, never a skip and never a wedge.
    ///
    /// What it cannot do is un-ISSUE an advance: the cursor is monotonic by
    /// design (lowering one on remotely-triggered input is the primitive P0-5
    /// removed), so a skipped event backdated below a cursor that moved before
    /// the skip is re-requested only by the next REQ's lookback — a minute on a
    /// group bucket, and on the inbox seven days while no cursor is persisted
    /// (`INBOX_GIFTWRAP_LOOKBACK_SECS`) or 96 hours once one is
    /// (`INBOX_RESUBSCRIBE_LOOKBACK_SECS`), whichever phase issued it.
    pub fn note_delivery_gap(&self) {
        self.anchors.suppress_open_generations();
        self.inbox_anchor.suppress_open_generation();
    }

    /// Opens a fresh INBOX cursor-anchor generation at `opened_at_secs` — a
    /// LOCAL wall-clock reading taken when the `kind:1059` REQ was (re-)issued.
    ///
    /// The session MUST call this for every inbox REQ it issues, before or as it
    /// issues it, reusing the same `now` it derived that REQ's `since` from.
    /// With no open generation the inbox cursor never advances.
    pub fn note_inbox_subscription_opened(&self, opened_at_secs: i64) {
        self.inbox_anchor.open(opened_at_secs);
    }

    /// Records the relay's end-of-stored-events for the INBOX subscription and
    /// advances the persisted `inbox_1059` cursor to what the generation
    /// justifies.
    ///
    /// Returns whether an advance was issued (`false` when no generation is open
    /// or this generation already advanced). Best-effort: a storage failure is
    /// swallowed, because the cursor is an optimization and dropping the EOSE
    /// signal must never cost a delivered invitation.
    ///
    /// # Why not the gift wrap's own timestamp
    ///
    /// A `kind:1059`'s `#p` routing tag is the recipient's PUBLIC key and its
    /// author is a throwaway ephemeral key by construction, so anyone who knows
    /// a user's npub can mint a wrap that peels cleanly at any `created_at` —
    /// see [`InboxAnchor`] for the full argument and for why the FUTURE
    /// direction is the one that kills invitation delivery outright.
    pub fn note_inbox_end_of_stored_events(&self) -> bool {
        let now_secs = chrono::Utc::now().timestamp();
        let Some(ms) = self.inbox_anchor.consume_eose(now_secs) else {
            return false;
        };
        let _ = self
            .circle
            .advance_sync_cursor(crate::relay::cursor::STREAM_INBOX_1059, ms);
        true
    }

    /// Drops the inbox anchor after its subscription is closed, so a later stray
    /// EOSE cannot advance a cursor for a REQ we no longer own.
    pub fn forget_inbox_subscription(&self) {
        self.inbox_anchor.forget();
    }

    /// Processes one incoming `kind:445` for `nostr_group_id` (its routed `#h`).
    ///
    /// Ingests via the engine, routes the drained events, advances stored
    /// convergence for any pending group, and resolves any engine publish work.
    ///
    /// **Never advances a cursor.** An event that could not be applied records a
    /// hold-back against its circle's current anchor generation, so the next
    /// [`Self::note_end_of_stored_events`] stops at or below it; every other
    /// outcome is cursor-inert. See the module docs for why no ingest outcome —
    /// `Processed` included — vouches for the outer `created_at`.
    ///
    /// The two matches below are the hold-back gate, under this module's
    /// `#![deny(clippy::wildcard_enum_match_arm)]`. A wildcard arm here is how a
    /// future variant — of
    /// [`ScreenedIngest`] or of the upstream `IngestOutcome` — silently inherits
    /// "nothing outstanding here", so making one a hard error (clippy runs with
    /// `-D warnings` in CI) forces the decision to be written down.
    #[cfg_attr(test, allow(clippy::missing_panics_doc))]
    pub async fn process_group_event(
        &self,
        event: &Event,
        nostr_group_id: &[u8],
    ) -> GroupProcessOutcome {
        // Test-only fault-injection seam: a sentinel content string panics here
        // so the worker's panic-isolation test proves one adversarial event
        // never blinds the receive path. Compiled out of non-test builds.
        #[cfg(test)]
        #[allow(clippy::manual_assert)]
        if event.content == "__panic_for_test__" {
            panic!("injected decrypt panic (test seam)");
        }

        let group_hex = hex::encode(nostr_group_id);
        let created_at_secs = i64::try_from(event.created_at.as_secs()).unwrap_or(i64::MAX);

        // An `Err` here is an ENGINE-side ingest failure: the envelope parsed, so
        // the engine took the message and failed on it. Something at this
        // position is unresolved, so hold the generation at it. Attacker-writable
        // in principle, but only downwards (and the cursor write is
        // monotonic-max), so the worst it buys is a wider refetch — and minting
        // one now costs producing ciphertext the engine will actually work on,
        // because an unreadable envelope no longer lands here (it is a
        // `RejectedBeforeAuth` below).
        //
        // Read once: the whole of this event is handled as the lifecycle it
        // arrived in asks, whatever the session becomes meanwhile.
        let staging = self.staging();
        let (screened, recorded) = match self.ingest(event, staging).await {
            Ok(ingested) => ingested,
            // The engine was never asked, so this is no verdict on the event
            // and no failure of anything published: it is held and fetched
            // again, and nothing is reported about it.
            Err(NostrError::EngineHeld) => {
                self.anchors.note_unapplied(&group_hex, created_at_secs);
                return GroupProcessOutcome::Held;
            }
            Err(_) => {
                self.bus.send(LiveSyncEvent::Status {
                    reason: SyncStatusReason::Unprocessable,
                });
                self.anchors.note_unapplied(&group_hex, created_at_secs);
                return GroupProcessOutcome::Unprocessable;
            }
        };

        let mut ingest = match screened {
            // Rejected by Haven's local screen BEFORE any MLS authentication:
            // the signature, the ephemeral author and the ciphertext are all
            // unverified. No routing, no publish work, no convergence drain —
            // and no hold-back either: there is no un-applied message to come
            // back for, so letting it hold would let one forged event stall the
            // circle's cursor for the whole generation.
            ScreenedIngest::RejectedBeforeAuth(_) => {
                if let Ok(routing) = <[u8; 32]>::try_from(nostr_group_id) {
                    self.session().neg_judge_refused(&routing, event);
                }
                return GroupProcessOutcome::RejectedBeforeAuth;
            }
            ScreenedIngest::Ingested(effects) => effects,
        };

        // Route the drained events, then release any stored convergence + route
        // those, resolving engine publish work as we go.
        self.deliver_events(&ingest.effects.events, created_at_secs)
            .await;
        let work = std::mem::take(&mut ingest.effects.publish);
        self.resolve(staging, recorded, work, created_at_secs).await;
        // Receive-side observation for the epoch-rotation repair's quiescence
        // gate (`circle::rotation`). Placed on the AUTHENTICATED batch, never on
        // the raw kind-445: an event the engine rejected is mintable by any
        // observer of the circle's public `#h`.
        self.circle
            .note_inbound_group_events(&ingest.effects.events);
        let mut directory = self
            .circle
            .directory_verdict_for_events(&ingest.effects.events);
        directory = directory.max(
            self.drain_convergence(
                staging,
                &SessionManager::groups_owing_service(&ingest),
                created_at_secs,
            )
            .await,
        );
        // Live sync is the default receive plane, so this — not the poll path —
        // is where an inbound commit normally lands. Once per event batch, after
        // convergence has drained, so a roster read is of applied state.
        if let Some(mode) = directory {
            self.circle
                .reconcile_member_directory_best_effort(mode)
                .await;
        }

        // The hold-back gate. NOT a cursor advance: no arm here writes a cursor,
        // because no engine verdict binds this envelope's `created_at` to what it
        // authenticated. `Buffered` is the one un-applied verdict, so it — and
        // only it — pins this generation's EOSE advance at or below the event.
        // An object the engine kept no trace of is Rule 12's case: relay
        // redelivery is its only way back, so it holds.
        match ingest_disposition(&ingest.outcome, ingest.left_object_unpersisted) {
            Disposition::Unpersisted => {
                self.anchors.note_unapplied(&group_hex, created_at_secs);
                return GroupProcessOutcome::Refused;
            }
            Disposition::TakenIn | Disposition::NoRoom => {}
        }
        match ingest.outcome {
            // Answered from a stranded row: the same answer at every
            // redelivery, whichever epoch the row carries — the rule
            // `relay::catchup::cursor_verdict` has. Never a hold.
            IngestOutcome::Buffered { group_id, .. }
                if self
                    .circle
                    .session()
                    .holds_stranded(&group_id, &event.id)
                    .await =>
            {
                GroupProcessOutcome::Stranded
            }
            // The drain above may already have carried the group past the
            // buffered input's epoch (a convergence pass closing inside it);
            // the anchor is then not held.
            IngestOutcome::Buffered { group_id, epoch }
                if matches!(
                    self.circle.session().epoch_state(&group_id).await,
                    Some(EpochState::Stable { epoch: now }) if now > epoch
                ) =>
            {
                GroupProcessOutcome::Applied
            }
            IngestOutcome::Buffered { .. } => {
                self.anchors.note_unapplied(&group_hex, created_at_secs);
                GroupProcessOutcome::Buffered
            }
            IngestOutcome::ResourceRefused { .. } => {
                self.anchors.note_unapplied(&group_hex, created_at_secs);
                GroupProcessOutcome::Refused
            }
            IngestOutcome::Processed => GroupProcessOutcome::Applied,
            IngestOutcome::TransportDeferred { .. } => GroupProcessOutcome::Deferred,
            IngestOutcome::Stale { .. }
            | IngestOutcome::Ignored { .. }
            | IngestOutcome::Rejected { .. }
            | IngestOutcome::LocalState { .. } => GroupProcessOutcome::Stale,
        }
    }

    /// Advances every circle the engine has named as owing an advance since a
    /// plane last drained them ([`SessionManager::take_owed_advance`]) —
    /// after the open's recovery, the first time in a session.
    pub async fn drain_open_advance(&self) {
        // A session only started begins nothing of its own: this advance
        // runs before any REQ, in a process a start cannot tell from a
        // background cold launch, and an eviction a burst left due would be
        // staged and published here ahead of everything the circle has sent
        // since. So it settles what is stored and stages nothing; the claim's
        // drive makes what is due, under a record.
        self.drain_open_advance_as(self.staging()).await;
    }

    /// [`Self::drain_open_advance`] under `staging`.
    async fn drain_open_advance_as(&self, staging: (u64, DriveMode)) {
        let session = self.circle.session();
        // What the engine handed back at the open first, so a join recovered
        // there is in the circle list read next — and the groups its hydrate
        // named, which that drain usually collects, are in the set taken next.
        if session.take_open_recovery() {
            self.circle.recover_owed_outputs().await;
        }
        let owed = session.take_owed_advance();
        if owed.is_empty() {
            return;
        }
        let Ok(circles) = self.circle.routable_circles().await else {
            session.owe_advance(&owed);
            return;
        };
        let now_secs = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap_or(i64::MAX);
        let mut directory = None;
        for group_id in owed.iter().filter(|group_id| {
            circles
                .iter()
                .any(|cwm| &cwm.circle.mls_group_id == *group_id)
        }) {
            let drained = self
                .drain_convergence(staging, std::slice::from_ref(group_id), now_secs)
                .await;
            directory = directory.max(drained);
        }
        if let Some(mode) = directory {
            self.circle
                .reconcile_member_directory_best_effort(mode)
                .await;
        }
    }

    /// Drains stored convergence for the pending groups, re-ticking a group the
    /// engine still owes a deadline — a convergence pass closing, a due
    /// `SelfRemove` auto-commit — once it falls due (bounded by
    /// [`MAX_CONVERGENCE_RETICKS`], see [`next_receive_retick`]).
    ///
    /// A single advance per group would strand the commit and the eviction: the
    /// engine applies neither before its cutoff. Each pass routes the drained
    /// events and resolves publish work (publishing the auto-commit over the
    /// relay plane, Rule 13). A quiet group (nothing owed) exits immediately
    /// with no delay, so only a membership change pays the wait.
    ///
    /// Returns the strongest member-directory verdict the drained events imply,
    /// for the single reconcile the caller runs once the drain is complete.
    async fn drain_convergence(
        &self,
        staging: (u64, DriveMode),
        initial_pending: &[GroupId],
        event_created_at_secs: i64,
    ) -> Option<DirectoryReconcile> {
        let mut directory = None;
        let mut pending: Vec<GroupId> = initial_pending.to_vec();
        let mut advanced: Vec<GroupId> = Vec::new();
        for _ in 0..MAX_CONVERGENCE_RETICKS {
            if pending.is_empty() {
                break;
            }
            let mut owing: Vec<GroupId> = Vec::new();
            for gid in &pending {
                if !advanced.contains(gid) {
                    advanced.push(gid.clone());
                }
                if let Ok((mut more, recorded)) = self.advance(gid, staging).await {
                    self.deliver_events(&more.events, event_created_at_secs)
                        .await;
                    let work = std::mem::take(&mut more.publish);
                    self.resolve(staging, recorded, work, event_created_at_secs)
                        .await;
                    self.circle.note_inbound_group_events(&more.events);
                    directory =
                        directory.max(self.circle.directory_verdict_for_events(&more.events));
                    owing.extend(SessionManager::groups_owing_advance(&more));
                }
            }
            let (next, wait) = next_receive_retick(self.circle.session(), &pending, owing).await;
            pending = next;
            if !pending.is_empty() {
                self.reticks.fetch_add(1, Ordering::Relaxed);
                tokio::time::sleep(wait).await;
            }
        }
        // Out of deadlines it may wait out with the engine still owing one, or
        // left with work the engine named no deadline for: owed to the next
        // drain — the worker comes back for it after the next open
        // ([`Self::owe_come_back`]).
        owe_unfinished(self.circle.session(), pending, &advanced).await;
        directory
    }

    /// How many engine deadlines this processor's convergence drains have
    /// waited out (presence-only). No more than [`MAX_CONVERGENCE_RETICKS`]
    /// for one event or one drive, however long a circle goes on announcing
    /// one — and as many again for each circle when the worker comes back for
    /// it after an open: nothing here arms a timer on an engine deadline.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn convergence_reticks(&self) -> usize {
        self.reticks.load(Ordering::Relaxed)
    }

    /// Persists an engine batch's locations (which also acknowledges them to
    /// the engine), routes the batch onto the bus, and asks for a catch-up when
    /// the engine refused an object only a refetch by id can bring back.
    async fn deliver_events(&self, events: &[GroupEvent], event_created_at_secs: i64) {
        let results = self.circle.persist_for_routing(events).await;
        self.route_results(results, event_created_at_secs);
        // A circle that has just reached a new epoch may now open what the
        // engine refused before, and the engine sweeps what it admitted at
        // its next advance: what is owed is asked for at once, not at the
        // app's next sweep, so a refused leave is less often overtaken by
        // its own eviction. This plane holds no REQ of its own to ask with
        // and does not wait for the answer.
        // So is a walk of a circle's history the epoch-stall detector armed
        // on an ingest of this plane: once per arm, however many events the
        // batch carried.
        let stall_armed = self.circle.session().take_stall_armed();
        if stall_armed
            || events.iter().any(|event| match event {
                GroupEvent::TransportObjectResourceRefused { .. } => true,
                GroupEvent::EpochChanged { group_id, .. } => {
                    self.circle.session().owes_refetch(group_id)
                }
                GroupEvent::GroupCreated { .. }
                | GroupEvent::GroupJoined { .. }
                | GroupEvent::MessageReceived { .. }
                | GroupEvent::AppMessageInvalidated { .. }
                | GroupEvent::GroupStateChanged { .. }
                | GroupEvent::GroupHydrationQuarantined { .. }
                | GroupEvent::CommitRolledBack { .. }
                | GroupEvent::GroupStateInvalidated { .. }
                | GroupEvent::GroupStateRevalidated { .. }
                | GroupEvent::GroupUnrecoverable { .. }
                | GroupEvent::PendingCommitRecovered { .. }
                | GroupEvent::GroupHydrationRecovered { .. } => false,
            })
        {
            self.emit_status(SyncStatusReason::RefetchOwed);
        }
    }

    /// Routes ALREADY-FOLDED results onto the bus, each keyed off the result's
    /// OWN circle.
    ///
    /// No batch is scoped to one subscription — the engine's effect buffers are
    /// global, and an advance that fails mid-drain leaves its output for the
    /// next call on ANY circle to collect — so there is no ambient
    /// `nostr_group_id` to route by, and using the triggering event's would put
    /// one circle's peer on another circle's map. A result whose circle this
    /// device no longer holds is dropped: the bus names circles by their public
    /// id or it names nothing.
    fn route_results(&self, results: Vec<LocationMessageResult>, event_created_at_secs: i64) {
        // A circle whose routing an applied commit changed had its row follow
        // when the batch was persisted, which woke the session's follow
        // (`CircleManager::routing_moved`): the result is routed under the id
        // the row now names.
        for result in results {
            let Some(nostr_group_id) = self.circle.nostr_group_id_for(result.group_id()) else {
                continue;
            };
            self.route_one(result, &nostr_group_id, event_created_at_secs);
        }
    }

    /// One folded result onto the bus.
    fn route_one(
        &self,
        result: LocationMessageResult,
        nostr_group_id: &[u8],
        event_created_at_secs: i64,
    ) {
        match result {
            LocationMessageResult::Location {
                sender_pubkey,
                content,
                ..
            } => self.bus.send(LiveSyncEvent::Location {
                nostr_group_id: nostr_group_id.to_vec(),
                sender_pubkey,
                content,
                event_created_at_secs,
            }),
            // A roster/epoch change, a join, or a superseded (invalidated)
            // commit are all UI-only refresh signals now (the engine already
            // applied / rolled back the change internally).
            LocationMessageResult::GroupUpdate { .. }
            | LocationMessageResult::Joined { .. }
            | LocationMessageResult::Invalidated { .. } => {
                // A roster/epoch move is the receive side's commit activity:
                // it is what a background burst's settle window is measured
                // from, so a peer's commit landing at the end of a burst
                // holds the sockets open for its own convergence traffic
                // instead of being cut off by the pause.
                self.note_commit_activity();
                self.bus.send(LiveSyncEvent::GroupUpdate {
                    nostr_group_id: nostr_group_id.to_vec(),
                });
            }
            // The engine has given up on this group: it will not apply or
            // ingest further state, and only joining a replacement Welcome (a
            // re-invite) clears the halt. Surface the TERMINAL per-circle verdict, named
            // by the pseudonymous `nostr_group_id` (Rule 4/8), so a consumer
            // can stop send/mutate on that circle alone and offer the
            // re-invite. It used to flatten into `Unprocessable`, which is a
            // per-EVENT, self-clearing signal and named no circle — so the
            // one state that needs a destructive repair was indistinguishable
            // from one bad message.
            LocationMessageResult::Unrecoverable { .. } => {
                self.bus.send(LiveSyncEvent::GroupUnrecoverable {
                    nostr_group_id: nostr_group_id.to_vec(),
                });
            }
        }
    }

    /// How this processor takes in what the engine hands it now
    /// ([`Lifecycle::receives`]): the mode, and the instant on the clock its
    /// records are paced on.
    fn staging(&self) -> (u64, DriveMode) {
        (self.now_ms(), self.lifecycle.get().receives())
    }

    /// Now, on the clock this processor's records are paced on.
    fn now_ms(&self) -> u64 {
        self.driver
            .as_ref()
            .map_or_else(|| WallClock.now_ms(), |driver| driver.clock.now_ms())
    }

    /// Ingests `event`. In the full mode every commit and proposal the
    /// engine hands back is recorded in the hold that took the event, and
    /// comes back as a handle; in the mode that makes no commit nothing is
    /// staged, and only the user's own leave, proposed again, is recorded.
    async fn ingest(
        &self,
        event: &Event,
        (now_ms, mode): (u64, DriveMode),
    ) -> crate::nostr::Result<(ScreenedIngest, Vec<FanoutId>)> {
        // Read again with the engine held, as the advance is.
        let began = Leash::over(&self.lifecycle, None);
        self.circle
            .session()
            .process_event_staging(event, now_ms, Still::new(&began, mode))
            .await
    }

    /// Advances `group_id`. In the full mode that is the advance of a plane
    /// that drives: a change the user queued is given its attempt after the
    /// queued-change check, and what the advance releases is recorded in its
    /// hold. In the mode that makes no commit it is the engine's inputs-only
    /// advance: what the circle has received is settled, nothing is staged,
    /// and a queued change that is what holds the circle at its epoch is
    /// retired, its circle told first
    /// ([`SessionManager::settle_inputs_for_drive`]).
    async fn advance(
        &self,
        group_id: &GroupId,
        (now_ms, mode): (u64, DriveMode),
    ) -> crate::nostr::Result<(SessionEffects, Vec<FanoutId>)> {
        let session = self.circle.session();
        let staged = match mode {
            // Read again with the engine held: `staging` was read before
            // this advance waited for it, and a pause can land in that wait.
            DriveMode::Full => {
                let leash = Leash::over(&self.lifecycle, None);
                session
                    .advance_for_drive_while(group_id, now_ms, Still::new(&leash, DriveMode::Full))
                    .await
            }
            DriveMode::FinishOnly => session.settle_inputs_for_drive(group_id, now_ms).await,
        };
        self.circle.forget_dropped_removals().await;
        let staged = staged?;
        let mut recorded = staged.fanouts;
        recorded.extend(staged.proposals);
        Ok((staged.effects, recorded))
    }

    /// Disposes of what one engine batch left to be published: `recorded`
    /// are the handles of what its hold recorded, `work` what it did not.
    ///
    /// A processor that takes its input in as a plane that drives, or as one
    /// that makes no commit, sends nothing from here. Each record is the
    /// drive's ([`Self::drive_due`]), which runs off this worker, so no
    /// ingest waits on a relay for it; what `work` still holds is then a
    /// proposal no record could be written for — kept for a full drive's one
    /// publish, and let go by a hold that makes no commit — and a commit
    /// that could be neither recorded nor rolled back, which stays staged
    /// and was told to its circle in its hold.
    async fn resolve(
        &self,
        (now_ms, mode): (u64, DriveMode),
        recorded: Vec<FanoutId>,
        work: Vec<PublishWork>,
        event_created_at_secs: i64,
    ) {
        // Commit activity: noted BEFORE anything is sent,
        // so a settle that begins while a relay's answer is still out knows
        // the session is not quiet. A hold that makes no commit records only
        // a leave it sends to nobody.
        if mode == DriveMode::Full {
            for _ in &recorded {
                self.note_commit_activity();
            }
        }
        let unrecorded = SessionEffects {
            events: Vec::new(),
            publish: work,
            queued: Vec::new(),
            pending_convergence: Vec::new(),
        };
        // Taken before the fold, which is where this waits: what it hands
        // back is kept only if the foreground has not ended meanwhile.
        let began = Leash::over(&self.lifecycle, None);
        let (handed_back, _) = self
            .circle
            .fold_staged(unrecorded, false, now_ms, Still::new(&began, mode))
            .await;
        self.route_results(handed_back.results, event_created_at_secs);
        // With no transport a proposal that has no record cannot leave this
        // device: the engine proposes it again at the circle's next epoch.
        if self.driver.is_none() || mode != DriveMode::Full {
            return;
        }
        let wanted = !recorded.is_empty() || !handed_back.proposals.is_empty();
        self.keep_for_the_drive(&began, handed_back.proposals);
        if wanted {
            self.request_drive();
        }
    }

    /// Keeps `proposals` for the drive's one publish — unless the foreground
    /// `began` was taken in has ended. The end of the foreground drops what
    /// was kept, and a proposal kept behind that drop would be published,
    /// stale, in some later foreground.
    ///
    /// Read under the lock the drop takes, which it takes after the
    /// lifecycle is written: one of the two sees the other.
    fn keep_for_the_drive(&self, began: &Leash<'_>, proposals: Vec<Event>) {
        let mut kept = self
            .unrecorded
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if began.mode() == DriveMode::Full {
            kept.extend(proposals);
        }
    }

    /// Asks for a drive of the stored records. The session's drive task runs
    /// one ([`Self::drive_due`]); any number of requests made while one runs
    /// are one more.
    pub(super) fn request_drive(&self) {
        self.drive_wanted.notify_one();
    }

    /// Says an open — a burst, or a foreground re-anchor — is issuing its
    /// REQs: the worker comes back, once, for the advance a convergence drain handed
    /// back when it ran out of deadlines it may wait out
    /// ([`Self::come_back_if_owed`]), so a circle whose engine still owes a
    /// deadline is not left deaf until its next send, ingest or start.
    pub(super) fn owe_come_back(&self) {
        self.come_back_owed.store(true, Ordering::SeqCst);
    }

    /// Says the session has just become the foreground's: the drive task runs
    /// one NIP-77 pass for it, once ([`Self::take_negentropy_owed`]). The
    /// steady foreground runs none.
    pub(super) fn owe_negentropy(&self) {
        self.negentropy_owed.store(true, Ordering::SeqCst);
    }

    /// Takes the pass a foreground entry is owed, if any.
    pub(super) fn take_negentropy_owed(&self) -> bool {
        // Raised before the take, so a waiter never reads "nothing owed"
        // between the take and the pass it begins.
        #[cfg(any(test, feature = "test-utils"))]
        self.entry_pass_turn.0.store(true, Ordering::SeqCst);
        self.negentropy_owed.swap(false, Ordering::SeqCst)
    }

    /// The drive task's turn at an owed pass is over, whatever came of it;
    /// tests only.
    #[cfg(any(test, feature = "test-utils"))]
    pub(super) fn note_entry_pass_turn_ended(&self) {
        self.entry_pass_turn.0.store(false, Ordering::SeqCst);
        self.entry_pass_turn.1.notify_waiters();
    }

    /// Whether the session still serves `lifecycle` and has not been stopped:
    /// what a NIP-77 pass reads before each step that touches a relay or the
    /// engine.
    pub(super) fn still_serves(&self, lifecycle: Lifecycle) -> bool {
        self.lifecycle.get() == lifecycle && !self.halt.as_ref().is_some_and(|halt| *halt.borrow())
    }

    /// Which stretch of lifecycle a pass begins in
    /// ([`LifecycleCell::changes`]).
    pub(super) fn stretch(&self) -> u64 {
        self.lifecycle.changes()
    }

    /// Counts a pass as under way, until the guard drops.
    pub(super) fn pass_under_way(&self) -> Counted<'_> {
        self.passes.count()
    }

    /// Counts a NIP-77 pass's relay work, until the guard drops, on the
    /// count a pause waits on before it closes the drive pool; `None`,
    /// counting nothing, once the session no longer serves `serves` in the
    /// stretch `began` named.
    pub(super) fn negentropy_in_flight(
        &self,
        serves: Lifecycle,
        began: u64,
    ) -> Option<Counted<'_>> {
        let counted = self.in_flight.count();
        (self.lifecycle.changes() == began && self.still_serves(serves)).then_some(counted)
    }

    /// The drive task began waiting for a foreground entry's replay
    /// (`step` 0) or ran or gave up its pass (`step` 1); tests only.
    #[cfg(any(test, feature = "test-utils"))]
    pub(super) fn note_negentropy_step(&self, step: usize) {
        let counter = if step == 0 {
            &self.negentropy_steps.0
        } else {
            &self.negentropy_steps.1
        };
        counter.fetch_add(1, Ordering::SeqCst);
    }

    /// What is left of the wake a pass begun now would run in: the drive's
    /// budget, cut at the end of a burst
    /// ([`crate::relay::fanout::wake_deadline`]). `None` without a driver.
    pub(super) fn wake_left(&self) -> Option<Duration> {
        let clock = self.driver.as_ref()?.clock.as_ref();
        let deadline = crate::relay::fanout::wake_deadline(&self.circle, clock, RESUME_BUDGET_MS);
        Some(Duration::from_millis(
            deadline.saturating_sub(clock.now_ms()),
        ))
    }

    /// The come-back an open owes ([`Self::owe_come_back`]): the advance a
    /// convergence drain handed back ([`Self::drain_open_advance`]), inputs
    /// only. On the worker, after a relay's end of stored events — behind
    /// what it replayed, and ahead of a pause, whose marker queues behind it.
    pub(super) async fn come_back_if_owed(&self) {
        if self.come_back_owed.swap(false, Ordering::SeqCst) {
            // Inputs only, in any lifecycle: an eviction left due is staged
            // by the drive alone, once its circle is caught up
            // (`SessionManager::may_stage_left_due`), never by a come-back.
            self.drain_open_advance_as((self.now_ms(), DriveMode::FinishOnly))
                .await;
        }
    }

    /// The network is back after the live pool lost every relay: every relay
    /// a pending record could not reach is made due now
    /// ([`crate::relay::fanout::wake_unreachable`]) and a drive is asked for —
    /// at most once in [`NETWORK_BACK_FLOOR_MS`] on the driver's clock, so a
    /// flapping network calls each such relay at most once a minute, and only
    /// in a lifecycle that drives on a timer. A relay that was reached
    /// (`rate-limited:`) keeps its schedule.
    pub(super) async fn network_back(&self) {
        let Some(driver) = &self.driver else {
            return;
        };
        if !matches!(
            self.lifecycle.get(),
            Lifecycle::Foreground | Lifecycle::Burst
        ) {
            return;
        }
        let now_ms = driver.clock.now_ms();
        {
            let mut woken = self
                .network_woken_at_ms
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            if woken.is_some_and(|at| now_ms.abs_diff(at) < NETWORK_BACK_FLOOR_MS) {
                return;
            }
            *woken = Some(now_ms);
        }
        if crate::relay::fanout::wake_unreachable(&self.circle)
            .await
            .is_ok()
        {
            self.request_drive();
        }
    }

    /// Completes when a drive has been asked for.
    pub(super) async fn drive_requested(&self) {
        self.drive_wanted.notified().await;
    }

    /// Drives every stored record that has something due, in every circle:
    /// the live plane's one use of the fanout driver ([`Publishing::resume`]).
    ///
    /// In the mode the lifecycle gives ([`Lifecycle::drives`]), on the leash
    /// taken as the pass begins, within [`RESUME_BUDGET_MS`]. In the
    /// foreground that is the full drive, which also gives each queued
    /// change its attempt and publishes once each proposal staged without a
    /// record. In a background burst, and for a session nobody has claimed
    /// the foreground for, it is the drive that only finishes
    /// ([`DriveMode::FinishOnly`]): it begins a relay call only with a whole
    /// row's budget left, and the pause that ends a burst waits for what it
    /// has out. While paused it does nothing at all. A relay that is not due is not called
    /// and not dialled, so a drive with nothing due costs a read of the
    /// store.
    ///
    /// What the pass hands back is all taken in here: the locations a
    /// resolution replayed — each already stored and stamped as arrived by
    /// the fold that produced it — go onto the bus as an ingested one does;
    /// when there is next something to do is kept
    /// ([`Self::drive_retry_after_ms`]); what became of a change is in its
    /// circle's durable notes until the app acknowledges them, and an error
    /// was said, by kind, where it arose.
    pub(super) async fn drive_due(&self) {
        let Some(driver) = &self.driver else {
            return;
        };
        let _pass = self.pass_under_way();
        // The leash first, and the pass begins on its word alone: read
        // apart, the lifecycle and the leash could disagree, and a pass
        // would begin narrowed and widen.
        let leash = Leash::counted(&self.lifecycle, &self.in_flight, self.halt.clone());
        if !leash.runs() {
            return;
        }
        let full = leash.mode() == DriveMode::Full;
        let fanout = Leashed {
            inner: driver.fanout.as_ref(),
            leash: &leash,
        };
        let publisher = LeashedPublisher {
            inner: driver.publisher.as_ref(),
            leash: &leash,
        };
        let clock: &dyn FanoutClock = driver.clock.as_ref();
        // A burst's pass begins no call the OS would cut: one cut is an
        // attempt stored possibly exposed for good.
        let deadline_ms =
            crate::relay::fanout::wake_deadline(&self.circle, clock, RESUME_BUDGET_MS);
        let publishing = Publishing {
            fanout: &fanout,
            publisher: &publisher,
            clock,
            deadline_ms: Some(deadline_ms),
            mode: &leash,
        };
        self.attempt_queued_changes(clock.now_ms(), &leash).await;
        // Kept for a full drive's one publish, and taken by no other.
        let proposals = if full {
            std::mem::take(
                &mut *self
                    .unrecorded
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner),
            )
        } else {
            Vec::new()
        };
        let retry_after_ms = if proposals.is_empty() {
            None
        } else {
            let unrecorded = DecryptedIngest {
                proposals,
                ..DecryptedIngest::default()
            };
            let settled = publishing
                .settle_staged(&self.circle, Vec::new(), unrecorded)
                .await;
            self.absorb_drive(settled)
        };
        let resumed = publishing.resume(&self.circle).await;
        let resumed = self.absorb_drive(resumed);
        let retry_after_ms = match (retry_after_ms, resumed) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        };
        *self
            .drive_retry_after_ms
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = retry_after_ms;
        // A hint of zero says the pass ran out of its own budget: the
        // plane's next wake takes it up, and a timer armed on it would spin.
        *self
            .drive_due_at_ms
            .lock()
            .unwrap_or_else(PoisonError::into_inner) =
            retry_after_ms.filter(|wait| *wait > 0).map(|wait| {
                clock
                    .now_ms()
                    .saturating_add(wait.max(DRIVE_TIMER_FLOOR_MS))
            });
    }

    /// Completes when the last drive's own hint falls due on the driver's
    /// clock: a relay it left waiting may be called again, or a record's
    /// bound has come. Never completes while there is no such hint, or in a
    /// lifecycle that does not drive.
    ///
    /// It adds a drive, never a call: a drive calls a relay only when that
    /// relay's schedule says it is due.
    pub async fn drive_due_again(&self) {
        let at_ms = *self
            .drive_due_at_ms
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        match (&self.driver, at_ms) {
            // Not for a session only started: it runs the one drive its
            // start asks for and waits for a claim, with no standing contact
            // of its own.
            (Some(driver), Some(at_ms))
                if matches!(
                    self.lifecycle.get(),
                    Lifecycle::Foreground | Lifecycle::Burst
                ) =>
            {
                driver.clock.until(at_ms).await;
            }
            _ => std::future::pending().await,
        }
    }

    /// Gives every circle that holds a queued change the advance of a plane
    /// that drives, which makes the engine's one attempt at it — after the
    /// check of whether it can still be made — and records what it releases.
    ///
    /// A change of the group left queued keeps its circle from applying
    /// anything it receives until that attempt, and nothing else in a session
    /// makes it for a circle no event arrives in. So no such reservation is
    /// left standing in the foreground past a drive: one runs wherever a
    /// caller claims the foreground (a start, an open, the heal's claim, a
    /// health tick), and an event that arrives behind
    /// a reservation is itself answered with this advance
    /// ([`SessionManager::groups_owing_service`]).
    ///
    /// Only while the pass is in [`DriveMode::Full`], read before each
    /// circle's advance: once the foreground has ended under it, nothing
    /// queued is made.
    async fn attempt_queued_changes(&self, now_ms: u64, pass: &dyn ModeSource) {
        let holding = self.circle.session().groups_holding_queued_changes().await;
        let now_secs = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap_or(i64::MAX);
        let mut directory = None;
        for group_id in &holding {
            if pass.mode() != DriveMode::Full {
                break;
            }
            let drained = self
                .drain_convergence(
                    (now_ms, DriveMode::Full),
                    std::slice::from_ref(group_id),
                    now_secs,
                )
                .await;
            directory = directory.max(drained);
        }
        if let Some(mode) = directory {
            self.circle
                .reconcile_member_directory_best_effort(mode)
                .await;
        }
    }

    /// Takes in what one of this processor's drives handed back, and returns
    /// when it asked to be called again.
    fn absorb_drive(&self, outcome: ResumeOutcome) -> Option<u64> {
        let ResumeOutcome {
            replayed,
            retry_after_ms,
            // A Welcome's own state is its record's; the count is its
            // caller's convenience.
            welcomes_sent: _,
            // Said, by kind, where it arose; the stored records say where
            // each commit stands, and the next drive reads them.
            errored: _,
            // Said durably where the user has to act; the screen is W14's.
            withdrawn: _,
            requeued: _,
            clock_rejected,
        } = outcome;
        // The live plane has no caller to answer: its evidence goes on the
        // bus, where the clock check reads it.
        if let Some(complaint) = clock_rejected {
            self.bus.send(LiveSyncEvent::ClockRejected { complaint });
        }
        if !replayed.is_empty() {
            // A resolution has no source event: the local clock, as for the
            // session's open-time advance.
            let now_secs = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap_or(i64::MAX);
            self.route_results(replayed, now_secs);
        }
        retry_after_ms
    }

    /// How long after the last drive there is next something to do for a
    /// stored record — a relay due again, a bound reached — as that drive
    /// reported it; `None` when nothing is, or when the only record left is
    /// one that asks for no wake of its own.
    ///
    /// Nothing here schedules on it: a drive runs when something is staged
    /// and wherever a caller claims the foreground, and the drive task's own
    /// timer keeps the instant ([`Self::drive_due_again`]).
    #[must_use]
    pub fn drive_retry_after_ms(&self) -> Option<u64> {
        *self
            .drive_retry_after_ms
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }

    /// The lifecycle this processor is serving.
    #[must_use]
    pub fn lifecycle(&self) -> Lifecycle {
        self.lifecycle.get()
    }

    /// The lifecycle's writers and the drive, for a test that stands in for
    /// the session. They are the session's alone in a shipped build: each
    /// can put a processor in the foreground, or drive one, with no claim.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub const fn for_test(&self) -> SessionsPart<'_> {
        SessionsPart(self)
    }

    /// When a burst whose opener measured `budget_ms` of OS budget, now,
    /// ends; `None` when it gave none.
    pub(super) fn burst_end(&self, budget_ms: Option<u64>) -> Option<BurstEnd> {
        let driver = self.driver.as_ref()?;
        budget_ms.map(|budget| BurstEnd::after(driver.clock.as_ref(), budget))
    }

    /// Sets when the burst being opened ends, or that its opener gave no
    /// budget: every pass of the burst, and every call the bridge begins
    /// inside it, ends by then (`relay::fanout::wake_deadline`).
    pub(super) fn set_burst_end(&self, ends: Option<BurstEnd>) {
        self.circle.session().burst_ends(self.plane, ends);
    }

    /// Records that the session has been started, and that nobody has yet
    /// claimed the foreground for it ([`Lifecycle::Launched`]).
    pub(super) fn note_launched(&self) {
        self.enter(Lifecycle::Launched);
    }

    /// Writes the lifecycle, and tells the session where the plane that
    /// shares it now stands ([`SessionManager::plane_stands`]): a legacy
    /// hold on the same session — the app's own location send in a burst —
    /// stages no commit while this plane makes none
    /// ([`Lifecycle::receives`]), and reads what a circle was left waiting
    /// for while this plane is not a claimed foreground.
    ///
    /// The session is told FIRST on the way into a lifecycle that makes no
    /// commit and LAST on the way out of one, so that no legacy hold can
    /// find the lifecycle already narrowed and the session not yet told.
    fn enter(&self, lifecycle: Lifecycle) {
        let standing = match lifecycle {
            Lifecycle::Launched => PlaneStanding::Launched,
            Lifecycle::Foreground => PlaneStanding::Foreground,
            Lifecycle::Burst | Lifecycle::Background => PlaneStanding::MakesNone,
        };
        let narrows = standing == PlaneStanding::MakesNone;
        if narrows {
            self.circle.session().plane_stands(self.plane, standing);
        }
        // A burst's measured end is that burst's alone.
        if lifecycle != Lifecycle::Burst {
            self.circle.session().burst_ends(self.plane, None);
        }
        self.lifecycle.set(lifecycle);
        if !narrows {
            self.circle.session().plane_stands(self.plane, standing);
        }
    }

    /// Puts a session that had only been started in the foreground, and
    /// answers whether it did. For a caller that holds a foreground claim
    /// ([`super::Claim::Foreground`]) and for no other. A background
    /// lifecycle is ended by its own next open and by nothing else.
    pub(super) fn prove_foreground(&self) -> bool {
        let proven = self.lifecycle.prove_foreground();
        if proven {
            self.circle.session().plane_claimed(self.plane);
        }
        proven
    }

    /// Records that the session is paused or being stopped: the foreground
    /// has ended, or a burst has. A proposal kept for the drive's one
    /// publish is let go with it: by the next foreground its epoch may be
    /// long past, and the engine proposes again for each epoch the circle
    /// reaches.
    pub(super) fn leave_foreground(&self) {
        self.enter(Lifecycle::Background);
        self.forget_what_only_the_foreground_does();
    }

    /// Drops what waits for a foreground drive and would be stale by the
    /// next one: the kept proposals, and the drive timer's instant.
    fn forget_what_only_the_foreground_does(&self) {
        self.unrecorded
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clear();
        *self
            .drive_due_at_ms
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = None;
    }

    /// Attaches the owning session's cancellation, so a drive under way when
    /// the session is stopped gives its relays up instead of waiting them
    /// out.
    pub fn set_halt_signal(&mut self, halt: watch::Receiver<bool>) {
        self.halt = Some(halt);
    }

    /// Records which lifecycle an open has put this processor in — a
    /// background burst, or the foreground — see [`Self::lifecycle`].
    pub(super) fn set_background_burst(&self, background: bool) {
        self.enter(if background {
            Lifecycle::Burst
        } else {
            Lifecycle::Foreground
        });
        if background {
            self.forget_what_only_the_foreground_does();
        }
    }

    /// Emits a raw gift-wrapped invitation (`kind:1059`) onto the bus. The
    /// engine never unwraps it; the foreground consumer does.
    ///
    /// **Cursor-inert, in both directions.** The wrapper's `created_at` is not
    /// forwarded to the consumer at all, because the only thing it was ever used
    /// for was a cursor advance — and it is an unauthenticated field on an event
    /// anyone who knows this user's npub can mint (see [`InboxAnchor`]). The
    /// inbox cursor moves on [`Self::note_inbox_end_of_stored_events`] alone.
    pub fn process_inbox_event(&self, event: &Event) {
        self.bus.send(LiveSyncEvent::Welcome {
            gift_wrap_json: event.as_json(),
        });
    }

    /// Starts the silence window for one REQ endpoint, at the local instant that
    /// REQ was issued.
    ///
    /// The session MUST call this for every `(relay, subscription)` pair it
    /// issues, and for ONLY the pairs it issues — a single-relay repair re-seeds
    /// that relay alone, leaving the bucket's other relays' windows running.
    ///
    /// It also clears any `EOSE`/`CLOSED` this endpoint answered for a PREVIOUS
    /// generation. A background burst re-issues the same `(relay, sub_id)` pair
    /// every time, so without the clear the second burst would read the first
    /// burst's answer as its own and settle before the relay had replayed
    /// anything.
    pub fn open_delivery_window(&self, key: &RepairKey, opened_at_secs: i64) {
        self.delivery.open(key, opened_at_secs);
        self.settled_endpoints
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(key);
        self.released_endpoints
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(key);
        // Same reason, for the cursor's copy of the answer: a previous
        // generation's `EOSE` must not count towards this one's coverage.
        self.eose_coverage.reopen(key);
    }

    /// Whether an event `key` sends now is stored replay, to be held: the
    /// endpoint's REQ is open, and it has neither answered (`EOSE`,
    /// `CLOSED`) nor been released from its coverage.
    pub(super) fn in_stored_replay(&self, key: &RepairKey) -> bool {
        self.delivery.last(key).is_some()
            && !self
                .settled_endpoints
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .contains(key)
            && !self
                .released_endpoints
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .contains(key)
    }

    /// The circle the routing id `routing_id` names on this device, if any.
    pub(super) fn circle_routed_by(&self, routing_id: &[u8]) -> Option<GroupId> {
        <[u8; 32]>::try_from(routing_id)
            .ok()
            .and_then(|id| self.circle.circle_routed_by(&id).ok().flatten())
            .map(|circle| circle.mls_group_id)
    }

    /// The session behind this plane.
    pub(super) fn session(&self) -> &SessionManager {
        self.circle.session()
    }

    /// `events`, held under the routing id `routing_id`, in the order the
    /// engine is to take them in ([`SessionManager::order_for_ingest`]); as
    /// given when no circle is routed by it.
    pub(super) async fn order_stored(&self, routing_id: &[u8], events: Vec<Event>) -> Vec<Event> {
        let circle = <[u8; 32]>::try_from(routing_id)
            .ok()
            .and_then(|id| self.circle.circle_routed_by(&id).ok().flatten());
        let Some(circle) = circle else {
            return events;
        };
        self.circle
            .session()
            .order_for_ingest(&circle.mls_group_id, events)
            .await
            .into_iter()
            .map(|(_, event)| event)
            .collect()
    }

    /// Records that one REQ endpoint finished its stored replay for the current
    /// generation — the relay sent `EOSE`, or ended the REQ with `CLOSED`.
    ///
    /// Called from the ingest worker, which is SERIAL, so recording it here
    /// means every stored event that relay sent ahead of the answer has already
    /// been ingested, converged and had its publish work resolved. That is the
    /// whole content of the claim [`Self::wait_backlog_settled`] makes.
    ///
    /// A `CLOSED` counts because the relay will send nothing more on that REQ:
    /// waiting for an `EOSE` that can no longer come would spend the burst's
    /// entire budget on an endpoint that has already answered as fully as it
    /// ever will.
    pub fn note_endpoint_settled(&self, key: &RepairKey) {
        self.settled_endpoints
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(key.clone());
        self.eose_notify.notify_waiters();
    }

    /// Waits until every endpoint in `expected` has settled, or `timeout`
    /// elapses.
    ///
    /// `expected` is the set of `(relay, subscription)` pairs THIS burst issued
    /// AND whose relay took the REQ while connected — never the pairs it merely
    /// intended, nor one the pool only queued (T-POOL-QUEUED-ACCEPT). A dead
    /// relay is not in the set, so it cannot time out a burst; a burst that
    /// issued no inbox REQ expects no inbox endpoint, so it does not wait on
    /// one.
    ///
    /// An EMPTY `expected` settles immediately: there is nothing to wait for.
    ///
    /// Parks on a [`Notify`] the worker fires per endpoint rather than polling,
    /// and re-arms the waiter BEFORE re-reading the set, so an answer landing in
    /// between is never lost.
    pub async fn wait_backlog_settled(
        &self,
        expected: &[RepairKey],
        timeout: Duration,
    ) -> BacklogOutcome {
        let deadline = Instant::now() + timeout;
        loop {
            // Arm the waiter first, then read: a `notify_waiters()` fired
            // between a read and an un-armed park would be lost, and the burst
            // would wait out its whole budget on an endpoint that had answered.
            let notified = self.eose_notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();

            if self.endpoints_settled(expected) {
                return BacklogOutcome::Settled;
            }
            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                // Re-read once past the deadline: an answer can land in the same
                // instant the budget expires, and reporting TimedOut for a burst
                // that did settle would understate the receive plane's health.
                return if self.endpoints_settled(expected) {
                    BacklogOutcome::Settled
                } else {
                    BacklogOutcome::TimedOut
                };
            }
        }
    }

    /// Whether every endpoint in `expected` has answered.
    fn endpoints_settled(&self, expected: &[RepairKey]) -> bool {
        let settled = self
            .settled_endpoints
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        expected.iter().all(|key| settled.contains(key))
    }

    /// Waits — with NO cap — until every relay call this processor's passes
    /// have under way has answered.
    ///
    /// Uncapped on purpose (Security Rule 13). The alternative, a time-based
    /// cap, would let a pause `disconnect` a commit between SEND and OK: the
    /// relay may already have stored and served that commit to every peer
    /// while the drive records the attempt as unanswered, and the circle then
    /// waits a whole retry schedule on a commit its peers already hold. The
    /// wait is bounded by each counted call's own deadline — a drive's wake,
    /// a NIP-77 pass's connection and session wait — and by the drop guard,
    /// which gives the count back however the call ends.
    pub async fn wait_publishes_drained(&self) {
        self.in_flight.drained().await;
    }

    /// Waits until no drive or NIP-77 pass is under way, for no longer than
    /// what is left of the wake a pass begun now would run in: a pass stalled
    /// in local work holds no socket, and so may not hold a settle either.
    pub(super) async fn wait_passes_ended(&self) {
        let left = self.wake_left().unwrap_or_default();
        let _ = tokio::time::timeout(left, self.passes.drained()).await;
    }

    /// Counts a relay call as under way and hands back the REAL production
    /// drop guard, so a test can hold a publish "between SEND and OK" without a
    /// relay — and without a second, divergent copy of the count.
    ///
    /// Test-only: it is the one way to observe the UNCAPPED half of
    /// [`Self::wait_publishes_drained`] on a virtual clock, where no socket may
    /// exist.
    #[cfg(test)]
    pub(crate) fn hold_publish_for_test(&self) -> impl Drop + '_ {
        self.in_flight.count()
    }

    /// Records one commit-shaped observation, for a test that needs the settle
    /// window to have something to measure from without driving a real commit
    /// through MLS.
    #[cfg(test)]
    pub(crate) fn note_commit_activity_for_test(&self) {
        self.note_commit_activity();
    }

    /// How many relay calls are between SEND and OK right now.
    ///
    /// Presence-only (a count). The authoritative Rule-13 read taken by the
    /// pause immediately before `client.disconnect()`.
    #[must_use]
    pub fn in_flight_publishes(&self) -> usize {
        self.in_flight.now()
    }

    /// How many drive and NIP-77 passes are under way right now, local work
    /// included. Presence-only (a count).
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn passes_under_way(&self) -> usize {
        self.passes.now()
    }

    /// Forgets the commit activity observed so far, so the settle after a burst
    /// is measured from that burst's own traffic.
    ///
    /// Called at burst open, and NOWHERE else. Without it, the settle after a
    /// quiet burst would be measured from a commit the previous burst already
    /// settled — holding the radio open for nothing.
    ///
    /// Being the sole caller is also what defines the window for a teardown NO
    /// burst preceded: nothing reset the stamp, so that settle spans the
    /// foreground session's traffic back to its last re-anchor, and returns at
    /// once when there was none.
    pub fn reset_commit_activity(&self) {
        *self
            .commit_activity
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = CommitActivity::default();
    }

    /// Records one commit-shaped observation at the current instant.
    fn note_commit_activity(&self) {
        let mut activity = self
            .commit_activity
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        activity.count = activity.count.saturating_add(1);
        activity.last_at = Some(Instant::now());
    }

    /// When commit activity was last seen since the reset, or `None` if there
    /// has been none.
    ///
    /// `None` is what makes a settle pay zero.
    #[must_use]
    pub fn last_commit_activity_at(&self) -> Option<Instant> {
        self.commit_activity
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .last_at
    }

    /// How many commit-shaped observations have been made since the reset
    /// (presence-only).
    #[must_use]
    pub fn commit_activity_count(&self) -> u64 {
        self.commit_activity
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .count
    }

    /// Whether every cursor-anchor generation — group and inbox alike — has
    /// spent its advance.
    ///
    /// Presence-only. Read as "advance burned", never "EOSE seen": after
    /// [`Self::note_delivery_gap`] a suppressed generation answers `true`,
    /// because from the cursor's point of view the two are one fact — this
    /// generation will not advance, and the next REQ's floor is the untouched
    /// persisted cursor.
    #[must_use]
    pub fn all_advances_consumed(&self) -> bool {
        self.anchors.all_consumed() && self.inbox_anchor.is_consumed()
    }

    /// Records that one REQ endpoint delivered something.
    ///
    /// Called for an event or an `EOSE` on a subscription the router resolved,
    /// on the LOCAL clock and independent of any ingest verdict: the question is
    /// "is this REQ still carrying traffic", which a rejected event answers just
    /// as well as an applied one. The event's own `created_at` plays no part —
    /// it is remote-chosen, and would let one backdated event mint permanent
    /// silence or one future-dated one mask a real blackout.
    pub fn note_delivery(&self, key: &RepairKey) {
        self.delivery.note(key, chrono::Utc::now().timestamp());
    }

    /// When this REQ endpoint last delivered anything (seconds), or `None` if it
    /// has no open window.
    ///
    /// The delivery half of the health tick: a relay that keeps the socket open
    /// but silently deleted our REQ is `Connected` and mute, and this is the only
    /// thing that can tell the difference (see [`super::repair`]).
    #[must_use]
    pub fn last_delivery_secs(&self, key: &RepairKey) -> Option<i64> {
        self.delivery.last(key)
    }

    /// Records one group event the worker has taken in.
    #[cfg(any(test, feature = "test-utils"))]
    pub(super) fn note_taken_in_for_test(&self, id: nostr::EventId) {
        self.taken_in
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(id);
    }

    /// The group events the worker has taken in, held or ingested, in the
    /// order they arrived — before any ordering of a held batch.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn group_events_taken_in_for_test(&self) -> Vec<nostr::EventId> {
        self.taken_in
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Whether some endpoint of `relay` has settled in its current generation.
    #[cfg(any(test, feature = "test-utils"))]
    #[must_use]
    pub fn endpoint_settled_for_test(&self, relay: &RelayUrl) -> bool {
        self.settled_endpoints
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .any(|key| key.relay_url == *relay)
    }

    /// Drops every relay's silence window for one subscription — its REQ was
    /// closed, so nothing is owed on it any more.
    pub fn forget_delivery_for_sub(&self, sub_id: &SubscriptionId) {
        self.delivery.forget_sub(sub_id);
        self.eose_coverage.forget_sub(sub_id);
    }

    /// Emits a bare status signal on the bus (e.g. to surface a recovered worker
    /// panic rather than silently swallow it).
    pub fn emit_status(&self, reason: SyncStatusReason) {
        self.bus.send(LiveSyncEvent::Status { reason });
    }
}

/// What the session alone asks of its processor, handed to a test that plays
/// the session ([`EngineProcessor::for_test`]).
#[cfg(any(test, feature = "test-utils"))]
pub struct SessionsPart<'a>(&'a EngineProcessor);

#[cfg(any(test, feature = "test-utils"))]
impl SessionsPart<'_> {
    /// How many foreground NIP-77 passes the drive task has begun waiting for
    /// its entry's replay, and how many it has since run or given up.
    #[must_use]
    pub fn negentropy_steps(&self) -> (usize, usize) {
        (
            self.0.negentropy_steps.0.load(Ordering::SeqCst),
            self.0.negentropy_steps.1.load(Ordering::SeqCst),
        )
    }

    /// Waits, at most `bound`, until no foreground entry is owed its NIP-77
    /// pass and none is under way — run, cut or refused — and answers
    /// whether that came to hold.
    pub async fn entry_pass_ended(&self, bound: Duration) -> bool {
        let processor = self.0;
        let ended = || {
            !processor.negentropy_owed.load(Ordering::SeqCst)
                && !processor.entry_pass_turn.0.load(Ordering::SeqCst)
        };
        let deadline = Instant::now() + bound;
        loop {
            let notified = processor.entry_pass_turn.1.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if ended() {
                return true;
            }
            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                return ended();
            }
        }
    }

    /// As the tail of a session's start.
    pub fn note_launched(&self) {
        self.0.note_launched();
    }

    /// As a claim taken for a session that is only started.
    #[must_use]
    pub fn prove_foreground(&self) -> bool {
        self.0.prove_foreground()
    }

    /// As a pause or a stop.
    pub fn leave_foreground(&self) {
        self.0.leave_foreground();
    }

    /// As a burst's open (`true`) or a foreground open (`false`).
    pub fn set_background_burst(&self, background: bool) {
        self.0.set_background_burst(background);
    }

    /// As a burst's open that measured its budget (`Some`) or gave none.
    pub fn set_burst_budget(&self, budget_ms: Option<u64>) {
        self.0.set_burst_end(self.0.burst_end(budget_ms));
    }

    /// Whether the burst under way has a measured end.
    #[must_use]
    pub fn burst_is_bounded(&self) -> bool {
        self.0.circle.session().burst_bounded()
    }

    /// As the repair task, told the network is back.
    pub async fn network_back(&self) {
        self.0.network_back().await;
    }

    /// Whether a drive has been asked for and not yet taken up.
    #[must_use]
    pub fn drive_was_requested(&self) -> bool {
        futures::FutureExt::now_or_never(self.0.drive_requested()).is_some()
    }

    /// As the session's drive task, asked.
    pub fn owe_come_back(&self) {
        self.0.owe_come_back();
    }

    pub async fn come_back_if_owed(self) {
        self.0.come_back_if_owed().await;
    }

    pub fn request_drive(&self) {
        self.0.request_drive();
    }

    /// As the session's drive task, run. By value, so the pass borrows the
    /// processor and not this handle.
    pub async fn drive_due(self) {
        self.0.drive_due().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::circle::{CircleConfig, DirectoryTier, MemberKeyPackage};
    use crate::location::LocationMessage;
    use crate::nostr::mls::types::{EpochId, GroupEvent, MessageId};
    use crate::relay::cursor::STREAM_GROUP_445;
    use crate::relay::maintenance::build_kp_maintenance_events;
    use nostr::Keys;
    use tempfile::TempDir;

    /// A `(relay, sub)` key for the coverage tests.
    fn key(relay: &str, sub: &SubscriptionId) -> RepairKey {
        RepairKey {
            relay_url: RelayUrl::parse(relay).expect("a fixture relay url parses"),
            sub_id: sub.clone(),
        }
    }

    /// Both per-REQ tables are keyed by `(relay, subscription)`, and how many
    /// REQs a device holds is its relay-set size; so both render a BUCKET and
    /// neither renders a key (Rule 15).
    #[test]
    fn delivery_log_and_eose_coverage_debug_redacts_relay_and_sub_id() {
        let sub = SubscriptionId::new("s_group_0_SECRETSUB");
        let k = key("wss://secret-relay.example", &sub);

        let log = DeliveryLog::default();
        log.open(&k, 1_700_000_000);
        assert!(format!("{log:?}").contains("reqs: \"1\""));
        crate::assert_debug_redacted!(
            log,
            "DeliveryLog",
            &["secret-relay.example", "s_group_0_SECRETSUB", "1700000000"]
        );

        let coverage = EoseCoverage::default();
        let secret = [RelayUrl::parse("wss://secret-relay.example").expect("url")];
        coverage.expect(&sub, &secret, &secret);
        assert!(format!("{coverage:?}").contains("reqs: \"1\""));
        crate::assert_debug_redacted!(
            coverage,
            "EoseCoverage",
            &["secret-relay.example", "s_group_0_SECRETSUB"]
        );
    }

    #[test]
    fn one_relays_eose_does_not_cover_a_req_two_relays_accepted() {
        // The cursor-safety rule the anchor cannot state on its own: a bucket
        // REQ is one filter over SEVERAL relays and the circle has ONE
        // generation, so redeeming it on the first relay's EOSE advances the
        // cursor over whatever a slower co-bucketed relay had not yet replayed.
        let coverage = EoseCoverage::default();
        let sub = SubscriptionId::new("s_group_0");
        let both = [
            RelayUrl::parse("wss://fast.example").expect("url"),
            RelayUrl::parse("wss://slow.example").expect("url"),
        ];
        coverage.expect(&sub, &both, &both);

        assert!(
            !coverage.note(&key("wss://fast.example", &sub)),
            "the fast relay's EOSE vouches for its own window only"
        );
        assert!(
            coverage.note(&key("wss://slow.example", &sub)),
            "...and the advance is owed only once every relay that accepted the REQ \
             has finished"
        );
    }

    #[test]
    fn a_relay_that_refused_the_req_is_never_waited_on() {
        // The other direction: a dead relay in a two-relay bucket must not pin
        // the circle's cursor forever. `expect` is called a second time with the
        // ACCEPTED set, which narrows it — and must not discard an answer that
        // landed while the subscribe call was still returning.
        let coverage = EoseCoverage::default();
        let sub = SubscriptionId::new("s_group_0");
        let live = RelayUrl::parse("wss://live.example").expect("url");
        let issued = [
            live.clone(),
            RelayUrl::parse("wss://dead.example").expect("url"),
        ];
        coverage.expect(&sub, &issued, &issued);
        assert!(!coverage.note(&key("wss://live.example", &sub)));
        coverage.expect(&sub, &issued, &[live]);
        assert!(
            coverage.note(&key("wss://live.example", &sub)),
            "narrowing to the accepted set must resolve an EOSE the earlier, wider \
             expectation already recorded — dropping it would leave the cursor waiting \
             for a second EOSE the relay will never send"
        );
    }

    #[test]
    fn a_narrowing_onto_relays_that_have_all_answered_completes_the_req_once() {
        // The live relay's EOSE lands while the subscribe call is still
        // returning, against the wider expectation; no second EOSE follows.
        // The narrowing has to say the REQ is complete, or nothing redeems it.
        let coverage = EoseCoverage::default();
        let sub = SubscriptionId::new("s_group_0");
        let live = RelayUrl::parse("wss://live.example").expect("url");
        let issued = [
            live.clone(),
            RelayUrl::parse("wss://dead.example").expect("url"),
        ];
        assert!(!coverage.expect(&sub, &issued, &issued));
        assert!(!coverage.note(&key("wss://live.example", &sub)));
        assert!(
            coverage.expect(&sub, &issued, std::slice::from_ref(&live)),
            "a narrowing that leaves every relay still covering answered completes the REQ"
        );
        assert!(
            !coverage.expect(&sub, &issued, std::slice::from_ref(&live)),
            "a REQ already complete is not completed again"
        );

        // Narrowed before the answer: the worker's EOSE completes it, not the
        // narrowing.
        let coverage = EoseCoverage::default();
        assert!(!coverage.expect(&sub, &issued, &issued));
        assert!(!coverage.expect(&sub, &issued, std::slice::from_ref(&live)));
        assert!(coverage.note(&key("wss://live.example", &sub)));

        // Narrowed to nobody: no relay answered, so nothing is complete.
        let coverage = EoseCoverage::default();
        assert!(!coverage.expect(&sub, &issued, &issued));
        assert!(!coverage.expect(&sub, &issued, &[]));
    }

    #[test]
    fn a_previous_generations_eose_never_counts_towards_this_one() {
        // Every burst re-issues the SAME `(relay, sub_id)` pairs, so without the
        // per-endpoint reset the second burst would read the first burst's
        // answers as its own and advance before either relay had replayed
        // anything.
        let coverage = EoseCoverage::default();
        let sub = SubscriptionId::new("s_group_0");
        let both = [
            RelayUrl::parse("wss://fast.example").expect("url"),
            RelayUrl::parse("wss://slow.example").expect("url"),
        ];
        coverage.expect(&sub, &both, &both);
        assert!(!coverage.note(&key("wss://fast.example", &sub)));
        assert!(
            coverage.note(&key("wss://slow.example", &sub)),
            "precondition: the first generation is covered"
        );

        // The next burst re-issues both endpoints.
        coverage.reopen(&key("wss://fast.example", &sub));
        coverage.reopen(&key("wss://slow.example", &sub));
        coverage.expect(&sub, &both, &both);
        assert!(
            !coverage.note(&key("wss://fast.example", &sub)),
            "the new generation must be covered by its OWN answers: inheriting the \
             previous burst's would advance the cursor before the slow relay had \
             replayed a thing"
        );
        assert!(coverage.note(&key("wss://slow.example", &sub)));
    }

    #[test]
    fn a_single_relays_reissue_keeps_the_reqs_other_relays_owing() {
        // One relay of a bucket ends its REQ and is re-issued alone while
        // another is still replaying: the re-issued relay's answer must not
        // complete a coverage the other has not answered for.
        let coverage = EoseCoverage::default();
        let sub = SubscriptionId::new("s_group_0");
        let closed = RelayUrl::parse("wss://closed.example").expect("url");
        let both = [
            closed.clone(),
            RelayUrl::parse("wss://replaying.example").expect("url"),
        ];
        coverage.expect(&sub, &both, &both);
        coverage.reopen(&key("wss://closed.example", &sub));
        coverage.expect(
            &sub,
            std::slice::from_ref(&closed),
            std::slice::from_ref(&closed),
        );
        assert!(
            !coverage.note(&key("wss://closed.example", &sub)),
            "the re-issued relay's EOSE completed a coverage the replaying relay owes"
        );
        assert!(coverage.note(&key("wss://replaying.example", &sub)));
    }

    #[test]
    fn a_closed_subscription_leaves_no_coverage_state_behind() {
        // A leaked expectation is a permanent stall for whatever re-uses the id:
        // it would owe an EOSE from a relay that is no longer in the REQ.
        let coverage = EoseCoverage::default();
        let sub = SubscriptionId::new("s_group_0");
        let both = [
            RelayUrl::parse("wss://gone.example").expect("url"),
            RelayUrl::parse("wss://relay.example").expect("url"),
        ];
        coverage.expect(&sub, &both, &both);
        coverage.forget_sub(&sub);
        assert!(
            coverage.note(&key("wss://relay.example", &sub)),
            "an unsubscribed REQ owes nothing at all"
        );
    }

    #[test]
    fn per_circle_cursor_stream_keys_are_distinct_and_group_scoped() {
        let a = group_cursor_stream("aa00");
        let b = group_cursor_stream("bb11");
        assert_ne!(a, b, "each circle gets its own group cursor");
        assert!(a.starts_with(STREAM_GROUP_445));
        assert_ne!(a, crate::relay::cursor::STREAM_INBOX_1059);
    }

    // ── Member-directory wiring (picker plan §5.5) ───────────────────────────
    //
    // `process_group_event` is one of the two production write sites the M11
    // migration to live sync as the default receive plane actually exercises
    // (`docs/MEMBER_PICKER_PLAN.md` §5.5) — unlike the poll path
    // (`CircleManager::decrypt_location`), which in production almost never
    // fires now. These tests drive the REAL wiring: a real MLS circle, a real
    // inbound commit or location message, fed through this module's own
    // `process_group_event`, read back from the real SQLCipher directory table
    // via the public accessor — never a mock of
    // `reconcile_member_directory_best_effort`.

    /// A read time comfortably fixed, far in the past relative to any real wall
    /// clock a test run can hold — see `circle::manager::tests::DIR_NOW` for the
    /// same idiom. `ranked_directory_members` purges only rows with a finite
    /// `purge_after`, and every row this suite writes is a live co-membership
    /// (`DIRECTORY_PURGE_NEVER`), so the exact value only needs to be a stable
    /// constant, never a race against the setup helpers' own real-clock writes.
    const DIR_READ_AT: i64 = 20_000 * 86_400;

    async fn make_kp_event(manager: &CircleManager, keys: &Keys, relays: &[String]) -> Event {
        build_kp_maintenance_events(manager.session(), keys, relays, None, None)
            .await
            .expect("build key package event")
            .event
    }

    /// A freshly generated identity's `KeyPackage`, ready to be added to a
    /// circle. The throwaway session behind it is dropped after minting.
    async fn make_member_with_relays(relays: Vec<String>) -> MemberKeyPackage {
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let member = CircleManager::new_unencrypted(dir.path(), &keys).unwrap();
        let event = make_kp_event(&member, &keys, &relays).await;
        MemberKeyPackage {
            key_package_event: event,
            inbox_relays: relays,
            nip65_relays: vec![],
            nip65_write_relays: vec![],
        }
    }

    /// A real two-party MLS circle (Alice admin, Bob member), converged: Alice
    /// creates and confirms, Bob holds and accepts the engine-produced welcome.
    /// `bob` is an `Arc` because [`EngineProcessor::new`] needs one.
    struct AliceBob {
        alice: CircleManager,
        _alice_dir: TempDir,
        alice_keys: Keys,
        bob: Arc<CircleManager>,
        _bob_dir: TempDir,
        mls_group_id: GroupId,
        nostr_group_id: [u8; 32],
        relays: Vec<String>,
    }

    async fn setup_alice_bob() -> AliceBob {
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
            nip65_write_relays: vec![],
        };

        let config = CircleConfig::new("Test Circle").with_relays(relays.clone());
        let creation = alice
            .create_circle(&alice_keys, vec![bob_member], &config)
            .await
            .expect("create two-party circle");

        let mls_group_id = creation.circle.mls_group_id.clone();
        let nostr_group_id = creation.circle.nostr_group_id;

        let welcome = creation.welcome_events.first().expect("one welcome");
        bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
            .await
            .expect("bob holds welcome");
        bob.accept_invitation(&welcome.event.id)
            .await
            .expect("bob accepts welcome");

        AliceBob {
            alice,
            _alice_dir: alice_dir,
            alice_keys,
            bob: Arc::new(bob),
            _bob_dir: bob_dir,
            mls_group_id,
            nostr_group_id,
            relays,
        }
    }

    /// Queues a real user intent on `manager`: an admin-policy change adding
    /// `promote` to the admin set. Released, it is a `GroupEvolution` — the
    /// user's own change, owed its Welcomes and its publish obligation.
    async fn queue_user_intent(manager: &CircleManager, group_id: &GroupId, admins: &[[u8; 32]]) {
        let payload = SessionManager::admin_policy_payload_for_test(admins).expect("payload");
        manager
            .session()
            .queue_admin_policy_intent_for_test(group_id, payload)
            .await
            .expect("queue the intent");
    }

    /// Asserts the queued user intent is still queued and nothing was staged.
    async fn assert_intent_still_queued(manager: &CircleManager, group_id: &GroupId, plane: &str) {
        assert_eq!(
            manager
                .session()
                .queued_admin_policy_payloads_for_test(group_id)
                .await
                .expect("read the queue")
                .len(),
            1,
            "{plane}: a receive plane must not release the user's queued change"
        );
        assert!(
            matches!(
                manager.session().epoch_state(group_id).await,
                Some(crate::nostr::mls::types::EpochState::Stable { .. })
            ),
            "{plane}: nothing may be left staged (PendingPublish) by a receive plane"
        );
    }

    /// A proposal handed back by a hold that was under way when the
    /// What an endpoint sends is held as stored replay only while its REQ is
    /// open and it has neither answered nor been released; issuing its REQ
    /// again makes what it sends stored replay once more.
    #[tokio::test]
    async fn an_endpoint_is_held_from_its_reqs_issue_until_it_answers_or_is_released() {
        let dir = TempDir::new().unwrap();
        let circle =
            Arc::new(CircleManager::new_unencrypted(dir.path(), &Keys::generate()).unwrap());
        let processor = EngineProcessor::new(circle, EventBus::new());
        let key = RepairKey {
            relay_url: RelayUrl::parse("wss://relay.example").unwrap(),
            sub_id: SubscriptionId::new("s_held"),
        };
        assert!(
            !processor.in_stored_replay(&key),
            "an endpoint with no REQ open is not held"
        );
        processor.open_delivery_window(&key, 1_000);
        assert!(
            processor.in_stored_replay(&key),
            "an open REQ's replay is held"
        );
        let _ = processor.release_from_coverage(&key);
        assert!(
            !processor.in_stored_replay(&key),
            "a released endpoint is held no longer: nothing it sends would ever be taken in"
        );
        processor.open_delivery_window(&key, 1_001);
        assert!(
            processor.in_stored_replay(&key),
            "a REQ issued again holds its replay again"
        );
        processor.note_endpoint_settled(&key);
        assert!(
            !processor.in_stored_replay(&key),
            "an endpoint that answered is not held"
        );
    }

    /// foreground ended is not kept for a later foreground's drive: the end
    /// of the foreground dropped what was kept, and one kept behind that
    /// drop would be published, stale, whenever the app next came forward.
    /// One handed back while its foreground still stands is kept.
    #[tokio::test]
    async fn a_proposal_handed_back_after_the_foreground_ended_is_not_kept() {
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
        let processor = EngineProcessor::new(circle, EventBus::new());
        let proposal = || {
            nostr::EventBuilder::text_note("sealed")
                .sign_with_keys(&Keys::generate())
                .expect("a signed event")
        };
        let kept = || {
            processor
                .unrecorded
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .len()
        };

        processor.set_background_burst(false);
        let began = Leash::over(&processor.lifecycle, None);
        processor.keep_for_the_drive(&began, vec![proposal()]);
        assert_eq!(kept(), 1, "premise: kept while its foreground stands");

        // The foreground ends under a second hold, and returns.
        let began = Leash::over(&processor.lifecycle, None);
        processor.leave_foreground();
        assert_eq!(
            kept(),
            0,
            "premise: the end of the foreground drops what was kept"
        );
        processor.keep_for_the_drive(&began, vec![proposal()]);
        processor.set_background_burst(false);
        processor.keep_for_the_drive(&began, vec![proposal()]);
        assert_eq!(
            kept(),
            0,
            "a proposal of a hold that outlived its foreground was kept for a later one",
        );
    }

    /// A mode that reads full once, and finish-only from then on.
    struct FullOnce(std::sync::atomic::AtomicBool);

    impl ModeSource for FullOnce {
        fn mode(&self) -> DriveMode {
            if self.0.swap(false, Ordering::SeqCst) {
                DriveMode::Full
            } else {
                DriveMode::FinishOnly
            }
        }
    }

    /// Two circles of one device each hold a queued change, and the
    /// foreground ends between the two attempts: the mode is read before each
    /// circle's advance, so the first change is made and the second is left
    /// queued. With the foreground standing throughout, both are made.
    #[tokio::test]
    async fn a_queued_change_is_not_attempted_once_the_foreground_has_ended_between_two_circles() {
        async fn two_circles_each_holding_a_change() -> (Arc<CircleManager>, TempDir, [GroupId; 2])
        {
            let relays = vec!["wss://relay.test.com".to_string()];
            let dir = TempDir::new().unwrap();
            let keys = Keys::generate();
            let alice = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
            let mut groups = Vec::new();
            for name in ["One", "Two"] {
                let member = make_member_with_relays(relays.clone()).await;
                let promoted = member.key_package_event.pubkey.to_bytes();
                let created = alice
                    .create_circle(
                        &keys,
                        vec![member],
                        &CircleConfig::new(name).with_relays(relays.clone()),
                    )
                    .await
                    .expect("a circle is created");
                let group = created.circle.mls_group_id;
                queue_user_intent(&alice, &group, &[keys.public_key().to_bytes(), promoted]).await;
                groups.push(group);
            }
            let groups: [GroupId; 2] = groups.try_into().expect("two circles");
            (alice, dir, groups)
        }
        async fn still_queued(alice: &CircleManager, groups: &[GroupId; 2]) -> usize {
            let mut queued = 0;
            for group in groups {
                queued += alice
                    .session()
                    .queued_admin_policy_payloads_for_test(group)
                    .await
                    .expect("read the queue")
                    .len();
            }
            queued
        }

        // In the foreground, as a processor is wherever a pass reads full:
        // each advance reads the lifecycle again once it holds the engine.
        let (alice, _dir, groups) = two_circles_each_holding_a_change().await;
        let processor = EngineProcessor::new(Arc::clone(&alice), EventBus::new());
        processor.for_test().set_background_burst(false);
        assert_eq!(still_queued(&alice, &groups).await, 2, "premise");
        processor
            .attempt_queued_changes(1_700_000_000_000, &DriveMode::Full)
            .await;
        assert_eq!(
            still_queued(&alice, &groups).await,
            0,
            "control: with the foreground standing, each circle's change is attempted",
        );

        let (alice, _dir, groups) = two_circles_each_holding_a_change().await;
        let processor = EngineProcessor::new(Arc::clone(&alice), EventBus::new());
        processor.for_test().set_background_burst(false);
        let narrowing = FullOnce(std::sync::atomic::AtomicBool::new(true));
        processor
            .attempt_queued_changes(1_700_000_000_000, &narrowing)
            .await;
        assert_eq!(
            still_queued(&alice, &groups).await,
            1,
            "a queued change was attempted after the foreground had ended, or none was \
             attempted before it did",
        );
    }

    /// The hold on commits is the newest plane's to raise and lower. A plane
    /// let go late — a worker still holding it when the session that
    /// replaced it has opened a burst — lowers nothing, and neither does
    /// anything else it does: lowered by it, a bridge call in that burst
    /// could make a commit on its caller's word.
    #[tokio::test]
    async fn a_plane_let_go_late_does_not_lower_the_hold_of_the_burst_that_replaced_it() {
        let fx = setup_alice_bob().await;
        let alice = Arc::new(fx.alice);
        let held = || alice.session().beside_a_plane_that_makes_none();

        let older = EngineProcessor::new(Arc::clone(&alice), EventBus::new());
        older.for_test().set_background_burst(true);
        assert!(held(), "premise: a burst holds the session's commits");
        let newer = EngineProcessor::new(Arc::clone(&alice), EventBus::new());
        newer.for_test().set_background_burst(true);

        older.for_test().set_background_burst(false);
        assert!(
            held(),
            "a plane a newer one has replaced lowered the newer one's hold",
        );
        drop(older);
        assert!(
            held(),
            "a plane let go late lowered the hold of the burst that replaced it",
        );

        newer.for_test().set_background_burst(false);
        assert!(!held(), "the plane that holds could not lower its own hold");
        newer.for_test().set_background_burst(true);
        drop(newer);
        assert!(!held(), "a plane that is gone still holds the session back");
    }

    #[tokio::test]
    async fn a_receive_advance_never_releases_a_queued_user_intent() {
        // A receive plane that ran MDK's intent-draining advance would hand the
        // user's queued change to a publisher that owes it neither its
        // Welcomes nor its obligation (C7 re-review F1–F4). The live plane's
        // two advance edges — the session-open advance and the advance after
        // an ingested input — must both leave it queued.
        let fx = setup_alice_bob().await;
        let alice = Arc::new(fx.alice);
        let bob_key = fx
            .bob
            .session()
            .self_id()
            .await
            .as_slice()
            .try_into()
            .expect("32-byte member id");
        queue_user_intent(
            &alice,
            &fx.mls_group_id,
            &[fx.alice_keys.public_key().to_bytes(), bob_key],
        )
        .await;

        let processor = EngineProcessor::new(Arc::clone(&alice), EventBus::new());
        processor.drain_open_advance().await;
        assert_intent_still_queued(&alice, &fx.mls_group_id, "the open advance").await;

        let leave = fx
            .bob
            .propose_leave(&fx.mls_group_id)
            .await
            .expect("bob proposes leave")
            .expect("a first leave in this epoch proposes");
        processor
            .process_group_event(&leave, &fx.nostr_group_id)
            .await;
        assert_intent_still_queued(&alice, &fx.mls_group_id, "the ingest advance").await;
    }

    #[tokio::test]
    async fn a_real_inbound_add_commit_drained_through_process_group_event_writes_a_directory_row()
    {
        // The headline gap: nothing proved that `process_group_event`'s own
        // reconcile call — not a mock of it — turns a real inbound commit into
        // a real row. Isolated from every OTHER write site by construction:
        // Carol's pubkey never reaches Bob any other way in this test — not
        // through a welcome (Bob never processes Carol's), so her row can only
        // be explained by this call.
        let fx = setup_alice_bob().await;
        let carol = make_member_with_relays(fx.relays.clone()).await;
        let carol_hex = carol.key_package_event.pubkey.to_hex();

        let before = fx
            .bob
            .ranked_directory_members(DIR_READ_AT)
            .expect("directory read");
        assert!(
            !before.iter().any(|e| e.pubkey_hex == carol_hex),
            "precondition: Carol is nobody to Bob yet"
        );

        let add = fx
            .alice
            .add_members_for_test(&fx.mls_group_id, &[carol])
            .await
            .expect("alice adds carol");

        let processor = EngineProcessor::new(Arc::clone(&fx.bob), EventBus::new());
        let outcome = processor
            .process_group_event(&add.0, &fx.nostr_group_id)
            .await;
        assert_eq!(
            outcome,
            GroupProcessOutcome::Applied,
            "sanity: the commit really applied — a failure here would make the \
             absence check below meaningless"
        );

        let after = fx
            .bob
            .ranked_directory_members(DIR_READ_AT)
            .expect("directory read");
        let carol_row = after.iter().find(|e| e.pubkey_hex == carol_hex).expect(
            "process_group_event must reconcile the directory after a real \
             inbound commit — deleting that call, or making it a no-op, must \
             fail this assertion",
        );
        assert_eq!(carol_row.tier, DirectoryTier::Current);
    }

    #[tokio::test]
    async fn a_batch_of_only_location_messages_triggers_no_reconcile_at_all() {
        // The performance-review counterpart to the test above: an ordinary
        // location update must never pay for a multi-circle roster walk. Pinned
        // at the ROW level rather than "the roster is unchanged", because
        // `sync_co_members`'s promotion is idempotent when co-membership itself
        // doesn't change (the UPSERT re-derives the SAME `last_shared_day` on a
        // no-op pass, storage_member_directory.rs:180) — a byte-diff taken right
        // after ordinary setup would pass even if a regression made this call
        // reconcile on every location. Forcing `last_shared_day` onto a fixed,
        // far-past day FIRST makes a spurious reconcile impossible to miss: a
        // real one always writes the REAL wall-clock day, which cannot equal the
        // constant below now or in the future.
        const FAR_PAST_DAY_SECS: i64 = 20_000 * 86_400; // 2024-10-04.

        let fx = setup_alice_bob().await;
        let alice_hex = fx.alice_keys.public_key().to_hex();

        assert!(
            fx.bob
                .reconcile_member_directory(DirectoryReconcile::Rewrite, FAR_PAST_DAY_SECS)
                .await
                .expect("reconcile"),
            "precondition: bob's converged roster is readable"
        );
        let before = fx
            .bob
            .ranked_directory_members(DIR_READ_AT)
            .expect("directory read");
        let before_row = before
            .iter()
            .find(|e| e.pubkey_hex == alice_hex)
            .cloned()
            .expect("precondition: alice is bob's co-member");
        assert_eq!(
            before_row.last_shared_day,
            FAR_PAST_DAY_SECS / 86_400,
            "precondition: the forced stamp really landed"
        );

        let loc = LocationMessage::new(1.0, 2.0);
        let (event, ngid, _relays) = fx
            .alice
            .seal_location_for_test(&fx.mls_group_id, &loc)
            .await
            .expect("alice encrypts");

        let processor = EngineProcessor::new(Arc::clone(&fx.bob), EventBus::new());
        let outcome = processor.process_group_event(&event, &ngid).await;
        assert_eq!(
            outcome,
            GroupProcessOutcome::Applied,
            "sanity: the location really applied — a failure here would make \
             the row-unchanged assertion below meaningless"
        );

        let after = fx
            .bob
            .ranked_directory_members(DIR_READ_AT)
            .expect("directory read");
        let after_row = after
            .iter()
            .find(|e| e.pubkey_hex == alice_hex)
            .cloned()
            .expect("alice's row must still exist");
        assert_eq!(
            after_row, before_row,
            "a location-only batch must never touch the directory row — any \
             difference here (including a bumped last_shared_day) means a \
             reconcile ran where the plan says one must not"
        );
    }

    #[tokio::test]
    async fn the_directory_verdict_merge_prefers_withdrawal_over_an_ordinary_update_either_order() {
        // §6.2/§5.5: both write sites fold a `DirectoryReconcile` across a
        // drain with `Option::max` over the strength-ordered enum
        // (`Rewrite < RewriteWithdrawing`), never reading a roster mid-drain.
        // This proves the merge itself is commutative and that a withdrawal
        // present ANYWHERE in the batch wins, using the exact function both
        // `process_group_event` and `catchup::ingest_one` call
        // (`CircleManager::directory_verdict_for_events`), fed a REAL event
        // batch from a genuine inbound commit mixed with a hand-built
        // `GroupStateInvalidated`.
        //
        // The invalidated event is necessarily hand-built rather than
        // engine-emitted: producing one for real needs a losing branch from two
        // concurrent publishers, which — per
        // `circle::manager::tests::a_withdrawn_add_is_deleted_rather_than_kept_as_a_recent_contact`
        // — is out of reach for a deterministic unit test and is covered
        // black-box by the F2 convergence gate
        // (`tests/live_sync_out_of_order_commit_e2e.rs`) instead. Its shape (a
        // real group id, a plausible epoch/reason) is exactly what the fold
        // switches on, so hand-building it exercises the same match arm a real
        // one would.
        let fx = setup_alice_bob().await;
        let carol = make_member_with_relays(fx.relays.clone()).await;
        let add = fx
            .alice
            .add_members_for_test(&fx.mls_group_id, &[carol])
            .await
            .expect("alice adds carol");

        // Capture the REAL events the engine emits for a genuine ordinary
        // commit, straight from the same `SessionManager::process_event` both
        // write sites call, plus the receive advances that apply it once its
        // convergence pass closes.
        let before = fx
            .bob
            .session()
            .epoch(&fx.mls_group_id)
            .await
            .expect("epoch");
        let screened = fx
            .bob
            .session()
            .process_event(&add.0)
            .await
            .expect("engine ingest");
        let ScreenedIngest::Ingested(ingest) = screened else {
            panic!("a real commit for a live group must reach the engine");
        };
        let mut real_events = ingest.effects.events;
        real_events.extend(
            fx.bob
                .session()
                .settle_receive_for_test(&fx.mls_group_id)
                .await
                .expect("bob settles the add")
                .events,
        );
        assert_eq!(
            fx.bob
                .session()
                .epoch(&fx.mls_group_id)
                .await
                .expect("epoch"),
            before + 1,
            "precondition: bob really applied the add"
        );
        let ordinary = fx.bob.directory_verdict_for_events(&real_events);
        assert_eq!(
            ordinary,
            Some(DirectoryReconcile::Rewrite),
            "precondition: this real batch alone implies an ordinary rewrite"
        );

        let invalidated = GroupEvent::GroupStateInvalidated {
            group_id: fx.mls_group_id.clone(),
            epoch: EpochId(1),
            invalidated_commit_id: MessageId::new(vec![1]),
            reason: cgka_traits::engine::GroupStateInvalidationReason::SupersededByBranchSelection,
        };
        let withdrawing = fx
            .bob
            .directory_verdict_for_events(std::slice::from_ref(&invalidated));
        assert_eq!(withdrawing, Some(DirectoryReconcile::RewriteWithdrawing));

        // The inter-stage merge processor.rs/catchup.rs perform, both orders.
        assert_eq!(
            ordinary.max(withdrawing),
            Some(DirectoryReconcile::RewriteWithdrawing)
        );
        assert_eq!(
            withdrawing.max(ordinary),
            Some(DirectoryReconcile::RewriteWithdrawing)
        );

        // The intra-batch fold, invalidation first and invalidation last.
        let mut front = vec![invalidated.clone()];
        front.extend(real_events.clone());
        assert_eq!(
            fx.bob.directory_verdict_for_events(&front),
            Some(DirectoryReconcile::RewriteWithdrawing),
            "a withdrawal ahead of the real update in the batch must still win"
        );

        let mut back = real_events;
        back.push(invalidated);
        assert_eq!(
            fx.bob.directory_verdict_for_events(&back),
            Some(DirectoryReconcile::RewriteWithdrawing),
            "and behind it — the fold must not be order-dependent"
        );
    }
}
