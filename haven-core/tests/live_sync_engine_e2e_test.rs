//! End-to-end integration test for the persistent live-sync engine over a real
//! in-process Nostr relay.
//!
//! Proves the full networking glue wires up: the engine `Client` CONNECTS to a
//! real relay, the supervisor RECEIVES a live `kind:445`, the worker ROUTES it
//! by its `#h` tag to the right circle context, the processor PROCESSES it, and
//! the per-circle cursor ADVANCES.
//!
//! # Dark Matter port (DM-5a)
//!
//! The pre-migration tests observed the traversal via a `Status(Unprocessable)`
//! bus emit for an undecryptable 445. The DM engine classifies an undecryptable
//! / unknown-group 445 as `Ok(Stale)` (not an error), so no Unprocessable fires;
//! instead the per-circle cursor ADVANCES. The whole connect → subscribe →
//! receive → route → process path is therefore proven via the observable cursor
//! advance (the arithmetic side effect of a Processed/Stale ingest).

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::CircleManager;
use haven_core::relay::live_sync::{group_cursor_stream, CircleSpec, HealthAction, LiveSyncCore};
use nostr::{Alphabet, EventBuilder, Keys, Kind, SingleLetterTag, Tag, TagKind};
use nostr_relay_builder::MockRelay;
use nostr_sdk::Client;
use tempfile::TempDir;

/// Publishes a `kind:445` carrying `#h = h_value` via a fresh publisher.
async fn publish_kind445(url: &str, h_value: &str) {
    let publisher = Client::builder().build();
    publisher.add_relay(url).await.unwrap();
    publisher.connect().await;
    let event = EventBuilder::new(Kind::Custom(445), "opaque-ciphertext")
        .tags([Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
            [h_value.to_string()],
        )])
        .sign_with_keys(&Keys::generate())
        .unwrap();
    publisher
        .send_event(&event)
        .await
        .expect("publish kind:445");
}

/// Polls `circle`'s per-circle cursor for `group_hex` until it exceeds `floor`
/// (or the budget elapses). Returns whether it advanced.
async fn wait_cursor_advanced(
    circle: &CircleManager,
    group_hex: &str,
    floor: Option<i64>,
    budget: Duration,
) -> bool {
    let key = group_cursor_stream(group_hex);
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        let cur = circle.read_sync_cursor(&key).ok().flatten();
        let advanced = match (cur, floor) {
            (Some(c), Some(f)) => c > f,
            (Some(_), None) => true,
            _ => false,
        };
        if advanced {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_receives_routes_and_processes_a_kind445_over_a_real_relay() {
    // The engine enforces a WSS-only relay gate; arm the debug-only loopback
    // opt-in so the in-process `ws://127.0.0.1` relay is permitted for this test.
    let _ = haven_core::relay::allow_ws_loopback_for_test();

    let relay = MockRelay::run().await.expect("mock relay starts");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let circle =
        Arc::new(CircleManager::new_unencrypted(dir.path(), &nostr::Keys::generate()).unwrap());
    let engine = LiveSyncCore::new_local(Arc::clone(&circle), Keys::generate().public_key());

    let group_hex = hex::encode([0xABu8; 32]); // stand-in nostr_group_id
    engine
        .start(
            &[CircleSpec {
                group_id_hex: group_hex.clone(),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("engine starts and subscribes");
    tokio::time::sleep(Duration::from_millis(500)).await; // REQ registers

    let seed = circle
        .read_sync_cursor(&group_cursor_stream(&group_hex))
        .unwrap();

    // A separate publisher sends a kind:445 carrying our circle's #h.
    publish_kind445(&url, &group_hex).await;

    // The event must traverse connect → subscribe → receive → route → process →
    // cursor-advance (the Stale ingest's observable side effect).
    assert!(
        wait_cursor_advanced(&circle, &group_hex, seed, Duration::from_secs(8)).await,
        "the relayed kind:445 must traverse the whole engine path and advance the per-circle cursor"
    );

    engine.stop().await;
}

/// Two circles sharing one relay set are served by a SINGLE multiplexed `#h`
/// REQ on ONE socket: both deliver (both cursors advance), and an `#h` the engine
/// did not subscribe to is excluded by the relay-side filter (its cursor is never
/// created — the event never reaches the engine).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_multiplexes_two_circles_and_drops_unsubscribed_h() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let circle =
        Arc::new(CircleManager::new_unencrypted(dir.path(), &nostr::Keys::generate()).unwrap());
    let engine = LiveSyncCore::new_local(Arc::clone(&circle), Keys::generate().public_key());

    let hex_a = hex::encode([0xA1u8; 32]);
    let hex_b = hex::encode([0xB2u8; 32]);
    let hex_unsubscribed = hex::encode([0xCCu8; 32]);
    engine
        .start(
            &[
                CircleSpec {
                    group_id_hex: hex_a.clone(),
                    relays: vec![url.clone()],
                },
                CircleSpec {
                    group_id_hex: hex_b.clone(),
                    relays: vec![url.clone()],
                },
            ],
            &[],
        )
        .await
        .expect("start");
    tokio::time::sleep(Duration::from_millis(500)).await;

    let seed_a = circle
        .read_sync_cursor(&group_cursor_stream(&hex_a))
        .unwrap();
    let seed_b = circle
        .read_sync_cursor(&group_cursor_stream(&hex_b))
        .unwrap();

    publish_kind445(&url, &hex_a).await;
    publish_kind445(&url, &hex_b).await;
    publish_kind445(&url, &hex_unsubscribed).await; // must be filtered out

    assert!(
        wait_cursor_advanced(&circle, &hex_a, seed_a, Duration::from_secs(8)).await,
        "circle A delivers on the multiplexed socket"
    );
    assert!(
        wait_cursor_advanced(&circle, &hex_b, seed_b, Duration::from_secs(8)).await,
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

    engine.stop().await;
}

/// `resume_after_background` re-anchors the subscriptions: it emits
/// `BackgroundResumed` (proving the resume path executed, not a silent no-op)
/// AND a `kind:445` published after resume is still delivered (cursor advances).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_resume_after_background_re_anchors_and_still_delivers() {
    use haven_core::relay::live_sync::{LiveSyncEvent, SyncStatusReason};

    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let circle =
        Arc::new(CircleManager::new_unencrypted(dir.path(), &nostr::Keys::generate()).unwrap());
    let engine = LiveSyncCore::new_local(Arc::clone(&circle), Keys::generate().public_key());
    let group_hex = hex::encode([0x7Eu8; 32]);
    engine
        .start(
            &[CircleSpec {
                group_id_hex: group_hex.clone(),
                relays: vec![url.clone()],
            }],
            &[],
        )
        .await
        .expect("start");
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Subscribe BEFORE resume so we observe the BackgroundResumed status.
    let mut rx = engine.bus().subscribe();
    let seed = circle
        .read_sync_cursor(&group_cursor_stream(&group_hex))
        .unwrap();
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

    // Post-resume delivery: an event published after resume advances the cursor.
    publish_kind445(&url, &group_hex).await;
    assert!(
        wait_cursor_advanced(&circle, &group_hex, seed, Duration::from_secs(8)).await,
        "an event published after resume must still be received and processed"
    );

    engine.stop().await;
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

    engine.stop().await;
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

    engine.stop().await;
}
