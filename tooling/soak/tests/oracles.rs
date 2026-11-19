//! Positive controls for every oracle in the registry, and the bounds table.
//!
//! An oracle that has never gone red is an assertion nobody has tested. Each
//! test here plants ONE defect, in the product's own terms wherever the product
//! can be made to produce it, and requires the oracle to report exactly that —
//! then removes the plant and requires the same oracle to hold, so a control
//! cannot pass by being red about everything.
//!
//! # No `assert_eq!` here
//!
//! The identifier guard's Rust pass over `tooling/soak` reads every argument of
//! the `assert!` family after the first, so `assert_eq!(a, b)` puts `b`'s
//! expression text — which routinely names an epoch, a circle or a relay — into
//! a scanned position. `assert!(a == b, "<literal>")` puts only a literal there,
//! and reads better besides.
//!
//! # Bounds are re-derived, never spelled
//!
//! `bounds_are_the_products_own_constants` imports the constants themselves and
//! recomputes each function's value. The day one of them moves, this file moves
//! with it — which is the point: a test that spelled `94` would go on asserting
//! a bound the product no longer has.

use std::time::Duration;

use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::nostr::mls::types::{GroupId, UNRESOLVABLE_INPUT_MAX_AGE_SECS};
use haven_core::relay::fanout::{FanoutClock as _, LocationSeal, SendHeld, WallClock};
use haven_core::relay::live_sync::config::{
    BACKOFF_JITTER_FRACTION_BP, BACKOFF_MAX_SECS, BURST_BACKLOG_WAIT_SECS,
    COMMIT_SETTLE_WINDOW_SECS, DELIVERY_SILENCE_RETENTION_MULTIPLE, SUBSCRIBE_CONNECT_WAIT_SECS,
    SUBSCRIBE_MAX_ATTEMPTS, SUBSCRIBE_RETRY_WAIT_SECS,
};
use haven_core::relay::GROUP_RESUBSCRIBE_BUFFER_SECS;
use tokio::time::{Instant, MissedTickBehavior};

use haven_soak::nemesis::types::{DropClass, Fault, Schedule};
use haven_soak::oracle::quiescence::{self, PendingReason, Quiescence, Settled};
use haven_soak::oracle::undecryptable::{self, Probe, StoredRow};
use haven_soak::oracle::vacuity::{grade, ExpectationFloor, FloorTerm, Observed};
use haven_soak::oracle::{
    bounds, Finding, Invariant, ProbeToken, Reach, Recovery, RemovalPath, RemovalProbe, RemovalRow,
    RemovalStage, RetentionEdge, Round, Verdict,
};
use haven_soak::profiles::{ProfileName, ProfileSpec, WorldShape};
use haven_soak::rc::Rc;
use haven_soak::relay::{planes_for, NegFrame, SimRelay};
use haven_soak::rig::{
    poll_until, CapturedLine, Change, DeviceTag, LogDrain, PublishVerdict, RelayPlane, SimWorld,
};
use haven_soak::scenarios::s02_receiver_partition::unwitnessed_control;
use haven_soak::scenarios::s05_publish_confirm::acked_kill_control;
use haven_soak::scenarios::s08_live_plane_burial::below_the_cap_control;
use haven_soak::scenarios::s12_key_package_rotation::unexpired_control;
use haven_soak::scenarios::s14_restart_race::{
    co_admin, deafen, merge_race, stage_race, SecondCommit,
};
use haven_soak::scenarios::s20_catchup_sweep::empty_store_control;
use haven_soak::scenarios::s23_chained_backlog::one_commit_control;
use haven_soak::scenarios::s24_routing_collision::uncollided_control;
use haven_soak::scenarios::s25_silent_relays::answering_control;
use haven_soak::scenarios::s26_identity_planes::no_pool_control;
use haven_soak::scenarios::s27_mesh_independence::{self, sent_digest};
use haven_soak::scenarios::s28_member_bridging;
use haven_soak::scenarios::Scenario;
use haven_soak::timeline::Timeline;

/// A drain with nothing in it.
///
/// The one environment plane this file doubles, and the only one it may: no
/// oracle and no scenario reads a captured line, while the log sink itself is
/// process-global — installing it from a test binary would make one test's
/// verdict depend on which other test got there first. The relay is A2's real
/// plane over a real socket and the timeline is A5's real sink, because every
/// control here turns on what really crossed a wire or was really recorded.
#[derive(Clone, Copy, Default)]
struct EmptyDrain;

impl LogDrain for EmptyDrain {
    fn drain_since(&self, _from: u64) -> Vec<CapturedLine> {
        Vec::new()
    }
}

type World = SimWorld<SimRelay, Timeline, EmptyDrain>;

/// How often a bounded wait in this file re-reads its condition.
const POLL: Duration = Duration::from_millis(20);

/// The world's tick for these controls. A harness cadence, not a product bound.
const TICK: Duration = Duration::from_millis(20);

/// Two devices, one circle, one relay — the smallest world in which one peer can
/// receive what another sent.
const fn smallest_shape() -> WorldShape {
    WorldShape {
        members: 2,
        circles: 1,
        relays: 1,
        account_relays: 1,
        profile_relays: 0,
    }
}

async fn build_world() -> World {
    build_shaped_world(&smallest_shape()).await
}

/// A world of exactly `shape`, on as many relay planes as the shape declares.
async fn build_shaped_world(shape: &WorldShape) -> World {
    SimWorld::build(
        shape,
        Schedule::new(Vec::new()),
        planes_for(shape).await.expect("the relay planes start"),
        Timeline::in_memory(),
        EmptyDrain,
    )
    .await
    .expect("the world builds")
}

/// A round with every term a check could want. Built per test so the one term
/// that test cares about is visible against a fixed background.
const fn round(ordinal: u32) -> Round<'static> {
    Round {
        ordinal,
        reach: Reach::EveryOrderedPair,
        recovery: Recovery::Undisturbed,
        tick: TICK,
        // A settled world gates nothing, so any positive envelope would let a
        // real row pile-up through.
        row_envelope: 0,
        burst_opened: &[],
        classified: &[],
        // O4's subject, fed by the one arm that crosses the window; a
        // round that feeds none declares none. O3's removal probes are the same.
        retention: &[],
        forward_secrecy: &[],
    }
}

/// The two devices of the smallest world.
fn pair(world: &World) -> (DeviceTag, DeviceTag) {
    (world.devices()[0].tag, world.devices()[1].tag)
}

/// The circle every device in the smallest world belongs to.
fn group(world: &World) -> GroupId {
    world.circles()[0].mls_group_id().clone()
}

/// Waits, bounded, for every device to hold the same epoch for `group`.
async fn wait_until_epochs_agree(world: &World, group: &GroupId, bound: Duration) -> bool {
    let started = Instant::now();
    let mut ticker = tokio::time::interval(POLL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        let mut epochs = Vec::with_capacity(world.devices().len());
        for device in world.devices() {
            epochs.push(
                device
                    .manager()
                    .expect("a manager")
                    .group_epoch(group)
                    .await
                    .expect("an epoch"),
            );
        }
        if epochs.windows(2).all(|pair| pair[0] == pair[1]) {
            return true;
        }
        if started.elapsed() >= bound {
            return false;
        }
        ticker.tick().await;
    }
}

// ── The bounds table ────────────────────────────────────────────────────────

#[test]
fn bounds_are_the_products_own_constants_recomputed() {
    assert!(
        bounds::subscribe_ladder()
            == Duration::from_secs(
                SUBSCRIBE_CONNECT_WAIT_SECS
                    + u64::from(SUBSCRIBE_MAX_ATTEMPTS - 1) * SUBSCRIBE_RETRY_WAIT_SECS
            ),
        "the subscribe ladder is the connect wait plus the retries behind it"
    );
    assert!(
        bounds::settle() == Duration::from_secs(COMMIT_SETTLE_WINDOW_SECS),
        "the settle window is the engine's own commit settle window"
    );
    assert!(
        bounds::burst_backlog_wait() == Duration::from_secs(BURST_BACKLOG_WAIT_SECS),
        "the backlog wait is the engine's own burst backlog wait"
    );
    assert!(
        bounds::unresolvable_input_max_age()
            == Duration::from_secs(UNRESOLVABLE_INPUT_MAX_AGE_SECS),
        "the unresolvable horizon is the product's own, which is itself the \
         kind-445 retention plus the receiver's clock-skew grace"
    );
    assert!(
        bounds::unresolvable_input_max_age() > Duration::from_secs(LOCATION_MESSAGE_RETENTION_SECS),
        "and it is strictly past the retention, because the receive screen still \
         accepts an event at exactly the retention"
    );
    assert!(
        bounds::silence_window()
            == Duration::from_secs(
                DELIVERY_SILENCE_RETENTION_MULTIPLE.unsigned_abs()
                    * LOCATION_MESSAGE_RETENTION_SECS
            ),
        "the silence window is a whole number of kind-445 retention windows"
    );
    assert!(
        bounds::throttled_backoff()
            == Duration::from_millis(
                BACKOFF_MAX_SECS * 1_000 * (10_000 + u64::from(BACKOFF_JITTER_FRACTION_BP))
                    / 10_000
            ),
        "the throttle ceiling is the capped backoff plus its jitter fraction"
    );
    assert!(
        bounds::throttled_backoff_floor()
            == Duration::from_millis(
                BACKOFF_MAX_SECS * 1_000 * (10_000 - u64::from(BACKOFF_JITTER_FRACTION_BP))
                    / 10_000
            ),
        "the throttle floor is the capped backoff minus its jitter fraction"
    );
    assert!(
        bounds::throttled_backoff_floor() < Duration::from_secs(BACKOFF_MAX_SECS),
        "the one LOWER bound in the table, and the only thing that tells the two \
         ClosedKind arms apart"
    );
    // `pool_reconnect` has no case here on purpose: its three constants are
    // `pub(super)` in the pinned pool crate, so a test could only compare this
    // crate to itself. The soak-tooling grep of the vendored `constants.rs` is
    // its control, and `self_check` covers everything that CAN be re-derived.
    assert!(
        bounds::pool_reconnect() > bounds::subscribe_ladder(),
        "a pool reconnect is the slowest term in any recovery path"
    );
    // `location_publish_window` has no re-derivation here for the same reason:
    // both of its constants are private to haven-core's relay manager, which
    // carries its own compile-time assertion that the attempt count is one.
    // What IS checkable from here is the relation every arm depends on.
    assert!(
        bounds::location_publish_window() < bounds::withheld_publish_ladder(),
        "a location is ONE bounded attempt and a commit is a ladder, so an arm \
         that priced a withheld location at the commit ladder would wait for \
         attempts the product never makes"
    );
    assert!(
        bounds::resubscribe_lookback()
            == Duration::from_secs(GROUP_RESUBSCRIBE_BUFFER_SECS.unsigned_abs() + 1),
        "the lookback is the resubscribe buffer plus the one second `since` and a cursor \
         are both counted in"
    );
    bounds::self_check().expect("every re-derivable bound matches its source constant");
}

// ── O1 ──────────────────────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o1_fails_when_the_relay_swallows_the_acknowledgement_and_holds_once_it_is_healed() {
    let mut world = build_world().await;

    // The plant: the relay stores the location and the `OK` never reaches the
    // publisher. Rule 13's own shape — "the relay has it" is not an ack — and
    // the reason O1 requires a witnessed acknowledgement before it will even
    // start waiting for a delivery.
    world.relays_mut()[0]
        .apply(Fault::SwallowOk)
        .await
        .expect("the plane takes the fault");

    let (alice, _) = pair(&world);
    let circle = world.circles()[0].tag;
    let verdict = Invariant::LocationRoundTrip
        .check(&mut world, &round(1))
        .await
        .expect("the oracle reads");
    assert!(
        verdict
            == Verdict::Failed(Finding::ProbeNotPublished {
                device: alice,
                circle
            }),
        "a probe no relay acknowledged did not leave, whatever the relay's own store holds"
    );
    assert!(
        verdict.rc() == Rc::ViolationOrLeak,
        "an unacknowledged send is a finding about the subject"
    );

    world.relays_mut()[0]
        .apply(Fault::Heal)
        .await
        .expect("the plane heals");
    let healed = Invariant::LocationRoundTrip
        .check(&mut world, &round(2))
        .await
        .expect("the oracle reads");
    assert!(
        healed == Verdict::Holds,
        "the same oracle on the same world must go green once the plant is removed, \
         or it is not a control"
    );

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o1_refuses_to_grade_a_round_that_probes_nothing() {
    let mut world = build_world().await;
    let mut empty = round(1);
    empty.reach = Reach::These(&[]);
    let verdict = Invariant::LocationRoundTrip
        .check(&mut world, &empty)
        .await
        .expect("the oracle reads");
    assert!(
        verdict == Verdict::Failed(Finding::NothingProbed),
        "a round that probed no pair proves nothing, and a clean verdict would say \
         otherwise"
    );
    assert!(
        verdict.rc() == Rc::Unusable,
        "proving nothing is unusable, never clean and never a violation"
    );
    world.teardown().await.expect("teardown");
}

// ── O2 ──────────────────────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o2_holds_on_a_converged_world_and_fails_while_a_commit_is_staged_and_unresolved() {
    let mut world = build_world().await;
    let (alice, _) = pair(&world);
    let group = group(&world);

    assert!(
        Invariant::SendPathLiveness
            .check(&mut world, &round(1))
            .await
            .expect("the oracle reads")
            == Verdict::Holds,
        "a freshly built circle agrees on everything and can send"
    );

    // The plant, in the product's own terms: a commit staged under its record
    // and neither confirmed nor rolled back. Every READ accessor is still
    // cheerful about this group — which is exactly why O2 carries a send
    // attempt.
    let staged = world
        .device(alice)
        .expect("alice")
        .manager()
        .expect("a manager")
        .update_circle_relays_staging(&group, &relay_set(&world), WallClock.now_ms())
        .await
        .expect("a relay-list commit stages");
    assert!(staged.commit.is_some(), "premise: a commit was staged");

    let verdict = Invariant::SendPathLiveness
        .check(&mut world, &round(2))
        .await
        .expect("the oracle reads");
    // `converged_member_pubkeys` answers `NotConverged` while a commit is in
    // flight, and O2 reads it before it attempts anything — so this control
    // never reaches the send attempt. That is the right order (an accepted send
    // discharges a removal deferral, so the reads must come first), and it is
    // also why the send attempt has no positive control of its own in this
    // phase: the state in which every read accessor is cheerful about a group
    // that cannot send is an unrecovered removal-bearing staged commit, which
    // needs machinery no Phase-1 scenario builds.
    assert!(
        verdict
            == Verdict::Failed(Finding::RosterNotConverged {
                device: alice,
                circle: world.circles()[0].tag
            }),
        "a group with a commit in flight holds no converged roster, and a clean \
         verdict would report agreement nobody has"
    );
    assert!(
        verdict.rc() == Rc::ViolationOrLeak,
        "a circle that cannot send is a finding about the subject"
    );

    // The product's driver resolves the plant: a relay acknowledges it, it is
    // confirmed, and every device follows it.
    let resumed = world.resume(alice).await.expect("the driver runs");
    assert!(!resumed.errored, "the staged commit's drive erred");
    assert!(
        wait_until_epochs_agree(&world, &group, bounds::round_trip(Recovery::Undisturbed)).await,
        "the confirmed commit was not followed by every device"
    );

    assert!(
        Invariant::SendPathLiveness
            .check(&mut world, &round(3))
            .await
            .expect("the oracle reads")
            == Verdict::Holds,
        "and the same oracle goes green once the commit is resolved"
    );

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o2_fails_a_send_held_by_unread_input_that_never_ends() {
    let mut world = build_world().await;
    let (alice, _) = pair(&world);
    let group = group(&world);

    // The plant: a commit the pager holds back that no ingest will ever take
    // in. Every read O2 makes is still cheerful, so this reaches the send
    // attempt, which waits out unread input before it seals — and must then
    // grade a hold that never ends rather than wait past it.
    let never_taken_in = nostr::EventId::from_slice(&[7; 32]).expect("32 bytes is an event id");
    world
        .device(alice)
        .expect("alice")
        .session()
        .expect("a session")
        .hold_pager_commits_for_test(&group, &[never_taken_in]);

    let verdict = Invariant::SendPathLiveness
        .check(&mut world, &round(1))
        .await
        .expect("the oracle reads");
    assert!(
        verdict
            == Verdict::Failed(Finding::SendRefused {
                device: alice,
                circle: world.circles()[0].tag,
                cause: undecryptable::Verdict::SendDeferred,
            }),
        "a send held by input the device never takes in is refused, and the \
         wait ahead of the attempt is bounded rather than a pass"
    );
    assert!(
        verdict.rc() == Rc::ViolationOrLeak,
        "a circle that cannot send is a finding about the subject"
    );

    world.teardown().await.expect("teardown");
}

/// The circle's relay set plus one more, which is what makes a relay-list commit
/// a change rather than a no-op.
fn relay_set(world: &World) -> Vec<String> {
    let mut relays = world.relay_urls();
    relays.push("wss://o2-control.example.com".to_string());
    relays
}

// ── O4 ──────────────────────────────────────────────────────────────────────

/// One location ciphertext, sealed at `device`'s CURRENT epoch and never
/// published.
///
/// Never published, deliberately: a peer with a live engine would ingest it the
/// moment it crossed the relay, and the engine answers a second ingest of one
/// MLS message with `Stale { AlreadySeen }` — so the retention edge would be
/// graded on a duplicate rather than on the window.
async fn sealed_now(world: &World, device: DeviceTag, group: &GroupId) -> nostr::Event {
    let sender = world.device(device).expect("a device");
    let (event, _, _) = sender
        .manager()
        .expect("a manager")
        .seal_location_for_test(group, &ProbeToken::mint(9, 9).as_location())
        .await
        .expect("a location seals at the current epoch");
    event
}

/// Advances the group by `count` confirmed commits, and waits for both devices
/// to sit on the result.
///
/// Each commit carries a DIFFERENT relay list, across calls too: a repeat of
/// the list the group already holds is a no-op, and a no-op advances no epoch
/// — which would leave the window uncrossed while the arm believed it had
/// crossed it.
async fn advance_epochs(world: &World, device: DeviceTag, group: &GroupId, count: u64) {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    for _ in 0..count {
        let index = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let mut relays = world.relay_urls();
        relays.push(format!("wss://o4-{index}.example.com"));
        let changed = world
            .change(
                device,
                Change::Relays {
                    group,
                    relays: &relays,
                },
            )
            .await
            .expect("the driver makes the change");
        assert!(
            changed.verdict == PublishVerdict::Confirmed,
            "a commit nobody acked may not be merged (Rule 13)"
        );
    }
    assert!(
        wait_until_epochs_agree(world, group, bounds::round_trip(Recovery::Undisturbed)).await,
        "both devices must reach the epoch the window is measured from"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o4_grades_both_edges_of_the_window_the_engine_really_keeps() {
    // The window is READ, never spelled: `DEFAULT_MAX_PAST_EPOCHS` is how many
    // past epochs' exporter secrets the engine keeps (Security Rule 5), and
    // `haven-core/tests/security_rule_gates.rs` is what pins its value. What
    // this adds is the same two edges over a real relay and a real live plane.
    let window = u64::try_from(haven_core::nostr::mls::DEFAULT_MAX_PAST_EPOCHS)
        .expect("a retention window fits a u64");
    let mut world = build_world().await;
    let (alice, bob) = pair(&world);
    let group = group(&world);

    // `outside` is sealed one epoch older than `inside`, so after the same
    // advances one lands exactly at the window's edge and the other one past it.
    let outside = sealed_now(&world, alice, &group).await;
    advance_epochs(&world, alice, &group, 1).await;
    let inside = sealed_now(&world, alice, &group).await;
    advance_epochs(&world, alice, &group, window).await;

    let inside_outcome = undecryptable::classify(
        world.device(bob).expect("a device"),
        &inside,
        StoredRow::Unknown,
    )
    .await
    .expect("the ingest reads");
    let outside_outcome = undecryptable::classify(
        world.device(bob).expect("a device"),
        &outside,
        StoredRow::Unknown,
    )
    .await
    .expect("the ingest reads");

    assert!(
        inside_outcome == undecryptable::Verdict::Applied,
        "ciphertext at the window's own edge must still decrypt, or the engine keeps fewer \
         secrets than Rule 5 promises"
    );
    assert!(
        outside_outcome != undecryptable::Verdict::Applied,
        "ciphertext older than the window must not decrypt anywhere"
    );

    let edges = [
        RetentionEdge {
            device: bob,
            circle: world.circles()[0].tag,
            distance: window,
            outcome: inside_outcome,
        },
        RetentionEdge {
            device: bob,
            circle: world.circles()[0].tag,
            distance: window + 1,
            outcome: outside_outcome,
        },
    ];
    let graded = round(1).with_retention(&edges);
    let verdict = Invariant::RetentionWindow
        .check(&mut world, &graded)
        .await
        .expect("the oracle reads");
    assert!(
        verdict == Verdict::Holds,
        "both edges answered the way Rule 5 promises, so O4 must hold"
    );

    // The red half is planted at the ORACLE's input, and this is the one place
    // in this file where that is the honest thing to do: an engine that kept a
    // secret past its own window is the defect O4 exists to catch, and no seam
    // can make the product produce it on demand.
    let overrun = [
        edges[0],
        RetentionEdge {
            outcome: undecryptable::Verdict::Applied,
            ..edges[1]
        },
    ];
    let graded = round(1).with_retention(&overrun);
    let verdict = Invariant::RetentionWindow
        .check(&mut world, &graded)
        .await
        .expect("the oracle reads");
    assert!(
        verdict
            == Verdict::Failed(Finding::RetentionWindowOverrun {
                device: bob,
                circle: world.circles()[0].tag,
            }),
        "a secret that outlived the window must be reported as one"
    );
    assert!(
        verdict.rc() == Rc::ViolationOrLeak,
        "a secret outliving its window is a finding about the subject"
    );

    world.teardown().await.expect("teardown");
}

// ── O5 ──────────────────────────────────────────────────────────────────────

/// One genuine same-epoch commit race, classified with or without the stored
/// row the ingest wrote.
///
/// The race itself is the SCENARIO's, not this file's: S14 owns the one copy of
/// it, and driving it from here is what keeps the oracle's control and the
/// arm's own body from drifting apart. What this wrapper adds is the unnamed
/// classification the second control needs, which is a call and not a second
/// staging.
///
/// # Why the race runs in a circle of its own
///
/// The circle S14 builds is outside `world.circles()`, and the racers' engines
/// are stopped for the race (`deafen`): an engine listens to every circle its
/// device holds, and it records every message's disposition and answers the
/// second look at one MLS message with a duplicate, so a race delivered live
/// would classify as one.
///
/// # Why the named arm does not go through `classify`
///
/// A stored row is keyed by `SHA-256` over the PEELED MLS bytes, so a caller
/// holding only the signed event cannot name it in advance — and the publisher's
/// own row for the same commit is not the id the ingester writes either
/// (measured: naming it that way reads back absent). The row can only be LOCATED
/// after the ingest, which is exactly what the classifier's pure half exists
/// for. One ingest either way.
async fn same_epoch_race(name_the_row: bool) -> Vec<undecryptable::Verdict> {
    let mut world = build_world().await;
    let circle = world
        .build_extra_circle()
        .await
        .expect("a circle outside the world's table");
    let (alice, bob) = pair(&world);
    deafen(&mut world, (alice, bob))
        .await
        .expect("the racers' engines stop");
    co_admin(&world, &circle, alice, bob)
        .await
        .expect("the handoff confirms and the successor applies it");

    let stage = stage_race(&world, &circle, (alice, bob), SecondCommit::Confirmed)
        .await
        .expect("both commits stage, publish and confirm");
    assert!(
        stage.genuine,
        "both devices must have staged from ONE acknowledged epoch, or this is \
         two commits rather than a race"
    );

    let verdicts = if name_the_row {
        merge_race(&world, &circle, (alice, bob), &stage)
            .await
            .expect("the classifier reads")
    } else {
        let mut out = Vec::with_capacity(2);
        for (ingester, sibling) in [(bob, &stage.first), (alice, &stage.second)] {
            let device = world.device(ingester).expect("a device");
            let held = undecryptable::classify(device, sibling, StoredRow::Unknown)
                .await
                .expect("the classifier reads");
            assert!(
                held == undecryptable::Verdict::CommitGap,
                "MDK v0.10.4 holds a race's sibling for the pass that adjudicates it"
            );
            device
                .session()
                .expect("a session")
                .settle_receive_for_test(circle.mls_group_id())
                .await
                .expect("the pass closes");
            out.push(undecryptable::classify_settled_sibling(Probe::Unnamed));
        }
        out
    };

    world.teardown().await.expect("teardown");
    verdicts
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o5_accounts_for_every_disposition_of_a_real_same_epoch_race() {
    let verdicts = same_epoch_race(true).await;
    let losses = verdicts
        .iter()
        .filter(|verdict| {
            matches!(
                verdict,
                undecryptable::Verdict::PastEpochOrBranchLoss { .. }
            )
        })
        .count();
    assert!(
        losses == 1,
        "a same-epoch race costs exactly one branch; which side loses is the \
         engine's content-derived ordering, never this test's to name"
    );
    assert!(
        verdicts
            .iter()
            .filter(|verdict| **verdict == undecryptable::Verdict::Applied)
            .count()
            == 1,
        "and the other device applies the surviving branch rather than dropping it too"
    );
    assert!(
        verdicts.contains(&undecryptable::Verdict::PastEpochOrBranchLoss { branch_loss: true }),
        "the loser lost a BRANCH, which only the stored row's disposition can say"
    );

    let mut graded = round(1);
    graded.classified = &verdicts;
    let mut world = build_world().await;
    let verdict = Invariant::Undecryptable
        .check(&mut world, &graded)
        .await
        .expect("the oracle reads");
    assert!(
        verdict == Verdict::Holds,
        "every disposition a real race produces is one the classifier accounts for"
    );
    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o5_reports_an_unnamed_row_as_undetermined_rather_than_as_no_branch_lost() {
    // The plant: the same real race, classified without naming the stored row.
    let verdicts = same_epoch_race(false).await;
    assert!(
        verdicts.contains(&undecryptable::Verdict::Defect(
            undecryptable::Cause::BranchLossUndetermined
        )),
        "a past-epoch disposition with no row to read cannot be folded into \
         'no branch was lost' — that would under-report forks"
    );

    let mut graded = round(1);
    graded.classified = &verdicts;
    let mut world = build_world().await;
    let verdict = Invariant::Undecryptable
        .check(&mut world, &graded)
        .await
        .expect("the oracle reads");
    assert!(
        verdict == Verdict::Failed(Finding::UnnamedRow),
        "O5 reports it, rather than passing on a verdict nobody could support"
    );
    assert!(
        verdict.rc() == Rc::RigBroken,
        "a row the harness failed to name says nothing about the subject"
    );
    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o5_refuses_to_grade_a_round_that_classified_nothing() {
    let mut world = build_world().await;
    let verdict = Invariant::Undecryptable
        .check(&mut world, &round(1))
        .await
        .expect("the oracle reads");
    assert!(
        verdict == Verdict::Failed(Finding::NothingClassified),
        "an empty set would report that nothing went unaccounted for because \
         nothing was looked at"
    );
    assert!(verdict.rc() == Rc::Unusable, "an empty set proves nothing");
    world.teardown().await.expect("teardown");
}

// ── O6 ──────────────────────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o6_withholds_quiescence_while_a_staged_commit_is_outstanding() {
    let mut world = build_world().await;

    // The plant, S-F1's shape: a `PendingGuard` the rig never resolved. No
    // engine counter and no world fingerprint can see this state, which is
    // exactly why it is a term of the predicate rather than a consequence of
    // one.
    let leaked = world.note_pending_staged();
    let verdict = Invariant::Quiescence
        .check(&mut world, &round(1))
        .await
        .expect("the oracle reads");
    assert!(
        verdict == Verdict::Failed(Finding::NotQuiescent(PendingReason::StagedCommit)),
        "a world with a commit staged and unpublished is not settled, however \
         still everything else looks"
    );
    assert!(
        verdict.rc() == Rc::ViolationOrLeak,
        "a world that never settles inside its derived bound is a finding"
    );

    drop(leaked);
    assert!(
        Invariant::Quiescence
            .check(&mut world, &round(2))
            .await
            .expect("the oracle reads")
            == Verdict::Holds,
        "and it settles as soon as the staged commit is resolved"
    );

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o6_reads_a_world_whose_devices_are_all_paused_as_pending_rather_than_settled() {
    let mut world = build_world().await;
    for device in world.devices_mut() {
        device.go_offline().await.expect("the engine pauses");
    }
    assert!(
        quiescent_now(&world).await == Quiescence::Pending(PendingReason::NoOnlineDevice),
        "the predicate over an empty set would be vacuously true, and a world \
         nobody is running is not a world that settled"
    );
    let settled = quiescence::settle(&mut world, Recovery::Undisturbed, TICK)
        .await
        .expect("the settle reads");
    assert!(
        settled == Settled::TimedOut(PendingReason::NoOnlineDevice),
        "and the settle reports which term it was still waiting on"
    );
    world.teardown().await.expect("teardown");
}

async fn quiescent_now(world: &World) -> Quiescence {
    quiescence::quiescent(world)
        .await
        .expect("the predicate reads")
}

// ── O7 ──────────────────────────────────────────────────────────────────────

async fn o7(world: &mut World, ordinal: u32) -> Verdict {
    Invariant::RelayPlaneContainment
        .check(world, &round(ordinal))
        .await
        .expect("the oracle reads")
}

/// Asserts O7 holds on `world` before a plant, so the red after it is the
/// plant's.
async fn o7_clean(world: &mut World) {
    assert!(
        o7(world, 1).await == Verdict::Holds,
        "a world nobody broke is contained, or no plant below proves anything"
    );
}

/// Every identifier `world` minted that a finding could carry: each endpoint's
/// address, each device's pubkey, each circle's routing id.
fn o7_needles(world: &World) -> Vec<String> {
    let mut needles = Vec::new();
    for plane in world.all_planes() {
        needles.push(plane.url().to_owned());
        for device in world.devices() {
            needles.push(plane.url_for(device.tag).to_owned());
        }
    }
    for device in world.devices() {
        needles.push(device.pubkey_hex());
    }
    for circle in world.circles() {
        needles.push(circle.group_id_hex().to_owned());
    }
    needles.push("127.0.0.1".to_owned());
    needles
}

/// The finding renders the rig's handles and literals and none of `needles`.
fn assert_renders_no_value(verdict: Verdict, needles: &[String]) {
    let Verdict::Failed(finding) = verdict else {
        panic!("the plant was not reported");
    };
    let rendered = format!(
        "{} {finding:?} {}",
        finding.class(),
        finding.handles().join(" ")
    );
    for needle in needles {
        assert!(
            !rendered.contains(needle.as_str()),
            "an O7 finding carries a value the world minted"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o7_reds_on_a_kind_0_published_to_a_location_plane() {
    let mut world = build_world().await;
    o7_clean(&mut world).await;
    let (alice, _) = pair(&world);
    let device = world.device(alice).expect("alice");
    let profile = haven_core::profile::build_blank_metadata_event(&device.keys, None)
        .expect("a kind 0 signs");
    let location = world.relays()[0].url_for(alice).to_owned();
    let _ = device.relays.publish_event(&profile, &[location]).await;

    let verdict = o7(&mut world, 2).await;
    assert!(
        verdict
            == Verdict::Failed(Finding::PlaneCrossedEvent {
                relay: world.relays()[0].tag(),
                device: Some(alice),
                row: "EV-0",
                rule: "plane-crossed-event",
            }),
        "a profile on a circle's relay joins the profile plane to the location one"
    );
    assert!(
        verdict.rc() == Rc::ViolationOrLeak,
        "a crossing is a finding about the subject"
    );
    assert_renders_no_value(verdict, &o7_needles(&world));
    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o7_reds_on_an_inbox_request_sent_to_a_location_plane() {
    let mut world = build_world().await;
    o7_clean(&mut world).await;
    let (alice, _) = pair(&world);
    let device = world.device(alice).expect("alice");
    let own_inbox = nostr::Filter::new()
        .kind(nostr::Kind::GiftWrap)
        .pubkey(device.keys.public_key());
    let location = world.relays()[0].url_for(alice).to_owned();
    let _ = device
        .relays
        .fetch_events(own_inbox, &[location], Some(Duration::from_secs(5)))
        .await;

    let verdict = o7(&mut world, 2).await;
    assert!(
        verdict
            == Verdict::Failed(Finding::PlaneCrossedRequest {
                relay: world.relays()[0].tag(),
                device: Some(alice),
                row: "REQ-1059-P",
            }),
        "a device's #p on a circle's relay links its identity to the circle"
    );
    assert!(
        verdict.rc() == Rc::ViolationOrLeak,
        "a crossing is a finding about the subject"
    );
    assert_renders_no_value(verdict, &o7_needles(&world));
    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o7_reds_on_a_location_sent_to_the_other_circles_plane() {
    let mut shape = smallest_shape();
    shape.relays = 2;
    let mut world = build_shaped_world(&shape).await;
    let (alice, _) = pair(&world);
    let apart = world
        .build_extra_circle_on(&world.relay_urls()[1..])
        .await
        .expect("a circle on the second plane alone builds");
    o7_clean(&mut world).await;
    let device = world.device(alice).expect("alice");
    let (event, _, _) = device
        .manager()
        .expect("a manager")
        .seal_location_for_test(
            apart.mls_group_id(),
            &haven_core::location::LocationMessage::new(12.5, 25.0),
        )
        .await
        .expect("a location seals");
    let other = world.relays()[0].url_for(alice).to_owned();
    let _ = device.relays.publish_location_event(&event, &[other]).await;

    let verdict = o7(&mut world, 2).await;
    assert!(
        verdict
            == Verdict::Failed(Finding::PlaneCrossedEvent {
                relay: world.relays()[0].tag(),
                device: Some(alice),
                row: "EV-445A",
                rule: "plane-crossed-event",
            }),
        "a location on a relay its circle's routing never named is a crossing"
    );
    let mut needles = o7_needles(&world);
    needles.push(apart.group_id_hex().to_owned());
    assert_renders_no_value(verdict, &needles);
    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o7_reds_on_a_location_sent_to_an_address_only_the_other_circles_change_named() {
    // Both circles ride location#0, and circle B's change names one address no
    // plane serves, which every device dials at an alias endpoint fronting that
    // same relay. A's location sent there reached a relay A's routing never
    // named: an alias frame is judged by the address its slot stands for, never
    // by the plane behind its listener, where A's routing would admit it.
    let mut shape = smallest_shape();
    shape.circles = 2;
    let mut world = build_shaped_world(&shape).await;
    let (alice, _) = pair(&world);
    let (a_group, b_group) = (
        world.circles()[0].mls_group_id().clone(),
        world.circles()[1].mls_group_id().clone(),
    );
    let only_b = "wss://o7-only-b.example.com";
    let mut relays = world.relay_urls();
    relays.push(only_b.to_owned());
    let changed = world
        .change(
            alice,
            Change::Relays {
                group: &b_group,
                relays: &relays,
            },
        )
        .await
        .expect("the driver makes the change");
    assert!(
        changed.verdict == PublishVerdict::Confirmed,
        "premise: circle B routes over the address"
    );
    o7_clean(&mut world).await;
    let device = world.device(alice).expect("alice");
    let (event, _, _) = device
        .manager()
        .expect("a manager")
        .seal_location_for_test(
            &a_group,
            &haven_core::location::LocationMessage::new(6.25, 12.5),
        )
        .await
        .expect("a location seals");
    let alias = (device.endpoint_route())(only_b);
    let _ = device.relays.publish_location_event(&event, &[alias]).await;

    let verdict = o7(&mut world, 2).await;
    assert!(
        verdict
            == Verdict::Failed(Finding::PlaneCrossedEvent {
                relay: world.relays()[0].tag(),
                device: Some(alice),
                row: "EV-445A",
                rule: "plane-crossed-event",
            }),
        "circle A's location on the address only circle B's change named is a crossing"
    );
    assert!(
        verdict.rc() == Rc::ViolationOrLeak,
        "a crossing is a finding about the subject"
    );
    let mut needles = o7_needles(&world);
    needles.push(only_b.to_owned());
    assert_renders_no_value(verdict, &needles);
    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o7_reds_on_a_close_naming_a_subscription_its_relay_was_never_sent() {
    let mut world = build_world().await;
    o7_clean(&mut world).await;
    let (alice, _) = pair(&world);
    // The pool's own connection is the subject's; a CLOSE needs no
    // subscription of its own, so it is sent raw on a connection to alice's
    // endpoint, where it is judged as alice's.
    let url = world.relays()[0].url_for(alice).to_owned();
    let client = nostr_sdk::Client::builder().build();
    client.automatic_authentication(false);
    client
        .add_relay(&url)
        .await
        .expect("the endpoint is a relay");
    client.connect().await;
    client
        .send_msg_to(
            [url.as_str()],
            nostr::ClientMessage::close(nostr::SubscriptionId::new("never-opened")),
        )
        .await
        .expect("the CLOSE is sent");
    let recorded = wait_for(Duration::from_secs(5), || {
        world.relays()[0]
            .ledger()
            .plane_record()
            .frames
            .iter()
            .any(|frame| frame.text.contains("never-opened"))
    })
    .await;
    assert!(recorded, "premise: the CLOSE reached the endpoint");
    client.shutdown().await;

    let verdict = o7(&mut world, 2).await;
    assert!(
        verdict
            == Verdict::Failed(Finding::PlaneUnknownFrame {
                relay: world.relays()[0].tag(),
                device: Some(alice),
                rule: "plane-unknown-frame",
            }),
        "a CLOSE naming a subscription its relay was never sent carries an id \
         from another plane's socket, and is never special-cased"
    );
    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o7_answers_proves_too_little_when_a_declared_profile_plane_saw_nothing() {
    let mut shape = smallest_shape();
    shape.profile_relays = haven_core::profile::PROFILE_POOL_MIN;
    let mut world = build_shaped_world(&shape).await;
    assert!(
        o7(&mut world, 1).await == Verdict::Holds,
        "an undeclared profile plane owes nothing"
    );
    world.exercise_profile();
    let verdict = o7(&mut world, 2).await;
    assert!(
        verdict
            == Verdict::Failed(Finding::PlaneUnobserved {
                role: haven_soak::oracle::PlaneRole::Profile,
            }),
        "a profile plane declared driven that carried nothing graded nothing"
    );
    assert!(
        verdict.rc() == Rc::ProvesTooLittle,
        "which is ungraded, never clean and never a violation"
    );
    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn o7_answers_rig_broken_when_the_plane_record_is_full() {
    let mut world = build_world().await;
    o7_clean(&mut world).await;
    let (alice, _) = pair(&world);
    world.relays()[0].ledger().set_plane_caps(0, 0);
    // One more distinct, plane-legal shape: the circle's own `#h`, asked again.
    let device = world.device(alice).expect("alice");
    let h = nostr::SingleLetterTag::lowercase(nostr::Alphabet::H);
    let again = nostr::Filter::new()
        .kind(nostr::Kind::Custom(445))
        .custom_tag(h, world.circles()[0].group_id_hex());
    let location = world.relays()[0].url_for(alice).to_owned();
    let _ = device
        .relays
        .fetch_events(again, &[location], Some(Duration::from_secs(5)))
        .await;

    let verdict = o7(&mut world, 2).await;
    assert!(
        verdict
            == Verdict::Failed(Finding::PlaneRecordFull {
                relay: world.relays()[0].tag(),
            }),
        "a record that could not keep a frame cannot say what that frame was"
    );
    assert!(
        verdict.rc() == Rc::RigBroken,
        "the rig could not hold the evidence: never a silent pass"
    );
    world.teardown().await.expect("teardown");
}

/// Waits, bounded, for `condition`.
async fn wait_for(bound: Duration, condition: impl Fn() -> bool) -> bool {
    let started = Instant::now();
    let mut ticker = tokio::time::interval(POLL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        if condition() {
            return true;
        }
        if started.elapsed() >= bound {
            return false;
        }
        ticker.tick().await;
    }
}

// ── Expectation floors ──────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_arm_that_fired_no_fault_is_unusable_however_healthy_the_world_looks() {
    let mut world = build_world().await;
    // A real round trip, so the world genuinely delivered something and the
    // only unmet term is the one this test is about.
    assert!(
        Invariant::LocationRoundTrip
            .check(&mut world, &round(1))
            .await
            .expect("the oracle reads")
            == Verdict::Holds,
        "the world under test is a working one"
    );
    world.drain_buses();

    let observed = Observed::measure(&world, 1)
        .await
        .expect("the measurement reads");
    assert!(
        observed.deliveries_observed > 0,
        "the measured half comes out of the world, so an arm cannot mis-report it"
    );

    let floor = ExpectationFloor {
        faults_applied: 1,
        epochs_crossed: 0,
        deliveries_observed: 1,
        canaries_caught: 1,
    };
    let verdict = haven_soak::oracle::vacuity::grade(&floor, &observed);
    assert!(
        verdict == Verdict::Failed(Finding::FloorUnmet(FloorTerm::FaultsApplied)),
        "an arm whose scheduled fault never fired makes every bound derived from \
         it a fiction, however green its oracles are"
    );
    assert!(
        verdict.rc() == Rc::Unusable,
        "which is unusable, never clean"
    );

    world.teardown().await.expect("teardown");
}

// ── The registry itself ─────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn every_registered_oracle_holds_on_a_world_with_nothing_wrong_with_it() {
    let mut world = build_world().await;
    let classified = [undecryptable::Verdict::Applied];
    // O4's subject is not a state of the world but the edges an arm fed it, so
    // the healthy round declares the pair a healthy engine produces — exactly
    // as it declares O5's classification above. A round that fed neither is
    // `Unusable` by design, which is what keeps an arm from passing O4 by
    // feeding nothing.
    let window = u64::try_from(haven_core::nostr::mls::DEFAULT_MAX_PAST_EPOCHS)
        .expect("a retention window fits a u64");
    let edges = [
        RetentionEdge {
            device: DeviceTag::new(1),
            circle: world.circles()[0].tag,
            distance: window,
            outcome: undecryptable::Verdict::Applied,
        },
        RetentionEdge {
            device: DeviceTag::new(1),
            circle: world.circles()[0].tag,
            distance: window + 1,
            outcome: undecryptable::Verdict::PastEpochOrBranchLoss { branch_loss: false },
        },
    ];
    // O3's subject is likewise the probes an arm fed it, not a state of the
    // world: the healthy round declares one Delivered pair (refuses SelfEvicted)
    // and one Withheld pair (refuses PeelFailed with a row that never resolved),
    // so a round that fed neither is `Unusable` by design, exactly as O4/O5 are.
    let probes = [
        RemovalProbe {
            device: DeviceTag::new(0),
            circle: world.circles()[0].tag,
            stage: RemovalStage::Before,
            path: RemovalPath::Delivered,
            outcome: undecryptable::Verdict::Applied,
            carried_token: true,
            terminal: RemovalRow::NotApplicable,
        },
        RemovalProbe {
            device: DeviceTag::new(0),
            circle: world.circles()[0].tag,
            stage: RemovalStage::After,
            path: RemovalPath::Delivered,
            outcome: undecryptable::Verdict::SelfEvicted,
            carried_token: false,
            terminal: RemovalRow::NotApplicable,
        },
        RemovalProbe {
            device: DeviceTag::new(1),
            circle: world.circles()[0].tag,
            stage: RemovalStage::Before,
            path: RemovalPath::Withheld,
            outcome: undecryptable::Verdict::Applied,
            carried_token: true,
            terminal: RemovalRow::NotApplicable,
        },
        RemovalProbe {
            device: DeviceTag::new(1),
            circle: world.circles()[0].tag,
            stage: RemovalStage::After,
            path: RemovalPath::Withheld,
            outcome: undecryptable::Verdict::PeelFailed,
            carried_token: false,
            terminal: RemovalRow::StillDeferred,
        },
    ];
    let mut healthy = round(1)
        .with_retention(&edges)
        .with_forward_secrecy(&probes);
    healthy.classified = &classified;

    for invariant in Invariant::REGISTRY {
        let verdict = invariant
            .check(&mut world, &healthy)
            .await
            .expect("the oracle reads");
        assert!(
            verdict == Verdict::Holds,
            "a registered oracle that cannot go green on a healthy world would red \
             every run for a reason that is not the subject's"
        );
        // A report line is a log line: the oracle's own name and its verdict,
        // and nothing either of them carries.
        let line = format!("{invariant}: {verdict}");
        assert!(
            line.starts_with(invariant.id()),
            "the line names the oracle"
        );
        assert!(!line.contains("ws://"), "no endpoint reaches a report line");
        assert!(!line.contains("npub"), "no identity reaches a report line");
    }

    world.teardown().await.expect("teardown");
}

// ── Every registered ARM's happy path (R-M6, P-M3) ──────────────────────────
//
// One test per ARM, not per scenario. An ordering over arms — "the smallest
// one" — tie-breaks positionally and silently leaves most of the registry with
// no success path anywhere, including both of the Rule-13 arms S18 exists for.
// `the_happy_path_sweep_runs_every_arm_but_the_one_it_excludes` is what keeps
// the set below honest, and it names the single exclusion rather than allowing
// one.
//
// One test per arm rather than one loop, because every assertion message in
// this file is a literal: with a loop, every failure would panic on the same
// line with the same words and the test NAME would be the only thing saying
// which arm broke.

/// The two arms the sweep does not run, and the one reason.
///
/// Each asserts an ABSENCE over the whole delivery-silence window — three
/// kind-445 retention windows, 684 seconds — and an absence is the one span
/// that may never be scaled or shortened. S03's unnamed strand and S17's full
/// intake run in the `weekly` profile, which is where a bound that starts at
/// eleven minutes belongs. In registry order, because the sweep test compares
/// its leftovers to this list as it walks the registry.
const EXCLUDED_FROM_THE_SWEEP: [&str; 2] = ["lost-commit-unnamed", "full-intake"];

/// The arms the sweep runs and REQUIRES to be red, and the one reason: each is
/// a measured PRODUCT-side red this sweep asserts on every commit until it is
/// fixed (the `weekly` profile runs it too; the nightly does not, because
/// `verdict.log` keeps a run's first violation only), graded at
/// rc 1 rather than recorded as a canary, and the day one grades rc 0 its own
/// test fails with the instruction to promote it to `SWEPT` in the same change.
///
/// (C9's `kill-receive-auto-commit` stood here until MDK v0.10.4, where the
/// killed device takes its peer's commit of the owed eviction; it is `SWEPT`.)
///
/// (S16 `outsider-flood` stood here from the bump until Haven gave every
/// deferred-peel row its try before each send, `docs/MDK_UPSTREAM_TRACKER.md`
/// T-FOREGROUND-PEEL; it is `SWEPT`.)
///
/// (S08 `buried-past-the-cap` stood here for C8 until R4's NIP-77 pass
/// recovered a commit buried past a relay's replay cap; it is `SWEPT`, and its
/// relay-without-NIP-77 twin records the residual.)
///
/// Empty: no arm is required red today. The list and its checks stay, so the
/// next measured product red has a home.
const EXPECTED_RED: [(Scenario, &str); 0] = [];

/// Every (scenario, arm) the sweep below runs, written out so that an arm added
/// to a scenario without a test here fails rather than widening a loop.
const SWEPT: [(Scenario, &str); 68] = [
    (Scenario::RelayOutage, "single-relay-outage"),
    (Scenario::RelayOutage, "all-relay-outage"),
    (Scenario::RelayOutage, "rolling-outage"),
    (Scenario::ReceiverPartition, "partitioned-receiver"),
    (Scenario::ReceiverPartition, "commit-class-only"),
    (Scenario::LostCommit, "lost-commit-strands"),
    (Scenario::OfflineMember, "offline-quiet"),
    (Scenario::OfflineMember, "offline-across-commits"),
    (Scenario::OfflineMember, "offline-past-retention"),
    (Scenario::OfflineMember, "offline-across-removal"),
    (
        Scenario::PublishConfirmWindow,
        "confirm-err-is-not-a-failure",
    ),
    (Scenario::PublishConfirmWindow, "kill-send-plane"),
    (Scenario::PublishConfirmWindow, "kill-receive-auto-commit"),
    (Scenario::PublishConfirmWindow, "negative-gates-silent"),
    (Scenario::PublishConfirmWindow, "kill-sweep-eviction"),
    (Scenario::StuckRow, "stuck-row-sweep"),
    (Scenario::LivePlaneBurial, "buried-past-the-cap"),
    (Scenario::LivePlaneBurial, "unpacked-control"),
    (
        Scenario::LivePlaneBurial,
        "buried-on-a-relay-without-negentropy",
    ),
    (Scenario::CursorPoisoning, "standing-adversary"),
    (Scenario::CursorPoisoning, "rewrap-created-at-binding"),
    (
        Scenario::CursorPoisoning,
        "member-commit-past-expiration-applied",
    ),
    (
        Scenario::CursorPoisoning,
        "past-expiration-dropped-by-the-relay-pool",
    ),
    (Scenario::QuietCircle, "quiet-circle-resume"),
    (Scenario::KeyPackageRotation, "kp-rotation-slot"),
    (Scenario::KeyPackageRotation, "kp-expired-rejected"),
    (Scenario::HydrationQuarantine, "hydration-quarantine"),
    (Scenario::RestartRace, "race-no-restart"),
    (Scenario::RestartRace, "race-restart-after-confirm"),
    (Scenario::RestartRace, "race-restart-before-confirm"),
    (Scenario::RestartRace, "race-anchor-exhausted"),
    (Scenario::ClosedPrefixes, "closed-prefixes"),
    (Scenario::ClosedPrefixes, "notice"),
    (Scenario::SwallowedOk, "swallowed-ok-founding-welcome"),
    (Scenario::SwallowedOk, "swallowed-ok-relay-update"),
    (Scenario::SwallowedOk, "swallowed-ok-peers-online-converge"),
    (Scenario::SwallowedOk, "swallowed-ok-location-send"),
    (Scenario::SwallowedOk, "location-resumes-after-the-ack"),
    (Scenario::DuplicateReorder, "duplicate-replay"),
    (Scenario::DuplicateReorder, "reordered-pages"),
    (Scenario::DuplicateReorder, "cross-sub-eose"),
    (Scenario::DuplicateReorder, "commit-gap"),
    (Scenario::OversizedEvent, "oversized-commit"),
    (Scenario::OversizedEvent, "refusal-is-relay-count-invariant"),
    (Scenario::OversizedEvent, "oversized-welcome"),
    (
        Scenario::OversizedEvent,
        "oversized-removal-wedges-the-circle",
    ),
    (Scenario::TenCircleRoster, "ten-circle-roster"),
    (Scenario::StorageGrowth, "outsider-flood"),
    (Scenario::StorageGrowth, "member-future-header-flood"),
    (Scenario::StorageGrowth, "pending-window-flood"),
    (Scenario::StorageGrowth, "processed-ids-growth"),
    (Scenario::RemovalEffectiveness, "removal-withheld-commit"),
    (Scenario::RemovalEffectiveness, "removal-delivered-commit"),
    (Scenario::RemovalEffectiveness, "removal-lag"),
    (Scenario::CatchupSweep, "healthy-drain"),
    (Scenario::CatchupSweep, "clamped-limit"),
    (Scenario::CatchupSweep, "refused-page"),
    (Scenario::CatchupSweep, "same-second-pile-up"),
    (
        Scenario::CatchupSweep,
        "same-second-pile-up-without-negentropy",
    ),
    (Scenario::CatchupSweep, "cold-first-connect"),
    (Scenario::CatchupSweep, "future-dated-page"),
    (Scenario::ChainedBacklog, "chained-commit-backlog"),
    (Scenario::RoutingCollision, "collided-circles-leave-apart"),
    (Scenario::SilentRelays, "dead-and-silent-relays"),
    (Scenario::IdentityPlanes, "identity-planes-under-faults"),
    (Scenario::MeshIndependence, "mesh-off-then-on"),
    (Scenario::MemberBridging, "bridged-to-the-far-member"),
    (Scenario::MemberBridging, "removed-member-finds-nothing"),
];

/// The world one arm is run in: the PR profile's own shape, widened only where
/// an arm cannot run in it at all, or cannot fail in it.
///
/// The PR shape rather than each arm's own profile, because it is the shape the
/// lane actually executes and the cheapest one most arms can use. Some need a
/// second relay plane by definition: an all-relay or rolling outage over one
/// plane is a single-relay outage wearing another arm's label, and "a second
/// relay changes nothing about a size refusal" cannot be said in a world with
/// one. One needs a fourth device: a removal that left the
/// circle with only the admin and the returning member would be testing an empty
/// roster, which is also why that arm answers `ShapeMismatch` in the PR shape and
/// is not in `pr.toml`.
fn shape_for(label: &str) -> WorldShape {
    let mut shape = pr_spec().world;
    if matches!(
        label,
        "all-relay-outage"
            | "rolling-outage"
            | "refusal-is-relay-count-invariant"
            | "cold-first-connect"
            | "collided-circles-leave-apart"
    ) {
        shape.relays = shape.relays.max(2);
    }
    // The nightly's two location relays: a plane left forwarding the page
    // races the reversed one, which a world of one plane cannot show.
    if label == "reordered-pages" {
        shape.relays = shape.relays.max(2);
    }
    // A dead relay, a silent one, and one that answers.
    if label == "dead-and-silent-relays" {
        shape.relays = shape.relays.max(3);
    }
    // The nightly's identity planes: an inbox apart from the key packages,
    // and a profile pool the product will use.
    if label == "identity-planes-under-faults" {
        shape.account_relays = 2;
        shape.profile_relays = haven_core::profile::PROFILE_POOL_MIN;
    }
    if matches!(
        label,
        "offline-across-removal"
            | "removal-withheld-commit"
            | "removal-delivered-commit"
            | "removal-lag"
    ) {
        shape.members = shape.members.max(4);
    }
    shape
}

fn pr_spec() -> ProfileSpec {
    ProfileSpec::embedded(ProfileName::Pr).expect("the pr profile parses")
}

/// The tick every arm in this file is run at: the PR profile's own, because an
/// arm's bounds are composed at the period the run executes at.
fn pr_tick() -> Duration {
    Duration::from_millis(pr_spec().tick_ms)
}

/// The arm `label` names.
fn arm_of(scenario: Scenario, label: &str) -> &'static haven_soak::scenarios::Arm {
    scenario.arm(label).expect("an arm this scenario offers")
}

/// Runs one arm against a fresh world and requires every oracle and its floor
/// to hold.
///
/// Deliberately no assertion on the elapsed time. An arm's derived deadline is
/// a composition of the product's worst-case constants, and this binary runs
/// several whole MLS worlds at once: a wall-clock upper bound here would be
/// measuring the runner's load. Every span that matters is already enforced
/// INSIDE the oracles' own bounded waits, which fail on their own.
async fn happy_path(scenario: Scenario, label: &str) {
    happy_path_after(scenario, label, |_| {}).await;
}

/// [`happy_path`], with `premise` asserted on the world the arm ran in before
/// any verdict is read: a premise the arm's own report cannot carry.
async fn happy_path_after(scenario: Scenario, label: &str, premise: impl FnOnce(&World)) {
    let arm = arm_of(scenario, label);
    let mut world = build_shaped_world(&shape_for(label)).await;

    let report = scenario
        .run(&mut world, arm, pr_tick())
        .await
        .expect("the scenario runs");
    premise(&world);
    assert!(
        report
            .graded
            .iter()
            .any(|(invariant, _)| *invariant == Invariant::RelayPlaneContainment),
        "every arm's run grades O7 over its whole wire"
    );

    let graded: Vec<String> = report
        .graded
        .iter()
        .map(|(invariant, verdict)| format!("{} {verdict}", invariant.id()))
        .collect();
    assert!(
        report.holds(),
        "a registered arm must have a success path in this crate's own tests, \
         or the registry claims coverage no lane executes: {report}; floor {}; {}",
        report.floor,
        graded.join("; ")
    );
    assert!(
        report.rc() == Rc::Clean,
        "and it must fold to clean: an arm whose floor went unmet is unusable, \
         not green"
    );

    world.teardown().await.expect("teardown");
}

#[test]
fn the_happy_path_sweep_runs_every_arm_but_the_one_it_excludes() {
    let mut unswept: Vec<&str> = Vec::new();
    for scenario in Scenario::REGISTRY {
        for arm in scenario.arms() {
            if !SWEPT.contains(&(scenario, arm.label))
                && !EXPECTED_RED.contains(&(scenario, arm.label))
            {
                unswept.push(arm.label);
            }
        }
    }
    assert!(
        unswept == EXCLUDED_FROM_THE_SWEEP,
        "the set of arms with no success path in this file must be exactly the \
         one this file names and explains; a new arm cannot join it silently"
    );
    for (scenario, label) in SWEPT {
        assert!(
            scenario.arm(label).is_some(),
            "the sweep names an arm its scenario no longer offers"
        );
        assert!(
            !EXPECTED_RED.contains(&(scenario, label)),
            "an arm is swept for a success path or required red, never both"
        );
    }
    for (scenario, label) in EXPECTED_RED {
        assert!(
            scenario.arm(label).is_some(),
            "the expected-red list names an arm its scenario no longer offers"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s01_single_relay_outage_holds() {
    happy_path(Scenario::RelayOutage, "single-relay-outage").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s01_all_relay_outage_holds() {
    happy_path(Scenario::RelayOutage, "all-relay-outage").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s01_rolling_outage_holds() {
    happy_path(Scenario::RelayOutage, "rolling-outage").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s02_partitioned_receiver_holds() {
    happy_path(Scenario::ReceiverPartition, "partitioned-receiver").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s02_commit_class_only_holds() {
    happy_path(Scenario::ReceiverPartition, "commit-class-only").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s03_lost_commit_strands_holds() {
    happy_path(Scenario::LostCommit, "lost-commit-strands").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s04_offline_quiet_holds() {
    happy_path(Scenario::OfflineMember, "offline-quiet").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s04_offline_across_commits_holds() {
    happy_path(Scenario::OfflineMember, "offline-across-commits").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s04_offline_past_retention_holds() {
    happy_path(Scenario::OfflineMember, "offline-past-retention").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s04_offline_across_removal_holds() {
    happy_path(Scenario::OfflineMember, "offline-across-removal").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s05_confirm_err_is_not_a_failure_holds() {
    happy_path(
        Scenario::PublishConfirmWindow,
        "confirm-err-is-not-a-failure",
    )
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s05_kill_send_plane_holds() {
    happy_path(Scenario::PublishConfirmWindow, "kill-send-plane").await;
}

/// The receive-plane kill: the device killed while owing a peer's eviction
/// takes its peer's commit of it. `EXPECTED_RED` with C9's wedge until MDK
/// v0.10.4; promoted to `SWEPT` when it graded rc 0.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s05_kill_receive_auto_commit_holds() {
    happy_path(Scenario::PublishConfirmWindow, "kill-receive-auto-commit").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s05_negative_gates_silent_holds() {
    happy_path(Scenario::PublishConfirmWindow, "negative-gates-silent").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s06_stuck_row_sweep_holds() {
    happy_path(Scenario::StuckRow, "stuck-row-sweep").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s08_unpacked_control_holds() {
    happy_path(Scenario::LivePlaneBurial, "unpacked-control").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s09_standing_adversary_holds() {
    happy_path(Scenario::CursorPoisoning, "standing-adversary").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s09_rewrap_created_at_binding_holds() {
    happy_path(Scenario::CursorPoisoning, "rewrap-created-at-binding").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s09_member_commit_past_expiration_applied_holds() {
    happy_path(
        Scenario::CursorPoisoning,
        "member-commit-past-expiration-applied",
    )
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s09_past_expiration_dropped_by_the_relay_pool_holds() {
    happy_path(
        Scenario::CursorPoisoning,
        "past-expiration-dropped-by-the-relay-pool",
    )
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s11_quiet_circle_resume_holds() {
    happy_path(Scenario::QuietCircle, "quiet-circle-resume").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s12_kp_rotation_slot_holds() {
    happy_path(Scenario::KeyPackageRotation, "kp-rotation-slot").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s12_kp_expired_rejected_holds() {
    happy_path(Scenario::KeyPackageRotation, "kp-expired-rejected").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s13_hydration_quarantine_holds() {
    happy_path(Scenario::HydrationQuarantine, "hydration-quarantine").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s14_race_no_restart_holds() {
    happy_path(Scenario::RestartRace, "race-no-restart").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s14_race_restart_after_confirm_holds() {
    happy_path(Scenario::RestartRace, "race-restart-after-confirm").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s14_race_restart_before_confirm_holds() {
    happy_path(Scenario::RestartRace, "race-restart-before-confirm").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s14_race_anchor_exhausted_holds() {
    happy_path(Scenario::RestartRace, "race-anchor-exhausted").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s17_closed_prefixes_holds() {
    happy_path(Scenario::ClosedPrefixes, "closed-prefixes").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s17_notice_holds() {
    happy_path(Scenario::ClosedPrefixes, "notice").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s18_swallowed_ok_founding_welcome_holds() {
    happy_path(Scenario::SwallowedOk, "swallowed-ok-founding-welcome").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s18_swallowed_ok_relay_update_holds() {
    happy_path(Scenario::SwallowedOk, "swallowed-ok-relay-update").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s18_swallowed_ok_peers_online_converge_holds() {
    happy_path(Scenario::SwallowedOk, "swallowed-ok-peers-online-converge").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s18_swallowed_ok_location_send_holds() {
    happy_path(Scenario::SwallowedOk, "swallowed-ok-location-send").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s18_location_resumes_after_the_ack_holds() {
    happy_path(Scenario::SwallowedOk, "location-resumes-after-the-ack").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s19_duplicate_replay_holds() {
    happy_path(Scenario::DuplicateReorder, "duplicate-replay").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s19_reordered_pages_holds() {
    // The floor sums faults over every plane, so one plane reversed meets it.
    happy_path_after(Scenario::DuplicateReorder, "reordered-pages", |world| {
        let planes = world.relays();
        assert!(
            planes.len() >= 2 && planes.iter().all(|plane| plane.faults_applied() >= 1),
            "every location relay serves the page, so every one must reverse it"
        );
    })
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s19_cross_sub_eose_holds() {
    happy_path(Scenario::DuplicateReorder, "cross-sub-eose").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s19_commit_gap_holds() {
    happy_path(Scenario::DuplicateReorder, "commit-gap").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s22_oversized_commit_holds() {
    happy_path(Scenario::OversizedEvent, "oversized-commit").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s22_refusal_is_relay_count_invariant_holds() {
    happy_path(Scenario::OversizedEvent, "refusal-is-relay-count-invariant").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s22_oversized_welcome_holds() {
    happy_path(Scenario::OversizedEvent, "oversized-welcome").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s22_oversized_removal_wedges_the_circle_holds() {
    happy_path(
        Scenario::OversizedEvent,
        "oversized-removal-wedges-the-circle",
    )
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s10_ten_circle_roster_holds() {
    happy_path(Scenario::TenCircleRoster, "ten-circle-roster").await;
}

/// Promoted from `EXPECTED_RED` once the pre-send drain landed
/// (`docs/MDK_UPSTREAM_TRACKER.md` T-FOREGROUND-PEEL).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s16_outsider_flood_holds() {
    happy_path(Scenario::StorageGrowth, "outsider-flood").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s16_member_future_header_flood_holds() {
    happy_path(Scenario::StorageGrowth, "member-future-header-flood").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s16_pending_window_flood_holds() {
    happy_path(Scenario::StorageGrowth, "pending-window-flood").await;
}

/// A recorded expectation (`docs/MDK_UPSTREAM_TRACKER.md` T-DEDUPE-GROWTH): the
/// day the engine prunes its processed-transport-id table this goes rc 3, and
/// the arm is replaced by a graded bound in the same change.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s16_processed_ids_growth_holds() {
    happy_path(Scenario::StorageGrowth, "processed-ids-growth").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s21_removal_withheld_commit_holds() {
    happy_path(Scenario::RemovalEffectiveness, "removal-withheld-commit").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s21_removal_delivered_commit_holds() {
    happy_path(Scenario::RemovalEffectiveness, "removal-delivered-commit").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s21_removal_lag_holds() {
    happy_path(Scenario::RemovalEffectiveness, "removal-lag").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s20_healthy_drain_holds() {
    happy_path(Scenario::CatchupSweep, "healthy-drain").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s20_clamped_limit_holds() {
    happy_path(Scenario::CatchupSweep, "clamped-limit").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s20_refused_page_holds() {
    happy_path(Scenario::CatchupSweep, "refused-page").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s20_cold_first_connect_holds() {
    happy_path(Scenario::CatchupSweep, "cold-first-connect").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s20_future_dated_page_holds() {
    happy_path(Scenario::CatchupSweep, "future-dated-page").await;
}

/// S23 was `EXPECTED_RED` until C7's fix; promoted to `SWEPT` with it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s23_chained_commit_backlog_holds() {
    happy_path(Scenario::ChainedBacklog, "chained-commit-backlog").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s24_collided_circles_leave_apart_holds() {
    happy_path(Scenario::RoutingCollision, "collided-circles-leave-apart").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s24_two_circles_that_never_collided_prove_nothing_about_a_collision() {
    // The mis-configuration: no routing update, so nothing is held and the
    // arm has no collision to grade.
    let mut world = build_shaped_world(&shape_for("collided-circles-leave-apart")).await;

    let report = uncollided_control(&mut world, pr_tick())
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s25_dead_and_silent_relays_holds() {
    happy_path(Scenario::SilentRelays, "dead-and-silent-relays").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s26_identity_planes_under_faults_holds() {
    happy_path(Scenario::IdentityPlanes, "identity-planes-under-faults").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s26_identity_planes_with_no_pool_prove_nothing() {
    // The mis-configuration: no Profile row, so the pool underflows and the
    // product publishes and reads nothing — fail-closed, the curated pool
    // still excluded, so nothing leaves the machine.
    let mut world = build_shaped_world(&shape_for("identity-planes-under-faults")).await;

    let report = no_pool_control(&mut world, pr_tick())
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s27_mesh_off_then_on_holds() {
    happy_path(Scenario::MeshIndependence, "mesh-off-then-on").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s27_devices_out_of_radio_range_prove_nothing_about_the_mesh() {
    // The mis-configuration: mesh on at every device and none in range of
    // another, so no frame crosses a link and nothing is read from the mesh.
    let mut world = build_shaped_world(&shape_for("mesh-off-then-on")).await;

    let report = s27_mesh_independence::out_of_range_control(&mut world, pr_tick())
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s28_bridged_to_the_far_member_holds() {
    happy_path(Scenario::MemberBridging, "bridged-to-the-far-member").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s28_removed_member_finds_nothing_holds() {
    happy_path(Scenario::MemberBridging, "removed-member-finds-nothing").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s28_members_out_of_radio_range_prove_nothing_about_bridging() {
    // The mis-configuration: the offline member is in nobody's range, so the
    // online one reads nothing from the mesh and has nothing to pass on.
    let mut world = build_shaped_world(&shape_for("bridged-to-the-far-member")).await;

    let report = s28_member_bridging::out_of_range_control(&mut world, pr_tick())
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s27_after_a_setting_up_wait_ran_out_proves_nothing_and_names_no_delivery() {
    // The arm then waits for nothing: a send no peer was waited for is not
    // an undelivered one, which would outrank the unmet floor as rc 1.
    let mut world = build_shaped_world(&shape_for("mesh-off-then-on")).await;

    let report = s27_mesh_independence::late_setup_control(&mut world, pr_tick())
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s28_after_a_setting_up_wait_ran_out_proves_nothing_and_names_no_delivery() {
    let mut world = build_shaped_world(&shape_for("bridged-to-the-far-member")).await;

    let report = s28_member_bridging::late_setup_control(&mut world, pr_tick())
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

/// One arm run in a world of its own under `seed`: its verdict, and the
/// digest of every `EVENT` frame its devices sent a relay.
async fn seeded(scenario: Scenario, label: &str, seed: u64) -> (Rc, Vec<String>, [u8; 32]) {
    let mut world = build_shaped_world(&shape_for(label)).await;
    world.seed_with(seed);
    let report = scenario
        .run(&mut world, arm_of(scenario, label), pr_tick())
        .await
        .expect("the scenario runs");
    let graded = std::iter::once(report.floor.to_string())
        .chain(
            (report.graded.iter())
                .map(|(invariant, verdict)| format!("{} {verdict}", invariant.id())),
        )
        .collect();
    let digest = sent_digest(&world);
    world.teardown().await.expect("teardown");
    (report.rc(), graded, digest)
}

/// A mesh arm answers alike, and its devices send relays frames of the same
/// shapes, run after run and whatever seed its mesh engines draw from.
///
/// Not a proof that a seed reproduces what the MESH carried: inside a world
/// every packet wraps a fresh event under a fresh nonce, and this compares
/// nothing of the mesh. That a seed fixes what the plane carries is the
/// plane's own unit test, over fixed packets (`rig/mesh.rs`).
async fn answers_alike_run_to_run(scenario: Scenario, label: &str) {
    let first = seeded(scenario, label, 0x5eed).await;
    assert!(first.0 == Rc::Clean, "premise: the arm holds");
    assert!(
        seeded(scenario, label, 0x5eed).await == first,
        "a second run gives the same verdict and the same relay frames"
    );
    assert!(
        seeded(scenario, label, 0x0dd).await == first,
        "and so does one whose mesh engines draw from another seed"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s27_answers_and_sends_relays_alike_run_to_run_whatever_the_seed() {
    answers_alike_run_to_run(Scenario::MeshIndependence, "mesh-off-then-on").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s28_bridging_answers_and_sends_relays_alike_run_to_run_whatever_the_seed() {
    answers_alike_run_to_run(Scenario::MemberBridging, "bridged-to-the-far-member").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s28_removal_answers_and_sends_relays_alike_run_to_run_whatever_the_seed() {
    answers_alike_run_to_run(Scenario::MemberBridging, "removed-member-finds-nothing").await;
}

/// The three mesh arms, each in a world of `profile`'s shape: more devices
/// than the three that have a part, and more relays than one.
async fn mesh_arms_hold_in_the_world_of(profile: ProfileName) {
    let spec = ProfileSpec::embedded(profile).expect("the profile parses");
    for (scenario, label) in [
        (Scenario::MeshIndependence, "mesh-off-then-on"),
        (Scenario::MemberBridging, "bridged-to-the-far-member"),
        (Scenario::MemberBridging, "removed-member-finds-nothing"),
    ] {
        let mut world = build_shaped_world(&spec.world).await;
        let report = scenario
            .run(&mut world, arm_of(scenario, label), pr_tick())
            .await
            .expect("the scenario runs");
        assert!(
            report.holds(),
            "a mesh arm must hold in every world a lane runs it in: {report}; floor {}",
            report.floor
        );
        world.teardown().await.expect("teardown");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_mesh_arms_hold_in_the_nightly_world() {
    mesh_arms_hold_in_the_world_of(ProfileName::Nightly).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_mesh_arms_hold_in_the_weekly_world() {
    mesh_arms_hold_in_the_world_of(ProfileName::Weekly).await;
}

/// A mesh arm in a world whose relays deliver no location to anybody, so
/// that every wait the arm makes for one would run out: it reports the
/// undelivered location, and inside the bound it is priced at — one wait
/// ran out and no other was made.
async fn dead_delivery_is_reported_inside_the_arms_price(scenario: Scenario, label: &str) {
    let mut world = build_shaped_world(&shape_for(label)).await;
    let devices: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    for plane in world.relays_mut() {
        for &device in &devices {
            plane
                .apply_for(device, Fault::DropClass(DropClass::Application))
                .await
                .expect("the endpoint takes the fault");
        }
    }

    let report = scenario
        .run(&mut world, arm_of(scenario, label), pr_tick())
        .await
        .expect("the scenario runs");

    assert!(
        report.graded.iter().any(|(_, verdict)| matches!(
            verdict,
            Verdict::Failed(Finding::ProbeNotDelivered { .. })
        )) && report.rc() == Rc::ViolationOrLeak,
        "a relay path that delivers nothing is the finding, by name: {report}"
    );
    assert!(
        report.within_deadline(),
        "and the arm says so inside its derived bound, never by a deadline kill: {report}"
    );
    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s27_reports_a_dead_relay_delivery_inside_its_price() {
    dead_delivery_is_reported_inside_the_arms_price(Scenario::MeshIndependence, "mesh-off-then-on")
        .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s28_bridging_reports_a_dead_relay_delivery_inside_its_price() {
    dead_delivery_is_reported_inside_the_arms_price(
        Scenario::MemberBridging,
        "bridged-to-the-far-member",
    )
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s28_removal_reports_a_dead_relay_delivery_inside_its_price() {
    dead_delivery_is_reported_inside_the_arms_price(
        Scenario::MemberBridging,
        "removed-member-finds-nothing",
    )
    .await;
}

/// A world whose every device has just come to the foreground on relays that
/// kept their NIP-77 answers back: each session its entry pass opened was
/// given up by the pool at its negotiation wait, and none was closed.
async fn world_after_an_unanswered_entry_pass(label: &str) -> World {
    let mut world = build_shaped_world(&shape_for(label)).await;
    let sessions = |world: &World, frame| -> usize {
        (world.relays().iter())
            .map(|plane| plane.ledger().neg_total(frame))
            .sum()
    };
    // The pass each start ran must not stand in for the entry's own: the
    // product's spacing between two passes is let pass, as S20 does.
    let (spacing, since) = (bounds::negentropy_spacing(), Instant::now());
    poll_until(spacing + bounds::wall_second_turnover(), TICK, || async {
        Ok(since.elapsed() >= spacing)
    })
    .await
    .expect("a clock read cannot fail");
    let before = (
        sessions(&world, NegFrame::Open),
        sessions(&world, NegFrame::Close),
    );
    for plane in world.relays_mut() {
        plane
            .apply(Fault::WithholdNegentropy)
            .await
            .expect("the plane takes the fault");
    }
    let devices: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    for &tag in &devices {
        let device = world.device_mut(tag).expect("a device of the world");
        device.go_offline().await.expect("the device pauses");
        device.come_online().await.expect("the device resumes");
        device.take_in_replay().await.expect("an engine runs");
    }
    for plane in world.relays_mut() {
        plane.apply(Fault::Heal).await.expect("the plane heals");
    }
    assert!(
        sessions(&world, NegFrame::Open) > before.0
            && sessions(&world, NegFrame::Close) == before.1,
        "premise: the entries opened sessions, and the pool closed none of them"
    );
    world
}

/// A NIP-77 session the pool gave up is never closed on the wire, and is
/// nobody's undelivered location: the arm that follows it holds.
async fn an_unanswered_entry_pass_is_no_finding(scenario: Scenario, label: &str) {
    let mut world = world_after_an_unanswered_entry_pass(label).await;

    let report = scenario
        .run(&mut world, arm_of(scenario, label), pr_tick())
        .await
        .expect("the scenario runs");

    let graded: Vec<String> = report
        .graded
        .iter()
        .map(|(invariant, verdict)| format!("{} {verdict}", invariant.id()))
        .collect();
    assert!(
        report.holds() && report.rc() == Rc::Clean,
        "a relay slow to answer a session at a foreground entry changes nothing \
         the arm grades: {report}; floor {}; {}",
        report.floor,
        graded.join("; ")
    );
    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s27_holds_after_an_entry_pass_no_relay_answered() {
    an_unanswered_entry_pass_is_no_finding(Scenario::MeshIndependence, "mesh-off-then-on").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s28_bridging_holds_after_an_entry_pass_no_relay_answered() {
    an_unanswered_entry_pass_is_no_finding(Scenario::MemberBridging, "bridged-to-the-far-member")
        .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s28_removal_holds_after_an_entry_pass_no_relay_answered() {
    an_unanswered_entry_pass_is_no_finding(
        Scenario::MemberBridging,
        "removed-member-finds-nothing",
    )
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s25_relays_that_all_answered_prove_nothing_about_a_silent_one() {
    // The mis-configuration: no relay is dead or silent, so nothing held the
    // circle and nothing was owed.
    let mut world = build_shaped_world(&shape_for("dead-and-silent-relays")).await;

    let report = answering_control(&mut world, pr_tick())
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

/// S08 `buried-past-the-cap` was `EXPECTED_RED` for C8 until R4: the victim's
/// foreground entry now runs a NIP-77 pass that recovers the buried commit, and
/// the arm grades rc 0 with its `reconciled_on_the_wire` canary met — so a
/// recovery by any other mechanism would leave the floor unmet, not green.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s08_buried_past_the_cap_holds() {
    happy_path(Scenario::LivePlaneBurial, "buried-past-the-cap").await;
}

/// The residual on a relay that does not speak NIP-77, recorded: the burial
/// persists there, every canary met — the day it stops, the arm is rc 3.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s08_buried_on_a_relay_without_negentropy_holds() {
    happy_path(
        Scenario::LivePlaneBurial,
        "buried-on-a-relay-without-negentropy",
    )
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s20_same_second_pile_up_holds() {
    happy_path(Scenario::CatchupSweep, "same-second-pile-up").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s20_same_second_pile_up_without_negentropy_holds() {
    happy_path(
        Scenario::CatchupSweep,
        "same-second-pile-up-without-negentropy",
    )
    .await;
}

/// Runs S05's `kill-sweep-eviction` and requires it green on the path that
/// replaced the wake sweep's own staging: its floor met — the sweep made
/// nothing of the departure, the process died, and the foreground's drive made
/// the eviction under a record and a relay acknowledged it — and every oracle
/// holding (decision 27's window closed in W9q).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s05_kill_sweep_eviction_is_green_on_the_driven_path() {
    let (scenario, label) = (Scenario::PublishConfirmWindow, "kill-sweep-eviction");
    assert!(
        !EXPECTED_RED.contains(&(scenario, label)),
        "the arm this test requires green is not on the expected-red list"
    );
    let arm = arm_of(scenario, label);
    let mut world = build_shaped_world(&shape_for(label)).await;

    let report = scenario
        .run(&mut world, arm, pr_tick())
        .await
        .expect("the scenario runs");

    assert!(
        report.floor == Verdict::Holds,
        "the arm did not reach its own conditions: the sweep made something of the \
         departure, or the foreground's drive did not make the eviction"
    );
    assert!(
        report.rc() == Rc::Clean && report.holds(),
        "a wake sweep killed after taking a departure in left a circle that does not \
         converge, or a send it refuses"
    );

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s05_a_sweep_under_no_silence_proves_nothing() {
    // The mis-configuration: no plane swallows an acknowledgement while the
    // sweep runs, so the silence the arm's floor counts never falls and the
    // run proves nothing about a sweep that could have sent into one.
    let mut world = build_shaped_world(&shape_for("kill-sweep-eviction")).await;

    let report = acked_kill_control(&mut world, "kill-sweep-eviction", pr_tick())
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_scenario_arm_graded_against_a_floor_it_cannot_reach_is_unusable() {
    let scenario = Scenario::StuckRow;
    let arm = arm_of(scenario, "stuck-row-sweep");
    let mut world = build_shaped_world(&shape_for(arm.label)).await;

    let report = scenario
        .run(&mut world, arm, pr_tick())
        .await
        .expect("the scenario runs");
    assert!(
        report.holds(),
        "the arm under test is a healthy one, so the only thing the control \
         changes is the floor it is graded against"
    );

    // The plant: one more fault than the arm fires. Nothing about the world
    // changes — the same observation is graded against a declaration it cannot
    // satisfy, which is the ARITHMETIC of a floor rather than a world that
    // proved nothing. The controls below are the other half: a real
    // mis-configuration, one per scenario.
    let unreachable = ExpectationFloor {
        faults_applied: report.observed.faults_applied + 1,
        ..arm.floor
    };
    let verdict = grade(&unreachable, &report.observed);
    assert!(
        verdict == Verdict::Failed(Finding::FloorUnmet(FloorTerm::FaultsApplied)),
        "a floor the arm did not reach names the term it fell short on"
    );
    assert!(
        verdict.rc() == Rc::Unusable,
        "and folds to rc 3: an arm that proved nothing is unusable, never clean \
         and never a violation of the subject"
    );

    world.teardown().await.expect("teardown");
}

// ── One real mis-configuration control per scenario (R-M5) ──────────────────
//
// A floor re-graded against a bigger number is arithmetic. These controls are
// the other thing: the arm is run for real against a world deliberately arranged so
// the condition it grades cannot arise, and the run must report rc 3 — "this
// proves nothing" — rather than the rc 0 every oracle would otherwise give it.
//
// Several come back as a rig error rather than as a report, because the arm
// cannot reach its own grading point at all. That error's own verdict is rc 3
// for the same reason, and the assertion says so.

/// Requires `report`'s expectation floor to be unmet, whatever its oracles
/// answered.
///
/// A control is rc 3 and nothing else. A mis-configured world that also
/// reddens an oracle folds to rc 1, and a red control is a control that
/// staged a defect instead of a world where the arm's condition cannot arise.
fn floor_is_unusable(report: &haven_soak::scenarios::ScenarioReport) {
    assert!(
        report.floor != Verdict::Holds,
        "a world arranged so the arm's own condition cannot arise must fail its \
         expectation floor, or the floor is not holding the arm to anything"
    );
    assert!(
        report.rc() == Rc::Unusable,
        "and an unmet floor over green oracles is rc 3: the run proves nothing, \
         which is neither clean nor a finding about the subject"
    );
}

/// Waits, bounded, for every device to see no connected relay at all.
///
/// The product's own health probe, so the control knows the endpoint really is
/// gone before it runs the arm that depends on it being gone.
async fn wait_until_disconnected(world: &World, bound: Duration) -> bool {
    let started = Instant::now();
    let mut ticker = tokio::time::interval(POLL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        let mut all = true;
        for device in world.devices() {
            let health = device.engine().expect("an engine").relay_health().await;
            all &= health.connected == 0;
        }
        if all {
            return true;
        }
        if started.elapsed() >= bound {
            return false;
        }
        ticker.tick().await;
    }
}

/// Takes every plane a device's engine holds down — the circles' and its
/// inbox — and waits for the devices to notice: the world fully offline.
async fn down_and_noticed(world: &mut World) {
    for tag in world.engine_plane_tags() {
        world
            .plane_mut(tag)
            .expect("an engine plane is the world's")
            .apply(Fault::Down)
            .await
            .expect("the plane takes the fault");
    }
    assert!(
        wait_until_disconnected(world, bounds::round_trip(Recovery::Undisturbed)).await,
        "the control's premise: the endpoint really is gone before the arm runs"
    );
}

/// Runs `label` against `world` at the PR tick.
async fn run_arm(
    scenario: Scenario,
    label: &str,
    world: &mut World,
) -> Result<haven_soak::scenarios::ScenarioReport, haven_soak::rig::RigError> {
    scenario
        .run(world, arm_of(scenario, label), pr_tick())
        .await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s02_a_publisher_standing_as_its_own_witness_proves_no_partition() {
    // The mis-configuration: the witness role is filled by the publisher. An
    // engine folds no fix of its own, so nobody on the other side can be seen
    // to keep receiving — and a partition is only a partition if somebody did.
    // The victim's partition and recovery still run and hold, and both graded
    // rounds are whole, so the floor goes unmet over green oracles: rc 3,
    // never a partition the arm could not witness. (A drop armed on the
    // witness's endpoint instead would redden the control round's O1 before
    // any partition — rc 1, a defect staged rather than a world that proves
    // nothing.)
    let mut world = build_shaped_world(&shape_for("partitioned-receiver")).await;

    let report = unwitnessed_control(&mut world, pr_tick())
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);
    assert!(
        report.floor == Verdict::Failed(Finding::FloorUnmet(FloorTerm::CanariesCaught)),
        "the two unpartitioned-peer canaries are what go unmet, and nothing before them"
    );

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s03_a_commit_no_relay_ever_stored_cannot_be_lost() {
    // The mis-configuration: the endpoint is gone, so the commit the arm means
    // to lose is never acknowledged and Rule 13 rolls it back before any store
    // could hold it. A commit that was never stored cannot be forgotten, and a
    // device cannot be stranded behind one — the arm refuses at the first
    // unacknowledged commit rather than reporting a strand it never staged.
    let mut world = build_shaped_world(&shape_for("lost-commit-strands")).await;
    down_and_noticed(&mut world).await;

    let report = run_arm(Scenario::LostCommit, "lost-commit-strands", &mut world).await;
    match report {
        Ok(report) => floor_is_unusable(&report),
        Err(refused) => assert!(
            refused.rc() == Rc::Unusable,
            "an arm with no stored commit to lose is rc 3, never clean"
        ),
    }

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s01_an_outage_whose_recovery_cannot_be_observed_is_unusable() {
    // The mis-configuration: a second plane that never comes back. The rolling
    // arm breaks and heals each plane in turn and must SEE each of them return;
    // with one endpoint held down, the first heal's observation can never hold,
    // so the arm applies every fault it declares and still cannot show what it
    // claims to.
    let mut world = build_shaped_world(&shape_for("rolling-outage")).await;
    world.relays_mut()[1]
        .apply(Fault::Down)
        .await
        .expect("the plane takes the fault");

    let report = run_arm(Scenario::RelayOutage, "rolling-outage", &mut world)
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s04_a_world_whose_epochs_cannot_move_strands_nobody() {
    // The mis-configuration: the endpoint is gone, so Rule 13 rolls back every
    // commit the arm stages and no epoch is ever crossed above the device that
    // went away. "Away across commits it did not see" cannot arise in a world
    // where nobody commits, and the arm says so rather than reporting a
    // catch-up it never had to make.
    let mut world = build_shaped_world(&shape_for("offline-across-commits")).await;
    down_and_noticed(&mut world).await;

    let report = run_arm(
        Scenario::OfflineMember,
        "offline-across-commits",
        &mut world,
    )
    .await;
    match report {
        Ok(report) => floor_is_unusable(&report),
        // The arm refuses one step earlier, when the first commit goes
        // unacknowledged. Same finding, same verdict.
        Err(refused) => assert!(
            refused.rc() == Rc::Unusable,
            "an arm with no epoch above the absent device is rc 3, never clean"
        ),
    }

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s05_a_commit_nobody_acked_has_no_confirm_that_could_fail() {
    // The mis-configuration: every acknowledgement is swallowed, so Rule 13
    // never licenses a confirm anywhere in the arm — the victim circle cannot
    // even be created. A confirm that fails after the engine already delivered
    // is the arm's whole subject, and there is no confirm at all.
    let mut world = build_shaped_world(&shape_for("confirm-err-is-not-a-failure")).await;
    for plane in world.all_planes_mut() {
        plane
            .apply(Fault::SwallowOk)
            .await
            .expect("the plane takes the fault");
    }

    let refused = run_arm(
        Scenario::PublishConfirmWindow,
        "confirm-err-is-not-a-failure",
        &mut world,
    )
    .await
    .expect_err("nothing was acked, so nothing could be confirmed");
    assert!(
        refused.rc() == Rc::Unusable,
        "an arm with no publish→confirm window to die inside is rc 3, never clean"
    );

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s05_a_kill_after_the_ack_has_no_window_to_die_inside() {
    // The kill arms' mis-configuration: no acknowledgement is swallowed, so the
    // publish is acked and Rule 13 confirms it before the kill. The process
    // dies with nothing between SEND and confirm, and the arm says so rather
    // than grading a restart as a kill inside the window.
    let mut world = build_shaped_world(&shape_for("kill-send-plane")).await;

    let report = acked_kill_control(&mut world, "kill-send-plane", pr_tick())
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s05_an_eviction_acked_before_the_kill_leaves_nothing_owed_to_orphan() {
    // The receive-plane kill's mis-configuration: nothing swallows the
    // committer's acknowledgement, so the foreground's drive sends the
    // eviction, Rule 13 confirms it, and the process dies with no record
    // awaiting a relay.
    let mut world = build_shaped_world(&shape_for("kill-receive-auto-commit")).await;

    let report = acked_kill_control(&mut world, "kill-receive-auto-commit", pr_tick())
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s14_two_commits_nobody_acked_are_not_a_race() {
    // The mis-configuration: the endpoint is gone, so neither racer's commit is
    // ever acknowledged and Rule 13 rolls both back. A race is two CONFIRMED
    // siblings at one epoch; two rolled-back commits are neither, and the arm
    // refuses rather than classifying a branch loss nothing branched.
    let mut world = build_shaped_world(&shape_for("race-no-restart")).await;
    down_and_noticed(&mut world).await;

    let refused = run_arm(Scenario::RestartRace, "race-no-restart", &mut world)
        .await
        .expect_err("no ack, no confirmed sibling, no race");
    assert!(
        refused.rc() == Rc::Unusable,
        "an arm with no second branch is rc 3, never clean"
    );

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s06_a_row_already_past_the_horizon_proves_no_age_rule() {
    // The mis-configuration: the gated device's POLICY clock starts past the
    // unresolvable horizon, so the sweep the arm calls "early" is already late.
    // The row is retired before the arm can show that a sweep under the horizon
    // declines it — which is the half that stops the age rule being deleted.
    let mut world = build_shaped_world(&shape_for("stuck-row-sweep")).await;
    let stuck = world.devices()[1].tag;
    let past = i64::try_from(bounds::unresolvable_input_max_age().as_secs()).expect("a horizon");
    world
        .device_mut(stuck)
        .expect("the gated device")
        .step_policy_offset(past + 1);

    let report = run_arm(Scenario::StuckRow, "stuck-row-sweep", &mut world)
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s09_a_forgery_no_client_can_receive_poisons_nothing() {
    // The mis-configuration: the endpoint is closed before the adversary
    // forges, so no subscription is open on it and the forged frame reaches
    // nobody. An injection nobody received did not happen, and every "the
    // anchor did not move" below it would be a statement about an event that
    // was never delivered.
    let mut world = build_shaped_world(&shape_for("standing-adversary")).await;
    down_and_noticed(&mut world).await;

    let report = run_arm(Scenario::CursorPoisoning, "standing-adversary", &mut world).await;
    match report {
        Ok(report) => floor_is_unusable(&report),
        Err(refused) => assert!(
            refused.rc() == Rc::Unusable,
            "a forgery with nobody to write it towards is rc 3, never clean"
        ),
    }

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s12_a_slot_no_relay_serves_has_no_rotation_to_decide() {
    // The mis-configuration: the endpoint is gone, so the key package is never
    // acked and no plane serves the slot. `decide_kp_maintenance` fails closed
    // on a tick where nobody responded — it can neither confirm a drop nor
    // publish a rotation — so `Rotate` can never be the decision and the arm
    // grades a policy it never reached.
    let mut world = build_shaped_world(&shape_for("kp-rotation-slot")).await;
    down_and_noticed(&mut world).await;

    let report = run_arm(Scenario::KeyPackageRotation, "kp-rotation-slot", &mut world).await;
    match report {
        Ok(report) => floor_is_unusable(&report),
        // The arm refuses one step earlier, when the first key package goes
        // unacknowledged. Same finding, same verdict.
        Err(refused) => assert!(
            refused.rc() == Rc::Unusable,
            "an arm whose slot is on no plane is rc 3, never clean"
        ),
    }

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s12_a_package_that_never_expired_is_never_refused() {
    // The mis-configuration: the package the rejection arm expects refused is
    // minted under the production lifetime instead, so the engine accepts it
    // and the lifetime refusal the arm grades never happens. Its twin and the
    // silent planes still hold and the closing round is green, so the floor
    // goes unmet over green oracles: rc 3, never a cliff nobody reached.
    let mut world = build_shaped_world(&shape_for("kp-expired-rejected")).await;

    let report = unexpired_control(&mut world, pr_tick())
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s22_an_event_that_reached_no_relay_was_refused_by_none() {
    // The mis-configuration: the endpoint is closed, so the commit never
    // crosses to a plane at all. "Nothing acknowledged it" is then true for the
    // ordinary reason — an outage — and the machine-readable refusal this arm
    // grades, `OK false invalid:` on the client's own stream, never happens. An
    // outage is not a size cap, and the arm says so rather than reporting a
    // refusal nothing produced.
    let mut world = build_shaped_world(&shape_for("oversized-commit")).await;
    down_and_noticed(&mut world).await;

    let report = run_arm(Scenario::OversizedEvent, "oversized-commit", &mut world).await;
    match report {
        Ok(report) => floor_is_unusable(&report),
        Err(refused) => assert!(
            refused.rc() == Rc::Unusable,
            "an arm with no refusal on the wire is rc 3, never clean"
        ),
    }

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s11_a_prune_that_starts_past_the_rows_horizon_proves_no_retention() {
    // The same mis-configuration on the other clock-sensitive arm: with the
    // quiet device already past the row's own `purge_after`, the prune the arm
    // calls "below the horizon" retires the row, and the straddle it grades
    // never happens.
    let mut world = build_shaped_world(&shape_for("quiet-circle-resume")).await;
    let quiet = world.devices()[1].tag;
    let past = i64::try_from(bounds::unresolvable_input_max_age().as_secs()).expect("a horizon");
    world
        .device_mut(quiet)
        .expect("the quiet device")
        .step_policy_offset(past + 1);

    let report = run_arm(Scenario::QuietCircle, "quiet-circle-resume", &mut world)
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s13_a_victim_circle_that_was_never_created_cannot_be_quarantined() {
    // The mis-configuration: every acknowledgement is swallowed, so the circle
    // this arm exists to break is rolled back under Rule 13 and never exists.
    // The arm cannot reach its own grading point, and says so as rc 3 rather
    // than reporting a quarantine it never induced.
    let mut world = build_shaped_world(&shape_for("hydration-quarantine")).await;
    for plane in world.all_planes_mut() {
        plane
            .apply(Fault::SwallowOk)
            .await
            .expect("the plane takes the fault");
    }

    let refused = run_arm(
        Scenario::HydrationQuarantine,
        "hydration-quarantine",
        &mut world,
    )
    .await
    .expect_err("the victim circle cannot be created");
    assert!(
        refused.rc() == Rc::Unusable,
        "an arm that never reached the state it grades is rc 3, never clean"
    );

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s17_a_notice_no_client_can_receive_proves_nothing() {
    // The mis-configuration: the endpoint is closed before the arm injects its
    // NOTICE, so the text reaches no client-facing stream. The arm's one canary
    // is that the text was READ BACK off the wire, and there is no wire.
    let mut world = build_shaped_world(&shape_for("notice")).await;
    down_and_noticed(&mut world).await;

    let report = run_arm(Scenario::ClosedPrefixes, "notice", &mut world).await;
    match report {
        Ok(report) => floor_is_unusable(&report),
        // The injection itself can refuse once the last connection is gone,
        // which is the same finding one step earlier.
        Err(refused) => assert!(
            refused.rc() == Rc::Unusable,
            "a NOTICE with nobody to write it towards is rc 3, never clean"
        ),
    }

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s18_a_relay_that_never_received_the_event_proves_no_swallowed_ack() {
    // The mis-configuration: the endpoint is closed, so the location never
    // reaches the relay's store. "Nothing acknowledged it" is then true for the
    // ordinary reason — an outage — and the gap this arm grades, stored HERE and
    // unacknowledged THERE, does not exist.
    let mut world = build_shaped_world(&shape_for("swallowed-ok-location-send")).await;
    down_and_noticed(&mut world).await;

    let report = run_arm(
        Scenario::SwallowedOk,
        "swallowed-ok-location-send",
        &mut world,
    )
    .await
    .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s19_a_probe_that_never_crossed_cannot_be_duplicated() {
    // The mis-configuration: the endpoint is closed, so the probe the arm
    // intends to have delivered twice is never acknowledged even once. There is
    // nothing stored to replay, and the arm refuses rather than reporting a
    // dedup nothing exercised.
    let mut world = build_shaped_world(&shape_for("duplicate-replay")).await;
    down_and_noticed(&mut world).await;

    let refused = run_arm(Scenario::DuplicateReorder, "duplicate-replay", &mut world)
        .await
        .expect_err("nothing was acked, so nothing can be duplicated");
    assert!(
        refused.rc() == Rc::Unusable,
        "an arm with nothing on the wire to duplicate is rc 3, never clean"
    );

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s10_a_world_already_at_the_whole_roster_measures_nothing_about_scale() {
    // The mis-configuration: the world is built at the roster bound, so the
    // arm builds and adopts nothing and no engine is subscribed to a circle
    // mid-session. Every circle still delivers and every oracle holds, but the
    // arm's whole content — the roster GROWN to ten under running engines and
    // then carried across an outage — never happened, and the arm says so.
    let mut world = build_shaped_world(&WorldShape {
        members: pr_spec().world.members,
        circles: 10,
        relays: 1,
        account_relays: 1,
        profile_relays: 0,
    })
    .await;

    let report = run_arm(Scenario::TenCircleRoster, "ten-circle-roster", &mut world)
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s23_one_commit_while_away_is_not_a_chained_backlog() {
    // The mis-configuration: ONE commit lands while the victim is away. A
    // single commit is redelivered and applied on its own (S04), so the victim
    // converges, every oracle holds, and what the floor demands — a chain of
    // two — never formed: rc 3, never a green that proves nothing about C7.
    let mut world = build_shaped_world(&shape_for("chained-commit-backlog")).await;

    let report = one_commit_control(&mut world, pr_tick())
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);
    assert!(
        report.floor == Verdict::Failed(Finding::FloorUnmet(FloorTerm::EpochsCrossed)),
        "the term that goes unmet is the chain's length, and nothing before it"
    );

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s16_a_seal_no_plane_ever_carried_floods_no_buffer() {
    // The mis-configuration: the endpoint is gone, so the co-member's first
    // future-header seal is never acknowledged and the plane never holds it.
    // Nothing reaches the victim, the counter it reads before the flood is the
    // counter it would read after, and the arm refuses at that first seal
    // rather than reporting a store that grew.
    let mut world = build_shaped_world(&shape_for("member-future-header-flood")).await;
    down_and_noticed(&mut world).await;

    let report = run_arm(
        Scenario::StorageGrowth,
        "member-future-header-flood",
        &mut world,
    )
    .await;
    match report {
        Ok(report) => floor_is_unusable(&report),
        Err(refused) => assert!(
            refused.rc() == Rc::Unusable,
            "a flood with no plane to carry it is rc 3, never clean"
        ),
    }

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s16_fixes_no_plane_ever_carried_grow_no_processed_ids() {
    // The mis-configuration: the endpoint is gone, so the circle's only sends
    // are dropped at the plane. No wrapper reaches the victim, nothing is
    // peeled, and the arm refuses at its first fix rather than reporting a
    // table that grew.
    let mut world = build_shaped_world(&shape_for("processed-ids-growth")).await;
    down_and_noticed(&mut world).await;

    let report = run_arm(Scenario::StorageGrowth, "processed-ids-growth", &mut world).await;
    match report {
        Ok(report) => floor_is_unusable(&report),
        Err(refused) => assert!(
            refused.rc() == Rc::Unusable,
            "growth with no plane to carry the traffic is rc 3, never clean"
        ),
    }

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s21_a_member_already_removed_has_no_removal_left_to_grade() {
    // The mis-configuration: the evictee is removed and its commit delivered
    // BEFORE the arm runs, so it is already self-evicted and no longer in the
    // admin's roster. The withheld arm's own `remove_member` then has nobody to
    // remove — a fresh removal to hold back cannot arise — so it refuses at the
    // stage step rather than reporting a withheld path it never staged.
    let mut world = build_shaped_world(&shape_for("removal-withheld-commit")).await;
    let admin = world.devices()[0].tag;
    let evictee = world.devices()[3].tag;
    let circle_tag = world.circles()[0].tag;

    let commit = {
        let circle = world.circle(circle_tag).expect("a circle");
        let (commit, verdict) =
            haven_soak::scenarios::remove_member(&world, admin, circle, evictee)
                .await
                .expect("the removal stages and resolves");
        assert!(
            verdict == haven_soak::rig::PublishVerdict::Confirmed,
            "the control's own removal must confirm, or the evictee is not gone"
        );
        commit
    };
    // Deliver it to the evictee so its group is inactive, exactly as a delivered
    // removal would leave it.
    world
        .device(evictee)
        .expect("a device")
        .session()
        .expect("a session")
        .process_event_typed_for_test(&commit)
        .await
        .expect("the evictee ingests its own removal");

    let report = run_arm(
        Scenario::RemovalEffectiveness,
        "removal-withheld-commit",
        &mut world,
    )
    .await;
    match report {
        Ok(report) => floor_is_unusable(&report),
        // The arm refuses at the stage step: the evictee is no longer a member,
        // so there is no removal to withhold. Same finding, same verdict.
        Err(refused) => assert!(
            refused.rc() == Rc::Unusable,
            "an arm with no fresh removal to grade is rc 3, never clean"
        ),
    }

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s20_a_sweep_over_an_empty_store_drains_nothing() {
    // The mis-configuration: no backlog is seeded, so every circle's window is
    // empty and the sweep "drains" it in one pass having fetched nothing. The
    // advance still lands on the sweep's own open time — that canary holds —
    // but the drain it would be the evidence of never had anything to drain:
    // rc 3, never a clean catch-up over a backlog that was not there.
    let mut world = build_shaped_world(&shape_for("healthy-drain")).await;

    let report = empty_store_control(&mut world, pr_tick())
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);
    assert!(
        report.floor == Verdict::Failed(Finding::FloorUnmet(FloorTerm::CanariesCaught)),
        "the drain canary is what goes unmet, and nothing before it"
    );

    world.teardown().await.expect("teardown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s08_a_seed_the_relay_serves_whole_buries_nothing() {
    // The mis-configuration: the burial arm over a seed below the relay's
    // replay cap. The page the victim is served holds the commit, the victim
    // applies it and every oracle holds — but the capped page the arm grades
    // never formed: rc 3, never a clean burial that did not happen.
    let mut world = build_shaped_world(&shape_for("buried-past-the-cap")).await;

    let report = below_the_cap_control(&mut world, pr_tick())
        .await
        .expect("the scenario runs");
    floor_is_unusable(&report);
    assert!(
        report.floor == Verdict::Failed(Finding::FloorUnmet(FloorTerm::CanariesCaught)),
        "the capped-page canary is what goes unmet, and nothing before it"
    );

    world.teardown().await.expect("teardown");
}

#[test]
fn every_registered_scenario_has_a_mis_configuration_control() {
    // The controls above, by the scenario each one controls. Written out
    // so that a scenario added to the registry without a control fails here
    // rather than inheriting somebody else's.
    const CONTROLLED: [Scenario; 26] = [
        Scenario::RelayOutage,
        Scenario::ReceiverPartition,
        Scenario::LostCommit,
        Scenario::OfflineMember,
        Scenario::PublishConfirmWindow,
        Scenario::StuckRow,
        Scenario::LivePlaneBurial,
        Scenario::CursorPoisoning,
        Scenario::QuietCircle,
        Scenario::KeyPackageRotation,
        Scenario::HydrationQuarantine,
        Scenario::RestartRace,
        Scenario::ClosedPrefixes,
        Scenario::SwallowedOk,
        Scenario::DuplicateReorder,
        Scenario::OversizedEvent,
        Scenario::TenCircleRoster,
        Scenario::ChainedBacklog,
        Scenario::StorageGrowth,
        Scenario::RemovalEffectiveness,
        Scenario::CatchupSweep,
        Scenario::RoutingCollision,
        Scenario::SilentRelays,
        Scenario::IdentityPlanes,
        Scenario::MeshIndependence,
        Scenario::MemberBridging,
    ];
    assert!(
        CONTROLLED.len() == Scenario::REGISTRY.len(),
        "a scenario was registered without a deliberate mis-configuration control"
    );
    for scenario in Scenario::REGISTRY {
        assert!(
            CONTROLLED.contains(&scenario),
            "every registered scenario has a control that must report rc 3"
        );
    }
}

/// A commit staged under its record and left for a later drive — the shape a
/// resolution hands back when it stages the next commit of a cascade — is sent
/// and confirmed by the next foreground drive the rig asks the product for,
/// never left staged for nobody.
///
/// The rig resolves no pending state of its own any more: the product's driver
/// (`Publishing::resume`) is the one that does, and a commit left staged forks
/// the group, which is the state every oracle in this file assumes away.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_commit_left_for_the_next_drive_is_sent_and_confirmed_by_it() {
    let world = build_shaped_world(&pr_spec().world).await;
    let group = world.circles()[0].mls_group_id().clone();
    let admin = world.devices()[0].tag;
    let mut relays = world.relay_urls();
    relays.push("wss://ladder.example.com".to_string());
    let relays = relays;

    let staged = world
        .device(admin)
        .expect("the admin")
        .manager()
        .expect("a manager")
        .update_circle_relays_staging(&group, &relays, WallClock.now_ms())
        .await
        .expect("a relay-list commit stages");
    assert!(staged.commit.is_some(), "premise: a commit was staged");
    let seal = |index| {
        let world = &world;
        let group = &group;
        async move {
            world
                .device(admin)
                .expect("the admin")
                .manager()
                .expect("a manager")
                .seal_location_for_test(group, &ProbeToken::mint(0, index).as_location())
                .await
        }
    };
    assert!(
        seal(1).await.is_err(),
        "precondition: the staged commit really does hold the circle in a \
         publish-before-apply transition"
    );

    let resumed = world.resume(admin).await.expect("the driver runs");

    // The commit moved the circle's relays, and the REQs the engine re-issues
    // for them hold the circle's seals while their stored replay is unread
    // (Security Rule 10). That hold, and no other, is waited out: a commit
    // left staged answers as another hold, at once and for ever.
    let location = ProbeToken::mint(0, 2).as_location();
    let started = Instant::now();
    let mut ticker = tokio::time::interval(POLL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let sealed = loop {
        let seal = world
            .seal_fix(admin, &group, &location, &WallClock)
            .await
            .expect("the seal is asked for")
            .seal;
        let unread = matches!(seal, LocationSeal::Deferred(SendHeld::StoredInput));
        if !unread || started.elapsed() >= bounds::round_trip(Recovery::Undisturbed) {
            break seal;
        }
        ticker.tick().await;
    };
    assert!(
        !resumed.errored && matches!(sealed, LocationSeal::Sealed { .. }),
        "the circle sends again, which only a RESOLVED pending state allows — a \
         drive that left it would leave the group staged for ever"
    );

    world.teardown().await.expect("teardown");
}
