//! [`LiveSyncCore`] — the persistent receive engine's lifecycle and assembly.
//!
//! Owns the single engine `Client`, the shared settle buffer + event bus + write
//! gate, and the router; spawns the [`super::supervisor`] receiver/worker tasks
//! and issues the multiplexed `#h` (group) and `#p` (inbox) subscriptions.
//!
//! The engine `Client` is built WITHOUT `verify_subscriptions` (it would drop
//! the first stored events of every fresh REQ — see [`build_engine_client`];
//! [`super::supervisor::plane_wants_event`] holds the relay to the filter
//! instead), `automatic_authentication(false)` (never send a
//! NIP-42 AUTH on this socket — no nsec↔circle linkage), a generously-sized
//! notification channel (so a slow decrypt cannot lag the pool), a `Monitor`
//! (for reconnect re-anchoring), and **no** gossip (own-relays-only, PSI-8).

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex as StdMutex, PoisonError};
use std::time::{Duration, Instant};

use nostr::{Filter, PublicKey, RelayUrl, SubscriptionId};
use nostr_sdk::pool::monitor::{Monitor, MonitorNotification};
use nostr_sdk::{Client, ClientOptions, RelayPoolNotification, RelayPoolOptions, RelayStatus};
use tokio::sync::{broadcast, watch, Mutex as TokioMutex, MutexGuard as TokioMutexGuard, RwLock};
use tokio::task::JoinHandle;
use zeroize::Zeroizing;

use crate::circle::CircleManager;
use crate::relay::circle_handle;
use crate::relay::cursor::{since_for_stream, SubscribePhase, STREAM_INBOX_1059};

use super::config::{
    burst_issues_inbox, delivery_silence_window_secs, BURST_BACKLOG_WAIT_SECS,
    BURST_SETTLE_CAP_SECS, BUS_CAP, COMMIT_SETTLE_WINDOW_SECS, INBOX_BURSTS_PER_REQ,
    POOL_NOTIF_CAP, RELAY_LIFECYCLE_OP_TIMEOUT_SECS, SUBSCRIBE_CONNECT_WAIT_SECS,
    SUBSCRIBE_MAX_ATTEMPTS, SUBSCRIBE_RETRY_WAIT_SECS,
};
use super::error::{LiveSyncError, LiveSyncResult};
use super::event::{LiveSyncEvent, SyncStatusReason};
use super::event_bus::EventBus;
use super::gate::generate_session_salt;
use super::health::{
    delivery_is_silent, health_needs_resubscribe, health_needs_targeted_reanchor, HealthAction,
    RelayHealthSnapshot, SubscriptionHealthOutcome,
};
use super::planes::{
    build_relay_set_subscriptions, canonical_relay_set, derive_dynamic_group_sub_id,
    group::group_filter, inbox::inbox_filter, CircleSpec, GroupSubscription, InboxSubscription,
    PlaneKind,
};
use super::processor::{group_cursor_stream, BacklogOutcome, EngineProcessor};
use super::repair::{ClosedKind, RepairKey, RepairQueue};
use super::router::{Router, SubCtx};
use super::supervisor::{intake_queue, run_receiver, run_worker, RawSignal};

/// Cold-start cursor seed: on first subscription a circle's cursor is seeded to
/// `now − SEED_LOOKBACK_SECS` so the engine backfills the recent past without
/// re-fetching the circle's entire history.
const SEED_LOOKBACK_SECS: i64 = 86_400; // 24h

/// Whether the engine may connect to `relay`: WSS only, except a debug-only
/// loopback opt-in (mirrors [`crate::relay::ws_loopback_allowed_for_test`] and
/// `RelayManager::validate_relay_urls`). A plaintext `ws://` would expose the
/// engine socket's metadata; in release builds the loopback branch is compiled
/// out, so every `ws://` is rejected.
pub(crate) fn engine_relay_allowed(relay: &str) -> bool {
    !relay.starts_with("ws://") || crate::relay::ws_loopback_allowed_for_test(relay)
}

/// Builds the engine `Client` with the verified privacy-minimizing options.
///
/// # Why `verify_subscriptions` stays OFF
///
/// nostr-sdk's own filter re-check drops the FIRST stored events of every fresh
/// REQ. `Relay::subscribe_long_lived` (nostr-relay-pool 0.44.3) sends the REQ
/// and only THEN registers the filter locally; an `EVENT` that comes back inside
/// that window finds no registered subscription and is discarded with
/// `SubscriptionNotFound` — silently, with no signal any caller can observe.
/// Its `EOSE` is not subject to the same check, so it still lands and still
/// anchors the cursor to the REQ's open time, i.e. PAST the events that were
/// just dropped: this generation never comes back for them, and only the next
/// REQ's lookback re-requests them. On the inbox plane that is a gift-wrapped
/// invitation that does not arrive until the next session.
///
/// The window is a task-scheduling gap, so it widens exactly when the app is
/// busy and the relay is quick. It is what made
/// `inbox_cursor_poisoning_e2e::a_future_dated_gift_wrap_never_pushes_the_inbox_cursor_past_the_local_clock`
/// flaky (CI runs 31216078806, 31555665220), reproducible locally on two cores.
///
/// Nothing is given up: [`super::supervisor::plane_wants_event`] re-checks the
/// same identity dimensions in the worker, where the router context is
/// registered BEFORE the REQ goes out and no such window exists. Turning this
/// back on would restore the silent drop (guarded by
/// `scripts/ci/check_engine_client_options.sh`).
fn build_engine_client() -> Client {
    let pool_opts = RelayPoolOptions::default().notification_channel_size(POOL_NOTIF_CAP);
    let client_opts = ClientOptions::default()
        .verify_subscriptions(false)
        .automatic_authentication(false)
        .pool(pool_opts);
    // NO `.gossip(...)` — own-relays-only (PSI-8). The `Monitor` is consumed by
    // `run_monitor`, spawned with the supervisor tasks: it is the only place a
    // relay's connect/drop transition becomes a status the UI can show, and
    // without a consumer a dead socket was invisible to the user.
    Client::builder()
        .opts(client_opts)
        .monitor(Monitor::new(64))
        .build()
}

/// One live group REQ in the running session: either a base bucket (a
/// multiplexed `#h` over a shared relay set, assigned once at
/// [`LiveSyncCore::start`]) or a dynamic singleton (one circle added mid-session
/// via [`LiveSyncCore::subscribe_circle`], with its OWN sub-id and its OWN
/// `since`).
///
/// Stored so the delta ops and [`LiveSyncCore::resume_after_background`]
/// mutate / re-anchor the exact live set WITHOUT re-bucketing — re-bucketing a
/// mutated set would shift `build_relay_set_subscriptions`' positional sub-id
/// indices and orphan live REQs. The sub-id is frozen here and reused for the
/// whole session.
#[derive(Debug, Clone)]
struct LiveGroupSub {
    /// The subscription id this REQ was issued under (stable for the session).
    sub_id: SubscriptionId,
    /// The REQ's target relays (canonical set).
    relays: Vec<String>,
    /// The `hex(nostr_group_id)` values this REQ multiplexes (exactly one for a
    /// dynamic singleton).
    group_ids_hex: HashSet<String>,
}

/// The retained live session model: every live group REQ plus the inbox REQ, so
/// [`LiveSyncCore::resume_after_background`] and the delta ops re-anchor / mutate
/// the CURRENT set (never the stale start-time set).
#[derive(Debug, Clone)]
struct ActiveSession {
    /// The live group REQs (base buckets + dynamic singletons).
    group_subs: Vec<LiveGroupSub>,
    /// The inbox relay set (empty ⇒ no inbox REQ).
    inbox_relays: Vec<String>,
    /// The stable inbox sub-id (`derive_sub_id(salt, pk, Inbox, 0)`).
    inbox_sub_id: SubscriptionId,
}

/// Converts a stored [`LiveGroupSub`] back into a [`GroupSubscription`] for
/// re-issue on resume — same stored `sub_id` (NIP-01 replace), sorted `#h`, and
/// NO re-bucketing.
fn to_group_subscription(sub: &LiveGroupSub) -> GroupSubscription {
    let mut group_ids_hex: Vec<String> = sub.group_ids_hex.iter().cloned().collect();
    group_ids_hex.sort();
    GroupSubscription {
        relays: sub.relays.clone(),
        group_ids_hex,
        sub_id: sub.sub_id.clone(),
    }
}

/// Whether [`LiveSyncCore::stop`] observed every supervisor task exit.
///
/// The distinction matters to exactly one caller: something reclaiming an
/// orphaned MLS session needs to know whether the engine's
/// `Arc<CircleManager>` clones — and with them the Rule-14
/// `LiveSessionGuard` — are actually gone by the time `stop` returned.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
#[must_use = "a TimedOut stop left the manager Arc — and the Rule-14 guard — \
              possibly still held; discarding this reports a clean teardown \
              that did not happen"]
pub enum StopOutcome {
    /// No supervisor task is outstanding: either the session was never
    /// started, or a previous `stop` already joined every task. Both mean
    /// nothing this core spawned still holds an `Arc<CircleManager>`.
    NotStarted,
    /// Every supervisor task joined. Every `Arc<CircleManager>` this core and
    /// its tasks held has been dropped by the time `stop` returned.
    Drained,
    /// The join budget elapsed with a task still running. A caller relying on
    /// the `Arc` drop MUST treat this as "not released" and re-check rather
    /// than assume.
    TimedOut,
}

pub struct LiveSyncCore {
    client: Client,
    circle: Arc<CircleManager>,
    processor: Arc<EngineProcessor>,
    router: Arc<RwLock<Router>>,
    bus: EventBus,
    own_pubkey: PublicKey,
    salt: Zeroizing<[u8; 16]>,
    shutdown: Arc<AtomicBool>,
    /// Supervisor task handles from [`Self::start`], joined by [`Self::stop`].
    ///
    /// Retained so `stop` is a real happens-before edge for the `Arc`
    /// drops: a caller that needs the Rule-14 `LiveSessionGuard` released
    /// (the Android foreground service reclaiming an orphaned session) can
    /// only trust `stop`'s return if the tasks holding
    /// `Arc<EngineProcessor>` — and through it `Arc<CircleManager>` — are
    /// known to be gone.
    ///
    /// `std::sync::Mutex`, not the tokio one: it is only ever `take()`n
    /// synchronously and the guard is never held across an `.await` (which
    /// would also make the future non-`Send`).
    tasks: StdMutex<Vec<JoinHandle<()>>>,
    /// Sticky cancellation for the supervisor tasks.
    ///
    /// A `watch` rather than a `Notify` so a receiver created AFTER the send
    /// still observes it — see [`run_receiver`]'s use of `wait_for`.
    ///
    /// This exists because `shutdown` alone CANNOT wake the receiver: it is
    /// polled at the top of the loop, so a task parked in
    /// `notifications.recv().await` never sees it. The only other wake path
    /// was the relay pool's `Shutdown` notification, and that is not
    /// guaranteed to arrive (see [`Self::stop_inner`]).
    cancel_tx: watch::Sender<bool>,
    /// The live subscription model of the active session, retained so
    /// [`Self::resume_after_background`] and the delta ops
    /// ([`Self::subscribe_circle`] / [`Self::unsubscribe_circle`]) re-anchor /
    /// mutate the CURRENT set. `None` until [`Self::start`]. Read-modify-written
    /// only under the [`Self::lifecycle`] lock, so it never races a concurrent
    /// delta op or stop/resume.
    active: Arc<RwLock<Option<ActiveSession>>>,
    /// Serializes the connection-lifecycle operations — [`Self::start`],
    /// [`Self::stop`], and [`Self::resume_after_background`] — so a `stop`'s
    /// `client.shutdown()` (which clears the engine pool via
    /// `force_remove_all_relays`) can never interleave between a `start`'s
    /// `add_relay` and its `subscribe`. Without this, a concurrent `stop_session`
    /// / replacing `start_session` (both act on the SAME `Arc<LiveSyncCore>` this
    /// core is installed as) empties the pool mid-start, so the in-flight
    /// `subscribe_with_id_to` returns `Error::NoRelays` ("no relays") — the
    /// iOS-lane live-sync-start failure. The lock forces a total order: a start
    /// runs to completion (pool intact) before any stop tears it down.
    ///
    /// RELAY-TRIGGERED ACQUIRER: [`run_repair`] takes this lock to re-issue a REQ
    /// a relay ended with `CLOSED`, so — unlike start/stop/resume — an acquisition
    /// can be provoked from off-device. Two things bound what that buys an
    /// adversary: the worker screens a `CLOSED` against the live router before it
    /// is ever scheduled, and [`super::repair`]'s per-`(relay, sub)` jittered
    /// backoff caps how often one endpoint can be re-issued. What a provoked
    /// acquisition CAN still do is make a concurrent [`Self::stop`] wait, and that
    /// wait is bounded only by `reissue`'s own shutdown checks — one on entry and
    /// one per subscribe attempt — not by any timeout on the lock. The repair
    /// task's side of the same hazard (waiting for a lock `stop` holds across its
    /// task join) is closed by acquiring it under `cancel`; see [`run_repair`].
    ///
    /// INVARIANT this lock relies on: `client.shutdown()` (via [`Self::stop`])
    /// and [`Self::rebuild_stalled_relays`]' `force_remove_relay` are the ONLY
    /// operations that take a relay OUT of the engine client's pool, and both
    /// hold this lock. The rebuild is the narrower of the two — one url, removed
    /// and re-added — but the window is the same hazard in a second shape:
    /// `RelayPool::send_event_to` answers `Err(RelayNotFound)` if any named url
    /// is absent, so a publish issued in between fails outright. The lock does
    /// not serialise the WORKER, which is why that rebuild additionally runs only
    /// where a publish cannot be in flight (see that method). If a dynamic
    /// per-circle subscribe/unsubscribe FFI (the M3-deferred `subscribe_circle`)
    /// or any further `client.remove_relay(...)` is ever added, it too must hold
    /// this lock, or it could empty the pool outside the start/stop order and
    /// re-introduce the `NoRelays` race. Relatedly, `register_and_subscribe`
    /// is deliberately NOT `bounded()` (a subscribe bound regressed engine start
    /// in run b7dba45); under the pinned nostr-sdk 0.44 subscribe is local, so this
    /// is safe — but because a concurrent `stop` (logout) now WAITS for `start` to
    /// release this lock, that un-bounded subscribe is the sole thing that could
    /// delay logout. Revisit (bound the subscribe) only alongside an SDK upgrade
    /// where subscribe awaits relay confirmation (see `RELAY_LIFECYCLE_OP_TIMEOUT`).
    lifecycle: Arc<TokioMutex<()>>,
    /// Raised by [`run_receiver`] when the ingest worker has exited: the receive
    /// plane is down and cannot come back without a fresh session.
    ///
    /// Separate from `shutdown` because the two mean opposite things to a
    /// caller: `shutdown` is "we stopped it", this is "it died". Folded into
    /// [`Self::is_running`], which is what the Dart self-heal restarts on.
    wedged: Arc<AtomicBool>,
    /// Subscriptions a relay ended with `CLOSED`, awaiting re-issue by
    /// [`run_repair`]. Written by the worker, drained by the repair task.
    repair: Arc<RepairQueue>,
    /// Whether the session is PAUSED between background bursts: no standing REQ
    /// and no socket, but the same core, the same salt, the same supervisor
    /// tasks, the same router object and the same anchors.
    ///
    /// Distinct from `shutdown` in the way that matters: `shutdown` is terminal
    /// (the salt is zeroized, the pool emptied, a restart needs a fresh core),
    /// while this is a state the next burst leaves by re-issuing every REQ at
    /// its persisted cursor. Rebuilding the core per burst instead would rotate
    /// the sub-id salt every couple of minutes — a fresh relay-visible
    /// fingerprint (PSI-2 declares intra-session sub-id stability intentional) —
    /// and re-spawn the Rule-14 task set on every publish tick.
    ///
    /// Gates: `run_repair` (before `take_due`), `reissue`,
    /// `maintain_subscription_health`, `subscribe_circle`, `unsubscribe_circle`
    /// and `run_monitor`'s `Disconnected` suppression.
    paused: Arc<AtomicBool>,
    /// Whether the engine's radio is OFF: every relay has been terminated and
    /// the session wants NO socket at all until the next open.
    ///
    /// Deliberately NOT the same flag as `paused`. A pause raises `paused`
    /// first and only cuts the radio at its LAST step, because the steps in
    /// between — the `unsubscribe_all`, the drain marker, and above all the
    /// Rule-13 publish-gauge wait — need the sockets they are draining. A
    /// watchdog keyed on `paused` would therefore be licensed to close a socket
    /// with a commit between SEND and OK, which is precisely the cut Rule 13
    /// forbids. Keyed on THIS flag it is licensed only once the pause has
    /// already, deliberately, cut them all.
    ///
    /// Read by [`run_monitor`], which re-terminates any relay that is still up
    /// when it reports itself `Connecting`/`Connected` while this is set (see
    /// [`Self::terminate_all_relays`] for why one can).
    radio_off: Arc<AtomicBool>,
    /// How many relay connect transitions [`run_monitor`] had to cut because
    /// they happened while the radio was off.
    ///
    /// Presence-only (a count, never a url — Rules 4/6). Non-zero means the
    /// crate's own retry loop survived a pause and re-opened a socket this
    /// session never asked for: the fact P4 promises cannot happen.
    unrequested_connections: Arc<AtomicUsize>,
    /// How many BACKGROUND bursts this session has opened, so the inbox REQ can
    /// be folded onto every [`INBOX_BURSTS_PER_REQ`]-th one.
    ///
    /// Background only. The foreground re-anchors ([`Self::maintain_subscription_health`]
    /// and the app-resume) go through the same open path but must not consume a
    /// fold position: they close the standing inbox REQ with their
    /// `unsubscribe_all` and would then leave it un-issued until something else
    /// re-anchored, i.e. no invitation could arrive while the app was open.
    background_bursts: AtomicU64,
    /// Whether the last open ISSUED an inbox REQ.
    ///
    /// The health tick's presence probe counts what the session actually has on
    /// the wire, so under a fold period > 1 it must not expect an inbox
    /// endpoint a non-fold burst deliberately did not open — that shortfall
    /// reads as "a relay deleted our REQ" and re-anchors the whole session every
    /// tick.
    inbox_req_open: AtomicBool,
    /// What [`Self::wait_backlog_settled`] waits on: the endpoints of the last
    /// open that SUCCEEDED, or [`BurstWindow::Closed`] while no open vouches for
    /// any.
    ///
    /// Written under the lifecycle lock by whatever issued the REQs, so a burst
    /// open and the wait that follows it can never disagree about which
    /// endpoints were opened.
    burst_window: Arc<RwLock<BurstWindow>>,
    /// A clone of the ingest queue's `Sender`, so the pause can push its
    /// [`RawSignal::Pause`] marker in BEHIND everything already queued.
    ///
    /// **Dropped by [`Self::stop_inner`], and that is load-bearing.**
    /// `run_worker` exits when its channel closes, which happens only once every
    /// `Sender` is dropped; a clone parked here forever would keep the worker in
    /// `rx.recv()` after `stop`, so `join_tasks` would time out and the Rule-14
    /// `LiveSessionGuard` would read as still held.
    ///
    /// `std::sync::Mutex`: only ever cloned/taken synchronously, never held
    /// across an `.await`.
    intake: StdMutex<Option<tokio::sync::mpsc::Sender<RawSignal>>>,
}

/// Upper bound on a single engine relay control-plane op before the engine gives
/// up on it (see [`RELAY_LIFECYCLE_OP_TIMEOUT_SECS`]).
const RELAY_LIFECYCLE_OP_TIMEOUT: Duration = Duration::from_secs(RELAY_LIFECYCLE_OP_TIMEOUT_SECS);

/// How many times [`LiveSyncCore::terminate_all_relays`] may re-assert a
/// disconnect before it gives up and leaves the rest to the radio-off watch.
///
/// Three, because the first round is the one that races and a re-assert lands
/// on a SLEEPING connection task, which breaks without re-reading any status —
/// so the second round is already the belt and the third the braces. A larger
/// bound would buy nothing and spend the pause's remaining budget on a
/// condition [`run_monitor`] handles for free.
const RELAY_TERMINATE_ROUNDS: u8 = 3;

/// Handshake grace after `connect()` before the first REQ (see
/// [`SUBSCRIBE_CONNECT_WAIT_SECS`]).
const SUBSCRIBE_CONNECT_WAIT: Duration = Duration::from_secs(SUBSCRIBE_CONNECT_WAIT_SECS);

/// Per-retry connection wait between subscribe attempts (see
/// [`SUBSCRIBE_RETRY_WAIT_SECS`]).
const SUBSCRIBE_RETRY_WAIT: Duration = Duration::from_secs(SUBSCRIBE_RETRY_WAIT_SECS);

/// How long a background burst waits for its own REQs' backlog to drain before
/// publishing anyway (see [`BURST_BACKLOG_WAIT_SECS`]).
const BURST_BACKLOG_WAIT: Duration = Duration::from_secs(BURST_BACKLOG_WAIT_SECS);

/// How long the sockets stay open after the last commit activity (see
/// [`COMMIT_SETTLE_WINDOW_SECS`]).
const BURST_SETTLE_WINDOW: Duration = Duration::from_secs(COMMIT_SETTLE_WINDOW_SECS);

/// Total bound on a burst's settle, applying to idle follow-on activity only
/// (see [`BURST_SETTLE_CAP_SECS`]).
const BURST_SETTLE_CAP: Duration = Duration::from_secs(BURST_SETTLE_CAP_SECS);

/// Awaits `fut` under `dur`, mapping an elapsed deadline to
/// [`LiveSyncError::Timeout`]. The caller decides whether a timeout is fatal
/// (start/subscribe) or best-effort (stop). Holds no lock. Private so
/// `clippy::missing_errors_doc` does not require an `# Errors` section.
async fn bounded<T>(dur: Duration, fut: impl Future<Output = T>) -> LiveSyncResult<T> {
    tokio::time::timeout(dur, fut)
        .await
        .map_err(|_| LiveSyncError::Timeout)
}

/// Retries an async subscribe `attempt` until at least one relay in the bucket
/// accepts the REQ, waiting `wait` between tries, up to `max_attempts`.
///
/// The `attempt` future reports:
/// - `Ok(accepted)` with a NON-EMPTY set — the subscribe's `Output.success` set
///   (>= 1 relay took the REQ; a partial success still multiplexes + delivers).
///   Returns that set.
/// - `Ok(accepted)` with an EMPTY set — EVERY relay dropped the REQ (e.g. a
///   relay still mid-handshake). Retryable: `wait`, then re-attempt.
/// - `Err` — a POOL-level failure (no relays / relay-not-found). Not
///   self-healing, so it propagates immediately without retrying.
///
/// The ACCEPTED set — not the requested one — is what comes back, because it is
/// what a background burst may wait on: a dead relay in a two-relay bucket never
/// answers, and expecting it would make every burst spend its whole backlog
/// budget forever.
///
/// After `max_attempts` empty results it returns [`LiveSyncError::Relay`] so the
/// caller can tear the session down VISIBLY rather than silently orphaning the
/// subscription. Bounded: at most `max_attempts` attempts with `max_attempts − 1`
/// `wait`s between them (no `wait` after the final attempt); holds no lock.
/// Private so `clippy::missing_errors_doc` does not require an `# Errors` section.
///
/// Extracted from [`LiveSyncCore::subscribe_bucket`] so the retry DECISION logic
/// is unit-testable against plain closures, with no `Client` or network.
async fn retry_until_accepted<A, AF, W, WF>(
    max_attempts: u32,
    mut attempt: A,
    mut wait: W,
) -> LiveSyncResult<Vec<RelayUrl>>
where
    A: FnMut() -> AF,
    AF: Future<Output = LiveSyncResult<Vec<RelayUrl>>>,
    W: FnMut() -> WF,
    WF: Future<Output = ()>,
{
    for i in 0..max_attempts {
        match attempt().await {
            Ok(accepted) if !accepted.is_empty() => return Ok(accepted),
            Ok(_) => {}
            Err(e) => return Err(e),
        }
        // Wait for the sockets to finish before the next attempt — but never
        // after the final one (no point waiting only to give up).
        if i + 1 < max_attempts {
            wait().await;
        }
    }
    Err(LiveSyncError::relay(
        "subscribe: every relay in the bucket dropped the REQ across all attempts",
    ))
}

/// Everything issuing one REQ touches, borrowed from whoever drives it.
///
/// Extracted so the repair task ([`run_repair`]) re-issues a subscription
/// through the SAME code the session's own start / resume / delta paths use. A
/// second REQ builder would be a second place for the cursor-anchor ordering
/// (open the generation BEFORE the REQ, at the same `now` the `since` is derived
/// from), the accept-retry, and the shutdown interruption points to drift out of
/// agreement — and the anchor ordering is the one whose drift is silent and
/// permanent.
struct SubscribeCtx<'a> {
    client: &'a Client,
    circle: &'a CircleManager,
    processor: &'a EngineProcessor,
    router: &'a RwLock<Router>,
    shutdown: &'a AtomicBool,
    own_pubkey: PublicKey,
}

impl SubscribeCtx<'_> {
    /// Computes the bucket REQ `since` (seconds) as the minimum over the
    /// bucket's circles' per-circle cursors, so a multiplexed `#h` REQ never
    /// raises the `since` floor past any one circle's un-applied events.
    fn bucket_since(&self, group_ids_hex: &[String], phase: SubscribePhase, now: i64) -> i64 {
        group_ids_hex
            .iter()
            .map(|hex| {
                let key = group_cursor_stream(hex);
                let cursor = self
                    .circle
                    .read_sync_cursor(&key)
                    .ok()
                    .flatten()
                    .unwrap_or(0);
                since_for_stream(&key, cursor, phase, now)
            })
            .min()
            .unwrap_or(0)
    }

    /// Issues ONE bucket subscription (`sub_id` + `filter` over `relays`) with a
    /// BOUNDED accept-retry.
    ///
    /// [`nostr_sdk::Client::subscribe_with_id_to`] returns `Ok(Output)` even when
    /// a relay dropped the REQ mid-handshake — the drop lands in `Output.failed`,
    /// NOT in the `Result` — so a fire-and-forget `.await?` would proceed as
    /// SUBSCRIBED while the circle is silently orphaned (no events ever
    /// delivered). This inspects `Output.success`: a non-empty set (>= 1 relay
    /// took the REQ) is accepted; an empty set (every relay dropped it) retries
    /// after a short [`SUBSCRIBE_RETRY_WAIT`] connection wait, up to
    /// [`SUBSCRIBE_MAX_ATTEMPTS`]. Exhausting the attempts returns
    /// [`LiveSyncError::Relay`] so `start` tears the session down VISIBLY instead
    /// of leaving a half-started engine with an orphaned circle.
    ///
    /// It bounds a WAIT (`wait_for_connection`, which returns early on connect),
    /// never the subscribe call itself — a bound on the `verify_subscriptions`
    /// cold subscribe previously regressed engine start (run b7dba45) — so it does
    /// not reintroduce that regression.
    async fn subscribe_bucket(
        &self,
        relays: Vec<String>,
        sub_id: SubscriptionId,
        filter: Filter,
    ) -> LiveSyncResult<Vec<RelayUrl>> {
        retry_until_accepted(
            SUBSCRIBE_MAX_ATTEMPTS,
            || async {
                // Interruptible (teardown promptness): once a concurrent `stop`
                // raises `shutdown`, abandon the subscribe AND its remaining retries
                // at once and fail closed, so this lifecycle-lock holder releases
                // the lock and `stop` proceeds. This is the "un-bounded subscribe"
                // the lifecycle doc calls out as the one thing that could delay
                // logout. Failing closed (never issuing the REQ) also cannot orphan
                // a subscription onto a pool `stop` is about to empty.
                if self.shutdown.load(Ordering::Acquire) {
                    return Err(LiveSyncError::NoSession);
                }
                let output = self
                    .client
                    .subscribe_with_id_to(relays.clone(), sub_id.clone(), filter.clone(), None)
                    .await
                    .map_err(LiveSyncError::relay)?;
                // >= 1 relay accepted the REQ ⇒ the bucket is subscribed (a shared
                // relay set multiplexes, so one live socket still delivers). The
                // ACCEPTING relays come back: they are the endpoints a burst may
                // expect an answer from.
                Ok(output.success.into_iter().collect())
            },
            || self.client.wait_for_connection(SUBSCRIBE_RETRY_WAIT),
        )
        .await
    }

    /// Starts the per-endpoint silence window for every relay this REQ is issued
    /// to, and returns them parsed.
    fn open_delivery_windows(
        &self,
        relays: &[String],
        sub_id: &SubscriptionId,
        now: i64,
    ) -> Vec<RelayUrl> {
        let urls: Vec<RelayUrl> = relays
            .iter()
            .filter_map(|relay| RelayUrl::parse(relay).ok())
            .collect();
        for relay_url in &urls {
            self.processor.open_delivery_window(
                &RepairKey {
                    relay_url: relay_url.clone(),
                    sub_id: sub_id.clone(),
                },
                now,
            );
        }
        urls
    }

    /// Registers the router, opens each circle's cursor-anchor generation, and
    /// issues ONE group REQ over `relays` under `sub_id`.
    ///
    /// The anchor generation is opened BEFORE the REQ goes out, at the same
    /// `now` the `since` is derived from, so the anchor is the local instant we
    /// asked — never later than the request it vouches for, and never a value
    /// any relay or event author can influence. Opening before the subscribe
    /// also means a stored event arriving while the accept-retry is still
    /// running already has a generation to hold back.
    async fn issue_group(
        &self,
        relays: &[String],
        sub_id: &SubscriptionId,
        group_ids_hex: &[String],
        phase: SubscribePhase,
        now: i64,
    ) -> LiveSyncResult<Vec<RepairKey>> {
        let group_ids: HashSet<String> = group_ids_hex.iter().cloned().collect();
        self.router
            .write()
            .await
            .register_group(relays, sub_id, &group_ids);
        for hex in group_ids_hex {
            self.processor.note_subscription_opened(hex, now);
        }
        // One silence window per REQ ENDPOINT, so a single-relay repair re-seeds
        // only the relay it re-subscribed and the bucket's other relays keep
        // running out (see `EngineProcessor::open_delivery_window`).
        let issued = self.open_delivery_windows(relays, sub_id, now);
        // Provisionally, everyone this REQ goes to owes an EOSE. Recorded BEFORE
        // the subscribe, because a fast relay can answer while the call is still
        // returning and an empty expectation would let that one answer redeem
        // the whole bucket's advance.
        self.processor.expect_eose_from(sub_id, &issued);
        let since = self.bucket_since(group_ids_hex, phase, now);
        let filter = group_filter(group_ids_hex, since);
        let accepted = self
            .subscribe_bucket(relays.to_vec(), sub_id.clone(), filter)
            .await?;
        // Narrowed to the relays that ACCEPTED it: a relay that refused the REQ
        // owes nothing, and leaving it in the set would pin these circles'
        // cursors on an answer that can never come.
        self.processor.expect_eose_from(sub_id, &accepted);
        Ok(endpoints(&accepted, sub_id))
    }

    /// Registers the router, opens the inbox cursor-anchor generation, and
    /// issues the `kind:1059` REQ over `relays` under `sub_id`.
    ///
    /// The generation is opened on the SAME `now` the `since` is derived from,
    /// for the same reason as the group plane — and it matters more here: this
    /// is the ONLY input to the inbox advance, and no remote party can write it.
    /// A gift wrap's own `created_at` is chosen by whoever wrapped it, and a
    /// `#p`-routed wrap costs one NIP-44 encryption to a published npub (see
    /// [`super::anchor::InboxAnchor`]).
    async fn issue_inbox(
        &self,
        relays: &[String],
        sub_id: &SubscriptionId,
        phase: SubscribePhase,
        now: i64,
    ) -> LiveSyncResult<Vec<RepairKey>> {
        {
            let mut router = self.router.write().await;
            for relay in relays {
                router.register(
                    relay,
                    sub_id,
                    SubCtx {
                        plane: PlaneKind::Inbox,
                        group_ids_hex: HashSet::new(),
                    },
                );
            }
        }
        self.processor.note_inbox_subscription_opened(now);
        self.open_delivery_windows(relays, sub_id, now);
        let inbox_cursor = self
            .circle
            .read_sync_cursor(STREAM_INBOX_1059)
            .ok()
            .flatten()
            .unwrap_or(0);
        let since = since_for_stream(STREAM_INBOX_1059, inbox_cursor, phase, now);
        let filter = inbox_filter(self.own_pubkey, since);
        let accepted = self
            .subscribe_bucket(relays.to_vec(), sub_id.clone(), filter)
            .await?;
        Ok(endpoints(&accepted, sub_id))
    }
}

/// Which caller opened a set of REQs.
///
/// The two share one open path but differ in exactly one decision: only a
/// background burst may fold the inbox REQ away, because only a background
/// burst is followed by a pause that closes every REQ anyway. A foreground
/// re-anchor that skipped the inbox would leave the standing inbox REQ closed
/// (its own `unsubscribe_all` closed it) and un-issued.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BurstKind {
    /// The app-resume re-anchor and the health tick's whole-session repair.
    Foreground,
    /// One iOS background publish tick's burst.
    Background,
}

/// Whether an open has installed an endpoint set for
/// [`LiveSyncCore::wait_backlog_settled`] to wait on.
///
/// Two states rather than a bare `Vec`, because an empty vector is a
/// LEGITIMATE open — a non-fold burst on a session with no circles issues no
/// REQ and must settle immediately — so "the open failed / none has run" cannot
/// be spelled the same way without answering `Settled` for it. The wait reads
/// this instead of an endpoint list, so it can only ever claim a settle an open
/// vouches for; a caller that ignores a failed open's `Err` gets `TimedOut`, the
/// outcome that promises nothing.
#[derive(Debug, Clone, PartialEq, Eq)]
enum BurstWindow {
    /// No open vouches for an endpoint set: none has run yet, the last one
    /// failed part-way (an open closes the window before it touches anything),
    /// or a pause has since closed the REQs the last one named.
    Closed,
    /// The `(relay, subscription)` endpoints the last SUCCESSFUL open issued AND
    /// that at least one relay accepted.
    Open(Vec<RepairKey>),
}

/// Every relay the active session's REQs target, group and inbox alike.
///
/// A burst open registers this union in the pool BEFORE `connect()`. A circle
/// subscribed while paused pushed a `LiveGroupSub` into `active` but could not
/// add its relay to a pool that had no socket, so without the union its REQ
/// would be issued to a relay the pool does not hold — and the whole burst open
/// would fail on that one bucket's `?`, leaving the circle silent in the
/// background.
fn relay_union(active: &ActiveSession) -> HashSet<String> {
    let mut all: HashSet<String> = HashSet::new();
    for g in &active.group_subs {
        all.extend(g.relays.iter().cloned());
    }
    all.extend(active.inbox_relays.iter().cloned());
    all
}

/// The `(relay, subscription)` endpoints one REQ opened, from the relays that
/// ACCEPTED it.
fn endpoints(accepted: &[RelayUrl], sub_id: &SubscriptionId) -> Vec<RepairKey> {
    accepted
        .iter()
        .map(|relay_url| RepairKey {
            relay_url: relay_url.clone(),
            sub_id: sub_id.clone(),
        })
        .collect()
}

impl LiveSyncCore {
    /// Builds an engine over `circle` for `own_pubkey`, with a fresh ephemeral
    /// sub-id salt and a dedicated engine `Client`. Does not connect or
    /// subscribe — call [`Self::start`].
    #[must_use]
    pub fn new_local(circle: Arc<CircleManager>, own_pubkey: PublicKey) -> Self {
        let bus = EventBus::with_capacity(BUS_CAP);
        let client = build_engine_client();
        // The processor publishes receive-side auto-commits (a peer `SelfRemove`
        // eviction) over the SAME already-connected engine sockets and confirms
        // only after a ≥1-relay OK-ack (Rule 13 / security F13). `Client` is
        // cheaply cloneable (internally `Arc`-backed).
        let publisher: Arc<dyn crate::relay::auto_commit::AutoCommitPublisher> =
            Arc::new(client.clone());
        let processor = Arc::new(EngineProcessor::with_publisher(
            Arc::clone(&circle),
            bus.clone(),
            publisher,
        ));
        Self {
            client,
            circle,
            processor,
            router: Arc::new(RwLock::new(Router::new())),
            bus,
            own_pubkey,
            salt: generate_session_salt(),
            shutdown: Arc::new(AtomicBool::new(false)),
            tasks: StdMutex::new(Vec::new()),
            cancel_tx: watch::channel(false).0,
            active: Arc::new(RwLock::new(None)),
            lifecycle: Arc::new(TokioMutex::new(())),
            wedged: Arc::new(AtomicBool::new(false)),
            repair: Arc::new(RepairQueue::default()),
            paused: Arc::new(AtomicBool::new(false)),
            radio_off: Arc::new(AtomicBool::new(false)),
            unrequested_connections: Arc::new(AtomicUsize::new(0)),
            background_bursts: AtomicU64::new(0),
            inbox_req_open: AtomicBool::new(false),
            burst_window: Arc::new(RwLock::new(BurstWindow::Closed)),
            intake: StdMutex::new(None),
        }
    }

    /// The event bus a consumer subscribes to for decrypted locations, group
    /// updates, invitations, and status signals.
    #[must_use]
    pub const fn bus(&self) -> &EventBus {
        &self.bus
    }

    /// The shared MLS state owner — the SAME `Arc<CircleManager>` (one
    /// process-global [`SessionManager`], Rule 14) the engine processor mutates.
    /// The engine owns convergence internally now, so all writes serialize
    /// through the session's single `tokio` mutex.
    ///
    /// [`SessionManager`]: crate::nostr::mls::SessionManager
    // Dark Matter: consumed by DM-3/DM-4 engine-loop wiring; currently exercised
    // only by the live-sync session unit tests.
    #[allow(dead_code)]
    #[must_use]
    pub(crate) const fn circle(&self) -> &Arc<CircleManager> {
        &self.circle
    }

    /// Whether the session is live: not stopped, and its ingest worker is still
    /// alive.
    ///
    /// The second term is the fix for a silent death. `run_receiver` used to
    /// match only `TrySendError::Full`, so a `Closed` channel — the worker
    /// having exited — fell through with no signal at all, and this method (a
    /// bare read of the shutdown flag) kept answering `true` for a session that
    /// could never ingest another event. The Dart self-heal short-circuits on
    /// exactly this value, so a dead engine reported itself healthy forever.
    ///
    /// Deliberately NOT folding in "every expected subscription is present". A
    /// missing REQ is repairable in place, and it is repaired by
    /// [`Self::maintain_subscription_health`] — which no-ops when this method
    /// answers `false`. Reporting a missing subscription here would therefore
    /// disable the one thing that heals it. It is reported through the health
    /// snapshot instead, where it belongs.
    #[must_use]
    pub fn is_running(&self) -> bool {
        !self.shutdown.load(Ordering::Acquire) && !self.wedged.load(Ordering::Acquire)
    }

    /// Clamps any cursor parked in the FUTURE back to `now_secs`, on every
    /// stream this session is about to REQ. Best-effort.
    ///
    /// # Why a future cursor cannot be waited out
    ///
    /// [`since_for_stream`] caps the derived REQ floor at `now`, so a cursor
    /// above the wall clock does not produce a future-dated filter — it pins
    /// EVERY floor at `now` for the duration of the skew. And the advance path
    /// is monotonic-max, so nothing in it can ever bring such a value back
    /// down: it has to be clamped explicitly, or it lasts exactly as long as
    /// the timestamp that produced it — forever, if that timestamp was chosen.
    ///
    /// The inbox stream is where this actually bit. A pre-fix build advanced
    /// `inbox_1059` from a `kind:1059` gift wrap's outer `created_at`, which
    /// anyone who knows this user's published npub can set to any value (see
    /// [`super::anchor::InboxAnchor`]). Deleting that write path stops new
    /// poisoning but does nothing for a device that already took one, and a
    /// pinned inbox floor is fatal rather than merely wasteful: NIP-59 mandates
    /// backdating, so a floor at `now` filters out even a wrap published this
    /// second.
    ///
    /// Applied to the group streams too, where it is a standing guard against a
    /// local clock that jumped forward and back rather than a migration. In
    /// both cases LOWERING a cursor is the safe direction — it only widens the
    /// next REQ — and the clamp is conditional, so a healthy cursor below the
    /// clock is left exactly where it is.
    fn repair_future_cursors(&self, circles: &[CircleSpec], has_inbox: bool, now_secs: i64) {
        let now_ms = now_secs.saturating_mul(1000).max(0);
        for c in circles {
            let _ = self
                .circle
                .clamp_sync_cursor_down_to(&group_cursor_stream(&c.group_id_hex), now_ms);
        }
        if has_inbox
            && self
                .circle
                .clamp_sync_cursor_down_to(STREAM_INBOX_1059, now_ms)
                .unwrap_or(false)
        {
            log::warn!("[live_sync] inbox cursor was ahead of the local clock; clamped to now");
        }
    }

    /// Borrows this session's REQ-issuing handles. The repair task builds the
    /// same view over owned clones, so both drive one implementation.
    fn ctx(&self) -> SubscribeCtx<'_> {
        SubscribeCtx {
            client: &self.client,
            circle: &self.circle,
            processor: &self.processor,
            router: &self.router,
            shutdown: &self.shutdown,
            own_pubkey: self.own_pubkey,
        }
    }

    /// See [`SubscribeCtx::bucket_since`].
    fn bucket_since(&self, group_ids_hex: &[String], phase: SubscribePhase, now: i64) -> i64 {
        self.ctx().bucket_since(group_ids_hex, phase, now)
    }

    /// Starts the session: seeds cold-start cursors, connects the relays, spawns
    /// the supervisor (BEFORE the first REQ — the no-loss ordering fix), then
    /// registers and issues the multiplexed group + inbox subscriptions.
    ///
    /// # Errors
    ///
    /// Returns [`LiveSyncError::NoSession`] if this core was already stopped (a
    /// stopped `Client` cannot be restarted — build a fresh [`Self::new_local`]),
    /// or [`LiveSyncError::Relay`] if a subscription fails.
    pub async fn start(
        &self,
        circles: &[CircleSpec],
        inbox_relays: &[String],
    ) -> LiveSyncResult<()> {
        // Serialize against `stop`/`resume`: hold the lifecycle lock for the whole
        // start so a concurrent `stop` (which shuts the engine `Client` down and
        // clears its relay pool) cannot land between the `add_relay`s and the
        // first `subscribe`. See [`Self::lifecycle`]. Under the lock, `shutdown`
        // is authoritative: a stop can only set it while ALSO holding this lock,
        // so this check + the subscribe below observe a consistent client.
        let _lifecycle = self.lifecycle.lock().await;
        if self.shutdown.load(Ordering::Acquire) {
            // A stop already ran (or won the lock first): the `Client` is shut
            // down and its pool cleared, so a subscribe here would return the
            // opaque pool `NoRelays` ("no relays"). Fail closed with a precise
            // error instead — the caller rebuilds a fresh core to restart.
            return Err(LiveSyncError::NoSession);
        }
        let now = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap_or(i64::MAX);
        let seed_ms = now
            .saturating_sub(SEED_LOOKBACK_SECS)
            .saturating_mul(1000)
            .max(0);

        // Which inbox lookback this start has EARNED, decided BEFORE the seed
        // below writes one. `Initial`'s 7-day replay is the price of not knowing
        // when this device last heard an inbox EOSE; a persisted cursor IS that
        // knowledge, and it outlives the process. Keying the phase on "fresh
        // core" instead would charge the cold-start width on every engine
        // restart — and the engine is restarted whenever sharing is toggled off
        // and the user glances at the app again, i.e. several times an hour.
        let inbox_phase = if self
            .circle
            .read_sync_cursor(STREAM_INBOX_1059)
            .ok()
            .flatten()
            .is_some()
        {
            SubscribePhase::Resubscribe
        } else {
            SubscribePhase::Initial
        };

        // Cold-start cursor seeding (best-effort; a storage error must not abort
        // the session — an unseeded cursor merely fetches a wider window).
        for c in circles {
            let _ = self
                .circle
                .seed_sync_cursor_if_unset(&group_cursor_stream(&c.group_id_hex), seed_ms);
        }
        if !inbox_relays.is_empty() {
            let _ = self
                .circle
                .seed_sync_cursor_if_unset(STREAM_INBOX_1059, seed_ms);
        }
        self.repair_future_cursors(circles, !inbox_relays.is_empty(), now);

        let own_pk_bytes = self.own_pubkey.to_bytes();
        let (group_subs, inbox_sub) =
            build_relay_set_subscriptions(&self.salt, &own_pk_bytes, circles, inbox_relays);

        // Connect every relay (group ∪ inbox) once.
        let mut all_relays: HashSet<String> = HashSet::new();
        for g in &group_subs {
            all_relays.extend(g.relays.iter().cloned());
        }
        all_relays.extend(inbox_sub.relays.iter().cloned());

        // WSS-only gate (mirrors `RelayManager::validate_relay_urls`): the
        // always-on engine must NOT open a plaintext `ws://` standing
        // connection, which would expose this socket's sub-ids, the multiplexed
        // `#h` circle hexes, the `#p` recipient pubkey, and exact timing to any
        // passive on-path observer. Fail closed (before spawning the supervisor,
        // so no teardown is needed) — release builds reject every `ws://`.
        for relay in &all_relays {
            if !engine_relay_allowed(relay) {
                return Err(LiveSyncError::relay(format!(
                    "plaintext ws:// not allowed for the live-sync engine: {relay}"
                )));
            }
        }
        for relay in &all_relays {
            let _ = self.client.add_relay(relay.as_str()).await;
        }
        self.client.connect().await;
        // `connect()` only SPAWNS the per-relay connect tasks and returns; give
        // the WebSocket handshakes a bounded, early-returning grace to finish so
        // the first REQ (issued below) lands on a live socket instead of dropping
        // into `Output.failed`. Bounds a WAIT, not the subscribe call itself.
        self.client
            .wait_for_connection(SUBSCRIBE_CONNECT_WAIT)
            .await;

        // Interruptible: a concurrent `stop` may have raised `shutdown` during the
        // connect wait above. Bail BEFORE spawning the supervisor / issuing any REQ
        // so the lifecycle lock is released promptly for the waiting stop, tearing
        // down what we opened (add_relay + connect) via the non-locking inner stop
        // (idempotent with the concurrent stop's own `stop_inner`). Fail closed —
        // the caller rebuilds a fresh core to restart.
        if self.shutdown.load(Ordering::Acquire) {
            self.stop_inner().await;
            return Err(LiveSyncError::NoSession);
        }

        // Spawn the supervisor BEFORE the first subscribe so no event delivered
        // during the subscribe round-trip is missed (notifications() only yields
        // events seen after the receiver exists).
        let notifications: broadcast::Receiver<RelayPoolNotification> = self.client.notifications();
        let (tx, rx) = intake_queue();
        // Keep a `Sender` clone so a pause can push its marker in BEHIND
        // everything already queued (drain-then-clear, Rule 12). `stop_inner`
        // drops it — see the `intake` field doc for why that is not optional.
        *self.intake.lock().unwrap_or_else(PoisonError::into_inner) = Some(tx.clone());
        // The worker just drains events and feeds them to the engine (which owns
        // convergence + publish-before-apply internally); no per-circle gate /
        // settle buffer / converge task is needed anymore (plan §5.4).
        self.spawn_supervisor(notifications, tx, rx);

        // Register the router + issue every REQ. A failure mid-way must leave a
        // CLEANLY-STOPPED engine, not a half-started one (orphaned tasks, stale
        // router entries, un-CLOSEd REQs); so on any error we tear down before
        // returning, and the caller can retry with a fresh `new_local`.
        match self
            .register_and_subscribe(
                &group_subs,
                &inbox_sub,
                now,
                SubscribePhase::Initial,
                inbox_phase,
            )
            .await
        {
            Ok(opened) => *self.burst_window.write().await = BurstWindow::Open(opened),
            Err(e) => {
                // Already holding the lifecycle lock — tear down via the
                // non-locking inner stop (calling `self.stop()` here would
                // re-acquire and deadlock).
                self.stop_inner().await;
                return Err(e);
            }
        }

        // Retain the LIVE subscription model (frozen sub-ids) so a background
        // resume re-anchors — and the delta ops mutate — the CURRENT set without
        // re-bucketing (which would shift positional sub-ids and orphan REQs).
        let live_group_subs = group_subs
            .iter()
            .map(|g| LiveGroupSub {
                sub_id: g.sub_id.clone(),
                relays: g.relays.clone(),
                group_ids_hex: g.group_ids_hex.iter().cloned().collect(),
            })
            .collect();
        *self.active.write().await = Some(ActiveSession {
            group_subs: live_group_subs,
            inbox_relays: inbox_sub.relays.clone(),
            inbox_sub_id: inbox_sub.sub_id.clone(),
        });

        self.bus.send(LiveSyncEvent::Status {
            reason: SyncStatusReason::Connected,
        });
        // A session always STARTS in the foreground lifecycle: the bursts come
        // later, through `open_background_burst`. Setting it explicitly rather
        // than relying on the constructor's default means a core reused across a
        // stop/start cannot inherit the last burst's lifecycle and defer a
        // foreground eviction commit into a deferral nothing would redeem.
        //
        // It deliberately does NOT redeem a parked eviction commit here, even
        // though the lifecycle it just set would allow it. `start` cannot tell a
        // foreground launch from a background wake that cold-launched the process
        // (the caller knows; this does not), and redeeming in the second case is
        // exactly the publish-before-apply window OD4-c option (iv) removes. So
        // the ONE place a removal-bearing auto-commit is published or redeemed is
        // a FOREGROUND open — see `resume_burst`. A parked commit therefore waits
        // for the app resume or the health tick's re-anchor, and that circle's
        // sends stay refused until then.
        self.processor.set_background_burst(false);
        Ok(())
    }

    /// Spawns the session's four long-lived tasks and retains their handles so
    /// [`Self::stop`] joins them.
    ///
    /// Being in `tasks` is what makes `stop` a happens-before edge for the
    /// `Arc<CircleManager>` drops, and with them the Rule-14 `LiveSessionGuard`:
    /// the receiver, the worker and the repair task each hold one. Anything that
    /// spawns such a task outside this vec re-creates the orphaned-MLS-session
    /// hazard (see the `tasks` field doc).
    fn spawn_supervisor(
        &self,
        notifications: broadcast::Receiver<RelayPoolNotification>,
        tx: tokio::sync::mpsc::Sender<super::supervisor::RawSignal>,
        rx: tokio::sync::mpsc::Receiver<super::supervisor::RawSignal>,
    ) {
        let receiver_task = tokio::spawn(run_receiver(
            notifications,
            tx,
            Arc::clone(&self.processor),
            Arc::clone(&self.shutdown),
            Arc::clone(&self.wedged),
            self.cancel_tx.subscribe(),
        ));
        let worker_task = tokio::spawn(run_worker(
            rx,
            Arc::clone(&self.router),
            Arc::clone(&self.processor),
            Arc::clone(&self.repair),
            self.own_pubkey,
        ));
        // The repair task re-issues a REQ a relay ended. It runs OUTSIDE the
        // worker on purpose: a re-issue takes the lifecycle lock, and a worker
        // parked on that lock during a start/resume would stall ingest for the
        // whole network round-trip.
        let repair_task = tokio::spawn(run_repair(self.repair_plane(), self.cancel_tx.subscribe()));
        let mut tasks = self.tasks.lock().unwrap_or_else(PoisonError::into_inner);
        tasks.push(receiver_task);
        tasks.push(worker_task);
        tasks.push(repair_task);
        // The pool `Monitor` had no consumer, so a relay dropping was invisible
        // to the user: `Disconnected` / `Reconnecting` were emitted by nothing.
        // This task is the consumer, and also the radio-off watch. It holds no
        // `Arc<CircleManager>`, so it adds no Rule-14 lifetime edge; the `Client`
        // clone is an `Arc` over the relay pool only, and this task is joined
        // here anyway so nothing outlives `stop`.
        if let Some(monitor) = self.client.monitor() {
            tasks.push(tokio::spawn(run_monitor(
                monitor.subscribe(),
                self.bus.clone(),
                Arc::clone(&self.paused),
                RadioOffWatch {
                    radio_off: Arc::clone(&self.radio_off),
                    client: self.client.clone(),
                    cut: Arc::clone(&self.unrequested_connections),
                },
                self.cancel_tx.subscribe(),
            )));
        }
    }

    /// Registers the router contexts and issues the multiplexed group + inbox
    /// REQs. `phase` drives the GROUP buffer (`Initial` on first start,
    /// `Resubscribe` on resume — a wider clock-skew buffer). A subscribe failure
    /// short-circuits; the caller tears the session down on error.
    ///
    /// `inbox_phase` is separate because the two planes read the phase for
    /// opposite reasons. The group buffer asks "how long was this socket down",
    /// which only the caller knows; the inbox lookback asks "do we know when we
    /// last heard an EOSE", which the PERSISTED cursor answers across process
    /// lifetimes. So a fresh core over a known inbox cursor is a group `Initial`
    /// and an inbox `Resubscribe`.
    async fn register_and_subscribe(
        &self,
        group_subs: &[GroupSubscription],
        inbox_sub: &InboxSubscription,
        now: i64,
        phase: SubscribePhase,
        inbox_phase: SubscribePhase,
    ) -> LiveSyncResult<Vec<RepairKey>> {
        // Diagnostic (M11 e2e triage): HOW MANY circles this (re)subscribe anchors
        // onto, bucketed. It used to join one alias handle per circle, which made
        // the line's cardinality this account's exact circle count — a magnitude
        // Rule 15 forbids even at debug level, and one the handles cannot
        // anonymise because the number of them IS the disclosure. The bucket
        // keeps the signal the triage wanted ("did the fresh circle reach the
        // REQ at all"); WHICH circle each later per-circle line concerns is still
        // named by a handle there.
        let circle_count: usize = group_subs.iter().map(|g| g.group_ids_hex.len()).sum();
        // log-scan-ok: the only {:?} here are SubscribePhase, a fieldless enum whose Debug is a variant name
        log::debug!(
            "[live_sync::subscribe] register_and_subscribe phase={phase:?} \
             inbox_phase={inbox_phase:?}: circles={}",
            crate::log_alias::bucket(circle_count)
        );
        let ctx = self.ctx();
        // The endpoints this (re-)subscribe actually OPENED — accepted by a
        // relay, not merely requested. A background burst waits on exactly this
        // set, so a relay that refused the REQ can never make a burst spend its
        // whole backlog budget, and a burst that issued no inbox REQ expects no
        // inbox endpoint.
        let mut opened: Vec<RepairKey> = Vec::new();
        for g in group_subs {
            opened.extend(
                ctx.issue_group(&g.relays, &g.sub_id, &g.group_ids_hex, phase, now)
                    .await?,
            );
        }

        // What the health probe may expect on the wire: an inbox REQ this open
        // did not issue is not a REQ a relay deleted.
        self.inbox_req_open
            .store(!inbox_sub.relays.is_empty(), Ordering::Release);
        if inbox_sub.relays.is_empty() {
            return Ok(opened);
        }
        opened.extend(
            ctx.issue_inbox(&inbox_sub.relays, &inbox_sub.sub_id, inbox_phase, now)
                .await?,
        );
        Ok(opened)
    }

    /// See [`SubscribeCtx::subscribe_bucket`].
    async fn subscribe_bucket(
        &self,
        relays: Vec<String>,
        sub_id: SubscriptionId,
        filter: Filter,
    ) -> LiveSyncResult<Vec<RelayUrl>> {
        self.ctx().subscribe_bucket(relays, sub_id, filter).await
    }

    /// Stops the session: signals shutdown, CLOSEs every REQ, shuts down the
    /// `Client`, and clears the router. Terminal for this `Client` — a fresh
    /// [`Self::new_local`] is required to restart (the salt is zeroized on drop).
    ///
    /// Serialized against [`Self::start`] / [`Self::resume_after_background`] via
    /// the lifecycle lock: a stop requested while a start is in flight waits for
    /// that start to finish (pool intact) before tearing the `Client` down, so
    /// the start's subscribe never observes an emptied pool ("no relays").
    ///
    /// The `shutdown` flag is raised BEFORE contending for the lifecycle lock so a
    /// holder mid-flight in its (network-touching) connect + subscribe sequence
    /// observes it at its interruption points ([`Self::subscribe_bucket`] and the
    /// post-`wait_for_connection` checks in start/resume/`subscribe_circle`) and
    /// bails, releasing the lock promptly instead of making this stop wait out the
    /// holder's full relay round-trip — the previously "un-bounded subscribe" the
    /// lifecycle doc flags as the sole thing that could delay logout.
    ///
    /// This does NOT regress the no-relays invariant (commit 734a88a): the engine
    /// pool is emptied ONLY by [`Self::stop_inner`]'s `client.shutdown()`, which
    /// still runs strictly UNDER the lifecycle lock below — i.e. only after any
    /// in-flight start/subscribe has released it. So a concurrent start either
    /// finishes (or bails) with the pool still intact before this stop can clear
    /// it, or — if it has not yet taken the lock — observes `shutdown` on entry and
    /// fails closed ([`LiveSyncError::NoSession`]), never subscribing onto an
    /// emptied pool. Raising the flag early only lets a holder fail closed SOONER;
    /// it never lets the pool clear while a subscribe is in flight.
    pub async fn stop(&self) -> StopOutcome {
        self.shutdown.store(true, Ordering::Release);
        // Raise cancel with the flag, not later: the receiver may be parked in
        // `recv().await` where it can never observe `shutdown`, and the pool's
        // `Shutdown` notification is not a guaranteed wake (see `run_receiver`).
        //
        // `send_replace`, NOT `send`. `watch::Sender::send` returns `Err` and
        // DISCARDS THE VALUE when no receiver exists — and no receiver exists
        // for exactly the window this cancel is designed to cover: the channel
        // is built in `new_local` with its initial receiver dropped, so the
        // count is zero until `start` calls `subscribe`. A `stop` racing an
        // in-flight `start` would therefore have its cancel silently thrown
        // away, the receiver would subscribe to a `false`, and the whole
        // mechanism would fall back to the pool notification it exists to stop
        // trusting. `send_replace` always stores and cannot fail.
        self.cancel_tx.send_replace(true);
        // Diagnostic (teardown-hang triage): these bracket the two awaits `stop`
        // can park on — the lifecycle-lock acquire and `stop_inner` — so a drive
        // log pinpoints WHERE a teardown stalls (or, if none of these appear at
        // all, that `stop` was never entered → the hang is upstream at the FFI /
        // Dart stream-cancel boundary, not here). Pseudonymous, no key material.
        log::debug!("[live_sync] stop: shutdown flagged; awaiting lifecycle lock");
        let _lifecycle = self.lifecycle.lock().await;
        log::debug!("[live_sync] stop: lifecycle lock acquired");
        self.stop_inner().await;
        self.join_tasks(Self::STOP_JOIN_BUDGET).await
    }

    /// Awaits the supervisor tasks spawned by [`Self::start`], bounded.
    ///
    /// This is what turns `stop` into a happens-before edge for the `Arc`
    /// drops. Without it `stop` returns while `run_worker` may still hold
    /// `Arc<EngineProcessor>` → `Arc<CircleManager>` → the Rule-14
    /// `LiveSessionGuard`, so a caller reclaiming an orphaned session could not
    /// tell a released guard from one about to be released.
    ///
    /// On timeout the tasks are deliberately NOT aborted. Aborting
    /// `run_worker` only stops it awaiting its inner panic-isolation spawn;
    /// that inner task holds its own `Arc<EngineProcessor>` and runs to
    /// completion regardless, so an abort buys no earlier drop and loses the
    /// task's own signalling. Reporting [`StopOutcome::TimedOut`] and letting
    /// the caller's `acquire` remain the authority is both simpler and honest.
    async fn join_tasks(&self, budget: Duration) -> StopOutcome {
        // Take the handles OUT under the lock, then drop the guard before the
        // first await — a `std::sync::MutexGuard` held across `.await` would
        // make this future non-`Send`.
        let handles: Vec<JoinHandle<()>> = {
            let mut tasks = self.tasks.lock().unwrap_or_else(PoisonError::into_inner);
            std::mem::take(&mut *tasks)
        };
        if handles.is_empty() {
            return StopOutcome::NotStarted;
        }

        // Join under one shared deadline, keeping every handle we did NOT get
        // to. `timeout` takes `&mut handle` (a `JoinHandle` is `Unpin`) so a
        // handle SURVIVES its own elapsed timeout instead of being consumed.
        //
        // Restoring the survivors is load-bearing, not tidiness. An earlier
        // version moved every handle into one timed future, so a timeout
        // dropped them all — detaching the tasks, since tokio never aborts on
        // drop — and left `self.tasks` empty forever. The next `stop` then took
        // an empty vec and answered `NotStarted`, which the FFI maps to
        // "drained": a fail-OPEN on the one invariant this type exists to
        // report, hit precisely by the caller the docs tell to re-check after a
        // `TimedOut`.
        let deadline = Instant::now() + budget;
        let mut pending: Vec<JoinHandle<()>> = Vec::new();
        for mut handle in handles {
            let remaining = deadline.saturating_duration_since(Instant::now());
            // Once the budget is gone, keep the rest without awaiting them.
            if pending.is_empty() && !remaining.is_zero() {
                // A panicked task is still a DROPPED task, which is all this
                // join asserts; `JoinError` is therefore not a failure here.
                if bounded(remaining, &mut handle).await.is_ok() {
                    continue;
                }
            }
            pending.push(handle);
        }

        if pending.is_empty() {
            return StopOutcome::Drained;
        }
        let outstanding = pending.len();
        {
            let mut tasks = self.tasks.lock().unwrap_or_else(PoisonError::into_inner);
            // A concurrent `start` may have spawned fresh tasks while we were
            // joining; append rather than overwrite so neither set is lost.
            tasks.extend(pending);
        }
        // Bucketed: an exact task count is one per subscribed plane/relay, so it
        // sizes this account's relay set (Security Rule 15).
        log::warn!(
            "[live_sync] stop: supervisor join timed out with {} task(s) \
             outstanding; the manager Arc may still be held",
            crate::log_alias::bucket(outstanding)
        );
        StopOutcome::TimedOut
    }

    /// Bound on the post-teardown supervisor join.
    ///
    /// Sized to let a healthy task that has already been signalled finish its
    /// current event, without waiting on one that is wedged.
    ///
    /// Note this is the SMALLEST term in `stop`, so shortening it is not what
    /// bounds a caller. `stop` first awaits the lifecycle lock (unbounded), then
    /// `stop_inner` spends up to four `RELAY_LIFECYCLE_OP_TIMEOUT`s. A caller
    /// that needs a hard bound must impose it at its own call site.
    const STOP_JOIN_BUDGET: Duration = Duration::from_secs(5);

    /// The teardown body of [`Self::stop`], WITHOUT acquiring the lifecycle lock.
    ///
    /// Callers MUST already hold the lifecycle lock (via [`Self::stop`] or from
    /// within [`Self::start`]'s error path). Setting the `shutdown` flag here —
    /// under the lifecycle lock — is what makes [`Self::start`]'s shutdown check
    /// authoritative (a stop can flip `shutdown` only while holding the lock, so
    /// a concurrent start either finishes first or observes the flag and fails
    /// closed).
    async fn stop_inner(&self) {
        // Signal shutdown FIRST so the supervisor/receiver tasks die, then tear
        // down. The engine owns convergence internally now, so there is no
        // detached converge task to drain (the old cross-core race close).
        // (`stop` already raised the flag before taking the lifecycle lock; this
        // re-raise covers `start`'s error path, which calls `stop_inner` directly.)
        log::debug!("[live_sync] stop_inner: entered");
        self.shutdown.store(true, Ordering::Release);

        // Drop the pause marker's `Sender` clone. `run_worker` exits when its
        // channel closes, which happens only once EVERY sender is gone; holding
        // this one would park the worker in `rx.recv()` forever, `join_tasks`
        // would report `TimedOut`, and the Rule-14 `LiveSessionGuard` would read
        // as still held by a session that has stopped.
        drop(
            self.intake
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .take(),
        );

        // Best-effort, bounded teardown: the shutdown flag is already set, so the
        // supervisor/receiver tasks die regardless; a wedged pool op must not
        // block logout/teardown. `stop` returns (), so a timeout cannot propagate.
        if bounded(RELAY_LIFECYCLE_OP_TIMEOUT, self.client.unsubscribe_all())
            .await
            .is_err()
        {
            log::warn!("[live_sync] stop: unsubscribe_all timed out; proceeding");
        }
        log::debug!("[live_sync] stop_inner: unsubscribe_all returned");
        // Terminate BEFORE `shutdown`, and prove it. `shutdown` clears the pool
        // map, but a connection task holds its own full clone of the relay: one
        // stranded here (see [`Self::terminate_all_relays`]) re-connects to a
        // relay the pool no longer holds, keeps that socket until the process
        // exits, and is invisible to `relay_health` — which can only report
        // relays the pool still has. Proving every relay terminated while they
        // are all still IN the pool is the only place that leak can be closed.
        if bounded(RELAY_LIFECYCLE_OP_TIMEOUT, self.terminate_all_relays())
            .await
            .is_err()
        {
            log::warn!("[live_sync] stop: relay termination timed out; proceeding");
        }
        if bounded(RELAY_LIFECYCLE_OP_TIMEOUT, self.client.shutdown())
            .await
            .is_err()
        {
            log::warn!("[live_sync] stop: client shutdown timed out; proceeding");
        }
        log::debug!("[live_sync] stop_inner: client shutdown returned");
        // Bound the router clear too. `router.write()` is an in-memory `RwLock`
        // whose readers (the worker's per-event `lookup`) never hold the guard
        // across an await, so in steady state it acquires in << 1 ms — but this was
        // the ONE teardown step with neither a timeout nor a log, so a hypothetical
        // stuck reader could wedge logout INVISIBLY. Bounding + logging it means
        // teardown can never silently hang here; on timeout we warn and skip — a
        // stale router only drops events (which the cursor + catch-up re-fetch), it
        // never forks MLS state.
        if bounded(RELAY_LIFECYCLE_OP_TIMEOUT, async {
            self.router.write().await.clear();
        })
        .await
        .is_err()
        {
            log::warn!("[live_sync] stop: router clear timed out; proceeding");
        }
        // Every REQ is closed: drop the inbox anchor so a stray EOSE arriving
        // after teardown cannot redeem a generation for a subscription this
        // session no longer owns. (The per-circle group anchors are dropped by
        // `unsubscribe_circle`; a stopped session's router is cleared above, so
        // this is belt-and-braces on the one anchor that outlives no REQ.)
        self.processor.forget_inbox_subscription();
        log::debug!("[live_sync] stop_inner: router cleared; emitting SessionStopped");
        self.bus.send(LiveSyncEvent::Status {
            reason: SyncStatusReason::SessionStopped,
        });
    }

    /// Re-anchors the session after a background period / reconnect — and, in
    /// the burst model, OPENS one background burst.
    ///
    /// Reconnects any dropped relays, then re-issues every subscription with the
    /// **wider** `Resubscribe` clock-skew buffer anchored at each circle's
    /// persisted cursor, so events that arrived while the socket was down are
    /// re-fetched losslessly (the cursor advances only on applied events). The
    /// long-lived supervisor tasks and the notifications receiver are untouched,
    /// so there is no miss window. A no-op (other than a `BackgroundResumed`
    /// status) if the session was never started.
    ///
    /// This is the FOREGROUND re-anchor — the app-resume re-anchor and the
    /// health tick's whole-session repair — so it ALWAYS carries the inbox REQ,
    /// at any [`INBOX_BURSTS_PER_REQ`]. The fold is a background-burst
    /// behaviour and belongs to [`Self::open_background_burst`]; taking it here
    /// would let a foreground re-anchor CLOSE the standing inbox REQ (the
    /// `unsubscribe_all` above is unconditional) and then not re-issue it,
    /// leaving the device unable to receive an invitation for as long as the app
    /// is open.
    ///
    /// See [`Self::resume_burst`] for the rest of what an open does.
    ///
    /// # Errors
    ///
    /// Returns [`LiveSyncError`] if a re-subscription fails.
    pub async fn resume_after_background(&self) -> LiveSyncResult<()> {
        let lifecycle = self.lifecycle.lock().await;
        self.resume_burst(&lifecycle, BurstKind::Foreground, INBOX_BURSTS_PER_REQ)
            .await
    }

    /// Opens ONE background burst: the same re-anchor, plus the two things that
    /// are true only between publish ticks — the inbox REQ is folded onto every
    /// [`INBOX_BURSTS_PER_REQ`]-th burst, and the burst counter that decides it
    /// advances.
    ///
    /// Separate from [`Self::resume_after_background`] because that function is
    /// ALSO the foreground's re-anchor, on two paths that must never consume a
    /// fold position: the app-resume re-anchor and the 15-minute health tick.
    ///
    /// # Errors
    ///
    /// Returns [`LiveSyncError`] if a re-subscription fails.
    pub async fn open_background_burst(&self) -> LiveSyncResult<()> {
        let lifecycle = self.lifecycle.lock().await;
        self.resume_burst(&lifecycle, BurstKind::Background, INBOX_BURSTS_PER_REQ)
            .await
    }

    /// [`Self::resume_after_background`] / [`Self::open_background_burst`] with
    /// the caller's kind and the inbox fold period injected, so the "one inbox
    /// REQ per `k` bursts" behaviour is testable at a `k` the shipped constant
    /// does not currently take.
    ///
    /// # What a burst open does beyond a plain re-anchor
    ///
    /// * **clears `paused` (and the radio-off flag) under the lock, before
    ///   `connect()`, and RESTORES both on every failure exit** — the gates
    ///   (`run_repair`, the health tick, the delta ops) must see a live session
    ///   for the whole open, and the lock serialises this open behind a pause
    ///   that is still draining. There is no `finally` here and no caller that
    ///   supplies one, so an open that cleared the flags and then failed would
    ///   leave the session gate-open with sockets up and REQs missing; each exit
    ///   below puts them back itself. The lock alone does NOT protect the router
    ///   entries this open registers: a pause whose marker ack timed out has
    ///   released the lock with that marker still queued, so what stops it
    ///   wiping this burst is the registration count the marker carries
    ///   ([`super::router::Router::clear_if_unchanged`]). The exit that already
    ///   opened sockets also emits [`SyncStatusReason::Paused`], because
    ///   lowering the radio-off flag let the monitor report this open's
    ///   `Connecting`/`Connected` and a consumer left on those would call a
    ///   session subscribed to nothing healthy;
    /// * **`add_relay`s the relay UNION of the active set** — a circle
    ///   subscribed while paused registered no relay in the pool (the pause has
    ///   no socket to add one to), so without this its REQ would be issued to a
    ///   relay the pool does not hold, `retry_until_accepted` would exhaust, and
    ///   the `?` below would fail the WHOLE open. The circle would then never
    ///   receive in the background, silently;
    /// * **re-sweeps `unsubscribe_all` when the pool view is non-empty** — a
    ///   partial pause sweep leaves ids REGISTERED, and nostr-relay-pool's own
    ///   `resubscribe()` re-sends those OLD REQs on connect, AHEAD of the ones
    ///   this burst is about to issue. A stale REQ's `EOSE` would then consume
    ///   the new generation's advance for a window it never asked for. Sweeping
    ///   BEFORE `connect()` means the CLOSEs are flushed first.
    ///
    /// # Lifecycle lock
    ///
    /// **The caller holds it**, and the guard is taken by reference rather than
    /// merely documented (the contract [`RepairPlane::reissue`] states in prose)
    /// because one caller needs the acquisition to cover more than the open:
    /// [`Self::maintain_subscription_health`] reads `paused` under it, and
    /// re-taking the lock here would let a pause slip between that read and this
    /// open — which is the entire point of the read. Serializing against `stop`
    /// (and `start`, and a draining `pause`) is what the lock buys everyone
    /// else: an open re-issues subscriptions, so it must not race a `stop`'s
    /// pool-clearing shutdown, which would make the re-subscribe fail with the
    /// opaque "no relays". Under the lock, the shutdown check below is
    /// authoritative.
    ///
    /// # Errors
    ///
    /// Returns [`LiveSyncError`] if a re-subscription fails.
    async fn resume_burst(
        &self,
        _lifecycle: &TokioMutexGuard<'_, ()>,
        kind: BurstKind,
        inbox_every: u32,
    ) -> LiveSyncResult<()> {
        // Close the window BEFORE anything that can fail. Everything below —
        // the shutdown checks, and `register_and_subscribe`'s short-circuit on
        // the first bucket no relay accepted — returns `Err` with REQs of the
        // PREVIOUS burst never re-issued, and each of those is still marked
        // settled by the burst that did open it. Leaving them standing would let
        // `wait_backlog_settled` answer `Settled` for an open that issued
        // nothing, and the caller would encrypt believing a peer commit had been
        // applied.
        *self.burst_window.write().await = BurstWindow::Closed;
        if self.shutdown.load(Ordering::Acquire) {
            return Err(LiveSyncError::NoSession);
        }
        // Leave the paused state BEFORE anything touches a socket: every gate
        // reads this flag, and a burst that connected while still flagged paused
        // would have its own repairs and health tick refuse to act. Whether it
        // WAS paused is what decides the relay rebuild below.
        //
        // Lowering the radio-off flag with it is what LICENSES the sockets this
        // open is about to open: the watch would otherwise cut this burst's own
        // `connect()` as an unrequested one. It goes down first, and it goes
        // back up on every failure exit below — an open that clears these flags
        // and then fails would leave sockets up, zero or partial REQs, and every
        // gate that reads `paused` wide open, with nothing else in the engine to
        // re-raise them.
        let was_paused = self.paused.swap(false, Ordering::AcqRel);
        self.radio_off.store(false, Ordering::Release);
        // The inbox fold, decided ONCE and only for a background burst. The
        // foreground re-anchors share this path and their `unsubscribe_all` is
        // unconditional, so one that folded the inbox away would close the
        // standing `kind:1059` REQ and not re-issue it — no invitation could
        // arrive for as long as the app stayed open. They neither read nor
        // advance the period.
        let issues_inbox = match kind {
            BurstKind::Foreground => true,
            BurstKind::Background => burst_issues_inbox(
                self.background_bursts.fetch_add(1, Ordering::AcqRel),
                inbox_every,
            ),
        };
        // This burst's settle window is measured from THIS burst's commit
        // traffic; a commit the previous burst already settled must not hold the
        // radio open again.
        self.processor.reset_commit_activity();
        // The receive-side auto-commit policy, from the SAME typed kind the inbox
        // fold reads. A background open must not publish a removal-bearing
        // auto-commit (OD4-c option (iv)); a foreground open must, exactly as
        // before. Set before any REQ is issued, so no event this open delivers
        // can be resolved under the previous open's lifecycle.
        self.processor
            .set_background_burst(matches!(kind, BurstKind::Background));

        let active = self.active.read().await.clone();
        if let Some(active) = &active {
            for relay in relay_union(active) {
                let _ = self.client.add_relay(relay.as_str()).await;
            }
        }

        // A leftover registration on a `Terminated` relay is re-sent by the
        // pool's own `resubscribe()` the moment `connect()` re-opens the socket
        // — ahead of this burst's REQs. Flush the CLOSEs first.
        if !self.client.subscriptions().await.is_empty()
            && bounded(RELAY_LIFECYCLE_OP_TIMEOUT, self.client.unsubscribe_all())
                .await
                .is_err()
        {
            log::warn!("[live_sync] burst open: pre-connect unsubscribe_all timed out");
        }

        // ONLY after a pause. `disconnect()` is what strands a relay's
        // connection task, and only the pause calls it; in the foreground this
        // would be a pool mutation racing the worker's own `send_event_to`,
        // whose `RelayNotFound` fails the WHOLE publish and rolls a staged
        // commit back (see [`Self::rebuild_stalled_relays`]).
        if was_paused {
            self.rebuild_stalled_relays().await;
        }

        self.client.connect().await;
        // Same fresh-reconnect race as `start`: let the re-opened sockets finish
        // their handshake (early-returning wait) before re-issuing the REQs, so a
        // re-subscribe does not drop into `Output.failed` and orphan the circle.
        self.client
            .wait_for_connection(SUBSCRIBE_CONNECT_WAIT)
            .await;

        // Interruptible: a concurrent `stop` may have raised `shutdown` during the
        // connect wait. Bail (fail closed) before re-issuing any REQ so the
        // lifecycle lock is released promptly; the stop's `stop_inner` tears the
        // client down. Nothing to unwind here — resume re-uses the live supervisor
        // and has registered no new router state yet.
        //
        // The pause flag is restored, the radio is NOT re-cut: `stop_inner` is
        // already terminating every relay and its own drain is bounded, so a
        // second, uncapped Rule-13 wait on this exit could only wedge teardown.
        if self.shutdown.load(Ordering::Acquire) {
            self.paused.store(true, Ordering::Release);
            return Err(LiveSyncError::NoSession);
        }

        if let Some(active) = active {
            let now = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap_or(i64::MAX);
            // Re-anchor the STORED live set (base buckets + any dynamic singletons)
            // under their frozen sub-ids — NO re-bucketing, so nothing is orphaned
            // and a dynamically-added circle is re-anchored too. `Resubscribe`
            // phase widens the group buffer for a lossless offline-gap backfill.
            let group_subs: Vec<GroupSubscription> = active
                .group_subs
                .iter()
                .map(to_group_subscription)
                .collect();
            // An inbox-only relay sees a `#p` REQ only on a fold burst; on every
            // other one this burst opens no inbox endpoint at all, and therefore
            // expects none.
            let inbox_sub = InboxSubscription {
                relays: if issues_inbox {
                    active.inbox_relays.clone()
                } else {
                    Vec::new()
                },
                sub_id: active.inbox_sub_id.clone(),
            };
            match self
                .register_and_subscribe(
                    &group_subs,
                    &inbox_sub,
                    now,
                    SubscribePhase::Resubscribe,
                    SubscribePhase::Resubscribe,
                )
                .await
            {
                Ok(opened) => *self.burst_window.write().await = BurstWindow::Open(opened),
                // The burst is dead but the SESSION is not, and `connect()` has
                // already run: without this the engine sits with live sockets,
                // zero or partial REQs and open gates until the next tick — the
                // exact between-tick presence P4 promises does not happen. Put
                // it back where the pause left it, Rule 13 first (a bucket that
                // did subscribe may have started an auto-commit publish before
                // a later one failed).
                Err(err) => {
                    self.paused.store(true, Ordering::Release);
                    // Sweep the registrations the buckets that DID subscribe
                    // left behind, in the pause's own order. A registration
                    // outliving the radio is not inert: the pool's `resubscribe`
                    // re-sends it the instant any relay reconnects, so a leftover
                    // one turns a stranded connection task from a bare socket
                    // into a standing REQ mid-gap.
                    if bounded(RELAY_LIFECYCLE_OP_TIMEOUT, self.client.unsubscribe_all())
                        .await
                        .is_err()
                    {
                        log::warn!(
                            "[live_sync] failed burst open: unsubscribe_all timed out; \
                             proceeding to cut the radio"
                        );
                    }
                    self.processor.wait_publishes_drained().await;
                    self.terminate_all_relays().await;
                    self.radio_off.store(true, Ordering::Release);
                    // And SAY so, in the same place a deliberate pause does.
                    // This open lowered `radio_off` before `connect()`, so the
                    // monitor has already reported `Connecting`/`Connected` for
                    // the sockets just cut; leaving that as the last status
                    // would have a consumer judge a session subscribed to
                    // nothing by its publish acks, which succeed on a separate
                    // pool. One `Paused`, exactly as `pause_subscriptions`
                    // emits it — the state this arm leaves is the state it
                    // reports.
                    self.bus.send(LiveSyncEvent::Status {
                        reason: SyncStatusReason::Paused,
                    });
                    return Err(err);
                }
            }
        }

        self.bus.send(LiveSyncEvent::Status {
            reason: SyncStatusReason::BackgroundResumed,
        });
        // A FOREGROUND open is where a parked eviction commit is finally
        // published — this is the whole redemption path OD4-c option (iv) defers
        // to — and where a parked commit that outlived its session is reported.
        // AFTER the REQs, so the sockets it publishes over are the ones this open
        // just brought up; and only for a foreground open, because doing it in a
        // burst is the publish-before-apply window the deferral exists to avoid.
        if matches!(kind, BurstKind::Foreground) {
            self.processor.redeem_removal_deferrals().await;
            self.processor.report_unrecoverable_circles();
        }
        Ok(())
    }

    /// Replaces every relay that is not currently connected with a FRESH relay
    /// object, so this burst's `connect()` spawns a task and attempts
    /// immediately instead of inheriting the crate's 10-60 s retry schedule.
    ///
    /// # The race this exists for (measured, not theoretical)
    ///
    /// `Client::disconnect` sets `Terminated` SYNCHRONOUSLY, but the per-relay
    /// connection task exits asynchronously — and `spawn_connection_task`
    /// returns WITHOUT spawning while the previous task is still marked running.
    /// `Relay::connect` has already overwritten the status with `Pending` by
    /// then, and `Pending` is not in `can_connect()`, so no later `connect()` can
    /// rescue it. The stranded relay is picked up only by the OLD task, which
    /// sees a non-terminated status, marks it `Disconnected` and sleeps
    /// `calculate_retry_interval()` (~10 s) before trying again.
    ///
    /// A burst that waited that out would report `TimedOut`, publish at a
    /// possibly stale epoch, and hand its whole backlog to the NEXT burst — on
    /// every burst opened soon after a pause. Not hypothetical: it is
    /// reproducible in
    /// `a_burst_opened_immediately_after_a_pause_does_not_wait_out_the_crates_retry`.
    ///
    /// # Why the relay is REPLACED, and never `disconnect`ed-then-`connect`ed
    ///
    /// `disconnect()` latches a termination request on the relay's own channels,
    /// and the task a following `connect()` spawns observes that latch and
    /// aborts. That counts as a FAILED attempt, which drags the relay's success
    /// rate down until `ensure_operational` starts refusing REQs outright
    /// (`Error::NotConnected`) — i.e. the burst stops being able to subscribe at
    /// all. Measured on both `MockRelay` and `LocalRelay`; it is a trap, not an
    /// alternative.
    ///
    /// A relay rebuilt by `force_remove_relay` + `add_relay` carries no running
    /// task, no latched termination and no stale stats, so its `connect()` always
    /// spawns and always attempts at once. Nothing is lost: the registrations
    /// that go with the object were already swept by the pause, and this burst
    /// re-issues every REQ under a fresh generation regardless.
    ///
    /// A `Banned` relay is left alone: banning is a sticky decision the crate
    /// documents as permanent, and a rebuild would silently undo it.
    ///
    /// # Why only the relays that are NOT connected, and only after a PAUSE
    ///
    /// Rebuilding a live socket would drop and re-establish a connection that was
    /// working — a regression, not a repair — so a `Connected` relay is left
    /// alone.
    ///
    /// The whole rebuild runs only when the open is leaving a PAUSE, because
    /// `force_remove_relay` + `add_relay` is two statements with the relay ABSENT
    /// from the pool in between, and `RelayPool::send_event_to` answers
    /// `Err(RelayNotFound)` if any named url is missing: a receive-side
    /// auto-commit the worker sends in that window fails outright,
    /// `publish_auto_commit` reports false, and `publish_failed` rolls the
    /// eviction back with the group left un-converged. The pause holds a gauge
    /// against exactly that hazard (Rule 13); an open holds none, and the
    /// lifecycle lock does not serialise the WORKER.
    ///
    /// After a pause it is unreachable: the pause drained the publish gauge, the
    /// router is clear and the sockets are down, so no ingest can start a
    /// publish. And the stranded connection task this repairs comes from
    /// `client.disconnect()`, which only the pause calls. So the FOREGROUND
    /// callers — the health tick's whole-session re-anchor and the app-resume —
    /// both risk something real and gain nothing: a relay the NETWORK dropped is
    /// on the crate's own retry schedule, which `connect()` joins.
    ///
    /// Holds no lock of its own: every caller is already inside the lifecycle
    /// lock, which is the invariant that lets anything touch the pool's relay set
    /// (see [`Self::lifecycle`]).
    async fn rebuild_stalled_relays(&self) {
        let stalled: Vec<String> = self
            .client
            .relays()
            .await
            .iter()
            .filter(|(_, relay)| {
                !matches!(
                    relay.status(),
                    // Connected: nothing to repair, and rebuilding a live socket
                    // would be a regression rather than a repair.
                    RelayStatus::Connected
                        // Banned is a deliberate, sticky decision the crate
                        // documents as "can't reconnect again". Rebuilding would
                        // silently resurrect it.
                        | RelayStatus::Banned
                )
            })
            .map(|(url, _)| url.to_string())
            .collect();
        for url in &stalled {
            let _ = self.client.force_remove_relay(url.as_str()).await;
            let _ = self.client.add_relay(url.as_str()).await;
        }
    }

    /// How many pool relays are NOT in a terminal state right now.
    ///
    /// Presence-only (a count, never a url). `Banned` counts as terminal: the
    /// crate documents it as a sticky, permanent refusal, and its connection
    /// task has exited exactly as a `Terminated` one has.
    async fn unterminated_relay_count(&self) -> usize {
        self.client
            .relays()
            .await
            .values()
            .filter(|relay| {
                !matches!(
                    relay.status(),
                    RelayStatus::Terminated | RelayStatus::Banned
                )
            })
            .count()
    }

    /// Terminates every pool relay and PROVES it, re-asserting up to
    /// [`RELAY_TERMINATE_ROUNDS`] times.
    ///
    /// # Why one `disconnect()` is not enough (measured, not theoretical)
    ///
    /// `nostr-relay-pool`'s `InnerRelay::disconnect` fires the termination
    /// notification and only THEN stores `Terminated`, and that notification is
    /// a `Notify::notify_one` — a single permit, not a latch. If the connection
    /// task it wakes gets through its close and re-reads the relay's status
    /// before that store lands, it sees a live status, marks the relay
    /// `Disconnected`, and sleeps its retry interval — with the one permit that
    /// could have broken that sleep already spent. It then re-opens a REAL
    /// socket, over the pause's `Terminated`, and holds it (55 s pings,
    /// indefinitely) with no REQ on it, because the pause already swept every
    /// registration. The next burst silently ADOPTS that socket:
    /// [`Self::rebuild_stalled_relays`] skips `Connected` by design and
    /// `connect()` is a no-op on it. So the leak is invisible, and P4's promise
    /// — no socket between publish ticks — is false for the whole gap.
    ///
    /// The window is the gap between two adjacent statements, so it opens only
    /// when the notifying thread is preempted INSIDE it — which is a property of
    /// the machine, not of the code. Measured at 48/150 disconnects on a
    /// multi-threaded runtime while the host was oversubscribed 2x, and at 0/150
    /// on `current_thread` (which cannot interleave the woken task there at
    /// all). On an idle host it does not reproduce: 0/300 pauses, and 0/200 even
    /// on a 64-worker runtime over 8 relays, because a woken task lands on an
    /// idle core instead of displacing the notifier. That is why no test here
    /// waits for it to fire — one that did would assert nothing on an idle
    /// runner — and why the fix is a repair plus a watch rather than a
    /// prevention: a background phone is the loaded case, permanently.
    ///
    /// # Why re-asserting works
    ///
    /// `disconnect` early-returns ONLY on a status that is already `Terminated`
    /// or `Banned`. A relay stranded at `Disconnected` therefore does not
    /// early-return: the second call fires a FRESH permit, which the retry
    /// sleep's own `select!` consumes and breaks on. And a task woken out of
    /// that sleep re-reads nothing, so the round cannot re-strand the way the
    /// first one did.
    ///
    /// # The bound, and what happens when it is not enough
    ///
    /// BOUNDED, and it holds no timer: the Rule-13 publish-gauge wait that
    /// precedes the pause's call is already uncapped, so nothing after it may
    /// wait on the clock. Each round yields once — enough for a woken task to
    /// write the status that identifies it, and never a stand-in for a
    /// duration. Non-convergence does not fail the caller (a pause that
    /// refused to finish would wedge the background tick over a condition it
    /// cannot fix): it warns with a COUNT only, and [`run_monitor`]'s radio-off
    /// watch is the backstop that cuts the socket if one does open. That
    /// backstop is also what covers the residual this loop cannot see at all —
    /// a strand whose `Disconnected` write landed BEFORE the pool's
    /// `Terminated` store, which reads as correctly terminated here and still
    /// re-connects a retry interval later.
    async fn terminate_all_relays(&self) {
        for _ in 0..RELAY_TERMINATE_ROUNDS {
            self.client.disconnect().await;
            // Let a woken connection task write whatever status it is going to
            // write before this round judges convergence. A yield, never a
            // sleep: convergence is decided by the status read, not by time.
            tokio::task::yield_now().await;
            if self.unterminated_relay_count().await == 0 {
                return;
            }
        }
        log::warn!(
            "[live_sync] radio off: some relay(s) still hold a connection task after \
             every termination round; the radio-off watch will cut any socket they \
             re-open"
        );
    }

    /// Whether the session is PAUSED between background bursts.
    #[must_use]
    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::Acquire)
    }

    /// How many relay connect transitions this session has had to cut because
    /// they happened while the radio was off — i.e. sockets it never asked for.
    ///
    /// Presence-only (a count, never a url — Rules 4/6), and cumulative for the
    /// life of the session. Non-zero means the crate's own retry loop survived a
    /// pause and got a socket up that this session never asked for — the thing
    /// P4 is about. The engine cannot make that impossible (the race is inside
    /// the pinned crate, in the gap between two of its adjacent statements), so
    /// what it promises instead is that no such socket SURVIVES: the radio-off
    /// watch cuts every one, and this is how many there were.
    ///
    /// Counts only transitions the pool still held up when they were HANDLED, so
    /// a burst's own `Connected` arriving behind the failure that cut the radio
    /// does not inflate it (see [`RadioOffWatch::is_up`]).
    #[must_use]
    pub fn unrequested_connections(&self) -> usize {
        self.unrequested_connections.load(Ordering::Acquire)
    }

    /// How many publishes this session has between SEND and OK right now.
    ///
    /// Presence-only (a count). The Rule-13 gauge the pause blocks on before
    /// `client.disconnect()`, exposed so a test can observe the state the rule
    /// forbids cutting — "a commit is on the wire" — rather than infer it from a
    /// duration.
    #[must_use]
    pub fn in_flight_publishes(&self) -> usize {
        self.processor.in_flight_publishes()
    }

    /// How many long-lived subscriptions the engine pool still holds, across
    /// every relay.
    ///
    /// The direct read of the burst promise "no standing REQ between publish
    /// ticks" — and the one `relay_health` cannot give, because that counts only
    /// the pairs the ACTIVE SESSION expects and would therefore miss a
    /// registration a partial `unsubscribe_all` left behind under an id the
    /// session no longer models. Presence-only: a count, never a sub-id or relay.
    pub async fn pool_subscription_count(&self) -> usize {
        self.client
            .subscriptions()
            .await
            .values()
            .map(HashMap::len)
            .sum()
    }

    /// Waits for every endpoint THIS burst opened to finish its stored replay,
    /// bounded by [`BURST_BACKLOG_WAIT`].
    ///
    /// Called between a burst open and the location encrypt, so a peer commit
    /// that landed while the engine was paused is APPLIED first and the location
    /// goes out at the current epoch. A [`BacklogOutcome::TimedOut`] does not
    /// stop the burst — the caller publishes anyway, exactly as the foreground
    /// does with a slow REQ — it is reported.
    ///
    /// With NO open window — no burst has opened yet, the last open failed
    /// part-way, it was the no-op resume of a session that was never started, or
    /// a pause has since closed every REQ — the answer is
    /// [`BacklogOutcome::TimedOut`] at once. That is the only honest one
    /// available: no REQ this session owns is one a burst is waiting on, and
    /// `Settled` would tell a caller that ignored the open's `Err` (or never
    /// opened at all) that a peer commit had been applied.
    pub async fn wait_backlog_settled(&self) -> BacklogOutcome {
        let expected = {
            let window = self.burst_window.read().await;
            match &*window {
                BurstWindow::Open(endpoints) => endpoints.clone(),
                BurstWindow::Closed => return BacklogOutcome::TimedOut,
            }
        };
        self.processor
            .wait_backlog_settled(&expected, BURST_BACKLOG_WAIT)
            .await
    }

    /// Holds the sockets open until the engine's commit traffic has quiesced, so
    /// the pause that follows cannot cut a commit short.
    ///
    /// Two stages, in this order:
    ///
    /// 1. **the in-flight publish gauge, with NO cap.** A commit between SEND
    ///    and OK may never be disconnected (Security Rule 13): `wait_for_ok`
    ///    would return `Err`, `publish_failed` would roll the group back to the
    ///    prior epoch, and the relay may already have stored and served that
    ///    commit — a roster fork. The wait is bounded in practice by the crate's
    ///    own 10 s per-relay OK wait, never by a clock this method chose.
    /// 2. **[`COMMIT_SETTLE_WINDOW_SECS`] after the LAST commit activity**, so
    ///    the convergence traffic a commit provokes lands on an open socket
    ///    instead of on the next re-anchor.
    ///
    /// # What "the last commit activity" spans
    ///
    /// The stamp is cleared at a BURST open
    /// ([`EngineProcessor::reset_commit_activity`]) and nowhere else, so stage 2
    /// reads everything since the most recent re-anchor: a burst's own traffic
    /// after a burst, and the FOREGROUND session's on a teardown no burst
    /// preceded (the coordinator tears down every background pause, including
    /// the ones that drive nothing). Both are the wanted reading — a commit
    /// whose convergence is still arriving deserves the socket whichever session
    /// sent it — and either way an engine quiet for the window pays ZERO, which
    /// is the common case.
    ///
    /// [`BURST_SETTLE_CAP_SECS`] bounds stage 2 only. It is measured from the
    /// moment the gauge drained, and it is sized so a commit arriving late still
    /// gets its FULL window (`cap >= window + 10`, const-asserted).
    pub async fn settle_before_pause(&self) {
        self.settle_before_pause_with(BURST_SETTLE_WINDOW, BURST_SETTLE_CAP)
            .await;
    }

    /// [`Self::settle_before_pause`] with its two durations injected, so the
    /// window/cap arithmetic is unit-testable on tokio's virtual clock
    /// (`#[tokio::test(start_paused = true)]`) with no socket in sight.
    ///
    /// Uses [`tokio::time::Instant`] and [`tokio::time::sleep`] throughout — the
    /// same clock the paused runtime virtualises and the same one
    /// `EngineProcessor` stamps commit activity on — so the test drives exactly
    /// the production decision, not a copy of it.
    async fn settle_before_pause_with(&self, window: Duration, cap: Duration) {
        // Stage 1: uncapped, by design (Rule 13).
        self.processor.wait_publishes_drained().await;

        // Stage 2: quiesce. `started` is taken AFTER the gauge drained, so the
        // cap bounds follow-on activity only and never the publish it waited on.
        let started = tokio::time::Instant::now();
        loop {
            let Some(last) = self.processor.last_commit_activity_at() else {
                // Nothing has committed since the last re-anchor: pay zero.
                return;
            };
            let now = tokio::time::Instant::now();
            let elapsed = now.saturating_duration_since(started);
            if elapsed >= cap {
                log::debug!("[live_sync] settle: capped at {}s", cap.as_secs());
                return;
            }
            let quiet_for = now.saturating_duration_since(last);
            if quiet_for >= window {
                return;
            }
            // Never past the cap, so a group that keeps committing cannot hold
            // the radio open indefinitely. Both subtractions are guarded by the
            // two `>=` returns above, and `saturating_sub` keeps that true
            // without an `unwrap` that a future edit could make reachable.
            tokio::time::sleep(
                window
                    .saturating_sub(quiet_for)
                    .min(cap.saturating_sub(elapsed)),
            )
            .await;
        }
    }

    /// Pauses the session: CLOSEs every REQ, drains everything already
    /// downloaded, waits out any in-flight publish, and disconnects — leaving NO
    /// standing subscription and NO socket, but a session the next open
    /// re-anchors.
    ///
    /// That next open is a burst when a burst comes; when none does — the
    /// coordinator tears down a background pause it drove nothing from — it is
    /// the foreground re-anchor on the following resume. Nothing below assumes
    /// either, and nothing below assumes a burst PRECEDED this call.
    ///
    /// The lifecycle lock is held for the WHOLE call, which serialises a burst
    /// open behind a pause that is still draining.
    ///
    /// The lock is NOT what protects the next burst's router, and reading it
    /// that way was wrong: it orders the two CALLS, while the drain marker
    /// outlives the call that sent it. The ack wait in (b) is bounded, so a
    /// worker still draining when it expires leaves the marker queued while this
    /// call clears the router itself, returns, and releases the lock — and the
    /// marker then reaches the worker with a LATER burst's REQs registered. The
    /// marker therefore carries the registration count this pause observed, and
    /// clears only that state ([`super::router::Router::clear_if_unchanged`]).
    ///
    /// The order below is the correctness argument, in five steps:
    ///
    /// **(a) `unsubscribe_all`, then a post-condition sweep.**
    /// `InnerRelay::unsubscribe_all` `?`-propagates the FIRST per-relay send
    /// error, so on a relay whose socket is not operational every LATER id stays
    /// REGISTERED — and the pool's own `resubscribe()` re-sends those old REQs on
    /// the next connect, ahead of anything the next burst issues. Sweeping the
    /// leftovers one by one is what stops a stale REQ's `EOSE` consuming a
    /// generation it never covered. The sockets stay OPEN here: nothing new
    /// arrives, but an in-flight OK still can.
    ///
    /// **(b) the [`RawSignal::Pause`] marker — drain, THEN clear.** The router is
    /// resolved at PROCESSING time, so clearing it from here would drop every
    /// stored event still queued ahead of the marker — a burst's replay, or the
    /// FOREGROUND session's when no burst preceded this call: the silent loss of
    /// legitimate offline backlog Security Rule 12 forbids. The marker goes in
    /// BEHIND that backlog, `send().await` (never `try_send` — a full intake
    /// would drop the marker and the router would never clear), and the worker
    /// clears + [`EngineProcessor::note_delivery_gap`]s + acks only once it has
    /// drained everything ahead of it, inline auto-commits and their OK waits
    /// included. Both halves are bounded by [`RELAY_LIFECYCLE_OP_TIMEOUT`] and
    /// short-circuit on `wedged`: a dead worker never acks, and an unbounded wait
    /// here holds the lifecycle lock forever — i.e. hangs logout. On either
    /// fallback the router is cleared directly and the gap noted.
    ///
    /// `note_delivery_gap`, NEVER a `forget_*`: `forget` DROPS an un-applied
    /// hold-back, so a future-epoch event the queue was still carrying would stop
    /// bounding the next generation's advance and the cursor would move over it.
    /// Suppressing burns the advance and keeps the hold-back.
    ///
    /// **(c) the in-flight publish gauge.** The authoritative Rule-13 check, at
    /// the instant of disconnect: `settle_before_pause` is a separate call, and
    /// the window between its return and this point is exactly where a live
    /// `SelfRemove` can be ingested and SENT.
    ///
    /// **(d) `disconnect`, never `shutdown` — and verified.** Terminating leaves
    /// every relay `Terminated` while the pool keeps its registrations, so the
    /// next open's `connect()` re-opens them; `shutdown` would EMPTY the pool
    /// and that subscribe would fail with the opaque `no relays`. But ONE
    /// `disconnect()` does not reliably stop the crate's per-relay connection
    /// task (nor its 55 s pinger): it can strand on the retry schedule and
    /// re-open a real socket the next open then adopts silently.
    /// [`Self::terminate_all_relays`] re-asserts until the pool proves quiet,
    /// and only after it returns does the radio-off watch arm.
    ///
    /// **(e) `repair.clear()`.** Every REQ is re-issued under a fresh generation
    /// by the next open, so a repair firing after it would replace a live REQ
    /// and reset its generation mid-burst.
    ///
    /// # Errors
    ///
    /// Returns [`LiveSyncError::NoSession`] if the session was already stopped.
    pub async fn pause_subscriptions(&self) -> LiveSyncResult<()> {
        let _lifecycle = self.lifecycle.lock().await;
        if self.shutdown.load(Ordering::Acquire) {
            return Err(LiveSyncError::NoSession);
        }
        self.paused.store(true, Ordering::Release);
        // The burst window names the REQs the wait expects an answer from, and
        // (a) below closes every one of them: past this point no endpoint set
        // this session holds is one a burst still owns, so nothing may vouch for
        // a settle until the next open installs its own.
        *self.burst_window.write().await = BurstWindow::Closed;

        // (a) CLOSE every REQ, then prove it.
        if bounded(RELAY_LIFECYCLE_OP_TIMEOUT, self.client.unsubscribe_all())
            .await
            .is_err()
        {
            log::warn!("[live_sync] pause: unsubscribe_all timed out; sweeping leftovers");
        }
        let leftover: Vec<SubscriptionId> =
            bounded(RELAY_LIFECYCLE_OP_TIMEOUT, self.client.subscriptions())
                .await
                .map_or_else(
                    |_| {
                        log::warn!("[live_sync] pause: subscription probe timed out");
                        Vec::new()
                    },
                    |live| live.into_keys().collect(),
                );
        for sub_id in &leftover {
            if bounded(RELAY_LIFECYCLE_OP_TIMEOUT, self.client.unsubscribe(sub_id))
                .await
                .is_err()
            {
                log::warn!("[live_sync] pause: a leftover unsubscribe timed out; proceeding");
            }
        }
        if !leftover.is_empty() {
            log::warn!(
                "[live_sync] pause: swept the subscription(s) a partial unsubscribe_all \
                 left registered"
            );
        }

        // (b) Drain everything already downloaded, THEN clear the router.
        //
        // Inline, not behind a helper: these are the two facts the CI guard pins
        // (`note_delivery_gap`, never a `forget_*`), and a guard that accepted a
        // helper NAME would prove nothing about what the helper does.
        //
        // A worker that has already exited never acks, and an unbounded wait here
        // would hold the lifecycle lock — which `stop` also needs — forever, i.e.
        // hang logout with the Rule-14 guard held. So: short-circuit on `wedged`,
        // bound both halves, and fall back to clearing directly.
        let mut drained = false;
        if !self.wedged.load(Ordering::Acquire) {
            let tx = self
                .intake
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone();
            if let Some(tx) = tx {
                let (ack_tx, ack_rx) = tokio::sync::oneshot::channel();
                // The marker may clear only the router state THIS pause
                // observed. The ack wait below is bounded and the marker is not
                // recallable, so an abandoned marker outlives this call and the
                // lifecycle lock with it — see `Router::clear_if_unchanged`.
                let registrations = self.router.read().await.registrations();
                // `send().await`, NEVER `try_send`: a full intake would drop the
                // marker outright and the router would never clear.
                let queued = bounded(
                    RELAY_LIFECYCLE_OP_TIMEOUT,
                    tx.send(RawSignal::Pause {
                        registrations,
                        ack: ack_tx,
                    }),
                )
                .await
                .is_ok_and(|sent| sent.is_ok());
                drained = queued
                    && bounded(RELAY_LIFECYCLE_OP_TIMEOUT, ack_rx)
                        .await
                        .is_ok_and(|acked| acked.is_ok());
            }
        }
        if !drained {
            log::warn!(
                "[live_sync] pause: the ingest worker did not ack the drain marker; \
                 clearing the router directly — the undrained backlog will be \
                 re-downloaded by the next re-anchor"
            );
            self.router.write().await.clear();
            // `note_delivery_gap`, never a `forget_*`: `forget` DROPS an
            // un-applied hold-back, so the next burst's EOSE would advance the
            // cursor past an event this device could not apply and no plane would
            // ever ask for it again (Security Rule 12).
            self.processor.note_delivery_gap();
        }

        // (c) Rule 13: never disconnect a commit between SEND and OK.
        self.processor.wait_publishes_drained().await;

        // (d) Radio off. `disconnect`, never `shutdown` — the pool keeps its
        //     relays so the next burst's `connect()` has something to re-open.
        //     Verified and re-asserted, never fired once and assumed: a single
        //     `disconnect()` can leave a relay's connection task alive on the
        //     crate's retry schedule, which re-opens a real socket over the
        //     pause's `Terminated` and holds it until the next burst adopts it
        //     (see [`Self::terminate_all_relays`]).
        self.terminate_all_relays().await;
        // Only NOW may the radio-off watch cut a socket: every step above —
        // and the Rule-13 publish drain in particular — needed the sockets it
        // was draining.
        self.radio_off.store(true, Ordering::Release);

        // (e) The next burst re-issues every REQ under a fresh generation.
        self.repair.clear();

        self.bus.send(LiveSyncEvent::Status {
            reason: SyncStatusReason::Paused,
        });
        Ok(())
    }

    /// Subscribes the running session to ONE additional circle (delta only),
    /// leaving every existing circle's subscription — and its advanced `since`
    /// cursor — untouched.
    ///
    /// The circle is issued as its OWN dedicated REQ (a "dynamic singleton") at
    /// its OWN cursor/seed, NOT folded into an existing multiplexed bucket:
    /// folding would force the bucket's single `since` to `MIN(existing, the new
    /// circle's cold seed)` and collapse the whole bucket back to `now −
    /// SEED_LOOKBACK_SECS`, replaying every co-bucketed circle's history into the
    /// serial worker (the bug this fixes). A separate REQ over the already-open
    /// per-relay socket opens no new socket.
    ///
    /// Holds the [`Self::lifecycle`] lock for the whole body — no callee re-takes
    /// it — so a concurrent [`Self::stop`] cannot empty the pool mid-subscribe
    /// (the `NoRelays` race). Idempotent: an already-subscribed circle is `Ok`.
    ///
    /// # Errors
    ///
    /// Returns [`LiveSyncError::NoSession`] if the session was stopped or never
    /// started, or [`LiveSyncError::Relay`] if a relay fails the WSS gate or the
    /// subscription fails (the router registration is rolled back on failure).
    pub async fn subscribe_circle(&self, circle: &CircleSpec) -> LiveSyncResult<()> {
        let _lifecycle = self.lifecycle.lock().await;
        if self.shutdown.load(Ordering::Acquire) {
            return Err(LiveSyncError::NoSession);
        }

        // A circle with no usable relays cannot be subscribed (mirrors
        // `build_relay_set_subscriptions`' skip).
        let relays = canonical_relay_set(&circle.relays);
        if relays.is_empty() {
            return Ok(());
        }
        let hex = circle.group_id_hex.clone();

        // Idempotency + session presence: no active session ⇒ fail closed so the
        // caller falls back to a full start; already subscribed ⇒ Ok no-op. Snapshot
        // the decision into a bool so the read guard drops before the async work.
        let already_present = {
            let guard = self.active.read().await;
            match guard.as_ref() {
                None => return Err(LiveSyncError::NoSession),
                Some(active) => active
                    .group_subs
                    .iter()
                    .any(|s| s.group_ids_hex.contains(&hex)),
            }
        };
        if already_present {
            return Ok(());
        }

        // WSS-only gate: fail the WHOLE op closed BEFORE any `add_relay` (mirrors
        // `start`) — the always-on engine must never open a plaintext `ws://`
        // standing socket.
        for relay in &relays {
            if !engine_relay_allowed(relay) {
                return Err(LiveSyncError::relay(format!(
                    "plaintext ws:// not allowed for the live-sync engine: {relay}"
                )));
            }
        }

        // Cold-start cursor seed (best-effort; touches ONLY this circle's stream).
        //
        // Load-bearing on the PAUSED path below too, and more so: without a
        // seeded cursor the next burst's `bucket_since` reads `unwrap_or(0)` and
        // issues the forbidden `since = 0` REQ — this circle's entire history,
        // on a background wake.
        let now = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap_or(i64::MAX);
        let seed_ms = now
            .saturating_sub(SEED_LOOKBACK_SECS)
            .saturating_mul(1000)
            .max(0);
        let _ = self
            .circle
            .seed_sync_cursor_if_unset(&group_cursor_stream(&hex), seed_ms);

        // Dynamic singleton: its OWN hex-keyed sub-id (never an idx — an idx
        // collision would NIP-01-clobber a live bucket) and its OWN `since`.
        let own_pk_bytes = self.own_pubkey.to_bytes();
        let sub_id = derive_dynamic_group_sub_id(&self.salt, &own_pk_bytes, &hex);
        let group_ids: HashSet<String> = std::iter::once(hex.clone()).collect();

        // PAUSED: update the MODEL and nothing else. There is no socket to add a
        // relay to, no REQ to issue, and no generation to open — the next burst
        // opens all three from `active`, registering this circle's relays through
        // the union it adds before `connect()`. Registering a router entry here
        // would be worse than useless: nothing can deliver to it, and the pause
        // marker already cleared the router.
        if self.paused.load(Ordering::Acquire) {
            if let Some(active) = self.active.write().await.as_mut() {
                active.group_subs.push(LiveGroupSub {
                    sub_id,
                    relays,
                    group_ids_hex: group_ids,
                });
            }
            log::debug!(
                "[live_sync::subscribe] subscribe_circle staged (paused) {}",
                circle_handle(&hex)
            );
            return Ok(());
        }

        // Connect the circle's relays (idempotent for already-pooled ones; a new
        // relay gets its handshake grace, and the subscribe retry covers the cold
        // case). Never disturbs existing sockets.
        for relay in &relays {
            let _ = self.client.add_relay(relay.as_str()).await;
        }
        self.client.connect().await;
        self.client
            .wait_for_connection(SUBSCRIBE_CONNECT_WAIT)
            .await;

        // Interruptible: a concurrent `stop` may have raised `shutdown` during the
        // connect wait. Bail (fail closed) before registering the router / issuing
        // the REQ so the lifecycle lock is released promptly; nothing to unwind yet
        // (no router entry, no `active` mutation before this point).
        if self.shutdown.load(Ordering::Acquire) {
            return Err(LiveSyncError::NoSession);
        }

        // Register the router BEFORE the REQ; roll back on a subscribe failure so
        // no stale context leaks.
        self.router
            .write()
            .await
            .register_group(&relays, &sub_id, &group_ids);

        // Open this circle's cursor-anchor generation at the same local `now`
        // the `since` below is derived from (see `register_and_subscribe`).
        self.processor.note_subscription_opened(&hex, now);

        let since = self.bucket_since(std::slice::from_ref(&hex), SubscribePhase::Initial, now);
        let filter = group_filter(std::slice::from_ref(&hex), since);
        if let Err(e) = self
            .subscribe_bucket(relays.clone(), sub_id.clone(), filter)
            .await
        {
            self.router.write().await.rollback_subscription(&sub_id);
            // No REQ is live for this circle, so nothing can vouch for the
            // generation we just opened; drop it rather than leave an anchor a
            // stray EOSE could redeem.
            self.processor.forget_subscription(&hex);
            return Err(e);
        }

        // Commit the live model (still under the lifecycle lock; `active` is Some).
        if let Some(active) = self.active.write().await.as_mut() {
            active.group_subs.push(LiveGroupSub {
                sub_id,
                relays,
                group_ids_hex: group_ids,
            });
        }

        log::debug!(
            "[live_sync::subscribe] subscribe_circle added {}",
            circle_handle(&hex)
        );
        Ok(())
    }

    /// Unsubscribes the running session from ONE circle (delta only), dropping
    /// only its RECEIVE subscription.
    ///
    /// It never touches the settle window, the write gate, or an in-flight path-B
    /// converge (fork-safety), and never removes a relay from the pool (a relay
    /// may still serve other subs / an in-flight converge publish). A dynamic
    /// singleton (or the last member of a bucket) is closed outright; a
    /// still-multiplexed bucket is re-issued under the SAME sub-id with the left
    /// circle's `#h` removed (dropping it from the wire filter) at `MIN(remaining)`
    /// `Resubscribe` `since` — which only NARROWS the shared floor, never skipping
    /// a remaining circle's un-applied event. The router is updated to the
    /// remaining set BEFORE the replace-REQ so a straggler `kind:445` for the left
    /// circle is dropped without decryption. Idempotent: an unknown circle / no
    /// active session is `Ok`.
    ///
    /// Holds the [`Self::lifecycle`] lock for the whole body (no callee re-takes
    /// it): `client.unsubscribe` empties no relay pool (only `client.shutdown`
    /// does), so this cannot re-introduce the `NoRelays` race.
    ///
    /// # Errors
    ///
    /// Returns [`LiveSyncError`] only if a multiplexed-bucket re-issue's subscribe
    /// fails (the caller then falls back to a full restart).
    pub async fn unsubscribe_circle(&self, group_id_hex: &str) -> LiveSyncResult<()> {
        let _lifecycle = self.lifecycle.lock().await;
        if self.shutdown.load(Ordering::Acquire) {
            return Ok(());
        }

        // Snapshot the sub serving this circle, then drop the read guard.
        let found = {
            let guard = self.active.read().await;
            guard.as_ref().and_then(|active| {
                active
                    .group_subs
                    .iter()
                    .find(|s| s.group_ids_hex.contains(group_id_hex))
                    .map(|s| (s.sub_id.clone(), s.relays.clone(), s.group_ids_hex.clone()))
            })
        };
        let Some((sub_id, relays, sub_hexes)) = found else {
            // No active session or unknown circle → idempotent no-op.
            return Ok(());
        };

        // PAUSED: this circle's REQ is already closed (the pause CLOSEd every
        // one), so there is nothing to unsubscribe and nothing to re-issue. Drop
        // it from the model and drop its anchor, so a stray EOSE for a recycled
        // sub-id can never advance a cursor for a circle we no longer follow.
        if self.paused.load(Ordering::Acquire) {
            self.processor.forget_subscription(group_id_hex);
            self.processor.forget_delivery_for_sub(&sub_id);
            if let Some(active) = self.active.write().await.as_mut() {
                if sub_hexes.len() <= 1 {
                    active.group_subs.retain(|s| s.sub_id != sub_id);
                } else if let Some(sub) = active.group_subs.iter_mut().find(|s| s.sub_id == sub_id)
                {
                    sub.group_ids_hex.remove(group_id_hex);
                }
            }
            log::debug!(
                "[live_sync::subscribe] unsubscribe_circle dropped (paused) {}",
                circle_handle(group_id_hex)
            );
            return Ok(());
        }

        if sub_hexes.len() <= 1 {
            // Singleton / last member: CLOSE the REQ (drops its `#h` from the
            // wire). Bounded so a wedged pool op can't stall the lifecycle lock.
            if bounded(RELAY_LIFECYCLE_OP_TIMEOUT, self.client.unsubscribe(&sub_id))
                .await
                .is_err()
            {
                log::warn!("[live_sync] unsubscribe_circle: unsubscribe timed out; proceeding");
            }
            self.router.write().await.rollback_subscription(&sub_id);
            // Its REQ is closed: drop the anchor so no later EOSE for a recycled
            // sub-id can advance a cursor for a circle we no longer follow, and
            // the delivery windows so a REQ that no longer exists cannot be
            // reported silent (and re-issued) by the health tick.
            self.processor.forget_subscription(group_id_hex);
            self.processor.forget_delivery_for_sub(&sub_id);
            if let Some(active) = self.active.write().await.as_mut() {
                active.group_subs.retain(|s| s.sub_id != sub_id);
            }
        } else {
            // Still-multiplexed bucket: re-issue `#h = remaining` under the SAME
            // sub-id. Update the router to the remaining set FIRST so a straggler
            // for the left circle is dropped pre-decryption during the replace.
            let mut remaining = sub_hexes.clone();
            remaining.remove(group_id_hex);
            self.router
                .write()
                .await
                .register_group(&relays, &sub_id, &remaining);

            let mut remaining_vec: Vec<String> = remaining.iter().cloned().collect();
            remaining_vec.sort();
            let now = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap_or(i64::MAX);
            // The bucket's REQ is being replaced, so every remaining circle
            // starts a fresh anchor generation at this local `now`; the leaving
            // circle's anchor is dropped outright.
            self.processor.forget_subscription(group_id_hex);
            for hex in &remaining_vec {
                self.processor.note_subscription_opened(hex, now);
            }
            let since = self.remove_reissue_since(&remaining_vec, now);
            let filter = group_filter(&remaining_vec, since);
            self.subscribe_bucket(relays.clone(), sub_id.clone(), filter)
                .await?;

            if let Some(active) = self.active.write().await.as_mut() {
                if let Some(s) = active.group_subs.iter_mut().find(|s| s.sub_id == sub_id) {
                    s.group_ids_hex = remaining;
                }
            }
        }

        log::debug!(
            "[live_sync::subscribe] unsubscribe_circle dropped {}",
            circle_handle(group_id_hex)
        );
        Ok(())
    }

    /// The `since` an [`Self::unsubscribe_circle`] re-issue of a multiplexed
    /// bucket uses for the REMAINING circles: `MIN` over their per-circle cursors
    /// with the wider [`SubscribePhase::Resubscribe`] buffer.
    ///
    /// Extracted so the losslessness invariant is unit-testable: the re-issue
    /// `since` is `MIN(remaining)`, never below `MIN(all)`, so removing one member
    /// only NARROWS the shared floor — it can never regress to a fresh `now` and
    /// skip a remaining circle's un-applied event.
    fn remove_reissue_since(&self, remaining_hex: &[String], now: i64) -> i64 {
        self.bucket_since(remaining_hex, SubscribePhase::Resubscribe, now)
    }

    /// Builds the owned handle set the repair task drives (see [`RepairPlane`]).
    fn repair_plane(&self) -> RepairPlane {
        RepairPlane {
            client: self.client.clone(),
            circle: Arc::clone(&self.circle),
            processor: Arc::clone(&self.processor),
            router: Arc::clone(&self.router),
            shutdown: Arc::clone(&self.shutdown),
            paused: Arc::clone(&self.paused),
            active: Arc::clone(&self.active),
            lifecycle: Arc::clone(&self.lifecycle),
            repair: Arc::clone(&self.repair),
            own_pubkey: self.own_pubkey,
        }
    }

    /// Probes the active session's REQs: how many the pool still holds, and
    /// which have gone silent.
    ///
    /// Returns `(expected, live, silent_keys)`, all empty when no session is
    /// active.
    ///
    /// Registration in nostr-relay-pool is LOCAL and survives a disconnect (the
    /// pool replays it on reconnect), so a shortfall between `expected` and
    /// `live` is not a relay that is merely mid-handshake — it is a REQ a
    /// `CLOSED` deleted, which `should_resubscribe` will never bring back.
    ///
    /// A relay string that does not parse never entered the pool either, so it
    /// is counted in neither: counting it as expected-but-missing would make the
    /// health tick re-anchor forever over a url no REQ was ever issued to.
    ///
    /// # Why only the GROUP plane is checked for silence
    ///
    /// A silent inbox REQ is the NORMAL state — invitations are rare, so on a
    /// typical device the inbox delivers nothing for weeks. Reading that as a
    /// reason to act would make the arm fire on essentially every tick forever,
    /// which is not a cheap no-op: it would re-issue the inbox REQ at `since =
    /// cursor − 49 h` (NIP-59 mandates backdating, hence the lookback), so the
    /// device would ask its relays to replay two days of gift wraps keyed on its
    /// own `#p` every quarter of an hour — battery, relay load, and a standing
    /// re-advertisement of "this npub is here, asking about itself".
    ///
    /// Nothing is given up. The inbox failure that actually matters is a relay
    /// ending the REQ, and that is caught by the PRESENCE arm above (the deleted
    /// subscription is gone from `client.subscriptions()`) and repaired by
    /// [`run_repair`] within seconds.
    async fn probe_subscriptions(&self) -> (usize, usize, Vec<RepairKey>) {
        let Some(active) = self.active.read().await.clone() else {
            return (0, 0, Vec::new());
        };
        let live = self.client.subscriptions().await;
        let now = chrono::Utc::now().timestamp();
        let window = delivery_silence_window_secs();
        let is_live = |sub_id: &SubscriptionId, url: &RelayUrl| {
            live.get(sub_id).is_some_and(|m| m.contains_key(url))
        };

        let mut expected = 0usize;
        let mut present = 0usize;
        let mut silent: Vec<RepairKey> = Vec::new();
        for g in &active.group_subs {
            for relay in &g.relays {
                let Ok(url) = RelayUrl::parse(relay) else {
                    continue;
                };
                expected += 1;
                let key = RepairKey {
                    relay_url: url,
                    sub_id: g.sub_id.clone(),
                };
                if is_live(&key.sub_id, &key.relay_url) {
                    present += 1;
                    // Silence is only meaningful for a REQ the pool still holds;
                    // one it no longer holds is the presence arm's business, and
                    // counting it twice would re-anchor it twice.
                    if self
                        .processor
                        .last_delivery_secs(&key)
                        .is_some_and(|at| delivery_is_silent(at, now, window))
                    {
                        silent.push(key);
                    }
                }
            }
        }
        // Only when the last open actually issued the inbox REQ. Under a fold
        // period > 1 a burst deliberately opens none, and counting it as
        // expected-but-missing would make `health_needs_resubscribe` re-anchor
        // the whole session on every tick — closing the REQs it just counted.
        if self.inbox_req_open.load(Ordering::Acquire) {
            for relay in &active.inbox_relays {
                let Ok(url) = RelayUrl::parse(relay) else {
                    continue;
                };
                expected += 1;
                if is_live(&active.inbox_sub_id, &url) {
                    present += 1;
                }
            }
        }
        (expected, present, silent)
    }

    /// Presence-only snapshot of the engine pool's relay connectivity (M8-4).
    ///
    /// Folds nostr-relay-pool's eight [`RelayStatus`] variants into three
    /// disjoint buckets so a caller can tell "all good" from "some still
    /// connecting" from "some dropped":
    ///
    /// - **connected** — `Connected`.
    /// - **still-connecting** — `Initialized` / `Pending` / `Connecting`: the
    ///   relay is mid-setup. Transient, so it is neither a drop (no resubscribe)
    ///   nor healthy-subscribed yet (does not read as all-healthy).
    /// - **dropped** — `Disconnected` / `Terminated` / `Banned` (mirroring
    ///   nostr-relay-pool's own `is_disconnected`): this warrants a re-anchor.
    ///
    /// Returns only counts, never a relay url (Security Rule 4/6).
    ///
    /// `Sleeping` is deliberately in no bucket: [`build_engine_client`] never
    /// enables `sleep_when_idle` (it defaults off), so the engine pool cannot
    /// produce a `Sleeping` relay, and were one to appear it is an intentional
    /// idle state — not a drop to heal. If that option is ever enabled and
    /// sleeping relays must be re-woken, that logic would be added here.
    async fn health_probe(&self) -> (RelayHealthSnapshot, Vec<RepairKey>) {
        let relays = self.client.relays().await;
        let total = relays.len();
        let mut connected = 0usize;
        let mut still_connecting = 0usize;
        let mut disconnected = 0usize;
        for relay in relays.values() {
            match relay.status() {
                RelayStatus::Connected => connected += 1,
                RelayStatus::Initialized | RelayStatus::Pending | RelayStatus::Connecting => {
                    still_connecting += 1;
                }
                RelayStatus::Disconnected | RelayStatus::Terminated | RelayStatus::Banned => {
                    disconnected += 1;
                }
                // Intentional idle — counted in `total` only, never a drop.
                RelayStatus::Sleeping => {}
            }
        }
        let (subscriptions_expected, subscriptions_live, silent) = self.probe_subscriptions().await;
        (
            RelayHealthSnapshot {
                total,
                connected,
                still_connecting,
                disconnected,
                subscriptions_expected,
                subscriptions_live,
                subscriptions_silent: silent.len(),
            },
            silent,
        )
    }

    /// Presence-only snapshot of the engine pool's relay connectivity and
    /// subscription liveness. See [`Self::health_probe`] for the full contract.
    pub async fn relay_health(&self) -> RelayHealthSnapshot {
        self.health_probe().await.0
    }

    /// Re-issues exactly the REQ endpoints the delivery arm found silent.
    ///
    /// Routed through the repair schedule rather than calling
    /// [`RepairPlane::reissue`] directly, so a silent endpoint that is ALREADY
    /// being repaired after a `CLOSED` is not re-issued twice, and so the shared
    /// jittered backoff governs how often one stubbornly quiet endpoint can be
    /// re-issued (Security Rule 12). Draining the queue here rather than leaving
    /// it to [`run_repair`] keeps the tick's reported outcome honest — it says
    /// what it did, not what it hoped someone else would do. If the repair task
    /// wins the race for a key, `take_due` simply returns fewer keys and the
    /// re-issue still happens exactly once.
    ///
    /// The lifecycle lock [`RepairPlane::reissue`] requires is the caller's, and
    /// deliberately so: it is the same acquisition the tick's `paused` read is
    /// taken under, so this cannot arm a re-issue against a session that was
    /// paused between the probe and here.
    async fn reanchor_silent_subscriptions(
        &self,
        _lifecycle: &TokioMutexGuard<'_, ()>,
        silent: Vec<RepairKey>,
    ) {
        for key in &silent {
            self.repair.note_closed(key, ClosedKind::Dropped);
        }
        let due = self.repair.take_due();
        if due.is_empty() {
            return;
        }
        let plane = self.repair_plane();
        for key in &due {
            plane.reissue(key).await;
        }
        log::info!("[live_sync::health] re-anchored the silent subscription(s)");
    }

    /// Runs one subscription-health maintenance tick (M8-4).
    ///
    /// A no-op ([`HealthAction::EngineOff`]) if the session has been stopped or
    /// its ingest worker has died (neither is repairable in place — the caller
    /// rebuilds the session). Otherwise it snapshots relay connectivity, live
    /// subscription presence and per-REQ delivery, and applies ONE OF TWO
    /// remedies:
    ///
    /// * a **dropped relay or a missing REQ** → the whole-session foreground
    ///   re-anchor ([`Self::resume_after_background`]'s body, run under this
    ///   tick's own lock acquisition): reconnect the pool and re-issue every
    ///   subscription at its persisted cursor under the same subscription ids (no
    ///   miss window). Sockets are involved, so nothing narrower would do;
    /// * **delivery silence alone** → [`Self::reanchor_silent_subscriptions`],
    ///   which re-issues ONLY the `(relay, sub)` endpoints that went quiet. Every
    ///   socket is up and every REQ is registered, so a whole-session re-anchor
    ///   would be pure cost — including the inbox's 49-hour gift-wrap replay.
    ///
    /// The two report DIFFERENT actions — [`HealthAction::Resubscribed`] and
    /// [`HealthAction::TargetedReanchor`] — because they differ by orders of
    /// magnitude in cost and a targeted re-anchor is expected on an idle device;
    /// the outcome's subscription counters say what the tick saw.
    ///
    /// The presence and delivery arms are what make this a repair for a relay
    /// that keeps its socket open after deleting our REQ; connectivity alone
    /// reads that state as perfectly healthy (see [`super::health`]).
    ///
    /// The `SESSION`-empty "engine off" gate lives at the FFI boundary; this
    /// method additionally guards on [`Self::is_running`] so a stopped-but-still
    /// -referenced core also no-ops.
    ///
    /// # Errors
    ///
    /// Returns [`LiveSyncError`] if the re-anchor's re-subscription fails.
    pub async fn maintain_subscription_health(&self) -> LiveSyncResult<SubscriptionHealthOutcome> {
        if !self.is_running() {
            return Ok(SubscriptionHealthOutcome::engine_off());
        }
        // PAUSED: short-circuit BEFORE the probe, and this is the single most
        // important gate in the burst design. A paused pool is `Terminated`
        // across the board, which `health_needs_resubscribe` reads as "dropped"
        // — so a tick that reached `health_probe` would call
        // `resume_after_background` and silently re-open standing REQs in the
        // background, undoing the pause on a timer. There is nothing to heal
        // either: the next burst re-subscribes every REQ at its persisted cursor
        // by construction.
        if self.paused.load(Ordering::Acquire) {
            return Ok(SubscriptionHealthOutcome::paused());
        }
        let (snapshot, silent) = self.health_probe().await;
        // And AGAIN, under the lifecycle lock, because the gate above cannot
        // stop a tick that was already inside `health_probe` when a pause began.
        // Such a tick sees the pause's own all-`Terminated` pool, reads it as
        // "dropped", and re-opens the entire session — standing REQs, a socket,
        // the 55 s pinger and the 49-hour `#p` inbox REQ — at an instant that is
        // not a publish, with no burst left to close it again. Re-reading the
        // flag outside the lock would only narrow that: the pause could still
        // complete between the read and the open. So the read and the remedy
        // share ONE acquisition, and both remedies below inherit it.
        let lifecycle = self.lifecycle.lock().await;
        if self.paused.load(Ordering::Acquire) {
            return Ok(SubscriptionHealthOutcome::paused());
        }
        let action = if health_needs_resubscribe(snapshot) {
            // A dropped relay or a REQ missing from the pool: the whole session
            // needs re-anchoring, sockets included. The FOREGROUND kind, which
            // always carries the inbox REQ and consumes no fold position — see
            // [`Self::resume_after_background`].
            self.resume_burst(&lifecycle, BurstKind::Foreground, INBOX_BURSTS_PER_REQ)
                .await?;
            HealthAction::Resubscribed
        } else if health_needs_targeted_reanchor(snapshot) {
            // Delivery silence only. Every socket is up and every REQ is
            // registered, so a full `resume_after_background` would be gross
            // overkill: it reconnects the pool and re-issues EVERY REQ on EVERY
            // relay, including the inbox at its 49-hour gift-wrap lookback. Only
            // the endpoints that went quiet are re-issued.
            self.reanchor_silent_subscriptions(&lifecycle, silent).await;
            HealthAction::TargetedReanchor
        } else {
            HealthAction::Healthy
        };
        drop(lifecycle);
        Ok(SubscriptionHealthOutcome {
            action,
            relays_total: snapshot.total,
            relays_still_connecting: snapshot.still_connecting,
            relays_disconnected: snapshot.disconnected,
            subscriptions_expected: snapshot.subscriptions_expected,
            subscriptions_live: snapshot.subscriptions_live,
            subscriptions_silent: snapshot.subscriptions_silent,
        })
    }
}

/// The owned counterpart of [`SubscribeCtx`], for the task that outlives a
/// borrow of the core.
///
/// Every handle here is a CLONE of one the session already holds — `Client` is
/// internally `Arc`-backed, and the rest are `Arc`s — so this duplicates
/// handles, never state: the repair task and the session act on the same pool,
/// the same router, the same anchors and the same lifecycle lock.
///
/// **Rule 14.** It holds `Arc<CircleManager>` (directly and through the
/// processor), so the task it drives MUST be one `stop` joins. It is spawned in
/// [`LiveSyncCore::start`] and pushed onto `tasks` beside the receiver and the
/// worker; anything that spawns it elsewhere re-creates the orphaned-MLS-session
/// hazard the `tasks` field exists to close.
struct RepairPlane {
    client: Client,
    circle: Arc<CircleManager>,
    processor: Arc<EngineProcessor>,
    router: Arc<RwLock<Router>>,
    shutdown: Arc<AtomicBool>,
    /// The session's pause flag: a paused session holds no REQ, so there is
    /// nothing to repair and a re-issue would re-open a socket the pause closed.
    paused: Arc<AtomicBool>,
    active: Arc<RwLock<Option<ActiveSession>>>,
    lifecycle: Arc<TokioMutex<()>>,
    repair: Arc<RepairQueue>,
    own_pubkey: PublicKey,
}

impl RepairPlane {
    fn ctx(&self) -> SubscribeCtx<'_> {
        SubscribeCtx {
            client: &self.client,
            circle: &self.circle,
            processor: &self.processor,
            router: &self.router,
            shutdown: &self.shutdown,
            own_pubkey: self.own_pubkey,
        }
    }

    /// Re-issues the one REQ `key` names, on the one relay that ended it.
    ///
    /// Best-effort: a re-issue that fails leaves the key's backoff armed, and
    /// the 15-minute health tick is the standing backstop either way. Silent on
    /// a `key` the active session no longer models — the session moved on, so
    /// there is nothing to restore.
    ///
    /// Only the affected relay is re-subscribed. The other relays in the bucket
    /// still hold the REQ, and re-issuing to them would ask each to replay its
    /// stored window for nothing.
    ///
    /// # Lifecycle lock
    ///
    /// **The caller MUST hold the lifecycle lock** for the whole re-issue: that
    /// is the invariant the lock documents — `client.shutdown()` (via `stop`)
    /// empties the pool, so a subscribe not serialized against it can land on an
    /// emptied pool and fail with the opaque `NoRelays`. Acquiring it is the
    /// CALLER's job because it must be acquired cancellably; see [`run_repair`].
    /// The subscribe's own shutdown check keeps a `stop` waiting on the lock
    /// from being delayed by a network round-trip.
    ///
    /// # Cursor safety
    ///
    /// The re-issue goes through [`SubscribeCtx::issue_group`] /
    /// [`SubscribeCtx::issue_inbox`] like every other REQ, so it opens a FRESH
    /// cursor-anchor generation at the same local `now` its `since` is derived
    /// from — never later than the request it vouches for. The superseded
    /// generation's hold-backs go with it, which is safe for exactly the reason
    /// [`super::anchor`] gives: the new REQ's floor comes from the PERSISTED
    /// cursor, which those hold-backs already prevented from advancing.
    /// `Resubscribe` phase widens the group buffer, so the gap the `CLOSED`
    /// opened is re-fetched rather than skipped.
    async fn reissue(&self, key: &RepairKey) {
        if self.shutdown.load(Ordering::Acquire) {
            return;
        }
        // Belt and braces: `run_repair` already returns before `take_due` while
        // paused (an early return HERE would consume the pending re-issue that
        // `take_due` armed), but the health tick's `reanchor_silent_subscriptions`
        // is a second caller — and re-issuing a REQ onto a disconnected pool
        // while paused would either fail loudly or, worse, re-open one.
        if self.paused.load(Ordering::Acquire) {
            return;
        }
        let Some(active) = self.active.read().await.clone() else {
            return;
        };
        let now = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap_or(i64::MAX);
        let ctx = self.ctx();

        if key.sub_id == active.inbox_sub_id {
            let Some(relay) = matching_relay(&active.inbox_relays, &key.relay_url) else {
                return;
            };
            let outcome = ctx
                .issue_inbox(
                    std::slice::from_ref(relay),
                    &key.sub_id,
                    SubscribePhase::Resubscribe,
                    now,
                )
                .await;
            self.report_reissue("inbox", outcome.is_ok());
            return;
        }

        let Some(sub) = active.group_subs.iter().find(|s| s.sub_id == key.sub_id) else {
            return;
        };
        let Some(relay) = matching_relay(&sub.relays, &key.relay_url) else {
            return;
        };
        let mut group_ids_hex: Vec<String> = sub.group_ids_hex.iter().cloned().collect();
        group_ids_hex.sort();
        let outcome = ctx
            .issue_group(
                std::slice::from_ref(relay),
                &key.sub_id,
                &group_ids_hex,
                SubscribePhase::Resubscribe,
                now,
            )
            .await;
        self.report_reissue("group", outcome.is_ok());
    }

    /// Reports the outcome of one re-issue: presence-only log, plus — on success
    /// — a [`SyncStatusReason::Connected`] on the bus.
    ///
    /// The `Connected` is what closes the consumer's false-alarm window. A
    /// `CLOSED` emits `RelayError`, and without a matching recovery signal a UI
    /// built on that status would show "sharing may be paused" until something
    /// else happened to clear it — indefinitely, since the repair is silent.
    /// Emitting `Connected` here means the consumer can pair the two: the REQ
    /// this device lost is live again. Deliberately NOT a new enum variant —
    /// that would need an FFI change this unit cannot make — and `Connected`
    /// already means "the receive plane is serving", which is exactly what a
    /// completed re-issue restores (see [`SyncStatusReason::Connected`]).
    ///
    /// A FAILED re-issue emits nothing: the endpoint is still down, the backoff
    /// is already armed for another attempt, and the health tick remains the
    /// standing backstop. Claiming recovery here would be the false-clear this
    /// signal exists to prevent.
    fn report_reissue(&self, plane: &str, ok: bool) {
        if ok {
            self.processor.emit_status(SyncStatusReason::Connected);
            log::info!("[live_sync::repair] re-issued a relay-closed {plane} subscription");
        } else {
            log::warn!(
                "[live_sync::repair] re-issuing a relay-closed {plane} subscription failed; \
                 the health tick remains the backstop"
            );
        }
    }
}

/// The stored relay string equal to `url`, if this REQ was issued to it.
///
/// Compared as parsed [`RelayUrl`]s rather than as text. A textual compare would
/// in fact work today — [`run_worker`]'s router lookup is exactly that, and it
/// works because `RelayUrl`'s rendering and the session's canonical relay string
/// happen to agree. Parsing removes the dependency on that agreement instead of
/// adding a second place that silently breaks when either normalization changes:
/// here the two sides come from genuinely different origins (a relay's `CLOSED`
/// versus [`super::planes::canonical_relay_set`]), and the failure mode of a
/// mismatch is a repair that silently never fires.
fn matching_relay<'a>(relays: &'a [String], url: &RelayUrl) -> Option<&'a String> {
    relays
        .iter()
        .find(|r| RelayUrl::parse(r).is_ok_and(|parsed| parsed == *url))
}

/// The repair task: re-issues every REQ a relay ended, when its backoff allows.
///
/// Parks on the queue's notification or on the earliest pending deadline,
/// whichever comes first, and exits on `cancel` — the same independent wake
/// [`run_receiver`] relies on, for the same reason: a task parked in an `await`
/// never observes the `shutdown` flag, and this one holds `Arc<CircleManager>`
/// (Rule 14), so it must not be able to outlive `stop`.
///
/// While the session is PAUSED it parks on the notification alone: an entry that
/// is already due keeps its deadline in the past, and the gate that defers it
/// (rightly) does not clear it, so arming the deadline arm would spin.
async fn run_repair(plane: RepairPlane, mut cancel: watch::Receiver<bool>) {
    loop {
        plane.repair.note_wakeup();
        if plane.shutdown.load(Ordering::Acquire) {
            break;
        }
        // PARK while paused, never arm a deadline. `take_due` is the only thing
        // that clears `due_at` and the gate below skips it, so a due entry keeps
        // `next_deadline` in the PAST for the whole pause: `sleep_until` is then
        // Ready on every poll and this loop burns a core until `repair.clear()`
        // — through the marker send, its ack, and the UNCAPPED publish gauge.
        // The schedule is a backoff, not a hot loop (see [`super::repair`]).
        let deadline = if plane.paused.load(Ordering::Acquire) {
            None
        } else {
            plane.repair.next_deadline()
        };
        tokio::select! {
            biased;
            // `wait_for` (not `changed()`) so a cancel raised before this
            // receiver existed is still observed — see `run_receiver`.
            _ = cancel.wait_for(|cancelled| *cancelled) => break,
            () = plane.repair.wake() => {}
            () = sleep_until_opt(deadline) => {}
        }
        if plane.shutdown.load(Ordering::Acquire) {
            break;
        }
        // BEFORE `take_due`, never inside `reissue`. `take_due` CLEARS `due_at`,
        // bumps `attempts` and arms the next backoff, so an early return further
        // down would CONSUME the pending re-issue rather than keep it — the
        // repair would be silently forgotten instead of deferred. Deferring is
        // free: the next burst re-issues every REQ under a fresh generation, and
        // the pause clears this queue for exactly that reason.
        //
        // While paused this is reached only from a `wake()`, so it re-parks
        // rather than spinning (the deadline arm is parked above).
        if plane.paused.load(Ordering::Acquire) {
            continue;
        }
        let due = plane.repair.take_due();
        if due.is_empty() {
            continue;
        }
        // Acquire the lifecycle lock WITH an escape hatch, never blindly.
        // `stop` holds that lock across its own `join_tasks`, so a repair
        // parked on it unconditionally could never be joined — and a timed-out
        // join is exactly the orphaned Rule-14 `LiveSessionGuard` the `tasks`
        // vec exists to prevent. `stop` raises cancel BEFORE contending for
        // the lock, so this arm always wins that race.
        let lifecycle = tokio::select! {
            biased;
            _ = cancel.wait_for(|cancelled| *cancelled) => break,
            guard = plane.lifecycle.lock() => guard,
        };
        for key in due {
            plane.reissue(&key).await;
        }
        drop(lifecycle);
    }
}

/// Sleeps until `at`, or forever when nothing is scheduled.
async fn sleep_until_opt(at: Option<Instant>) {
    match at {
        Some(at) => tokio::time::sleep_until(tokio::time::Instant::from_std(at)).await,
        None => std::future::pending::<()>().await,
    }
}

/// What [`run_monitor`] needs to enforce the radio-off promise: the flag saying
/// the engine wants no socket at all, the pool to cut one with, and the
/// presence-only counter that records having had to.
///
/// The pool handle is a `Client` clone, which is an `Arc` over the relay pool —
/// no MLS state, so no Rule-14 lifetime edge. `disconnect()` cuts the WHOLE pool
/// rather than the one relay that reported: while the radio is off every relay
/// is meant to be terminated anyway, `disconnect` early-returns on the ones that
/// already are, and the wider sweep needs no relay url — which must never reach
/// a log (Rules 4/6).
struct RadioOffWatch {
    /// [`LiveSyncCore::radio_off`].
    radio_off: Arc<AtomicBool>,
    /// The engine pool.
    client: Client,
    /// [`LiveSyncCore::unrequested_connections`].
    cut: Arc<AtomicUsize>,
}

impl RadioOffWatch {
    /// Whether the pool holds that relay in a connected or connecting state
    /// RIGHT NOW — the question a stale status notification cannot answer.
    async fn is_up(&self, relay_url: &RelayUrl) -> bool {
        self.client
            .relay(relay_url.clone())
            .await
            .is_ok_and(|relay| {
                matches!(
                    relay.status(),
                    RelayStatus::Connected | RelayStatus::Connecting
                )
            })
    }
}

/// The pool `Monitor` consumer: turns relay status transitions into bus statuses.
///
/// Before this existed the `Monitor` was attached and read by nothing, so
/// [`SyncStatusReason::Disconnected`] / [`SyncStatusReason::Reconnecting`] were
/// emitted by no production code and a dropped relay was invisible to the user.
///
/// A relay coming up is reported as `Connecting` the first time and
/// `Reconnecting` afterwards, because those mean different things to a UI: the
/// first is startup, the second is a live session that lost a socket. The set of
/// relays seen connected is bounded by the pool, and never logged.
///
/// While the session is PAUSED between background bursts the per-relay
/// `Disconnected` transitions are SUPPRESSED: the pause terminates every relay
/// by design, so surfacing those would make a deliberate pause indistinguishable
/// from a relay outage. Each burst's `Reconnecting`/`Connected` churn is left
/// alone — it is honest, and harmless while backgrounded.
///
/// It is also the RADIO-OFF WATCH: once a pause has cut every socket, a relay
/// that reports itself `Connecting`/`Connected` again is one the crate's retry
/// loop re-opened behind the engine's back, and this task terminates it and
/// counts it instead of reporting it (see [`RadioOffWatch`]).
///
/// Holds the bus, the two flags and a pool `Client` — no `Arc<CircleManager>` —
/// so it adds no Rule-14 edge, and exits on `cancel` so `stop` still joins it.
async fn run_monitor(
    mut notifications: broadcast::Receiver<MonitorNotification>,
    bus: EventBus,
    paused: Arc<AtomicBool>,
    watch: RadioOffWatch,
    mut cancel: watch::Receiver<bool>,
) {
    let mut ever_connected: HashSet<RelayUrl> = HashSet::new();
    loop {
        let notification = tokio::select! {
            biased;
            _ = cancel.wait_for(|cancelled| *cancelled) => break,
            received = notifications.recv() => received,
        };
        match notification {
            Ok(MonitorNotification::StatusChanged { relay_url, status }) => {
                // A relay coming UP while the radio is off is a socket this
                // session never asked for, and the only thing that produces one
                // is the crate's own retry loop having survived a pause (see
                // `LiveSyncCore::terminate_all_relays`). Two things follow, and
                // neither is "suppress it":
                //
                //  * cut it. This is the backstop that makes the pause's bounded
                //    re-assert a CLOSED loop rather than a probabilistic repair
                //    — including for the strand it cannot see at all, the one
                //    that reads as correctly `Terminated` and re-connects a
                //    retry interval later.
                //  * count it, and never report it as connectivity. Publishing
                //    `Connected`/`Reconnecting` here would have the health model
                //    clear its "disconnected since" stamp on the strength of a
                //    socket the engine did not open — reporting the falsification
                //    of P4 as evidence of health.
                if matches!(status, RelayStatus::Connected | RelayStatus::Connecting)
                    && watch.radio_off.load(Ordering::Acquire)
                {
                    // Judge the pool as it is NOW, not as the notification found
                    // it. A burst's own `Connected` can still be in this queue
                    // when the burst fails and cuts the radio behind it, and
                    // acting on that stale transition would both inflate the
                    // count — which is meant to mean "a socket was up while the
                    // radio was off", a claim about the present — and re-cut a
                    // relay that is already terminated. Either way the status is
                    // NOT reported: the radio is off now, so there is no
                    // connectivity to report.
                    if watch.is_up(&relay_url).await {
                        watch.cut.fetch_add(1, Ordering::AcqRel);
                        log::warn!(
                            "[live_sync] radio off: cutting a relay connection this session \
                             did not open"
                        );
                        watch.client.disconnect().await;
                    }
                    continue;
                }
                let reason = match status {
                    RelayStatus::Connected => {
                        ever_connected.insert(relay_url);
                        Some(SyncStatusReason::Connected)
                    }
                    RelayStatus::Connecting => Some(if ever_connected.contains(&relay_url) {
                        SyncStatusReason::Reconnecting
                    } else {
                        SyncStatusReason::Connecting
                    }),
                    // A PAUSE terminates every relay on purpose. Reporting that
                    // as `Disconnected` would have the health model stamp a
                    // "disconnected since" and — a burst interval can be as long
                    // as the receive-silence threshold — confirm a relay outage
                    // on a deliberate pause. The pause emits ONE `Paused`
                    // instead; a genuine drop while LIVE still reports here.
                    RelayStatus::Disconnected | RelayStatus::Terminated | RelayStatus::Banned => {
                        (!paused.load(Ordering::Acquire)).then_some(SyncStatusReason::Disconnected)
                    }
                    // Not transitions a user can act on: `Initialized`/`Pending`
                    // precede the connect attempt, and the engine never enables
                    // `sleep_when_idle` so `Sleeping` cannot occur.
                    RelayStatus::Initialized | RelayStatus::Pending | RelayStatus::Sleeping => None,
                };
                if let Some(reason) = reason {
                    bus.send(LiveSyncEvent::Status { reason });
                }
            }
            // A skipped status transition costs a status event, never state: the
            // health tick re-derives connectivity from the pool itself.
            Err(broadcast::error::RecvError::Lagged(_)) => {}
            Err(broadcast::error::RecvError::Closed) => break,
        }
    }
}

#[cfg(test)]
impl LiveSyncCore {
    /// [`Self::resume_burst`] with the lifecycle lock taken here, so the inbox
    /// fold tests can drive an `inbox_every` the shipped constant does not take
    /// without each restating an acquisition production callers own.
    async fn resume_burst_for_test(&self, kind: BurstKind, inbox_every: u32) -> LiveSyncResult<()> {
        let lifecycle = self.lifecycle.lock().await;
        self.resume_burst(&lifecycle, kind, inbox_every).await
    }

    /// Test accessor: the session shutdown flag, so a test can prove the
    /// interruptibility contract (a mid-flight op / settle wait observes it).
    fn shutdown_for_test(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.shutdown)
    }

    /// Test snapshot of the live group subscriptions as
    /// `(sub_id_string, sorted_relays, sorted_#h)`, so a delta test can assert the
    /// bookkeeping without reaching into private fields.
    async fn live_group_subs_for_test(&self) -> Vec<(String, Vec<String>, Vec<String>)> {
        self.active
            .read()
            .await
            .as_ref()
            .map_or_else(Vec::new, |a| {
                a.group_subs
                    .iter()
                    .map(|s| {
                        let mut relays = s.relays.clone();
                        relays.sort();
                        let mut hexes: Vec<String> = s.group_ids_hex.iter().cloned().collect();
                        hexes.sort();
                        (s.sub_id.to_string(), relays, hexes)
                    })
                    .collect()
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{Alphabet, Keys, SingleLetterTag};
    use std::sync::atomic::AtomicUsize;
    use tempfile::TempDir;

    /// A relay url for the retry tests' "a relay accepted" fixture.
    fn accepting_relay() -> RelayUrl {
        RelayUrl::parse("wss://relay.example").expect("a fixture relay url parses")
    }

    /// The endpoints the core's burst window vouches for — `None` while it is
    /// CLOSED, which is a different fact from an open that issued nothing.
    async fn open_endpoints(core: &LiveSyncCore) -> Option<Vec<RepairKey>> {
        match &*core.burst_window.read().await {
            BurstWindow::Open(endpoints) => Some(endpoints.clone()),
            BurstWindow::Closed => None,
        }
    }

    fn build_core() -> (LiveSyncCore, TempDir) {
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
        let pk = keys.public_key();
        (LiveSyncCore::new_local(circle, pk), dir)
    }

    #[tokio::test]
    async fn a_timed_out_join_keeps_its_handles_so_a_retry_stays_truthful() {
        // The regression test for a fail-OPEN. An earlier `join_tasks` moved
        // every handle into one timed future, so a timeout dropped them all
        // (tokio does not abort on drop — the tasks kept running) and left
        // `self.tasks` empty. The next `stop` then saw an empty vec and
        // answered `NotStarted`, which the FFI maps to "drained" — telling the
        // caller the manager `Arc`, and with it the Rule-14 guard, had been
        // released while a live task still held it. That is exactly the
        // re-check the `TimedOut` contract instructs the caller to perform.
        let (core, _dir) = build_core();
        let (release_tx, release_rx) = tokio::sync::oneshot::channel::<()>();
        core.tasks
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(tokio::spawn(async move {
                let _ = release_rx.await;
            }));

        assert_eq!(
            core.join_tasks(Duration::from_millis(50)).await,
            StopOutcome::TimedOut,
            "a task that will not finish must time out"
        );
        assert_eq!(
            core.join_tasks(Duration::from_millis(50)).await,
            StopOutcome::TimedOut,
            "the RE-CHECK must still say TimedOut; answering NotStarted here is \
             the fail-open this test exists to catch"
        );

        // ...and the handle really was retained, not merely reported: once the
        // task finishes, the same core can finally observe a genuine drain.
        let _ = release_tx.send(());
        assert_eq!(
            core.join_tasks(Duration::from_secs(5)).await,
            StopOutcome::Drained,
            "a retained handle must still be joinable once its task completes"
        );
    }

    #[tokio::test]
    async fn joining_a_core_that_never_spawned_reports_nothing_outstanding() {
        // The other half: `NotStarted` must stay reachable for a core with no
        // tasks, or the FFI would report a permanent TimedOut for an idle
        // session and the caller would retry forever.
        let (core, _dir) = build_core();
        assert_eq!(
            core.join_tasks(Duration::from_millis(50)).await,
            StopOutcome::NotStarted
        );
    }

    #[tokio::test]
    async fn bounded_returns_the_value_when_the_future_completes() {
        let r = bounded(Duration::from_secs(5), async { 7_u32 }).await;
        assert_eq!(
            r.unwrap(),
            7,
            "the happy path must never false-trip the timeout"
        );
    }

    #[tokio::test]
    async fn bounded_maps_an_elapsed_deadline_to_timeout() {
        // A would-hang op (`pending`) is bounded into a clean Timeout in ~20ms.
        let r: LiveSyncResult<()> =
            bounded(Duration::from_millis(20), std::future::pending()).await;
        assert!(matches!(r, Err(LiveSyncError::Timeout)));
    }

    #[tokio::test]
    async fn retry_until_accepted_returns_ok_on_the_first_non_empty_success() {
        // Happy path: the very first subscribe reports >= 1 relay accepted the REQ
        // ⇒ Ok immediately, with NO retry wait (the orphan-avoidance must not add
        // latency to the common case).
        let attempts = Arc::new(AtomicUsize::new(0));
        let waits = Arc::new(AtomicUsize::new(0));
        let attempts_c = Arc::clone(&attempts);
        let waits_c = Arc::clone(&waits);
        let r = retry_until_accepted(
            SUBSCRIBE_MAX_ATTEMPTS,
            move || {
                let attempts_c = Arc::clone(&attempts_c);
                async move {
                    attempts_c.fetch_add(1, Ordering::AcqRel);
                    // A relay accepted on the first try.
                    Ok(vec![accepting_relay()])
                }
            },
            move || {
                let waits_c = Arc::clone(&waits_c);
                async move {
                    waits_c.fetch_add(1, Ordering::AcqRel);
                }
            },
        )
        .await;
        assert_eq!(
            r.expect("a non-empty success on the first try must be Ok"),
            vec![accepting_relay()],
            "the ACCEPTED relay set must come back, not merely a yes/no: it is what \
             a background burst waits on, so a relay that never took the REQ must \
             not appear in it"
        );
        assert_eq!(
            attempts.load(Ordering::Acquire),
            1,
            "the happy path subscribes exactly once"
        );
        assert_eq!(
            waits.load(Ordering::Acquire),
            0,
            "no retry wait on a first-try success"
        );
    }

    #[tokio::test]
    async fn retry_until_accepted_retries_then_errors_when_every_attempt_is_empty() {
        // The orphan bug: every relay silently drops the REQ (empty success) on
        // every attempt. The retry must try exactly N times, wait N-1 times
        // between them, and then FAIL VISIBLY (so `start` tears down) rather than
        // proceed as subscribed. The wait closure just counts — no real sleep.
        let attempts = Arc::new(AtomicUsize::new(0));
        let waits = Arc::new(AtomicUsize::new(0));
        let attempts_c = Arc::clone(&attempts);
        let waits_c = Arc::clone(&waits);
        let r = retry_until_accepted(
            SUBSCRIBE_MAX_ATTEMPTS,
            move || {
                let attempts_c = Arc::clone(&attempts_c);
                async move {
                    attempts_c.fetch_add(1, Ordering::AcqRel);
                    // Every relay dropped the REQ: an EMPTY accepted set.
                    Ok(Vec::new())
                }
            },
            move || {
                let waits_c = Arc::clone(&waits_c);
                async move {
                    waits_c.fetch_add(1, Ordering::AcqRel);
                }
            },
        )
        .await;
        assert!(
            matches!(r, Err(LiveSyncError::Relay(_))),
            "an always-empty success set must error, not silently orphan the sub"
        );
        assert_eq!(
            attempts.load(Ordering::Acquire),
            SUBSCRIBE_MAX_ATTEMPTS as usize,
            "must try exactly SUBSCRIBE_MAX_ATTEMPTS times before giving up"
        );
        assert_eq!(
            waits.load(Ordering::Acquire),
            (SUBSCRIBE_MAX_ATTEMPTS - 1) as usize,
            "must wait N-1 times between attempts, never after the final one"
        );
    }

    #[tokio::test]
    async fn retry_until_accepted_stops_on_the_first_empty_then_non_empty_success() {
        // A relay finishes its handshake on the second attempt: one empty result,
        // one retry wait, then acceptance ⇒ Ok after two attempts.
        let attempts = Arc::new(AtomicUsize::new(0));
        let waits = Arc::new(AtomicUsize::new(0));
        let attempts_c = Arc::clone(&attempts);
        let waits_c = Arc::clone(&waits);
        let r = retry_until_accepted(
            SUBSCRIBE_MAX_ATTEMPTS,
            move || {
                let attempts_c = Arc::clone(&attempts_c);
                async move {
                    // Empty on the first attempt, accepted on the second.
                    let n = attempts_c.fetch_add(1, Ordering::AcqRel);
                    Ok(if n >= 1 {
                        vec![accepting_relay()]
                    } else {
                        Vec::new()
                    })
                }
            },
            move || {
                let waits_c = Arc::clone(&waits_c);
                async move {
                    waits_c.fetch_add(1, Ordering::AcqRel);
                }
            },
        )
        .await;
        assert_eq!(
            r.expect("acceptance on a later attempt must succeed"),
            vec![accepting_relay()],
            "the set that comes back is the one the ACCEPTING attempt reported"
        );
        assert_eq!(
            attempts.load(Ordering::Acquire),
            2,
            "one empty attempt, then an accepted retry"
        );
        assert_eq!(
            waits.load(Ordering::Acquire),
            1,
            "exactly one retry wait before the successful re-attempt"
        );
    }

    #[tokio::test]
    async fn retry_until_accepted_propagates_a_pool_error_without_retrying() {
        // A pool-level error (no relays / relay-not-found) is not self-healing:
        // it must propagate immediately, with no retry and no wait.
        let attempts = Arc::new(AtomicUsize::new(0));
        let waits = Arc::new(AtomicUsize::new(0));
        let attempts_c = Arc::clone(&attempts);
        let waits_c = Arc::clone(&waits);
        let r = retry_until_accepted(
            SUBSCRIBE_MAX_ATTEMPTS,
            move || {
                let attempts_c = Arc::clone(&attempts_c);
                async move {
                    attempts_c.fetch_add(1, Ordering::AcqRel);
                    Err(LiveSyncError::relay("no relays"))
                }
            },
            move || {
                let waits_c = Arc::clone(&waits_c);
                async move {
                    waits_c.fetch_add(1, Ordering::AcqRel);
                }
            },
        )
        .await;
        assert!(matches!(r, Err(LiveSyncError::Relay(_))));
        assert_eq!(
            attempts.load(Ordering::Acquire),
            1,
            "a pool error is not self-healing ⇒ no retry"
        );
        assert_eq!(waits.load(Ordering::Acquire), 0, "no wait on a hard error");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn subscribe_bucket_succeeds_against_a_real_connected_relay() {
        // End-to-end proof that `subscribe_bucket` reads `Output.success`
        // correctly through the real engine `Client`: added + connected relay ⇒
        // the REQ lands in `success` ⇒ Ok on the first try.
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        let _ = core.client.add_relay(url.as_str()).await;
        core.client.connect().await;
        core.client
            .wait_for_connection(Duration::from_secs(5))
            .await;

        let sub_id = SubscriptionId::new("test_group_0");
        let filter = Filter::new().kind(nostr::Kind::Custom(445));
        let r = tokio::time::timeout(
            Duration::from_secs(10),
            core.subscribe_bucket(vec![url], sub_id, filter),
        )
        .await
        .expect("subscribe_bucket must not hang against a live relay");
        assert!(
            r.is_ok(),
            "a subscribe to a connected relay must be accepted (non-empty success)"
        );
    }

    /// Builds one live group REQ (and, with `with_inbox`, the inbox REQ) against
    /// `url` and records them in `active`, the way `start` would — but WITHOUT
    /// the supervisor, so nothing races the cursor-anchor assertions below.
    ///
    /// Returns `(group_sub_id, inbox_sub_id)`.
    async fn issue_live_subs(
        core: &LiveSyncCore,
        url: &str,
        group_id_hex: &str,
        with_inbox: bool,
    ) -> (SubscriptionId, SubscriptionId) {
        let _ = core.client.add_relay(url).await;
        core.client.connect().await;
        core.client
            .wait_for_connection(Duration::from_secs(5))
            .await;
        let sub_id = SubscriptionId::new("test_group_0");
        let inbox_sub_id = SubscriptionId::new("test_inbox_0");
        let now = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap();
        let relays = vec![url.to_string()];
        core.ctx()
            .issue_group(
                &relays,
                &sub_id,
                std::slice::from_ref(&group_id_hex.to_string()),
                SubscribePhase::Initial,
                now,
            )
            .await
            .expect("the initial REQ must be accepted by a connected relay");
        if with_inbox {
            core.ctx()
                .issue_inbox(&relays, &inbox_sub_id, SubscribePhase::Initial, now)
                .await
                .expect("the inbox REQ must be accepted by a connected relay");
        }
        *core.active.write().await = Some(ActiveSession {
            group_subs: vec![LiveGroupSub {
                sub_id: sub_id.clone(),
                relays: relays.clone(),
                group_ids_hex: HashSet::from([group_id_hex.to_string()]),
            }],
            inbox_relays: if with_inbox { relays } else { Vec::new() },
            inbox_sub_id: inbox_sub_id.clone(),
        });
        (sub_id, inbox_sub_id)
    }

    /// A `(relay, sub)` endpoint key for the test relay.
    fn endpoint(url: &str, sub_id: &SubscriptionId) -> RepairKey {
        RepairKey {
            relay_url: RelayUrl::parse(url).unwrap(),
            sub_id: sub_id.clone(),
        }
    }

    /// The C3 repair, end to end against a real relay.
    ///
    /// nostr-relay-pool deletes a subscription on most `CLOSED` reasons and
    /// `should_resubscribe` then answers `false` for the missing entry — so the
    /// REQ is gone forever while the socket stays `Connected`. `client
    /// .unsubscribe` reproduces exactly that pool state.
    ///
    /// Three things must follow: the health tick must SEE it with every relay
    /// connected, the repair must put a fresh REQ back on the wire, and that REQ
    /// must open a FRESH cursor-anchor generation (a re-issue that inherited the
    /// spent generation could never advance the cursor again).
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_relay_closed_subscription_is_re_issued_with_a_fresh_anchor_generation() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        let hex = "aa".repeat(32);
        let (sub_id, _) = issue_live_subs(&core, &url, &hex, false).await;

        assert!(
            !core.client.subscription(&sub_id).await.is_empty(),
            "precondition: the pool holds the REQ we just issued"
        );
        // Spend this generation's single advance, so a fresh one is observable.
        core.processor.note_end_of_stored_events(&hex);
        assert!(
            !core.processor.note_end_of_stored_events(&hex),
            "precondition: the generation's one advance is spent"
        );

        // What a `CLOSED` does inside the pool.
        core.client.unsubscribe(&sub_id).await;
        assert!(
            core.client.subscription(&sub_id).await.is_empty(),
            "precondition: the pool no longer holds the REQ"
        );

        let snapshot = core.relay_health().await;
        assert_eq!(
            snapshot.disconnected, 0,
            "the socket is still up — which is exactly why connectivity cannot \
             see this failure"
        );
        assert!(
            snapshot.subscriptions_live < snapshot.subscriptions_expected,
            "the health snapshot must notice the missing REQ"
        );
        assert!(
            health_needs_resubscribe(snapshot),
            "a REQ a relay ended must warrant a re-anchor even with every relay \
             connected"
        );

        {
            // `reissue` requires the lifecycle lock, exactly as `run_repair`
            // acquires it (cancellably) before calling.
            let _lifecycle = core.lifecycle.lock().await;
            core.repair_plane()
                .reissue(&RepairKey {
                    relay_url: RelayUrl::parse(&url).unwrap(),
                    sub_id: sub_id.clone(),
                })
                .await;
        }

        assert!(
            !core.client.subscription(&sub_id).await.is_empty(),
            "the repair must put a fresh REQ back on the wire"
        );
        assert!(
            core.processor.note_end_of_stored_events(&hex),
            "the re-issued REQ must open a FRESH cursor-anchor generation, or \
             this circle's cursor could never advance again"
        );
        let _ = core.stop().await;
    }

    /// The whole wiring: the worker's CLOSED hook surfaces a status and hands
    /// the key to the repair task, which re-issues the REQ.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_repair_task_re_issues_a_closed_subscription_and_reports_it() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        let hex = "bb".repeat(32);
        let (sub_id, _) = issue_live_subs(&core, &url, &hex, false).await;
        core.client.unsubscribe(&sub_id).await;

        let mut bus = core.bus().subscribe();
        let task = tokio::spawn(run_repair(core.repair_plane(), core.cancel_tx.subscribe()));

        // Exactly what `run_worker` does for a CLOSED on a sub we own.
        super::super::supervisor::note_subscription_closed(
            &core.processor,
            &core.repair,
            &endpoint(&url, &sub_id),
            ClosedKind::Dropped,
        );

        let reported = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if matches!(
                    bus.recv().await,
                    Ok(LiveSyncEvent::Status {
                        reason: SyncStatusReason::RelayError
                    })
                ) {
                    return true;
                }
            }
        })
        .await
        .expect("a relay ending our REQ must be reported, not swallowed");
        assert!(reported);

        // The first Dropped incident is due immediately, so this settles as soon
        // as the task is scheduled; the timeout only bounds a hang.
        let restored = tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                if !core.client.subscription(&sub_id).await.is_empty() {
                    return true;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("the repair task must re-issue the REQ the relay ended");
        assert!(restored);

        let _ = core.stop().await;
        let _ = tokio::time::timeout(Duration::from_secs(5), task).await;
    }

    /// The delivery arm, wired end to end — and confined to the group plane.
    ///
    /// Two promises in one test, because they are the same mistake from either
    /// side. A quiet INBOX must never count as silent: invitations are rare, so
    /// on a typical device the inbox delivers nothing for weeks, and its REQ
    /// carries a 49-hour gift-wrap lookback — an arm that fired on it would
    /// have every device replay two days of wraps keyed on its own `#p` on every
    /// tick, forever. A silent GROUP bucket must be re-issued, and ONLY it.
    ///
    /// The window is backdated by re-opening that one endpoint's delivery
    /// window, which is exactly what a REQ issued that long ago and never served
    /// looks like; no clock is mocked and nothing sleeps.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn only_a_silent_group_req_is_re_issued_and_a_quiet_inbox_is_never_one() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        let hex = "cc".repeat(32);
        let (group_sub, inbox_sub) = issue_live_subs(&core, &url, &hex, true).await;

        // Spend both planes' advances, so a re-opened generation is observable.
        core.processor.note_end_of_stored_events(&hex);
        core.processor.note_inbox_end_of_stored_events();
        assert!(!core.processor.note_end_of_stored_events(&hex));
        assert!(!core.processor.note_inbox_end_of_stored_events());

        // Both planes fresh: nothing is silent, nothing needs doing.
        let fresh = core.relay_health().await;
        assert_eq!(
            fresh.subscriptions_silent, 0,
            "a REQ issued a moment ago has not been silent — silence is measured from the REQ, not from process start"
        );
        assert!(!health_needs_resubscribe(fresh));
        assert!(!health_needs_targeted_reanchor(fresh));
        assert_eq!(
            core.maintain_subscription_health().await.unwrap().action,
            HealthAction::Healthy,
            "a healthy plane must be able to report Healthy at all — an arm that fires on every tick makes this unreachable"
        );

        // Age the INBOX endpoint far past the window. It must STILL not count:
        // a quiet inbox is the normal state, not a fault.
        let now = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap();
        let window = delivery_silence_window_secs();
        core.processor
            .open_delivery_window(&endpoint(&url, &inbox_sub), now - window * 10);
        let inbox_aged = core.relay_health().await;
        assert_eq!(
            inbox_aged.subscriptions_silent, 0,
            "the inbox plane is exempt from the silence arm"
        );
        assert!(!health_needs_targeted_reanchor(inbox_aged));

        // Now age the GROUP endpoint.
        core.processor
            .open_delivery_window(&endpoint(&url, &group_sub), now - window);
        let stale = core.relay_health().await;
        assert_eq!(
            stale.disconnected, 0,
            "the socket is up and the registration is intact: connectivity and presence both read healthy"
        );
        assert_eq!(stale.subscriptions_live, stale.subscriptions_expected);
        assert_eq!(stale.subscriptions_silent, 1, "exactly the group endpoint");
        assert!(
            !health_needs_resubscribe(stale),
            "silence must not escalate to a whole-session re-anchor"
        );
        assert!(health_needs_targeted_reanchor(stale));

        let outcome = core
            .maintain_subscription_health()
            .await
            .expect("the targeted re-anchor must succeed against a live relay");
        assert_eq!(
            outcome.action,
            HealthAction::TargetedReanchor,
            "silence gets its own action: reporting a full Resubscribed would make \
             an idle device look like it kept losing relays"
        );
        assert_eq!(outcome.subscriptions_silent, 1, "and it says what it saw");
        assert_eq!(outcome.subscriptions_expected, outcome.subscriptions_live);

        // Exactly one REQ was re-issued: the group bucket's generation is fresh
        // again, and the inbox's is untouched.
        assert!(
            core.processor.note_end_of_stored_events(&hex),
            "the silent group bucket must have been re-issued"
        );
        assert!(
            !core.processor.note_inbox_end_of_stored_events(),
            "the inbox REQ must NOT have been re-issued: re-issuing it means asking every relay for a 49-hour gift-wrap replay keyed on this device's #p"
        );
        // The arm is self-limiting: the re-issue reseeds that endpoint's window.
        assert_eq!(core.relay_health().await.subscriptions_silent, 0);
        let _ = core.stop().await;
    }

    /// The recovery signal that closes the consumer's false-alarm window.
    ///
    /// A relay `CLOSED` emits `RelayError`; a UI built on that status would show
    /// "sharing may be paused" until something cleared it, and the repair is
    /// otherwise entirely silent. So a SUCCESSFUL re-issue must emit
    /// `Connected`, and exactly once — a stream of them would be as useless as
    /// none. A FAILED re-issue must emit nothing at all: the endpoint is still
    /// down, and claiming recovery there is the false clear this exists to
    /// prevent.
    ///
    /// No `start()` here, so nothing else on this core emits `Connected` (the
    /// session-start status and the pool `Monitor` task are both absent) — the
    /// count is therefore attributable to the repair alone.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_successful_re_issue_reports_connected_and_a_failed_one_reports_nothing() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        let hex = "ff".repeat(32);
        let (sub_id, _) = issue_live_subs(&core, &url, &hex, false).await;
        core.client.unsubscribe(&sub_id).await;

        let mut bus = core.bus().subscribe();
        super::super::supervisor::note_subscription_closed(
            &core.processor,
            &core.repair,
            &endpoint(&url, &sub_id),
            ClosedKind::Dropped,
        );
        {
            let _lifecycle = core.lifecycle.lock().await;
            core.repair_plane().reissue(&endpoint(&url, &sub_id)).await;
        }
        assert!(
            !core.client.subscription(&sub_id).await.is_empty(),
            "precondition: the repair really did re-issue the REQ"
        );

        // The bus must carry exactly RelayError then Connected, in that order.
        let mut seen: Vec<SyncStatusReason> = Vec::new();
        while let Ok(Ok(LiveSyncEvent::Status { reason })) =
            tokio::time::timeout(Duration::from_millis(200), bus.recv()).await
        {
            seen.push(reason);
        }
        assert_eq!(
            seen,
            vec![SyncStatusReason::RelayError, SyncStatusReason::Connected],
            "a lost REQ must report the loss AND, once it is live again, exactly one recovery"
        );

        // Now a re-issue that cannot succeed: the active session names a relay
        // that was never added to the pool, so the subscribe fails at the pool
        // level (relay not found) and propagates without retrying.
        let ghost = "wss://127.0.0.1:9/".to_string();
        if let Some(active) = core.active.write().await.as_mut() {
            active.group_subs[0].relays = vec![ghost.clone()];
        }
        let mut bus = core.bus().subscribe();
        {
            let _lifecycle = core.lifecycle.lock().await;
            core.repair_plane()
                .reissue(&endpoint(&ghost, &sub_id))
                .await;
        }
        let mut seen_after: Vec<SyncStatusReason> = Vec::new();
        while let Ok(Ok(LiveSyncEvent::Status { reason })) =
            tokio::time::timeout(Duration::from_millis(200), bus.recv()).await
        {
            seen_after.push(reason);
        }
        assert!(
            !seen_after.contains(&SyncStatusReason::Connected),
            "a failed re-issue must never claim recovery, got {seen_after:?}"
        );
        let _ = core.stop().await;
    }

    /// A single-relay repair must re-seed only the relay it re-subscribed.
    ///
    /// The delivery clock is per `(relay, subscription)`, not per circle. Keyed
    /// per circle, a relay that ends and re-subscribes our REQ every few seconds
    /// would keep the circle's clock permanently fresh — masking genuine silence
    /// on the bucket's OTHER relays, which is the failure the arm exists to find.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_single_relay_re_issue_does_not_refresh_the_other_relays_windows() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay_a = nostr_relay_builder::MockRelay::run().await.unwrap();
        let relay_b = nostr_relay_builder::MockRelay::run().await.unwrap();
        let url_a = relay_a.url().await.to_string();
        let url_b = relay_b.url().await.to_string();
        let (core, _dir) = build_core();
        let hex = "ee".repeat(32);
        let sub_id = SubscriptionId::new("test_group_0");

        for url in [&url_a, &url_b] {
            let _ = core.client.add_relay(url.as_str()).await;
        }
        core.client.connect().await;
        core.client
            .wait_for_connection(Duration::from_secs(5))
            .await;
        let now = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap();
        let relays = vec![url_a.clone(), url_b.clone()];
        core.ctx()
            .issue_group(
                &relays,
                &sub_id,
                std::slice::from_ref(&hex),
                SubscribePhase::Initial,
                now,
            )
            .await
            .expect("the bucket REQ must be accepted");
        *core.active.write().await = Some(ActiveSession {
            group_subs: vec![LiveGroupSub {
                sub_id: sub_id.clone(),
                relays,
                group_ids_hex: HashSet::from([hex.clone()]),
            }],
            inbox_relays: Vec::new(),
            inbox_sub_id: SubscriptionId::new("test_inbox_0"),
        });

        // Both endpoints have gone quiet.
        let window = delivery_silence_window_secs();
        for url in [&url_a, &url_b] {
            core.processor
                .open_delivery_window(&endpoint(url, &sub_id), now - window);
        }
        assert_eq!(core.relay_health().await.subscriptions_silent, 2);

        // Relay A alone ends and repairs its REQ.
        {
            let _lifecycle = core.lifecycle.lock().await;
            core.repair_plane()
                .reissue(&endpoint(&url_a, &sub_id))
                .await;
        }

        let after = core.relay_health().await;
        assert_eq!(
            after.subscriptions_silent, 1,
            "only relay A's window may be re-seeded; relay B is still silent and must stay countable"
        );
        assert!(
            core.processor
                .last_delivery_secs(&endpoint(&url_b, &sub_id))
                .is_some_and(|at| delivery_is_silent(at, now, window)),
            "relay B's silence must survive relay A's repair"
        );
        let _ = core.stop().await;
    }

    /// `stop` must join EVERY supervisor task, the repair task included, even
    /// with a repair outstanding.
    ///
    /// This is the C1-orphan regression pin. `stop`'s `TimedOut` is not a
    /// cosmetic outcome: the FFI reinstalls a timed-out core into the process
    /// -global `SESSION`, which keeps `Arc<CircleManager>` — and with it the
    /// Rule-14 `LiveSessionGuard` — held by a static no Dart handle in any
    /// isolate references, leaving an MLS database no isolate can reopen for the
    /// life of the process. Adding a task that `stop` cannot join is therefore
    /// how this unit would have re-created the exact failure the analysis ranks
    /// first.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stop_drains_every_supervisor_task_including_a_pending_repair() {
        let (core, _relay, _dir, url) = started_core_with(&["dd".repeat(32).as_str()]).await;
        let sub_id = SubscriptionId::new(core.live_group_subs_for_test().await[0].0.clone());

        core.repair
            .note_closed(&endpoint(&url, &sub_id), ClosedKind::Dropped);

        let outcome = tokio::time::timeout(Duration::from_secs(20), core.stop())
            .await
            .expect("stop must not hang with a repair outstanding");
        assert_eq!(
            outcome,
            StopOutcome::Drained,
            "every supervisor task — receiver, worker, repair and monitor — must be joined by stop; a TimedOut here is the orphaned Rule-14 guard"
        );
    }

    /// A repair waiting for the lifecycle lock must still be joinable.
    ///
    /// `stop` holds that lock across its OWN `join_tasks`, so a repair task that
    /// waited for it unconditionally could not be joined while `stop` held it —
    /// `stop` would report `TimedOut`, which is precisely the orphaned Rule-14
    /// `LiveSessionGuard` (an MLS database no isolate can reopen for the life of
    /// the process). The repair task therefore acquires the lock with `cancel`
    /// as an escape hatch, and this pins that.
    ///
    /// Deterministic and discriminating: we HOLD the lock for the whole test and
    /// never release it, and only raise cancel once the task has demonstrably
    /// taken its key off the queue — after which its sole remaining step is the
    /// lock we are holding. Without the escape hatch it parks there forever and
    /// this test times out.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_repair_waiting_for_the_lifecycle_lock_still_exits_on_cancel() {
        let (core, _dir) = build_core();
        let (cancel_tx, cancel_rx) = watch::channel(false);
        let task = tokio::spawn(run_repair(core.repair_plane(), cancel_rx));

        let held = core.lifecycle.lock().await;
        assert_eq!(
            core.repair.pending_len(),
            0,
            "precondition: the queue starts empty"
        );
        core.repair.note_closed(
            &RepairKey {
                relay_url: RelayUrl::parse("wss://relay.example").unwrap(),
                sub_id: SubscriptionId::new("s_group_0"),
            },
            ClosedKind::Dropped,
        );
        // `note_closed` set the count to 1 synchronously in THIS task, and the
        // only thing that lowers it is the repair task's `take_due`. So
        // observing 0 here proves the task has dequeued the key and its sole
        // remaining step is the lock we hold — whether or not it got there
        // before this loop's first read. (Asserting `== 1` first would be the
        // race: the task is free to dequeue the instant `note_closed` returns.)
        while core.repair.pending_len() != 0 {
            tokio::task::yield_now().await;
        }

        cancel_tx.send_replace(true);
        tokio::time::timeout(Duration::from_secs(5), task)
            .await
            .expect(
                "a repair waiting for the lifecycle lock must still exit on cancel; \
                 parking there unconditionally is what makes stop report TimedOut \
                 and orphan the Rule-14 guard",
            )
            .expect("the repair task must join cleanly");
        drop(held);
    }

    #[tokio::test]
    async fn a_wedged_receive_plane_reports_the_session_as_not_running() {
        // `is_running` is what the Dart self-heal restarts on, so a dead ingest
        // worker must flip it — otherwise the engine reports itself healthy
        // forever while ingesting nothing.
        let (core, _dir) = build_core();
        assert!(core.is_running());
        core.wedged.store(true, Ordering::Release);
        assert!(
            !core.is_running(),
            "a dead worker must not read as a live session"
        );
        // ...and a health tick over a dead plane is a no-op, not a repair: the
        // caller has to rebuild the session, which a re-anchor cannot do.
        assert_eq!(
            core.maintain_subscription_health().await.unwrap().action,
            HealthAction::EngineOff
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stop_on_a_fresh_engine_returns_promptly() {
        let (core, _dir) = build_core();
        let outcome = tokio::time::timeout(Duration::from_secs(2), core.stop())
            .await
            .expect("stop on a never-started engine must return promptly");
        assert_eq!(
            outcome,
            StopOutcome::NotStarted,
            "a core that never spawned a supervisor task must report NotStarted, \
             not a Drained/TimedOut join it never performed"
        );
    }

    // DELETED-WITH-SUBJECT: `stop_drains_an_in_flight_converge_task` and
    // `stop_drain_is_bounded_when_a_task_wedges` drove the `converge_inflight`
    // counter that `stop` used to drain. The engine owns convergence internally
    // now, so `LiveSyncCore` no longer spawns a detached converge task and the
    // counter + its `STOP_DRAIN_TIMEOUT_SECS` drain are deleted (`stop_inner`:
    // "no detached converge task to drain"). The surviving teardown-promptness
    // invariant is covered by `stop_on_a_fresh_engine_returns_promptly` (stop
    // returns promptly) and the `bounded_*` tests (a wedged pool op is bounded
    // into a clean Timeout, never a hang).

    // DELETED-WITH-SUBJECT: `stop_interrupts_a_converge_stuck_in_its_settle_window`
    // exercised `autocommit::settle_wait` — the hand-rolled interruptible
    // settle-window sleep of the deleted settle/converge/autocommit layer (plan
    // §5.4). The engine owns convergence now (`advance_convergence`), so there is
    // no Haven-parked settle window to interrupt. The surviving teardown-promptness
    // invariant — `stop` drains an in-flight converge and is bounded on a wedged
    // one — is covered by `stop_drains_an_in_flight_converge_task` and
    // `stop_drain_is_bounded_when_a_task_wedges` above.

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn subscribe_bucket_bails_immediately_when_shutting_down() {
        // Interruptibility of the "un-bounded subscribe": once `stop` raises the
        // shutdown flag, an in-flight `subscribe_bucket` (a lifecycle-lock holder's
        // relay op) must abandon its attempt AND its retries instantly and fail
        // closed as NoSession — so the holder releases the lifecycle lock and stop
        // proceeds, and so it never subscribes onto a pool stop is about to empty.
        // With shutdown set it returns before ever touching the client, so no relay
        // or connection is needed and there is NO SUBSCRIBE_RETRY_WAIT accrual.
        let (core, _dir) = build_core();
        core.shutdown_for_test().store(true, Ordering::Release);
        let start = std::time::Instant::now();
        let r = core
            .subscribe_bucket(
                vec!["wss://relay.example".to_string()],
                SubscriptionId::new("interrupted"),
                Filter::new().kind(nostr::Kind::Custom(445)),
            )
            .await;
        assert!(
            matches!(r, Err(LiveSyncError::NoSession)),
            "a subscribe under an active shutdown must fail closed as NoSession: {r:?}"
        );
        assert!(
            start.elapsed() < Duration::from_secs(1),
            "no retry waits when shutting down; took {:?}",
            start.elapsed()
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stop_raises_shutdown_before_taking_the_lifecycle_lock() {
        // The teardown-promptness fix relies on `stop` making the shutdown flag
        // observable BEFORE it contends for the lifecycle lock, so a lock-HOLDER
        // (an in-flight start/subscribe) sees it at its interruption points and
        // bails, releasing the lock promptly instead of making `stop` wait out the
        // holder's full relay round-trip. Prove the ordering DIRECTLY without
        // racing a real holder: hold the lifecycle lock ourselves (standing in for
        // a mid-flight holder), spawn `stop`, and assert the flag is ALREADY raised
        // while `stop` is still parked on the lock we hold. Under the OLD ordering
        // (flag set only inside `stop_inner`, AFTER acquiring the lock) the flag
        // would still be false here and this test would fail — so it is not vacuous.
        let (core, _dir) = build_core();
        let core = Arc::new(core);
        assert!(core.is_running(), "fresh core is running");

        // Hold the lifecycle lock: `stop` cannot enter `stop_inner` until we drop it.
        let held = core.lifecycle.lock().await;
        let stop_core = Arc::clone(&core);
        let stopping = tokio::spawn(async move { stop_core.stop().await });

        // `stop` stores the flag synchronously before its first await (the lock
        // acquire), so it becomes observable promptly even while `stop` is parked.
        // Poll (bounded) rather than assume a precise scheduling instant.
        let mut flag_seen_while_locked = false;
        for _ in 0..200 {
            if !core.is_running() {
                flag_seen_while_locked = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert!(
            flag_seen_while_locked,
            "stop must raise the shutdown flag BEFORE acquiring the lifecycle lock"
        );
        assert!(
            !stopping.is_finished(),
            "stop must still be parked on the lifecycle lock we are holding"
        );

        // Release the lock → `stop` proceeds through `stop_inner` and completes.
        drop(held);
        let outcome = tokio::time::timeout(Duration::from_secs(10), stopping)
            .await
            .expect("stop must complete once the lifecycle lock is released")
            .expect("stop task must not panic");
        assert_eq!(
            outcome,
            StopOutcome::NotStarted,
            "this core was never started, so the released stop has no task to join"
        );
        assert!(!core.is_running(), "stop completed with the flag raised");
    }

    #[test]
    fn new_local_is_running_and_exposes_a_subscribable_bus() {
        let (core, _dir) = build_core();
        assert!(core.is_running());
        // The bus is subscribable before any start.
        let _rx = core.bus().subscribe();
        // An unseeded circle still yields a well-defined (floored) since.
        let since = core.bucket_since(&["aa".to_string()], SubscribePhase::Initial, 1_000_000);
        assert_eq!(since, 0, "unseeded circle → since floored at 0");
    }

    #[test]
    fn two_engines_for_the_same_pubkey_get_distinct_salts() {
        // Distinct ephemeral salts → distinct sub-ids across sessions (PSI-2).
        let (a, _da) = build_core();
        let (b, _db) = build_core();
        assert_ne!(*a.salt, *b.salt);
    }

    #[test]
    fn bucket_since_takes_the_minimum_across_circles() {
        let (core, _dir) = build_core();
        let now = 10_000_000_i64;
        // Seed two circles to different cursors; the bucket since must track the
        // SMALLER (earlier) one so neither circle's events are skipped.
        let early_hex = "aa00";
        let late_hex = "bb11";
        core.circle
            .seed_sync_cursor_if_unset(&group_cursor_stream(early_hex), 1_000_000)
            .unwrap();
        core.circle
            .seed_sync_cursor_if_unset(&group_cursor_stream(late_hex), 5_000_000)
            .unwrap();
        let since = core.bucket_since(
            &[early_hex.to_string(), late_hex.to_string()],
            SubscribePhase::Initial,
            now,
        );
        // The earlier cursor (1_000_000 ms = 1000 s) minus the 10s initial buffer.
        assert_eq!(since, 1000 - 10);
    }

    #[test]
    fn resume_after_a_stopped_session_errors_with_no_session() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let (core, _dir) = build_core();
            // Never started, so the arrange-stop must report NotStarted. Pinning
            // it keeps this a stopped-session test: if the stop silently became
            // a TimedOut (tasks still live) the "stopped" premise would be false.
            assert_eq!(core.stop().await, StopOutcome::NotStarted);
            assert!(!core.is_running());
            let result = core.resume_after_background().await;
            assert!(
                matches!(result, Err(LiveSyncError::NoSession)),
                "resume on a stopped session must fail closed, not re-open it"
            );
        });
    }

    #[test]
    fn relay_health_of_a_fresh_engine_reports_no_relays() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let (core, _dir) = build_core();
            // A never-started engine has an empty pool: nothing connected,
            // nothing dropped.
            let snapshot = core.relay_health().await;
            assert_eq!(snapshot.total, 0);
            assert_eq!(snapshot.disconnected, 0);
        });
    }

    #[test]
    fn subscription_health_on_a_running_engine_with_no_drops_is_healthy() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let (core, _dir) = build_core();
            assert!(core.is_running());
            // Empty pool ⇒ zero disconnected ⇒ Healthy, no re-anchor attempted
            // (a re-anchor would call `resume_after_background`, which here would
            // succeed as a no-op, but the decision must be Healthy).
            let outcome = core.maintain_subscription_health().await.unwrap();
            assert_eq!(outcome.action, HealthAction::Healthy);
            assert_eq!(outcome.relays_total, 0);
            assert_eq!(outcome.relays_disconnected, 0);
            // No session started ⇒ nothing expected, nothing live, nothing
            // silent. The counters must not report a shortfall out of an absent
            // session model, or the consumer would read "REQs are missing".
            assert_eq!(outcome.subscriptions_expected, 0);
            assert_eq!(outcome.subscriptions_live, 0);
            assert_eq!(outcome.subscriptions_silent, 0);
        });
    }

    #[test]
    fn subscription_health_on_a_stopped_engine_is_engine_off() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let (core, _dir) = build_core();
            assert_eq!(core.stop().await, StopOutcome::NotStarted);
            assert!(!core.is_running());
            let outcome = core.maintain_subscription_health().await.unwrap();
            assert_eq!(
                outcome.action,
                HealthAction::EngineOff,
                "a stopped session must no-op, never touch relays"
            );
            assert_eq!(outcome.relays_total, 0);
            assert_eq!(outcome.relays_disconnected, 0);
        });
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn add_relay_populates_the_pool_for_a_loopback_ws_url() {
        // Root-cause pin: `Client::add_relay` on the engine client is NOT the
        // failure. Both e2e-lane URL forms — iOS `ws://localhost:7777` and
        // Android `ws://10.0.2.2:7777` — parse, pass the WSS loopback gate, and
        // land in the pool. So an empty pool at subscribe time (Error::NoRelays,
        // "no relays") is NEVER a localhost-rejection at add time; it is an
        // emptied pool (a lifecycle race), which the lifecycle lock now closes.
        let _ = crate::relay::allow_ws_loopback_for_test();
        for url in [
            "ws://localhost:7777",
            "ws://10.0.2.2:7777",
            "wss://relay.example",
        ] {
            assert!(engine_relay_allowed(url), "gate must allow {url}");
            let client = build_engine_client();
            let added = client.add_relay(url).await;
            assert!(added.is_ok(), "add_relay({url}) must not error: {added:?}");
            assert_eq!(
                client.relays().await.len(),
                1,
                "add_relay({url}) must populate the engine pool"
            );
        }
    }

    /// The publish pool's power options must never be copied onto this one.
    ///
    /// `relay::manager::publish_relay_options` turns the keepalive off because
    /// that pool connects, sends, collects the `OK`s and holds no subscription:
    /// a ping there wakes the radio for a socket nothing is listening on. The
    /// engine pool is the opposite — a standing REQ is its whole purpose and
    /// its socket carries no other traffic, so the ping is the only thing that
    /// notices a NAT box silently dropping that REQ before the 15-minute health
    /// tick. "Make both pools consistent" is therefore a receive blackout, and
    /// this is its runtime half (the static half is
    /// `scripts/ci/check_engine_client_options.sh`).
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn engine_pool_keeps_ping_while_subscribed() {
        use nostr_relay_builder::{LocalRelay, RelayBuilder};

        let _ = crate::relay::allow_ws_loopback_for_test();
        let server = LocalRelay::new(RelayBuilder::default());
        server.run().await.expect("local relay runs");
        let url = server.url().await.to_string();

        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "ab".repeat(32),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("the engine must start against a live local relay");

        let relay = core
            .client
            .relay(url.as_str())
            .await
            .expect("the started engine registered its circle relay");

        // Anti-vacuity first: the keepalive is only load-bearing because this
        // socket is holding a REQ open, so a start that subscribed to nothing
        // must not be able to satisfy the flag assertion below.
        assert!(
            !relay.subscriptions().await.is_empty(),
            "the engine must be holding a standing REQ on this relay"
        );
        assert!(
            relay.flags().has_ping(),
            "the engine pool must keep its keepalive: registering these relays \
             the publish pool's way (pool().add_relay(url, publish_relay_options())) \
             strips PING, and a dropped standing REQ then stays silently dead \
             until the 15-minute health tick",
        );

        let _ = core.stop().await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_shutdown_engine_client_subscribe_yields_the_no_relays_error() {
        // Documents the mechanism the fix guards against: `client.shutdown()`
        // clears the pool (`force_remove_all_relays`), so any subsequent
        // subscribe returns the pool `NoRelays` ("no relays") — the exact string
        // seen in the iOS live-sync-start failure. This is WHY `start` must fail
        // closed (NoSession) rather than reach a subscribe on a shut-down client.
        let _ = crate::relay::allow_ws_loopback_for_test();
        let client = build_engine_client();
        let _ = client.add_relay("ws://localhost:7777").await;
        assert_eq!(client.relays().await.len(), 1);
        client.shutdown().await;
        assert_eq!(client.relays().await.len(), 0, "shutdown clears the pool");
        let sub = client
            .subscribe_with_id_to(
                vec!["ws://localhost:7777".to_string()],
                SubscriptionId::new("regress"),
                Filter::new().kind(nostr::Kind::Custom(445)),
                None,
            )
            .await;
        let msg = sub
            .expect_err("subscribe on an empty pool must error")
            .to_string();
        assert_eq!(
            msg, "no relays",
            "the emptied-pool error is verbatim 'no relays'"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn separate_engine_clients_have_isolated_pools() {
        // Rules out the shared-pool hypothesis: `start_session` does
        // `previous.stop()` (shuts the PRIOR core's client down) right before the
        // new core subscribes. If pools were shared, that would empty the new
        // core's pool → NoRelays. They are not: shutting one client down leaves
        // the other's pool intact, so the emptied-pool must come from stopping
        // the SAME core mid-start (the race the lifecycle lock closes).
        let _ = crate::relay::allow_ws_loopback_for_test();
        let client_a = build_engine_client();
        let client_b = build_engine_client();
        let _ = client_a.add_relay("ws://localhost:7777").await;
        client_b.shutdown().await;
        assert_eq!(
            client_a.relays().await.len(),
            1,
            "shutting down client B must not empty client A's pool"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn start_on_an_already_stopped_core_fails_closed_not_no_relays() {
        // REGRESSION (iOS live-sync start): a core whose `Client` was already shut
        // down must NOT reach a subscribe (which would return the opaque pool
        // "no relays"). The lifecycle shutdown-guard fails it closed as NoSession
        // with a loopback relay that WOULD otherwise pass the WSS gate and be
        // added — proving the guard, not the gate, is what stops it.
        let _ = crate::relay::allow_ws_loopback_for_test();
        let (core, _dir) = build_core();
        // Never started ⇒ NotStarted; the flag + client shutdown are what the
        // rest of the test exercises.
        assert_eq!(core.stop().await, StopOutcome::NotStarted);
        let result = core
            .start(
                &[CircleSpec {
                    group_id_hex: "ab".repeat(32),
                    relays: vec!["ws://localhost:7777".to_string()],
                }],
                &[],
            )
            .await;
        assert!(
            matches!(result, Err(LiveSyncError::NoSession)),
            "a stopped core's start must fail closed as NoSession, not 'no relays': {result:?}"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_stop_during_start_never_yields_no_relays() {
        // REGRESSION for the exact iOS symptom: a `stop` requested while `start`
        // is in flight on the SAME core must NOT empty the pool between `start`'s
        // add_relay and its subscribe (which produced Error::NoRelays, "no
        // relays"). The lifecycle lock serializes them, so `start` either
        // completes fully (Ok, against the live MockRelay) or — if `stop` won the
        // lock first — fails closed as NoSession. Never "no relays".
        //
        // Runs many rounds so any residual interleaving window would be hit.
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        for _ in 0..12 {
            let (core, _dir) = build_core();
            let core = Arc::new(core);
            let circles = vec![CircleSpec {
                group_id_hex: "cd".repeat(32),
                relays: vec![url.clone()],
            }];
            let start_core = Arc::clone(&core);
            let start = tokio::spawn(async move { start_core.start(&circles, &[]).await });
            // Request a stop on the same core concurrently with the in-flight start.
            // The outcome is racy BY DESIGN here — whether there is a supervisor
            // task to join depends on which side won the lifecycle lock, which is
            // the very race under test — so it is the one place it must not be
            // asserted. The drain itself is pinned by `join_tasks_*` above.
            let _ = core.stop().await;
            let started = tokio::time::timeout(Duration::from_secs(10), start)
                .await
                .expect("start must not hang")
                .expect("start task must not panic");
            match started {
                // Either start won the lock and completed against the live
                // relay, or stop won it first and start failed closed. Any
                // OTHER error — notably the pool's opaque "no relays" — is the
                // regression.
                Ok(()) | Err(LiveSyncError::NoSession) => {}
                Err(other) => panic!(
                    "concurrent stop must never surface as a pool 'no relays' error: {other:?}"
                ),
            }
        }
    }

    #[test]
    fn engine_relay_allowed_gates_plaintext_ws() {
        // wss:// is always allowed; a non-loopback ws:// is never allowed
        // (the loopback opt-in only relaxes loopback hosts, which this isn't).
        assert!(engine_relay_allowed("wss://relay.example"));
        assert!(!engine_relay_allowed("ws://malicious.example"));
    }

    #[test]
    fn start_rejects_a_plaintext_ws_relay() {
        // The WSS-only gate (H1) must fail `start` closed on a plaintext ws://
        // relay before any connection is attempted — a non-loopback host is
        // rejected regardless of the loopback opt-in's state.
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let (core, _dir) = build_core();
            let result = core
                .start(
                    &[CircleSpec {
                        group_id_hex: "ab".repeat(32),
                        relays: vec!["ws://malicious.example".to_string()],
                    }],
                    &[],
                )
                .await;
            assert!(
                result.is_err(),
                "plaintext ws:// must be rejected by the engine WSS gate"
            );
            assert!(
                core.is_running(),
                "a pre-connect rejection leaves the engine un-started"
            );
        });
    }

    // ===================== Incremental subscribe/unsubscribe =====================

    /// Starts a live session over `hexes` (each on the SAME shared `MockRelay`), so
    /// the delta-op tests run against a real connected relay. Returns the started
    /// core (Arc, for the concurrent-stop test), the relay + tempdir (kept alive),
    /// and the relay url (to add more circles).
    async fn started_core_with(
        hexes: &[&str],
    ) -> (
        Arc<LiveSyncCore>,
        nostr_relay_builder::MockRelay,
        TempDir,
        String,
    ) {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, dir) = build_core();
        let core = Arc::new(core);
        let circles: Vec<CircleSpec> = hexes
            .iter()
            .map(|h| CircleSpec {
                group_id_hex: (*h).to_string(),
                relays: vec![url.clone()],
            })
            .collect();
        core.start(&circles, &[]).await.expect("session starts");
        (core, relay, dir, url)
    }

    /// Waits (bounded) for the next routed-event marker on the bus.
    ///
    /// The marker is the `#[cfg(test)]` panic seam inside `process_group_event`,
    /// which `run_worker` isolates and reports as `Status { Unprocessable }`.
    /// Reaching it requires the worker to have ROUTED the event to a specific
    /// `#h`, which makes it the one per-event delivery oracle that survives both
    /// the engine's `Ok(Stale)` classification of undecryptable input and the
    /// removal of the per-event cursor advance.
    async fn await_routed(
        bus: &mut tokio::sync::broadcast::Receiver<crate::relay::live_sync::LiveSyncEvent>,
    ) -> bool {
        use crate::relay::live_sync::{LiveSyncEvent, SyncStatusReason};
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while tokio::time::Instant::now() < deadline {
            match tokio::time::timeout(Duration::from_secs(1), bus.recv()).await {
                Ok(Ok(LiveSyncEvent::Status {
                    reason: SyncStatusReason::Unprocessable,
                })) => return true,
                Ok(Ok(_)) | Err(_) => {}
                Ok(Err(_)) => return false,
            }
        }
        false
    }

    /// Waits (bounded) until `hex`'s start-generation EOSE anchor has been
    /// consumed, i.e. its cursor has moved off the cold-start seed.
    ///
    /// The live plane advances a cursor ONLY on a relay's end-of-stored-events
    /// (see `live_sync::anchor`), which lands asynchronously some time after
    /// `start` returns. Any test that snapshots a cursor has to settle that
    /// first, or it races an advance it did not cause and blames the next
    /// operation for it. Returns the settled value.
    async fn settle_eose_anchor(core: &LiveSyncCore, hex: &str) -> Option<i64> {
        let key = group_cursor_stream(hex);
        let read = || core.circle.read_sync_cursor(&key).ok().flatten();
        // The cold seed is `now − 24h`; the EOSE anchor is `now`, so "moved off
        // the seed" is an unambiguous, engine-independent signal.
        let floor = i64::try_from(nostr::Timestamp::now().as_secs())
            .unwrap_or(i64::MAX)
            .saturating_sub(SEED_LOOKBACK_SECS / 2)
            .saturating_mul(1000);
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        loop {
            let current = read();
            if current.is_some_and(|ms| ms >= floor) || tokio::time::Instant::now() >= deadline {
                return current;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }

    /// Waits (bounded) until `cond` holds, polling on a short interval.
    ///
    /// The interval is a POLL, never a proxy for a duration: the outcome is
    /// decided by `cond` alone, so a slow machine only makes the wait longer and
    /// can never flip the verdict. Returns whether it held.
    async fn poll_until(cond: impl FnMut() -> bool) -> bool {
        poll_until_within(Duration::from_secs(10), cond).await
    }

    /// [`poll_until`] for a condition that has to be awaited (a pool read).
    async fn poll_until_async<F>(mut cond: impl FnMut() -> F) -> bool
    where
        F: std::future::Future<Output = bool>,
    {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        loop {
            if cond().await {
                return true;
            }
            if tokio::time::Instant::now() >= deadline {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    /// [`poll_until`] with an explicit budget, for the tests that assert a
    /// condition NEVER holds and therefore always pay the whole wait.
    async fn poll_until_within(budget: Duration, mut cond: impl FnMut() -> bool) -> bool {
        let deadline = tokio::time::Instant::now() + budget;
        loop {
            if cond() {
                return true;
            }
            if tokio::time::Instant::now() >= deadline {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn subscribe_circle_does_not_re_anchor_existing_bucket_since() {
        // THE regression: adding a circle must NOT fold into an existing bucket
        // (which would collapse the bucket's shared `since` to the new circle's
        // cold seed). B is a SEPARATE singleton; A's entry is byte-identical, so
        // A's REQ was never re-issued and its `since` never recomputed.
        let a = "aa".repeat(32);
        let b = "bb".repeat(32);
        let (core, _relay, _dir, url) = started_core_with(&[&a]).await;

        let before = core.live_group_subs_for_test().await;
        assert_eq!(before.len(), 1);
        let a_sub_id = before[0].0.clone();
        assert_eq!(before[0].2, vec![a.clone()]);

        core.subscribe_circle(&CircleSpec {
            group_id_hex: b.clone(),
            relays: vec![url],
        })
        .await
        .expect("subscribe_circle B");

        let after = core.live_group_subs_for_test().await;
        assert_eq!(
            after.len(),
            2,
            "B is a SEPARATE singleton, never folded into A's bucket"
        );
        let a_entry = after
            .iter()
            .find(|e| e.2 == vec![a.clone()])
            .expect("A entry present");
        assert_eq!(a_entry.0, a_sub_id, "A's sub_id unchanged (no re-anchor)");
        let b_entry = after
            .iter()
            .find(|e| e.2 == vec![b.clone()])
            .expect("B entry present");
        assert_ne!(
            b_entry.0, a_sub_id,
            "B gets its OWN sub_id — a separate REQ with its own since"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn subscribe_circle_is_idempotent_for_an_already_subscribed_circle() {
        let a = "aa".repeat(32);
        let (core, _relay, _dir, url) = started_core_with(&[&a]).await;
        core.subscribe_circle(&CircleSpec {
            group_id_hex: a.clone(),
            relays: vec![url],
        })
        .await
        .expect("idempotent re-subscribe is Ok");
        let subs = core.live_group_subs_for_test().await;
        assert_eq!(
            subs.len(),
            1,
            "no duplicate entry for an already-subscribed circle"
        );
        assert_eq!(subs[0].2, vec![a]);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn subscribe_circle_seeds_only_its_own_cursor() {
        let a = "aa".repeat(32);
        let b = "bb".repeat(32);
        let (core, _relay, _dir, url) = started_core_with(&[&a]).await;
        // Settle A's own start-generation EOSE anchor first, so the comparison
        // below measures what subscribing B did and not an advance already in
        // flight when the session started.
        let a_cursor_before = settle_eose_anchor(&core, &a).await;
        assert!(
            a_cursor_before.is_some(),
            "precondition: A's start generation must have anchored, else the \
             equality below would hold vacuously"
        );
        core.subscribe_circle(&CircleSpec {
            group_id_hex: b.clone(),
            relays: vec![url],
        })
        .await
        .expect("subscribe B");
        let a_cursor_after = core
            .circle
            .read_sync_cursor(&group_cursor_stream(&a))
            .unwrap();
        assert_eq!(
            a_cursor_before, a_cursor_after,
            "subscribing B must not touch A's cursor"
        );
        assert!(
            core.circle
                .read_sync_cursor(&group_cursor_stream(&b))
                .unwrap()
                .is_some(),
            "B's OWN cursor is seeded"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn unsubscribe_circle_of_a_singleton_closes_only_that_sub() {
        let a = "aa".repeat(32);
        let b = "bb".repeat(32);
        let (core, _relay, _dir, url) = started_core_with(&[&a]).await;
        core.subscribe_circle(&CircleSpec {
            group_id_hex: b.clone(),
            relays: vec![url],
        })
        .await
        .unwrap();
        assert_eq!(core.live_group_subs_for_test().await.len(), 2);

        core.unsubscribe_circle(&b).await.expect("unsubscribe B");
        let subs = core.live_group_subs_for_test().await;
        assert_eq!(subs.len(), 1, "only B's singleton removed");
        assert_eq!(subs[0].2, vec![a], "A untouched");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn unsubscribe_circle_of_a_multiplexed_member_re_issues_remaining() {
        // A and B share the SAME relay set → one multiplexed bucket at start.
        let a = "aa".repeat(32);
        let b = "bb".repeat(32);
        let (core, _relay, _dir, _url) = started_core_with(&[&a, &b]).await;

        let before = core.live_group_subs_for_test().await;
        assert_eq!(before.len(), 1, "A and B collapse to one bucket");
        assert_eq!(before[0].2, vec![a.clone(), b.clone()]);
        let bucket_sub_id = before[0].0.clone();

        core.unsubscribe_circle(&a)
            .await
            .expect("remove A from the bucket");
        let after = core.live_group_subs_for_test().await;
        assert_eq!(
            after.len(),
            1,
            "the bucket persists for the remaining circle"
        );
        assert_eq!(
            after[0].2,
            vec![b],
            "A's #h dropped from the wire, B remains"
        );
        assert_eq!(
            after[0].0, bucket_sub_id,
            "same sub_id (NIP-01 replace, not a new REQ)"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn unsubscribe_circle_of_the_last_bucket_member_closes_the_sub() {
        let a = "aa".repeat(32);
        let b = "bb".repeat(32);
        let (core, _relay, _dir, _url) = started_core_with(&[&a, &b]).await;
        core.unsubscribe_circle(&a).await.expect("remove A");
        core.unsubscribe_circle(&b)
            .await
            .expect("remove B (last member)");
        assert!(
            core.live_group_subs_for_test().await.is_empty(),
            "the bucket is CLOSEd once its last member leaves"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn unsubscribe_circle_of_an_unknown_circle_is_ok_noop() {
        let a = "aa".repeat(32);
        let (core, _relay, _dir, _url) = started_core_with(&[&a]).await;
        core.unsubscribe_circle(&"ff".repeat(32))
            .await
            .expect("unknown circle is a no-op");
        assert_eq!(core.live_group_subs_for_test().await.len(), 1, "unchanged");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn subscribe_circle_rejects_plaintext_ws() {
        // The WSS gate must fail the WHOLE op closed BEFORE any add_relay; a
        // non-loopback ws:// is rejected regardless of the loopback opt-in.
        let a = "aa".repeat(32);
        let (core, _relay, _dir, _url) = started_core_with(&[&a]).await;
        let result = core
            .subscribe_circle(&CircleSpec {
                group_id_hex: "bb".repeat(32),
                relays: vec!["ws://malicious.example".to_string()],
            })
            .await;
        assert!(result.is_err(), "plaintext ws:// must be rejected");
        assert_eq!(
            core.live_group_subs_for_test().await.len(),
            1,
            "the rejected circle was not added"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn subscribe_circle_on_a_stopped_core_fails_closed_no_session() {
        let (core, _dir) = build_core();
        assert_eq!(core.stop().await, StopOutcome::NotStarted); // shutdown flag set
        let result = core
            .subscribe_circle(&CircleSpec {
                group_id_hex: "aa".repeat(32),
                relays: vec!["wss://relay.example".to_string()],
            })
            .await;
        assert!(
            matches!(result, Err(LiveSyncError::NoSession)),
            "a stopped core's subscribe must fail closed as NoSession: {result:?}"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn subscribe_circle_on_a_never_started_core_fails_closed_no_session() {
        // No active session (never started) ⇒ fail closed so the caller falls back
        // to a full start (correction #5).
        let (core, _dir) = build_core();
        let result = core
            .subscribe_circle(&CircleSpec {
                group_id_hex: "aa".repeat(32),
                relays: vec!["wss://relay.example".to_string()],
            })
            .await;
        assert!(matches!(result, Err(LiveSyncError::NoSession)));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn unsubscribe_circle_on_a_stopped_core_is_ok_noop() {
        // A stopped / no-active session has nothing to unsubscribe ⇒ Ok no-op
        // (correction #5), never an error and never a full-restart trigger.
        let (core, _dir) = build_core();
        assert_eq!(core.stop().await, StopOutcome::NotStarted);
        core.unsubscribe_circle(&"aa".repeat(32))
            .await
            .expect("unsubscribe on a stopped core is an Ok no-op");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_stop_during_subscribe_circle_never_yields_no_relays() {
        // Mirrors `concurrent_stop_during_start_never_yields_no_relays`: a `stop`
        // racing an in-flight `subscribe_circle` on the SAME core must never empty
        // the pool between its add_relay and its subscribe. The lifecycle lock
        // serializes them, so subscribe either completes (Ok, pool intact) or —
        // if stop won the lock first — fails closed as NoSession. Never "no relays".
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let a = "aa".repeat(32);
        let b = "bb".repeat(32);
        for _ in 0..8 {
            let (core, _dir) = build_core();
            let core = Arc::new(core);
            core.start(
                &[CircleSpec {
                    group_id_hex: a.clone(),
                    relays: vec![url.clone()],
                }],
                &[],
            )
            .await
            .expect("start");

            let sub_core = Arc::clone(&core);
            let (b2, url2) = (b.clone(), url.clone());
            let sub = tokio::spawn(async move {
                sub_core
                    .subscribe_circle(&CircleSpec {
                        group_id_hex: b2,
                        relays: vec![url2],
                    })
                    .await
            });
            // Racy by design, exactly as in
            // `concurrent_stop_during_start_never_yields_no_relays`.
            let _ = core.stop().await;
            let res = tokio::time::timeout(Duration::from_secs(10), sub)
                .await
                .expect("subscribe must not hang")
                .expect("subscribe task must not panic");
            match res {
                // Subscribe won the lock, or stop won it and subscribe failed
                // closed. Anything else — notably "no relays" — is the bug.
                Ok(()) | Err(LiveSyncError::NoSession) => {}
                Err(other) => panic!(
                    "concurrent stop must never surface as a pool 'no relays' error: {other:?}"
                ),
            }
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn subscribe_circle_delivers_new_and_leaves_existing_live() {
        // Lossless-across-an-add: after subscribing B, BOTH the existing circle A
        // and the new circle B reach the processor — proving B is live AND A was
        // not torn down (no receive gap). A publisher independent of the engine
        // sends one kind:445 per circle.
        //
        // RE-EXPRESSED (twice). The pre-Dark-Matter version keyed on
        // `Status { Unprocessable }` from an MDK error path the engine no longer
        // takes (it reports an undecryptable 445 as `Ok(Stale)`), so it moved to
        // "the per-circle cursor advanced". That oracle is now gone too, and for
        // a reason worth stating: a delivered event no longer advances any
        // cursor, because its `created_at` is remotely chosen (see
        // `live_sync::anchor`). Cursor motion in this plane means "a relay sent
        // EOSE", which happens whether or not either circle's event was routed —
        // it would have made this test pass vacuously.
        //
        // So delivery is proven by the ONE side effect that is per-event and
        // engine-independent: the `#[cfg(test)]` panic seam inside
        // `process_group_event`, which the worker isolates and reports as
        // `Status { Unprocessable }`. Reaching it requires the worker to have
        // routed the event to that exact `#h`. The two circles are published
        // SEQUENTIALLY, each awaited, so a missing delivery for A times out on
        // its own await instead of being masked by B's.
        // (Scary panic messages on stderr are expected.)
        use nostr::{Alphabet, EventBuilder, Kind, SingleLetterTag, Tag, TagKind};

        let a = "aa".repeat(32);
        let b = "bb".repeat(32);
        let (core, _relay, _dir, url) = started_core_with(&[&a]).await;
        let mut bus = core.bus().subscribe();

        core.subscribe_circle(&CircleSpec {
            group_id_hex: b.clone(),
            relays: vec![url.clone()],
        })
        .await
        .expect("subscribe B live");

        let publisher = Client::builder().build();
        let _ = publisher.add_relay(url.as_str()).await;
        publisher.connect().await;
        publisher.wait_for_connection(Duration::from_secs(5)).await;
        let event_445 = |h: &str| {
            EventBuilder::new(Kind::Custom(445), "__panic_for_test__")
                .tags(vec![Tag::custom(
                    TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
                    [h.to_string()],
                )])
                .sign_with_keys(&Keys::generate())
                .unwrap()
        };

        publisher
            .send_event_to([url.as_str()], &event_445(&a))
            .await
            .expect("publish for A");
        assert!(
            await_routed(&mut bus).await,
            "the existing circle A must keep delivering to the processor after \
             B is added (no receive gap from the delta subscribe)"
        );

        publisher
            .send_event_to([url.as_str()], &event_445(&b))
            .await
            .expect("publish for B");
        assert!(
            await_routed(&mut bus).await,
            "the newly-added circle B must deliver live"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn resume_re_anchors_current_set_including_a_dynamic_add() {
        let a = "aa".repeat(32);
        let b = "bb".repeat(32);
        let (core, _relay, _dir, url) = started_core_with(&[&a]).await;
        core.subscribe_circle(&CircleSpec {
            group_id_hex: b,
            relays: vec![url],
        })
        .await
        .unwrap();
        let before = core.live_group_subs_for_test().await;
        assert_eq!(before.len(), 2);

        core.resume_after_background().await.expect("resume");

        let after = core.live_group_subs_for_test().await;
        assert_eq!(
            after.len(),
            2,
            "resume re-anchors both A and the dynamically-added B"
        );
        let ids_before: HashSet<String> = before.iter().map(|e| e.0.clone()).collect();
        let ids_after: HashSet<String> = after.iter().map(|e| e.0.clone()).collect();
        assert_eq!(
            ids_before, ids_after,
            "resume reuses the STORED sub-ids (no re-bucketing, no orphan)"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn unsubscribe_circle_is_receive_plane_only() {
        // Invariant 5 (RE-EXPRESSED): unsubscribe is strictly receive-plane — it
        // drops the circle's REQ from the live subscription model without tearing
        // down the session. The deleted converge-counter / settle-buffer halves of
        // the original assertion go with the engine-owned convergence (plan §5.4);
        // the surviving invariant is that the group sub is removed and the session
        // stays live.
        let a = "aa".repeat(32);
        let b = "bb".repeat(32);
        let (core, _relay, _dir, _url) = started_core_with(&[&a, &b]).await;

        core.unsubscribe_circle(&a).await.expect("unsubscribe A");

        let remaining: Vec<String> = core
            .live_group_subs_for_test()
            .await
            .into_iter()
            .flat_map(|(_, _, hexes)| hexes)
            .collect();
        assert!(
            !remaining.contains(&a),
            "unsubscribe must drop circle A's REQ"
        );
        assert!(
            remaining.contains(&b),
            "unsubscribe must leave the co-multiplexed circle B (session stays live)"
        );
    }

    #[test]
    fn remove_reissue_since_is_min_remaining_with_resubscribe_buffer_lossless() {
        // The multiplexed-member remove re-issues at MIN(remaining) with the wider
        // Resubscribe buffer — never a fresh `now`. MIN(remaining) >= MIN(all), so
        // the floor only NARROWS, never skipping a remaining circle's un-applied
        // event (the losslessness regression both reviewers required).
        let (core, _dir) = build_core();
        let now = 10_000_000_i64;
        let b = "bb".repeat(32);
        let c = "cc".repeat(32);
        core.circle
            .seed_sync_cursor_if_unset(&group_cursor_stream(&b), 1_000_000)
            .unwrap();
        core.circle
            .seed_sync_cursor_if_unset(&group_cursor_stream(&c), 5_000_000)
            .unwrap();
        let since = core.remove_reissue_since(&[b, c], now);
        // MIN(B = 1000s, C = 5000s) minus the 60s Resubscribe buffer.
        assert_eq!(
            since,
            1000 - crate::relay::cursor::GROUP_RESUBSCRIBE_BUFFER_SECS,
            "since = MIN(remaining) - Resubscribe buffer (lossless narrow)"
        );
        assert_ne!(since, now, "must never regress to a fresh now");
    }

    #[tokio::test]
    async fn subscribe_circle_is_a_no_op_for_a_circle_with_no_usable_relays() {
        // Mirrors the skip `build_relay_set_subscriptions` performs at start:
        // a circle whose relay set normalizes to nothing has nowhere to send a
        // REQ. It must be a benign no-op, NOT an error the caller would escalate
        // into a full engine restart, and — the part that matters — it must
        // register NO router state, or every later `kind:445` would be routed to
        // a subscription that was never issued.
        let (core, _dir) = build_core();

        let res = core
            .subscribe_circle(&CircleSpec {
                group_id_hex: "ab".repeat(32),
                // Blank entries are exactly what `canonical_relay_set` drops,
                // so the normalized set is empty — the state a circle stored
                // with no routing relays presents.
                relays: vec![String::new(), "   ".to_string()],
            })
            .await;

        assert!(
            res.is_ok(),
            "an unusable relay set is a no-op, not a failure: {res:?}"
        );
        assert!(
            core.live_group_subs_for_test().await.is_empty(),
            "nothing may be recorded as live — a subscription the engine never \
             issued would silently swallow that circle's events"
        );
    }

    #[tokio::test]
    async fn subscribe_circle_fails_closed_once_the_session_is_shut_down() {
        // Rule 14 adjacent: after `stop` the engine no longer owns its handles.
        // Accepting a subscribe here would register router state and issue a REQ
        // against a client that is being torn down, leaving an entry nothing
        // ever clears. The caller is expected to rebuild a fresh core, so this
        // must be an error rather than a silent success.
        let (core, _dir) = build_core();
        core.shutdown_for_test().store(true, Ordering::Release);

        let res = core
            .subscribe_circle(&CircleSpec {
                group_id_hex: "cd".repeat(32),
                relays: vec!["wss://relay.example.com".to_string()],
            })
            .await;

        assert!(
            matches!(res, Err(LiveSyncError::NoSession)),
            "a shut-down session must refuse a delta subscribe: {res:?}"
        );
        assert!(
            core.live_group_subs_for_test().await.is_empty(),
            "and must leave no live-subscription bookkeeping behind"
        );
    }

    #[tokio::test]
    async fn resume_after_background_fails_closed_once_shut_down() {
        // The resume path re-issues every REQ under the FROZEN sub-ids. Doing
        // that against a stopped engine would re-open sockets the stop just
        // closed; the caller must see `NoSession` and start a fresh core.
        let (core, _dir) = build_core();
        core.shutdown_for_test().store(true, Ordering::Release);

        let res = core.resume_after_background().await;

        assert!(
            matches!(res, Err(LiveSyncError::NoSession)),
            "a shut-down session must refuse to re-anchor: {res:?}"
        );
    }

    #[tokio::test]
    async fn circle_accessor_hands_back_the_one_shared_manager() {
        // Rule 14: the engine processor must mutate the SAME `CircleManager`
        // the rest of the process holds — a second manager over one database is
        // two hydrated epoch states. The accessor is how that sharing is
        // observable, so pin that it hands back the very Arc it was built with
        // rather than a clone of the underlying manager.
        let dir = TempDir::new().unwrap();
        let keys = Keys::generate();
        let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
        let core = LiveSyncCore::new_local(Arc::clone(&circle), keys.public_key());

        assert!(
            Arc::ptr_eq(core.circle(), &circle),
            "the engine must share the caller's manager, not its own"
        );
    }

    // ======================= P4: the background burst =======================
    //
    // The pure half lives here (virtual clock, private seams); the relay-backed
    // attacks live in `tests/live_sync_burst_e2e.rs`.

    /// A quiet burst pays ZERO settle time.
    ///
    /// The common case by far: a burst that received no commit and published no
    /// auto-commit has nothing to quiesce, so holding the radio open for the
    /// settle window would be ~8 s of pure cost on every publish tick. The
    /// `start_paused` clock makes "zero" observable as an exact reading rather
    /// than "fast enough".
    #[tokio::test(start_paused = true)]
    async fn settle_before_pause_with_returns_at_once_on_a_quiet_burst() {
        let (core, _dir) = build_core();
        let started = tokio::time::Instant::now();
        core.settle_before_pause_with(Duration::from_secs(8), Duration::from_secs(18))
            .await;
        assert_eq!(
            tokio::time::Instant::now() - started,
            Duration::ZERO,
            "a burst that saw no commit activity must not hold the sockets open at all"
        );
    }

    /// Each new commit gets its OWN full window — the settle measures from the
    /// LAST commit activity, not from the first.
    ///
    /// A commit at t = 6 arrives while the t = 0 commit's window is still open;
    /// the sockets must therefore stay up until t = 14, so the convergence
    /// traffic that commit provokes lands on an open socket instead of on the
    /// next burst. 14 is STRICTLY below the 18 s cap, which is what proves the
    /// window — not the cap — is what ended this settle.
    #[tokio::test(start_paused = true)]
    async fn settle_before_pause_with_extends_the_window_from_each_new_commit() {
        let (core, _dir) = build_core();
        let processor = Arc::clone(&core.processor);
        // A second commit arrives 6 s in — inside the first commit's window.
        let follow_on = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(6)).await;
            processor.note_commit_activity_for_test();
        });

        let started = tokio::time::Instant::now();
        // The commit this burst is settling for.
        core.processor.note_commit_activity_for_test();
        core.settle_before_pause_with(Duration::from_secs(8), Duration::from_secs(18))
            .await;
        let elapsed = tokio::time::Instant::now() - started;
        follow_on.await.expect("the follow-on task must not panic");

        assert_eq!(
            elapsed,
            Duration::from_secs(14),
            "the settle must run a full window from the LAST commit (6 + 8 = 14), not \
             close at the first commit's own deadline (t = 8)"
        );
        assert!(
            elapsed < Duration::from_secs(18),
            "and it must be the WINDOW that ended it, not the cap — otherwise this test \
             would pass for a settle that ignored the second commit entirely"
        );
    }

    /// Follow-on commit activity cannot hold the radio open forever.
    ///
    /// A group that keeps committing would otherwise re-arm the window on every
    /// pass. The cap is what bounds the burst's worst case, and it is measured
    /// from the settle's start — so this returns at exactly the cap, however
    /// long the traffic continues.
    #[tokio::test(start_paused = true)]
    async fn settle_before_pause_with_caps_follow_on_activity_at_eighteen_seconds() {
        let (core, _dir) = build_core();
        let processor = Arc::clone(&core.processor);
        let chatty = tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(2)).await;
                processor.note_commit_activity_for_test();
            }
        });

        let started = tokio::time::Instant::now();
        // The commit this burst is settling for; the task above then re-arms the
        // window every 2 s, forever.
        core.processor.note_commit_activity_for_test();
        core.settle_before_pause_with(
            Duration::from_secs(COMMIT_SETTLE_WINDOW_SECS),
            Duration::from_secs(BURST_SETTLE_CAP_SECS),
        )
        .await;
        let elapsed = tokio::time::Instant::now() - started;
        chatty.abort();

        assert_eq!(
            elapsed,
            Duration::from_secs(BURST_SETTLE_CAP_SECS),
            "unending commit activity must be cut at the cap, never allowed to hold \
             the sockets open indefinitely"
        );
    }

    /// Rule 13: the settle's FIRST stage has no cap at all.
    ///
    /// A commit between SEND and OK may never be cut. This holds the real
    /// production gauge (the same drop guard `resolve_publish_work` uses) and
    /// drives the settle with a window AND a cap of one second: if either bound
    /// applied to the gauge wait, the call would return. It must not — and then
    /// must return the instant the gauge drops, which is what proves the test is
    /// observing the gauge rather than a hang.
    #[tokio::test(start_paused = true)]
    async fn settle_before_pause_never_caps_the_in_flight_publish_wait() {
        let (core, _dir) = build_core();
        let gauge = core.processor.hold_publish_for_test();

        let settle = std::pin::pin!(
            core.settle_before_pause_with(Duration::from_secs(1), Duration::from_secs(1),)
        );
        // Far past both bounds on the virtual clock: a capped wait would be long
        // finished. `timeout` returning Err IS the assertion.
        assert!(
            tokio::time::timeout(Duration::from_secs(600), settle)
                .await
                .is_err(),
            "the in-flight publish wait must be UNCAPPED (Rule 13): cutting the socket \
             here makes wait_for_ok return Err, rolls the commit back to the prior epoch, \
             and the relay may already have served it — a roster fork"
        );

        drop(gauge);
        assert!(
            tokio::time::timeout(
                Duration::from_secs(5),
                core.settle_before_pause_with(Duration::from_secs(1), Duration::from_secs(1)),
            )
            .await
            .is_ok(),
            "once the publish resolves the settle must proceed — otherwise the test above \
             would pass for a settle that simply hangs"
        );
    }

    /// A relay that never `EOSE`s costs one bounded wait, reported honestly.
    ///
    /// Pure: an endpoint nobody ever settles cannot become settled by chance, so
    /// the outcome is deterministic whatever the budget. The virtual clock makes
    /// the budget free.
    #[tokio::test(start_paused = true)]
    async fn wait_backlog_settled_times_out_without_a_relay_eose_and_reports_it() {
        let (core, _dir) = build_core();
        let silent = RepairKey {
            relay_url: accepting_relay(),
            sub_id: SubscriptionId::new("s_group_0"),
        };
        assert_eq!(
            core.processor
                .wait_backlog_settled(
                    std::slice::from_ref(&silent),
                    Duration::from_secs(BURST_BACKLOG_WAIT_SECS)
                )
                .await,
            BacklogOutcome::TimedOut,
            "an endpoint that never answers must be reported, not waited on forever"
        );
    }

    /// The positive control for the wait, and the per-ENDPOINT rule.
    ///
    /// Two relays share ONE subscription id (a multiplexed bucket). The FIRST
    /// relay's `EOSE` consumes the circle's single anchor generation, so a
    /// per-circle wait would call the burst settled while the SECOND relay —
    /// possibly the only one holding a peer's commit — is still replaying. The
    /// wait must not return until BOTH endpoints have answered.
    #[tokio::test(start_paused = true)]
    async fn wait_backlog_settled_waits_for_every_endpoint_not_just_the_first() {
        let (core, _dir) = build_core();
        let sub_id = SubscriptionId::new("s_group_0");
        let fast = RepairKey {
            relay_url: RelayUrl::parse("wss://fast.example").expect("relay url"),
            sub_id: sub_id.clone(),
        };
        let slow = RepairKey {
            relay_url: RelayUrl::parse("wss://slow.example").expect("relay url"),
            sub_id,
        };
        let expected = vec![fast.clone(), slow.clone()];

        core.processor.note_endpoint_settled(&fast);
        assert_eq!(
            core.processor
                .wait_backlog_settled(&expected, Duration::from_secs(BURST_BACKLOG_WAIT_SECS))
                .await,
            BacklogOutcome::TimedOut,
            "the FAST relay's EOSE must not settle the burst: it consumes the circle's \
             single generation while the slow relay is still replaying the commit"
        );

        core.processor.note_endpoint_settled(&slow);
        assert_eq!(
            core.processor
                .wait_backlog_settled(&expected, Duration::from_secs(BURST_BACKLOG_WAIT_SECS))
                .await,
            BacklogOutcome::Settled,
            "with every endpoint answered the burst is settled"
        );
    }

    /// A burst that opened NO endpoint settles immediately.
    ///
    /// The empty-set case is what makes the non-fold burst (and a burst whose
    /// every relay refused the REQ) free rather than a guaranteed 5 s stall.
    #[tokio::test(start_paused = true)]
    async fn wait_backlog_settled_on_an_empty_endpoint_set_is_immediate() {
        let (core, _dir) = build_core();
        let started = tokio::time::Instant::now();
        assert_eq!(
            core.processor
                .wait_backlog_settled(&[], Duration::from_secs(BURST_BACKLOG_WAIT_SECS))
                .await,
            BacklogOutcome::Settled
        );
        assert_eq!(tokio::time::Instant::now() - started, Duration::ZERO);
    }

    /// Re-issuing a REQ clears that endpoint's previous answer.
    ///
    /// Every burst re-issues the SAME `(relay, sub_id)` pair, so without the
    /// clear the second burst would read the first burst's `EOSE` as its own and
    /// settle before the relay had replayed anything — publishing at a stale
    /// epoch on every burst but the first.
    #[tokio::test(start_paused = true)]
    async fn re_opening_an_endpoint_clears_the_previous_bursts_answer() {
        let (core, _dir) = build_core();
        let key = RepairKey {
            relay_url: accepting_relay(),
            sub_id: SubscriptionId::new("s_group_0"),
        };
        core.processor.note_endpoint_settled(&key);
        assert_eq!(
            core.processor
                .wait_backlog_settled(std::slice::from_ref(&key), Duration::from_secs(1))
                .await,
            BacklogOutcome::Settled,
        );

        core.processor.open_delivery_window(&key, 1_000);
        assert_eq!(
            core.processor
                .wait_backlog_settled(std::slice::from_ref(&key), Duration::from_secs(1))
                .await,
            BacklogOutcome::TimedOut,
            "a re-issued REQ must wait for its OWN EOSE, never inherit the previous \
             generation's"
        );
    }

    // ---- burst tests that need the private client / the injected fold period ----

    /// A recording `QueryPolicy`: keeps every REQ filter a relay was asked to
    /// serve, in arrival order, so a test can assert what the relay ACTUALLY saw
    /// rather than what the session believes it sent.
    #[derive(Debug, Default)]
    struct RecordingQueries {
        seen: Arc<StdMutex<Vec<Filter>>>,
    }

    impl RecordingQueries {
        fn handle(&self) -> Arc<StdMutex<Vec<Filter>>> {
            Arc::clone(&self.seen)
        }
    }

    impl nostr_relay_builder::builder::QueryPolicy for RecordingQueries {
        fn admit_query<'a>(
            &'a self,
            query: &'a Filter,
            _addr: &'a std::net::SocketAddr,
        ) -> nostr::util::BoxedFuture<'a, nostr_relay_builder::builder::PolicyResult> {
            Box::pin(async move {
                self.seen
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .push(query.clone());
                nostr_relay_builder::builder::PolicyResult::Accept
            })
        }
    }

    /// Runs an in-process relay that records every REQ filter it is asked to
    /// serve, and returns `(relay, url, recorded)`.
    async fn recording_relay() -> (
        nostr_relay_builder::LocalRelay,
        String,
        Arc<StdMutex<Vec<Filter>>>,
    ) {
        let policy = RecordingQueries::default();
        let recorded = policy.handle();
        let relay = nostr_relay_builder::LocalRelay::new(
            nostr_relay_builder::RelayBuilder::default().query_policy(policy),
        );
        relay.run().await.expect("local relay runs");
        let url = relay.url().await.to_string();
        (relay, url, recorded)
    }

    /// REQ filters the relay admitted that carry `#p` — i.e. inbox REQs.
    fn inbox_req_count(recorded: &Arc<StdMutex<Vec<Filter>>>) -> usize {
        recorded
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .filter(|f| {
                f.generic_tags
                    .contains_key(&SingleLetterTag::lowercase(Alphabet::P))
            })
            .count()
    }

    /// The inbox REQ rides every k-th burst, and no other.
    ///
    /// An inbox-only relay carries none of this device's circles, so it sees no
    /// `kind:445` — a `#p` REQ on every burst would be a bare "this pubkey is
    /// background-sharing right now" cadence for that relay class alone. The fold
    /// is the lever that removes it, so the arithmetic has to hold against a real
    /// relay's own record of what it was asked, not against the session's
    /// intention.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_burst_reissues_the_inbox_req_every_kth_burst() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let (_relay, url, recorded) = recording_relay().await;
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "ab".repeat(32),
                relays: vec![url.clone()],
            }],
            std::slice::from_ref(&url),
        )
        .await
        .expect("the engine starts against the recording relay");
        // The settle is the barrier, not a sleep: `Settled` means every endpoint
        // this open issued has EOSE'd, i.e. the relay has provably served both
        // REQs and recorded them.
        assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);

        let after_start = inbox_req_count(&recorded);
        assert_eq!(after_start, 1, "start issues exactly one inbox REQ");

        // Bursts consume sequence 0, 1, 2, 3. At k = 3 only 0 and 3 fold the
        // inbox in — `ceil(4 / 3) = 2`.
        for _ in 0..4 {
            core.pause_subscriptions().await.expect("pause");
            core.resume_burst_for_test(BurstKind::Background, 3)
                .await
                .expect("burst opens");
            assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
        }

        assert_eq!(
            inbox_req_count(&recorded) - after_start,
            4_usize.div_ceil(3),
            "with k = 3 only bursts at sequence 0 and 3 may issue a `#p` REQ. Every \
             burst issuing one is the cadence signal — \"this pubkey is \
             background-sharing right now\" — that an inbox-only relay, which carries \
             none of this device's circles, would otherwise read off the wire"
        );

        let _ = core.stop().await;
    }

    /// A socket that re-opens while the radio is off is CUT, COUNTED, and never
    /// reported as connectivity.
    ///
    /// This is P4's central promise — no standing subscription and no socket
    /// between publish ticks — and the invariant
    /// `INV-R-BACKGROUND-PRESENCE-ONLY-AT-PUBLISH` — under the one thing that
    /// can falsify it: `nostr-relay-pool`'s per-relay connection task surviving
    /// the pause's `disconnect()` and re-opening a real socket on its own retry
    /// schedule (see [`LiveSyncCore::terminate_all_relays`] for the mechanism).
    ///
    /// The re-open is INJECTED with `Relay::connect()` rather than raced for,
    /// and that is deliberate. The crate-level race needs the notifying thread
    /// to be preempted between two adjacent statements: it was measured at
    /// 48/150 disconnects on a machine oversubscribed 2x and at 0/150 on an idle
    /// one, so a test that waited for it would assert nothing at all on an idle
    /// runner and would be exactly as unreliable as the bug. `connect()` puts
    /// the pool in the identical STATE — a live socket the engine did not ask
    /// for while paused — which is the state the promise is about.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_socket_re_opened_while_the_radio_is_off_is_cut_and_counted() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "7e".repeat(32),
                relays: vec![url.clone()],
            }],
            std::slice::from_ref(&url),
        )
        .await
        .expect("the engine starts");
        assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);

        core.pause_subscriptions().await.expect("pause");
        assert!(
            core.client
                .relays()
                .await
                .values()
                .all(|r| r.status() == RelayStatus::Terminated),
            "the pause terminates every relay before anything is injected"
        );
        assert_eq!(
            core.unrequested_connections(),
            0,
            "nothing has re-opened a socket yet"
        );

        // Inject the strand: a socket the engine did not ask for, open while the
        // radio is off.
        //
        // Through a REBUILT relay object, not `connect()` on the terminated one.
        // `Relay::connect` sets `Pending` and then declines to spawn while the
        // previous connection task is still marked running, and `Pending` is not
        // in `can_connect()`, so the relay is stuck there and no retry rescues it
        // — the trap [`LiveSyncCore::rebuild_stalled_relays`] documents. How long
        // the old task takes to exit is a scheduling question, so an injection
        // that ignored this would inject nothing at all on a busy machine and the
        // test would pass by asserting against a pool that never came up.
        let urls: Vec<String> = core
            .client
            .relays()
            .await
            .keys()
            .map(ToString::to_string)
            .collect();
        for url in &urls {
            let _ = core.client.force_remove_relay(url.as_str()).await;
            let _ = core.client.add_relay(url.as_str()).await;
        }
        core.client.connect().await;

        assert!(
            poll_until(|| core.unrequested_connections() > 0).await,
            "a relay that comes up while the radio is off must be recognised as a socket this \
             session never asked for. Unrecognised, it holds a real TCP connection (and a 55 \
             s ping) for the whole gap between publish ticks, and the next burst adopts it \
             silently — `rebuild_stalled_relays` skips `Connected` by design"
        );
        assert!(
            poll_until_async(|| async {
                core.client
                    .relays()
                    .await
                    .values()
                    .all(|r| matches!(r.status(), RelayStatus::Terminated | RelayStatus::Banned))
            })
            .await,
            "and it must be cut back to a terminal status, not merely counted"
        );
        assert_eq!(
            core.relay_health().await.connected,
            0,
            "no socket may survive the cut"
        );

        let _ = core.stop().await;
    }

    /// Drives [`run_monitor`] over a hand-made notification stream, against a
    /// pool holding one really-connected relay.
    ///
    /// Returns `(bus statuses emitted, unrequested-connection count, whether the
    /// relay is still up)`. The monitor is cancelled and joined, so every
    /// notification it was given has provably been processed before any of the
    /// three is read — no drain that races the emit it is looking for.
    async fn monitor_verdict(
        radio_off: bool,
        cut_pool_first: bool,
        statuses: &[RelayStatus],
    ) -> (Vec<SyncStatusReason>, usize, bool) {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let client = build_engine_client();
        client.add_relay(url.as_str()).await.expect("add relay");
        client.connect().await;
        client.wait_for_connection(SUBSCRIBE_CONNECT_WAIT).await;
        let relay_url = RelayUrl::parse(&url).expect("the relay url parses");
        let watch = RadioOffWatch {
            radio_off: Arc::new(AtomicBool::new(radio_off)),
            client: client.clone(),
            cut: Arc::new(AtomicUsize::new(0)),
        };
        assert!(
            watch.is_up(&relay_url).await,
            "the fixture relay must really be up, or the verdict is about nothing"
        );
        let cut = Arc::clone(&watch.cut);
        if cut_pool_first {
            // The pool moves past the transitions below BEFORE the monitor sees
            // them, which is what makes them stale.
            client.disconnect().await;
        }

        let (notify_tx, notify_rx) = broadcast::channel(16);
        let (cancel_tx, cancel_rx) = watch::channel(false);
        let bus = EventBus::new();
        let mut events = bus.subscribe();
        for status in statuses {
            notify_tx
                .send(MonitorNotification::StatusChanged {
                    relay_url: relay_url.clone(),
                    status: *status,
                })
                .expect("the monitor task holds the receiver");
        }
        let task = tokio::spawn(run_monitor(
            notify_rx,
            bus,
            Arc::new(AtomicBool::new(true)),
            watch,
            cancel_rx,
        ));
        // Cancellation is `biased` in the monitor's `select!`, so it is only
        // taken once the notification arm has nothing left to hand over.
        while !notify_tx.is_empty() {
            tokio::task::yield_now().await;
        }
        cancel_tx.send(true).expect("the monitor task holds it");
        task.await.expect("the monitor task exits on cancel");

        let mut reported = Vec::new();
        while let Ok(event) = events.try_recv() {
            if let LiveSyncEvent::Status { reason } = event {
                reported.push(reason);
            }
        }
        let still_up = client
            .relay(relay_url)
            .await
            .is_ok_and(|r| matches!(r.status(), RelayStatus::Connected | RelayStatus::Connecting));
        (reported, cut.load(Ordering::Acquire), still_up)
    }

    /// A relay that is really up while the radio is off is CUT and COUNTED, and
    /// never reported as connectivity.
    ///
    /// The reporting half is not cosmetic. `SharingHealthProvider` clears its
    /// "disconnected since" stamp on `connecting` and on `connected` alike, so
    /// forwarding either would let a socket the engine did not open — the very
    /// falsification of P4 — read to the user as evidence of health, and erase
    /// the start time of a real outage it happened to span. Suppressing it
    /// silently would be the other half-measure: the count is what makes an
    /// unrequested socket visible instead of merely inaudible.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_relay_up_while_the_radio_is_off_is_cut_not_reported() {
        let (reported, cut, still_up) =
            monitor_verdict(true, false, &[RelayStatus::Connected]).await;
        assert!(
            reported.is_empty(),
            "no connectivity status may be published for a socket the session never \
             asked for. Saw {reported:?}"
        );
        assert_eq!(cut, 1, "and the socket must be counted");
        assert!(!still_up, "and actually cut, not merely counted");
    }

    /// A status transition the pool has already moved past is neither counted
    /// nor reported.
    ///
    /// The queue between the pool and this task is not instantaneous, so a
    /// burst's own `Connected` can still be in it when the burst fails and cuts
    /// the radio behind it. Counting that would make
    /// [`LiveSyncCore::unrequested_connections`] — whose whole claim is "a socket
    /// was up while the radio was off" — read positive on a pool that is
    /// provably quiet, which is worse than not counting at all: it is a
    /// diagnostic that cries wolf on the engine's own correct behaviour.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_stale_connected_transition_is_neither_counted_nor_reported() {
        let (reported, cut, still_up) =
            monitor_verdict(true, true, &[RelayStatus::Connected]).await;
        assert!(
            reported.is_empty(),
            "the radio is off, so nothing here is connectivity to report. Saw {reported:?}"
        );
        assert_eq!(
            cut, 0,
            "a transition the pool has already moved past is not a socket that is up"
        );
        assert!(!still_up, "control: the pool really did move past it");
    }

    /// With the radio ON the same transitions are reported unchanged.
    ///
    /// The watch must not cost the foreground its connectivity reporting: a
    /// relay dropping and coming back is exactly what `Reconnecting` /
    /// `Connected` exist to tell the user about.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_relay_coming_up_while_the_radio_is_on_is_reported_normally() {
        let (reported, cut, still_up) = monitor_verdict(
            false,
            false,
            &[RelayStatus::Connecting, RelayStatus::Connected],
        )
        .await;
        assert_eq!(
            reported,
            vec![SyncStatusReason::Connecting, SyncStatusReason::Connected],
            "a first connect is `Connecting`, then `Connected`"
        );
        assert_eq!(cut, 0, "and nothing is cut while the radio is on");
        assert!(still_up, "the socket is left alone");
    }

    /// The pause proves the pool quiet instead of assuming it.
    ///
    /// [`LiveSyncCore::terminate_all_relays`]'s post-condition, asserted at the
    /// only place a caller can see it: when `pause_subscriptions` returns, no
    /// relay in the pool is in a non-terminal status, so none is holding a
    /// connection task that could re-open a socket during the gap. A relay left
    /// at `Disconnected` here is the crate's retry schedule, armed.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn the_pause_leaves_no_relay_in_a_non_terminal_status() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "9c".repeat(32),
                relays: vec![url.clone()],
            }],
            std::slice::from_ref(&url),
        )
        .await
        .expect("the engine starts");
        assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);

        // Every burst of a background session pays this, so assert it over a
        // sequence rather than once: a pause is only as good as the last one.
        for _ in 0..5 {
            core.resume_burst_for_test(BurstKind::Background, 3)
                .await
                .expect("burst opens");
            assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
            assert!(
                core.relay_health().await.connected > 0,
                "the burst must actually hold a socket, or the pause below proves nothing"
            );

            core.pause_subscriptions().await.expect("pause");
            assert_eq!(
                core.unterminated_relay_count().await,
                0,
                "when the pause returns, every relay must be terminated"
            );
            assert_eq!(
                core.unrequested_connections(),
                0,
                "and nothing may have re-opened a socket behind it"
            );
        }

        let _ = core.stop().await;
    }

    /// A burst that issued no inbox REQ does not wait on an inbox endpoint.
    ///
    /// The expectation set is built from the endpoints the burst OPENED, so a
    /// non-fold burst expects none — otherwise every non-fold burst would spend
    /// its entire backlog budget waiting for an `EOSE` from a REQ it never sent,
    /// which is +5 s of held socket on the majority of bursts — worth ≈ +5 J on
    /// the plan's LTE wake model (`docs/POWER_EFFICIENCY_PLAN.md` §2.3:
    /// ESTIMATED arithmetic, never a measurement).
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_non_kth_burst_settles_without_an_inbox_endpoint() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "cd".repeat(32),
                relays: vec![url.clone()],
            }],
            std::slice::from_ref(&url),
        )
        .await
        .expect("the engine starts");
        let inbox_sub_id = core
            .active
            .read()
            .await
            .as_ref()
            .expect("an active session")
            .inbox_sub_id
            .clone();

        // Burst sequence 0 always folds (the first burst after a foreground
        // session is the one most likely to hold an invitation backlog); it is
        // sequence 1 at k = 2 that must not.
        core.pause_subscriptions().await.expect("pause");
        core.resume_burst_for_test(BurstKind::Background, 2)
            .await
            .expect("fold burst opens");
        assert!(
            open_endpoints(&core)
                .await
                .expect("the fold burst opened its window")
                .iter()
                .any(|key| key.sub_id == inbox_sub_id),
            "the fold burst MUST open the inbox endpoint — without this control the \
             assertion below would pass for a session that never opens one at all"
        );

        core.pause_subscriptions().await.expect("pause");
        core.resume_burst_for_test(BurstKind::Background, 2)
            .await
            .expect("non-fold burst opens");
        let expected = open_endpoints(&core)
            .await
            .expect("the non-fold burst opened its window");
        assert!(
            expected.iter().all(|key| key.sub_id != inbox_sub_id),
            "a non-fold burst must open NO inbox endpoint"
        );
        assert!(
            !expected.is_empty(),
            "...but it must still open its group endpoint"
        );
        assert_eq!(
            core.wait_backlog_settled().await,
            BacklogOutcome::Settled,
            "a burst that issued no inbox REQ must settle on its group endpoint alone, \
             never spend its whole budget waiting for an EOSE from a REQ it never sent"
        );

        let _ = core.stop().await;
    }

    /// A relay in the bucket that REFUSES the REQ is not waited on.
    ///
    /// `subscribe_bucket` reports the ACCEPTED relays, and only those become
    /// expected endpoints. A dead relay in a two-relay bucket would otherwise
    /// make every burst — forever — spend its whole backlog budget and report
    /// `TimedOut`.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_dead_relay_in_a_bucket_does_not_time_out_the_burst() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let live = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let dead = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let live_url = live.url().await.to_string();
        let dead_url = dead.url().await.to_string();

        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "ef".repeat(32),
                relays: vec![live_url.clone(), dead_url.clone()],
            }],
            &[],
        )
        .await
        .expect("a two-relay bucket starts");
        assert_eq!(
            open_endpoints(&core)
                .await
                .expect("the start opened its window")
                .len(),
            2,
            "the control: while BOTH relays are operational the burst expects both, so \
             the assertion below is about the refusal and not about the fixture"
        );

        // Make one relay non-operational, exactly as `ensure_operational` sees a
        // relay it must refuse to send on. Its REQ now lands in `Output.failed`.
        core.client
            .relay(dead_url.as_str())
            .await
            .expect("the session registered both relays")
            .ban();

        core.pause_subscriptions().await.expect("pause");
        core.open_background_burst().await.expect("burst opens");

        assert_eq!(
            open_endpoints(&core)
                .await
                .expect("the burst opened its window")
                .len(),
            1,
            "only the relay that ACCEPTED the REQ may be waited on; expecting the \
             refusing one would make every burst — forever — spend its whole backlog \
             budget and report TimedOut"
        );
        assert_eq!(
            core.wait_backlog_settled().await,
            BacklogOutcome::Settled,
            "the burst settles on the accepted endpoint alone"
        );

        let _ = core.stop().await;
    }

    /// A burst open that FAILED never leaves the PREVIOUS burst's settle
    /// standing.
    ///
    /// `register_and_subscribe` short-circuits on the first bucket no relay
    /// accepted, so an open can return `Err` with some of the previous burst's
    /// endpoints never re-issued — and every one of those is still marked
    /// settled from the burst that DID open them. A wait that read that set
    /// would answer `Settled` for a burst that opened nothing: the caller
    /// encrypts believing a peer commit was applied, publishes an epoch behind,
    /// and records no `TimedOut` anywhere.
    ///
    /// The failure is provoked the way the field produces it — a second circle
    /// whose relay stops taking REQs — and the inbox endpoint is the one the
    /// short-circuit never reaches, because the inbox REQ is issued only after
    /// every group bucket. No pause runs here, deliberately: the pause has a
    /// close of its own, and one that ran first would mask whether the OPEN
    /// closes the window.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_failed_burst_open_never_reports_the_previous_bursts_settle() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let refusing = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let refusing_url = refusing.url().await.to_string();

        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "1a".repeat(32),
                relays: vec![url.clone()],
            }],
            std::slice::from_ref(&url),
        )
        .await
        .expect("the engine starts");
        assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
        let previous = open_endpoints(&core)
            .await
            .expect("the start opened its window");
        let inbox_sub_id = core
            .active
            .read()
            .await
            .as_ref()
            .expect("an active session")
            .inbox_sub_id
            .clone();
        assert!(
            previous.iter().any(|key| key.sub_id == inbox_sub_id),
            "precondition: the previous burst opened the inbox endpoint the failing \
             open below never reaches"
        );

        // A second circle on its own relay — subscribed while the relay is still
        // live, so it lands in the session's bucket list AFTER the first.
        core.subscribe_circle(&CircleSpec {
            group_id_hex: "2b".repeat(32),
            relays: vec![refusing_url.clone()],
        })
        .await
        .expect("the second circle subscribes");

        // Now that relay will not send on: its REQ lands in `Output.failed`, so
        // the bucket exhausts its attempts and the whole open fails on the `?`.
        core.client
            .relay(refusing_url.as_str())
            .await
            .expect("the session registered the relay")
            .ban();

        core.open_background_burst()
            .await
            .expect_err("precondition: the second circle's relay refuses, so the open fails");
        assert!(
            open_endpoints(&core).await.is_none(),
            "the mechanism: a failed open leaves NO window, so there is no endpoint set \
             for a wait to read"
        );

        // The control, and the whole reason this test is not vacuous: every
        // endpoint of the PREVIOUS burst is marked settled, so a wait that read
        // that set WOULD answer `Settled` here.
        //
        // Marked explicitly rather than left to the relay. A failing open still
        // ISSUES the buckets ahead of the one that fails, and issuing re-opens
        // their delivery window (an endpoint must never inherit the previous
        // generation's answer), so whether those endpoints are settled again by
        // the time of the assertion depends on an `EOSE` arriving before the
        // failure path cuts the radio — a race, and one this control has no
        // interest in. Asserting the state directly is what makes the control
        // mean what it says.
        for key in &previous {
            core.processor.note_endpoint_settled(key);
        }
        assert_eq!(
            core.processor
                .wait_backlog_settled(&previous, BURST_BACKLOG_WAIT)
                .await,
            BacklogOutcome::Settled,
            "control: the previous burst's endpoints are all still settled"
        );

        assert_eq!(
            core.wait_backlog_settled().await,
            BacklogOutcome::TimedOut,
            "a failed open opened NOTHING, so nothing may vouch for a settle. Answering \
             `Settled` off the previous burst's endpoints tells the caller a peer commit \
             was applied when no REQ was even issued"
        );

        let _ = core.stop().await;
    }

    /// A pause closes the window: the settle it reported belonged to REQs that
    /// no longer exist.
    ///
    /// The other half of "only an open may vouch for a settle". The burst's
    /// endpoints are all genuinely settled here — the pause is what makes the
    /// answer meaningless, because it closed every REQ the set names. A cycle
    /// whose open never ran (it threw before the call, or the caller skipped it)
    /// would otherwise be told the previous burst's backlog was this one's.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_pause_leaves_no_settle_for_the_next_wait_to_inherit() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "3c".repeat(32),
                relays: vec![url.clone()],
            }],
            std::slice::from_ref(&url),
        )
        .await
        .expect("the engine starts");
        assert_eq!(
            core.wait_backlog_settled().await,
            BacklogOutcome::Settled,
            "precondition: every endpoint answered, so the ONLY thing that can change \
             the verdict below is the pause"
        );
        let settled = open_endpoints(&core)
            .await
            .expect("the start opened its window");

        core.pause_subscriptions().await.expect("pause");

        assert_eq!(
            core.processor
                .wait_backlog_settled(&settled, BURST_BACKLOG_WAIT)
                .await,
            BacklogOutcome::Settled,
            "control: the endpoints themselves are still marked settled, so a wait that \
             read that set WOULD answer Settled"
        );
        assert_eq!(
            core.wait_backlog_settled().await,
            BacklogOutcome::TimedOut,
            "no REQ named by that set is live anymore: a wait between a pause and the \
             next open must promise nothing"
        );

        let _ = core.stop().await;
    }

    /// A core that has opened no burst at all never answers `Settled`.
    ///
    /// The reason the failed-open path may not simply CLEAR the endpoint set: an
    /// EMPTY expectation settles immediately by design (a non-fold burst on a
    /// circle-less session opens nothing and must not wait), so "no burst is
    /// open" and "a burst that legitimately opened no endpoint" have to be two
    /// different states, not one empty vector.
    #[tokio::test]
    async fn a_core_that_opened_no_burst_never_reports_a_settle() {
        let (core, _dir) = build_core();
        assert_eq!(
            core.wait_backlog_settled().await,
            BacklogOutcome::TimedOut,
            "a wait on a core that never opened a burst must promise nothing"
        );
    }

    /// The post-condition sweep clears what a partial `unsubscribe_all` leaves
    /// behind.
    ///
    /// `InnerRelay::unsubscribe_all` `?`-propagates the FIRST per-relay send
    /// error, so on a non-operational relay every LATER id stays REGISTERED —
    /// and the pool's own `resubscribe()` re-sends those OLD REQs on the next
    /// connect, ahead of anything the next burst issues. A stale REQ's `EOSE`
    /// would then consume the new generation's advance for a window it never
    /// asked for.
    ///
    /// The control arm runs the bare `unsubscribe_all` on the identical shape and
    /// asserts a leftover really is produced — without it this test would pass on
    /// a relay where nothing was left over and prove nothing.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_partial_unsubscribe_all_is_swept_before_disconnect() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let circles: Vec<CircleSpec> = ["11", "22", "33", "44"]
            .iter()
            .map(|h| CircleSpec {
                group_id_hex: h.repeat(32),
                relays: vec![url.clone()],
            })
            .collect();

        // ── Control: the crate behaviour this sweep exists for.
        {
            let (control, _control_dir) = build_core();
            control
                .start(&circles, std::slice::from_ref(&url))
                .await
                .expect("control session starts");
            assert!(
                control.pool_subscription_count().await > 1,
                "the control needs several registrations for a partial failure to be \
                 partial"
            );
            let control_relay = control
                .client
                .relay(url.as_str())
                .await
                .expect("the control registered its relay");
            control_relay.ban();
            assert!(
                control_relay.unsubscribe_all().await.is_err(),
                "a banned relay must make unsubscribe_all fail — otherwise the leftover \
                 this test is about cannot arise and the assertion below is vacuous"
            );
            assert!(
                control.pool_subscription_count().await > 0,
                "...and the failure must LEAVE ids registered: that residue is what the \
                 pool's own resubscribe() would re-send ahead of the next burst's REQs"
            );
            let _ = control.stop().await;
        }

        // ── The pause: same shape, and the pool view must end EMPTY.
        let (core, _dir) = build_core();
        core.start(&circles, std::slice::from_ref(&url))
            .await
            .expect("session starts");
        core.client
            .relay(url.as_str())
            .await
            .expect("the session registered its relay")
            .ban();

        core.pause_subscriptions().await.expect("pause");
        assert_eq!(
            core.pool_subscription_count().await,
            0,
            "the post-condition sweep must unsubscribe every id a partial \
             unsubscribe_all left registered, so nothing survives for resubscribe() \
             to re-send on the next burst's connect"
        );

        let _ = core.stop().await;
    }

    /// A stale relay-side REQ can never precede the burst's own.
    ///
    /// Models F27: a registration under the SAME sub-id carrying an OLDER
    /// `since` is live at pause time — the residue a partial `unsubscribe_all`
    /// leaves, and precisely what nostr-relay-pool's own `resubscribe()` replays
    /// on the next connect, AHEAD of anything the session issues. If it were
    /// served first, its `EOSE` would consume the burst's fresh generation and
    /// advance the cursor for a window the burst never asked for.
    ///
    /// The pause must therefore leave NOTHING registered, and the first REQ the
    /// relay admits after the burst opens must carry the SESSION's `since`.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_stale_relay_side_req_never_precedes_the_bursts_own_req() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let (_relay, url, recorded) = recording_relay().await;
        let hex = "7a".repeat(32);
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: hex.clone(),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("session starts");
        assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
        let sub_id = core.active.read().await.as_ref().unwrap().group_subs[0]
            .sub_id
            .clone();

        // Plant the stale registration while the socket is still LIVE, so it is
        // REGISTERED in the pool (the state `resubscribe()` replays from) rather
        // than merely queued on a dead relay's outbound channel.
        let stale_since = nostr::Timestamp::from(1_000_u64);
        let planted = group_filter(std::slice::from_ref(&hex), 1_000);
        core.client
            .subscribe_with_id_to(vec![url.clone()], sub_id.clone(), planted, None)
            .await
            .expect("the stale registration is planted");
        assert!(
            core.pool_subscription_count().await > 0,
            "the fixture must really have registered something, or the pause below \
             sweeps nothing and this test proves nothing"
        );
        // Wait for the RELAY to have served the planted REQ before clearing the
        // record, so the clear below cannot race it and leave the stale REQ
        // looking like the burst's own.
        assert!(
            poll_until(|| {
                recorded
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .iter()
                    .any(|f| f.since == Some(stale_since))
            })
            .await,
            "the planted stale REQ must reach the relay, or there is nothing for the \
             burst's REQ to be ahead of"
        );

        core.pause_subscriptions().await.expect("pause");
        assert_eq!(
            core.pool_subscription_count().await,
            0,
            "the pause must leave NOTHING for resubscribe() to replay ahead of the next \
             burst's REQ"
        );
        recorded
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clear();

        core.open_background_burst().await.expect("burst opens");
        assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);

        let first = recorded
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .first()
            .cloned()
            .expect("the burst's open must have made the relay serve at least one REQ");
        assert!(
            first.since.is_some_and(|since| since > stale_since),
            "the FIRST REQ the relay admits after a burst open must carry the SESSION's \
             `since`, never a stale registration's: served first, its EOSE would consume \
             the burst's generation for a window the burst never asked for"
        );

        let _ = core.stop().await;
    }

    /// A pause emits exactly one `Paused`, and no `Disconnected` at all.
    ///
    /// The pause terminates every relay by design. Surfacing those transitions
    /// would have the health model stamp a "disconnected since" and — a burst
    /// interval can be as long as the receive-silence threshold — confirm a relay
    /// outage on a deliberate pause, i.e. tell the user sharing is broken every
    /// couple of minutes while it is working exactly as designed.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn pause_emits_paused_not_disconnected() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "5c".repeat(32),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("session starts");

        let mut bus = core.bus().subscribe();
        core.pause_subscriptions().await.expect("pause");

        // Drain everything the pause produced. The monitor is a separate task, so
        // the drain is bounded by a status the pause itself emits LAST: once
        // `Paused` is seen, keep reading until the bus is momentarily empty.
        let mut paused = 0usize;
        let mut disconnected = 0usize;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while tokio::time::Instant::now() < deadline {
            match tokio::time::timeout(Duration::from_millis(200), bus.recv()).await {
                Ok(Ok(LiveSyncEvent::Status { reason })) => match reason {
                    SyncStatusReason::Paused => paused += 1,
                    SyncStatusReason::Disconnected => disconnected += 1,
                    _ => {}
                },
                Ok(Ok(_)) => {}
                Ok(Err(_)) => break,
                // Nothing more in flight; the monitor has had its chance.
                Err(_) => {
                    if paused > 0 {
                        break;
                    }
                }
            }
        }

        assert_eq!(paused, 1, "a pause must emit exactly one Paused");
        assert_eq!(
            disconnected, 0,
            "and NO Disconnected: the relays this pause terminated were terminated on \
             purpose, and a health model fed those would confirm a relay outage on a \
             deliberate pause"
        );

        let _ = core.stop().await;
    }

    /// The health tick short-circuits while paused — the single most important
    /// gate in the burst design.
    ///
    /// A paused pool is `Terminated` across the board, which
    /// `health_needs_resubscribe` reads as "dropped". A tick that reached the
    /// probe would therefore call `resume_after_background` and silently re-open
    /// standing REQs in the background, undoing the pause on a 15-minute timer.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn maintain_subscription_health_while_paused_reports_paused_and_touches_no_socket() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "9e".repeat(32),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("session starts");
        core.pause_subscriptions().await.expect("pause");

        let outcome = core
            .maintain_subscription_health()
            .await
            .expect("the tick must not error while paused");
        assert_eq!(outcome.action, HealthAction::Paused);
        assert_eq!(
            (outcome.relays_total, outcome.relays_disconnected),
            (0, 0),
            "the tick must not even SNAPSHOT the pool: reporting its real \
             all-Terminated counters would publish a relay-outage-shaped snapshot for a \
             deliberate pause"
        );
        assert_eq!(
            core.pool_subscription_count().await,
            0,
            "and above all it must not have re-opened a REQ — that is the silent undo \
             this gate exists to prevent"
        );
        assert!(core.is_paused(), "the session is still paused afterwards");

        let _ = core.stop().await;
    }

    /// A tick already INSIDE the probe when a pause lands must not re-open the
    /// session.
    ///
    /// The gate before the probe cannot reach it: the call is in flight, and
    /// nothing above cancels one. Such a tick then reads the pause's own
    /// all-`Terminated` pool as "every relay dropped" and — before the second
    /// gate — re-anchored the WHOLE session: standing REQs, a socket, the 55 s
    /// pinger and the 49-hour `#p` inbox REQ, at an instant that is not a
    /// publish. A pause that drove no burst has no next burst to close that
    /// again, so what it leaves behind is unbounded.
    ///
    /// Deterministic, with no sleep and no scheduling assumption. The tick's
    /// future is polled ONCE, in this task: everything ahead of the probe is
    /// synchronous, so a single poll is proof the first gate has already run and
    /// passed, and it parks inside the probe on the `active` read this test
    /// holds shut. The pause — which never touches `active` — then runs to
    /// completion, and only afterwards is the probe released.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_health_tick_inside_the_probe_when_a_pause_lands_reopens_nothing() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "6b".repeat(32),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("session starts");
        assert!(
            !core.is_paused(),
            "the tick must set off from a LIVE session, or the gate before the probe \
             would answer for it and this would prove nothing"
        );
        assert!(
            core.pool_subscription_count().await > 0,
            "precondition: the session holds the REQs a re-open would put back"
        );

        // `probe_subscriptions` reads the active session first, so this is where
        // the tick parks.
        let active = core.active.write().await;
        let mut tick = std::pin::pin!(core.maintain_subscription_health());
        assert!(
            futures::poll!(tick.as_mut()).is_pending(),
            "one poll must carry the tick past the pre-probe gate and INTO the probe. \
             A `Ready` here would mean it answered without probing, and everything \
             below would be measuring the gate this test is not about"
        );

        core.pause_subscriptions().await.expect("pause");
        drop(active);

        let outcome = tick.await.expect("the tick must not error");
        assert_eq!(
            outcome.action,
            HealthAction::Paused,
            "the tick must answer from the state it is deciding in, not from the one \
             its probe found"
        );
        assert_eq!(
            core.pool_subscription_count().await,
            0,
            "and above all re-open no REQ: a standing subscription put back here has \
             nothing left to close it — this pause drove no burst"
        );
        assert_eq!(
            core.relay_health().await.connected,
            0,
            "and no socket, which is the other half of the residual: a re-anchor \
             reconnects the pool and the crate's 55 s pinger keeps the radio awake"
        );
        assert!(core.is_paused(), "the pause must still stand afterwards");

        let _ = core.stop().await;
    }

    /// Subscribing a circle while paused updates the MODEL and opens nothing.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn subscribe_circle_while_paused_updates_the_model_but_opens_nothing() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "a1".repeat(32),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("session starts");
        core.pause_subscriptions().await.expect("pause");

        let added = "b2".repeat(32);
        core.subscribe_circle(&CircleSpec {
            group_id_hex: added.clone(),
            relays: vec![url.clone()],
        })
        .await
        .expect("a paused subscribe must succeed, not fail closed");

        assert!(
            core.live_group_subs_for_test()
                .await
                .iter()
                .any(|(_, _, hexes)| hexes.contains(&added)),
            "the circle must be in the live model, or the next burst will not open it"
        );
        assert_eq!(
            core.pool_subscription_count().await,
            0,
            "...and NOTHING may be opened: a REQ here would put a standing subscription \
             back on the wire between publish ticks, which is the whole thing the pause \
             removes"
        );
        assert!(
            core.router
                .read()
                .await
                .lookup(&url, &SubscriptionId::new("x"))
                .is_none(),
            "a router with no REQ behind it can only mislead"
        );

        let _ = core.stop().await;
    }

    /// A circle subscribed while paused must have its cursor SEEDED.
    ///
    /// Without the seed the next burst's `bucket_since` reads an unset cursor as
    /// `unwrap_or(0)` and issues a `since = 0` REQ — this circle's entire
    /// history, replayed into a background wake.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn subscribe_circle_while_paused_seeds_the_cursor_so_the_next_burst_never_asks_since_zero(
    ) {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let (_relay, url, recorded) = recording_relay().await;
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "c3".repeat(32),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("session starts");
        core.pause_subscriptions().await.expect("pause");

        let added = "d4".repeat(32);
        core.subscribe_circle(&CircleSpec {
            group_id_hex: added.clone(),
            relays: vec![url.clone()],
        })
        .await
        .expect("paused subscribe");

        let seeded = core
            .circle
            .read_sync_cursor(&group_cursor_stream(&added))
            .expect("cursor read")
            .expect("a paused subscribe MUST seed the cursor");
        assert!(seeded > 0, "a seeded cursor is never zero");

        recorded
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clear();
        core.open_background_burst().await.expect("burst opens");
        // The barrier, not a sleep: an open returns once the pool ACCEPTED the
        // REQ, which is strictly before the relay has served it and run the
        // recording policy. `Settled` means every endpoint EOSE'd, i.e. the
        // relay has provably served both REQs and recorded their filters.
        assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);

        let floors: Vec<u64> = recorded
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .filter_map(|f| f.since.map(|s| s.as_secs()))
            .collect();
        assert!(
            !floors.is_empty(),
            "the burst must have made the relay serve REQs, or this proves nothing"
        );
        assert!(
            floors.iter().all(|since| *since > 0),
            "no REQ may ask `since = 0`: an unseeded cursor would replay the circle's \
             whole history into a background wake. Floors seen: {floors:?}"
        );

        let _ = core.stop().await;
    }

    /// A pause completes within the lifecycle bound even when the worker is dead.
    ///
    /// A dead worker never acks the marker, and an unbounded wait here would hold
    /// the lifecycle lock forever — which `stop` also needs, so logout would hang
    /// with the Rule-14 guard held. The fallback clears the router directly.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn pause_subscriptions_completes_within_the_lifecycle_bound_when_the_worker_is_dead() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let hex = "e5".repeat(32);
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: hex.clone(),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("session starts");
        settle_eose_anchor(&core, &hex).await;

        // The FA C6 class: the ingest worker has exited and can never ack.
        core.wedged.store(true, Ordering::Release);

        let started = tokio::time::Instant::now();
        core.pause_subscriptions()
            .await
            .expect("a wedged worker must not fail the pause");
        let elapsed = tokio::time::Instant::now() - started;
        assert!(
            elapsed < RELAY_LIFECYCLE_OP_TIMEOUT,
            "the pause must short-circuit on `wedged` rather than wait out the bound: \
             it took {elapsed:?}"
        );
        assert!(
            core.router.read().await.is_empty(),
            "the fallback must clear the router directly when the worker cannot"
        );
        assert!(
            core.processor.all_advances_consumed(),
            "...and burn every open generation's advance (note_delivery_gap), or the \
             next EOSE would advance a cursor over events the dead worker never applied"
        );

        // Rule 14: a later `stop` must not hang on the lock this pause held.
        assert!(
            tokio::time::timeout(Duration::from_secs(20), core.stop())
                .await
                .is_ok(),
            "a stop after a wedged pause must not hang — that is a logout hang with the \
             Rule-14 LiveSessionGuard still held"
        );
    }

    /// The pause DRAINS the intake before it clears the router — Security Rule 12
    /// at the `pause_subscriptions` level.
    ///
    /// The companion to
    /// `supervisor::a_pause_marker_drains_every_queued_event_before_the_router_is_cleared`,
    /// which pins the WORKER's half. This one pins the CALLER's: a pause that
    /// cleared the router itself — instead of sending a marker through the intake
    /// queue and waiting for the ack — drops every event still queued from this
    /// burst's own replay. Downloaded backlog, discarded silently and
    /// permanently, because the generation's advance is burned in the same
    /// breath and the catch-up sweep re-derives its floor from the same cursor.
    ///
    /// Deterministic by construction: the events are queued BEFORE the pause is
    /// called, so "the marker is behind the backlog" is a fact about the channel.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn pause_subscriptions_drains_the_intake_before_it_clears_the_router() {
        // How much backlog is queued ahead of the pause.
        const QUEUED: usize = 12;

        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let hex = "2b".repeat(32);
        let (core, _dir) = build_core();
        let mut bus = core.bus().subscribe();
        core.start(
            &[CircleSpec {
                group_id_hex: hex.clone(),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("session starts");
        let sub_id = core.active.read().await.as_ref().unwrap().group_subs[0]
            .sub_id
            .clone();
        assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);

        // Queue the backlog straight onto the intake, so the test controls
        // exactly what is outstanding when the pause runs. The `#[cfg(test)]`
        // panic seam inside `process_group_event` is the per-event delivery
        // oracle: reaching it proves the worker ROUTED that event. (Scary panic
        // messages on stderr are expected.)
        let tx = core
            .intake
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
            .expect("a started session retains its intake sender");
        for _ in 0..QUEUED {
            tx.send(crate::relay::live_sync::supervisor::RawSignal::Event(
                Box::new(crate::relay::live_sync::supervisor::RawEvent {
                    relay_url: RelayUrl::parse(&url).expect("relay url"),
                    subscription_id: sub_id.clone(),
                    event: nostr::EventBuilder::new(nostr::Kind::Custom(445), "__panic_for_test__")
                        .tags([nostr::Tag::custom(
                            nostr::TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
                            [hex.clone()],
                        )])
                        .sign_with_keys(&Keys::generate())
                        .expect("sign"),
                }),
            ))
            .await
            .expect("the intake accepts the backlog");
        }

        core.pause_subscriptions().await.expect("pause");

        // Every queued event must already have been routed by the time the pause
        // returned: that is the whole content of the marker's ack.
        let mut seen = 0usize;
        while let Ok(Ok(ev)) = tokio::time::timeout(Duration::from_millis(200), bus.recv()).await {
            if matches!(
                ev,
                LiveSyncEvent::Status {
                    reason: SyncStatusReason::Unprocessable
                }
            ) {
                seen += 1;
            }
        }
        assert_eq!(
            seen, QUEUED,
            "every event queued when the pause began must be routed BEFORE the router \
             is cleared. A pause that clears the router itself drops whatever is still \
             queued behind the marker — downloaded backlog, discarded silently and \
             permanently (Security Rule 12)"
        );

        let _ = core.stop().await;
    }

    /// The pause BLOCKS on the in-flight publish gauge before it disconnects.
    ///
    /// Security Rule 13's structural half, tested on the gauge itself rather
    /// than through a scenario — because today no scenario can distinguish it.
    /// The engine's auto-commit publish is awaited INLINE in the serial worker,
    /// so the pause marker is always queued behind it and the marker drain
    /// happens to cover the same window. The gauge exists so that stops being a
    /// coincidence: it is the authoritative check AT THE INSTANT OF DISCONNECT,
    /// covering the marker fallback path (a wedged worker acks nothing), and the
    /// ms window between `settle_before_pause` returning and the pause reaching
    /// its disconnect.
    ///
    /// Deletion of the gauge makes this red at the first assertion. The
    /// companion source gate is
    /// `security_rule_gates::rule13_a_burst_never_pauses_with_a_pending_publish_outstanding`.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn pause_subscriptions_blocks_on_the_in_flight_publish_gauge() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        let core = Arc::new(core);
        core.start(
            &[CircleSpec {
                group_id_hex: "3d".repeat(32),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("session starts");

        // A publish is between SEND and OK, held on the REAL production gauge.
        let gauge = core.processor.hold_publish_for_test();
        assert_eq!(core.in_flight_publishes(), 1);

        let pausing = Arc::clone(&core);
        let pause = tokio::spawn(async move { pausing.pause_subscriptions().await });

        // The pause must NOT complete. Deterministic: nothing releases the gauge
        // during this window, so no amount of scheduling can finish the call.
        assert!(
            tokio::time::timeout(Duration::from_secs(2), async {
                while !pause.is_finished() {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .is_err(),
            "the pause must block while a publish is between SEND and OK. \
             Disconnecting there makes wait_for_ok return Err, publish_failed rolls the \
             group back to the prior epoch, and the relay may already have stored and \
             served that commit — a roster fork every burst (Security Rule 13)"
        );
        assert!(
            core.relay_health().await.connected > 0,
            "...and it must not have disconnected either: the block is the point, not \
             the return value"
        );

        // Release it: the pause must then complete promptly, which is what proves
        // the assertion above observed the GAUGE rather than a hang.
        drop(gauge);
        pause
            .await
            .expect("the pause task must not panic")
            .expect("the pause must succeed once the publish resolves");
        assert_eq!(core.pool_subscription_count().await, 0);

        let _ = core.stop().await;
    }

    /// A repair armed while paused is DEFERRED, never consumed — and it opens
    /// nothing.
    ///
    /// The gate has to sit in `run_repair` BEFORE `take_due`, not inside
    /// `reissue`. `take_due` clears `due_at`, bumps `attempts` and arms the next
    /// backoff, so a gate one call later would CONSUME the pending re-issue: the
    /// repair is then silently forgotten rather than deferred, and the endpoint
    /// it was going to restore waits for the 15-minute health tick instead.
    ///
    /// The pause also drains the queue outright (`repair.clear()`), which is what
    /// makes this belt-and-braces in the field — so the fixture arms the repair
    /// AFTER the pause, which is the only state in which the gate is the thing
    /// doing the work.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_repair_armed_while_paused_is_deferred_and_opens_nothing() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "8f".repeat(32),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("session starts");
        let sub_id = core.active.read().await.as_ref().unwrap().group_subs[0]
            .sub_id
            .clone();

        core.pause_subscriptions().await.expect("pause");
        assert_eq!(
            core.repair.pending_len(),
            0,
            "the pause drains the repair queue, so the entry below is unambiguously the \
             one this test armed"
        );

        // A `CLOSED` recorded while paused: due immediately (a first `Dropped`
        // incident is), so the repair task will wake for it at once.
        core.repair.note_closed(
            &RepairKey {
                relay_url: RelayUrl::parse(&url).expect("relay url"),
                sub_id,
            },
            ClosedKind::Dropped,
        );

        // Nothing may be re-opened. The repair is due IMMEDIATELY (a first
        // `Dropped` incident is), so the task wakes at once and a short window is
        // ample; a violation short-circuits the wait rather than waiting it out.
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        while tokio::time::Instant::now() < deadline {
            if core.pool_subscription_count().await > 0 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert_eq!(
            core.pool_subscription_count().await,
            0,
            "a repair must never re-open a REQ while paused: that puts a standing \
             subscription back on the wire between publish ticks and re-opens the socket \
             the pause closed"
        );
        // ...and the pending re-issue must still be THERE.
        assert_eq!(
            core.repair.pending_len(),
            1,
            "the gate must DEFER the re-issue, not consume it. A gate inside `reissue` \
             instead of before `take_due` would leave this at 0: `take_due` already \
             cleared `due_at` and armed the next backoff, so the repair is silently \
             forgotten rather than deferred"
        );

        let _ = core.stop().await;
    }

    /// A repair that is DUE while paused leaves the repair task PARKED.
    ///
    /// `run_repair`'s paused gate defers the re-issue without clearing its
    /// `due_at` — which is the right call, since `take_due` would consume it —
    /// so the entry's deadline stays in the PAST for the whole pause. A loop
    /// that still armed `sleep_until` on it finds that arm Ready on every poll
    /// and re-polls it at CPU speed, from the relay's `CLOSED` until
    /// `repair.clear()` at the end of the pause: through the marker send, its
    /// ack, and the UNCAPPED publish gauge. One relay echoing `CLOSED` at the
    /// pause's own `unsubscribe_all` is enough to arm it.
    ///
    /// Nothing functional can see that. Nothing is re-issued, nothing is
    /// consumed, and every assertion of
    /// `a_repair_armed_while_paused_is_deferred_and_opens_nothing` still passes —
    /// the wake COUNT is the only difference between a parked task and a
    /// spinning one.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_repair_due_while_paused_leaves_the_repair_task_parked() {
        /// A parked loop wakes once per notification. Four orders of magnitude
        /// below the ~700k iterations a spin produces in a couple of seconds,
        /// and far enough above the single wake this test provokes that no
        /// scheduling detail can reach it.
        const PARKED_WAKES: u64 = 32;

        // No relay and no REQ: the paused arm of the loop is the whole subject,
        // and a re-issue can never run (the gate returns before `take_due`).
        let (core, _dir) = build_core();
        core.paused.store(true, Ordering::Release);
        let task = tokio::spawn(run_repair(core.repair_plane(), core.cancel_tx.subscribe()));

        // The task's entry pass, observed rather than assumed, so the baseline
        // cannot race the spawn.
        assert!(
            poll_until(|| core.repair.wakeups() >= 1).await,
            "the repair task must run at least one pass on entry"
        );
        let baseline = core.repair.wakeups();

        // A `CLOSED` recorded while paused is due IMMEDIATELY (a first `Dropped`
        // incident is), so from here the schedule's next deadline is permanently
        // in the past.
        core.repair.note_closed(
            &endpoint("wss://relay.example", &SubscriptionId::new("test_group_0")),
            ClosedKind::Dropped,
        );
        assert!(
            poll_until(|| core.repair.wakeups() > baseline).await,
            "the notification must still wake the task — parking must not mean \
             ignoring a CLOSED"
        );

        // Now give a spin room to be caught. The verdict is the COUNT, never the
        // elapsed time: a slower machine only polls more often, and a spinning
        // loop crosses the bound within microseconds, which short-circuits the
        // wait instead of running it out.
        let spun = poll_until_within(Duration::from_millis(500), || {
            core.repair.wakeups() > baseline + PARKED_WAKES
        })
        .await;
        assert!(
            !spun,
            "the repair task must PARK while paused, not re-poll a deadline that can \
             no longer move: {} wakes for one CLOSED is a busy loop holding a core for \
             the whole pause",
            core.repair.wakeups() - baseline
        );
        assert_eq!(
            core.repair.pending_len(),
            1,
            "...and the re-issue is still deferred, not consumed"
        );

        core.cancel_tx.send_replace(true);
        let _ = tokio::time::timeout(Duration::from_secs(5), task).await;
    }

    /// A drain marker the pause ABANDONED never clears a later burst's router.
    ///
    /// The pause's wait for the marker ack is bounded (`RELAY_LIFECYCLE_OP_TIMEOUT`)
    /// and the marker is not recallable, so a worker still draining when that
    /// expires leaves the marker queued while the pause clears the router itself,
    /// returns, and releases the lifecycle lock. The lock therefore does NOT
    /// protect what comes next: the marker can reach the worker with a LATER
    /// burst's REQs registered, and an unconditional clear there is a total
    /// receive outage for that burst — every endpoint reads as subscribed, the
    /// backlog wait times out because its own EOSE found no context, and a peer's
    /// `kind:445` is dropped at the router lookup.
    ///
    /// The abandoned marker is injected rather than provoked by a 10-second
    /// stall: what the worker sees is identical (a `Pause` naming the
    /// registration count of a pause that has already given up), and it is
    /// injected AFTER the burst so the ordering is a fact about the queue rather
    /// than a race.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_marker_from_an_abandoned_pause_never_wipes_the_next_bursts_router() {
        use nostr::{EventBuilder, Kind, Tag, TagKind};

        let hex = "a7".repeat(32);
        let (core, _relay, _dir, url) = started_core_with(&[&hex]).await;
        let mut bus = core.bus().subscribe();

        // What the pause read while it held the lock — and what its marker
        // therefore carries.
        let stale = core.router.read().await.registrations();
        core.pause_subscriptions().await.expect("pause");
        core.open_background_burst().await.expect("burst opens");
        assert!(
            core.router.read().await.registrations() > stale,
            "precondition: the burst registered its own REQs, so the abandoned marker \
             is now stale"
        );

        // The marker finally reaches the worker, one burst too late.
        let tx = core
            .intake
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
            .expect("a started session holds the intake sender");
        let (ack_tx, ack_rx) = tokio::sync::oneshot::channel();
        tx.send(RawSignal::Pause {
            registrations: stale,
            ack: ack_tx,
        })
        .await
        .expect("the marker is queued");
        tokio::time::timeout(Duration::from_secs(10), ack_rx)
            .await
            .expect("the worker must resolve the marker")
            .expect("the worker must not drop the ack");

        // The burst's receive plane must still be a receive plane. (Scary panic
        // messages on stderr are expected — the routed-event oracle is the
        // `#[cfg(test)]` seam inside `process_group_event`.)
        let publisher = Client::builder().build();
        let _ = publisher.add_relay(url.as_str()).await;
        publisher.connect().await;
        publisher.wait_for_connection(Duration::from_secs(5)).await;
        publisher
            .send_event_to(
                [url.as_str()],
                &EventBuilder::new(Kind::Custom(445), "__panic_for_test__")
                    .tags(vec![Tag::custom(
                        TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
                        [hex.clone()],
                    )])
                    .sign_with_keys(&Keys::generate())
                    .expect("sign the peer's event"),
            )
            .await
            .expect("the relay accepts the peer's event");
        assert!(
            await_routed(&mut bus).await,
            "a peer's kind:445 must still reach the engine after an abandoned marker \
             arrives mid-burst. An unconditional clear there empties the router this \
             burst just registered, and the burst receives nothing at all while every \
             endpoint still reads as subscribed"
        );

        let _ = core.stop().await;
    }

    /// A FOREGROUND re-anchor never swaps a relay out of the pool.
    ///
    /// `rebuild_stalled_relays` is `force_remove_relay` + `add_relay`, and
    /// `RelayPool::send_event_to` answers `Err(RelayNotFound)` if any named url
    /// is absent — so a receive-side auto-commit the worker sends in that window
    /// fails outright, `publish_auto_commit` reports false, `publish_failed`
    /// rolls the eviction back and the group stays un-converged. The pause has a
    /// gauge for exactly that hazard; the open has none, and the foreground —
    /// the health tick's whole-session re-anchor and the app-resume — shares this
    /// path with a LIVE worker.
    ///
    /// It is skipped there because the race it repairs cannot occur: the stranded
    /// connection task comes from `client.disconnect()`, which only the pause
    /// calls. `first_connection_timestamp` is the pool's own fingerprint of the
    /// relay OBJECT — written once and never again — so a rebuild is visible
    /// after the fact even though the absence itself is not.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_foreground_reanchor_never_rebuilds_a_relay_out_of_the_pool() {
        let (core, _relay, _dir, url) = started_core_with(&[&"b4".repeat(32)]).await;
        let object_id = || async {
            core.client
                .relay(url.as_str())
                .await
                .expect("the pool holds the relay")
                .stats()
                .first_connection_timestamp()
        };
        // OBSERVED, never implied by `start` returning: the fingerprint is
        // written by the pool's connection task, and `start`'s connect grace is
        // an early-returning WAIT that a loaded machine can outlast. Reading it
        // the instant `start` returns makes this precondition a race.
        let mut before = object_id().await;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while before == nostr::Timestamp::from(0) && tokio::time::Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(10)).await;
            before = object_id().await;
        }
        assert!(
            before > nostr::Timestamp::from(0),
            "precondition: the relay connected, so the fingerprint is written"
        );

        // Not connected — the only state in which the rebuild is reachable at all
        // — and a second crossed, so a rebuilt object's own first connection
        // could not be mistaken for this one.
        core.client.disconnect().await;
        let start = nostr::Timestamp::now().as_secs();
        assert!(poll_until(|| nostr::Timestamp::now().as_secs() > start).await);

        // The foreground re-anchor. Its OUTCOME is not the subject: with a
        // Terminated relay the REQ may or may not be accepted inside the connect
        // wait, which is precisely the race the rebuild exists for in the PAUSE
        // path. What must hold either way is that the pool's relay object was
        // not swapped while a worker could be mid-`send_event_to`.
        let _ = core.resume_after_background().await;
        assert_eq!(
            object_id().await,
            before,
            "a foreground re-anchor must leave the pool's relay object alone: \
             force_remove_relay + add_relay opens a window where send_event_to fails \
             with RelayNotFound, which rolls a staged eviction commit back"
        );

        // Control: after a PAUSE the same open still rebuilds. Without this the
        // assertion above would pass for a build that deleted the repair
        // outright, and a burst opened right after a pause would wait out the
        // crate's ~10 s retry schedule instead.
        core.pause_subscriptions().await.expect("pause");
        core.open_background_burst().await.expect("burst opens");
        assert_ne!(
            object_id().await,
            before,
            "a burst opened after a pause MUST rebuild the relay the pause terminated"
        );

        let _ = core.stop().await;
    }

    /// A FOREGROUND re-anchor always carries the inbox REQ, at any fold period.
    ///
    /// The fold belongs to the background burst, which is followed by a pause
    /// that closes every REQ anyway. A foreground re-anchor's `unsubscribe_all`
    /// is unconditional, so one that skipped the inbox would CLOSE the standing
    /// `kind:1059` REQ and then not re-issue it — no invitation could arrive for
    /// as long as the app stayed open. Worse, it is self-feeding: the health tick
    /// re-anchors on the missing REQ, consumes another sequence, and can skip
    /// again.
    ///
    /// The relay's own record of the `#p` REQs it was asked to serve is the
    /// oracle; the session's intention is not.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_foreground_reanchor_carries_the_inbox_req_at_every_fold_period() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let (_relay, url, recorded) = recording_relay().await;
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "d3".repeat(32),
                relays: vec![url.clone()],
            }],
            std::slice::from_ref(&url),
        )
        .await
        .expect("the engine starts against the recording relay");
        assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
        let mut expected = inbox_req_count(&recorded);
        assert_eq!(expected, 1, "start issues exactly one inbox REQ");

        // k = 2: at the shared counter this fixture would skip every second
        // re-anchor. Each re-anchor is a foreground one, so every one of them
        // must carry the inbox REQ.
        for round in 0..4 {
            core.resume_burst_for_test(BurstKind::Foreground, 2)
                .await
                .expect("the foreground re-anchor succeeds");
            assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
            expected += 1;
            assert_eq!(
                inbox_req_count(&recorded),
                expected,
                "foreground re-anchor {round} closed the standing inbox REQ and did not \
                 re-issue it: the device can receive no invitation while the app is open"
            );
        }

        // ...and the health tick's re-anchor is one of those callers, so the
        // presence probe may not read the session as short of a REQ.
        assert_eq!(
            core.maintain_subscription_health()
                .await
                .expect("the health tick runs")
                .action,
            HealthAction::Healthy,
            "a session whose every REQ is live and served must read Healthy"
        );

        let _ = core.stop().await;
    }

    /// A foreground re-anchor does not CONSUME a background fold position.
    ///
    /// The counter that decides the fold is the background burst count, so
    /// interleaving foreground re-anchors must not shift which bursts carry the
    /// inbox REQ. Sharing one counter (today's `resume_after_background` is both)
    /// makes the pattern depend on how often the user opened the app.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_foreground_reanchor_does_not_consume_a_background_fold_position() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let (_relay, url, recorded) = recording_relay().await;
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "e5".repeat(32),
                relays: vec![url.clone()],
            }],
            std::slice::from_ref(&url),
        )
        .await
        .expect("the engine starts against the recording relay");
        assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
        let after_start = inbox_req_count(&recorded);

        // Background sequence 0 folds the inbox in; a foreground re-anchor runs
        // between the two bursts and always issues one of its own; background
        // sequence 1 at k = 2 must NOT.
        core.pause_subscriptions().await.expect("pause");
        core.resume_burst_for_test(BurstKind::Background, 2)
            .await
            .expect("burst 0 opens");
        assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
        assert_eq!(
            inbox_req_count(&recorded) - after_start,
            1,
            "background burst 0 always folds the inbox in"
        );

        core.resume_burst_for_test(BurstKind::Foreground, 2)
            .await
            .expect("the foreground re-anchor succeeds");
        assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
        assert_eq!(
            inbox_req_count(&recorded) - after_start,
            2,
            "and the foreground re-anchor issues its own"
        );

        core.pause_subscriptions().await.expect("pause");
        core.resume_burst_for_test(BurstKind::Background, 2)
            .await
            .expect("burst 1 opens");
        assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
        assert_eq!(
            inbox_req_count(&recorded) - after_start,
            2,
            "background burst 1 at k = 2 must fold NOTHING in: the foreground re-anchor \
             between the bursts must not have advanced the fold counter, or the cadence \
             an inbox-only relay sees depends on how often the app was opened"
        );

        // And the probe must not then expect the endpoint that burst chose not to
        // open — that shortfall reads as "a relay deleted our REQ" and re-anchors
        // the whole session on every 15-minute tick, closing the REQs it counted.
        let (expected, live, _) = core.probe_subscriptions().await;
        assert_eq!(
            expected, live,
            "after a burst that issued no inbox REQ the probe must expect no inbox \
             endpoint"
        );
        assert_eq!(
            core.maintain_subscription_health()
                .await
                .expect("the health tick runs")
                .action,
            HealthAction::Healthy,
            "...so the health tick has nothing to repair"
        );

        let _ = core.stop().await;
    }

    /// `stop` after a pause still drains the supervisor.
    ///
    /// The pause needs a clone of the intake `Sender` to push its marker behind
    /// the queued backlog — and `run_worker` exits only when EVERY sender is
    /// dropped. A clone parked on the core forever would leave the worker in
    /// `rx.recv()` after `stop`, so `join_tasks` would report `TimedOut` and the
    /// Rule-14 `LiveSessionGuard` would read as still held by a stopped session.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn stop_after_a_pause_still_drains_the_supervisor() {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await.to_string();
        let (core, _dir) = build_core();
        core.start(
            &[CircleSpec {
                group_id_hex: "f6".repeat(32),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("session starts");
        core.pause_subscriptions().await.expect("pause");

        assert_eq!(
            core.stop().await,
            StopOutcome::Drained,
            "every supervisor task must join after a pause; a retained intake Sender \
             would park the worker forever and report TimedOut"
        );
    }
}
