//! **S23** — a device misses TWO chained commits and still converges.
//!
//! It converges without sending anything. The arm grades C7's fix
//! (`docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md`), which is Haven's mitigation
//! of an MDK gap — row C7 of `docs/MDK_UPSTREAM_TRACKER.md`, whose removal
//! condition is this arm staying green with Haven's drain removed. MDK PR #1206
//! (first in v0.9.11) adds deferral- and hydrate-scheduling, which may cover C7
//! — unverified; no upstream issue describes the epoch-change edge.
//!
//! The user-visible consequence it guards: before the fix, a device that was
//! away long enough for two commits to land stopped receiving its peers' fixes
//! and never resumed. The map's other markers simply stopped moving. Nothing
//! said so — its own publishes kept succeeding, the circle reported a healthy
//! send path and `unrecoverable_circles()` was empty throughout.
//!
//! # The mechanism
//!
//! 1. A relay serves a stored page NEWEST FIRST (`nostr::Event`'s `Ord` is
//!    `created_at` descending, ties by id), so the returning device ingests
//!    the newer commit of the pair before the older.
//! 2. A kind-445 commit's outer layer is keyed at its committer's PRE-commit
//!    epoch, so the newer sibling cannot be peeled by a device that has not
//!    applied the older one.
//! 3. The unpeelable sibling is retained rather than dropped, as a
//!    `PeelDeferred` row.
//! 4. At MDK v0.9.4 (`e391adc`) such rows were retried only from inside an
//!    advance nothing scheduled, so the device stayed one epoch behind until
//!    it next sent something. Haven then drained them with two edges of its
//!    own (an epoch change left its group owing an advance; the first plane
//!    of a session advanced every circle).
//! 5. At v0.10.4 (mdk#1206) a deferral and the hydrate name the group in the
//!    engine's `pending_convergence`, the advance that settles a pass retries
//!    the deferred-peel sweep itself (`cgka-engine/src/message_processor/
//!    mod.rs` 1537-1545), and the peel-context fingerprint moves on every
//!    stored commit (`:62-76`), so the cutoff reads zero. Since R2 the first
//!    plane of a session drains the engine's own pending set
//!    (`SessionManager::take_owed_advance`) in place of advancing every
//!    circle, and this arm is the end-of-migration nightly that decides
//!    whether that stands; the epoch-change edge
//!    (`SessionManager::groups_owing_advance`) is kept (tracker rows C7,
//!    T-SCHEDULER).
//!
//! # What drained it before the fix, and why the closing round is shaped so
//!
//! The stranded device's OWN next seal. `Publishing::seal_location` — the seal alone,
//! nothing published — runs the send path's settle, which reaches the
//! deferred-peel sweep (measured 2026-09-25). A closing round in the standard
//! order, with the resumed device SENDING first, would therefore grade that
//! send-side recovery and call the world converged even with the receive-side
//! drain missing. So the WITNESS leads: the victim's first probe is a receive,
//! O1 grades it before the victim has sent anything, and O2 reads the epochs
//! before it attempts a send. The victim's own seal is RECORDED as the arm's
//! last canary, after the grade, and cannot pre-empt it. Remove Haven's drain
//! and this arm grades rc 1 again, with O2 reporting the divergence and O1 the
//! undelivered probe.
//!
//! # The page order is pinned, so the strand is not a coin toss
//!
//! Two commits sealed inside one wall second carry one `created_at`, and the
//! store then orders them by event id. The id is minted from a per-message
//! ephemeral key, so it differs on every run. That is the "coin toss" the first
//! measurement saw. This arm reads the first commit's stored `created_at` back
//! off the relay and waits, bounded, for the WALL second to turn over before it
//! stages the next. So the pair's timestamps strictly increase, the page is
//! newest-first by construction, and every night the victim is handed the
//! strand's shape. The wait is a bounded condition on the relay's own store,
//! never a sleep and never a policy-clock step (`check_soak_clock_partition.sh`:
//! the page order is a WALL fact).
//!
//! # Graded, not recorded
//!
//! The closing round asks the standard invariants — O6, O1 and O2 — so a
//! regression is GRADED at rc 1, not recorded as a canary. This arm was
//! `EXPECTED_RED` in `tests/oracles.rs` until C7's fix made it grade rc 0. It
//! is now `SWEPT`, and it runs in the nightly again.
//!
//! # `offline` is a paused engine, not an unplugged socket
//!
//! `go_offline` closes every REQ and disconnects nothing, so the recovery is
//! `Undisturbed` and the resume pays the subscribe ladder — S04's shape.

use std::time::Duration;

use haven_core::nostr::mls::types::GroupId;
use nostr::{Event, EventId, Filter};

use crate::clock::WallNow;
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{bounds, Invariant, ProbeToken, Reach, Recovery};
use crate::rig::{CircleTag, DeviceTag, LogDrain, PublishVerdict, RigError, Step, TimelineSink};
use crate::scenarios::{
    await_condition, chain_pairs, closing_pairs, deliveries_for, grade_round, relay_update, round,
    Absence, Arm, ArmOutcome, Scenario, ScenarioReport, ScenarioWorld, WithheldAcks,
    NO_GATING_ROWS,
};
use tokio::time::{Instant, MissedTickBehavior};

/// How many confirmed commits land while the victim is away: the smallest
/// chained backlog, and the one C7's first measurement showed never drained.
const COMMITS_WHILE_AWAY: u64 = 2;

/// How many fixes the admin publishes after the victim resumes. Three, as C7's
/// measurement was made, when none of them reached the stranded device.
const FIXES_AFTER_RESUME: u32 = 3;

/// The round the arm's own fixes are stamped with: neither graded round's
/// ordinal, so a late replay can never satisfy a closing-round probe.
const FIX_ROUND: u32 = 123;

/// How often a bounded wait for a delivery re-reads the ledger. A harness
/// cadence; no expectation is derived from it.
const DELIVERY_POLL: Duration = Duration::from_millis(20);

/// The arm this scenario offers.
pub const ARMS: [Arm; 1] = [Arm {
    label: "chained-commit-backlog",
    recovery: Recovery::Undisturbed,
    probe_rounds: 2,
    resubscribes: true,
    absence: Absence::None,
    withheld_acks: WithheldAcks::None,
    floor: ExpectationFloor {
        faults_applied: 0,
        // A single commit is not a chain: one is redelivered and applied on
        // its own (S04), so a world that crossed fewer proves nothing here.
        epochs_crossed: COMMITS_WHILE_AWAY,
        deliveries_observed: 2,
        canaries_caught: 5,
    },
}];

/// Runs the arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not this scenario's,
/// [`RigError::ShapeMismatch`] if the world has fewer than three devices — the
/// backlog needs a committer, a witness that takes the chain live and the
/// victim that misses it — [`RigError::PublishNeverAcked`] if a commit of the
/// chain was rolled back (Rule 13), otherwise [`RigError`] naming the step
/// that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    if arm.label != ARMS[0].label {
        return Err(RigError::UnknownTarget);
    }
    spanning(world, tick, COMMITS_WHILE_AWAY).await
}

/// The arm over ONE commit while away.
///
/// S04's shape, in which the victim converges on its own, so the chain this
/// scenario grades never forms and the floor's `epochs_crossed` goes unmet. The
/// mis-configuration control in `tests/oracles.rs` runs it and requires rc 3.
///
/// # Errors
///
/// As [`run`].
pub async fn one_commit_control<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
) -> Result<ScenarioReport, RigError> {
    let started = Instant::now();
    let outcome = spanning(world, tick, 1).await?;
    Ok(Scenario::ChainedBacklog.report(world, &ARMS[0], outcome, started))
}

/// The arm's body, over `commits` confirmed commits while the victim is away.
async fn spanning<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
    commits: u64,
) -> Result<ArmOutcome, RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [admin, witness, victim, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let bound = bounds::round_trip(Recovery::Undisturbed);

    // The control round: the world delivers before anybody goes away.
    let pairs = chain_pairs(world);
    let opening = round(
        1,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &[],
        &[],
    );
    let mut graded = grade_round(world, &opening, &[Invariant::LocationRoundTrip]).await?;

    let mut canaries = strand(world, admin, witness, victim, circle_tag, commits).await?;

    // The closing round, graded with the standard invariants: this is where
    // a strand would be GRADED. The WITNESS leads, so the victim's first probe
    // is a receive — a victim send would drain the backlog by itself (see the
    // module docs), and O1 stops at the first probe that never arrives.
    let pairs = closing_pairs(world, witness);
    let opened = [victim];
    let closing = round(
        2,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &opened,
        &[],
    );
    graded.extend(
        grade_round(
            world,
            &closing,
            &[
                Invariant::Quiescence,
                Invariant::LocationRoundTrip,
                Invariant::SendPathLiveness,
            ],
        )
        .await?,
    );

    // 5. The send-side lever, recorded: one seal of the victim's own,
    //    unpublished, and the epochs agree. Read AFTER the grade, so it can
    //    never stand in for the receive-side drain the grade is about.
    seal(world, victim, &group, FIXES_AFTER_RESUME).await?;
    if await_condition(bound, || async {
        Ok(epoch_of(world, victim, &group).await? == epoch_of(world, admin, &group).await?)
    })
    .await?
    {
        canaries += 1;
    }

    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// The chain, the pause across it, the resume and the fixes that follow:
/// canaries 1 to 4, and the state the closing round then grades.
async fn strand<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    witness: DeviceTag,
    victim: DeviceTag,
    circle_tag: CircleTag,
    commits: u64,
) -> Result<usize, RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let bound = bounds::round_trip(Recovery::Undisturbed);
    let mut canaries = 0_usize;
    world.device_mut(victim)?.go_offline().await?;

    // The chain, each link confirmed under Rule 13, taken live by the witness,
    // and sealed in a wall second of its own.
    let mut chain: Vec<Event> = Vec::new();
    let mut turned_over = true;
    for index in 0..commits {
        let commit = confirmed_commit(world, admin, circle_tag, index).await?;
        let tip = epoch_of(world, admin, &group).await?;
        await_condition(bound, || async {
            Ok(epoch_of(world, witness, &group).await? == tip)
        })
        .await?;
        turned_over &= wall_second_turned_over(world, &commit.id).await?;
        chain.push(commit);
    }
    // 1. The page order is pinned: every link is in every store, and each is
    //    stamped strictly later than the one before it, so newest-first is
    //    what the victim will be served.
    if turned_over && stored_strictly_ascending(world, &chain).await? {
        canaries += 1;
    }
    // 2. The victim really missed the whole chain.
    let behind_by = epoch_of(world, admin, &group)
        .await?
        .saturating_sub(epoch_of(world, victim, &group).await?);
    if behind_by == commits {
        canaries += 1;
    }

    world.device_mut(victim)?.come_online().await?;
    // 3. …and the whole chain crossed the victim's own endpoint after the
    //    resume: the backlog was served, so whatever the victim holds
    //    afterwards is the engine's doing and not a partition's.
    let mut served = true;
    for commit in &chain {
        served &= carried_to(
            world,
            victim,
            &commit.id,
            bound + bounds::subscribe_ladder(),
        )
        .await?;
    }
    if served {
        canaries += 1;
    }
    // 4. The fixes that follow are real: every one of them is folded by the
    //    witness, so a victim that folds none is the victim's own story.
    world.drain_buses();
    let mut witnessed = true;
    for index in 0..FIXES_AFTER_RESUME {
        let before = deliveries_for(world.device(witness)?, circle_tag);
        publish_fix(world, admin, circle_tag, index).await?;
        witnessed &= await_delivery(world, witness, circle_tag, before, bound).await?;
    }
    if witnessed {
        canaries += 1;
    }
    Ok(canaries)
}

/// One confirmed relay-list commit from `device`, carrying a relay list the
/// group does not already hold: the product answers a repeat already so,
/// staging nothing and advancing no epoch.
async fn confirmed_commit<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle_tag: CircleTag,
    index: u64,
) -> Result<Event, RigError> {
    let mut relays = world.relay_urls();
    relays.push(format!("wss://s23-{index}.example.com"));
    let circle = world.circle(circle_tag)?;
    let (event, verdict) = relay_update(world, device, circle, &relays).await?;
    if verdict != PublishVerdict::Confirmed {
        // Nothing merged, so the chain has a hole and the victim is behind
        // nothing.
        return Err(RigError::PublishNeverAcked);
    }
    Ok(event)
}

/// Waits, bounded, for the wall second `event_id` was stored in to end, and
/// answers whether it did.
///
/// Read back off the first plane's store rather than off the event in hand:
/// the stamp the page is ordered by is the one the relay holds. A wait that ran
/// out is folded into the page-order canary rather than reported as a failure.
async fn wall_second_turned_over<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    event_id: &EventId,
) -> Result<bool, RigError> {
    let plane = world.relays().first().ok_or(RigError::ShapeMismatch)?;
    let Some(stored_at) = stored_created_at(plane, event_id).await? else {
        return Ok(false);
    };
    await_condition(bounds::wall_second_turnover(), || async {
        Ok(WallNow::now().secs() > stored_at)
    })
    .await
}

/// The `created_at` `plane`'s store holds for `event_id`, if it holds it.
async fn stored_created_at(
    plane: &crate::relay::SimRelay,
    event_id: &EventId,
) -> Result<Option<i64>, RigError> {
    Ok(plane
        .stored_page(Filter::new().id(*event_id))
        .await?
        .first()
        .and_then(|event| i64::try_from(event.created_at.as_secs()).ok()))
}

/// Whether every plane's store holds every link of `chain`, stamped strictly
/// later than the link before it.
async fn stored_strictly_ascending<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    chain: &[Event],
) -> Result<bool, RigError> {
    for plane in world.relays() {
        let mut stamps = Vec::with_capacity(chain.len());
        for commit in chain {
            let Some(stamp) = stored_created_at(plane, &commit.id).await? else {
                return Ok(false);
            };
            stamps.push(stamp);
        }
        if !stamps.windows(2).all(|pair| pair[0] < pair[1]) {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Waits, bounded, for `device`'s own endpoint on every plane to have carried
/// `event_id`.
async fn carried_to<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    event_id: &EventId,
    bound: Duration,
) -> Result<bool, RigError> {
    await_condition(bound, || async {
        Ok(world
            .relays()
            .iter()
            .all(|plane| plane.ledger().delivered_to(device, event_id)))
    })
    .await
}

/// Waits, bounded, for `device`'s folded delivery count for `circle` to rise
/// above `above`, draining the buses on every read.
async fn await_delivery<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: CircleTag,
    above: u64,
    bound: Duration,
) -> Result<bool, RigError> {
    let started = Instant::now();
    let mut ticker = tokio::time::interval(DELIVERY_POLL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        world.drain_buses();
        if deliveries_for(world.device(device)?, circle) > above {
            return Ok(true);
        }
        if started.elapsed() >= bound {
            return Ok(false);
        }
        ticker.tick().await;
    }
}

/// Publishes one fix into `circle` from `sender` and waits for a relay's own
/// ack.
async fn publish_fix<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    sender: DeviceTag,
    circle_tag: CircleTag,
    index: u32,
) -> Result<(), RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let event = seal(world, sender, &group, index).await?;
    if world
        .publish_witnessed(sender, std::slice::from_ref(&event))
        .await?
        .is_none()
    {
        return Err(RigError::PublishNeverAcked);
    }
    Ok(())
}

/// Seals one location at `device`'s current epoch, unpublished.
async fn seal<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
    index: u32,
) -> Result<Event, RigError> {
    let sender = world.device(device)?;
    sender
        .manager()?
        .seal_location_for_test(group, &ProbeToken::mint(FIX_ROUND, index).as_location())
        .await
        .map(|(event, _, _)| event)
        .map_err(|_| RigError::Core(Step::Publish))
}

/// One device's epoch for one circle.
async fn epoch_of<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
) -> Result<u64, RigError> {
    world
        .device(device)?
        .manager()?
        .group_epoch(group)
        .await
        .map_err(|_| RigError::Core(Step::ReadEpoch))
}

#[cfg(test)]
mod tests {
    use super::{ARMS, COMMITS_WHILE_AWAY, FIXES_AFTER_RESUME, FIX_ROUND};
    use crate::oracle::Recovery;

    #[test]
    fn the_arm_pays_for_its_resume_and_demands_a_chain() {
        let arm = ARMS[0];
        assert!(
            arm.recovery == Recovery::Undisturbed,
            "a paused engine closes no socket, so the pool's ladder is not in the path"
        );
        assert!(
            arm.resubscribes,
            "the victim re-opens its own REQs, so the subscribe ladder is"
        );
        assert!(
            arm.floor.faults_applied == 0,
            "nothing is done to a relay: the backlog is the fault"
        );
        assert!(
            arm.floor.epochs_crossed == COMMITS_WHILE_AWAY && COMMITS_WHILE_AWAY >= 2,
            "one commit is redelivered and applied on its own (S04); a chain is two \
             or more, and a world that crossed fewer proves nothing here"
        );
        assert!(
            arm.floor.canaries_caught == 5,
            "the pinned page order, the missed chain, the served backlog, the \
             witnessed fixes, and the epochs agreeing after the victim's own seal"
        );
    }

    #[test]
    fn three_further_fixes_as_the_measurement_was_made() {
        const { assert!(FIXES_AFTER_RESUME >= 3) }
    }

    #[test]
    fn arm_fixes_are_stamped_outside_both_graded_rounds() {
        const { assert!(FIX_ROUND != 1 && FIX_ROUND != 2) }
    }
}
