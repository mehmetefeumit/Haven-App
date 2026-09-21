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

use haven_core::circle::DecryptedIngest;
use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::nostr::mls::types::{GroupId, OpenMlsContentKind, UNRESOLVABLE_INPUT_MAX_AGE_SECS};
use haven_core::relay::live_sync::config::{
    BACKOFF_JITTER_FRACTION_BP, BACKOFF_MAX_SECS, BURST_BACKLOG_WAIT_SECS,
    COMMIT_SETTLE_WINDOW_SECS, DELIVERY_SILENCE_RETENTION_MULTIPLE, SUBSCRIBE_CONNECT_WAIT_SECS,
    SUBSCRIBE_MAX_ATTEMPTS, SUBSCRIBE_RETRY_WAIT_SECS,
};
use tokio::time::{Instant, MissedTickBehavior};

use haven_soak::nemesis::types::{Fault, Schedule};
use haven_soak::oracle::quiescence::{self, PendingReason, Quiescence, Settled};
use haven_soak::oracle::undecryptable::{self, StoredRow};
use haven_soak::oracle::vacuity::{grade, ExpectationFloor, FloorTerm, Observed};
use haven_soak::oracle::{bounds, Finding, Invariant, ProbeToken, Reach, Recovery, Round, Verdict};
use haven_soak::profiles::{ProfileName, ProfileSpec, WorldShape};
use haven_soak::rc::Rc;
use haven_soak::relay::SimRelay;
use haven_soak::rig::{CapturedLine, DeviceTag, LogDrain, RelayPlane, RelayTag, SimWorld};
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
    }
}

async fn build_world() -> World {
    build_shaped_world(&smallest_shape()).await
}

/// A world of exactly `shape`, on as many relay planes as the shape declares.
async fn build_shaped_world(shape: &WorldShape) -> World {
    let mut relays = Vec::with_capacity(shape.relays);
    for ordinal in 0..shape.relays {
        relays.push(
            SimRelay::start(RelayTag::new(
                u32::try_from(ordinal).expect("a world has few relays"),
            ))
            .await
            .expect("the relay plane starts"),
        );
    }
    SimWorld::build(
        shape,
        Schedule::new(Vec::new()),
        relays,
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

    // The plant, in the product's own terms: a commit staged and neither
    // confirmed nor rolled back. Every READ accessor is still cheerful about
    // this group — which is exactly why O2 carries a send attempt.
    let staged = world
        .device(alice)
        .expect("alice")
        .manager()
        .expect("a manager")
        .update_circle_relays(&group, &relay_set(&world))
        .await
        .expect("a relay-list commit stages");
    let outstanding = world.note_pending_staged();

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

    drop(outstanding);
    let ingest = world
        .device(alice)
        .expect("alice")
        .manager()
        .expect("a manager")
        .publish_failed(staged.pending)
        .await
        .expect("the staged commit rolls back");
    assert!(
        ingest.auto_commits.is_empty() && ingest.proposals.is_empty(),
        "nothing was buffered behind this commit, so its rollback has nothing \
         further to publish; work here would be a ref nobody resolves"
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

/// The circle's relay set plus one more, which is what makes a relay-list commit
/// a change rather than a no-op.
fn relay_set(world: &World) -> Vec<String> {
    let mut relays = world.relay_urls();
    relays.push("wss://o2-control.example.com".to_string());
    relays
}

// ── O5 ──────────────────────────────────────────────────────────────────────

/// One genuine same-epoch commit race, classified with or without the stored
/// row the ingest wrote.
///
/// Both devices are co-admins on one epoch; each stages, publishes and confirms
/// a relay-list commit with its ENGINE PAUSED, so neither has ingested the
/// other's when the classifier runs. That pause is not decoration: the engine
/// records every message's disposition, and a live engine would have ingested
/// the peer's commit first — the classifier would then be reading the SECOND
/// look, where a lost branch reads as a duplicate.
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
    let (alice, bob) = pair(&world);
    let group = group(&world);

    // Bob must be able to commit at all, so alice hands him the admin bit and
    // his live engine applies it — the last thing either engine does.
    let handoff = world
        .device(alice)
        .expect("alice")
        .manager()
        .expect("a manager")
        .propose_admin_handoff(&group, &world.device(bob).expect("bob").keys.public_key())
        .await
        .expect("an admin handoff stages");
    world
        .publish_and_confirm(alice, handoff.pending, &[handoff.commit_event])
        .await
        .expect("the handoff publishes and confirms");
    assert!(
        wait_until_epochs_agree(&world, &group, bounds::round_trip(Recovery::Undisturbed)).await,
        "both devices must sit on one epoch before a same-epoch race means anything"
    );

    for device in world.devices_mut() {
        device.go_offline().await.expect("the engine pauses");
    }

    let mut commits = Vec::with_capacity(2);
    for (index, tag) in [alice, bob].into_iter().enumerate() {
        let mut relays = world.relay_urls();
        relays.push(format!("wss://race-{index}.example.com"));
        let device = world.device(tag).expect("a device");
        let staged = device
            .manager()
            .expect("a manager")
            .update_circle_relays(&group, &relays)
            .await
            .expect("a relay-list commit stages");
        let outstanding = world.note_pending_staged();
        assert!(
            world
                .publish_witnessed(tag, std::slice::from_ref(&staged.commit_event))
                .await
                .expect("the witness reads")
                .is_some(),
            "Rule 13: a commit is confirmed only on an acknowledgement that reached us"
        );
        let ingest = device
            .manager()
            .expect("a manager")
            .finalize_relay_update(staged.pending, &group)
            .await
            .expect("the commit confirms");
        assert!(
            ingest.auto_commits.is_empty() && ingest.proposals.is_empty(),
            "no window was open behind this commit, so its confirm stages \
             nothing further"
        );
        drop(outstanding);
        commits.push(staged.commit_event);
    }

    // Each device ingests the OTHER's commit, exactly once.
    let mut verdicts = Vec::with_capacity(2);
    for (ingester, source) in [(bob, 0_usize), (alice, 1_usize)] {
        let device = world.device(ingester).expect("a device");
        if name_the_row {
            let session = device.session().expect("a session");
            let ingested = session.process_event_typed_for_test(&commits[source]).await;
            let record = session
                .stored_convergence_input_for_test(&group, OpenMlsContentKind::Commit, 1)
                .await
                .expect("the ingest wrote a commit row");
            let probe = session
                .stored_message_record_for_test(&record.id)
                .await
                .expect("the row the locator just returned reads");
            verdicts.push(undecryptable::classify_ingest(
                &ingested,
                undecryptable::Probe::Read(probe),
            ));
        } else {
            verdicts.push(
                undecryptable::classify(device, &commits[source], StoredRow::Unknown)
                    .await
                    .expect("the classifier reads"),
            );
        }
    }

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
    let mut healthy = round(1);
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

/// The one arm the sweep does not run, and why.
///
/// S17's full intake asserts an ABSENCE over the whole delivery-silence window
/// — three kind-445 retention windows, 684 seconds — and an absence is the one
/// span that may never be scaled or shortened. It runs in the `weekly` profile,
/// which is where a bound that starts at eleven minutes belongs.
const EXCLUDED_FROM_THE_SWEEP: [&str; 1] = ["full-intake"];

/// Every (scenario, arm) the sweep below runs, written out so that an arm added
/// to a scenario without a test here fails rather than widening a loop.
const SWEPT: [(Scenario, &str); 15] = [
    (Scenario::RelayOutage, "single-relay-outage"),
    (Scenario::RelayOutage, "all-relay-outage"),
    (Scenario::RelayOutage, "rolling-outage"),
    (Scenario::StuckRow, "stuck-row-sweep"),
    (Scenario::QuietCircle, "quiet-circle-resume"),
    (Scenario::HydrationQuarantine, "hydration-quarantine"),
    (Scenario::ClosedPrefixes, "closed-prefixes"),
    (Scenario::ClosedPrefixes, "notice"),
    (Scenario::SwallowedOk, "swallowed-ok-create"),
    (Scenario::SwallowedOk, "swallowed-ok-relay-update"),
    (Scenario::SwallowedOk, "swallowed-ok-location-send"),
    (Scenario::DuplicateReorder, "duplicate-replay"),
    (Scenario::DuplicateReorder, "reordered-pages"),
    (Scenario::DuplicateReorder, "cross-sub-eose"),
    (Scenario::DuplicateReorder, "commit-gap"),
];

/// The world one arm is run in: the PR profile's own shape, widened only where
/// an arm cannot run in it at all.
///
/// The PR shape rather than each arm's own profile, because it is the shape the
/// lane actually executes and the cheapest one every arm but two can use. The
/// two exceptions need a second relay plane by definition: an all-relay or
/// rolling outage over one plane is a single-relay outage wearing another arm's
/// label.
fn shape_for(label: &str) -> WorldShape {
    let mut shape = pr_spec().world;
    if matches!(label, "all-relay-outage" | "rolling-outage") {
        shape.relays = shape.relays.max(2);
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
    let arm = arm_of(scenario, label);
    let mut world = build_shaped_world(&shape_for(label)).await;

    let report = scenario
        .run(&mut world, arm, pr_tick())
        .await
        .expect("the scenario runs");

    assert!(
        report.holds(),
        "a registered arm must have a success path in this crate's own tests, \
         or the registry claims coverage no lane executes"
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
            if !SWEPT.contains(&(scenario, arm.label)) {
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
async fn s06_stuck_row_sweep_holds() {
    happy_path(Scenario::StuckRow, "stuck-row-sweep").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s11_quiet_circle_resume_holds() {
    happy_path(Scenario::QuietCircle, "quiet-circle-resume").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s13_hydration_quarantine_holds() {
    happy_path(Scenario::HydrationQuarantine, "hydration-quarantine").await;
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
async fn s18_swallowed_ok_create_holds() {
    happy_path(Scenario::SwallowedOk, "swallowed-ok-create").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s18_swallowed_ok_relay_update_holds() {
    happy_path(Scenario::SwallowedOk, "swallowed-ok-relay-update").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s18_swallowed_ok_location_send_holds() {
    happy_path(Scenario::SwallowedOk, "swallowed-ok-location-send").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s19_duplicate_replay_holds() {
    happy_path(Scenario::DuplicateReorder, "duplicate-replay").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn s19_reordered_pages_holds() {
    happy_path(Scenario::DuplicateReorder, "reordered-pages").await;
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
    // proved nothing. The seven controls below are the other half: a real
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
// A floor re-graded against a bigger number is arithmetic. These seven are the
// other thing: the arm is run for real against a world deliberately arranged so
// the condition it grades cannot arise, and the run must report rc 3 — "this
// proves nothing" — rather than the rc 0 every oracle would otherwise give it.
//
// Two of them come back as a rig error rather than as a report, because the arm
// cannot reach its own grading point at all. That error's own verdict is rc 3
// for the same reason, and the assertion says so.

/// Requires `report`'s expectation floor to be unmet, whatever its oracles
/// answered.
///
/// The floor and the oracles are folded separately on purpose: a control that
/// also breaks a promise is still a control, and demanding a bare rc 3 would
/// mean demanding that a world nobody can grade still satisfies every oracle.
fn floor_is_unusable(report: &haven_soak::scenarios::ScenarioReport) {
    assert!(
        report.floor != Verdict::Holds,
        "a world arranged so the arm's own condition cannot arise must fail its \
         expectation floor, or the floor is not holding the arm to anything"
    );
    assert!(
        report.floor.rc() == Rc::Unusable,
        "and an unmet floor is rc 3: the run proves nothing, which is neither \
         clean nor a finding about the subject"
    );
    assert!(
        report.rc() != Rc::Clean,
        "so the arm as a whole can never fold to clean"
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

/// Takes one plane down and waits for the devices to notice.
async fn down_and_noticed(world: &mut World, plane: usize) {
    world.relays_mut()[plane]
        .apply(Fault::Down)
        .await
        .expect("the plane takes the fault");
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
    for plane in world.relays_mut() {
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
    down_and_noticed(&mut world, 0).await;

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
    down_and_noticed(&mut world, 0).await;

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
    down_and_noticed(&mut world, 0).await;

    let refused = run_arm(Scenario::DuplicateReorder, "duplicate-replay", &mut world)
        .await
        .expect_err("nothing was acked, so nothing can be duplicated");
    assert!(
        refused.rc() == Rc::Unusable,
        "an arm with nothing on the wire to duplicate is rc 3, never clean"
    );

    world.teardown().await.expect("teardown");
}

#[test]
fn every_registered_scenario_has_a_mis_configuration_control() {
    // The seven tests above, by the scenario each one controls. Written out so
    // that a scenario added to the registry without a control fails here rather
    // than inheriting somebody else's.
    const CONTROLLED: [Scenario; 7] = [
        Scenario::RelayOutage,
        Scenario::StuckRow,
        Scenario::QuietCircle,
        Scenario::HydrationQuarantine,
        Scenario::ClosedPrefixes,
        Scenario::SwallowedOk,
        Scenario::DuplicateReorder,
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

/// The rig's ladder resolves what a resolution hands back, rather than leaving
/// a staged commit for nobody.
///
/// haven-core ends both Rule-13 rungs in the engine's replay, so a confirm can
/// hand back the NEXT staged commit. The rig has one ladder for that
/// (`rig::circle::resolve_ingest`), and its whole job is that a ref arriving
/// that way is published and resolved like any other — a commit left staged
/// forks the group, which is the state every oracle in this file assumes away.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_rigs_ladder_resolves_a_commit_a_resolution_handed_back() {
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
        .update_circle_relays(&group, &relays)
        .await
        .expect("a relay-list commit stages");
    assert!(
        world
            .device(admin)
            .expect("the admin")
            .manager()
            .expect("a manager")
            .encrypt_location(
                &group,
                &world.device(admin).expect("the admin").keys.public_key(),
                &ProbeToken::mint(0, 1).as_location(),
                LOCATION_MESSAGE_RETENTION_SECS,
            )
            .await
            .is_err(),
        "precondition: the staged commit really does hold the circle in a \
         publish-before-apply transition"
    );

    // Handed to the ladder the way a resolution's own replay hands one back.
    world
        .resolve_ingest(
            admin,
            DecryptedIngest {
                results: Vec::new(),
                auto_commits: vec![staged],
                proposals: Vec::new(),
            },
        )
        .await
        .expect("the ladder resolves it");

    assert!(
        world
            .device(admin)
            .expect("the admin")
            .manager()
            .expect("a manager")
            .encrypt_location(
                &group,
                &world.device(admin).expect("the admin").keys.public_key(),
                &ProbeToken::mint(0, 2).as_location(),
                LOCATION_MESSAGE_RETENTION_SECS,
            )
            .await
            .is_ok(),
        "the circle sends again, which only a RESOLVED pending state allows — a \
         ladder that dropped it would leave the group staged for ever"
    );

    world.teardown().await.expect("teardown");
}
