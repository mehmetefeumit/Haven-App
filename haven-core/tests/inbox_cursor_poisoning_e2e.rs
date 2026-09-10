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
//! bring the value back down. The inbox lookback bounds the BACKWARD
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
//!
//! # The other half: the floor must stay LOW ENOUGH
//!
//! Everything above is about a floor pushed too HIGH. The bounded re-subscribe
//! lookback (`INBOX_RESUBSCRIBE_LOOKBACK_SECS`) moves the floor deliberately
//! upward — a re-anchor asks for 49 h, not 7 days — so the last three gates in
//! this file assert the opposite direction: what the narrowed window must still
//! reach. They are the availability counterweight to the poisoning gates, and
//! they are in this file rather than a new one precisely because the two
//! directions have to be read together.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use haven_core::circle::CircleManager;
use haven_core::relay::cursor::{
    since_for_stream, SubscribePhase, INBOX_GIFTWRAP_LOOKBACK_SECS,
    INBOX_RESUBSCRIBE_LOOKBACK_SECS, STREAM_INBOX_1059,
};
use haven_core::relay::live_sync::{LiveSyncCore, LiveSyncEvent, StopOutcome};
use nostr::nips::nip59::RANGE_RANDOM_TIMESTAMP_TWEAK;
use nostr::{
    Event, EventBuilder, EventId, Filter, JsonUtil, Keys, Kind, PublicKey, Tag, Timestamp,
};
use nostr_relay_builder::prelude::{
    BoxedFuture, MemoryDatabase, MemoryDatabaseOptions, NostrDatabase, PolicyResult, QueryPolicy,
};
use nostr_relay_builder::{LocalRelay, MockRelay, RelayBuilder};
use nostr_sdk::Client;
use tempfile::TempDir;

fn now_secs() -> i64 {
    i64::try_from(Timestamp::now().as_secs()).unwrap()
}

/// Mirrors `live_sync::session::SEED_LOOKBACK_SECS` (private): the cold-start
/// floor `start` installs on an unseeded cursor. Only used to know what value
/// the EOSE anchor has to beat.
const COLD_SEED_LOOKBACK_SECS: i64 = 86_400;

/// Scales the wall-clock budget of the waits below.
///
/// Every `wait_*` in this file bounds how long a DELIVERY may take; none of
/// them is the property under test. That distinction is what makes scaling
/// them safe: the assertion is always "the thing arrived", so a larger budget
/// can only remove a false negative — it can never let a broken build pass,
/// because a delivery that never happens still exhausts any budget.
///
/// The budgets are sized for an uninstrumented build, where the whole target
/// runs in ~7s. Under `cargo llvm-cov` every basic block carries counter
/// updates, so the scale absorbs that.
///
/// It absorbs slowness and nothing else. An earlier version of this comment
/// blamed the bound for the flake in CI runs 31216078806 and 31555665220 —
/// "the bound was the problem, not the code under it" — and that was wrong.
/// The code under it was the problem: the engine `Client` enabled nostr-sdk's
/// `verify_subscriptions`, which discards the stored events a REQ replays
/// before nostr-relay-pool registers that REQ's filter. Measured against a
/// 120-second budget the forged wrap still never arrived: delivery was ~1ms or
/// never, so no bound could have fixed it. See `build_engine_client` and
/// `scripts/ci/check_engine_client_options.sh`.
///
/// Set by the coverage workflow. Absent or unparsable means 1, so an ordinary
/// `cargo test` keeps today's fast feedback.
fn wait_scale() -> u32 {
    std::env::var("HAVEN_TEST_WAIT_SCALE")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|s| *s >= 1)
        .unwrap_or(1)
}

/// A delivery budget of `base_secs`, scaled for instrumented runs.
fn wait_budget(base_secs: u64) -> Duration {
    Duration::from_secs(base_secs * u64::from(wait_scale()))
}

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

/// Waits (bounded) until every id in `expected` has surfaced as a `Welcome`,
/// returning whatever is still missing when the budget runs out.
///
/// Plural because a fixture set that differs only in `created_at` is exactly how
/// a lookback WIDTH is probed: [`wait_for_welcome`] returning on the first
/// arrival cannot tell "both were fetched" from "the shallower one was".
async fn wait_for_welcomes(
    bus: &mut tokio::sync::broadcast::Receiver<LiveSyncEvent>,
    expected: &[EventId],
    budget: Duration,
) -> Vec<EventId> {
    let mut missing: Vec<EventId> = expected.to_vec();
    let deadline = tokio::time::Instant::now() + budget;
    while !missing.is_empty() {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        let Ok(received) = tokio::time::timeout(remaining, bus.recv()).await else {
            break;
        };
        match received {
            Ok(LiveSyncEvent::Welcome { gift_wrap_json }) => {
                if let Ok(event) = Event::from_json(&gift_wrap_json) {
                    missing.retain(|id| *id != event.id);
                }
            }
            Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
        }
    }
    missing
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
/// keep its full per-phase lookback rather than collapsing to `now`.
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
    let after_start = now_secs();

    // Anti-vacuity, the load-bearing one: the forged wrap must actually reach
    // the receive path. If the relay never served it (or the `#p` filter never
    // matched), every cursor assertion below would hold for the trivial reason
    // that nothing was delivered — and the defect this file pins would be
    // untested rather than fixed.
    let delivered = wait_for_welcome(&mut bus, wait_budget(10)).await;
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
    //
    // The seed value has to be bounded from ABOVE, though, and `opened_at` is a
    // bound from below: `start` reads its OWN clock (`live_sync::session`,
    // `SEED_LOOKBACK_SECS`) after this test read `opened_at`, so under load the
    // two readings differ and the seed lands strictly above
    // `(opened_at - 24h) * 1000` — whereupon the wait returns on the SEED and
    // the anti-vacuity check passes on exactly the value it exists to exclude.
    // (The gate below then fails on the seed, which is how this surfaced.) The
    // clock read once `start` returned bounds the engine's reading from above,
    // so no seed can exceed `max_cold_seed_ms` and the advance — anchored at the
    // REQ's open time, itself at or after `opened_at` — clears it by a full 24h.
    let max_cold_seed_ms = (after_start - COLD_SEED_LOOKBACK_SECS) * 1000;
    let advanced = wait_inbox_cursor_above(&circle, Some(max_cold_seed_ms), wait_budget(10))
        .await
        .expect("start seeds the inbox cursor, so it always reads back");

    // Anti-vacuity: the advance still happens on its own trusted signal.
    // Without this the assertions below would pass just as well if the inbox
    // advance had been deleted outright.
    assert!(
        advanced > max_cold_seed_ms,
        "the inbox subscription's EOSE must advance the cursor off its cold \
         seed, which cannot exceed {max_cold_seed_ms} ms (otherwise every \
         assertion below holds vacuously); got {advanced} ms"
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

    // THE CONSEQUENCE, asserted directly, in BOTH phases. A cursor ahead of the
    // clock collapses the inbox lookback to nothing, and NIP-59 backdates every
    // genuine wrap by up to 48h — so a floor at `now` hides even one published
    // this second. The two phases now buy different widths, and the poisoning
    // has to be excluded from each of them: a `Resubscribe`-only check would
    // leave every cold start unguarded, and vice versa.
    for (phase, lookback) in [
        (SubscribePhase::Initial, INBOX_GIFTWRAP_LOOKBACK_SECS),
        (SubscribePhase::Resubscribe, INBOX_RESUBSCRIBE_LOOKBACK_SECS),
    ] {
        let floor = since_for_stream(STREAM_INBOX_1059, advanced, phase, settled);
        assert!(
            floor <= settled - lookback + 60,
            "the derived inbox REQ floor must keep {phase:?}'s full {lookback} s \
             lookback (expected ≈ {}, got {floor}); a floor pinned at {settled} \
             would filter out every NIP-59-backdated invitation, permanently",
            settled - lookback,
        );
    }

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

    let engine = LiveSyncCore::new_local(Arc::clone(&circle), own);
    engine
        .start(&[], std::slice::from_ref(&url))
        .await
        .expect("start session");
    let after_start = now_secs();

    // Against an UPPER BOUND on the cold-seed value, not a read-back: a
    // read-back taken after the EOSE has already landed would sample the
    // advanced value and make the precondition trivially false, and a bound
    // taken before `start` would be a LOWER one, letting the seed itself
    // satisfy the wait. See the first test.
    let max_cold_seed_ms = (after_start - COLD_SEED_LOOKBACK_SECS) * 1000;
    let anchored = wait_inbox_cursor_above(&circle, Some(max_cold_seed_ms), wait_budget(10))
        .await
        .expect("cursor reads back");
    assert!(
        anchored > max_cold_seed_ms,
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

    let engine1 = LiveSyncCore::new_local(Arc::clone(&circle), own);
    engine1
        .start(&[], std::slice::from_ref(&url))
        .await
        .expect("start session 1");
    // An UPPER bound on the cold seed, read once `start` returned — see the
    // first test for why a reading taken before it is the wrong direction.
    let max_cold_seed_ms = (now_secs() - COLD_SEED_LOOKBACK_SECS) * 1000;
    let advanced = wait_inbox_cursor_above(&circle, Some(max_cold_seed_ms), wait_budget(10))
        .await
        .expect("cursor reads back");
    assert!(
        advanced > max_cold_seed_ms,
        "precondition: the anchor redeemed"
    );

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
    for (phase, lookback) in [
        (SubscribePhase::Initial, INBOX_GIFTWRAP_LOOKBACK_SECS),
        (SubscribePhase::Resubscribe, INBOX_RESUBSCRIBE_LOOKBACK_SECS),
    ] {
        let floor = since_for_stream(STREAM_INBOX_1059, repaired, phase, after);
        assert!(
            floor <= after - lookback + 60,
            "and the repaired cursor must restore {phase:?}'s full {lookback} s \
             lookback (expected ≈ {}, got {floor})",
            after - lookback,
        );
    }

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

// ---------------------------------------------------------------------------
// The bounded re-subscribe lookback: what the narrowed floor must still reach.
// ---------------------------------------------------------------------------

/// NIP-59's maximum backdate, read from the PINNED CRATE, not written down: a
/// sender subtracts a uniform offset in `0..RANGE_RANDOM_TIMESTAMP_TWEAK` from
/// the wrapper's build time, so this is the largest gap a conformant sender can
/// put between a wrap's ARRIVAL and its `created_at`. A crate bump that widens
/// it makes the fixtures below reach past the bound and these gates go red —
/// which is the whole point of not hard-coding 172 800.
fn max_nip59_backdate_secs() -> i64 {
    i64::try_from(RANGE_RANDOM_TIMESTAMP_TWEAK.end).expect("the tweak range fits in i64")
}

/// Records the `since` of every `kind:1059` REQ the relay is asked to serve.
///
/// A `QueryPolicy` runs on the REQ itself, before any event is matched, so it
/// observes the FILTER this device actually put on the wire — the only place
/// the derived floor is observable from outside `haven-core`. Reading the
/// delivered events instead could not tell "asked for 49 h" from "asked for 7
/// days and the extra five days happened to be empty".
#[derive(Debug)]
struct RecordInboxSince {
    /// One entry per inbox REQ, in arrival order. `None` = a REQ with no
    /// `since` at all, i.e. the forbidden "send all history" window.
    seen: Arc<Mutex<Vec<Option<i64>>>>,
}

impl QueryPolicy for RecordInboxSince {
    fn admit_query<'a>(
        &'a self,
        query: &'a Filter,
        _addr: &'a SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        if query
            .kinds
            .as_ref()
            .is_some_and(|kinds| kinds.contains(&Kind::GiftWrap))
        {
            let since = query
                .since
                .map(|t| i64::try_from(t.as_secs()).unwrap_or(i64::MAX));
            self.seen.lock().expect("recorder mutex").push(since);
        }
        Box::pin(async { PolicyResult::Accept })
    }
}

/// An inbox relay whose store the test seeds DIRECTLY and whose inbox REQ
/// floors it records.
///
/// Seeding through the shared `MemoryDatabase` rather than over a socket is
/// what makes these gates about the REQ FLOOR: a relay pushes an event to a
/// live subscription when a client hands it one over the wire, so an event that
/// never crossed a socket has no live-delivery path at all. The only way it can
/// reach the device is a REQ whose `since` admits it — which is exactly the
/// number under test. (Same construction as `catchup_sweep_e2e::SeededRelay`.)
struct InboxRelay {
    _relay: LocalRelay,
    url: String,
    db: MemoryDatabase,
    seen: Arc<Mutex<Vec<Option<i64>>>>,
}

impl InboxRelay {
    async fn run() -> Self {
        let _ = haven_core::relay::allow_ws_loopback_for_test();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let db = MemoryDatabase::with_opts(MemoryDatabaseOptions {
            events: true,
            max_events: None,
        });
        let relay = LocalRelay::new(RelayBuilder::default().database(db.clone()).query_policy(
            RecordInboxSince {
                seen: Arc::clone(&seen),
            },
        ));
        relay.run().await.expect("local relay runs");
        let url = relay.url().await.to_string();
        Self {
            _relay: relay,
            url,
            db,
            seen,
        }
    }

    /// Stores `event` verbatim, bypassing the socket. A rejected save would
    /// make every assertion below hold for the wrong reason, so it is asserted.
    async fn seed(&self, event: &Event) {
        assert!(
            self.db.save_event(event).await.expect("seed").is_success(),
            "the relay must really hold the seeded wrap, or the fetch under \
             test has nothing to fetch"
        );
    }

    /// The inbox REQ floors recorded so far, oldest first.
    fn inbox_since_values(&self) -> Vec<Option<i64>> {
        self.seen.lock().expect("recorder mutex").clone()
    }

    /// Waits (bounded) until at least `count` inbox REQs have been recorded,
    /// then returns them. Bounds a DELIVERY, never the property under test.
    async fn wait_for_inbox_reqs(&self, count: usize, budget: Duration) -> Vec<Option<i64>> {
        let deadline = tokio::time::Instant::now() + budget;
        loop {
            let seen = self.inbox_since_values();
            if seen.len() >= count || tokio::time::Instant::now() >= deadline {
                return seen;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
}

/// Starts an engine on `relay` with no circles and waits for the inbox anchor
/// to redeem its first EOSE, returning the engine and the cursor (ms) it landed
/// on.
///
/// `planted_cursor_secs` is written first so the FIRST REQ's floor is an exact
/// number the caller chose, rather than one derived from whatever `start`'s
/// cold seed happened to compute against its own clock read.
async fn engine_anchored_on(
    circle: &Arc<CircleManager>,
    own: PublicKey,
    relays: &[String],
    planted_cursor_secs: i64,
) -> (LiveSyncCore, i64) {
    let planted_ms = planted_cursor_secs * 1000;
    circle
        .advance_sync_cursor(STREAM_INBOX_1059, planted_ms)
        .expect("plant a healthy cursor");

    let engine = LiveSyncCore::new_local(Arc::clone(circle), own);
    engine.start(&[], relays).await.expect("start session");

    let anchored = wait_inbox_cursor_above(circle, Some(planted_ms), wait_budget(10))
        .await
        .expect("the planted cursor always reads back");
    assert!(
        anchored > planted_ms,
        "precondition: the inbox REQ's EOSE must have advanced the cursor off \
         the planted value ({planted_ms} ms); got {anchored} ms"
    );
    (engine, anchored)
}

/// THE BOUND. A re-anchor asks for 2 days + 1 hour; only a store with no inbox
/// cursor at all asks for seven days
/// (`a_first_ever_start_with_no_cursor_asks_for_seven_days`).
///
/// Asserted at the RELAY, on the filter this device put on the wire, and by
/// EXACT VALUE — "narrower than before" would pass just as well for a bound of
/// one second, which would drop every conformant invitation.
///
/// Why it matters beyond bytes: the foreground resume, every relay-`CLOSED`
/// repair and the 15-minute health tick all re-anchor, so at 7 days this device
/// re-advertises the one query that links its npub to itself — and replays a
/// week of gift wraps — several times an hour.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_resubscribe_asks_for_two_days_plus_an_hour_never_seven() {
    let relay = InboxRelay::run().await;

    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
    let own = Keys::generate().public_key();

    let planted_secs = now_secs() - 600;
    let (engine, anchored_ms) =
        engine_anchored_on(&circle, own, std::slice::from_ref(&relay.url), planted_secs).await;

    engine
        .resume_after_background()
        .await
        .expect("re-anchor succeeds");
    let seen = relay.wait_for_inbox_reqs(2, wait_budget(10)).await;

    assert_eq!(
        seen.len(),
        2,
        "precondition: exactly two inbox REQs — the start's and the re-anchor's \
         — must have reached the relay; got {seen:?}"
    );
    // Against LITERAL widths, deliberately. An expectation written as
    // `cursor - INBOX_RESUBSCRIBE_LOOKBACK_SECS` moves with the constant, so it
    // would keep passing for a bound of zero — the value that drops every
    // conformant invitation.
    assert_eq!(
        seen[0],
        Some(planted_secs - 176_400),
        "a start over an ALREADY-KNOWN cursor is a re-anchor too: the cursor \
         outlives the process, so it — not the freshness of the engine — is \
         what decides the width"
    );
    assert_eq!(
        seen[1],
        Some(anchored_ms.div_euclid(1000) - 176_400),
        "and the RE-ANCHOR asks from its own anchored cursor minus 49 h — \
         exactly, not approximately"
    );

    let seven_day_floor = anchored_ms.div_euclid(1000) - 604_800;
    assert!(
        seen[1].expect("a since is always present") > seven_day_floor,
        "the re-anchor must NOT replay seven days ({seven_day_floor}); that \
         replay rode every foreground resume, every CLOSED repair and every \
         health tick"
    );

    let _ = engine.stop().await;
}

/// The seven days, where they are actually spent: a store with NO inbox cursor.
///
/// This is the one width that can recover a wrap backdated further than 49 h,
/// and it is the width `CircleStorage::PROCESSED_GIFT_WRAP_RETENTION_SECS` is
/// derived from, so it needs its own wire-level gate rather than riding on the
/// first REQ of a fixture that plants a cursor.
///
/// A two-sided bound, not an equality: the floor is `start`'s OWN clock read
/// minus the 24 h cold seed minus the lookback, and the two readings taken
/// around `start` bracket that read exactly. Both bounds are 604 800 s wide
/// apart from the seed, so a 49-hour floor misses the window by five days.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_first_ever_start_with_no_cursor_asks_for_seven_days() {
    let relay = InboxRelay::run().await;

    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
    let own = Keys::generate().public_key();
    assert_eq!(
        circle.read_sync_cursor(STREAM_INBOX_1059).unwrap(),
        None,
        "precondition: the store must carry no inbox cursor, or this asserts \
         the wrong phase"
    );

    let before = now_secs();
    let engine = LiveSyncCore::new_local(Arc::clone(&circle), own);
    engine
        .start(&[], std::slice::from_ref(&relay.url))
        .await
        .expect("start session");
    let after = now_secs();

    let seen = relay.wait_for_inbox_reqs(1, wait_budget(10)).await;
    let floor = seen
        .first()
        .copied()
        .flatten()
        .expect("the cold start must put a since on the wire, never send-all-history");
    let lowest = before - COLD_SEED_LOOKBACK_SECS - 604_800;
    let highest = after - COLD_SEED_LOOKBACK_SECS - 604_800;
    assert!(
        (lowest..=highest).contains(&floor),
        "a store with no inbox cursor must ask from its cold seed minus the \
         full seven days, i.e. within [{lowest}, {highest}]; got {floor}"
    );

    let _ = engine.stop().await;
}

/// THE RESTART GATE. A fresh engine over a store that ALREADY has an inbox
/// cursor asks 49 hours — not the seven days a cold start pays.
///
/// The engine is no longer a process-lifetime thing: turning background sharing
/// off stops it, and the next foreground glance builds a new core and calls
/// `start` again. Keying the inbox width on "is this core fresh" rather than
/// "is the cursor known" therefore bought a seven-day gift-wrap replay, keyed on
/// this device's `#p`, on every one of those cycles — and undebounced, because
/// the 60 s resume gate guards `resume_after_background`, which no-ops on a
/// stopped engine.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restart_on_a_known_cursor_asks_for_forty_nine_hours_not_seven_days() {
    let relay = InboxRelay::run().await;

    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
    let own = Keys::generate().public_key();

    let (engine1, _) = engine_anchored_on(
        &circle,
        own,
        std::slice::from_ref(&relay.url),
        now_secs() - 600,
    )
    .await;

    // Rule 14 (single live session per MLS DB): session 1's supervisor tasks
    // must be joined before a second core runs against the same store.
    assert_ne!(
        engine1.stop().await,
        StopOutcome::TimedOut,
        "session 1 must be fully drained before session 2 starts"
    );
    let carried_secs = circle
        .read_sync_cursor(STREAM_INBOX_1059)
        .unwrap()
        .expect("session 1 anchored a cursor")
        .div_euclid(1000);

    let engine2 = LiveSyncCore::new_local(Arc::clone(&circle), own);
    engine2
        .start(&[], std::slice::from_ref(&relay.url))
        .await
        .expect("start session 2");

    let seen = relay.wait_for_inbox_reqs(2, wait_budget(10)).await;
    assert_eq!(
        seen.len(),
        2,
        "precondition: exactly two inbox REQs — one per session — must have \
         reached the relay; got {seen:?}"
    );
    assert_eq!(
        seen[1],
        Some(carried_secs - 176_400),
        "the RESTART must ask from the persisted cursor minus 49 h. A literal, \
         so a bound that slides with the constant cannot hide here — and the \
         value this replaces was {} (seven days), asked on every sharing-off \
         glance cycle",
        carried_secs - 604_800,
    );

    let _ = engine2.stop().await;
}

/// A wrap that reached the relay AFTER the last EOSE, backdated by the NIP-59
/// maximum, is still fetched by the bounded re-anchor — and so is the same wrap
/// from a sender whose clock is nearly an hour slow.
///
/// Two fixtures, because the constant has two summands and each buys a distinct
/// guarantee:
///
/// * `cursor − 48 h` is what a CONFORMANT sender with an accurate clock
///   produces at the worst end of `RANGE_RANDOM_TIMESTAMP_TWEAK`. Two days of
///   lookback is what covers it.
/// * `cursor − 48 h − 59 m 59 s` is the same wrap from a sender whose clock is
///   slow by just under the margin. The extra hour is the ONLY thing that
///   covers it, and a bound of exactly 172 800 s drops it — which is precisely
///   the boundary Residual 1 names.
///
/// Both are seeded straight into the relay's store, so neither ever crossed a
/// socket and neither has a live-delivery path: a REQ whose floor admits them is
/// the only way either can arrive.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_wrap_backdated_forty_eight_hours_published_after_the_last_open_is_still_delivered() {
    let relay = InboxRelay::run().await;

    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
    let own = Keys::generate().public_key();

    let (engine, anchored_ms) = engine_anchored_on(
        &circle,
        own,
        std::slice::from_ref(&relay.url),
        now_secs() - 600,
    )
    .await;
    let anchored_secs = anchored_ms.div_euclid(1000);

    let accurate_clock = routed_giftwrap_at(own, anchored_secs - max_nip59_backdate_secs());
    // Literal, not `INBOX_RESUBSCRIBE_LOOKBACK_SECS - 1`: an offset derived from
    // the constant slides with it and would still be delivered at any bound.
    let slow_clock = routed_giftwrap_at(own, anchored_secs - 176_399);
    assert!(
        slow_clock.created_at < accurate_clock.created_at,
        "precondition: the slow-clock fixture must sit BELOW the accurate one, \
         inside the hour of margin that is the only thing covering it"
    );

    let mut bus = engine.bus().subscribe();
    relay.seed(&accurate_clock).await;
    relay.seed(&slow_clock).await;

    engine
        .resume_after_background()
        .await
        .expect("re-anchor succeeds");

    let missing = wait_for_welcomes(
        &mut bus,
        &[accurate_clock.id, slow_clock.id],
        wait_budget(10),
    )
    .await;
    assert!(
        missing.is_empty(),
        "every conformant gift wrap at or above the re-anchor floor of {} s \
         must be delivered — the accurate-clock one is {} s and the \
         nearly-an-hour-slow one is {} s; missing: {missing:?}",
        anchored_secs - 176_400,
        accurate_clock.created_at.as_secs(),
        slow_clock.created_at.as_secs(),
    );

    // The floor is what let them through, stated as the wire fact.
    let seen = relay.wait_for_inbox_reqs(2, wait_budget(10)).await;
    assert_eq!(
        seen.last().copied().flatten(),
        Some(anchored_secs - 176_400),
    );

    let _ = engine.stop().await;
}

/// Residual 2, from its recoverable side: a wrap only ONE inbox relay ever held
/// is still fetched, because every inbox relay is asked from the SAME anchor —
/// and only while that anchor has not moved past it by more than the lookback.
///
/// There is one un-keyed inbox cursor for the whole inbox relay set, and the
/// first EOSE of a generation consumes its advance, so a relay that was away
/// while another kept answering does not get asked from ITS own last EOSE — it
/// gets asked from the shared floor, which by then has marched on. That is the
/// residual, and this stages its compressed form: a wrap that exists in exactly
/// one relay's store, dated a full 48 h below the shared cursor. It comes back,
/// and the two relays are provably asked the same question. At ~50 h below it
/// would not come back, which is what the constant documents.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_wrap_only_the_slow_inbox_relay_holds_is_fetched_within_the_lookback() {
    let answering = InboxRelay::run().await;
    let lagging = InboxRelay::run().await;

    let dir = TempDir::new().unwrap();
    let keys = Keys::generate();
    let circle = Arc::new(CircleManager::new_unencrypted(dir.path(), &keys).unwrap());
    let own = Keys::generate().public_key();

    let relays = vec![answering.url.clone(), lagging.url.clone()];
    let (engine, anchored_ms) = engine_anchored_on(&circle, own, &relays, now_secs() - 600).await;
    let anchored_secs = anchored_ms.div_euclid(1000);

    let wrap = routed_giftwrap_at(own, anchored_secs - max_nip59_backdate_secs());
    lagging.seed(&wrap).await;
    assert!(
        answering
            .db
            .event_by_id(&wrap.id)
            .await
            .expect("store read")
            .is_none(),
        "precondition: ONLY the lagging relay may hold this wrap, or the test \
         does not distinguish the two relays at all"
    );

    let mut bus = engine.bus().subscribe();
    engine
        .resume_after_background()
        .await
        .expect("re-anchor succeeds");

    assert!(
        wait_for_welcome(&mut bus, wait_budget(10)).await,
        "a wrap only the lagging inbox relay holds must still be fetched while \
         it sits inside the {INBOX_RESUBSCRIBE_LOOKBACK_SECS} s lookback: its \
         created_at is {} s, the shared floor is {} s",
        anchored_secs - max_nip59_backdate_secs(),
        anchored_secs - INBOX_RESUBSCRIBE_LOOKBACK_SECS,
    );

    // The un-keyed anchor, stated as the wire fact that makes the residual real:
    // the relay that was behind is asked from the SHARED floor, not from its own
    // last EOSE — so how far behind it may fall is decided by this constant
    // alone.
    let shared_floor = Some(anchored_secs - 176_400);
    let asked_answering = answering.wait_for_inbox_reqs(2, wait_budget(10)).await;
    let asked_lagging = lagging.wait_for_inbox_reqs(2, wait_budget(10)).await;
    assert_eq!(asked_answering.last().copied().flatten(), shared_floor);
    assert_eq!(asked_lagging.last().copied().flatten(), shared_floor);

    let _ = engine.stop().await;
}
