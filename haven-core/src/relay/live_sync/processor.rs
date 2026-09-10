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
//! reports a future-epoch APPLICATION message as `Stale { PeelFailed }` (it
//! retains it as a retryable row and re-peels once the commit lands), not as
//! `Buffered`. `Buffered` is reported when this device's own group state cannot
//! ingest at all — during a publish-before-apply transition. The EOSE anchor
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

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use nostr::{Event, JsonUtil, RelayUrl, SubscriptionId};
use tokio::sync::Notify;
use tokio::time::Instant;

use crate::circle::{CircleManager, DirectoryReconcile};
use crate::nostr::mls::types::{
    GroupId, IngestOutcome, LocationMessageResult, PublishWork, ScreenedIngest,
};
use crate::nostr::mls::SessionManager;
use crate::relay::auto_commit::{
    park_or_rollback_receive_publish_work, resolve_receive_publish_work_with_policy,
    AutoCommitPublisher, ReceiveAutoCommitPolicy, CONVERGENCE_RETICK_DELAY,
    MAX_CONVERGENCE_RETICKS,
};

use super::anchor::{CursorAnchors, InboxAnchor};
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
    /// (`IngestOutcome::Stale` — duplicate, stale epoch, not-for-us, or
    /// undecryptable-and-retained). Holds nothing back: the engine owns the
    /// retry of what it retained, and holding here would let one forged event
    /// pin the circle's cursor for the session.
    Stale,
    /// The engine buffered the message (this device's own group state cannot
    /// ingest right now — a publish-before-apply transition). Un-applied, so it
    /// holds this generation's advance at or below its `created_at`; the engine
    /// also persists it durably, so nothing is lost across a restart.
    Buffered,
    /// Haven's local receiver-side screen rejected the event BEFORE any MLS
    /// authentication (see [`crate::nostr::mls::types::ScreenedIngest`]) — an
    /// expired NIP-40 replay, or an envelope the pure pre-engine transport parse
    /// could not read at all. Nothing was routed and nothing was persisted. It
    /// holds nothing back either: there is no un-applied message to come back
    /// for, and letting it hold would sell an attacker a stall for the price of
    /// one forged event.
    RejectedBeforeAuth,
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
        f.debug_struct("DeliveryLog").field("reqs", &len).finish()
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
/// So the advance waits for every relay that ACCEPTED the REQ. A relay that
/// refused it is not in the set (it can never stall a burst forever); a relay
/// that ends the REQ with `CLOSED` never appears in `seen`, so the generation is
/// left un-redeemed and the next REQ re-requests the window from its unmoved
/// cursor — a stall, which costs bandwidth, rather than a skip, which costs the
/// backlog.
///
/// Presence-only `Debug` (a count, never a relay or a sub-id) per Rules 4/6.
#[derive(Default)]
struct EoseCoverage {
    inner: Mutex<HashMap<SubscriptionId, Coverage>>,
}

/// One REQ's coverage: who owes an `EOSE`, and who has sent one.
#[derive(Debug, Default)]
struct Coverage {
    expected: HashSet<RelayUrl>,
    seen: HashSet<RelayUrl>,
}

impl std::fmt::Debug for EoseCoverage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let len = self
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len();
        f.debug_struct("EoseCoverage").field("reqs", &len).finish()
    }
}

impl EoseCoverage {
    /// Sets who owes this REQ an `EOSE`, leaving what has already been seen
    /// alone.
    ///
    /// Called TWICE per issue: once with the relays the REQ is issued to (so an
    /// `EOSE` racing the subscribe call cannot redeem an empty expectation), and
    /// once with the subset that accepted it (so a relay that refused the REQ
    /// cannot pin the cursor). `seen` is NOT reset here — that happens per
    /// endpoint in [`EngineProcessor::open_delivery_window`], because an answer
    /// landing between the two calls is a real answer to this generation.
    fn expect(&self, sub_id: &SubscriptionId, relays: &[RelayUrl]) {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entry(sub_id.clone())
            .or_default()
            .expected = relays.iter().cloned().collect();
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
            coverage
                .expected
                .iter()
                .all(|relay| coverage.seen.contains(relay))
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

/// Decrements the in-flight publish gauge on drop, so a publish that panics,
/// is cancelled, or returns early can never leave the gauge above zero.
///
/// A gauge that never returns to zero would make [`EngineProcessor::wait_publishes_drained`]
/// — which is deliberately UNCAPPED (Security Rule 13: the pause may not cut a
/// commit between SEND and OK) — hang forever, which is a background receive
/// outage. The guard is what makes "uncapped" safe to write.
struct PublishGauge<'a>(&'a AtomicUsize, &'a Notify);

impl Drop for PublishGauge<'_> {
    fn drop(&mut self) {
        if self.0.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.1.notify_waiters();
        }
    }
}

/// The receive engine's group/inbox event processor.
///
/// Holds the single MLS-state owner ([`CircleManager`], whose one process-global
/// [`SessionManager`] satisfies Rule 14) and the fan-out bus.
pub struct EngineProcessor {
    circle: Arc<CircleManager>,
    bus: EventBus,
    /// The relay plane used to publish receive-side auto-commits (a peer
    /// `SelfRemove` eviction) before confirming them (Rule 13). `None` for a bare
    /// processor with no relay plane wired — it then rolls such commits back
    /// (never an optimistic apply). The live-sync session installs the engine
    /// `Client` here via [`Self::with_publisher`].
    publisher: Option<Arc<dyn AutoCommitPublisher>>,
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
    /// Fired whenever an endpoint settles, so [`Self::wait_backlog_settled`]
    /// parks instead of polling.
    eose_notify: Notify,
    /// Which relays each live GROUP REQ still owes an `EOSE` before its circles
    /// may advance their cursors. See [`EoseCoverage`].
    eose_coverage: EoseCoverage,
    /// Publishes this processor has put on the wire and not yet resolved.
    ///
    /// Incremented BEFORE the publisher call in [`Self::resolve_publish_work`]
    /// and decremented by a drop guard, so it is an exact count of commits
    /// between SEND and OK. A background pause MUST NOT `disconnect` while this
    /// is non-zero: `wait_for_ok` would return `Err`, the commit would roll back
    /// to the prior epoch, and the relay may already have stored and served it —
    /// a roster fork (Security Rule 13).
    in_flight_publishes: AtomicUsize,
    /// Fired when [`Self::in_flight_publishes`] reaches zero.
    publish_drained: Notify,
    /// Whether the session is currently serving a BACKGROUND burst rather than
    /// a foreground pass.
    ///
    /// Written by [`super::LiveSyncCore`] from the typed `BurstKind` every open
    /// decides, and by `start` (a session always starts in the foreground). It
    /// is the ONLY input to the receive-side auto-commit policy
    /// ([`Self::auto_commit_policy`]), so "removal-bearing auto-commits stay out
    /// of background bursts" (owner decision OD4-c, option (iv)) is a state read
    /// rather than a convention: one processor serves both lifecycles over the
    /// same engine, and nothing else about a burst distinguishes them.
    background_burst: AtomicBool,
    /// How many commit-shaped things this processor has observed since the
    /// counter was last reset, and when the last one was.
    ///
    /// "Commit activity" is a roster/epoch change routed by
    /// [`Self::route_events`] (`GroupUpdate`) or an auto-commit resolved by
    /// [`Self::resolve_publish_work`] (`PublishWork::AutoPublish`) — the engine
    /// has no `EpochChanged` variant, so those two are the observable surface.
    /// `None` means "nothing has committed since the reset", which is what lets
    /// a settle pay zero.
    commit_activity: Mutex<CommitActivity>,
}

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
    /// Creates a processor over the shared MLS state and bus, with NO relay plane.
    ///
    /// A receive-side auto-commit surfaced through this processor is rolled back
    /// (fail closed, Rule 13) since it cannot be published. Use
    /// [`Self::with_publisher`] for the live-sync path.
    #[must_use]
    pub fn new(circle: Arc<CircleManager>, bus: EventBus) -> Self {
        Self {
            circle,
            bus,
            publisher: None,
            anchors: CursorAnchors::default(),
            inbox_anchor: InboxAnchor::default(),
            delivery: DeliveryLog::default(),
            settled_endpoints: Mutex::new(HashSet::new()),
            eose_notify: Notify::new(),
            eose_coverage: EoseCoverage::default(),
            in_flight_publishes: AtomicUsize::new(0),
            publish_drained: Notify::new(),
            background_burst: AtomicBool::new(false),
            commit_activity: Mutex::new(CommitActivity::default()),
        }
    }

    /// Creates a processor wired to a relay `publisher`, so a receive-side
    /// auto-commit (peer `SelfRemove` eviction) is published to the group's relays
    /// and confirmed ONLY after a ≥1-relay OK-ack (Rule 13 / security F13).
    #[must_use]
    pub fn with_publisher(
        circle: Arc<CircleManager>,
        bus: EventBus,
        publisher: Arc<dyn AutoCommitPublisher>,
    ) -> Self {
        Self {
            circle,
            bus,
            publisher: Some(publisher),
            anchors: CursorAnchors::default(),
            inbox_anchor: InboxAnchor::default(),
            delivery: DeliveryLog::default(),
            settled_endpoints: Mutex::new(HashSet::new()),
            eose_notify: Notify::new(),
            eose_coverage: EoseCoverage::default(),
            in_flight_publishes: AtomicUsize::new(0),
            publish_drained: Notify::new(),
            background_burst: AtomicBool::new(false),
            commit_activity: Mutex::new(CommitActivity::default()),
        }
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

    /// Records which relays owe this GROUP REQ an `EOSE` before the circles it
    /// multiplexes may redeem their cursor advance (see [`EoseCoverage`]).
    pub fn expect_eose_from(&self, sub_id: &SubscriptionId, relays: &[RelayUrl]) {
        self.eose_coverage.expect(sub_id, relays);
    }

    /// Records one endpoint's `EOSE` and answers whether every relay that
    /// accepted this REQ has now finished its stored replay — the only condition
    /// under which [`Self::note_end_of_stored_events`] may be called.
    #[must_use]
    pub fn note_eose_endpoint(&self, key: &RepairKey) -> bool {
        self.eose_coverage.note(key)
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
    /// (`INBOX_GIFTWRAP_LOOKBACK_SECS`) or 49 hours once one is
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
    /// `#[deny(clippy::wildcard_enum_match_arm)]`: the two matches below are the
    /// hold-back gate. A wildcard arm here is how a future variant — of
    /// [`ScreenedIngest`] or of the upstream `IngestOutcome` — silently inherits
    /// "nothing outstanding here", so making one a hard error (clippy runs with
    /// `-D warnings` in CI) forces the decision to be written down.
    #[cfg_attr(test, allow(clippy::missing_panics_doc))]
    #[deny(clippy::wildcard_enum_match_arm)]
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
        let Ok(screened) = self.circle.session().process_event(event).await else {
            self.bus.send(LiveSyncEvent::Status {
                reason: SyncStatusReason::Unprocessable,
            });
            self.anchors.note_unapplied(&group_hex, created_at_secs);
            return GroupProcessOutcome::Unprocessable;
        };

        let ingest = match screened {
            // Rejected by Haven's local screen BEFORE any MLS authentication:
            // the signature, the ephemeral author and the ciphertext are all
            // unverified. No routing, no publish work, no convergence drain —
            // and no hold-back either: there is no un-applied message to come
            // back for, so letting it hold would let one forged event stall the
            // circle's cursor for the whole generation.
            ScreenedIngest::RejectedBeforeAuth(_) => {
                return GroupProcessOutcome::RejectedBeforeAuth;
            }
            ScreenedIngest::Ingested(effects) => effects,
        };

        // Route the drained events, then release any stored convergence + route
        // those, resolving engine publish work as we go.
        self.route_events(&ingest.effects.events, nostr_group_id, created_at_secs);
        self.resolve_publish_work(&ingest.effects.publish).await;
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
                &ingest.effects.pending_convergence,
                nostr_group_id,
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
        match ingest.outcome {
            IngestOutcome::Buffered { .. } => {
                self.anchors.note_unapplied(&group_hex, created_at_secs);
                GroupProcessOutcome::Buffered
            }
            IngestOutcome::Processed => GroupProcessOutcome::Applied,
            IngestOutcome::Stale { .. } => GroupProcessOutcome::Stale,
        }
    }

    /// Drains stored convergence for the pending groups, re-ticking a group that
    /// stays pending until its jitter-delayed `SelfRemove` auto-commit surfaces
    /// (bounded by [`MAX_CONVERGENCE_RETICKS`]).
    ///
    /// A single advance per group would strand the eviction: the engine re-queues
    /// the group until the auto-commit's wall-clock due time passes, and a lone
    /// advance drains it out of the pending set before it comes due. Each pass
    /// routes the drained events and resolves publish work (publishing the
    /// auto-commit over the relay plane, Rule 13). A quiet group (nothing pending)
    /// exits immediately with no delay, so only a leave pays the re-tick cost.
    ///
    /// Returns the strongest member-directory verdict the drained events imply,
    /// for the single reconcile the caller runs once the drain is complete.
    async fn drain_convergence(
        &self,
        initial_pending: &[GroupId],
        nostr_group_id: &[u8],
        event_created_at_secs: i64,
    ) -> Option<DirectoryReconcile> {
        let mut directory = None;
        let mut pending: Vec<GroupId> = initial_pending.to_vec();
        for _ in 0..MAX_CONVERGENCE_RETICKS {
            if pending.is_empty() {
                return directory;
            }
            let mut next: Vec<GroupId> = Vec::new();
            for gid in &pending {
                if let Ok(more) = self.circle.session().advance_convergence(gid).await {
                    self.route_events(&more.events, nostr_group_id, event_created_at_secs);
                    self.resolve_publish_work(&more.publish).await;
                    self.circle.note_inbound_group_events(&more.events);
                    directory =
                        directory.max(self.circle.directory_verdict_for_events(&more.events));
                    next.extend(more.pending_convergence);
                }
            }
            pending = next;
            if !pending.is_empty() {
                tokio::time::sleep(CONVERGENCE_RETICK_DELAY).await;
            }
        }
        directory
    }

    /// Routes an engine `GroupEvent` batch onto the fan-out bus.
    fn route_events(
        &self,
        events: &[crate::nostr::mls::types::GroupEvent],
        nostr_group_id: &[u8],
        event_created_at_secs: i64,
    ) {
        for group_event in events {
            let Some(result) = SessionManager::location_result_from_event(group_event) else {
                continue;
            };
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
                        evolution_event_json: None,
                    });
                }
                // The engine has given up on this group: it will not apply or
                // ingest further state and its one legal exit has no caller at
                // the pinned rev. Surface the TERMINAL per-circle verdict, named
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
    }

    /// Whether a receive-side auto-commit surfaced right now may be published.
    ///
    /// [`ReceiveAutoCommitPolicy::DeferToForeground`] iff this processor is
    /// serving a BACKGROUND burst. Derived from one atomic the session writes
    /// from its typed `BurstKind`, so the scoping cannot drift out of step with
    /// the lifecycle it describes.
    fn auto_commit_policy(&self) -> ReceiveAutoCommitPolicy {
        if self.background_burst.load(Ordering::Acquire) {
            ReceiveAutoCommitPolicy::DeferToForeground
        } else {
            ReceiveAutoCommitPolicy::Publish
        }
    }

    /// Records which lifecycle this processor is serving — see
    /// [`Self::background_burst`].
    pub fn set_background_burst(&self, background: bool) {
        self.background_burst.store(background, Ordering::Release);
    }

    /// Resolves engine publish work surfaced during ingest / convergence.
    ///
    /// On the receive path the engine can auto-commit a peer `SelfRemove`
    /// (`PublishWork::AutoPublish`). Publish-before-apply (Rule 13 / security
    /// F13): the commit is published over the live-sync relay plane and confirmed
    /// ONLY after ≥1 relay OK-acks — never an optimistic confirm, which would
    /// apply an eviction no peer received and fork the group. A publish no relay
    /// acks leaves the removal OWED rather than discarding it
    /// ([`crate::circle::CircleManager::owe_removal_publish`]), so the next
    /// foreground pass retries it; without a relay plane at all the commit is
    /// parked for the same reason. `ApplicationMessage` / `Proposal` publish work
    /// carries no pending ref.
    ///
    /// # In a background burst it publishes nothing
    ///
    /// A receive-side auto-commit is always removal-bearing, and MDK's hydrate
    /// deliberately refuses to recover a removal-bearing staged commit, so a
    /// burst killed between SEND and OK leaves the group wedged with no
    /// `PendingCommitRecovered` and no way back (owner decision OD4-c). Inside a
    /// burst the commit is therefore PARKED as a durable per-circle obligation
    /// and published by the next foreground pass
    /// ([`Self::redeem_removal_deferrals`]). The gauge is not raised for a parked
    /// commit, because nothing is on the wire — which is also what lets the
    /// pause proceed immediately instead of waiting for a publish that will not
    /// happen.
    async fn resolve_publish_work(&self, work: &[PublishWork]) {
        // An auto-commit in this batch is commit activity, and it is recorded
        // BEFORE the publish so a settle that begins while the OK is still in
        // flight already knows the burst is not quiet.
        let commits = work
            .iter()
            .filter(|w| matches!(w, PublishWork::AutoPublish { .. }))
            .count();
        for _ in 0..commits {
            self.note_commit_activity();
        }
        match &self.publisher {
            Some(publisher) => {
                let policy = self.auto_commit_policy();
                // Rule 13: the gauge is raised BEFORE the publisher call and
                // lowered by a drop guard, so a background pause that reads it
                // as non-zero holds the socket open rather than cutting a commit
                // between SEND and OK. `commits` can be 0 (a batch of pure
                // application messages), and raising the gauge for those too
                // would be harmless but dishonest — the gauge means "a publish
                // is on the wire".
                let goes_on_the_wire = commits > 0 && policy == ReceiveAutoCommitPolicy::Publish;
                let _gauge = goes_on_the_wire.then(|| {
                    self.in_flight_publishes.fetch_add(1, Ordering::AcqRel);
                    PublishGauge(&self.in_flight_publishes, &self.publish_drained)
                });
                let deferred = resolve_receive_publish_work_with_policy(
                    &self.circle,
                    publisher.as_ref(),
                    work,
                    policy,
                )
                .await;
                if deferred > 0 {
                    log::info!(
                        "background burst deferred {deferred} removal commit(s) to the \
                         foreground (OD4-c)"
                    );
                }
            }
            None => park_or_rollback_receive_publish_work(&self.circle, work).await,
        }
    }

    /// Publishes every eviction commit THIS session owes, under the Rule-13
    /// ladder.
    ///
    /// FOREGROUND only: the obligation exists precisely so the publish happens
    /// where the process is not about to be suspended. A commit no relay acks
    /// stays owed and is retried on the next foreground pass — never rolled
    /// back, because a rollback is the permanent silent drop
    /// [`crate::circle::CircleManager::owe_removal_publish`] documents.
    ///
    /// It covers what a burst parked AND what a foreground plane published
    /// without getting an ack: both are entries in the same map. What it cannot
    /// cover is an obligation another SESSION recorded — the Android foreground
    /// service and the `WorkManager` catch-up worker each run their own
    /// `CircleManager` over the same DB file (Rule 14 hands the one live session
    /// between them), so their `PendingStateRef`s die with their isolate and
    /// their rows surface at [`Self::report_unrecoverable_circles`] instead.
    pub async fn redeem_removal_deferrals(&self) {
        let Some(publisher) = &self.publisher else {
            return;
        };
        if self.circle.owed_removal_commits().is_empty() {
            return;
        }
        // Rule 13: this publish IS on the wire, so it raises the same gauge the
        // receive path's does. The foreground open that calls this holds the
        // lifecycle lock, so no pause can interleave — but the gauge makes the
        // invariant local instead of resting on a lock the caller happens to
        // hold.
        self.in_flight_publishes.fetch_add(1, Ordering::AcqRel);
        let _gauge = PublishGauge(&self.in_flight_publishes, &self.publish_drained);
        let confirmed = self
            .circle
            .redeem_removal_deferrals(publisher.as_ref())
            .await;
        if confirmed > 0 {
            log::info!("foreground published {confirmed} deferred removal commit(s) (OD4-c)");
        }
    }

    /// Emits the terminal [`LiveSyncEvent::GroupUnrecoverable`] verdict for every
    /// circle this device can no longer move at all, from EITHER cause.
    ///
    /// 1. A parked eviction commit whose engine handle died with the session
    ///    that staged it. Nothing at the pinned MDK rev can publish or clear it —
    ///    see [`crate::circle::CircleManager::orphaned_removal_deferrals`].
    /// 2. A group the engine itself declared `Unrecoverable`
    ///    ([`crate::circle::CircleManager::unrecoverable_circles`]): it will
    ///    neither apply nor ingest further state, and its one legal exit
    ///    (`EpochState::repair_to_stable`) has no caller at the pinned rev.
    ///
    /// Both are terminal and the consumer's repair for both is a re-invite.
    ///
    /// The SECOND cause is here because the engine announces it exactly once —
    /// after `mark_unrecoverable`, every later convergence run short-circuits
    /// before the arm that pushes the event — while the consumer acts only on a
    /// SECOND observation, to keep a circle a peer already healed from telling
    /// its user to rebuild a working circle. One announcement and a
    /// two-observation consumer means a genuinely terminal group would never be
    /// surfaced at all; this sweep is what repeats the verdict. Repetition is
    /// honest for both causes: cause 1 clears when the row clears, cause 2 is a
    /// latch nothing at this rev unlatches.
    ///
    /// # Why this is NOT called from `start`, only from a foreground re-anchor
    ///
    /// There is exactly one way an orphaned deferral can be healed after the
    /// fact: another remaining member publishes the same eviction, and this
    /// device applies it. That commit arrives in the RELAY BACKLOG a session open
    /// requests — so a report issued at `start`, before any backlog has been
    /// served, would name a circle that is about to heal itself. A foreground
    /// re-anchor (the app resume and the health tick) runs on a session that has
    /// already been receiving. Delaying the verdict by one re-anchor costs a
    /// genuinely wedged circle nothing — the state is terminal, not urgent — and
    /// removes a whole class of false positives, which is the one thing this
    /// verdict must never produce.
    ///
    /// # What clears a healed row, and what this cannot distinguish
    ///
    /// A peer's healing commit leaves NO engine event to clear the row on: the
    /// group record's epoch was already projected forward when the commit was
    /// staged, so applying the peer's commit reports `Processed` with an EMPTY
    /// event batch. What clears it instead is the next successful publish for
    /// that circle
    /// ([`crate::circle::CircleManager::discharge_removal_deferral_after_send`]):
    /// the engine accepts an outbound message only from `Stable`, so a send that
    /// succeeds is positive proof that no staged commit remains.
    ///
    /// So the residual window is exactly: a circle a peer healed, whose next
    /// publish has not yet run, at the instant a foreground re-anchor happens.
    /// That reports the verdict once; the following publish clears the row and it
    /// is not repeated. Nothing cheaper closes that window, because at MDK
    /// `e391adc` NO read accessor exposes whether a staged commit is present —
    /// `epoch`, `members`, `group_record` and `current_safe_export_epoch` all
    /// project the post-merge state from the moment of staging.
    ///
    /// It also cannot see a device wedged by a session that predates this code:
    /// there is no row, and the same absence of accessors means the state itself
    /// is unreadable.
    pub fn report_unrecoverable_circles(&self) {
        let mut reported = self.circle.orphaned_removal_deferrals();
        for nostr_group_id in self.circle.unrecoverable_circles() {
            // A circle can be both — an orphaned park is exactly the kind of
            // state that later trips the engine's own verdict — and two verdicts
            // inside ONE sweep read as one observation, so naming it twice would
            // spend a sweep for nothing.
            if !reported.contains(&nostr_group_id) {
                reported.push(nostr_group_id);
            }
        }
        for nostr_group_id in reported {
            self.bus.send(LiveSyncEvent::GroupUnrecoverable {
                nostr_group_id: nostr_group_id.to_vec(),
            });
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
        // Same reason, for the cursor's copy of the answer: a previous
        // generation's `EOSE` must not count towards this one's coverage.
        self.eose_coverage.reopen(key);
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
    /// AND whose REQ at least one relay ACCEPTED — never the pairs it merely
    /// intended. A dead relay in a two-relay bucket is not in the set, so it
    /// cannot time out every burst forever; a burst that issued no inbox REQ
    /// expects no inbox endpoint, so it does not wait on one.
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

    /// Waits — with NO cap — until every publish this processor put on the wire
    /// has resolved.
    ///
    /// Uncapped on purpose (Security Rule 13). The alternative, a time-based
    /// cap, would let a pause `disconnect` a commit between SEND and OK:
    /// `wait_for_ok` then returns `Err`, `publish_failed` rolls the group back to
    /// the prior epoch, and the relay may already have stored and served that
    /// commit to every peer — a roster fork, on a background device, every
    /// couple of minutes. The wait is bounded in practice by the crate's own 10 s
    /// per-relay OK wait, and by [`PublishGauge`], which decrements even if the
    /// publish panics or is cancelled.
    pub async fn wait_publishes_drained(&self) {
        loop {
            let notified = self.publish_drained.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.in_flight_publishes.load(Ordering::Acquire) == 0 {
                return;
            }
            notified.await;
        }
    }

    /// Raises the in-flight publish gauge and hands back the REAL production
    /// drop guard, so a test can hold a publish "between SEND and OK" without a
    /// relay — and without a second, divergent copy of the gauge protocol.
    ///
    /// Test-only: it is the one way to observe the UNCAPPED half of
    /// [`Self::wait_publishes_drained`] on a virtual clock, where no socket may
    /// exist.
    #[cfg(test)]
    pub(crate) fn hold_publish_for_test(&self) -> impl Drop + '_ {
        self.in_flight_publishes.fetch_add(1, Ordering::AcqRel);
        PublishGauge(&self.in_flight_publishes, &self.publish_drained)
    }

    /// Records one commit-shaped observation, for a test that needs the settle
    /// window to have something to measure from without driving a real commit
    /// through MLS.
    #[cfg(test)]
    pub(crate) fn note_commit_activity_for_test(&self) {
        self.note_commit_activity();
    }

    /// How many publishes are between SEND and OK right now.
    ///
    /// Presence-only (a count). The authoritative Rule-13 read taken by the
    /// pause immediately before `client.disconnect()`.
    #[must_use]
    pub fn in_flight_publishes(&self) -> usize {
        self.in_flight_publishes.load(Ordering::Acquire)
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

    /// The `nostr_group_id`s a bus receiver has been told are unrecoverable.
    fn unrecoverable(rx: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        while let Ok(event) = rx.try_recv() {
            if let LiveSyncEvent::GroupUnrecoverable { nostr_group_id } = event {
                out.push(nostr_group_id);
            }
        }
        out
    }

    /// The engine announces `Unrecoverable` ONCE per group per session, and the
    /// consumer acts only on a second observation — so the re-anchor sweep has
    /// to repeat it or a genuinely terminal circle is never surfaced at all.
    ///
    /// The recording site is the production one: `process_group_event` folds the
    /// engine's event batch through `directory_verdict_for_events`, which is the
    /// only place the one-shot announcement is remembered.
    #[tokio::test]
    async fn a_reanchor_sweep_repeats_the_engines_one_shot_unrecoverable_verdict() {
        let fx = setup_alice_bob().await;
        let bus = EventBus::new();
        let mut rx = bus.subscribe();
        let processor = EngineProcessor::new(Arc::clone(&fx.bob), bus);

        assert!(
            unrecoverable(&mut rx).is_empty(),
            "precondition: a healthy circle is reported by neither cause"
        );
        processor.report_unrecoverable_circles();
        assert!(unrecoverable(&mut rx).is_empty());

        let _ = fx
            .bob
            .directory_verdict_for_events(&[GroupEvent::GroupUnrecoverable {
                group_id: fx.mls_group_id.clone(),
            }]);

        processor.report_unrecoverable_circles();
        assert_eq!(
            unrecoverable(&mut rx),
            vec![fx.nostr_group_id.to_vec()],
            "the engine's verdict must reach the consumer from the sweep, named \
             by the pseudonymous id"
        );
        processor.report_unrecoverable_circles();
        assert_eq!(
            unrecoverable(&mut rx),
            vec![fx.nostr_group_id.to_vec()],
            "and AGAIN on the next sweep: the consumer blocks the circle only on \
             a verdict from a later re-anchor, and the engine will never repeat \
             its own — `mark_unrecoverable` latches and every later convergence \
             run short-circuits before the arm that pushes the event"
        );
    }

    /// One sweep names a circle ONCE even when both causes hold, because two
    /// verdicts inside one sweep are one observation to the consumer.
    #[tokio::test]
    async fn a_circle_that_is_wedged_both_ways_is_named_once_per_sweep() {
        let fx = setup_alice_bob().await;
        let bus = EventBus::new();
        let mut rx = bus.subscribe();
        let processor = EngineProcessor::new(Arc::clone(&fx.bob), bus);

        fx.bob
            .storage
            .put_deferred_removal_commit(&fx.nostr_group_id, 1)
            .expect("the durable half alone — an orphaned park");
        let _ = fx
            .bob
            .directory_verdict_for_events(&[GroupEvent::GroupUnrecoverable {
                group_id: fx.mls_group_id.clone(),
            }]);

        processor.report_unrecoverable_circles();
        assert_eq!(
            unrecoverable(&mut rx),
            vec![fx.nostr_group_id.to_vec()],
            "a circle that is wedged both ways must not spend two of the \
             consumer's observations in one sweep — that would block it on the \
             FIRST re-anchor, which is the false positive the second \
             observation exists to prevent"
        );
    }

    /// A `(relay, sub)` key for the coverage tests.
    fn key(relay: &str, sub: &SubscriptionId) -> RepairKey {
        RepairKey {
            relay_url: RelayUrl::parse(relay).expect("a fixture relay url parses"),
            sub_id: sub.clone(),
        }
    }

    #[test]
    fn one_relays_eose_does_not_cover_a_req_two_relays_accepted() {
        // The cursor-safety rule the anchor cannot state on its own: a bucket
        // REQ is one filter over SEVERAL relays and the circle has ONE
        // generation, so redeeming it on the first relay's EOSE advances the
        // cursor over whatever a slower co-bucketed relay had not yet replayed.
        let coverage = EoseCoverage::default();
        let sub = SubscriptionId::new("s_group_0");
        coverage.expect(
            &sub,
            &[
                RelayUrl::parse("wss://fast.example").expect("url"),
                RelayUrl::parse("wss://slow.example").expect("url"),
            ],
        );

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
        coverage.expect(
            &sub,
            &[
                live.clone(),
                RelayUrl::parse("wss://dead.example").expect("url"),
            ],
        );
        assert!(!coverage.note(&key("wss://live.example", &sub)));
        coverage.expect(&sub, &[live]);
        assert!(
            coverage.note(&key("wss://live.example", &sub)),
            "narrowing to the accepted set must resolve an EOSE the earlier, wider \
             expectation already recorded — dropping it would leave the cursor waiting \
             for a second EOSE the relay will never send"
        );
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
        coverage.expect(&sub, &both);
        assert!(!coverage.note(&key("wss://fast.example", &sub)));
        assert!(
            coverage.note(&key("wss://slow.example", &sub)),
            "precondition: the first generation is covered"
        );

        // The next burst re-issues both endpoints.
        coverage.reopen(&key("wss://fast.example", &sub));
        coverage.reopen(&key("wss://slow.example", &sub));
        coverage.expect(&sub, &both);
        assert!(
            !coverage.note(&key("wss://fast.example", &sub)),
            "the new generation must be covered by its OWN answers: inheriting the \
             previous burst's would advance the cursor before the slow relay had \
             replayed a thing"
        );
        assert!(coverage.note(&key("wss://slow.example", &sub)));
    }

    #[test]
    fn a_closed_subscription_leaves_no_coverage_state_behind() {
        // A leaked expectation is a permanent stall for whatever re-uses the id:
        // it would owe an EOSE from a relay that is no longer in the REQ.
        let coverage = EoseCoverage::default();
        let sub = SubscriptionId::new("s_group_0");
        coverage.expect(
            &sub,
            &[
                RelayUrl::parse("wss://gone.example").expect("url"),
                RelayUrl::parse("wss://relay.example").expect("url"),
            ],
        );
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
            .add_members_with_welcomes(&fx.alice_keys, &fx.mls_group_id, vec![carol], &fx.relays)
            .await
            .expect("alice adds carol");
        fx.alice
            .confirm_published(add.pending)
            .await
            .expect("confirm add");

        let processor = EngineProcessor::new(Arc::clone(&fx.bob), EventBus::new());
        let outcome = processor
            .process_group_event(&add.commit_event, &fx.nostr_group_id)
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
            .encrypt_location(&fx.mls_group_id, &fx.alice_keys.public_key(), &loc, 60)
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
            .add_members_with_welcomes(&fx.alice_keys, &fx.mls_group_id, vec![carol], &fx.relays)
            .await
            .expect("alice adds carol");
        fx.alice
            .confirm_published(add.pending)
            .await
            .expect("confirm add");

        // Capture the REAL events the engine emits for a genuine ordinary
        // commit, straight from the same `SessionManager::process_event` both
        // write sites call.
        let screened = fx
            .bob
            .session()
            .process_event(&add.commit_event)
            .await
            .expect("engine ingest");
        let ScreenedIngest::Ingested(ingest) = screened else {
            panic!("a real commit for a live group must reach the engine");
        };
        assert_eq!(
            ingest.outcome,
            IngestOutcome::Processed,
            "precondition: bob really applied the add"
        );
        let real_events = ingest.effects.events;
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
