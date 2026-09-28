//! **S23** — a device misses TWO chained commits and never converges again.
//! **EXPECTED RED at rc 1** until the product fix lands: C7 in
//! `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md`.
//!
//! The user-visible consequence: a device that was away long enough for two
//! commits to land stops receiving its peers' fixes and never resumes. The
//! map's other markers simply stop moving. Nothing says so — its own publishes
//! keep succeeding, the circle reports a healthy send path and
//! `unrecoverable_circles()` is empty throughout. **Sharing stops.**
//!
//! # The mechanism, at the pinned MDK rev (`e391adc`)
//!
//! 1. A relay serves a stored page NEWEST FIRST (`nostr::Event`'s `Ord` is
//!    `created_at` descending, ties by id), so the returning device ingests
//!    the newer commit of the pair before the older.
//! 2. A kind-445 commit's outer layer is keyed at its committer's PRE-commit
//!    epoch — the wrap "reads exporter from the still-current (pre-stage)
//!    epoch" (`cgka-engine/src/message_processor/send.rs:151-155`) — so the
//!    newer sibling cannot be peeled by a device that has not applied the
//!    older one.
//! 3. The unpeelable sibling is retained rather than dropped: `PeelFailed`
//!    persists the raw transport as a `PeelDeferred` row
//!    (`cgka-engine/src/message_processor/ingest.rs:313-327`).
//! 4. Those rows are retried only by `retry_deferred_peels`
//!    (`cgka-engine/src/message_processor/mod.rs:475`), reached only from
//!    `advance_convergence_inputs_until_settled` (`mod.rs:340`, the call at
//!    `:359`), which Haven drives through `advance_convergence` over an
//!    ingest's `pending_convergence` alone
//!    (`haven-core/src/relay/live_sync/processor.rs:819`,
//!    `haven-core/src/relay/catchup.rs:1002`). A `PeelDeferred` row is not a
//!    convergence input, so nothing schedules the sweep.
//! 5. So the sweep needs a PEELABLE inbound event, and a device one epoch
//!    behind its peers never receives one: every later fix is sealed above it.
//!
//! # What DOES drain it, measured here (2026-09-25), and what that means
//!
//! The stranded device's OWN next seal. `encrypt_location` — the seal alone,
//! nothing published — runs the send path's settle, which reaches the
//! deferred-peel sweep the receive path never does: the retained commit peels,
//! applies, and the device converges. Three fixes from a peer do not move it;
//! one seal of its own does. So the blackout C7 records is bounded by the
//! victim's own publish cadence while it is sharing, and unbounded only for a
//! device that receives without sending — sharing off, or its publisher
//! wedged (the very shapes `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md` is
//! about). That is still a defect: a receive plane that depends on the local
//! send plane to recover is not a receive plane, and C7's "permanent" reads as
//! "until this device next publishes".
//!
//! It also decides the closing round's shape. The standard closing round has
//! the resumed device SEND first, which here is the lever that drains the
//! backlog — a closing round in that order grades the send-side recovery and
//! calls the world converged. So the WITNESS leads: the victim's first probe
//! is a receive, O1 reports it undelivered before the victim has sent
//! anything, O2 reads the epochs before it attempts a send, and the send-side
//! recovery is then RECORDED as the arm's last canary rather than allowed to
//! pre-empt the grade.
//!
//! # The page order is pinned, so the strand is not a coin toss
//!
//! Two commits sealed inside one wall second carry one `created_at`, and the
//! store then orders them by event id — minted from a per-message ephemeral
//! key, so different every run. That is the "coin toss" the first measurement
//! saw. This arm reads the first commit's stored `created_at` back off the
//! relay and waits, bounded, for the WALL second to turn over before it stages
//! the next, so the pair's timestamps are strictly increasing and the page is
//! newest-first by construction: the victim is always stranded, and the
//! verdict is the same every night. The wait is a bounded condition on the
//! relay's own store, never a sleep and never a policy-clock step
//! (`check_soak_clock_partition.sh`: the page order is a WALL fact).
//!
//! # Graded, not recorded
//!
//! The closing round asks the standard invariants — O6, O1 and O2 — so the
//! strand is GRADED: O2 reports the epoch divergence and O1 the probe that
//! never reaches the victim, both at rc 1. That is deliberate and it is the
//! difference from S03 and S14's recorded expectations: their subjects are
//! decided and not built (OD-1); this one is neither decided nor intended, so
//! the honest grade is a finding. `tests/oracles.rs` names this arm in
//! `EXPECTED_RED` and requires rc 1 with those two findings; the day it grades
//! rc 0, C7 is fixed and the arm is promoted to `SWEPT` in the same change.
//!
//! The product fix — a sweep of deferred peels on resume or on a timer,
//! independent of whether a peelable event arrived — is NOT designed here. It
//! is a product change with its own plan. S04 works around this defect by
//! spanning exactly one commit (`COMMITS_WHILE_AWAY` there); this arm is the
//! scenario that grades it.
//!
//! # `offline` is a paused engine, not an unplugged socket
//!
//! `go_offline` closes every REQ and disconnects nothing, so the recovery is
//! `Undisturbed` and the resume pays the subscribe ladder — S04's shape.

use std::time::Duration;

use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
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
/// chained backlog, and the one the first measurement showed never drains.
const COMMITS_WHILE_AWAY: u64 = 2;

/// How many fixes the admin publishes after the victim resumes. Three, as the
/// measurement was made: none of them reaches the stranded device.
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
    // the strand is GRADED. The WITNESS leads, so the victim's first probe is
    // a receive — a victim send would drain the backlog first (see the module
    // docs), and O1 stops at the first probe that never arrives.
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

    // 5. The lever that drains it, recorded: one seal of the victim's own,
    //    unpublished, and the epochs agree. Read AFTER the grade, so the
    //    recovery is evidence beside the finding rather than a substitute for
    //    it — and still true the day the sweep runs on resume, so the floor
    //    stays met when the arm turns green.
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
/// group does not already hold — a repeat is a no-op and advances no epoch.
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
        .encrypt_location(
            group,
            &sender.keys.public_key(),
            &ProbeToken::mint(FIX_ROUND, index).as_location(),
            LOCATION_MESSAGE_RETENTION_SECS,
        )
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
             witnessed fixes, and the victim's own seal converging it"
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
