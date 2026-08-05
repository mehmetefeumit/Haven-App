//! Per-circle sync-cursor integration tests over an in-process relay.
//!
//! # What these used to assert, and why that premise was a defect
//!
//! The Dark Matter port (DM-5a) re-expressed this file's surviving invariants
//! over the observable CURSOR, on the premise that "a delivered `kind:445`
//! advances the per-circle cursor to its `created_at`" — which the DM engine
//! made true for undecryptable and unknown-group events too, since it reports
//! them as `Ok(Stale)` rather than an error.
//!
//! That premise is the vulnerability. A `kind:445`'s outer envelope is signed by
//! a throwaway ephemeral key, its `#h` routing tag is the circle's PUBLIC
//! `nostr_group_id`, and no receive-side check binds its `created_at` to the
//! inner MLS message the engine authenticates. Anyone who has observed one of a
//! circle's events can therefore hand this device any cursor value it likes —
//! and `since_for_stream` derives every subsequent REQ floor from that cursor,
//! so everything below it is stranded permanently and across restarts. A
//! stranded location merely ages out; a stranded COMMIT breaks the epoch chain.
//!
//! # What they assert now
//!
//! The live plane advances a cursor on exactly one signal: the relay's
//! end-of-stored-events for an open REQ, redeemed against the LOCAL clock
//! reading taken when that REQ was issued (`live_sync::anchor`). Delivered events
//! never advance it, whatever the engine makes of them.
//!
//! - **`delivered_445_never_sets_the_cursor_but_eose_does`** — a 445 delivered
//!   with an old `created_at` must NOT drag the cursor onto that timestamp; the
//!   cursor lands on the subscription's own open time instead. The advanced
//!   cursor then PERSISTS across a fresh session and never regresses (the
//!   restart coverage this file has always carried: the original defect's damage
//!   was durable, so the fix has to be too).
//! - **R4 bucket `since` = MIN** — with two circles multiplexed on ONE `#h` REQ,
//!   a BUSY circle's high cursor must NOT raise the shared bucket floor past a
//!   QUIET co-multiplexed circle's older event. Proven by the quiet circle's
//!   event being DELIVERED (a decrypted location on the bus), because the cursor
//!   is no longer a delivery oracle: it moves on EOSE whether or not anything was
//!   routed, so a cursor-based assertion would now pass vacuously. The pure
//!   arithmetic is additionally unit-tested in `session.rs`
//!   (`remove_reissue_since_is_min_remaining_*`).

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::relay::live_sync::{
    group_cursor_stream, CircleSpec, LiveSyncCore, LiveSyncEvent, StopOutcome,
};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{
    Alphabet, Event, EventBuilder, Keys, Kind, SingleLetterTag, Tag, TagKind, TagStandard,
    Timestamp,
};
use nostr_relay_builder::MockRelay;
use nostr_sdk::Client;
use tempfile::TempDir;

/// Publishes an undecryptable `kind:445` carrying `#h = h_value` at
/// `created_at_secs` via a fresh publisher.
async fn publish_kind445_at(url: &str, h_value: &str, created_at_secs: u64) {
    let event = EventBuilder::new(Kind::Custom(445), "opaque-ciphertext")
        .tags([Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
            [h_value.to_string()],
        )])
        .custom_created_at(Timestamp::from(created_at_secs))
        .sign_with_keys(&Keys::generate())
        .unwrap();
    publish(url, &event).await;
}

async fn publish(url: &str, event: &Event) {
    let publisher = Client::builder().build();
    publisher.add_relay(url).await.unwrap();
    publisher.connect().await;
    publisher.send_event(event).await.expect("publish");
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

fn now_secs() -> i64 {
    i64::try_from(Timestamp::now().as_secs()).unwrap()
}

/// A delivered 445 must NOT move the cursor; the cursor advances on the
/// subscription's EOSE, to the REQ's local open time — and that advanced value
/// survives a session restart without regressing.
///
/// # How each half discriminates
///
/// Two events are used, because "the cursor did not follow the event" is only
/// observable when the two candidate values are far apart:
///
/// * a STORED event dated an hour in the past, replayed at subscribe time. The
///   old per-event rule set the cursor to `now − 3600`; the anchor sets it to
///   the REQ's open time, an hour higher.
/// * a LIVE event published several seconds AFTER the EOSE anchor has been
///   redeemed. The old rule pushed the cursor forward again, to `now`; the
///   anchor is spent for this generation, so the cursor must not move at all.
///   The deliberate settle before publishing is what puts whole seconds between
///   the two candidate values — without it both rules land on the same second
///   and the assertion would pass either way.
///
/// The complementary assertion — that the cursor moves at all, on EOSE — is what
/// fails if the anchor were removed rather than redirected.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn delivered_445_never_sets_the_cursor_but_eose_does() {
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

    // The event the relay will replay as stored history, dated an hour ago.
    let planted_secs = now_secs() - 3600;
    publish_kind445_at(&url, &group_hex, u64::try_from(planted_secs).unwrap()).await;

    // --- Session 1: the REQ opens, the stored event is delivered, EOSE lands. ---
    let opened_at = now_secs();
    let engine1 = LiveSyncCore::new_local(Arc::clone(&circle), Keys::generate().public_key());
    engine1
        .start(std::slice::from_ref(&spec), &[])
        .await
        .expect("start session 1");

    let seed = circle.read_sync_cursor(&cursor_key).unwrap();
    assert!(seed.is_some(), "start seeds the per-circle group cursor");

    let advanced = wait_cursor_above(&circle, &cursor_key, seed, Duration::from_secs(10))
        .await
        .expect("the cursor is seeded, so it always reads back");
    assert!(
        advanced > seed.unwrap(),
        "the subscription's EOSE must advance the cursor off its cold seed \
         (otherwise the assertions below hold vacuously)"
    );
    assert!(
        advanced >= opened_at * 1000,
        "the cursor must land on the REQ's own local open time ({opened_at} s), \
         not on the replayed event's remotely-chosen created_at \
         ({planted_secs} s). Got {advanced} ms.",
    );

    // --- THE INVARIANT, live. Let whole seconds pass so a per-event advance
    // would be unmistakable, then deliver a 445 dated `now`. The generation's
    // anchor is already spent, so nothing may move. ---
    tokio::time::sleep(Duration::from_secs(3)).await;
    let live_secs = now_secs();
    assert!(
        live_secs * 1000 > advanced,
        "precondition: the live event must be dated strictly above the anchored \
         cursor, or a per-event advance would be invisible here"
    );
    publish_kind445_at(&url, &group_hex, u64::try_from(live_secs).unwrap()).await;
    // Long enough for the event to traverse receive → route → ingest; the
    // engine-path latency is milliseconds (see `live_sync_engine_e2e_test`).
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert_eq!(
        circle.read_sync_cursor(&cursor_key).unwrap(),
        Some(advanced),
        "a delivered event must move the cursor NOWHERE: its outer created_at \
         ({live_secs} s) is signed by a throwaway key and bound to nothing the \
         engine authenticates, so it is not evidence of anything",
    );

    // Rule 14 (single live session per MLS DB): session 2 below re-opens on the
    // SAME `Arc<CircleManager>`, so this stop must have JOINED session 1's
    // supervisor tasks first. A discarded `TimedOut` here would silently mean two
    // live sessions over one store — the exact divergence the guard exists to
    // prevent — and the restart assertions below would be reading a cursor two
    // engines were writing.
    assert_ne!(
        engine1.stop().await,
        StopOutcome::TimedOut,
        "session 1 must be fully drained before session 2 opens the same store"
    );

    // --- The persistence half. The poisoned cursor used to survive restarts, so
    // the corrected one has to as well. ---
    let after_stop = circle.read_sync_cursor(&cursor_key).unwrap();
    assert_eq!(
        after_stop,
        Some(advanced),
        "the anchored cursor must persist across a session teardown"
    );

    let engine2 = LiveSyncCore::new_local(Arc::clone(&circle), Keys::generate().public_key());
    engine2
        .start(std::slice::from_ref(&spec), &[])
        .await
        .expect("start session 2");
    tokio::time::sleep(Duration::from_millis(500)).await;
    let after_restart = circle.read_sync_cursor(&cursor_key).unwrap().unwrap();
    assert!(
        after_restart >= advanced,
        "a restart must never regress the persisted cursor: {after_restart} ms \
         < {advanced} ms"
    );
    assert!(
        after_restart >= opened_at * 1000,
        "and the replayed event must not drag it back down to its created_at"
    );
    // Teardown only: every assertion above has already run, and the drain itself
    // is pinned by the mid-test `assert_ne!` above and by `join_tasks_*` in
    // `session.rs`.
    let _ = engine2.stop().await;
}

// ============================================================================
// R4: the multiplexed bucket floor is MIN(per-circle cursors)
// ============================================================================

/// Builds a real two-member circle whose admin is `alice` — so a location Bob
/// encrypts for it decrypts on Alice's side and surfaces on the live-sync bus.
async fn build_real_circle(
    alice: &Arc<CircleManager>,
    alice_keys: &Keys,
    relays: &[String],
) -> (
    Arc<CircleManager>,
    Keys,
    haven_core::nostr::mls::types::GroupId,
    [u8; 32],
    TempDir,
) {
    let bob_dir = TempDir::new().unwrap();
    let bob_keys = Keys::generate();
    let bob = Arc::new(CircleManager::new_unencrypted(bob_dir.path(), &bob_keys).unwrap());
    let kp_event = build_kp_maintenance_events(
        bob.session(),
        &bob_keys,
        &["wss://kp.example.com".to_string()],
        None,
        None,
    )
    .await
    .expect("bob key package")
    .event;
    let member = MemberKeyPackage {
        key_package_event: kp_event,
        inbox_relays: vec!["wss://inbox.example.com".to_string()],
        nip65_relays: vec![],
    };

    let config = CircleConfig::new("Multiplex Circle").with_relays(relays.to_vec());
    let result = alice
        .create_circle(alice_keys, vec![member], &config, relays)
        .await
        .expect("create circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;
    alice
        .confirm_published(result.pending)
        .await
        .expect("confirm creation");

    let welcome = result
        .welcome_events
        .iter()
        .find(|w| w.recipient_pubkey == bob_keys.public_key().to_hex())
        .expect("welcome for bob");
    bob.process_gift_wrapped_invitation(&bob_keys, &welcome.event)
        .await
        .expect("bob processes the welcome");
    bob.accept_invitation(&welcome.event.id)
        .await
        .expect("bob joins");

    (bob, bob_keys, mls_group_id, nostr_group_id, bob_dir)
}

/// Re-wraps an already-encrypted `kind:445` under a fresh key at
/// `created_at_secs`, KEEPING its NIP-40 `expiration` so it is still live.
///
/// Only the outer envelope changes: the ciphertext, and therefore the inner MLS
/// message, is untouched and still authenticates. This is how the test backdates
/// a genuine event without touching the engine.
fn backdate(observed: &Event, created_at_secs: i64) -> Event {
    EventBuilder::new(observed.kind, observed.content.clone())
        .tags(observed.tags.iter().cloned().collect::<Vec<Tag>>())
        .custom_created_at(Timestamp::from(u64::try_from(created_at_secs).unwrap()))
        .sign_with_keys(&Keys::generate())
        .expect("re-sign the observed ciphertext")
}

/// R4 (per-circle cursor multiplex gap): two circles on ONE relay share a single
/// multiplexed `#h` REQ. A BUSY circle (A) whose cursor is far ahead must NOT
/// raise the bucket floor past a QUIET circle (B) whose older event has not been
/// seen — because the bucket REQ `since` is the MINIMUM across the bucket's
/// per-circle cursors.
///
/// # Why the oracle is the bus and no longer the cursor
///
/// B's cursor now advances on the bucket's EOSE regardless of whether anything
/// was routed, so "B's cursor moved" would be true even if B's event had been
/// filtered out by a floor anchored on A — the assertion would pass for the
/// wrong reason. So B is a REAL circle and its event is a real location: the
/// decrypted `LiveSyncEvent::Location` on the bus can only appear if the relay
/// actually returned an event dated an hour before A's cursor.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn busy_circle_high_cursor_does_not_bury_a_quiet_co_multiplexed_circle() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let alice_keys = Keys::generate();
    let alice = Arc::new(CircleManager::new_unencrypted(dir.path(), &alice_keys).unwrap());

    // B is a REAL circle Alice administers; A is a synthetic co-multiplexed one
    // whose only role is to hold a high cursor.
    let (bob, bob_keys, mls_group_id, ngid_b, _bob_dir) =
        build_real_circle(&alice, &alice_keys, std::slice::from_ref(&url)).await;
    let hex_a = hex::encode([0xA1u8; 32]); // the BUSY circle
    let hex_b = hex::encode(ngid_b); // the QUIET circle
    let key_a = group_cursor_stream(&hex_a);
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

    // Circle A is BUSY: its cursor sits at ~now, far ahead of B's cold seed
    // (now − 24h). If the bucket floor followed A, B's older event would be
    // filtered out by the relay and never delivered.
    let now = now_secs();
    let now_ms = now * 1000;
    alice.advance_sync_cursor(&key_a, now_ms).unwrap();

    // B's event: a genuine location from Bob, re-wrapped so the OUTER envelope
    // is dated an hour ago — below A's cursor, above B's seed.
    let observed = bob
        .encrypt_location(
            &mls_group_id,
            &bob_keys.public_key(),
            &LocationMessage::new(48.85, 2.35),
            600,
        )
        .await
        .expect("bob encrypts a location")
        .0;
    assert!(
        observed
            .tags
            .iter()
            .any(|t| matches!(t.as_standardized(), Some(TagStandard::Expiration(_)))),
        "precondition: the location carries a NIP-40 expiration, so the backdated \
         re-wrap below must keep it or the receiver-side screen would drop it"
    );
    let backdated = backdate(&observed, now - 3600);
    publish(&url, &backdated).await;

    let engine = LiveSyncCore::new_local(Arc::clone(&alice), alice_keys.public_key());
    let mut bus = engine.bus().subscribe();
    engine.start(&specs, &[]).await.expect("start session");

    // The oracle: B's backdated location is decrypted and routed. Only reachable
    // if the multiplexed REQ went back to MIN (B's low seed).
    let mut delivered = false;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    while tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_secs(1), bus.recv()).await {
            Ok(Ok(LiveSyncEvent::Location {
                nostr_group_id,
                sender_pubkey,
                ..
            })) => {
                if nostr_group_id == ngid_b.to_vec()
                    && sender_pubkey == bob_keys.public_key().to_hex()
                {
                    delivered = true;
                    break;
                }
            }
            Ok(Ok(_)) | Err(_) => {}
            Ok(Err(_)) => break,
        }
    }
    assert!(
        delivered,
        "B's older event must be fetched (bucket since = MIN = B's low seed), \
         not buried by A's high cursor"
    );

    // A's cursor was never regressed by the multiplexed re-anchor. (It MAY move
    // forward, on the bucket's own EOSE — that is the anchor working, not a
    // disturbance.)
    assert!(
        alice.read_sync_cursor(&key_a).unwrap().unwrap() >= now_ms,
        "the busy circle's own cursor must never be dragged backwards by the \
         MIN-anchored bucket"
    );

    let _ = engine.stop().await;
}
