//! Cursor no-advance / lossless-replay integration tests over an in-process relay.
//!
//! Both tests exercise the load-bearing sync-cursor invariant: **the per-circle
//! group cursor advances ONLY on a successfully-applied event**, so an event the
//! engine could not apply (an `Unprocessable` `kind:445`) is never skipped — the
//! un-advanced cursor re-anchors the next REQ below it and the event is replayed.
//!
//! - **R8** — an `Unprocessable` 445 does not advance the cursor, and a fresh
//!   session RE-DELIVERS the same event (the persisted, un-advanced cursor drives
//!   the replay).
//! - **R4** — with two circles multiplexed on ONE `#h` REQ, a busy circle's
//!   cursor advancing must NOT bury a quiet co-multiplexed circle's un-applied
//!   event: the bucket `since` is the MINIMUM across the bucket's per-circle
//!   cursors, so the quiet circle's event is still re-fetched on resubscribe.
//!
//! Neither test needs a real MLS group: an event for a circle the manager does
//! not hold decrypts to `Unprocessable`, which is exactly the "cursor must not
//! advance" case under test. A fresh `LiveSyncCore` (new relay pool) is used for
//! each "restart" so the relay-pool's per-session seen-event dedup cannot mask a
//! genuine re-fetch.

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::CircleManager;
use haven_core::relay::live_sync::{
    group_cursor_stream, CircleSpec, LiveSyncCore, LiveSyncEvent, SyncStatusReason,
};
use nostr::{Alphabet, EventBuilder, Keys, Kind, SingleLetterTag, Tag, TagKind, Timestamp};
use nostr_relay_builder::MockRelay;
use nostr_sdk::Client;
use tempfile::TempDir;

/// Publishes an undecryptable `kind:445` carrying `#h = h_value` at
/// `created_at_secs` via a fresh publisher.
async fn publish_kind445_at(url: &str, h_value: &str, created_at_secs: u64) {
    let publisher = Client::builder().build();
    publisher.add_relay(url).await.unwrap();
    publisher.connect().await;
    let event = EventBuilder::new(Kind::Custom(445), "opaque-ciphertext")
        .tags([Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
            [h_value.to_string()],
        )])
        .custom_created_at(Timestamp::from(created_at_secs))
        .sign_with_keys(&Keys::generate())
        .unwrap();
    publisher
        .send_event(&event)
        .await
        .expect("publish kind:445");
}

/// Waits up to `budget` for the engine to emit at least one `Unprocessable`
/// status. Returns `true` if seen.
async fn wait_unprocessable(
    rx: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>,
    budget: Duration,
) -> bool {
    tokio::time::timeout(budget, async {
        loop {
            match rx.recv().await {
                Ok(LiveSyncEvent::Status {
                    reason: SyncStatusReason::Unprocessable,
                }) => break true,
                Ok(_) => {}
                Err(_) => break false,
            }
        }
    })
    .await
    .unwrap_or(false)
}

/// R8: an `Unprocessable` `kind:445` must NOT advance the per-circle cursor, and
/// a fresh session RE-DELIVERS the same event — proving the persisted,
/// un-advanced cursor drives lossless replay (a dropped event can never skip an
/// unprocessed commit).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn unprocessable_does_not_advance_cursor_and_replays_on_restart() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path()).unwrap());
    let group_hex = hex::encode([0x8Au8; 32]);
    let cursor_key = group_cursor_stream(&group_hex);
    let spec = CircleSpec {
        group_id_hex: group_hex.clone(),
        relays: vec![url.clone()],
    };

    // --- Session 1: receive one undecryptable 445 → Unprocessable. ---
    let engine1 = LiveSyncCore::new_local(Arc::clone(&circle), Keys::generate().public_key());
    let mut rx1 = engine1.bus().subscribe();
    engine1
        .start(std::slice::from_ref(&spec), &[])
        .await
        .expect("start session 1");
    tokio::time::sleep(Duration::from_millis(500)).await; // REQ registers

    // The cold-start seed (now-24h) is installed; capture it — it must not move.
    let seed = circle.read_sync_cursor(&cursor_key).unwrap();
    assert!(seed.is_some(), "start seeds the per-circle group cursor");

    // Publish an undecryptable 445 an hour ago (well inside the 24h seed window).
    let now = Timestamp::now().as_secs();
    publish_kind445_at(&url, &group_hex, now - 3600).await;

    assert!(
        wait_unprocessable(&mut rx1, Duration::from_secs(8)).await,
        "the relayed 445 must surface Unprocessable (no MLS group to decrypt it)"
    );

    // The cursor did NOT advance (Unprocessable ⇒ advance_cursor = false).
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        circle.read_sync_cursor(&cursor_key).unwrap(),
        seed,
        "an Unprocessable event must NEVER advance the sync cursor"
    );

    engine1.stop().await;

    // --- Session 2 (fresh engine + fresh relay pool, SAME persisted cursor): the
    // un-advanced cursor re-anchors the REQ `since` below the stored event, so the
    // SAME event is REPLAYED and surfaces Unprocessable again. ---
    let engine2 = LiveSyncCore::new_local(Arc::clone(&circle), Keys::generate().public_key());
    let mut rx2 = engine2.bus().subscribe();
    engine2
        .start(std::slice::from_ref(&spec), &[])
        .await
        .expect("start session 2");
    assert!(
        wait_unprocessable(&mut rx2, Duration::from_secs(8)).await,
        "the un-advanced cursor must replay the same event on a fresh session"
    );

    engine2.stop().await;
}

/// R4 (per-circle cursor multiplex gap): two circles on ONE relay share a single
/// multiplexed `#h` REQ. A BUSY circle (A) whose cursor advances must NOT bury a
/// QUIET circle (B) whose event was not applied — because the bucket REQ `since`
/// is the MINIMUM across the bucket's per-circle cursors. So B's original event
/// is RE-FETCHED on a fresh subscription anchored at B's low cursor, never
/// skipped by A's advance.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn busy_circle_cursor_advance_does_not_bury_a_quiet_co_multiplexed_circle() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path()).unwrap());
    let hex_a = hex::encode([0xA1u8; 32]); // the BUSY circle
    let hex_b = hex::encode([0xB2u8; 32]); // the QUIET circle
    let key_a = group_cursor_stream(&hex_a);
    let key_b = group_cursor_stream(&hex_b);
    // Same relay set ⇒ ONE multiplexed bucket/REQ covering both circles.
    let specs = [
        CircleSpec {
            group_id_hex: hex_a.clone(),
            relays: vec![url.clone()],
        },
        CircleSpec {
            group_id_hex: hex_b.clone(),
            relays: vec![url.clone()],
        },
    ];

    // --- Session 1: establish the divergent per-circle cursors. ---
    let engine1 = LiveSyncCore::new_local(Arc::clone(&circle), Keys::generate().public_key());
    let mut rx1 = engine1.bus().subscribe();
    engine1.start(&specs, &[]).await.expect("start session 1");
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Both circles cold-seeded to now-24h; capture B's seed (it must not move).
    let seed_b = circle.read_sync_cursor(&key_b).unwrap();
    assert!(seed_b.is_some(), "start seeds circle B's cursor");

    // Circle A is BUSY: directly advance its cursor to ~now (models A having just
    // applied a recent event). This is far ahead of B's now-24h seed.
    let now = Timestamp::now().as_secs();
    let now_ms = i64::try_from(now).unwrap() * 1000;
    circle.advance_sync_cursor(&key_a, now_ms).unwrap();

    // Circle B is QUIET: a single undecryptable 445 an hour ago → Unprocessable,
    // so B's cursor stays at the low seed.
    publish_kind445_at(&url, &hex_b, now - 3600).await;
    assert!(
        wait_unprocessable(&mut rx1, Duration::from_secs(8)).await,
        "B's relayed 445 must surface Unprocessable"
    );
    tokio::time::sleep(Duration::from_millis(300)).await;

    // The per-circle cursors DIVERGED: A high (now), B still the low seed.
    assert_eq!(
        circle.read_sync_cursor(&key_a).unwrap(),
        Some(now_ms),
        "the busy circle's cursor advanced"
    );
    assert_eq!(
        circle.read_sync_cursor(&key_b).unwrap(),
        seed_b,
        "the quiet circle's cursor stayed at its low seed (its 445 was Unprocessable)"
    );

    engine1.stop().await;

    // --- Session 2 (fresh engine + pool, SAME persisted cursors): the bucket
    // `since` for the A∪B multiplex is the MINIMUM = B's LOW cursor, so B's
    // original event is RE-FETCHED (surfaces Unprocessable again). Circle A has NO
    // event on the relay, so the re-fetched Unprocessable is unambiguously B's —
    // proving A's advance did not raise the bucket floor past B's event. Were the
    // bucket wrongly anchored at A's HIGH cursor, B's hour-old event would fall
    // below `since` and be buried. ---
    let engine2 = LiveSyncCore::new_local(Arc::clone(&circle), Keys::generate().public_key());
    let mut rx2 = engine2.bus().subscribe();
    engine2.start(&specs, &[]).await.expect("start session 2");
    assert!(
        wait_unprocessable(&mut rx2, Duration::from_secs(8)).await,
        "B's event must be re-fetched (bucket since = MIN = B's low cursor), not buried by A's advance"
    );

    engine2.stop().await;
}
