//! Per-circle sync-cursor integration tests over an in-process relay.
//!
//! # Dark Matter port (DM-5a)
//!
//! The pre-migration tests keyed on an undecryptable `kind:445` surfacing a
//! `Status { Unprocessable }` and NOT advancing the cursor. The DM engine
//! classifies an undecryptable / unknown-group 445 as `Ok(Stale)` — NOT an
//! error — so `process_group_event` ADVANCES the per-circle cursor silently.
//! The surviving invariants are therefore re-expressed over the observable
//! CURSOR (not the removed bus signal):
//!
//! - **cursor advance + persistence** — a delivered (Stale) 445 advances the
//!   per-circle cursor, and the advanced cursor PERSISTS across a fresh session
//!   (no re-processing). The lossless-replay-of-UNAPPLIED events invariant now
//!   belongs to the engine's durable `Buffered` (future-epoch) store and is
//!   re-expressed in the F2 gate `live_sync_out_of_order_commit_e2e`.
//! - **R4 bucket `since` = MIN** — with two circles multiplexed on ONE `#h` REQ,
//!   a BUSY circle's high cursor must NOT raise the shared bucket floor past a
//!   QUIET co-multiplexed circle's older event: proven by the quiet circle's
//!   cursor advancing past its low seed (the multiplexed REQ went back to MIN).
//!   The pure arithmetic is additionally unit-tested in `session.rs`
//!   (`remove_reissue_since_is_min_remaining_*`).

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::CircleManager;
use haven_core::relay::live_sync::{group_cursor_stream, CircleSpec, LiveSyncCore};
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

/// Polls `manager`'s `key` cursor until it exceeds `floor` (or the budget
/// elapses). Returns the final cursor value.
async fn wait_cursor_above(
    manager: &CircleManager,
    key: &str,
    floor: Option<i64>,
    budget: Duration,
) -> Option<i64> {
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        let cur = manager.read_sync_cursor(key).ok().flatten();
        let advanced = match (cur, floor) {
            (Some(c), Some(f)) => c > f,
            (Some(_), None) => true,
            _ => false,
        };
        if advanced || tokio::time::Instant::now() >= deadline {
            return cur;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// A delivered (Stale) 445 advances the per-circle cursor, and the advanced
/// cursor PERSISTS across a fresh session — so the event is not re-processed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn delivered_445_advances_cursor_and_persists_across_restart() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let circle =
        Arc::new(CircleManager::new_unencrypted(dir.path(), &nostr::Keys::generate()).unwrap());
    let group_hex = hex::encode([0x8Au8; 32]);
    let cursor_key = group_cursor_stream(&group_hex);
    let spec = CircleSpec {
        group_id_hex: group_hex.clone(),
        relays: vec![url.clone()],
    };

    // --- Session 1: receive one 445 → Stale → cursor advances. ---
    let engine1 = LiveSyncCore::new_local(Arc::clone(&circle), Keys::generate().public_key());
    engine1
        .start(std::slice::from_ref(&spec), &[])
        .await
        .expect("start session 1");
    tokio::time::sleep(Duration::from_millis(500)).await; // REQ registers

    let seed = circle.read_sync_cursor(&cursor_key).unwrap();
    assert!(seed.is_some(), "start seeds the per-circle group cursor");

    let now = Timestamp::now().as_secs();
    publish_kind445_at(&url, &group_hex, now - 3600).await;

    let advanced = wait_cursor_above(&circle, &cursor_key, seed, Duration::from_secs(8)).await;
    assert!(
        advanced > seed,
        "a delivered 445 must advance the per-circle cursor past its seed"
    );

    engine1.stop().await;

    // --- Session 2 (fresh engine + pool, SAME persisted cursor): the cursor
    // survived the restart at its advanced value (durable persistence). ---
    let after_restart = circle.read_sync_cursor(&cursor_key).unwrap();
    assert_eq!(
        after_restart, advanced,
        "the advanced cursor must persist across a session restart"
    );

    let engine2 = LiveSyncCore::new_local(Arc::clone(&circle), Keys::generate().public_key());
    engine2
        .start(std::slice::from_ref(&spec), &[])
        .await
        .expect("start session 2");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        circle.read_sync_cursor(&cursor_key).unwrap() >= advanced,
        "a restart must never regress the persisted cursor"
    );
    engine2.stop().await;
}

/// R4 (per-circle cursor multiplex gap): two circles on ONE relay share a single
/// multiplexed `#h` REQ. A BUSY circle (A) whose cursor is far ahead must NOT
/// raise the bucket floor past a QUIET circle (B) whose older event has not been
/// seen — because the bucket REQ `since` is the MINIMUM across the bucket's
/// per-circle cursors. Observed via B's cursor advancing past its low seed: the
/// multiplexed REQ went back to MIN (B's low), fetched B's old event, and
/// advanced B — proving A's high cursor did not bury it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn busy_circle_high_cursor_does_not_bury_a_quiet_co_multiplexed_circle() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let circle =
        Arc::new(CircleManager::new_unencrypted(dir.path(), &nostr::Keys::generate()).unwrap());
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

    let engine1 = LiveSyncCore::new_local(Arc::clone(&circle), Keys::generate().public_key());
    engine1.start(&specs, &[]).await.expect("start session 1");
    tokio::time::sleep(Duration::from_millis(500)).await;

    let seed_b = circle.read_sync_cursor(&key_b).unwrap();
    assert!(seed_b.is_some(), "start seeds circle B's cursor");

    // Circle A is BUSY: directly advance its cursor to ~now — far ahead of B's
    // now-24h seed. If the bucket floor followed A, B's older event would be
    // buried.
    let now = Timestamp::now().as_secs();
    let now_ms = i64::try_from(now).unwrap() * 1000;
    circle.advance_sync_cursor(&key_a, now_ms).unwrap();

    // Circle B is QUIET: a single 445 an hour ago (well above B's seed, below A's
    // cursor). The multiplexed REQ, anchored at MIN = B's low seed, must fetch it
    // and advance B — proving A did not bury it.
    engine1.stop().await;
    let engine2 = LiveSyncCore::new_local(Arc::clone(&circle), Keys::generate().public_key());
    engine2.start(&specs, &[]).await.expect("start session 2");
    tokio::time::sleep(Duration::from_millis(500)).await;
    publish_kind445_at(&url, &hex_b, now - 3600).await;

    let b_after = wait_cursor_above(&circle, &key_b, seed_b, Duration::from_secs(8)).await;
    assert!(
        b_after > seed_b,
        "B's older event must be fetched (bucket since = MIN = B's low seed), \
         not buried by A's high cursor"
    );
    // A's cursor was never regressed by the multiplexed re-anchor.
    assert_eq!(
        circle.read_sync_cursor(&key_a).unwrap(),
        Some(now_ms),
        "the busy circle's own cursor is not disturbed by the MIN-anchored bucket"
    );

    engine2.stop().await;
}
