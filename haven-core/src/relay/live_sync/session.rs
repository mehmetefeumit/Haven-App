//! [`LiveSyncCore`] — the persistent receive engine's lifecycle and assembly.
//!
//! Owns the single engine `Client`, the shared settle buffer + event bus + write
//! gate, and the router; spawns the [`super::supervisor`] receiver/worker tasks
//! and issues the multiplexed `#h` (group) and `#p` (inbox) subscriptions.
//!
//! The engine `Client` is built with `verify_subscriptions(true)` (drop
//! filter-mismatched events), `automatic_authentication(false)` (never send a
//! NIP-42 AUTH on this socket — no nsec↔circle linkage), a generously-sized
//! notification channel (so a slow decrypt cannot lag the pool), a `Monitor`
//! (for reconnect re-anchoring), and **no** gossip (own-relays-only, PSI-8).

use std::collections::HashSet;
use std::future::Future;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use nostr::{Filter, PublicKey, SubscriptionId};
use nostr_sdk::pool::monitor::Monitor;
use nostr_sdk::{Client, ClientOptions, RelayPoolNotification, RelayPoolOptions, RelayStatus};
use tokio::sync::{broadcast, mpsc, RwLock};
use zeroize::Zeroizing;

use crate::circle::CircleManager;
use crate::relay::cursor::{since_for_stream, SubscribePhase, STREAM_INBOX_1059};

use super::autocommit::EngineHandles;
use super::config::{
    BUS_CAP, POOL_NOTIF_CAP, RELAY_LIFECYCLE_OP_TIMEOUT_SECS, STOP_DRAIN_TIMEOUT_SECS,
    SUBSCRIBE_CONNECT_WAIT_SECS, SUBSCRIBE_MAX_ATTEMPTS, SUBSCRIBE_RETRY_WAIT_SECS,
    WORKER_QUEUE_CAP,
};
use super::error::{LiveSyncError, LiveSyncResult};
use super::event::{LiveSyncEvent, SyncStatusReason};
use super::event_bus::EventBus;
use super::gate::{generate_session_salt, MlsWriteGate};
use super::health::{
    health_needs_resubscribe, HealthAction, RelayHealthSnapshot, SubscriptionHealthOutcome,
};
use super::planes::{
    build_relay_set_subscriptions, group::group_filter, inbox::inbox_filter, CircleSpec,
    GroupSubscription, InboxSubscription, PlaneKind,
};
use super::processor::{group_cursor_stream, EngineProcessor};
use super::router::{Router, SubCtx};
use super::settle::CommitSettleBuffer;
use super::supervisor::{run_receiver, run_worker};

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
fn build_engine_client() -> Client {
    let pool_opts = RelayPoolOptions::default().notification_channel_size(POOL_NOTIF_CAP);
    let client_opts = ClientOptions::default()
        .verify_subscriptions(true)
        .automatic_authentication(false)
        .pool(pool_opts);
    // NO `.gossip(...)` — own-relays-only (PSI-8). Monitor enables reconnect
    // re-anchoring (the task that consumes it is a follow-up; the pool's
    // built-in auto-resubscribe already replays on reconnect meanwhile).
    Client::builder()
        .opts(client_opts)
        .monitor(Monitor::new(64))
        .build()
}

/// The persistent live-sync engine.
pub struct LiveSyncCore {
    client: Client,
    circle: Arc<CircleManager>,
    processor: Arc<EngineProcessor>,
    settle: Arc<StdMutex<CommitSettleBuffer>>,
    router: Arc<RwLock<Router>>,
    gate: Arc<MlsWriteGate>,
    bus: EventBus,
    own_pubkey: PublicKey,
    salt: Zeroizing<[u8; 16]>,
    shutdown: Arc<AtomicBool>,
    /// The circles + inbox relays of the active session, retained so
    /// [`Self::resume_after_background`] can re-anchor the same subscriptions
    /// after a reconnect. `None` until [`Self::start`].
    active: RwLock<Option<(Vec<CircleSpec>, Vec<String>)>>,
    /// Count of in-flight detached path-B converge tasks; [`Self::stop`] drains
    /// this to 0 (bounded) so an old core's converge never writes the shared MDK
    /// concurrently with a freshly-started core.
    converge_inflight: Arc<AtomicUsize>,
}

/// Upper bound on a single engine relay control-plane op before the engine gives
/// up on it (see [`RELAY_LIFECYCLE_OP_TIMEOUT_SECS`]).
const RELAY_LIFECYCLE_OP_TIMEOUT: Duration = Duration::from_secs(RELAY_LIFECYCLE_OP_TIMEOUT_SECS);

/// Bound for [`LiveSyncCore::stop`]'s in-flight-converge drain (see
/// [`STOP_DRAIN_TIMEOUT_SECS`]).
const STOP_DRAIN_TIMEOUT: Duration = Duration::from_secs(STOP_DRAIN_TIMEOUT_SECS);

/// Poll granularity for the `stop` drain loop; the interrupted converge task
/// decrements the counter and `stop` observes it within this interval.
const DRAIN_POLL_INTERVAL: Duration = Duration::from_millis(25);

/// Handshake grace after `connect()` before the first REQ (see
/// [`SUBSCRIBE_CONNECT_WAIT_SECS`]).
const SUBSCRIBE_CONNECT_WAIT: Duration = Duration::from_secs(SUBSCRIBE_CONNECT_WAIT_SECS);

/// Per-retry connection wait between subscribe attempts (see
/// [`SUBSCRIBE_RETRY_WAIT_SECS`]).
const SUBSCRIBE_RETRY_WAIT: Duration = Duration::from_secs(SUBSCRIBE_RETRY_WAIT_SECS);

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
/// - `Ok(true)` — the subscribe's `Output.success` set was non-empty (>= 1 relay
///   took the REQ; a partial success still multiplexes + delivers). Returns `Ok`.
/// - `Ok(false)` — EVERY relay dropped the REQ (empty `Output.success`, e.g. a
///   relay still mid-handshake). Retryable: `wait`, then re-attempt.
/// - `Err` — a POOL-level failure (no relays / relay-not-found). Not
///   self-healing, so it propagates immediately without retrying.
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
) -> LiveSyncResult<()>
where
    A: FnMut() -> AF,
    AF: Future<Output = LiveSyncResult<bool>>,
    W: FnMut() -> WF,
    WF: Future<Output = ()>,
{
    for i in 0..max_attempts {
        match attempt().await {
            Ok(true) => return Ok(()),
            Ok(false) => {}
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

impl LiveSyncCore {
    /// Builds an engine over `circle` for `own_pubkey`, with a fresh ephemeral
    /// sub-id salt and a dedicated engine `Client`. Does not connect or
    /// subscribe — call [`Self::start`].
    #[must_use]
    pub fn new_local(circle: Arc<CircleManager>, own_pubkey: PublicKey) -> Self {
        let bus = EventBus::with_capacity(BUS_CAP);
        let settle = Arc::new(StdMutex::new(CommitSettleBuffer::new()));
        let processor = Arc::new(EngineProcessor::new(
            Arc::clone(&circle),
            Arc::clone(&settle),
            bus.clone(),
        ));
        Self {
            client: build_engine_client(),
            circle,
            processor,
            settle,
            router: Arc::new(RwLock::new(Router::new())),
            gate: Arc::new(MlsWriteGate::new()),
            bus,
            own_pubkey,
            salt: generate_session_salt(),
            shutdown: Arc::new(AtomicBool::new(false)),
            active: RwLock::new(None),
            converge_inflight: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// The event bus a consumer subscribes to for decrypted locations, group
    /// updates, invitations, and status signals.
    #[must_use]
    pub const fn bus(&self) -> &EventBus {
        &self.bus
    }

    /// The shared settle buffer (the foreground finalize site opens/closes
    /// windows and takes competitors through it; it MUST also hold the write
    /// gate — see [`super::gate::MlsWriteGate`]).
    #[must_use]
    pub const fn settle(&self) -> &Arc<StdMutex<CommitSettleBuffer>> {
        &self.settle
    }

    /// The per-circle MLS write gate. The foreground converge/finalize writer
    /// MUST hold `gate.for_group(hex).lock().await` around its MDK-mutating call.
    #[must_use]
    pub const fn gate(&self) -> &Arc<MlsWriteGate> {
        &self.gate
    }

    /// The shared MLS state owner. The SEND-path convergence orchestration
    /// (`super::finalize`) stages + converges through this `CircleManager` — the
    /// SAME `Arc` the engine processor mutates, so the per-circle gate genuinely
    /// serializes foreground finalize against the engine's receive writes.
    #[must_use]
    pub(crate) const fn circle(&self) -> &Arc<CircleManager> {
        &self.circle
    }

    /// Whether the session is live (not yet stopped).
    #[must_use]
    pub fn is_running(&self) -> bool {
        !self.shutdown.load(Ordering::Acquire)
    }

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

    /// Starts the session: seeds cold-start cursors, connects the relays, spawns
    /// the supervisor (BEFORE the first REQ — the no-loss ordering fix), then
    /// registers and issues the multiplexed group + inbox subscriptions.
    ///
    /// # Errors
    ///
    /// Returns [`LiveSyncError::Relay`] if a subscription fails.
    pub async fn start(
        &self,
        circles: &[CircleSpec],
        inbox_relays: &[String],
    ) -> LiveSyncResult<()> {
        let now = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap_or(i64::MAX);
        let seed_ms = now
            .saturating_sub(SEED_LOOKBACK_SECS)
            .saturating_mul(1000)
            .max(0);

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

        // Spawn the supervisor BEFORE the first subscribe so no event delivered
        // during the subscribe round-trip is missed (notifications() only yields
        // events seen after the receiver exists).
        let notifications: broadcast::Receiver<RelayPoolNotification> = self.client.notifications();
        let (tx, rx) = mpsc::channel(WORKER_QUEUE_CAP);
        // The worker needs publish + converge capability for path-B auto-commits;
        // bundle the cheap-clone handles (Client/EventBus are Arc-internal).
        let handles = EngineHandles {
            client: self.client.clone(),
            circle: Arc::clone(&self.circle),
            gate: Arc::clone(&self.gate),
            settle: Arc::clone(&self.settle),
            bus: self.bus.clone(),
            shutdown: Arc::clone(&self.shutdown),
            converge_inflight: Arc::clone(&self.converge_inflight),
        };
        tokio::spawn(run_receiver(notifications, tx, Arc::clone(&self.shutdown)));
        tokio::spawn(run_worker(
            rx,
            Arc::clone(&self.router),
            Arc::clone(&self.processor),
            handles,
        ));

        // Register the router + issue every REQ. A failure mid-way must leave a
        // CLEANLY-STOPPED engine, not a half-started one (orphaned tasks, stale
        // router entries, un-CLOSEd REQs); so on any error we tear down before
        // returning, and the caller can retry with a fresh `new_local`.
        if let Err(e) = self
            .register_and_subscribe(&group_subs, &inbox_sub, now, SubscribePhase::Initial)
            .await
        {
            self.stop().await;
            return Err(e);
        }

        // Retain the session inputs so a background resume can re-anchor the
        // same subscriptions after a reconnect.
        *self.active.write().await = Some((circles.to_vec(), inbox_relays.to_vec()));

        self.bus.send(LiveSyncEvent::Status {
            reason: SyncStatusReason::Connected,
        });
        Ok(())
    }

    /// Registers the router contexts and issues the multiplexed group + inbox
    /// REQs in `phase` (`Initial` on first start, `Resubscribe` on resume — a
    /// wider clock-skew buffer). A subscribe failure short-circuits; the caller
    /// tears the session down on error.
    async fn register_and_subscribe(
        &self,
        group_subs: &[GroupSubscription],
        inbox_sub: &InboxSubscription,
        now: i64,
        phase: SubscribePhase,
    ) -> LiveSyncResult<()> {
        // Diagnostic (M11 e2e triage): log the exact circle set this
        // (re)subscribe anchors onto, so the drive log shows whether a
        // newly-created mid-session circle actually reached the engine's REQ.
        // Pseudonymous `nostr_group_id` prefixes only (Protocol Rule 4) — never
        // the real MLS group id, never key material.
        log::debug!(
            "[live_sync::subscribe] register_and_subscribe phase={phase:?}: {} bucket(s), circles=[{}]",
            group_subs.len(),
            group_subs
                .iter()
                .flat_map(|g| g.group_ids_hex.iter())
                .map(|h| h.get(..8).unwrap_or(h.as_str()))
                .collect::<Vec<_>>()
                .join(",")
        );
        for g in group_subs {
            let group_ids: HashSet<String> = g.group_ids_hex.iter().cloned().collect();
            self.router
                .write()
                .await
                .register_group(&g.relays, &g.sub_id, &group_ids);
            let since = self.bucket_since(&g.group_ids_hex, phase, now);
            let filter = group_filter(&g.group_ids_hex, since);
            self.subscribe_bucket(g.relays.clone(), g.sub_id.clone(), filter)
                .await?;
        }

        if inbox_sub.relays.is_empty() {
            return Ok(());
        }
        {
            let mut router = self.router.write().await;
            for relay in &inbox_sub.relays {
                router.register(
                    relay,
                    &inbox_sub.sub_id,
                    SubCtx {
                        plane: PlaneKind::Inbox,
                        group_ids_hex: HashSet::new(),
                    },
                );
            }
        }
        let inbox_cursor = self
            .circle
            .read_sync_cursor(STREAM_INBOX_1059)
            .ok()
            .flatten()
            .unwrap_or(0);
        let since = since_for_stream(STREAM_INBOX_1059, inbox_cursor, phase, now);
        let filter = inbox_filter(self.own_pubkey, since);
        self.subscribe_bucket(inbox_sub.relays.clone(), inbox_sub.sub_id.clone(), filter)
            .await?;
        Ok(())
    }

    /// Issues ONE bucket subscription (`sub_id` + `filter` over `relays`) with a
    /// BOUNDED accept-retry, and is used by BOTH `register_and_subscribe` sites.
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
    ) -> LiveSyncResult<()> {
        retry_until_accepted(
            SUBSCRIBE_MAX_ATTEMPTS,
            || async {
                let output = self
                    .client
                    .subscribe_with_id_to(relays.clone(), sub_id.clone(), filter.clone(), None)
                    .await
                    .map_err(LiveSyncError::relay)?;
                // >= 1 relay accepted the REQ ⇒ the bucket is subscribed (a shared
                // relay set multiplexes, so one live socket still delivers).
                Ok(!output.success.is_empty())
            },
            || self.client.wait_for_connection(SUBSCRIBE_RETRY_WAIT),
        )
        .await
    }

    /// Stops the session: signals shutdown, CLOSEs every REQ, shuts down the
    /// `Client`, and clears the router. Terminal for this `Client` — a fresh
    /// [`Self::new_local`] is required to restart (the salt is zeroized on drop).
    pub async fn stop(&self) {
        // Signal shutdown FIRST so an in-flight converge task's interruptible
        // settle wait bails promptly, then drain the in-flight converges (bounded)
        // so no old-core converge writes the shared MDK concurrently with a
        // freshly-started core (the cross-core race close), then tear down.
        self.shutdown.store(true, Ordering::Release);
        self.drain_converge_tasks().await;

        // Best-effort, bounded teardown: the shutdown flag is already set, so the
        // supervisor/receiver tasks die regardless; a wedged pool op must not
        // block logout/teardown. `stop` returns (), so a timeout cannot propagate.
        if bounded(RELAY_LIFECYCLE_OP_TIMEOUT, self.client.unsubscribe_all())
            .await
            .is_err()
        {
            log::warn!("[live_sync] stop: unsubscribe_all timed out; proceeding");
        }
        if bounded(RELAY_LIFECYCLE_OP_TIMEOUT, self.client.shutdown())
            .await
            .is_err()
        {
            log::warn!("[live_sync] stop: client shutdown timed out; proceeding");
        }
        self.router.write().await.clear();
        self.bus.send(LiveSyncEvent::Status {
            reason: SyncStatusReason::SessionStopped,
        });
    }

    /// Best-effort, lock-free drain of in-flight path-B converge tasks (the
    /// cross-core race close).
    ///
    /// Holds NO gate/settle lock — a draining task needs the per-circle gate to
    /// finish `gated_converge`. On the [`STOP_DRAIN_TIMEOUT`] deadline, logs and
    /// returns: an escaped task's writes are fork-safe — one shared MDK store,
    /// serialized by the process-global `crate::write_lock` writer lock + the
    /// converge epoch-TOCTOU guard, holds a single epoch lineage (a raced late
    /// converge degrades to `RolledBack`/retryable, never a fork). Assumes the
    /// shutdown flag is already set (so `settle_wait`s have been interrupted).
    async fn drain_converge_tasks(&self) {
        let inflight = Arc::clone(&self.converge_inflight);
        let drained = bounded(STOP_DRAIN_TIMEOUT, async move {
            while inflight.load(Ordering::Acquire) > 0 {
                tokio::time::sleep(DRAIN_POLL_INTERVAL).await;
            }
        })
        .await;
        if drained.is_err() {
            log::warn!("[live_sync] stop: converge drain timed out; proceeding");
        }
    }

    /// Re-anchors the session after a background period / reconnect.
    ///
    /// Reconnects any dropped relays, then re-issues every subscription with the
    /// **wider** `Resubscribe` clock-skew buffer anchored at each circle's
    /// persisted cursor, so events that arrived while the socket was down are
    /// re-fetched losslessly (the cursor advances only on applied events). The
    /// long-lived supervisor tasks and the notifications receiver are untouched,
    /// so there is no miss window. A no-op (other than a `BackgroundResumed`
    /// status) if the session was never started.
    ///
    /// # Errors
    ///
    /// Returns [`LiveSyncError`] if a re-subscription fails.
    pub async fn resume_after_background(&self) -> LiveSyncResult<()> {
        if self.shutdown.load(Ordering::Acquire) {
            return Err(LiveSyncError::NoSession);
        }
        self.client.connect().await;
        // Same fresh-reconnect race as `start`: let the re-opened sockets finish
        // their handshake (early-returning wait) before re-issuing the REQs, so a
        // re-subscribe does not drop into `Output.failed` and orphan the circle.
        self.client
            .wait_for_connection(SUBSCRIBE_CONNECT_WAIT)
            .await;

        let active = self.active.read().await.clone();
        if let Some((circles, inbox_relays)) = active {
            let now = i64::try_from(nostr::Timestamp::now().as_secs()).unwrap_or(i64::MAX);
            let own_pk_bytes = self.own_pubkey.to_bytes();
            let (group_subs, inbox_sub) =
                build_relay_set_subscriptions(&self.salt, &own_pk_bytes, &circles, &inbox_relays);
            self.register_and_subscribe(&group_subs, &inbox_sub, now, SubscribePhase::Resubscribe)
                .await?;
        }

        self.bus.send(LiveSyncEvent::Status {
            reason: SyncStatusReason::BackgroundResumed,
        });
        Ok(())
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
    pub async fn relay_health(&self) -> RelayHealthSnapshot {
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
        RelayHealthSnapshot {
            total,
            connected,
            still_connecting,
            disconnected,
        }
    }

    /// Runs one subscription-health maintenance tick (M8-4).
    ///
    /// A no-op ([`HealthAction::EngineOff`]) if the session has been stopped.
    /// Otherwise it snapshots relay connectivity and, if any relay has dropped,
    /// re-anchors every subscription at its persisted cursor via
    /// [`Self::resume_after_background`] (reconnect + re-issue the same
    /// subscription ids — no miss window).
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
        let snapshot = self.relay_health().await;
        let action = if health_needs_resubscribe(snapshot) {
            self.resume_after_background().await?;
            HealthAction::Resubscribed
        } else {
            HealthAction::Healthy
        };
        Ok(SubscriptionHealthOutcome {
            action,
            relays_total: snapshot.total,
            relays_still_connecting: snapshot.still_connecting,
            relays_disconnected: snapshot.disconnected,
        })
    }
}

#[cfg(test)]
impl LiveSyncCore {
    /// Test accessor: the in-flight-converge counter [`Self::stop`] drains.
    fn converge_inflight_for_test(&self) -> Arc<AtomicUsize> {
        Arc::clone(&self.converge_inflight)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::Keys;
    use tempfile::TempDir;

    fn build_core() -> (LiveSyncCore, TempDir) {
        let dir = TempDir::new().unwrap();
        let circle = Arc::new(CircleManager::new_unencrypted(dir.path()).unwrap());
        let pk = Keys::generate().public_key();
        (LiveSyncCore::new_local(circle, pk), dir)
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
                    Ok(true) // a relay accepted on the first try
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
        assert!(r.is_ok(), "a non-empty success on the first try must be Ok");
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
                    Ok(false) // every relay dropped the REQ
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
                    Ok(n >= 1)
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
        assert!(r.is_ok(), "acceptance on a later attempt must succeed");
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

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stop_on_a_fresh_engine_returns_promptly() {
        let (core, _dir) = build_core();
        tokio::time::timeout(Duration::from_secs(2), core.stop())
            .await
            .expect("stop on a never-started engine must return promptly");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stop_drains_an_in_flight_converge_task() {
        let (core, _dir) = build_core();
        let inflight = core.converge_inflight_for_test();
        // Model a converge task's counter lifecycle: register, do ~200ms of work,
        // deregister — `stop` must WAIT for that deregistration.
        inflight.fetch_add(1, Ordering::AcqRel);
        let task_inflight = Arc::clone(&inflight);
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(200)).await;
            task_inflight.fetch_sub(1, Ordering::AcqRel);
        });
        let start = std::time::Instant::now();
        tokio::time::timeout(Duration::from_secs(2), core.stop())
            .await
            .expect("stop must not hang");
        assert!(
            start.elapsed() >= Duration::from_millis(180),
            "stop must wait for the in-flight converge task to finish (drained)"
        );
        assert_eq!(inflight.load(Ordering::Acquire), 0, "counter drained to 0");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stop_drain_is_bounded_when_a_task_wedges() {
        let (core, _dir) = build_core();
        // A wedged task: registered, never deregisters. `stop` must proceed after
        // the drain timeout (best-effort), not hang.
        core.converge_inflight_for_test()
            .fetch_add(1, Ordering::AcqRel);
        let start = std::time::Instant::now();
        tokio::time::timeout(
            Duration::from_secs(STOP_DRAIN_TIMEOUT_SECS + 2),
            core.stop(),
        )
        .await
        .expect("stop must proceed after the drain timeout, not hang");
        let elapsed = start.elapsed();
        assert!(
            elapsed >= Duration::from_secs(STOP_DRAIN_TIMEOUT_SECS),
            "stop must wait out the full drain budget on a wedged task"
        );
        assert!(
            elapsed < Duration::from_secs(STOP_DRAIN_TIMEOUT_SECS + 2),
            "stop must not hang past the drain budget"
        );
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
            core.stop().await; // sets the shutdown flag
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
            core.stop().await;
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
}
