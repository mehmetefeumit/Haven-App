//! End-to-end integration test for the persistent live-sync engine over a real
//! in-process Nostr relay.
//!
//! Proves the full networking glue wires up: the engine `Client` CONNECTS to a
//! real relay, the supervisor RECEIVES a live `kind:445`, the worker ROUTES it
//! by its `#h` tag to the right circle context, the processor PROCESSES it, and
//! the result is EMITTED on the engine bus. The event is deliberately
//! undecryptable (there is no matching MLS group), so the engine surfaces a
//! `Status(Unprocessable)` — which is exactly the observable proof that the
//! event traversed the entire connect → subscribe → receive → route → process →
//! emit path rather than being dropped at any seam.

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::CircleManager;
use haven_core::relay::live_sync::{CircleSpec, LiveSyncCore, LiveSyncEvent, SyncStatusReason};
use nostr::{Alphabet, EventBuilder, Keys, Kind, SingleLetterTag, Tag, TagKind};
use nostr_relay_builder::MockRelay;
use nostr_sdk::Client;
use tempfile::TempDir;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_receives_routes_and_processes_a_kind445_over_a_real_relay() {
    // The engine enforces a WSS-only relay gate; arm the debug-only loopback
    // opt-in so the in-process `ws://127.0.0.1` relay is permitted for this test.
    let _ = haven_core::relay::allow_ws_loopback_for_test();

    // 1. An in-process relay.
    let relay = MockRelay::run().await.expect("mock relay starts");
    let url = relay.url().await.to_string();

    // 2. An engine over a fresh (empty) MLS store, subscribed to one circle.
    let dir = TempDir::new().unwrap();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path()).unwrap());
    let engine = LiveSyncCore::new_local(circle, Keys::generate().public_key());
    let mut rx = engine.bus().subscribe();

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

    // Let the REQ register on the relay before publishing the live event.
    tokio::time::sleep(Duration::from_millis(500)).await;

    // 3. A separate publisher sends a kind:445 carrying our circle's #h.
    let publisher = Client::builder().build();
    publisher.add_relay(&url).await.unwrap();
    publisher.connect().await;
    let event = EventBuilder::new(Kind::Custom(445), "opaque-ciphertext")
        .tags([Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
            [group_hex.clone()],
        )])
        .sign_with_keys(&Keys::generate())
        .unwrap();
    publisher
        .send_event(&event)
        .await
        .expect("publish kind:445");

    // 4. The engine must receive + route + process it and emit Unprocessable
    //    (it cannot decrypt an event for a group it does not hold). Skip the
    //    start() Connected status; fail on timeout.
    let received = tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            match rx.recv().await {
                Ok(LiveSyncEvent::Status {
                    reason: SyncStatusReason::Unprocessable,
                }) => break true,
                Ok(_) => {} // Connected / other status — keep waiting
                Err(_) => break false,
            }
        }
    })
    .await;

    assert_eq!(
        received,
        Ok(true),
        "the relayed kind:445 must traverse the whole engine path and emit Unprocessable"
    );

    engine.stop().await;
}

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

/// Counts `Status(Unprocessable)` emissions on `rx` over a quiet window
/// (returns once `recv` is idle for `idle`).
async fn count_unprocessable(
    rx: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>,
    idle: Duration,
) -> usize {
    let mut count = 0;
    while let Ok(Ok(ev)) = tokio::time::timeout(idle, rx.recv()).await {
        if matches!(
            ev,
            LiveSyncEvent::Status {
                reason: SyncStatusReason::Unprocessable
            }
        ) {
            count += 1;
        }
    }
    count
}

/// Two circles sharing one relay set are served by a SINGLE multiplexed `#h`
/// REQ on ONE socket: both deliver, and an `#h` the engine did not subscribe to
/// is excluded by the relay-side filter (never reaches the engine).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_multiplexes_two_circles_and_drops_unsubscribed_h() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path()).unwrap());
    let engine = LiveSyncCore::new_local(circle, Keys::generate().public_key());

    let hex_a = hex::encode([0xA1u8; 32]);
    let hex_b = hex::encode([0xB2u8; 32]);
    let hex_unsubscribed = hex::encode([0xCCu8; 32]);
    // Same relay set ⇒ ONE multiplexed bucket/REQ for both circles.
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
    let mut rx = engine.bus().subscribe(); // after start: skip the Connected status

    publish_kind445(&url, &hex_a).await;
    publish_kind445(&url, &hex_b).await;
    publish_kind445(&url, &hex_unsubscribed).await; // must be filtered out

    let count = count_unprocessable(&mut rx, Duration::from_millis(1500)).await;
    assert_eq!(
        count, 2,
        "exactly the two subscribed circles are delivered on one socket; the unsubscribed #h is dropped"
    );

    engine.stop().await;
}

/// `resume_after_background` re-anchors the subscriptions (Resubscribe phase):
/// it actually executes the resume path (asserted via the `BackgroundResumed`
/// status — so this is non-vacuous about resume itself, not merely about the
/// already-live REQ) AND a `kind:445` published after resume is still delivered.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_resume_after_background_re_anchors_and_still_delivers() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path()).unwrap());
    let engine = LiveSyncCore::new_local(circle, Keys::generate().public_key());
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

    // Subscribe BEFORE resume so we observe the BackgroundResumed status the
    // resume path emits — proving it ran (not a silent no-op over the live REQ).
    let mut rx = engine.bus().subscribe();
    engine
        .resume_after_background()
        .await
        .expect("resume re-anchors the subscriptions");
    tokio::time::sleep(Duration::from_millis(300)).await;
    publish_kind445(&url, &group_hex).await;

    // Drain a window: require BOTH the resume status AND post-resume delivery.
    let mut saw_resumed = false;
    let mut unprocessable = 0;
    while let Ok(Ok(ev)) = tokio::time::timeout(Duration::from_millis(1500), rx.recv()).await {
        match ev {
            LiveSyncEvent::Status {
                reason: SyncStatusReason::BackgroundResumed,
            } => saw_resumed = true,
            LiveSyncEvent::Status {
                reason: SyncStatusReason::Unprocessable,
            } => unprocessable += 1,
            _ => {}
        }
    }
    assert!(
        saw_resumed,
        "resume must emit BackgroundResumed (proves the resume path executed)"
    );
    assert!(
        unprocessable >= 1,
        "an event published after resume must still be received and processed"
    );

    engine.stop().await;
}
