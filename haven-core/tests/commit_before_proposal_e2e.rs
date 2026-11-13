//! A member catching up after a `SelfRemove` must never hand MDK the eviction
//! commit before the leave proposal it commits.
//!
//! MDK drops such a commit for good and keeps its transport id as processed
//! (`docs/MDK_UPSTREAM_TRACKER.md` T-COMMIT-BEFORE-PROPOSAL, pinned by
//! `live_sync_burst_e2e::mdk_drops_for_good_a_commit_taken_in_before_the_proposal_it_commits`).
//! The member is then left with the leaver's eviction due, makes a rival of
//! its own, and the circle can end permanently split. Haven orders every
//! stored batch it hands the engine so that a proposal at the circle's
//! current epoch goes first: on the catch-up pager, the refetch by id and the
//! live plane's stored replay, including a background burst.
//!
//! Each test ends on the promise itself: the member is on ONE branch with the
//! committer (the same epoch, and a location each seals is one the other
//! reads), and its next full advance stages no rival eviction.
//!
//! The leave the late member reads is the leaver's proposal wrapped again
//! later ([`SessionManager::rewrap_handshake_for_test`]): a leaver whose clock
//! runs ahead of the committer's, which puts the proposal after its commit in
//! any order by `created_at`.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod helpers;

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{EpochState, GroupId, PendingStateRef, PublishWork};
use haven_core::nostr::mls::SessionManager;
use haven_core::relay::catchup::{run_catchup_all_circles, run_refused_refetch};
use haven_core::relay::fanout::scripted::ScriptedFanout;
use haven_core::relay::fanout::{DriveMode, LocationSeal, RecoveryCause, SendHeld};
use haven_core::relay::live_sync::{BacklogOutcome, CircleSpec, LiveSyncCore};
use haven_core::relay::scripted_relay::{Frame, ScriptedRelay};
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use helpers::drive::{
    epoch, leave_of, ngid, reads, roster, sealed_by, stored_fix, through, wait_out_the_engine,
    ManualClock, Recorder, HOUR_MS,
};
use helpers::{setup_circle, CircleFixture, CircleMember};
use nostr::{Event, Filter, Kind, RelayUrl, Timestamp};
use nostr_relay_builder::prelude::{
    BoxedFuture, MemoryDatabase, MemoryDatabaseOptions, NostrDatabase, PolicyResult, QueryPolicy,
};
use nostr_relay_builder::{LocalRelay, RelayBuilder};

const ALICE: usize = 0;
const BOB: usize = 1;
const CAROL: usize = 2;

// ═══════════════════════════════════════════════════════════════════════════
// Harness
// ═══════════════════════════════════════════════════════════════════════════

fn secs(event: &Event) -> i64 {
    i64::try_from(event.created_at.as_secs()).expect("a created_at fits")
}

/// Waits until the wall clock is past `secs`: the clock reading is the
/// quantity under test, never a stand-in for something else happening.
async fn wait_until_after(secs: i64) {
    while chrono::Utc::now().timestamp() <= secs {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// Asks `question` until it answers yes, for at most twenty seconds.
async fn eventually(mut question: impl FnMut() -> bool) -> bool {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        if question() {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// The eviction commit `admin`'s engine stages for a leave it took in, once
/// the engine's own deadlines for it have passed.
async fn stage_eviction(admin: &CircleMember, group: &GroupId) -> (Event, PendingStateRef) {
    for _ in 0..8 {
        let effects = admin
            .session()
            .stage_unrecorded_for_test(group)
            .await
            .expect("the admin's engine advances");
        if let Some(staged) = effects.publish.iter().find_map(|work| match work {
            PublishWork::AutoPublish { msg, pending } => Some((
                SessionManager::transport_message_to_event(msg).expect("a commit event"),
                *pending,
            )),
            _ => None,
        }) {
            return staged;
        }
        let wait = admin
            .session()
            .receive_retick_after(group)
            .await
            .expect("the engine still owes the eviction a deadline");
        tokio::time::sleep(wait).await;
    }
    panic!("the eviction commit never surfaced");
}

/// Bob's leave, Alice's eviction of him applied on her side as a relay's
/// acknowledgement would let her, and the leave wrapped again in a second
/// after the eviction's.
struct Departure {
    leave: Event,
    eviction: Event,
    late_leave: Event,
}

async fn depart(fx: &CircleFixture) -> Departure {
    let leave = leave_of(fx, BOB).await;
    wait_until_after(secs(&leave)).await;
    let admin = fx.admin();
    admin
        .session()
        .process_event(&leave)
        .await
        .expect("the admin takes the leave in");
    let (eviction, pending) = stage_eviction(admin, &fx.group).await;
    admin
        .session()
        .confirm_published(pending)
        .await
        .expect("the eviction is applied on the admin's side");
    wait_until_after(secs(&eviction)).await;
    let late_leave = fx.members[BOB]
        .session()
        .rewrap_handshake_for_test(&fx.group, &leave)
        .await
        .expect("the leaver, still at the leave's epoch, wraps it again");
    assert!(
        late_leave.created_at > eviction.created_at,
        "premise: the leave is dated after its eviction"
    );
    Departure {
        leave,
        eviction,
        late_leave,
    }
}

/// Carol ended on Alice's branch: Bob is gone at Alice's epoch, Carol's next
/// full advance stages no eviction of her own, and a location each of them
/// seals is one the other reads.
async fn assert_on_the_committers_branch(fx: &CircleFixture, plane: &str) {
    let (alice, carol) = (&fx.members[ALICE], &fx.members[CAROL]);
    assert_eq!(
        epoch(carol, &fx.group).await,
        epoch(alice, &fx.group).await,
        "{plane}: the member is not at the committer's epoch: the eviction was dropped"
    );
    assert!(
        !roster(carol, &fx.group)
            .await
            .contains(&fx.members[BOB].pubkey_hex()),
        "{plane}: the leaver is still on the member's roster"
    );
    // A full advance once the engine's own deadlines are due, as the next
    // foreground drive makes: it stages the leave's eviction if the member
    // still owes one.
    wait_out_the_engine(carol, &fx.group).await;
    let advanced = carol
        .session()
        .stage_unrecorded_for_test(&fx.group)
        .await
        .expect("the member's engine advances");
    assert!(
        !advanced.publish.iter().any(|work| matches!(
            work,
            PublishWork::AutoPublish { .. } | PublishWork::GroupEvolution { .. }
        )) && !matches!(
            carol.session().epoch_state(&fx.group).await,
            Some(EpochState::PendingPublish(_))
        ),
        "{plane}: the member stages an eviction of its own: a rival of the committer's"
    );
    let from_alice = sealed_by(alice, &fx.group, 11.0).await;
    let from_carol = sealed_by(carol, &fx.group, 12.0).await;
    assert!(
        reads(carol, &from_alice).await && reads(alice, &from_carol).await,
        "{plane}: the member and the committer do not read each other: two branches"
    );
}

/// A relay whose store the test writes directly, read through a real socket.
struct SeededRelay {
    _relay: LocalRelay,
    url: String,
    db: MemoryDatabase,
    /// The endpoint that declines NIP-77 in front of the relay, when
    /// [`SeededRelay::without_negentropy`] put one there.
    _declines: Option<helpers::neg_wire::NegWire>,
}

impl SeededRelay {
    async fn with(builder: RelayBuilder) -> Self {
        let _ = allow_ws_loopback_for_test();
        let db = MemoryDatabase::with_opts(MemoryDatabaseOptions {
            events: true,
            max_events: None,
        });
        let relay = LocalRelay::new(builder.database(db.clone()));
        relay.run().await.expect("seeded relay");
        let url = relay.url().await.to_string();
        Self {
            _relay: relay,
            url,
            db,
            _declines: None,
        }
    }

    /// This relay as one that does not speak NIP-77: where a chase that
    /// halts is the circle's only catch-up, which is what the tests that use
    /// it grade. On a relay that speaks NIP-77 the pass recovers what the
    /// chase could not reach, proposal first
    /// (`a_buried_proposal_and_its_commit_are_taken_in_proposal_first`).
    async fn without_negentropy(self) -> Self {
        let declines = helpers::neg_wire::NegWire::in_front_of(
            &self.url,
            helpers::neg_wire::NegPolicy::Notice("ERROR: bad msg: unknown cmd".into()),
        )
        .await;
        Self {
            url: declines.url.clone(),
            _declines: Some(declines),
            ..self
        }
    }

    async fn seed(&self, events: &[Event]) {
        for event in events {
            assert!(
                self.db.save_event(event).await.expect("seed").is_success(),
                "the relay must hold every seeded event"
            );
        }
    }
}

/// Refuses, while set, every page of a backward chase below the first: any
/// REQ whose `until` is older than `serve_above`.
#[derive(Debug)]
struct RefuseChasePages {
    serve_above: Arc<std::sync::Mutex<Timestamp>>,
    refusing: Arc<AtomicBool>,
}

impl QueryPolicy for RefuseChasePages {
    fn admit_query<'a>(
        &'a self,
        query: &'a Filter,
        _addr: &'a std::net::SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async move {
            let serve_above = *self.serve_above.lock().expect("the bound");
            match query.until {
                Some(until) if self.refusing.load(Ordering::SeqCst) && until < serve_above => {
                    PolicyResult::Reject("chase page withheld".to_string())
                }
                _ => PolicyResult::Accept,
            }
        })
    }
}

fn group_req(filter: &Filter) -> bool {
    filter
        .kinds
        .as_ref()
        .is_some_and(|kinds| kinds.contains(&Kind::Custom(445)))
}

/// Carol's live engine over `relays`, started and settled, then paused: the
/// next open is a background burst.
async fn paused_engine(fx: &CircleFixture, relays: &[&str]) -> LiveSyncCore {
    let carol = &fx.members[CAROL];
    let core = LiveSyncCore::new_local(
        Arc::clone(&carol.circle),
        carol.keys.public_key(),
        Arc::new(RelayManager::new()),
    );
    core.start(
        &[CircleSpec {
            group_id_hex: hex::encode(ngid(carol, &fx.group).await),
            relays: relays.iter().map(ToString::to_string).collect(),
        }],
        &[],
    )
    .await
    .expect("carol's engine starts");
    // `start` follows the circle's routing before it returns: a REQ issued
    // anywhere else is moved off at once, racing that relay's EOSE, and what
    // a test scripts there is never asked.
    let wanted: HashSet<RelayUrl> = relays
        .iter()
        .map(|relay| RelayUrl::parse(relay).expect("a relay url"))
        .collect();
    assert!(
        core.relays_in_pool_for_test()
            .await
            .into_iter()
            .collect::<HashSet<_>>()
            == wanted,
        "the harness starts carol's engine on the relays her circle routes to"
    );
    assert_eq!(
        core.wait_backlog_settled().await,
        BacklogOutcome::Settled,
        "the harness starts from a settled engine"
    );
    core.pause_subscriptions().await.expect("pause");
    core
}

// ═══════════════════════════════════════════════════════════════════════════
// The planes
// ═══════════════════════════════════════════════════════════════════════════

/// The catch-up pager: one page holding the eviction and its leave, the leave
/// dated later. Sorted by `created_at` alone the eviction goes first.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_member_catching_up_through_the_pager_ends_on_the_committers_branch() {
    let relay = SeededRelay::with(RelayBuilder::default()).await;
    let fx = setup_circle(3, &[relay.url.as_str()]).await;
    let departure = depart(&fx).await;
    relay
        .seed(&[departure.eviction.clone(), departure.late_leave.clone()])
        .await;

    let out = run_catchup_all_circles(&fx.members[CAROL].circle, &RelayManager::new(), 30).await;
    assert_eq!(out.relay_errors, 0, "premise: the relay answered");

    assert_on_the_committers_branch(&fx, "pager").await;
}

/// The refetch by id: both ids owed, one REQ brings both back.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_member_catching_up_through_a_refetch_by_id_ends_on_the_committers_branch() {
    let relay = SeededRelay::with(RelayBuilder::default()).await;
    let fx = setup_circle(3, &[relay.url.as_str()]).await;
    let departure = depart(&fx).await;
    relay
        .seed(&[departure.eviction.clone(), departure.late_leave.clone()])
        .await;
    let carol = &fx.members[CAROL];
    carol
        .session()
        .record_refused_for_test(&fx.group, &[departure.eviction.id, departure.late_leave.id]);

    run_refused_refetch(&carol.circle, &RelayManager::new(), 30).await;
    assert!(
        carol.session().engine_processed(&departure.eviction.id)
            && carol.session().engine_processed(&departure.late_leave.id),
        "premise: the refetch brought both owed ids back to the engine"
    );

    assert_on_the_committers_branch(&fx, "refetch by id").await;
}

/// The live plane, in a background burst: relay A serves the eviction and
/// relay B the leave, both before A's `EOSE`, and A's `EOSE` comes first.
/// Held per REQ and ordered at that `EOSE`, the pair reaches the engine as
/// one batch, the leave first; held per relay, A's batch would be the
/// eviction alone.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_member_catching_up_through_the_live_plane_from_two_relays_ends_on_the_committers_branch()
{
    let a = ScriptedRelay::start();
    let b = ScriptedRelay::start();
    let fx = setup_circle(3, &[a.url(), b.url()]).await;
    let departure = depart(&fx).await;
    let core = paused_engine(&fx, &[a.url(), b.url()]).await;

    let (open_b, b_opens) = tokio::sync::watch::channel(false);
    let (end_a, a_ends) = tokio::sync::watch::channel(false);
    let (end_b, b_ends) = tokio::sync::watch::channel(false);
    a.answer(
        group_req,
        vec![
            Frame::Event(departure.eviction.clone()),
            Frame::Hold(a_ends),
            Frame::Eose,
        ],
    );
    b.answer(
        group_req,
        vec![
            Frame::Hold(b_opens),
            Frame::Event(departure.late_leave.clone()),
            Frame::Hold(b_ends),
            Frame::Eose,
        ],
    );

    let taken = core.group_events_taken_in_for_test().len();
    core.open_background_burst().await.expect("burst opens");
    assert!(
        eventually(|| core.group_events_taken_in_for_test().len() > taken).await,
        "premise: the worker took relay A's eviction in"
    );
    open_b.send_replace(true);
    assert!(
        eventually(|| core.group_events_taken_in_for_test().len() > taken + 1).await,
        "premise: the worker took relay B's leave in, behind the eviction"
    );
    end_a.send_replace(true);
    let a_url = RelayUrl::parse(a.url()).expect("a relay url");
    assert!(
        eventually(|| core.endpoint_settled_for_test(&a_url)).await,
        "premise: relay A's EOSE was taken"
    );
    end_b.send_replace(true);
    assert_eq!(core.wait_backlog_settled().await, BacklogOutcome::Settled);
    let _ = core.stop().await;

    assert_on_the_committers_branch(&fx, "live plane").await;
}

/// A page cut between the leave and its eviction: a relay that serves one
/// event a page, newest first, hands the pager the eviction a page ahead of
/// the leave. The eviction is held until a later page has brought something,
/// so the leave reaches the engine first.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_page_cut_between_a_leave_and_its_eviction_still_ends_on_the_committers_branch() {
    let relay = SeededRelay::with(RelayBuilder::default().max_filter_limit(1)).await;
    let fx = setup_circle(3, &[relay.url.as_str()]).await;
    let departure = depart(&fx).await;
    assert!(
        departure.leave.created_at < departure.eviction.created_at,
        "premise: newest first, the eviction is the first page"
    );
    relay
        .seed(&[departure.leave.clone(), departure.eviction.clone()])
        .await;

    let out = run_catchup_all_circles(&fx.members[CAROL].circle, &RelayManager::new(), 30).await;
    assert_eq!(
        out.relay_errors, 0,
        "premise: the relay answered every page"
    );

    assert_on_the_committers_branch(&fx, "page cut").await;
}

/// A chase that halts at the cut, the next page never served: the held
/// eviction is not handed to the engine and holds the cursor, and the next
/// sweep, served in full, ends on the committer's branch. Handed over at the
/// halt, the eviction would be dropped for good before its leave arrived.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_held_eviction_a_halted_chase_never_paged_past_is_deferred_to_the_next_sweep() {
    let serve_above = Arc::new(std::sync::Mutex::new(Timestamp::from(u64::MAX)));
    let refusing = Arc::new(AtomicBool::new(true));
    let relay = SeededRelay::with(RelayBuilder::default().max_filter_limit(1).query_policy(
        RefuseChasePages {
            serve_above: Arc::clone(&serve_above),
            refusing: Arc::clone(&refusing),
        },
    ))
    .await
    .without_negentropy()
    .await;
    let fx = setup_circle(3, &[relay.url.as_str()]).await;
    let departure = depart(&fx).await;
    *serve_above.lock().expect("the bound") = departure.eviction.created_at + 1_u64;
    relay
        .seed(&[departure.leave.clone(), departure.eviction.clone()])
        .await;
    let carol = &fx.members[CAROL];
    let before = epoch(carol, &fx.group).await;
    let stream = haven_core::relay::live_sync::group_cursor_stream(&hex::encode(
        ngid(carol, &fx.group).await,
    ));

    let out = run_catchup_all_circles(&carol.circle, &RelayManager::new(), 30).await;
    assert_eq!(
        out.windows_truncated, 1,
        "premise: the chase halted at the page it was refused"
    );
    assert!(
        !carol.session().engine_processed(&departure.eviction.id)
            && epoch(carol, &fx.group).await == before,
        "the eviction held at the cut was handed to the engine although the chase never \
         paged past it"
    );
    assert_eq!(
        carol.circle.read_sync_cursor(&stream).expect("cursor read"),
        None,
        "a held eviction the sweep never handed over must hold the cursor"
    );

    refusing.store(false, Ordering::SeqCst);
    let again = run_catchup_all_circles(&carol.circle, &RelayManager::new(), 30).await;
    assert_eq!(
        again.relay_errors, 0,
        "premise: the relay answered every page"
    );

    assert_on_the_committers_branch(&fx, "halted chase").await;
}

// ═══════════════════════════════════════════════════════════════════════════
// Rule 10: what is held is applied before the burst seals
// ═══════════════════════════════════════════════════════════════════════════

/// A removal a fast relay serves is applied by the time that relay's `EOSE`
/// is taken, while a second relay never answers, and the location the burst
/// seals after its wait is one the removed member cannot read.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_removal_a_fast_relay_serves_is_applied_at_its_eose_while_a_slow_relay_stalls() {
    let fast = ScriptedRelay::start();
    let slow = ScriptedRelay::start();
    let fx = setup_circle(3, &[fast.url(), slow.url()]).await;
    let departure = depart(&fx).await;
    let core = paused_engine(&fx, &[fast.url(), slow.url()]).await;

    let (_never, stalls) = tokio::sync::watch::channel(false);
    fast.answer(
        group_req,
        vec![
            Frame::Event(departure.eviction.clone()),
            Frame::Event(departure.leave.clone()),
            Frame::Eose,
        ],
    );
    slow.answer(group_req, vec![Frame::Hold(stalls)]);

    core.open_background_burst().await.expect("burst opens");
    let fast_url = RelayUrl::parse(fast.url()).expect("a relay url");
    assert!(
        eventually(|| core.endpoint_settled_for_test(&fast_url)).await,
        "premise: the fast relay's EOSE was taken"
    );
    let (alice, bob, carol) = (&fx.members[ALICE], &fx.members[BOB], &fx.members[CAROL]);
    assert_eq!(
        epoch(carol, &fx.group).await,
        epoch(alice, &fx.group).await,
        "the removal the fast relay served was not applied when its EOSE was taken"
    );
    assert_eq!(
        core.wait_backlog_settled().await,
        BacklogOutcome::TimedOut,
        "premise: the slow relay never answers"
    );
    let sealed = sealed_by(carol, &fx.group, 21.0).await;
    assert!(
        !reads(bob, &sealed).await && reads(alice, &sealed).await,
        "the burst sealed its location under the epoch before the removal"
    );
    let _ = core.stop().await;
}

/// A removal a relay serves before it stalls, after the other relay's `EOSE`,
/// is applied when the burst's wait releases that relay — before the seal —
/// and what the released relay serves after that is taken in as it comes.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_removal_a_relay_serves_before_it_stalls_is_applied_before_the_burst_seals() {
    let fast = ScriptedRelay::start();
    let slow = ScriptedRelay::start();
    let fx = setup_circle(3, &[fast.url(), slow.url()]).await;
    let departure = depart(&fx).await;
    let core = paused_engine(&fx, &[fast.url(), slow.url()]).await;
    let (alice, bob, carol) = (&fx.members[ALICE], &fx.members[BOB], &fx.members[CAROL]);
    let later_fix = sealed_by(alice, &fx.group, 31.0).await;

    let (send_removal, removal_held) = tokio::sync::watch::channel(false);
    let (send_fix, fix_held) = tokio::sync::watch::channel(false);
    let (_never, stalls) = tokio::sync::watch::channel(false);
    fast.answer(group_req, vec![Frame::Eose]);
    slow.answer(
        group_req,
        vec![
            Frame::Hold(removal_held),
            Frame::Event(departure.eviction.clone()),
            Frame::Event(departure.leave.clone()),
            Frame::Hold(fix_held),
            Frame::Event(later_fix.clone()),
            Frame::Hold(stalls),
        ],
    );

    let taken = core.group_events_taken_in_for_test().len();
    core.open_background_burst().await.expect("burst opens");
    let fast_url = RelayUrl::parse(fast.url()).expect("a relay url");
    assert!(
        eventually(|| core.endpoint_settled_for_test(&fast_url)).await,
        "premise: the fast relay's EOSE was taken before the slow relay served"
    );
    send_removal.send_replace(true);
    assert!(
        eventually(|| core.group_events_taken_in_for_test().len() >= taken + 2).await,
        "premise: the worker took the slow relay's removal in"
    );
    assert_eq!(
        core.wait_backlog_settled().await,
        BacklogOutcome::TimedOut,
        "premise: the slow relay never ends its stored events"
    );
    let sealed = sealed_by(carol, &fx.group, 22.0).await;
    assert!(
        !reads(bob, &sealed).await && reads(alice, &sealed).await,
        "the burst sealed its location under the epoch before a removal it had taken in"
    );

    send_fix.send_replace(true);
    let mut stored = false;
    for _ in 0..2_000 {
        stored = stored_fix(carol, &fx.group, alice, 31.0).await;
        if stored {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(
        stored,
        "a relay the burst's wait released is still held: what it serves next waits for an \
         EOSE it never sends"
    );
    let _ = core.stop().await;
}

/// What the driver's seal answers for `member`'s circle `group` now: the
/// sealed event, or why there is none.
async fn driver_seal(
    member: &CircleMember,
    group: &GroupId,
    latitude: f64,
) -> Result<Event, SendHeld> {
    driver_seal_at(member, group, latitude, &ManualClock::at(0)).await
}

/// [`driver_seal`], with the driver's clock reading `clock`.
async fn driver_seal_at(
    member: &CircleMember,
    group: &GroupId,
    latitude: f64,
    clock: &ManualClock,
) -> Result<Event, SendHeld> {
    let (transport, outbox) = (ScriptedFanout::default(), Recorder::acking(true));
    match through(&transport, &outbox, clock, &DriveMode::Full)
        .seal_location(&member.circle, group, &LocationMessage::new(latitude, 2.0))
        .await
        .expect("the seal runs")
        .seal
    {
        LocationSeal::Sealed { event, .. } => Ok(*event),
        LocationSeal::Deferred(held) => Err(held),
    }
}

/// A chase that halts with a fetched removal held back, not taken in: no
/// location is sealed for the circle until it is, for the member it removes
/// would read it (Security Rule 10). The next sweep, served in full, takes
/// the removal in, and the seal it then allows is one that member cannot
/// read.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_location_is_sealed_while_a_halted_chase_holds_a_fetched_commit() {
    let serve_above = Arc::new(std::sync::Mutex::new(Timestamp::from(u64::MAX)));
    let refusing = Arc::new(AtomicBool::new(true));
    let relay = SeededRelay::with(RelayBuilder::default().max_filter_limit(1).query_policy(
        RefuseChasePages {
            serve_above: Arc::clone(&serve_above),
            refusing: Arc::clone(&refusing),
        },
    ))
    .await
    .without_negentropy()
    .await;
    let fx = setup_circle(3, &[relay.url.as_str()]).await;
    let departure = depart(&fx).await;
    *serve_above.lock().expect("the bound") = departure.eviction.created_at + 1_u64;
    relay
        .seed(&[departure.leave.clone(), departure.eviction.clone()])
        .await;
    let (alice, bob, carol) = (&fx.members[ALICE], &fx.members[BOB], &fx.members[CAROL]);

    let out = run_catchup_all_circles(&carol.circle, &RelayManager::new(), 30).await;
    assert_eq!(
        out.windows_truncated, 1,
        "premise: the chase halted at the cut"
    );
    assert!(
        !carol.session().engine_processed(&departure.eviction.id),
        "premise: the removal was held back, not taken in"
    );
    assert_eq!(
        driver_seal(carol, &fx.group, 41.0).await.err(),
        Some(SendHeld::StoredInput),
        "a location was sealed while a fetched removal was held back"
    );

    refusing.store(false, Ordering::SeqCst);
    let _ = run_catchup_all_circles(&carol.circle, &RelayManager::new(), 30).await;
    let sealed = driver_seal(carol, &fx.group, 42.0)
        .await
        .unwrap_or_else(|held| panic!("the seal is held after the removal was taken in: {held:?}"));
    assert!(
        !reads(bob, &sealed).await && reads(alice, &sealed).await,
        "the seal the next sweep allowed is readable by the member it removed"
    );
}

/// A live REQ holding a relay's stored replay, a removal among it, until an
/// `EOSE` the relay never sends: no location is sealed for the circle
/// meanwhile. Once the wait releases the relay and the replay is taken in,
/// the seal is one the removed member cannot read.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn no_location_is_sealed_while_a_live_req_holds_its_stored_replay() {
    let relay = ScriptedRelay::start();
    let fx = setup_circle(3, &[relay.url()]).await;
    let departure = depart(&fx).await;
    let core = paused_engine(&fx, &[relay.url()]).await;
    let (alice, bob, carol) = (&fx.members[ALICE], &fx.members[BOB], &fx.members[CAROL]);
    let (_never, stalls) = tokio::sync::watch::channel(false);
    relay.answer(
        group_req,
        vec![
            Frame::Event(departure.eviction.clone()),
            Frame::Event(departure.leave.clone()),
            Frame::Hold(stalls),
        ],
    );

    let taken = core.group_events_taken_in_for_test().len();
    core.open_background_burst().await.expect("burst opens");
    assert!(
        eventually(|| core.group_events_taken_in_for_test().len() >= taken + 2).await,
        "premise: the worker holds the relay's replay"
    );
    assert_eq!(
        driver_seal(carol, &fx.group, 51.0).await.err(),
        Some(SendHeld::StoredInput),
        "a location was sealed while a live REQ held a removal unread"
    );

    assert_eq!(
        core.wait_backlog_settled().await,
        BacklogOutcome::TimedOut,
        "premise: the relay never ends its stored events"
    );
    let sealed = driver_seal(carol, &fx.group, 52.0)
        .await
        .unwrap_or_else(|held| panic!("the seal is held after the replay was taken in: {held:?}"));
    assert!(
        !reads(bob, &sealed).await && reads(alice, &sealed).await,
        "the seal after the release is readable by the member it removed"
    );
    let _ = core.stop().await;
}

/// Holds, while closed, every page of a backward chase below the first
/// until the test opens it, and says when one is waiting.
#[derive(Debug)]
struct DelayChasePages {
    serve_above: Arc<std::sync::Mutex<Timestamp>>,
    waiting: Arc<AtomicBool>,
    open: tokio::sync::watch::Receiver<bool>,
}

impl QueryPolicy for DelayChasePages {
    fn admit_query<'a>(
        &'a self,
        query: &'a Filter,
        _addr: &'a std::net::SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async move {
            let serve_above = *self.serve_above.lock().expect("the bound");
            if query.until.is_some_and(|until| until < serve_above) {
                self.waiting.store(true, Ordering::SeqCst);
                let _ = self.open.clone().wait_for(|open| *open).await;
            }
            PolicyResult::Accept
        })
    }
}

/// A relay serving one event a page whose pages below the eviction are
/// refused while `refusing` is set, seeded with Bob's leave and its eviction;
/// Carol's sweep over it halts with the eviction held back.
async fn halted_with_the_eviction_held() -> (SeededRelay, CircleFixture, Departure, Arc<AtomicBool>)
{
    let serve_above = Arc::new(std::sync::Mutex::new(Timestamp::from(u64::MAX)));
    let refusing = Arc::new(AtomicBool::new(true));
    let relay = SeededRelay::with(RelayBuilder::default().max_filter_limit(1).query_policy(
        RefuseChasePages {
            serve_above: Arc::clone(&serve_above),
            refusing: Arc::clone(&refusing),
        },
    ))
    .await
    .without_negentropy()
    .await;
    let fx = setup_circle(3, &[relay.url.as_str()]).await;
    let departure = depart(&fx).await;
    *serve_above.lock().expect("the bound") = departure.eviction.created_at + 1_u64;
    relay
        .seed(&[departure.leave.clone(), departure.eviction.clone()])
        .await;
    let carol = &fx.members[CAROL];
    let out = run_catchup_all_circles(&carol.circle, &RelayManager::new(), 30).await;
    assert_eq!(
        out.windows_truncated, 1,
        "premise: the chase halted at the cut"
    );
    assert_eq!(
        driver_seal(carol, &fx.group, 61.0).await.err(),
        Some(SendHeld::StoredInput),
        "premise: the held eviction holds the circle's seals"
    );
    (relay, fx, departure, refusing)
}

/// Another plane taking the held commit in ends the hold: the live plane,
/// on the circle's relay, serves the leave and its eviction as the session
/// starts, and the seal that follows is allowed and unreadable by the member
/// removed, although no pager pass of the circle has completed since.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_held_commit_the_live_plane_takes_in_ends_the_hold() {
    let (relay, fx, _departure, _refusing) = halted_with_the_eviction_held().await;
    let (alice, bob, carol) = (&fx.members[ALICE], &fx.members[BOB], &fx.members[CAROL]);
    let core = paused_engine(&fx, &[relay.url.as_str()]).await;
    core.open_background_burst().await.expect("burst opens");
    assert_eq!(
        core.wait_backlog_settled().await,
        BacklogOutcome::Settled,
        "premise: the live plane took its replay in"
    );

    let sealed = driver_seal(carol, &fx.group, 62.0)
        .await
        .unwrap_or_else(|held| {
            panic!("the seal is held after the live plane took the commit in: {held:?}")
        });
    assert!(
        !reads(bob, &sealed).await && reads(alice, &sealed).await,
        "the seal after the live plane took the removal in is readable by the member it removed"
    );
    let _ = core.stop().await;
}

/// The session's plain ingest (what a caller decrypting one event makes)
/// taking the held commit in ends the hold too.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_held_commit_a_plain_ingest_takes_in_ends_the_hold() {
    let (_relay, fx, departure, _refusing) = halted_with_the_eviction_held().await;
    let (alice, bob, carol) = (&fx.members[ALICE], &fx.members[BOB], &fx.members[CAROL]);
    for event in [&departure.leave, &departure.eviction] {
        let _ = carol
            .session()
            .process_event(event)
            .await
            .expect("carol's engine takes the event");
    }

    // A plain ingest leaves the commit's own follow-up to the next drive: the
    // first seal may resolve it and ask to be called again, never wait on the
    // commit as unread.
    let sealed = match driver_seal(carol, &fx.group, 67.0).await {
        Err(SendHeld::Nothing) => driver_seal(carol, &fx.group, 67.0).await,
        first => first,
    }
    .unwrap_or_else(|held| panic!("the seal is held after an ingest took the commit in: {held:?}"));
    assert!(
        !reads(bob, &sealed).await && reads(alice, &sealed).await,
        "the seal after the ingest took the removal in is readable by the member it removed"
    );
}

/// A pass of the circle that completes without taking the held commit in
/// does not end the hold: here the relay serves nothing on the next sweep,
/// and the circle's seals are still held, for the commit is still fetched
/// and not in.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_pass_that_completes_without_the_held_commit_never_ends_the_hold() {
    let (relay, fx, _departure, _refusing) = halted_with_the_eviction_held().await;
    let carol = &fx.members[CAROL];
    relay
        .db
        .delete(Filter::new())
        .await
        .expect("the store empties");

    let again = run_catchup_all_circles(&carol.circle, &RelayManager::new(), 30).await;
    assert!(
        again.windows_truncated == 0 && again.relay_errors == 0,
        "premise: the next pass completed"
    );
    assert_eq!(
        driver_seal(carol, &fx.group, 63.0).await.err(),
        Some(SendHeld::StoredInput),
        "a pass that never took the held removal in ended its hold"
    );
}

/// A hold set after another plane already took the commit in — the late
/// insertion a pager or a live sink makes for a commit it classified before
/// that ingest — waits on nothing: the engine records the commit, so no
/// seal and no recovery read is held by it, and the seal is one the member
/// the commit removed cannot read.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_hold_set_after_another_plane_took_the_commit_in_never_holds_the_circle() {
    let relay = SeededRelay::with(RelayBuilder::default()).await;
    let fx = setup_circle(3, &[relay.url.as_str()]).await;
    let departure = depart(&fx).await;
    let (alice, bob, carol) = (&fx.members[ALICE], &fx.members[BOB], &fx.members[CAROL]);
    for event in [&departure.leave, &departure.eviction] {
        let _ = carol
            .session()
            .process_event(event)
            .await
            .expect("carol's engine takes the event");
    }
    assert!(
        carol.session().engine_processed(&departure.eviction.id),
        "premise: another plane took the removal in"
    );

    carol
        .session()
        .hold_pager_commits_for_test(&fx.group, &[departure.eviction.id]);
    let sealed = match driver_seal(carol, &fx.group, 68.0).await {
        Err(SendHeld::Nothing) => driver_seal(carol, &fx.group, 68.0).await,
        first => first,
    }
    .unwrap_or_else(|held| {
        panic!("a hold set after the commit was taken in held the seal: {held:?}")
    });
    assert!(
        !reads(bob, &sealed).await && reads(alice, &sealed).await,
        "the seal is readable by the member the commit removed"
    );
    assert_eq!(
        carol
            .circle
            .circle_recovery_for_test(&fx.group, true)
            .await
            .expect("the recovery read"),
        None,
        "a hold on a commit already taken in is reported as holding the circle"
    );
}

/// A held commit no ingest took in, which the engine does not record, holds
/// every seal and every recovery read however long it stands — days on the
/// driver's clock — and only its ingest ends the hold, with a seal the member
/// it removes cannot read (Security Rule 12: fail closed, never on time).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_held_commit_no_ingest_took_in_still_holds_every_seal_and_recovery_read() {
    let (_relay, fx, departure, _refusing) = halted_with_the_eviction_held().await;
    let (alice, bob, carol) = (&fx.members[ALICE], &fx.members[BOB], &fx.members[CAROL]);
    assert!(
        !carol.session().engine_processed(&departure.eviction.id),
        "premise: the removal was held back, not taken in"
    );
    let (transport, outbox, clock) = (
        ScriptedFanout::default(),
        Recorder::acking(true),
        ManualClock::at(0),
    );
    for day in 1..=3_u64 {
        clock.set(day * 25 * HOUR_MS);
        assert_eq!(
            driver_seal_at(carol, &fx.group, 69.0, &clock).await.err(),
            Some(SendHeld::StoredInput),
            "a location was sealed past a held removal no ingest took in"
        );
        assert_eq!(
            through(&transport, &outbox, &clock, &DriveMode::Full)
                .circle_recovery(&carol.circle, &fx.group)
                .await
                .expect("the recovery read"),
            Some(RecoveryCause::StoredInput),
            "the recovery read does not name the held removal"
        );
    }

    for event in [&departure.leave, &departure.eviction] {
        let _ = carol
            .session()
            .process_event(event)
            .await
            .expect("carol's engine takes the event");
    }
    let sealed = match driver_seal_at(carol, &fx.group, 70.0, &clock).await {
        Err(SendHeld::Nothing) => driver_seal_at(carol, &fx.group, 70.0, &clock).await,
        first => first,
    }
    .unwrap_or_else(|held| panic!("the seal is held after an ingest took the commit in: {held:?}"));
    assert!(
        !reads(bob, &sealed).await && reads(alice, &sealed).await,
        "the seal after the ingest took the removal in is readable by the member it removed"
    );
}

/// A held commit is what the circle's recovery read names, in the
/// foreground and out of it: the circle's card tells the user why it is not
/// sharing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_held_commit_is_read_as_stored_input_by_the_circles_recovery() {
    let (_relay, fx, _departure, _refusing) = halted_with_the_eviction_held().await;
    let carol = &fx.members[CAROL];
    for foreground in [true, false] {
        assert_eq!(
            carol
                .circle
                .circle_recovery_for_test(&fx.group, foreground)
                .await
                .expect("the recovery read"),
            Some(RecoveryCause::StoredInput),
            "the recovery read (foreground: {foreground}) does not name the held removal"
        );
    }
}

/// A commit held at one page of a chase holds the circle's seals while the
/// next page is still on its way, not only once the chase halts: a seal made
/// meanwhile is held, and the one made after the chase completed is
/// unreadable by the member removed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_seal_racing_the_next_page_of_a_chase_is_held() {
    let serve_above = Arc::new(std::sync::Mutex::new(Timestamp::from(u64::MAX)));
    let waiting = Arc::new(AtomicBool::new(false));
    let (open, opened) = tokio::sync::watch::channel(false);
    let relay = SeededRelay::with(RelayBuilder::default().max_filter_limit(1).query_policy(
        DelayChasePages {
            serve_above: Arc::clone(&serve_above),
            waiting: Arc::clone(&waiting),
            open: opened,
        },
    ))
    .await;
    let fx = setup_circle(3, &[relay.url.as_str()]).await;
    let departure = depart(&fx).await;
    *serve_above.lock().expect("the bound") = departure.eviction.created_at + 1_u64;
    relay
        .seed(&[departure.leave.clone(), departure.eviction.clone()])
        .await;
    let (alice, bob, carol) = (&fx.members[ALICE], &fx.members[BOB], &fx.members[CAROL]);

    let sweeping = Arc::clone(&carol.circle);
    let sweep =
        tokio::spawn(
            async move { run_catchup_all_circles(&sweeping, &RelayManager::new(), 30).await },
        );
    assert!(
        eventually(|| waiting.load(Ordering::SeqCst)).await,
        "premise: the chase asked for its next page"
    );
    assert!(
        !carol.session().engine_processed(&departure.eviction.id),
        "premise: the eviction is held back, not taken in"
    );
    assert_eq!(
        driver_seal(carol, &fx.group, 64.0).await.err(),
        Some(SendHeld::StoredInput),
        "a location was sealed while a chase held a fetched removal for its next page"
    );

    open.send(true).expect("the pages open");
    let out = sweep.await.expect("the sweep runs");
    assert_eq!(out.windows_truncated, 0, "premise: the chase completed");
    let sealed = driver_seal(carol, &fx.group, 65.0)
        .await
        .unwrap_or_else(|held| {
            panic!("the seal is held after the chase took the removal in: {held:?}")
        });
    assert!(
        !reads(bob, &sealed).await && reads(alice, &sealed).await,
        "the seal after the chase is readable by the member it removed"
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// The ordering fails open
// ═══════════════════════════════════════════════════════════════════════════

/// A `kind:445` under `group`'s routing id, signed by a stranger, dated
/// `at`, with `content`: nothing a member's exporter opens.
fn stranger_445(h: &str, at: u64, content: &str) -> Event {
    nostr::EventBuilder::new(Kind::Custom(445), content)
        .tags(vec![nostr::Tag::parse(["h", h]).expect("an h tag")])
        .custom_created_at(Timestamp::from(at))
        .sign_with_keys(&nostr::Keys::generate())
        .expect("signed")
}

/// The ordering drops nothing and errs on nothing: an event no exporter
/// opens keeps its place by `(created_at, id)` while the leave still goes
/// first; and a circle the engine cannot read, or a classification that
/// panics, leaves the batch exactly as given.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_ordering_keeps_every_event_and_falls_back_to_the_order_given() {
    let fx = setup_circle(3, &["wss://order.fail-open.example.com"]).await;
    let departure = depart(&fx).await;
    let carol = &fx.members[CAROL];
    let h = hex::encode(ngid(carol, &fx.group).await);
    let ids = |events: &[Event]| events.iter().map(|event| event.id).collect::<Vec<_>>();
    let garbage = stranger_445(
        &h,
        departure.late_leave.created_at.as_secs() + 1,
        "bm90IGEgbWVzc2FnZQ==",
    );

    let given = vec![
        garbage.clone(),
        departure.eviction.clone(),
        departure.late_leave.clone(),
    ];
    assert_eq!(
        ids(&carol
            .session()
            .order_for_ingest_for_test(&fx.group, given.clone())
            .await),
        vec![departure.late_leave.id, departure.eviction.id, garbage.id],
        "the leave goes first, and an event nothing opens keeps its sorted place"
    );

    let unreadable = GroupId::new(vec![0x42; 32]);
    assert_eq!(
        ids(&carol
            .session()
            .order_for_ingest_for_test(&unreadable, given.clone())
            .await),
        ids(&given),
        "a circle whose exporter cannot be read must leave the batch as given, whole"
    );

    let panics = stranger_445(
        &h,
        departure.eviction.created_at.as_secs(),
        haven_core::nostr::mls::ORDER_PANIC_FOR_TEST,
    );
    let given = vec![
        departure.eviction.clone(),
        panics,
        departure.late_leave.clone(),
    ];
    assert_eq!(
        ids(&carol
            .session()
            .order_for_ingest_for_test(&fx.group, given.clone())
            .await),
        ids(&given),
        "a classification that panics must leave the batch as given, whole"
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// NIP-77: a buried leave and its eviction (`relay::negentropy`)
// ═══════════════════════════════════════════════════════════════════════════

/// Holds every by-id REQ until `open` reads true, saying when one waits.
#[derive(Debug)]
struct GateByIdAsks {
    waiting: Arc<AtomicBool>,
    open: tokio::sync::watch::Receiver<bool>,
}

impl QueryPolicy for GateByIdAsks {
    fn admit_query<'a>(
        &'a self,
        query: &'a Filter,
        _addr: &'a std::net::SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async move {
            if query.ids.as_ref().is_some_and(|ids| !ids.is_empty()) {
                self.waiting.store(true, Ordering::SeqCst);
                let _ = self.open.clone().wait_for(|open| *open).await;
            }
            PolicyResult::Accept
        })
    }
}

/// The leave, wrapped again after its eviction, and the eviction, both under a
/// full page of junk in the second above them that no page of the pager steps
/// below. A relay that speaks NIP-77 reports both; the pass fetches them by id
/// in one ask and hands the engine the leave first. While that ask is out, a
/// seal for the circle is held (Security Rule 10); afterwards Carol is on the
/// committer's branch, and the seal she then makes the leaver cannot read.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_buried_proposal_and_its_commit_are_taken_in_proposal_first() {
    let waiting = Arc::new(AtomicBool::new(false));
    let (open, opened) = tokio::sync::watch::channel(false);
    let relay = SeededRelay::with(RelayBuilder::default().query_policy(GateByIdAsks {
        waiting: Arc::clone(&waiting),
        open: opened,
    }))
    .await;
    let fx = setup_circle(3, &[relay.url.as_str()]).await;
    let departure = depart(&fx).await;
    let carol = &fx.members[CAROL];
    let routing = hex::encode(ngid(carol, &fx.group).await);
    let above = departure.late_leave.created_at.as_secs() + 1;
    let pile: Vec<Event> = (0..500)
        .map(|i| {
            nostr::EventBuilder::new(Kind::Custom(445), format!("cGlsZQ-{i}"))
                .tags(vec![
                    nostr::Tag::parse(["h", &routing]).expect("an h tag"),
                    nostr::Tag::parse(["h", &hex::encode([0x11u8; 32])]).expect("an h tag"),
                ])
                .custom_created_at(Timestamp::from(above))
                .sign_with_keys(&nostr::Keys::generate())
                .expect("signed")
        })
        .collect();
    relay
        .seed(&[departure.late_leave.clone(), departure.eviction.clone()])
        .await;
    relay.seed(&pile).await;
    wait_until_after(i64::try_from(above).unwrap()).await;
    let (alice, bob) = (&fx.members[ALICE], &fx.members[BOB]);

    let sweeping = Arc::clone(&carol.circle);
    let sweep =
        tokio::spawn(
            async move { run_catchup_all_circles(&sweeping, &RelayManager::new(), 30).await },
        );
    assert!(
        eventually(|| waiting.load(Ordering::SeqCst)).await,
        "premise: the pass asked for what the pager could not reach"
    );
    assert_eq!(
        driver_seal(carol, &fx.group, 66.0).await.err(),
        Some(SendHeld::StoredInput),
        "a location was sealed while a pass held fetched input not yet taken in"
    );
    open.send(true).expect("the asks open");
    let _ = sweep.await.expect("the sweep runs");

    assert_on_the_committers_branch(&fx, "reconciliation").await;
    let sealed = driver_seal(carol, &fx.group, 67.0)
        .await
        .unwrap_or_else(|held| panic!("the seal is held after the pass took both in: {held:?}"));
    assert!(
        !reads(bob, &sealed).await && reads(alice, &sealed).await,
        "the seal after the pass is readable by the member it removed"
    );
}
