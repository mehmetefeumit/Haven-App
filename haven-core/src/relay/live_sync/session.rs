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
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

use nostr::PublicKey;
use nostr_sdk::pool::monitor::Monitor;
use nostr_sdk::{Client, ClientOptions, RelayPoolNotification, RelayPoolOptions};
use tokio::sync::{broadcast, mpsc, RwLock};
use zeroize::Zeroizing;

use crate::circle::CircleManager;
use crate::relay::cursor::{since_for_stream, SubscribePhase, STREAM_INBOX_1059};

use super::autocommit::EngineHandles;
use super::config::{BUS_CAP, POOL_NOTIF_CAP, WORKER_QUEUE_CAP};
use super::error::{LiveSyncError, LiveSyncResult};
use super::event::{LiveSyncEvent, SyncStatusReason};
use super::event_bus::EventBus;
use super::gate::{generate_session_salt, MlsWriteGate};
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
        for g in group_subs {
            let group_ids: HashSet<String> = g.group_ids_hex.iter().cloned().collect();
            self.router
                .write()
                .await
                .register_group(&g.relays, &g.sub_id, &group_ids);
            let since = self.bucket_since(&g.group_ids_hex, phase, now);
            let filter = group_filter(&g.group_ids_hex, since);
            self.client
                .subscribe_with_id_to(g.relays.clone(), g.sub_id.clone(), filter, None)
                .await
                .map_err(LiveSyncError::relay)?;
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
        self.client
            .subscribe_with_id_to(
                inbox_sub.relays.clone(),
                inbox_sub.sub_id.clone(),
                filter,
                None,
            )
            .await
            .map_err(LiveSyncError::relay)?;
        Ok(())
    }

    /// Stops the session: signals shutdown, CLOSEs every REQ, shuts down the
    /// `Client`, and clears the router. Terminal for this `Client` — a fresh
    /// [`Self::new_local`] is required to restart (the salt is zeroized on drop).
    pub async fn stop(&self) {
        self.shutdown.store(true, Ordering::Release);
        self.client.unsubscribe_all().await;
        self.client.shutdown().await;
        self.router.write().await.clear();
        self.bus.send(LiveSyncEvent::Status {
            reason: SyncStatusReason::SessionStopped,
        });
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
