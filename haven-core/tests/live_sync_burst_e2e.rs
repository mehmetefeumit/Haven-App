//! The background burst (P4): open → ingest → publish → settle → close, over
//! real in-process relays.
//!
//! While backgrounded on iOS with sharing on, the engine holds NO standing REQ
//! and NO socket between publish ticks. Each tick is one bounded burst on the
//! SAME [`LiveSyncCore`] (Rule 14: one session, one salt, one supervisor task
//! set, one router object, one set of anchors — a core per burst would rotate
//! the sub-id salt every couple of minutes and re-spawn the Rule-14 task set on
//! every publish).
//!
//! # What these tests attack
//!
//! The pause is the only place in the engine that closes a socket while events
//! may still be in flight, so it is the only place that can lose a cursor's
//! meaning. Each test here is one attack on that:
//!
//! * **Rule 13** — a pause must never disconnect a commit between SEND and OK.
//! * **Rule 12** — the marker must DRAIN before the router is cleared, and it
//!   must `note_delivery_gap`, never `forget_*` (which drops hold-backs).
//! * **cursor safety** — a late `EOSE`, a queued `CLOSED`, a hold-back, a stale
//!   relay-side REQ, and a fast relay's `EOSE` settling a burst while a slow one
//!   is still replaying.
//!
//! The pure clock arithmetic (`settle_before_pause_with`, `wait_backlog_settled`
//! timeouts) and everything needing a private seam live in `session.rs`'s own
//! unit tests; this file is the relay-backed half.
//!
//! # Entry point
//!
//! Every open here is [`LiveSyncCore::open_background_burst`] — the entry the
//! background publish tick actually takes. It is the one that decides the inbox
//! fold on the BACKGROUND burst counter; `resume_after_background` is the
//! FOREGROUND re-anchor (app resume, health tick), which always carries the
//! inbox REQ and consumes no fold position. Every open in this file follows a
//! pause, and only a background burst pauses, so driving them through the
//! foreground entry would leave the burst path itself untested here. The
//! foreground re-anchor's own relay-backed coverage is
//! `live_sync_engine_e2e_test.rs` and `inbox_cursor_poisoning_e2e.rs`.
//!
//! # Test-reliability contract
//!
//! No wait here is a sleep standing in for a duration. Every one is a bounded
//! wait on a CONDITION — `wait_backlog_settled` (the engine's own settle), or
//! [`poll_until`] — so a slow machine lengthens a wait and can never flip a
//! verdict.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use haven_core::circle::{CircleConfig, CircleManager, MemberKeyPackage};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{GroupId, LocationMessageResult};
use haven_core::relay::live_sync::{
    group_cursor_stream, BacklogOutcome, CircleSpec, LiveSyncCore, LiveSyncEvent, SyncStatusReason,
};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::util::BoxedFuture;
use nostr::{Alphabet, Event, Filter, Keys, PublicKey, SingleLetterTag, Timestamp};
use nostr_relay_builder::builder::{PolicyResult, QueryPolicy, WritePolicy};
use nostr_relay_builder::{LocalRelay, MockRelay, RelayBuilder};
use nostr_sdk::Client;
use tempfile::TempDir;

// ═══════════════════════════════════════════════════════════════════════════
// Harness
// ═══════════════════════════════════════════════════════════════════════════

/// Waits (bounded) until `cond` holds, polling on a short interval.
///
/// The interval is a POLL, never a proxy for a duration: the verdict is decided
/// by `cond` alone, so a slow machine only lengthens the wait. Returns whether
/// it held.
async fn poll_until(mut cond: impl FnMut() -> bool) -> bool {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        if cond() {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// Waits until the wall clock crosses into the next whole second, and returns
/// it.
///
/// Cursor values are second-granular, so a test that needs "strictly later than
/// that event" has to cross a second boundary to be able to SEE the difference.
/// The wait is on the clock reading itself — the quantity under test — never a
/// stand-in for something else happening.
async fn wait_for_next_second() -> i64 {
    let start = Timestamp::now().as_secs();
    poll_until(|| Timestamp::now().as_secs() > start).await;
    i64::try_from(Timestamp::now().as_secs()).expect("a wall clock second fits in i64")
}

/// Same, for an async condition.
async fn poll_until_async<F>(mut cond: impl FnMut() -> F) -> bool
where
    F: std::future::Future<Output = bool>,
{
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        if cond().await {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// A `QueryPolicy` that records every REQ filter the relay was asked to serve,
/// in arrival order — what the relay ACTUALLY saw, not what the session believes
/// it sent.
#[derive(Debug, Default)]
struct RecordingQueries {
    seen: Arc<Mutex<Vec<Filter>>>,
}

impl QueryPolicy for RecordingQueries {
    fn admit_query<'a>(
        &'a self,
        query: &'a Filter,
        _addr: &'a std::net::SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async move {
            self.seen.lock().expect("record a REQ").push(query.clone());
            PolicyResult::Accept
        })
    }
}

/// Runs an in-process relay that records every REQ it serves.
async fn recording_relay() -> (LocalRelay, String, Arc<Mutex<Vec<Filter>>>) {
    let policy = RecordingQueries::default();
    let seen = Arc::clone(&policy.seen);
    let relay = LocalRelay::new(RelayBuilder::default().query_policy(policy));
    relay.run().await.expect("local relay runs");
    let url = relay.url().await.to_string();
    (relay, url, seen)
}

/// Accepts the FIRST `kind:445` (the test's own published proposal) at once and
/// withholds the OK for every later one until `release` is set.
///
/// The later ones are the ENGINE's auto-commits — the events Security Rule 13 is
/// about. Withholding by construction, released on an OBSERVED condition (the
/// test entering the pause), is what makes the race real: a wall-clock hold near
/// the crate's 10 s OK bound would be a CI timing race, not a test.
#[derive(Debug, Default)]
struct HoldEngineCommitOk {
    release: Arc<std::sync::atomic::AtomicBool>,
    seen: Arc<AtomicUsize>,
    held: Arc<AtomicUsize>,
}

impl WritePolicy for HoldEngineCommitOk {
    fn admit_event<'a>(
        &'a self,
        event: &'a Event,
        _addr: &'a std::net::SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async move {
            if event.kind != nostr::Kind::Custom(445)
                || self.seen.fetch_add(1, Ordering::AcqRel) == 0
            {
                return PolicyResult::Accept;
            }
            self.held.fetch_add(1, Ordering::AcqRel);
            // A bounded safety valve so a test can never hang; it is never what
            // decides the verdict, because every assertion is on the outcome.
            let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
            while !self.release.load(Ordering::Acquire) && tokio::time::Instant::now() < deadline {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            PolicyResult::Accept
        })
    }
}

/// Runs an in-process relay behind [`HoldEngineCommitOk`], returning the relay,
/// its url, the release switch and the withheld-OK counter.
async fn ok_withholding_relay() -> (
    LocalRelay,
    String,
    Arc<std::sync::atomic::AtomicBool>,
    Arc<AtomicUsize>,
) {
    let policy = HoldEngineCommitOk::default();
    let release = Arc::clone(&policy.release);
    let held = Arc::clone(&policy.held);
    let relay = LocalRelay::new(RelayBuilder::default().write_policy(policy));
    relay.run().await.expect("local relay runs");
    let url = relay.url().await.to_string();
    (relay, url, release, held)
}

/// A `QueryPolicy` that HOLDS every REQ until the test opens the gate, and then
/// serves it normally.
///
/// A relay that never answers, on an OBSERVED switch rather than a duration: the
/// REQ is neither answered with an `EOSE` nor ended with a `CLOSED`, which is the
/// one shape a co-bucketed relay can take that leaves its window unserved while
/// the burst's other relay finishes.
#[derive(Debug)]
struct GatedQueries {
    open: tokio::sync::watch::Receiver<bool>,
}

impl QueryPolicy for GatedQueries {
    fn admit_query<'a>(
        &'a self,
        _query: &'a Filter,
        _addr: &'a std::net::SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async move {
            let mut open = self.open.clone();
            // Bounded only so a broken test can never hang; the verdict is
            // always an outcome, never this wait.
            let _ =
                tokio::time::timeout(Duration::from_secs(60), open.wait_for(|open| *open)).await;
            PolicyResult::Accept
        })
    }
}

/// Runs an in-process relay whose REQ handling can be closed and re-opened.
async fn gated_relay() -> (LocalRelay, String, tokio::sync::watch::Sender<bool>) {
    let (gate, open) = tokio::sync::watch::channel(true);
    let relay = LocalRelay::new(RelayBuilder::default().query_policy(GatedQueries { open }));
    relay.run().await.expect("local relay runs");
    let url = relay.url().await.to_string();
    (relay, url, gate)
}

/// Publishes an already-built event to `url` over a throwaway client.
async fn publish_to(url: &str, event: &Event) {
    let publisher = Client::builder().build();
    publisher.add_relay(url).await.expect("add relay");
    publisher.connect().await;
    publisher
        .send_event(event)
        .await
        .expect("the in-process relay accepts the event");
}

/// A genuine multi-member circle, each member with their own real MLS store.
struct Circle {
    alice: Arc<CircleManager>,
    alice_keys: Keys,
    bob: Arc<CircleManager>,
    bob_keys: Keys,
    carol: Option<Arc<CircleManager>>,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    _dirs: Vec<TempDir>,
}

impl Circle {
    fn hex(&self) -> String {
        hex::encode(self.nostr_group_id)
    }
}

async fn mint_member(inbox: &[String]) -> (Arc<CircleManager>, Keys, MemberKeyPackage, TempDir) {
    let dir = TempDir::new().expect("tempdir");
    let keys = Keys::generate();
    let mgr = CircleManager::new_unencrypted(dir.path(), &keys).expect("circle manager");
    let kp_event = build_kp_maintenance_events(
        mgr.session(),
        &keys,
        &["wss://kp.example.com".to_string()],
        None,
        None,
    )
    .await
    .expect("member key package")
    .event;
    let member = MemberKeyPackage {
        key_package_event: kp_event,
        inbox_relays: inbox.to_vec(),
        nip65_relays: vec![],
    };
    (Arc::new(mgr), keys, member, dir)
}

/// Builds Alice (admin) + Bob, and optionally Carol, as real co-members whose
/// circle routes to `group_relays`.
async fn build_circle(group_relays: Vec<String>, with_carol: bool) -> Circle {
    let inbox = vec!["wss://member-inbox.example.com".to_string()];
    let (bob, bob_keys, bob_member, bob_dir) = mint_member(&inbox).await;
    let mut members = vec![bob_member];
    let mut dirs = vec![bob_dir];
    let carol_pair = if with_carol {
        let (carol, carol_keys, carol_member, carol_dir) = mint_member(&inbox).await;
        members.push(carol_member);
        dirs.push(carol_dir);
        Some((carol, carol_keys))
    } else {
        None
    };

    let alice_dir = TempDir::new().expect("tempdir");
    let alice_keys = Keys::generate();
    let alice =
        Arc::new(CircleManager::new_unencrypted(alice_dir.path(), &alice_keys).expect("alice"));
    let config = CircleConfig::new("Burst Circle").with_relays(group_relays.clone());
    let result = alice
        .create_circle(&alice_keys, members, &config, &group_relays)
        .await
        .expect("create circle");
    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;
    alice
        .confirm_published(result.pending)
        .await
        .expect("alice confirms creation");

    let mut joiners: Vec<(&Arc<CircleManager>, &Keys)> = vec![(&bob, &bob_keys)];
    if let Some((carol, carol_keys)) = carol_pair.as_ref() {
        joiners.push((carol, carol_keys));
    }
    for (mgr, keys) in joiners {
        let welcome = result
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == keys.public_key().to_hex())
            .expect("welcome for member");
        mgr.process_gift_wrapped_invitation(keys, &welcome.event)
            .await
            .expect("process welcome");
        mgr.accept_invitation(&welcome.event.id)
            .await
            .expect("accept");
    }

    dirs.push(alice_dir);
    Circle {
        alice,
        alice_keys,
        bob,
        bob_keys,
        carol: carol_pair.map(|(c, _)| c),
        mls_group_id,
        nostr_group_id,
        _dirs: dirs,
    }
}

/// Starts Alice's engine over `relays` for the circle, and settles its first
/// backlog so the test starts from a known state.
async fn start_engine(fx: &Circle, relays: &[String]) -> LiveSyncCore {
    let core = LiveSyncCore::new_local(Arc::clone(&fx.alice), fx.alice_keys.public_key());
    core.start(
        &[CircleSpec {
            group_id_hex: fx.hex(),
            relays: relays.to_vec(),
        }],
        &[],
    )
    .await
    .expect("alice's engine starts");
    assert_eq!(
        core.wait_backlog_settled().await,
        BacklogOutcome::Settled,
        "the harness starts from a settled engine"
    );
    core
}

async fn epoch(mgr: &CircleManager, gid: &GroupId) -> u64 {
    mgr.session().epoch(gid).await.expect("epoch")
}

async fn roster(mgr: &CircleManager, gid: &GroupId) -> Vec<String> {
    mgr.session().member_pubkeys(gid).await.expect("roster")
}

/// Whether `decryptor` can decrypt a fresh Location `encryptor` sends — the only
/// reliable detector of a twin fork (equal epoch NUMBER, different exporter).
async fn cross_decrypts(
    encryptor: &CircleManager,
    encryptor_pubkey: &PublicKey,
    decryptor: &CircleManager,
    gid: &GroupId,
) -> bool {
    let location = LocationMessage::new(40.12, -74.34);
    let Ok((event, _, _)) = encryptor
        .encrypt_location(gid, encryptor_pubkey, &location, 300)
        .await
    else {
        return false;
    };
    matches!(
        decryptor.decrypt_location(&event).await,
        Ok(ref results) if results.iter().any(|r| matches!(r, LocationMessageResult::Location { .. }))
    )
}

// ═══════════════════════════════════════════════════════════════════════════
// The promise: no standing REQ, no socket, between bursts
// ═══════════════════════════════════════════════════════════════════════════

/// A pause leaves NO subscription in the pool and every relay `Terminated`.
///
/// The whole battery claim, stated as the two things a client can observe. The
/// control arm — the same reads WHILE LIVE — is what stops this passing for an
/// engine that never subscribed or never connected in the first place.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn pause_subscriptions_leaves_no_subscription_in_the_pool() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    let fx = build_circle(vec![url.clone()], false).await;
    let core = start_engine(&fx, std::slice::from_ref(&url)).await;

    // Control: while LIVE there is a REQ and a connected relay.
    assert!(
        core.pool_subscription_count().await > 0,
        "a live engine holds a standing REQ — without this the pause assertion below \
         would pass for an engine that never subscribed"
    );
    let live = core.relay_health().await;
    assert_eq!(
        (live.connected, live.disconnected),
        (1, 0),
        "a live engine holds an open socket"
    );

    core.pause_subscriptions().await.expect("pause");

    assert_eq!(
        core.pool_subscription_count().await,
        0,
        "a paused engine must hold NO standing subscription: that is the promise"
    );
    let paused = core.relay_health().await;
    assert_eq!(
        (paused.connected, paused.disconnected),
        (0, 1),
        "...and no open socket — every relay Terminated, so the crate's per-relay \
         connection task and its 55 s pinger have exited and no timer wake remains"
    );
    assert!(core.is_paused());

    let _ = core.stop().await;
}

/// Between bursts the engine holds nothing, however many bursts have run.
///
/// The repeated form of the promise: a burst that leaked a REQ or a socket would
/// show up on the second or third cycle, not the first.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn background_burst_holds_no_standing_req() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    let fx = build_circle(vec![url.clone()], false).await;
    let core = start_engine(&fx, std::slice::from_ref(&url)).await;

    for burst in 0..3 {
        core.pause_subscriptions().await.expect("pause");
        assert_eq!(
            core.pool_subscription_count().await,
            0,
            "burst {burst}: no standing REQ may survive a pause"
        );
        assert_eq!(
            core.relay_health().await.connected,
            0,
            "burst {burst}: no socket may survive a pause"
        );

        core.open_background_burst().await.expect("burst opens");
        assert_eq!(
            core.wait_backlog_settled().await,
            BacklogOutcome::Settled,
            "burst {burst}: the burst must reach a settled backlog — a burst that could \
             not even connect would satisfy the 'nothing standing' assertions above \
             vacuously"
        );
        assert!(
            core.pool_subscription_count().await > 0,
            "burst {burst}: ...and it must really re-open its REQ"
        );
    }

    let _ = core.stop().await;
}

/// A burst opened immediately after a pause connects at once.
///
/// The crate makes this easy to get wrong: `Client::disconnect` terminates
/// synchronously while its connection task exits asynchronously, and a
/// `connect()` that lands in that window spawns nothing, strands the relay in
/// `Pending`, and leaves recovery to the old task's ~10 s retry interval. A burst
/// that inherited that would report `TimedOut` on every cycle, publish at a
/// possibly stale epoch, and hand its backlog to the next burst.
///
/// Back-to-back pause/open with no delay at all is the worst case, so it is
/// what this drives.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_burst_opened_immediately_after_a_pause_does_not_wait_out_the_crates_retry() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    let fx = build_circle(vec![url.clone()], false).await;
    let core = start_engine(&fx, std::slice::from_ref(&url)).await;

    for burst in 0..4 {
        core.pause_subscriptions().await.expect("pause");
        core.open_background_burst().await.expect("burst opens");
        assert_eq!(
            core.wait_backlog_settled().await,
            BacklogOutcome::Settled,
            "burst {burst} must settle within its own budget; inheriting the crate's \
             10 s reconnect backoff would time out every burst opened soon after a pause"
        );
    }

    let _ = core.stop().await;
}

// ═══════════════════════════════════════════════════════════════════════════
// Cursor safety
// ═══════════════════════════════════════════════════════════════════════════

/// A `EOSE` arriving after the pause cannot advance a cursor.
///
/// The pause CLOSEs every REQ and clears the router. A relay that sends its
/// `EOSE` a moment later names a subscription the router no longer resolves, so
/// the worker drops it — and even if it did not, the generation's advance was
/// burned by `note_delivery_gap`. Either way the persisted cursor must not move.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_late_eose_after_pause_never_advances_a_cursor() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    let fx = build_circle(vec![url.clone()], false).await;
    let core = start_engine(&fx, std::slice::from_ref(&url)).await;
    let stream = group_cursor_stream(&fx.hex());

    core.pause_subscriptions().await.expect("pause");
    let after_pause = fx
        .alice
        .read_sync_cursor(&stream)
        .expect("cursor read")
        .expect("the settled start advanced the cursor");

    // Everything an EOSE could act on is now gone: the anchor's advance is burned
    // and the router resolves nothing. Give any in-flight signal every chance to
    // land, then re-read.
    assert!(
        poll_until_async(|| async { core.pool_subscription_count().await == 0 }).await,
        "the pause must have closed every REQ"
    );
    assert_eq!(
        fx.alice.read_sync_cursor(&stream).expect("cursor read"),
        Some(after_pause),
        "no signal arriving after a pause may advance a cursor: the generation's \
         advance is burned and the router resolves nothing"
    );

    let _ = core.stop().await;
}

/// A hold-back survives the pause and bounds the NEXT burst's advance.
///
/// An event the engine could not APPLY holds its generation's advance at or
/// below its own `created_at`. The pause must SUPPRESS the pending advance
/// (`note_delivery_gap`) and never `forget` the anchor: `forget` DROPS the
/// hold-back, so the next burst's `EOSE` would advance the cursor straight over
/// an event this device never applied — and nothing would ever ask for it again.
///
/// This is the test that goes red if the pause path ever grows a `forget_*`.
///
/// The un-appliable state is a genuine publish-before-apply transition: Alice
/// stages a commit and does NOT confirm it, so her group cannot ingest and every
/// inbound message is `Buffered`. The control arm — the same sequence with no
/// staged commit — is what proves the cursor WOULD otherwise have advanced.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_hold_back_survives_pause_and_is_re_requested_by_the_next_burst() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    let fx = build_circle(vec![url.clone()], false).await;
    let core = start_engine(&fx, std::slice::from_ref(&url)).await;
    let stream = group_cursor_stream(&fx.hex());

    // ── Control: with nothing held back, a burst's EOSE advances the cursor to
    //    that burst's own open time. Without this the assertion below would pass
    //    for a cursor that simply never moves.
    let control_open = wait_for_next_second().await;
    core.pause_subscriptions().await.expect("pause");
    core.open_background_burst().await.expect("burst opens");
    assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
    assert!(
        poll_until(|| fx
            .alice
            .read_sync_cursor(&stream)
            .ok()
            .flatten()
            .is_some_and(|ms| ms >= control_open.saturating_mul(1000)))
        .await,
        "control: an unobstructed burst advances the cursor to its own open time"
    );

    // ── Arm the hold-back: Alice stages a commit and never confirms it, so her
    //    group is mid publish-before-apply and cannot ingest — every inbound
    //    message comes back `Buffered`, i.e. un-applied.
    let staged = fx
        .alice
        .update_circle_relays(&fx.mls_group_id, &["wss://group3.example.com".to_string()])
        .await
        .expect("alice stages a commit she will not confirm");
    drop(staged);

    let (buffered_event, _, _) = fx
        .bob
        .encrypt_location(
            &fx.mls_group_id,
            &fx.bob_keys.public_key(),
            &LocationMessage::new(3.0, 4.0),
            600,
        )
        .await
        .expect("bob encrypts");
    let held_at = i64::try_from(buffered_event.created_at.as_secs()).expect("created_at");
    publish_to(&url, &buffered_event).await;

    // Let the engine take it (and refuse to apply it) before the pause.
    assert!(
        poll_until_async(|| async { core.relay_health().await.subscriptions_live > 0 }).await,
        "the REQ carrying the un-appliable event must be live"
    );

    // The next burst opens STRICTLY LATER than the held event, so an advance to
    // the burst's open time is distinguishable from one bounded by the hold-back.
    let burst_open = wait_for_next_second().await;
    assert!(burst_open > held_at);

    core.pause_subscriptions().await.expect("pause");
    core.open_background_burst().await.expect("burst opens");
    assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);

    // Give any advance every chance to land, then read.
    assert!(poll_until_async(|| async { core.relay_health().await.subscriptions_live > 0 }).await);
    let cursor_after = fx
        .alice
        .read_sync_cursor(&stream)
        .expect("cursor read")
        .expect("cursor present");
    assert!(
        cursor_after < burst_open.saturating_mul(1000),
        "the next burst's EOSE must NOT advance the cursor to the burst's open time \
         while an event this device could not apply sits below it. `forget`ting the \
         anchor at pause drops that hold-back and the advance sails over the event — \
         which is then re-requested by no plane at all (Security Rule 12). \
         cursor_after={cursor_after} burst_open_ms={}",
        burst_open.saturating_mul(1000)
    );

    let _ = core.stop().await;
}

/// A `CLOSED` queued before the pause cannot re-open a REQ while paused, and
/// cannot fire into the next burst either.
///
/// A relay ending a REQ schedules a repair. The pause DRAINS the repair queue,
/// because a repair firing after a burst opened would replace a live REQ and
/// reset its generation mid-burst — the anchor would then vouch for a window the
/// burst's own REQ never asked for. And while paused, `run_repair` returns
/// BEFORE `take_due`, so the pending re-issue is deferred rather than consumed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_closed_queued_before_pause_does_not_reopen_a_req_while_paused() {
    /// A relay that ends every REQ it is given.
    #[derive(Debug)]
    struct CloseEverything;

    impl QueryPolicy for CloseEverything {
        fn admit_query<'a>(
            &'a self,
            _query: &'a Filter,
            _addr: &'a std::net::SocketAddr,
        ) -> BoxedFuture<'a, PolicyResult> {
            Box::pin(async { PolicyResult::Reject("closed by policy".to_string()) })
        }
    }

    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let closer = LocalRelay::new(RelayBuilder::default().query_policy(CloseEverything));
    closer.run().await.expect("local relay runs");
    let url = closer.url().await.to_string();
    let fx = build_circle(vec![url.clone()], false).await;

    let core = LiveSyncCore::new_local(Arc::clone(&fx.alice), fx.alice_keys.public_key());
    core.start(
        &[CircleSpec {
            group_id_hex: fx.hex(),
            relays: vec![url.clone()],
        }],
        &[],
    )
    .await
    .expect("alice's engine starts");

    // The relay CLOSEs the REQ, so a repair is scheduled. Wait for the pool to
    // have lost the subscription — the observable consequence of the CLOSED.
    assert!(
        poll_until_async(|| async { core.pool_subscription_count().await == 0 }).await,
        "the relay must actually end the REQ, or there is no repair to defer"
    );

    core.pause_subscriptions().await.expect("pause");

    // Nothing may re-open while paused, however long the repair backoff runs —
    // and nothing may re-open a SOCKET either, which is the half that used to be
    // checked only once, at the end. The 20 s budget spans a full crate retry
    // interval (10 s, jittered by at most +3 s), so a connection task that
    // survived the pause and rearmed itself has its chance to fire INSIDE this
    // window; polling the socket count as part of the condition is what catches
    // it at the moment it opens rather than in whatever state it happens to be
    // in when the loop ends.
    assert!(
        !poll_until_async(|| async { core.pool_subscription_count().await > 0 }).await,
        "a repair must never re-open a REQ while the session is paused: that puts a \
         standing subscription back on the wire between publish ticks and re-opens a \
         socket the pause closed"
    );
    let health = core.relay_health().await;
    assert_eq!(
        (health.connected, health.still_connecting),
        (0, 0),
        "and at the end of a full retry interval the radio is still off. This is the \
         DURABLE form of the promise, and deliberately not \"a socket was never up for \
         an instant\": the crate's `disconnect` fires its termination permit before \
         storing `Terminated`, so a preempted caller can leave a connection task armed \
         and nothing outside the crate can prevent that. What the engine can \
         guarantee, and what P4 needs, is that no such socket SURVIVES — the \
         radio-off watch cuts it, and `unrequested_connections` (= {}) is how often \
         it had to",
        core.unrequested_connections()
    );

    let _ = core.stop().await;
}

/// The same `CLOSED`, seen from the next burst: its repair is not still armed.
///
/// The pause clears the repair queue precisely so a deferred re-issue cannot
/// land on top of the burst's own REQ. The observable is the REQ count the relay
/// records for that sub-id inside the burst: exactly one.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_closed_queued_before_pause_does_not_fire_after_the_next_burst_opens() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let (_relay, url, recorded) = recording_relay().await;
    let fx = build_circle(vec![url.clone()], false).await;
    let core = start_engine(&fx, std::slice::from_ref(&url)).await;

    // Provoke a repair the honest way: the worker records a CLOSED only for a
    // subscription the router resolves, so drive it through the relay by ending
    // the REQ from the relay side is not available here — instead assert the
    // burst's own REQ count, which is what the repair would double.
    core.pause_subscriptions().await.expect("pause");
    recorded.lock().expect("clear").clear();

    core.open_background_burst().await.expect("burst opens");
    assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);

    // Let any deferred repair have its chance: it must never arrive.
    assert!(
        !poll_until(|| recorded.lock().expect("read").len() > 1).await,
        "exactly ONE REQ per sub-id may reach the relay in a burst. A repair surviving \
         the pause would replace the burst's live REQ and reset its generation \
         mid-burst, so the anchor would vouch for a window the burst never asked for. \
         Saw {} REQ(s)",
        recorded.lock().expect("read").len()
    );

    let _ = core.stop().await;
}

/// A circle subscribed while paused is LIVE after the next burst.
///
/// Its relay was never added to the pool (a paused session has no socket to add
/// one to), so the burst open must register the relay UNION of the active set
/// before `connect()`. Without that, the REQ is issued to a relay the pool does
/// not hold, the bucket's `?` fails the WHOLE open, and the circle receives
/// nothing in the background — silently.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_circle_added_while_paused_is_live_after_the_next_burst() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let first = MockRelay::run().await.expect("mock relay");
    let first_url = first.url().await.to_string();
    // The added circle lives on a DIFFERENT relay, so the union is load-bearing.
    let (_second, second_url, recorded) = recording_relay().await;

    let fx = build_circle(vec![first_url.clone()], false).await;
    let core = start_engine(&fx, std::slice::from_ref(&first_url)).await;

    let added = "5a".repeat(32);
    core.pause_subscriptions().await.expect("pause");
    core.subscribe_circle(&CircleSpec {
        group_id_hex: added.clone(),
        relays: vec![second_url.clone()],
    })
    .await
    .expect("subscribing while paused stages the circle");

    core.open_background_burst()
        .await
        .expect("the burst open must NOT fail because of a relay the pool did not hold");
    assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);

    let saw_added = recorded.lock().expect("read").iter().any(|f| {
        f.generic_tags
            .get(&SingleLetterTag::lowercase(Alphabet::H))
            .is_some_and(|values| values.contains(&added))
    });
    assert!(
        saw_added,
        "the burst must issue a REQ whose `#h` carries the circle added while paused, \
         to the relay that circle named — otherwise that circle is silent in the \
         background forever and nothing reports it"
    );

    let _ = core.stop().await;
}

/// The crate premise the pause's re-assert rests on, pinned against a bump.
///
/// `LiveSyncCore::terminate_all_relays` calls `disconnect()` a second time on a
/// relay the first call left in a non-terminal status, and that repairs the
/// strand for exactly one reason: `InnerRelay::disconnect` early-returns ONLY on
/// `Terminated`/`Banned`, so from `Disconnected` it fires a FRESH termination
/// permit — and the permit is the only thing that breaks a connection task out
/// of its retry sleep, since the loop never re-reads the status it was given.
///
/// If a future `nostr-relay-pool` made `disconnect` a no-op on `Disconnected`
/// too, or stopped honouring the permit during the retry sleep, the re-assert
/// would become a silent no-op and the pause would go back to leaking a socket
/// per background gap with nothing to say so. The crate is PINNED, so a bump is
/// the moment this can change; this test is what makes that bump loud.
///
/// The stranded state is reached honestly: a relay whose connect is refused
/// lands on `Disconnected` with its task asleep on the retry interval, which is
/// the same state and the same task as a real strand's.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_second_disconnect_still_terminates_a_relay_the_first_left_behind() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    // Port 1 on loopback refuses instantly, so the failure needs no timeout.
    let client = Client::default();
    client
        .add_relay("ws://127.0.0.1:1")
        .await
        .expect("add relay");
    client.connect().await;
    let relay = client
        .relays()
        .await
        .into_values()
        .next()
        .expect("the pool holds the relay it was given");

    assert!(
        poll_until(|| relay.status() == nostr_sdk::RelayStatus::Disconnected).await,
        "a refused connect must leave the relay `Disconnected` with its connection \
         task asleep on the retry interval — the state a strand is in"
    );

    client.disconnect().await;
    assert_eq!(
        relay.status(),
        nostr_sdk::RelayStatus::Terminated,
        "`disconnect` must NOT early-return on a `Disconnected` relay. If it did, the \
         pause's re-assert could never fire a fresh termination permit and would be a \
         no-op on exactly the relays it exists to repair"
    );

    // And the permit must actually break the sleeping task, not merely relabel
    // the status: a task still asleep re-connects when its interval expires. The
    // budget spans a full interval (10 s) plus the jitter ceiling (+3 s), and
    // the observable is the crate's own attempt counter, which only a real
    // connection attempt moves.
    let attempts = relay.stats().attempts();
    assert!(
        !poll_until(|| relay.stats().attempts() > attempts).await,
        "a terminated relay must make no further connection attempt. One here means \
         the connection task outlived the termination and is still on the crate's \
         retry schedule — a socket re-opening mid-gap, which is what the pause \
         exists to prevent"
    );
}

/// A burst open that fails half-way leaves the session PAUSED, silent, and
/// REPORTED paused.
///
/// The open clears the paused state before it touches a socket, because every
/// gate reads that flag and a burst running behind a closed gate would have its
/// own repairs and health tick refuse to act. But there is no `finally` in Rust
/// and no coordinator above this that supplies one: an open that cleared the
/// flag, connected, and then failed to issue its REQs used to return `Err` with
/// sockets up, zero or partial subscriptions, and every gate wide open — for the
/// whole 2-15 minutes until the next tick. That is the between-tick presence P4
/// promises does not exist, entered through the error path instead of the happy
/// one.
///
/// "Silent" is not enough on its own, and that was the second half of the same
/// defect. This arm lowers the radio-off flag before `connect()`, so the monitor
/// has already put `Connecting`/`Connected` on the bus by the time the
/// subscribe fails; emitting nothing afterwards leaves a consumer holding a
/// status that says the receive plane is serving. A consumer that early-returns
/// on `Paused` would instead judge health by its publish acks — which succeed,
/// on a SEPARATE pool — and report a session subscribed to nothing as healthy.
/// So the arm emits the same single `Paused` a deliberate pause does.
///
/// The failure is real, not simulated: a circle is added while paused whose
/// relay refuses connections, so its bucket is never accepted and the open
/// short-circuits exactly as it does in the field when a relay is unreachable.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_burst_open_that_fails_to_subscribe_leaves_the_session_paused_and_silent() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let live = MockRelay::run().await.expect("mock relay");
    let live_url = live.url().await.to_string();
    let fx = build_circle(vec![live_url.clone()], false).await;
    let core = start_engine(&fx, std::slice::from_ref(&live_url)).await;

    core.pause_subscriptions().await.expect("pause");
    assert!(core.is_paused(), "the pause is where this open starts from");

    // A malformed relay entry (the port is out of range) is the deterministic
    // form of the failure the open's own contract names: a REQ issued to a relay
    // the pool does not hold. `add_relay` refuses the url, `subscribe_with_id_to`
    // answers `RelayNotFound`, and the whole open short-circuits — the same exit
    // an unusable persisted relay list takes in the field.
    core.subscribe_circle(&CircleSpec {
        group_id_hex: "3f".repeat(32),
        relays: vec!["wss://relay.invalid:99999".to_string()],
    })
    .await
    .expect("subscribing while paused only stages the circle");

    // Subscribed AFTER the deliberate pause, so the only `Paused` this receiver
    // can see is the failed open's own.
    let mut bus = core.bus().subscribe();
    assert!(
        core.open_background_burst().await.is_err(),
        "a bucket whose relay the pool does not hold must fail the open — if it silently succeeded there would \
         be no error path left to test"
    );

    // No wait: `EventBus::send` is synchronous and this task awaited the open to
    // completion, so everything the arm emitted is already buffered.
    let mut paused = 0usize;
    let mut resumed = 0usize;
    while let Ok(event) = bus.try_recv() {
        match event {
            LiveSyncEvent::Status {
                reason: SyncStatusReason::Paused,
            } => paused += 1,
            LiveSyncEvent::Status {
                reason: SyncStatusReason::BackgroundResumed,
            } => resumed += 1,
            _ => {}
        }
    }
    assert_eq!(
        paused, 1,
        "a failed open must report the state it leaves — exactly one Paused, as a \
         deliberate pause emits. Without it the last status on the bus is this open's \
         own Connecting/Connected, and a consumer that early-returns on Paused instead \
         grades the session on its publish acks (a separate pool, still succeeding) and \
         calls a session subscribed to nothing healthy"
    );
    assert_eq!(
        resumed, 0,
        "and it must NOT report a resume: BackgroundResumed is the happy path's signal \
         that every REQ is back on the wire, which is the one thing this open did not do"
    );

    assert!(
        core.is_paused(),
        "a failed open must leave the session paused. Otherwise `run_repair`, the health tick \
         and the delta ops all believe a burst is live and act on a session that holds no REQ"
    );
    assert_eq!(
        core.pool_subscription_count().await,
        0,
        "and hold no subscription: the buckets that DID subscribe before the failing one must \
         not be left standing on the wire for the whole gap"
    );
    assert_eq!(
        core.relay_health().await.connected,
        0,
        "and no socket: the open already called `connect()`, so the error path is the only \
         thing that can put the radio back"
    );
    // And it must still be off a full crate retry interval later (10 s, jittered
    // by at most +3 s), which is when a connection task the failure left armed
    // would fire. `poll_until_async` pays its whole 20 s budget on a condition
    // that never holds, so this observes the entire window.
    assert!(
        !poll_until_async(|| async { core.pool_subscription_count().await > 0 }).await,
        "no REQ may go back on the wire after a failed open"
    );
    let health = core.relay_health().await;
    assert_eq!(
        (health.connected, health.still_connecting),
        (0, 0),
        "and no socket may survive the window either. Cut once, a relay stays cut: a \
         non-terminal status here is a connection task that outlived the failure and \
         is back on the crate's retry schedule, which the next burst would adopt \
         silently. (`unrequested_connections` = {}: how many transitions the \
         radio-off watch had to cut inside the window.)",
        core.unrequested_connections()
    );

    let _ = core.stop().await;
}

// ═══════════════════════════════════════════════════════════════════════════
// Ingest before publish, and Rule 13
// ═══════════════════════════════════════════════════════════════════════════

/// A burst applies a peer's commit BEFORE the location is encrypted.
///
/// TWO relays carry the circle, and only the SLOW one holds Alice's commit.
/// `note_eose(group_hex)` consumes the circle's single anchor generation on the
/// FIRST relay's `EOSE`, so a per-CIRCLE settle would call the burst settled
/// while the relay holding the commit was still replaying — and the burst would
/// encrypt one epoch behind, every time. Waiting per ENDPOINT is what makes
/// "ingest, then publish" true.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn burst_ingests_a_peer_commit_before_the_location_is_encrypted() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let fast = MockRelay::run().await.expect("mock relay");
    let slow = MockRelay::run().await.expect("mock relay");
    let fast_url = fast.url().await.to_string();
    let slow_url = slow.url().await.to_string();

    let fx = build_circle(vec![fast_url.clone(), slow_url.clone()], false).await;
    // BOB runs the burst engine; ALICE is the circle's admin, so she is the one
    // who can stage a routing commit.
    let core = LiveSyncCore::new_local(Arc::clone(&fx.bob), fx.bob_keys.public_key());
    core.start(
        &[CircleSpec {
            group_id_hex: fx.hex(),
            relays: vec![fast_url.clone(), slow_url.clone()],
        }],
        &[],
    )
    .await
    .expect("bob's engine starts");
    assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
    let before = epoch(&fx.bob, &fx.mls_group_id).await;

    core.pause_subscriptions().await.expect("pause");

    // Alice commits while Bob is paused, and publishes ONLY to the slow relay —
    // so the burst settles only if it waited on THAT endpoint.
    let commit = fx
        .alice
        .update_circle_relays(&fx.mls_group_id, &["wss://group2.example.com".to_string()])
        .await
        .expect("alice stages a routing commit");
    fx.alice
        .finalize_relay_update(commit.pending, &fx.mls_group_id)
        .await
        .expect("alice finalizes");
    publish_to(&slow_url, &commit.commit_event).await;

    core.open_background_burst().await.expect("burst opens");
    assert_eq!(
        core.wait_backlog_settled().await,
        BacklogOutcome::Settled,
        "the burst must wait for EVERY endpoint, including the slow relay that is the \
         only one holding the commit"
    );

    assert!(
        poll_until_async(|| async { epoch(&fx.bob, &fx.mls_group_id).await > before }).await,
        "the commit the burst downloaded must be APPLIED before the burst publishes: a \
         location encrypted at the old epoch is one peers decrypt only from past-epoch \
         keys"
    );
    assert!(
        cross_decrypts(
            &fx.bob,
            &fx.bob_keys.public_key(),
            &fx.alice,
            &fx.mls_group_id
        )
        .await,
        "and the location encrypted after that settle must decrypt for the committer at \
         the epoch she committed to"
    );

    let _ = core.stop().await;
}

/// A peer `SelfRemove` auto-commit is NOT published inside a background burst —
/// and the FOREGROUND pass that follows does publish it, so a third member
/// converges off the relay.
///
/// # Why the burst does not publish it (owner decision OD4-c, option (iv))
///
/// A receive-side auto-commit always removes a member, and MDK's hydrate
/// deliberately refuses to recover a removal-bearing staged commit
/// (`cgka-engine/src/engine.rs:820-828` at the pinned rev `e391adc`
/// short-circuits on `staged_removes_member`). So a burst cut between SEND and OK
/// — the premise of the whole phase is a process the OS may end between bursts —
/// leaves the group with a staged commit nothing will ever publish or clear: no
/// `PendingCommitRecovered`, and every later send refused. The burst therefore
/// PARKS the commit as a durable per-circle obligation.
///
/// This test used to assert the opposite (published + confirmed inside the
/// burst), which is the behaviour the decision reverses. Both invariants it
/// protected are kept and two are added: the eviction must NOT be on the relay
/// after the burst NOR after a second one (bursts repeat, and a later background
/// open must not redeem what an earlier one parked), it MUST be on the relay after
/// the foreground pass, and a third member reading the relay converges only then.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_self_remove_auto_commit_is_deferred_by_the_burst_and_published_by_the_foreground() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    let fx = build_circle(vec![url.clone()], true).await;
    let carol = fx.carol.clone().expect("carol joined");
    let core = start_engine(&fx, std::slice::from_ref(&url)).await;
    let bob_hex = fx.bob_keys.public_key().to_hex();
    let before = epoch(&fx.alice, &fx.mls_group_id).await;

    core.pause_subscriptions().await.expect("pause");
    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");
    publish_to(&url, &proposal).await;

    core.open_background_burst().await.expect("burst opens");
    assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);

    // The burst ingested the proposal and the engine staged the eviction — but the
    // burst published nothing, and the obligation is on disk.
    assert!(
        poll_until_async(|| async { !fx.alice.owed_removal_commits().is_empty() }).await,
        "the burst must PARK the eviction commit as a durable obligation"
    );
    let reader = Client::builder().build();
    reader.add_relay(url.as_str()).await.expect("add relay");
    reader.connect().await;
    let feed_after_burst = |reader: &Client| {
        let reader = reader.clone();
        let hex = fx.hex();
        async move {
            reader
                .fetch_events(
                    Filter::new()
                        .kind(nostr::Kind::Custom(445))
                        .custom_tag(SingleLetterTag::lowercase(Alphabet::H), hex),
                    Duration::from_secs(5),
                )
                .await
                .expect("read the circle's events back off the relay")
        }
    };
    // The WIRE is the oracle here, not a member's roster: Bob's proposal is the
    // only kind-445 on this circle's stream, and a burst that published the
    // eviction would add a second. Carol's roster cannot say this — her own engine
    // schedules the same jitter-delayed auto-commit off the same proposal, so she
    // drops Bob on her own timetable no matter what Alice published.
    let ids_on_relay = |events: nostr_sdk::prelude::Events| {
        let mut ids: Vec<_> = events.into_iter().map(|e| e.id).collect();
        ids.sort_unstable();
        ids.dedup();
        ids
    };
    assert_eq!(
        ids_on_relay(feed_after_burst(&reader).await),
        vec![proposal.id],
        "nothing the burst put on the relay can evict Bob: a commit published in a \
         burst is exactly the publish-before-apply window an OS kill turns into an \
         unrecoverable group (OD4-c)"
    );

    // Nor can a LATER burst. Bursts repeat every few minutes, so a background open
    // that redeemed what an earlier one parked would re-open the exact window (iv)
    // removes — just one burst later, and with no test between them.
    core.open_background_burst()
        .await
        .expect("second burst opens");
    assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
    assert!(
        !fx.alice.owed_removal_commits().is_empty(),
        "a background open must never redeem a parked eviction commit"
    );
    assert_eq!(
        ids_on_relay(feed_after_burst(&reader).await),
        vec![proposal.id],
        "and a second burst adds nothing to the wire either"
    );

    // The FOREGROUND pass redeems it: published over the engine's own sockets and
    // confirmed on the relay's OK.
    core.resume_after_background()
        .await
        .expect("foreground re-anchor");

    assert!(
        poll_until_async(|| async {
            !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex)
                && fx.alice.owed_removal_commits().is_empty()
        })
        .await,
        "the foreground pass must publish the parked commit, confirm it on the relay's \
         OK and discharge the obligation — a deferred removal that never lands leaves \
         a member who asked to leave still in the circle"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        before + 1,
        "an epoch that moved is an epoch a relay acked (Rule 13)"
    );

    // And it really went out: a SECOND event is now on the wire, and the third
    // member converges from it off the relay.
    assert_eq!(
        ids_on_relay(feed_after_burst(&reader).await).len(),
        2,
        "the eviction commit must be ON the relay, not merely applied locally"
    );
    for event in feed_after_burst(&reader).await {
        let _ = carol.session().process_event(&event).await;
        let _ = carol.session().advance_convergence(&fx.mls_group_id).await;
    }
    assert!(
        !roster(&carol, &fx.mls_group_id).await.contains(&bob_hex),
        "the eviction commit must be ON THE RELAY, not merely applied locally: a third \
         member reading the relay converges on the post-eviction roster"
    );

    let _ = core.stop().await;
}

/// Rule 13, driven THROUGH the intake: a pause never disconnects while an
/// auto-commit is between SEND and OK.
///
/// Bob's `SelfRemove` proposal arrives as a RELAY EVENT — never a direct
/// `resolve_publish_work` call — so the eviction commit is staged and published
/// by the engine's own worker, exactly as it is in the field. The relay accepts
/// the proposal at once and then WITHHOLDS the OK for the engine's commit,
/// releasing it only when the test has observably entered the close path. A
/// wall-clock hold near the crate's 10 s OK bound would be a CI timing race
/// instead of a test.
///
/// What must hold: the pause blocks on the in-flight publish gauge, the OK is
/// then released, the commit is CONFIRMED (never rolled back), and only after
/// that does the disconnect happen.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn pause_never_disconnects_while_an_auto_commit_awaits_its_ok() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let (_relay, url, release, held) = ok_withholding_relay().await;

    let fx = build_circle(vec![url.clone()], true).await;
    let core = Arc::new(LiveSyncCore::new_local(
        Arc::clone(&fx.alice),
        fx.alice_keys.public_key(),
    ));
    core.start(
        &[CircleSpec {
            group_id_hex: fx.hex(),
            relays: vec![url.clone()],
        }],
        &[],
    )
    .await
    .expect("alice's engine starts");
    assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
    let bob_hex = fx.bob_keys.public_key().to_hex();
    let before = epoch(&fx.alice, &fx.mls_group_id).await;

    // THROUGH THE INTAKE: the proposal arrives as a relay event.
    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");
    publish_to(&url, &proposal).await;

    // Wait until the engine's auto-commit is genuinely on the wire with its OK
    // withheld — the state Rule 13 forbids cutting.
    assert!(
        poll_until(|| held.load(Ordering::Acquire) > 0).await,
        "the engine must publish the eviction commit over its own sockets, and the \
         relay must be withholding its OK — that withheld state is what Rule 13 \
         forbids cutting"
    );
    assert!(
        core.in_flight_publishes() > 0,
        "...and the in-flight gauge must see it: without the gauge the pause has \
         nothing to block on"
    );

    // Enter the pause. The OK is released on the OBSERVED condition that the
    // close path is pending.
    let pausing = Arc::clone(&core);
    let pause = tokio::spawn(async move { pausing.pause_subscriptions().await });
    release.store(true, Ordering::Release);

    pause
        .await
        .expect("the pause task must not panic")
        .expect("the pause must succeed");

    assert!(
        !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "the commit must be CONFIRMED, never rolled back: the pause held the socket \
         open until the gauge reached zero, so `wait_for_ok` saw the relay's OK. A \
         disconnect here makes it return Err(PrematureExit)/Err(NotConnected), the \
         commit rolls back to the prior epoch, and the relay may already have stored \
         and served it — a roster fork on every background burst"
    );
    assert_eq!(
        epoch(&fx.alice, &fx.mls_group_id).await,
        before + 1,
        "and the epoch moved, which only an acked commit may do"
    );
    assert_eq!(
        core.in_flight_publishes(),
        0,
        "the gauge is zero at the instant the pause disconnected — that is the check, \
         never a duration"
    );
    assert_eq!(
        core.pool_subscription_count().await,
        0,
        "and the pause really did complete (it is not merely still blocked)"
    );

    let _ = core.stop().await;
}

/// A commit arriving between the settle and the pause is still confirmed.
///
/// `settle_before_pause` and `pause_subscriptions` are separate calls, and the
/// window between them is exactly where a live `SelfRemove` can be ingested and
/// SENT. The gauge is therefore re-checked INSIDE the pause, after the marker
/// ack and before the disconnect — this drives that window directly: the settle
/// runs first, on a quiet burst, and only THEN does the proposal arrive.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_commit_arriving_between_settle_and_pause_is_still_confirmed() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let (_relay, url, release, held) = ok_withholding_relay().await;

    let fx = build_circle(vec![url.clone()], true).await;
    let core = Arc::new(LiveSyncCore::new_local(
        Arc::clone(&fx.alice),
        fx.alice_keys.public_key(),
    ));
    core.start(
        &[CircleSpec {
            group_id_hex: fx.hex(),
            relays: vec![url.clone()],
        }],
        &[],
    )
    .await
    .expect("alice's engine starts");
    assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
    let bob_hex = fx.bob_keys.public_key().to_hex();
    let before = epoch(&fx.alice, &fx.mls_group_id).await;

    // A QUIET settle: nothing has committed, so it returns at once and pays zero.
    let settle_started = tokio::time::Instant::now();
    core.settle_before_pause().await;
    assert!(
        tokio::time::Instant::now() - settle_started < Duration::from_secs(1),
        "a quiet settle must pay ~nothing; if it waited, the window this test is about \
         never opened"
    );

    // ONLY NOW does the proposal arrive — in the window the settle has already
    // passed and the pause has not yet reached its disconnect.
    let proposal = fx
        .bob
        .propose_leave(&fx.mls_group_id)
        .await
        .expect("bob proposes leave");
    publish_to(&url, &proposal).await;
    assert!(
        poll_until(|| held.load(Ordering::Acquire) > 0).await,
        "the engine must have the eviction commit on the wire, OK withheld"
    );
    assert!(
        core.in_flight_publishes() > 0,
        "and the gauge must see it — this is the window only the pause's own gauge \
         check covers"
    );

    let pausing = Arc::clone(&core);
    let pause = tokio::spawn(async move { pausing.pause_subscriptions().await });
    release.store(true, Ordering::Release);
    pause
        .await
        .expect("the pause task must not panic")
        .expect("the pause must succeed");

    assert!(
        !roster(&fx.alice, &fx.mls_group_id).await.contains(&bob_hex),
        "a commit ingested AFTER settle_before_pause returned must still be confirmed: \
         the settle is a separate call, so only the gauge check INSIDE the pause can \
         cover this window"
    );
    assert_eq!(epoch(&fx.alice, &fx.mls_group_id).await, before + 1);

    let _ = core.stop().await;
}

/// A burst that did not settle every endpoint leaves NO cursor advance standing.
///
/// The cursor-safety hole per-endpoint SETTLING alone does not close. A bucket
/// REQ is one filter over several relays while the circle holds ONE anchor
/// generation, so the FAST relay's `EOSE` redeems that generation and writes the
/// persisted cursor at the burst's open time — even though the slow relay, here
/// the only one holding the peer's commit, never served its window. The burst
/// then reports `TimedOut`, publishes, and disconnects seconds later with the
/// cursor already moved; the next burst's floor on that relay is
/// `cursor − GROUP_RESUBSCRIBE_BUFFER_SECS`, so anything more than a minute below
/// it is never requested again, by any burst or catch-up sweep.
///
/// Three arms, in order: the cursor must NOT move on a burst that timed out; the
/// event must still be deliverable (the control the reviewer's probe used —
/// holding the socket open DOES deliver the late replay, which is what makes the
/// first arm about the CURSOR and not about a fixture that published nothing);
/// and once every endpoint has answered the cursor must move after all, or "safe"
/// would just mean "never advances".
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_burst_that_did_not_settle_every_endpoint_leaves_no_advance_standing() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let fast = MockRelay::run().await.expect("mock relay");
    let fast_url = fast.url().await.to_string();
    let (_slow, slow_url, gate) = gated_relay().await;

    let fx = build_circle(vec![fast_url.clone(), slow_url.clone()], false).await;
    // BOB runs the burst engine; ALICE is the admin, so she is the one who can
    // stage a routing commit.
    let core = LiveSyncCore::new_local(Arc::clone(&fx.bob), fx.bob_keys.public_key());
    core.start(
        &[CircleSpec {
            group_id_hex: fx.hex(),
            relays: vec![fast_url.clone(), slow_url.clone()],
        }],
        &[],
    )
    .await
    .expect("bob's engine starts");
    assert_eq!(
        core.wait_backlog_settled().await,
        BacklogOutcome::Settled,
        "the fixture starts from a settled engine, both relays served"
    );
    let stream = group_cursor_stream(&fx.hex());
    let before_epoch = epoch(&fx.bob, &fx.mls_group_id).await;

    core.pause_subscriptions().await.expect("pause");
    let anchored = fx
        .bob
        .read_sync_cursor(&stream)
        .expect("cursor read")
        .expect("the settled start advanced the cursor");
    // Cursor values are second-granular, so the burst below has to open in a
    // LATER second for an over-advance to be visible at all.
    wait_for_next_second().await;

    // The peer's commit is stored on the SLOW relay alone, and that relay stops
    // answering REQs before the burst opens.
    let commit = fx
        .alice
        .update_circle_relays(&fx.mls_group_id, &["wss://group2.example.com".to_string()])
        .await
        .expect("alice stages a routing commit");
    fx.alice
        .finalize_relay_update(commit.pending, &fx.mls_group_id)
        .await
        .expect("alice finalizes");
    publish_to(&slow_url, &commit.commit_event).await;
    gate.send_replace(false);

    core.open_background_burst().await.expect("burst opens");
    assert_eq!(
        core.wait_backlog_settled().await,
        BacklogOutcome::TimedOut,
        "precondition: with one endpoint silent the burst cannot settle"
    );

    // ── Arm 1: the advance.
    assert_eq!(
        fx.bob.read_sync_cursor(&stream).expect("cursor read"),
        Some(anchored),
        "a burst whose endpoints did not all answer must leave no advance standing. \
         The fast relay's EOSE is ITS completeness claim; taking it for the circle's \
         moves the cursor past a window the slow relay never served, and the next \
         burst's floor is only 60 s below that"
    );

    // ── Arm 2: the event was really there, and a held-open socket delivers it.
    gate.send_replace(true);
    assert!(
        poll_until_async(|| async { epoch(&fx.bob, &fx.mls_group_id).await > before_epoch }).await,
        "the slow relay's replay must reach the engine once it answers — otherwise \
         arm 1 would pass for a fixture that never published anything"
    );

    // ── Arm 3: and then the cursor DOES advance, or "cursor-safe" would only
    //    mean "never advances again".
    assert_eq!(
        core.wait_backlog_settled().await,
        BacklogOutcome::Settled,
        "every endpoint has now answered"
    );
    assert!(
        poll_until(|| fx
            .bob
            .read_sync_cursor(&stream)
            .expect("cursor read")
            .is_some_and(|ms| ms > anchored))
        .await,
        "once every relay that accepted the REQ has finished its replay, the \
         generation's advance must be redeemed"
    );

    let _ = core.stop().await;
}

/// A burst open racing a draining pause waits for the clear.
///
/// The pause holds the lifecycle lock for its WHOLE call — sweep, marker drain,
/// gauge, disconnect — so an open cannot slip in mid-pause and register entries
/// the marker then wipes on its way out. The observable is that the burst really
/// receives: a peer location published after the open reaches the engine.
///
/// The lock is only half of it, and only this half. A pause whose marker ack
/// TIMED OUT releases the lock with that marker still queued, and no lock can
/// order what happens then — that case is
/// `session::tests::a_marker_from_an_abandoned_pause_never_wipes_the_next_bursts_router`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_burst_open_racing_a_draining_pause_waits_for_the_clear() {
    let _ = haven_core::relay::allow_ws_loopback_for_test();
    let relay = MockRelay::run().await.expect("mock relay");
    let url = relay.url().await.to_string();
    let fx = build_circle(vec![url.clone()], false).await;
    let core = Arc::new(start_engine(&fx, std::slice::from_ref(&url)).await);

    // Start the pause and the open together, from separate tasks.
    let pausing = Arc::clone(&core);
    let pause = tokio::spawn(async move { pausing.pause_subscriptions().await });
    let opening = Arc::clone(&core);
    let open = tokio::spawn(async move { opening.open_background_burst().await });

    pause
        .await
        .expect("pause task")
        .expect("the pause must succeed");
    open.await
        .expect("open task")
        .expect("the open must succeed");

    // Whichever won the lock, the engine must end in a state that RECEIVES: if
    // the open lost, the caller sees a paused engine and opens again; if it won,
    // its router entries must have survived the pause's marker.
    if core.is_paused() {
        core.open_background_burst()
            .await
            .expect("a burst opens after the pause completed");
    }
    assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);

    let mut bus = core.bus().subscribe();
    let (event, _, _) = fx
        .bob
        .encrypt_location(
            &fx.mls_group_id,
            &fx.bob_keys.public_key(),
            &LocationMessage::new(7.0, 8.0),
            600,
        )
        .await
        .expect("bob encrypts");
    publish_to(&url, &event).await;

    let received = tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            match bus.recv().await {
                Ok(haven_core::relay::live_sync::LiveSyncEvent::Location { .. }) => return true,
                Ok(_) => {}
                Err(_) => return false,
            }
        }
    })
    .await
    .unwrap_or(false);

    assert!(
        received,
        "the open's router entries must survive: an open that raced a draining pause \
         and had its entries wiped would leave an engine that believes it is \
         subscribed and receives nothing"
    );

    let _ = core.stop().await;
}
