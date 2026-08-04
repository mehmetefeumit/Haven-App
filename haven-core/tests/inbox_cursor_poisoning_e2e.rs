//! Inbox (`kind:1059`) sync-cursor integrity against UNAUTHENTICATED input.
//!
//! The companion to `cursor_poisoning_e2e.rs`, which covers the same defect on
//! the `kind:445` group stream. This one is the inbox instance — the last, and
//! the cheapest to exploit.
//!
//! # Who can mint a gift wrap that reaches a victim's inbox
//!
//! Anyone who knows the victim's public key, which is public by design: it is
//! in their `kind:0` profile, their `kind:10002` / `kind:10050` relay lists and
//! every `kind:30443` `KeyPackage` they publish. A gift wrap is routed by a `#p`
//! tag carrying exactly that key, is authored by a throwaway ephemeral key *by
//! construction* (NIP-59), and is peeled with NIP-59 alone — a valid seal over a
//! `kind:444` rumor with a well-formed `e` tag, a well-formed `relays` tag and
//! non-empty base64 content is accepted. **No MLS state is consulted on that
//! path and nothing binds the outer `created_at` to the payload.** So the whole
//! attack costs one NIP-44 encryption to a published npub and one relay
//! publish; no membership, no invitation, no prior relationship.
//!
//! # Why a FUTURE-dated wrap was the whole exploit
//!
//! [`since_for_stream`] caps the derived REQ floor at `now`, so a cursor parked
//! above the wall clock does not produce a future-dated filter — it silently
//! pins EVERY subsequent inbox floor at `now` for the duration of the skew. And
//! NIP-59 *requires* gift wraps to be backdated (rust-nostr randomizes up to
//! 48h into the past), so with the floor at `now` even a wrap published this
//! second falls below it. Invitation delivery stops entirely — permanently, and
//! across restarts, because the advance path is monotonic-max and can never
//! bring the value back down. The 7-day inbox lookback bounds the BACKWARD
//! direction only; here it is subtracted from a number already ahead of the
//! clock.
//!
//! # What replaced it, and what these gates therefore assert
//!
//! The inbox cursor advances on exactly one signal now: the inbox REQ's own
//! `EOSE`, redeemed against the LOCAL clock reading taken when that REQ was
//! issued (`live_sync::anchor::InboxAnchor`). A gift wrap's `created_at` enters
//! in NO direction — it is not even carried across the FFI boundary any more.
//!
//! So the gates come in matched pairs, as in the group file:
//!
//! * a future-dated wrap moves the cursor nowhere near its own timestamp; and
//! * the plane still advances on its own trusted signal, so the first half is
//!   the anchor refusing a remote number and not the advance having been
//!   quietly deleted.
//!
//! Plus the two properties the original defect made durable: the corrected
//! cursor survives a restart, and an install that already took a poisoned value
//! is REPAIRED on the next session start rather than left pinned forever.

use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::CircleManager;
use haven_core::relay::cursor::{
    since_for_stream, SubscribePhase, INBOX_GIFTWRAP_LOOKBACK_SECS, STREAM_INBOX_1059,
};
use haven_core::relay::live_sync::{LiveSyncCore, LiveSyncEvent, StopOutcome};
use nostr::{Event, EventBuilder, Keys, Kind, PublicKey, Tag, Timestamp};
use nostr_relay_builder::MockRelay;
use nostr_sdk::Client;
use tempfile::TempDir;

fn now_secs() -> i64 {
    i64::try_from(Timestamp::now().as_secs()).unwrap()
}

/// Mirrors `live_sync::session::SEED_LOOKBACK_SECS` (private): the cold-start
/// floor `start` installs on an unseeded cursor. Only used to know what value
/// the EOSE anchor has to beat.
const COLD_SEED_LOOKBACK_SECS: i64 = 86_400;

/// A `kind:1059` routed at `recipient`'s `#p` tag, minted by a throwaway key
/// that belongs to nobody, at a `created_at` of the caller's choosing.
///
/// Deliberately NOT a real NIP-59 wrap: nothing in the receive path being
/// gated here looks at the ciphertext. The relay routes on `#p` and the kind,
/// the live worker hands the JSON to the consumer, and the cursor question —
/// the only thing under test — is settled before any peel is attempted. Using
/// an opaque body keeps the fixture to the two fields an attacker actually
/// controls: the routing tag and the timestamp.
fn routed_giftwrap_at(recipient: PublicKey, created_at_secs: i64) -> Event {
    EventBuilder::new(Kind::GiftWrap, "b3BhcXVl")
        .tags(vec![Tag::public_key(recipient)])
        .custom_created_at(Timestamp::from(u64::try_from(created_at_secs).unwrap()))
        .sign_with_keys(&Keys::generate())
        .unwrap()
}

async fn publish(url: &str, event: &Event) {
    let publisher = Client::builder().build();
    publisher.add_relay(url).await.unwrap();
    publisher.connect().await;
    publisher.send_event(event).await.expect("publish");
}

/// Waits (bounded) for a `Welcome` to surface on the engine bus — i.e. for a
/// routed gift wrap to have travelled relay → receiver → worker → consumer.
async fn wait_for_welcome(
    bus: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>,
    budget: Duration,
) -> bool {
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return false;
        }
        // A timeout ends the wait; anything else is judged on what it carried.
        let Ok(received) = tokio::time::timeout(remaining, bus.recv()).await else {
            return false;
        };
        match received {
            Ok(LiveSyncEvent::Welcome { .. }) => return true,
            // Any other event, or a LAGGED bus (events dropped — not evidence
            // either way): keep waiting within the budget.
            Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
            Err(tokio::sync::broadcast::error::RecvError::Closed) => return false,
        }
    }
}

/// Polls the inbox cursor until it exceeds `floor` (or the budget elapses).
async fn wait_inbox_cursor_above(
    manager: &CircleManager,
    floor: Option<i64>,
    budget: Duration,
) -> Option<i64> {
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        let cur = manager.read_sync_cursor(STREAM_INBOX_1059).ok().flatten();
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

/// THE GATE. A gift wrap dated far in the future is delivered on the inbox
/// subscription; the persisted cursor must land on the REQ's own local open
/// time, nowhere near the wrapper's timestamp — and the derived REQ floor must
/// keep its full 7-day lookback rather than collapsing to `now`.
///
/// Both halves matter. The first is the anchor refusing the remote number; the
/// second is the CONSEQUENCE the defect actually had, asserted directly, so a
/// future change that keeps the cursor "small enough" but still ahead of the
/// clock cannot pass.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_future_dated_gift_wrap_never_pushes_the_inbox_cursor_past_the_local_clock() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
    let own = Keys::generate().public_key();

    // A year ahead: far enough that no clock-skew tolerance anywhere could
    // excuse it, and far enough that `cursor - 7d` is still in the future.
    let forged_secs = now_secs() + 365 * 86_400;
    publish(&url, &routed_giftwrap_at(own, forged_secs)).await;

    let opened_at = now_secs();
    let engine = LiveSyncCore::new_local(Arc::clone(&circle), own);
    // Subscribe BEFORE start so the stored replay cannot be missed.
    let mut bus = engine.bus().subscribe();
    engine
        .start(&[], std::slice::from_ref(&url))
        .await
        .expect("start session");

    // Anti-vacuity, the load-bearing one: the forged wrap must actually reach
    // the receive path. If the relay never served it (or the `#p` filter never
    // matched), every cursor assertion below would hold for the trivial reason
    // that nothing was delivered — and the defect this file pins would be
    // untested rather than fixed.
    let delivered = wait_for_welcome(&mut bus, Duration::from_secs(10)).await;
    assert!(
        delivered,
        "precondition: the future-dated gift wrap must have been DELIVERED on \
         the inbox subscription, or the cursor gates below prove nothing"
    );

    // `start` cold-seeds the inbox cursor to `now - 24h`; the EOSE anchor then
    // raises it to the REQ's open time. Comparing against the seed VALUE rather
    // than a read-back makes the anti-vacuity check race-free — by the time the
    // welcome above surfaced, the EOSE may already have landed, so a read-back
    // "before" would sample the advanced value and the comparison would be
    // trivially false.
    let cold_seed_ms = (opened_at - COLD_SEED_LOOKBACK_SECS) * 1000;
    let advanced = wait_inbox_cursor_above(&circle, Some(cold_seed_ms), Duration::from_secs(10))
        .await
        .expect("start seeds the inbox cursor, so it always reads back");

    // Anti-vacuity: the advance still happens on its own trusted signal.
    // Without this the assertions below would pass just as well if the inbox
    // advance had been deleted outright.
    assert!(
        advanced > cold_seed_ms,
        "the inbox subscription's EOSE must advance the cursor off its cold \
         seed of {cold_seed_ms} ms (otherwise every assertion below holds \
         vacuously); got {advanced} ms"
    );

    // THE INVARIANT.
    let settled = now_secs();
    assert!(
        advanced <= settled * 1000,
        "the inbox cursor must never sit above the local wall clock: got \
         {advanced} ms against a clock of {settled} s. The delivered wrap was \
         dated {forged_secs} s, which is what the defect wrote."
    );
    assert!(
        advanced >= opened_at * 1000,
        "and it must land on the REQ's own local open time ({opened_at} s), \
         not below it: {advanced} ms"
    );
    assert!(
        advanced < forged_secs * 1000,
        "the wrapper's remotely-chosen created_at ({forged_secs} s) must not \
         appear in the cursor at all: {advanced} ms"
    );

    // THE CONSEQUENCE, asserted directly. A cursor ahead of the clock collapses
    // the inbox lookback to nothing, and NIP-59 backdates every genuine wrap by
    // up to 48h — so a floor at `now` hides even one published this second.
    let floor = since_for_stream(
        STREAM_INBOX_1059,
        advanced,
        SubscribePhase::Resubscribe,
        settled,
    );
    assert!(
        floor <= settled - INBOX_GIFTWRAP_LOOKBACK_SECS + 60,
        "the derived inbox REQ floor must keep its full 7-day lookback \
         (expected ≈ {}, got {floor}); a floor pinned at {settled} would filter \
         out every NIP-59-backdated invitation, permanently",
        settled - INBOX_GIFTWRAP_LOOKBACK_SECS,
    );

    let _ = engine.stop().await;
}

/// A gift wrap delivered LIVE — after this generation's EOSE has been redeemed
/// — must move the cursor nowhere.
///
/// The generation's one advance is already spent, and a live delivery carries no
/// completeness claim of its own. Under the defect this was the second lever:
/// every arriving wrap re-raised the cursor to its own timestamp, so the
/// attacker did not even need to win a race with the stored replay.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_live_gift_wrap_after_eose_moves_the_inbox_cursor_nowhere() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
    let own = Keys::generate().public_key();

    let started_at = now_secs();
    let engine = LiveSyncCore::new_local(Arc::clone(&circle), own);
    engine
        .start(&[], std::slice::from_ref(&url))
        .await
        .expect("start session");

    // Against the cold-seed VALUE, not a read-back: a read-back taken after the
    // EOSE has already landed would sample the advanced value and make the
    // precondition trivially false. See the first test.
    let cold_seed_ms = (started_at - COLD_SEED_LOOKBACK_SECS) * 1000;
    let anchored = wait_inbox_cursor_above(&circle, Some(cold_seed_ms), Duration::from_secs(10))
        .await
        .expect("cursor reads back");
    assert!(
        anchored > cold_seed_ms,
        "precondition: the EOSE anchor must have been redeemed already"
    );

    // Let whole seconds pass so a per-event advance would be unmistakable.
    tokio::time::sleep(Duration::from_secs(3)).await;
    let live_secs = now_secs() + 86_400;
    assert!(
        live_secs * 1000 > anchored,
        "precondition: the live wrap must be dated strictly above the anchored \
         cursor, or a per-event advance would be invisible here"
    );
    publish(&url, &routed_giftwrap_at(own, live_secs)).await;
    tokio::time::sleep(Duration::from_secs(3)).await;

    assert_eq!(
        circle.read_sync_cursor(STREAM_INBOX_1059).unwrap(),
        Some(anchored),
        "a delivered gift wrap must move the inbox cursor NOWHERE: its outer \
         created_at ({live_secs} s) is chosen by whoever wrapped it, and a wrap \
         that reaches this subscription costs one encryption to a published npub"
    );

    let _ = engine.stop().await;
}

/// The anchored advance persists across a session restart and never regresses —
/// and a second session does not re-advance past what it earned.
///
/// The original defect's damage was durable (a poisoned cursor survived every
/// restart), so its fix has to be durable too.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_anchored_inbox_cursor_survives_a_restart() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
    let own = Keys::generate().public_key();

    publish(&url, &routed_giftwrap_at(own, now_secs() + 365 * 86_400)).await;

    let started_at = now_secs();
    let engine1 = LiveSyncCore::new_local(Arc::clone(&circle), own);
    engine1
        .start(&[], std::slice::from_ref(&url))
        .await
        .expect("start session 1");
    let cold_seed_ms = (started_at - COLD_SEED_LOOKBACK_SECS) * 1000;
    let advanced = wait_inbox_cursor_above(&circle, Some(cold_seed_ms), Duration::from_secs(10))
        .await
        .expect("cursor reads back");
    assert!(advanced > cold_seed_ms, "precondition: the anchor redeemed");

    // Rule 14 (single live session per MLS DB): session 2 re-opens the SAME
    // store, so session 1's supervisor tasks must be joined first.
    assert_ne!(
        engine1.stop().await,
        StopOutcome::TimedOut,
        "session 1 must be fully drained before session 2 opens the same store"
    );
    assert_eq!(
        circle.read_sync_cursor(STREAM_INBOX_1059).unwrap(),
        Some(advanced),
        "the anchored cursor must persist across a session teardown"
    );

    // Reopen the STORE, not just the session: the persisted value has to come
    // back off disk, which is where the defect's damage lived. The engine holds
    // its own `Arc<CircleManager>`, so it has to go too before the Rule-14
    // single-session guard will let the file be reopened.
    drop(engine1);
    drop(circle);
    tokio::time::sleep(Duration::from_millis(50)).await;
    let reopened = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).expect("reopen"));
    assert_eq!(
        reopened.read_sync_cursor(STREAM_INBOX_1059).unwrap(),
        Some(advanced),
        "and across a full process restart"
    );

    let engine2 = LiveSyncCore::new_local(Arc::clone(&reopened), own);
    engine2
        .start(&[], std::slice::from_ref(&url))
        .await
        .expect("start session 2");
    tokio::time::sleep(Duration::from_millis(500)).await;
    let after_restart = reopened
        .read_sync_cursor(STREAM_INBOX_1059)
        .unwrap()
        .unwrap();
    assert!(
        after_restart >= advanced,
        "a restart must never regress the persisted cursor: {after_restart} ms \
         < {advanced} ms"
    );
    assert!(
        after_restart <= now_secs() * 1000,
        "and the replayed future-dated wrap must not drag it above the clock on \
         the second pass either: {after_restart} ms"
    );

    let _ = engine2.stop().await;
}

/// An install that ALREADY carries a poisoned cursor is repaired on the next
/// session start.
///
/// Deleting the write path stops new poisoning but does nothing for a device
/// that took one before the fix — and nothing in the advance path can ever undo
/// it, because that path is monotonic-max. Without this repair such an install
/// stays pinned at `now` for as long as the attacker's timestamp says, which is
/// as long as they like.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_cursor_poisoned_by_a_pre_fix_build_is_repaired_on_the_next_start() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
    let own = Keys::generate().public_key();

    // Exactly what the pre-fix path wrote: the wrap's outer `created_at`, in ms,
    // unclamped. A year ahead.
    let poisoned_secs = now_secs() + 365 * 86_400;
    circle
        .advance_sync_cursor(STREAM_INBOX_1059, poisoned_secs * 1000)
        .expect("plant the poisoned cursor");

    // Precondition: this really is the failure mode. With the cursor a year
    // ahead, the derived REQ floor collapses onto `now` — and NIP-59 backdates
    // every genuine wrap, so a floor at `now` filters all of them out.
    let before = now_secs();
    assert_eq!(
        since_for_stream(
            STREAM_INBOX_1059,
            poisoned_secs * 1000,
            SubscribePhase::Initial,
            before
        ),
        before,
        "precondition: a future cursor must pin the floor at `now`, or this \
         test is not about the defect"
    );

    let engine = LiveSyncCore::new_local(Arc::clone(&circle), own);
    engine
        .start(&[], std::slice::from_ref(&url))
        .await
        .expect("start session");

    let repaired = circle
        .read_sync_cursor(STREAM_INBOX_1059)
        .unwrap()
        .expect("cursor present");
    let after = now_secs();
    assert!(
        repaired <= after * 1000,
        "the poisoned cursor must be clamped back to the local clock on start: \
         got {repaired} ms against a clock of {after} s"
    );
    assert!(
        repaired < poisoned_secs * 1000,
        "precondition: the clamp must actually have moved it off {poisoned_secs} s"
    );
    let floor = since_for_stream(STREAM_INBOX_1059, repaired, SubscribePhase::Initial, after);
    assert!(
        floor <= after - INBOX_GIFTWRAP_LOOKBACK_SECS + 60,
        "and the repaired cursor must restore the full 7-day lookback \
         (expected ≈ {}, got {floor})",
        after - INBOX_GIFTWRAP_LOOKBACK_SECS,
    );

    let _ = engine.stop().await;
}

/// A session start never LOWERS a healthy inbox cursor.
///
/// The complement of the test above, and the reason the repair is a conditional
/// UPDATE rather than a reset: "re-floor the inbox cursor on every start" would
/// also "fix" the poisoning, and would silently re-open a window the device had
/// already closed on every launch — the same availability failure from the
/// other side, self-inflicted every time the app opens.
///
/// The narrower "conditional, not unconditional" property is pinned at the
/// storage layer (`sync_cursor_clamp_lowers_only_a_cursor_above_the_bound`),
/// where it is observable: end-to-end, an unconditional clamp to `now` and the
/// legitimate EOSE advance to `now` land on the same value.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_start_never_lowers_a_healthy_inbox_cursor() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();

    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
    let own = Keys::generate().public_key();

    // A perfectly ordinary cursor: an hour old, comfortably below the clock.
    let healthy_ms = (now_secs() - 3600) * 1000;
    circle
        .advance_sync_cursor(STREAM_INBOX_1059, healthy_ms)
        .expect("plant a healthy cursor");

    let engine = LiveSyncCore::new_local(Arc::clone(&circle), own);
    engine
        .start(&[], std::slice::from_ref(&url))
        .await
        .expect("start session");

    // Read it immediately, before the EOSE anchor can legitimately raise it.
    let after_start = circle
        .read_sync_cursor(STREAM_INBOX_1059)
        .unwrap()
        .expect("cursor present");
    assert!(
        after_start >= healthy_ms,
        "the future-cursor repair must leave a healthy cursor alone: \
         {after_start} ms < {healthy_ms} ms"
    );

    let _ = engine.stop().await;
}
