//! **S10** — the whole roster: ten circles on one account, and one outage
//! across all of them.
//!
//! The promise: an account at its roster bound behaves like an account with
//! one circle, only ten times over — every circle delivers, every circle's
//! REQ survives a reconnect, and an outage manufactures no commit activity in
//! any of them. Ten is not a sample: `kMaxCirclesPerAccount = 10`
//! (`haven/lib/src/services/publish_stagger.dart`, restated on
//! `haven-core/src/location/ttl.rs`'s TTL derivation) is the roster the app
//! admits and refuses the eleventh, so this is the largest world the product
//! can have.
//!
//! # THE BOUND RULE, which carries the claim (decision 0.24)
//!
//! The world-level deadline is the PER-CIRCLE bound — not ten times it. The
//! planes are concurrent, and a linear bound would hide a serialization bug
//! behind slack. If the measured run cannot meet the per-circle bound at ten
//! circles, that is the finding S10 exists for, and the bound is never widened
//! to fit it.
//!
//! # The circles are built here, and the engines are told
//!
//! The profile's world holds a few circles; the arm grows it to ten through
//! the same create-and-join path every other circle took and ADOPTS each one
//! into the world's table, so every world-wide oracle grades all ten. Adopting
//! re-specs no running engine, so each device's engine is subscribed to the
//! new circle the way the app subscribes a circle it just created or joined —
//! a REQ of its own on every plane. That is what canary 4 then holds a
//! reconnect to: at ten circles a pool that silently stopped registering a
//! bucket is exactly the "revisit at scale" DM-5a asked for.
//!
//! # What this arm records and does not decide
//!
//! OD-11: the ten routing ids are pairwise distinct at the start and every
//! device's own circle table still answers for all ten at the end, so no
//! routing id rotated across the run. Evidence for the owner's decision, not
//! the posture — `nostr_group_id` never rotates, and this arm has no removal
//! to observe one across. DM-5a: commit activity is read per device before
//! and after the outage and compared in process; an outage that manufactured
//! commit activity in any circle would be a finding here.
//!
//! # Rule 15
//!
//! Ten circles is ten `simcircle#` handles — the alias table's high-cardinality
//! case. Nothing here prints a count: every magnitude is compared in process,
//! and the floor's ten is a rig count of rig circles.

use std::time::Duration;

use haven_core::relay::live_sync::CircleSpec;

use crate::nemesis::types::Fault;
use crate::oracle::bounds;
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{Invariant, Reach, Recovery};
use crate::rig::{DeviceTag, LogDrain, RelayPlane, RelayTag, RigError, Step, TimelineSink};
use crate::scenarios::{
    await_condition, await_connected, chain_pairs, closing_pairs, deliveries_for, grade_round,
    round, Absence, Arm, ArmOutcome, ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// The whole roster: `kMaxCirclesPerAccount` (10), the bound the app refuses
/// an eleventh circle at, in `haven/lib/src/services/publish_stagger.dart`.
///
/// A literal with its citation, for the reason `bounds::pool_reconnect` is:
/// the constant is Dart's and no expression in this crate can name it.
/// `haven-core/src/location/ttl.rs` restates the same ten on its TTL
/// derivation, which is the second place a change would have to be made.
const ROSTER_CIRCLES: usize = 10;

/// The arm this scenario offers.
pub const ARMS: [Arm; 1] = [Arm {
    label: "ten-circle-roster",
    recovery: Recovery::Reconnect,
    probe_rounds: 2,
    resubscribes: false,
    absence: Absence::None,
    withheld_acks: WithheldAcks::None,
    floor: ExpectationFloor {
        // One outage on one plane. The heal is not a fault the plane counts.
        faults_applied: 1,
        epochs_crossed: 0,
        deliveries_observed: ROSTER_CIRCLES as u64,
        canaries_caught: 4,
    },
}];

/// Runs the arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not this scenario's,
/// [`RigError::ShapeMismatch`] if the world already holds MORE than the roster
/// (ten is the product's bound, and a world above it is not one the app can
/// have) or has no device, otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    if arm.label != ARMS[0].label {
        return Err(RigError::UnknownTarget);
    }
    if world.circles().len() > ROSTER_CIRCLES {
        return Err(RigError::ShapeMismatch);
    }
    let lead = world
        .devices()
        .first()
        .map(|device| device.tag)
        .ok_or(RigError::ShapeMismatch)?;
    let planes = world.relays().len();
    let plane = world
        .relays()
        .first()
        .map(RelayPlane::tag)
        .ok_or(RigError::ShapeMismatch)?;

    let built = grow_to_the_roster(world).await?;
    let routing_ids: Vec<[u8; 32]> = world
        .circles()
        .iter()
        .map(|circle| *circle.nostr_group_id())
        .collect();

    // The control round: every circle delivers before anything is broken.
    let pairs = chain_pairs(world);
    let control = round(
        1,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &[],
        &[],
    );
    let mut graded = grade_round(world, &control, &[Invariant::LocationRoundTrip]).await?;

    let mut canaries = break_and_heal(world, plane, planes, built).await?;

    // The closing round, both directions, after the heal and against the
    // reconnect bound.
    let closing = closing_pairs(world, lead);
    let recovered = round(
        2,
        Reach::These(&closing),
        Recovery::Reconnect,
        tick,
        NO_GATING_ROWS,
        &[],
        &[],
    );
    graded.extend(
        grade_round(
            world,
            &recovered,
            &[
                Invariant::Quiescence,
                Invariant::LocationRoundTrip,
                Invariant::SendPathLiveness,
            ],
        )
        .await?,
    );

    world.drain_buses();
    // 1. The roster is whole and this arm grew it: ten circles, at least one
    //    built here, pairwise distinct routing ids that every device's own
    //    table still answers for (OD-11), and every one of the ten delivered
    //    to every device — the starvation detector.
    if built >= 1
        && world.circles().len() == ROSTER_CIRCLES
        && pairwise_distinct(&routing_ids)
        && every_device_still_holds(world, &routing_ids).await?
        && every_circle_delivered_everywhere(world)
    {
        canaries += 1;
    }
    // 2. …and nothing gates any circle's send path on any device.
    if nothing_gated(world).await? {
        canaries += 1;
    }

    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// Takes `plane` away and brings it back, answering canaries 3 and 4: the
/// outage manufactured no commit activity, and every REQ — the `built`
/// adopted circles' own among them — is live again on every device.
async fn break_and_heal<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    plane: RelayTag,
    planes: usize,
    built: usize,
) -> Result<usize, RigError> {
    let mut canaries = 0_usize;
    let activity_before = commit_activity(world)?;
    apply(world, plane, Fault::Down).await?;
    let outage_seen = await_connected(
        world,
        0,
        planes - 1,
        bounds::round_trip(Recovery::Undisturbed),
    )
    .await?;
    apply(world, plane, Fault::Heal).await?;
    let heal_seen = await_connected(
        world,
        planes,
        planes,
        bounds::pool_reconnect() + bounds::subscribe_ladder(),
    )
    .await?;
    // 3. The outage was real, the heal was real, and neither manufactured a
    //    commit-shaped observation in any circle on any device (DM-5a).
    if outage_seen && heal_seen && commit_activity(world)? == activity_before {
        canaries += 1;
    }
    // 4. After the reconnect every device's pool still holds every REQ its
    //    session expects — and the adopted circles are among them, each a REQ
    //    of its own on every plane. Registration replays on reconnect, so the
    //    bound is the pool's own ladder.
    if await_condition(
        bounds::pool_reconnect() + bounds::subscribe_ladder(),
        || async { every_bucket_live(world, built * planes).await },
    )
    .await?
    {
        canaries += 1;
    }
    Ok(canaries)
}

/// Builds and adopts circles until the world holds the whole roster, telling
/// every engine about each one. Returns how many were built.
async fn grow_to_the_roster<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
) -> Result<usize, RigError> {
    let mut built = 0_usize;
    while world.circles().len() < ROSTER_CIRCLES {
        let circle = world.build_extra_circle().await?;
        let specs: Vec<(DeviceTag, CircleSpec)> = world
            .devices()
            .iter()
            .map(|device| (device.tag, circle.spec_for(device.tag, world.relays())))
            .collect();
        for (device, spec) in specs {
            world.device_mut(device)?.subscribe_circle(spec).await?;
        }
        world.adopt_circle(circle);
        built += 1;
    }
    Ok(built)
}

/// Every device's commit-activity counter, in device order.
fn commit_activity<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
) -> Result<Vec<u64>, RigError> {
    world
        .devices()
        .iter()
        .map(|device| Ok(device.engine()?.processor().commit_activity_count()))
        .collect()
}

/// Whether every device's pool holds every REQ its session expects, and
/// expects at least `adopted_reqs` of them for the circles this arm added.
async fn every_bucket_live<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    adopted_reqs: usize,
) -> Result<bool, RigError> {
    for device in world.devices() {
        let health = device.engine()?.relay_health().await;
        if health.subscriptions_expected < adopted_reqs
            || health.subscriptions_live != health.subscriptions_expected
        {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Whether no two routing ids coincide.
fn pairwise_distinct(ids: &[[u8; 32]]) -> bool {
    ids.iter()
        .enumerate()
        .all(|(index, id)| !ids[..index].contains(id))
}

/// Whether every device's own circle table still answers for every routing
/// id the arm started with.
async fn every_device_still_holds<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    routing_ids: &[[u8; 32]],
) -> Result<bool, RigError> {
    for device in world.devices() {
        let held: Vec<[u8; 32]> = device
            .manager()?
            .get_circles()
            .await
            .map_err(|_| RigError::Core(Step::ReadRoster))?
            .into_iter()
            .map(|entry| entry.circle.nostr_group_id)
            .collect();
        if !routing_ids.iter().all(|id| held.contains(id)) {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Whether every circle delivered at least one location to every device.
fn every_circle_delivered_everywhere<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
) -> bool {
    world.circles().iter().all(|circle| {
        world
            .devices()
            .iter()
            .all(|device| deliveries_for(device, circle.tag) >= 1)
    })
}

/// Whether no device carries a gating row for any circle.
async fn nothing_gated<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
) -> Result<bool, RigError> {
    for device in world.devices() {
        for circle in world.circles() {
            let rows = device
                .session()?
                .gating_input_count(circle.mls_group_id())
                .await
                .map_err(|_| RigError::Core(Step::ReadGatingRows))?;
            if rows != NO_GATING_ROWS {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

/// Applies one fault to one plane.
async fn apply<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tag: RelayTag,
    fault: Fault,
) -> Result<(), RigError> {
    world
        .relays_mut()
        .iter_mut()
        .find(|plane| plane.tag() == tag)
        .ok_or(RigError::UnknownTarget)?
        .apply(fault)
        .await
}

#[cfg(test)]
mod tests {
    use super::{pairwise_distinct, ARMS, ROSTER_CIRCLES};
    use crate::oracle::Recovery;

    #[test]
    fn the_arm_is_graded_at_the_pools_ladder_and_demands_the_whole_roster() {
        let arm = ARMS[0];
        assert!(
            arm.recovery == Recovery::Reconnect,
            "an outage drops every socket, so the pool's own ladder is in the path"
        );
        assert!(
            !arm.resubscribes,
            "nothing restarts: the pool replays its registrations on reconnect"
        );
        assert!(
            arm.probe_rounds == 2,
            "a control round before the outage and a closing round after the heal"
        );
        assert!(
            arm.floor.faults_applied == 1,
            "one outage on one plane; the heal is not a fault the plane counts"
        );
        assert!(
            arm.floor.deliveries_observed == ROSTER_CIRCLES as u64,
            "the floor's ten is the whole roster"
        );
        assert!(
            arm.floor.canaries_caught == 4,
            "the whole roster delivered, nothing gated, no manufactured commit \
             activity, and every REQ live after the reconnect"
        );
    }

    #[test]
    fn the_roster_is_the_apps_own_bound() {
        // `kMaxCirclesPerAccount = 10` in `publish_stagger.dart`: the constant
        // is Dart's, so this is the one place the rig spells it.
        const { assert!(ROSTER_CIRCLES == 10) }
    }

    #[test]
    fn two_equal_routing_ids_are_not_distinct() {
        assert!(pairwise_distinct(&[[1; 32], [2; 32], [3; 32]]));
        assert!(!pairwise_distinct(&[[1; 32], [2; 32], [1; 32]]));
        assert!(pairwise_distinct(&[]));
    }
}
