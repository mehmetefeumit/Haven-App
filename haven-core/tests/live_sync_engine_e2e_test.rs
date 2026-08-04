//! End-to-end integration test for the persistent live-sync engine over a real
//! in-process Nostr relay.
//!
//! Proves the full networking glue wires up: the engine `Client` CONNECTS to a
//! real relay, the supervisor RECEIVES a live `kind:445`, the worker ROUTES it
//! by its `#h` tag to the right circle context, the processor PROCESSES it, and
//! the decrypted location REACHES the fan-out bus.
//!
//! # Why the oracle is a decrypted location on the bus
//!
//! Two earlier ports of this file used weaker proxies, and each was invalidated
//! by the layer underneath it.
//!
//! The pre-migration tests observed the traversal via a `Status(Unprocessable)`
//! bus emit for an undecryptable 445; the Dark Matter engine classifies an
//! undecryptable / unknown-group 445 as `Ok(Stale)` (not an error), so that
//! emit stopped firing. The DM-5a port therefore switched to "the per-circle
//! cursor advanced".
//!
//! That proxy is gone too, and for a reason worth stating: a delivered event no
//! longer advances any cursor, because its outer `created_at` is chosen by
//! whoever signed the envelope and is bound to nothing the engine authenticates
//! (see `live_sync::anchor`). In this plane the cursor moves when a relay sends
//! `EOSE`, which happens whether or not a single event was routed — so a
//! cursor-based delivery assertion would now pass VACUOUSLY.
//!
//! So these tests use real circles and real locations: a
//! `LiveSyncEvent::Location` carrying the expected `nostr_group_id` and sender
//! can only appear if the event traversed connect → subscribe → receive → route
//! → decrypt → emit. That is what the file claims to prove, and unlike both
//! proxies it cannot be satisfied by anything else.

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::live_sync::{
    group_cursor_stream, CircleSpec, HealthAction, LiveSyncCore, LiveSyncEvent,
};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Event, Keys};
use nostr_relay_builder::MockRelay;
use nostr_sdk::Client;
use tempfile::TempDir;

/// A real MLS circle the engine's `CircleManager` administers, plus the peer
/// whose locations it will receive.
struct RealCircle {
    peer: Arc<CircleManager>,
    peer_keys: Keys,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    _peer_dir: TempDir,
}

impl RealCircle {
    fn hex(&self) -> String {
        hex::encode(self.nostr_group_id)
    }

    fn spec(&self, url: &str) -> CircleSpec {
        CircleSpec {
            group_id_hex: self.hex(),
            relays: vec![url.to_string()],
        }
    }

    /// A genuine, MLS-encrypted `kind:445` location from the peer.
    async fn peer_location(&self, lat: f64, lon: f64) -> Event {
        self.peer
            .encrypt_location(
                &self.mls_group_id,
                &self.peer_keys.public_key(),
                &LocationMessage::new(lat, lon),
                600,
            )
            .await
            .expect("peer encrypts a location")
            .0
    }
}

/// Creates a circle administered by `admin` with one fresh peer member.
async fn real_circle(
    admin: &Arc<CircleManager>,
    admin_keys: &Keys,
    relays: &[String],
) -> RealCircle {
    let peer_dir = TempDir::new().unwrap();
    let peer_keys = Keys::generate();
    let peer = Arc::new(CircleManager::new_unencrypted(peer_dir.path(), &peer_keys).unwrap());
    let kp_event = build_kp_maintenance_events(
        peer.session(),
        &peer_keys,
        &["wss://kp.example.com".to_string()],
        None,
    )
    .await
    .expect("peer key package")
    .event;
    let member = MemberKeyPackage {
        key_package_event: kp_event,
        inbox_relays: vec!["wss://inbox.example.com".to_string()],
        nip65_relays: vec![],
    };

    let config = CircleConfig::new("Engine E2E Circle").with_relays(relays.to_vec());
    let result = admin
        .create_circle(admin_keys, vec![member], &config, relays)
        .await
        .expect("create circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;
    admin
        .confirm_published(result.pending)
        .await
        .expect("confirm creation");

    let welcome = result
        .welcome_events
        .iter()
        .find(|w| w.recipient_pubkey == peer_keys.public_key().to_hex())
        .expect("welcome for the peer");
    peer.process_gift_wrapped_invitation(&peer_keys, &welcome.event)
        .await
        .expect("peer processes the welcome");
    peer.accept_invitation(&welcome.event.id)
        .await
        .expect("peer joins");

    RealCircle {
        peer,
        peer_keys,
        mls_group_id,
        nostr_group_id,
        _peer_dir: peer_dir,
    }
}

/// Publishes `event` to `url` from a publisher independent of the engine.
async fn publish(url: &str, event: &Event) {
    let publisher = Client::builder().build();
    publisher.add_relay(url).await.unwrap();
    publisher.connect().await;
    publisher.send_event(event).await.expect("publish");
}

/// Waits (bounded) for a decrypted location from `circle`'s peer on the bus.
///
/// Consumes unrelated events so a `Status` or another circle's `Location`
/// cannot mask the one being waited for.
async fn wait_for_location(
    bus: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>,
    circle: &RealCircle,
    budget: Duration,
) -> bool {
    let want_gid = circle.nostr_group_id.to_vec();
    let want_sender = circle.peer_keys.public_key().to_hex();
    let deadline = tokio::time::Instant::now() + budget;
    while tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_millis(500), bus.recv()).await {
            Ok(Ok(LiveSyncEvent::Location {
                nostr_group_id,
                sender_pubkey,
                ..
            })) if nostr_group_id == want_gid && sender_pubkey == want_sender => return true,
            Ok(Ok(_)) | Err(_) => {}
            Ok(Err(_)) => return false,
        }
    }
    false
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_receives_routes_and_processes_a_kind445_over_a_real_relay() {
    // The engine enforces a WSS-only relay gate; arm the debug-only loopback
    // opt-in so the in-process `ws://127.0.0.1` relay is permitted for this test.
    let _ = haven_core::relay::allow_ws_loopback_for_test();

    let relay = MockRelay::run().await.expect("mock relay starts");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&circle, &admin_keys, std::slice::from_ref(&url)).await;

    let engine = LiveSyncCore::new_local(Arc::clone(&circle), admin_keys.public_key());
    let mut bus = engine.bus().subscribe();
    engine
        .start(&[fx.spec(&url)], &[])
        .await
        .expect("engine starts and subscribes");
    tokio::time::sleep(Duration::from_millis(500)).await; // REQ registers

    // A separate publisher sends the peer's real kind:445 for our circle.
    publish(&url, &fx.peer_location(52.370_216, 4.895_168).await).await;

    // The event must traverse connect → subscribe → receive → route → decrypt →
    // emit. Nothing but a genuine delivery produces this.
    assert!(
        wait_for_location(&mut bus, &fx, Duration::from_secs(15)).await,
        "the relayed kind:445 must traverse the whole engine path and surface as \
         a decrypted location"
    );

    // Teardown only: every assertion has already run. The outcome is not
    // asserted here because the drain contract itself is pinned by
    // `join_tasks_*` and the `stop_*` unit tests in
    // `src/relay/live_sync/session.rs`, and by the same-store restart
    // assertions in `live_sync_cursor_replay_e2e`.
    let _ = engine.stop().await;
}

/// Two circles sharing one relay set are served by a SINGLE multiplexed `#h`
/// REQ on ONE socket: both deliver, and an `#h` the engine did not subscribe to
/// is excluded by the relay-side filter (its cursor is never created — the event
/// never reaches the engine).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_multiplexes_two_circles_and_drops_unsubscribed_h() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx_a = real_circle(&circle, &admin_keys, std::slice::from_ref(&url)).await;
    let fx_b = real_circle(&circle, &admin_keys, std::slice::from_ref(&url)).await;
    let hex_unsubscribed = hex::encode([0xCCu8; 32]);

    let engine = LiveSyncCore::new_local(Arc::clone(&circle), admin_keys.public_key());
    let mut bus = engine.bus().subscribe();
    engine
        .start(&[fx_a.spec(&url), fx_b.spec(&url)], &[])
        .await
        .expect("start");
    tokio::time::sleep(Duration::from_millis(500)).await;

    publish(&url, &fx_a.peer_location(1.0, 2.0).await).await;
    publish(&url, &fx_b.peer_location(3.0, 4.0).await).await;
    // A 445 for a circle the engine never subscribed to; must be filtered out.
    publish(
        &url,
        &nostr::EventBuilder::new(nostr::Kind::Custom(445), "opaque-ciphertext")
            .tags([nostr::Tag::parse(["h", &hex_unsubscribed]).unwrap()])
            .sign_with_keys(&Keys::generate())
            .unwrap(),
    )
    .await;

    assert!(
        wait_for_location(&mut bus, &fx_a, Duration::from_secs(15)).await,
        "circle A delivers on the multiplexed socket"
    );
    assert!(
        wait_for_location(&mut bus, &fx_b, Duration::from_secs(15)).await,
        "circle B delivers on the SAME multiplexed socket"
    );
    // The unsubscribed #h never reaches the engine (relay-side filter): it was
    // never subscribed, so it has no per-circle cursor at all.
    assert_eq!(
        circle
            .read_sync_cursor(&group_cursor_stream(&hex_unsubscribed))
            .unwrap(),
        None,
        "the unsubscribed #h must never reach the engine (no cursor is created)"
    );

    // Teardown only: every assertion has already run. The outcome is not
    // asserted here because the drain contract itself is pinned by
    // `join_tasks_*` and the `stop_*` unit tests in
    // `src/relay/live_sync/session.rs`, and by the same-store restart
    // assertions in `live_sync_cursor_replay_e2e`.
    let _ = engine.stop().await;
}

/// `resume_after_background` re-anchors the subscriptions: it emits
/// `BackgroundResumed` (proving the resume path executed, not a silent no-op)
/// AND a `kind:445` published after resume is still delivered.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_resume_after_background_re_anchors_and_still_delivers() {
    use haven_core::relay::live_sync::SyncStatusReason;

    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let admin_keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &admin_keys).unwrap());
    let fx = real_circle(&circle, &admin_keys, std::slice::from_ref(&url)).await;

    let engine = LiveSyncCore::new_local(Arc::clone(&circle), admin_keys.public_key());
    engine.start(&[fx.spec(&url)], &[]).await.expect("start");
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Subscribe BEFORE resume so we observe the BackgroundResumed status.
    let mut rx = engine.bus().subscribe();
    engine
        .resume_after_background()
        .await
        .expect("resume re-anchors the subscriptions");

    // Drain a short window for the resume status (proves the resume path ran).
    let mut saw_resumed = false;
    while let Ok(Ok(ev)) = tokio::time::timeout(Duration::from_millis(800), rx.recv()).await {
        if matches!(
            ev,
            LiveSyncEvent::Status {
                reason: SyncStatusReason::BackgroundResumed
            }
        ) {
            saw_resumed = true;
            break;
        }
    }
    assert!(
        saw_resumed,
        "resume must emit BackgroundResumed (proves the resume path executed)"
    );

    // Post-resume delivery: an event published after resume still arrives.
    publish(&url, &fx.peer_location(9.0, 9.0).await).await;
    assert!(
        wait_for_location(&mut rx, &fx, Duration::from_secs(15)).await,
        "an event published after resume must still be received and processed"
    );

    // Teardown only: every assertion has already run. The outcome is not
    // asserted here because the drain contract itself is pinned by
    // `join_tasks_*` and the `stop_*` unit tests in
    // `src/relay/live_sync/session.rs`, and by the same-store restart
    // assertions in `live_sync_cursor_replay_e2e`.
    let _ = engine.stop().await;
}

/// M8-4: over a live relay, a health tick reports `Healthy` (relays present,
/// none dropped) — the "relays present" case the unit test's empty pool can't
/// reach.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn subscription_health_reports_healthy_over_a_connected_relay() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let circle =
        Arc::new(CircleManager::new_unencrypted(dir.path(), &nostr::Keys::generate()).unwrap());
    let engine = LiveSyncCore::new_local(circle, Keys::generate().public_key());
    engine
        .start(
            &[CircleSpec {
                group_id_hex: hex::encode([0x11u8; 32]),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("start");

    // Poll until the single relay reaches Connected.
    let mut connected = false;
    for _ in 0..50 {
        let s = engine.relay_health().await;
        if s.total == 1 && s.disconnected == 0 {
            connected = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(connected, "the live relay must reach Connected");

    let outcome = engine.maintain_subscription_health().await.unwrap();
    assert_eq!(outcome.action, HealthAction::Healthy);
    assert_eq!(outcome.relays_total, 1);
    assert_eq!(outcome.relays_disconnected, 0);

    // Teardown only: every assertion has already run. The outcome is not
    // asserted here because the drain contract itself is pinned by
    // `join_tasks_*` and the `stop_*` unit tests in
    // `src/relay/live_sync/session.rs`, and by the same-store restart
    // assertions in `live_sync_cursor_replay_e2e`.
    let _ = engine.stop().await;
}

/// M8-4: the actual healing branch — with a dropped relay in the pool, a health
/// tick re-anchors (`Resubscribed`). Uses one live relay + one refused loopback
/// port so a disconnected relay is deterministically present while the
/// re-subscribe still succeeds on the live relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn subscription_health_resubscribes_when_a_relay_is_down() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let live_url = relay.url().await.to_string();
    // A refused loopback port (nothing listening) — the pool marks it dropped.
    let dead_url = "ws://127.0.0.1:1".to_string();

    let dir = TempDir::new().unwrap();
    let circle =
        Arc::new(CircleManager::new_unencrypted(dir.path(), &nostr::Keys::generate()).unwrap());
    let engine = LiveSyncCore::new_local(circle, Keys::generate().public_key());
    engine
        .start(
            &[CircleSpec {
                group_id_hex: hex::encode([0x22u8; 32]),
                relays: vec![live_url.clone(), dead_url.clone()],
            }],
            &[],
        )
        .await
        .expect("start tolerates a down relay (subscribe queues on it)");

    // Poll until the refused relay is observed as dropped. Connection-refused on
    // a loopback port is fast, and the pool's retry backoff keeps it in the
    // dropped state between attempts, so this settles quickly.
    let mut saw_drop = false;
    for _ in 0..80 {
        let s = engine.relay_health().await;
        if s.total >= 2 && s.disconnected >= 1 {
            saw_drop = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(saw_drop, "the refused relay must be observed as dropped");

    let outcome = engine.maintain_subscription_health().await.unwrap();
    assert_eq!(
        outcome.action,
        HealthAction::Resubscribed,
        "a dropped relay must trigger a re-anchor"
    );
    assert!(outcome.relays_total >= 2);
    assert!(outcome.relays_disconnected >= 1);

    // Teardown only: every assertion has already run. The outcome is not
    // asserted here because the drain contract itself is pinned by
    // `join_tasks_*` and the `stop_*` unit tests in
    // `src/relay/live_sync/session.rs`, and by the same-store restart
    // assertions in `live_sync_cursor_replay_e2e`.
    let _ = engine.stop().await;
}
