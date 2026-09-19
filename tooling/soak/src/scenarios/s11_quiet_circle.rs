//! **S11** — a circle nobody uses for a long time, and then does.
//!
//! The promise: an idle circle ages out what it is supposed to age out and
//! nothing else. A last-known row is retired once it is past its OWN
//! `purge_after` and not a second before; the circle's epoch does not move on
//! its own; and when somebody finally sends again, the location still crosses.
//!
//! # The expectation comes from the row, never from the offset
//!
//! The rig steps a POLICY clock to reach a horizon a minutes-long run could not
//! otherwise touch, and it would be trivially circular to then assert "the row
//! aged out because I moved the clock past where I think the horizon is". So the
//! horizon is read back from the row the product itself wrote — `purge_after`,
//! derived by `upsert_last_known_location` from its own retention constant — and
//! the two prunes straddle exactly that instant.
//!
//! # Phase 1 does not rotate
//!
//! `repair_epoch_rotation` is deliberately never called here. The control this
//! arm rests on is "the epoch did not move while the circle was quiet", and a
//! repair rotation during the span would move it — which is a scenario of its
//! own (the static-epoch repair arm, Phase 2), not a detail to fold in.

use std::time::Duration;

use haven_core::circle::LastKnownLocation;

use crate::clock::{millis_to_secs, WallNow};
use crate::oracle::quiescence::{settle, Settled};
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{Invariant, Reach, Recovery};
use crate::rig::{DeviceTag, LogDrain, RigError, Step, TimelineSink};
use crate::scenarios::{
    deliveries_for, grade_round, round, Absence, Arm, ArmOutcome, ScenarioWorld, WithheldAcks,
    NO_GATING_ROWS,
};

/// The arm this scenario offers.
pub const ARMS: [Arm; 1] = [Arm {
    label: "quiet-circle-resume",
    recovery: Recovery::Undisturbed,
    probe_rounds: 1,
    resubscribes: false,
    absence: Absence::None,
    withheld_acks: WithheldAcks::None,
    floor: ExpectationFloor {
        faults_applied: 0,
        epochs_crossed: 0,
        deliveries_observed: 1,
        canaries_caught: 4,
    },
}];

/// Runs the arm.
///
/// # Errors
///
/// [`RigError::ShapeMismatch`] if the world has fewer than two devices or no
/// circle; otherwise [`RigError`] naming the read that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    if arm.label != ARMS[0].label {
        // A label this scenario does not offer means the dispatch table and the
        // registry disagree, which is the rig being wrong about itself.
        return Err(RigError::UnknownTarget);
    }
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [sender, quiet, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    let circle = world.circles().first().ok_or(RigError::ShapeMismatch)?;
    let circle_tag = circle.tag;
    let group_id = *circle.nostr_group_id();
    let sender_pubkey = world.device(sender)?.pubkey_hex();

    let mut canaries = 0_usize;
    let wall = WallNow::now();

    // The span is only "quiet" if the world was quiet when it began. A world
    // that has just been built still has its own welcomes crossing the buses,
    // and the silence canary below would be counting those rather than the
    // span's. The arm settles and drains ITSELF rather than trusting a caller's
    // tick loop to have done it: an arm that is only correct inside one run
    // loop is an arm nobody can run on its own.
    let settled = settle(world, Recovery::Undisturbed, tick).await?;
    world.drain_buses();

    let purge_after = write_last_known(world, quiet, &group_id, &sender_pubkey, wall)?;

    // What "quiet" is measured against: the stamps the WRITE side recorded, not
    // the offset the rig is about to apply.
    let before_epoch = epoch(world, quiet, circle_tag).await?;
    let before_stamps = world
        .device(quiet)?
        .manager()?
        .circle_rotation_state(&group_id)
        .map_err(|_| RigError::Core(Step::OpenStore))?;
    // THIS circle's deliveries, not the device's total: the world carries more
    // than one circle, and a sibling's traffic is not this circle's silence.
    let before_deliveries = deliveries_for(world.device(quiet)?, circle_tag);

    canaries += prune_straddles_the_rows_own_horizon(world, quiet, &group_id, purge_after, wall)?;

    // The circle really was idle: the epoch did not move and the write side
    //    recorded no new inbound group event across the span. Read from the
    //    stamps, converted once, and never rendered.
    let after_stamps = world
        .device(quiet)?
        .manager()?
        .circle_rotation_state(&group_id)
        .map_err(|_| RigError::Core(Step::OpenStore))?;
    let idle = epoch(world, quiet, circle_tag).await? == before_epoch
        && stamp_secs(after_stamps.last_inbound_event_at_ms)
            == stamp_secs(before_stamps.last_inbound_event_at_ms)
        && stamp_secs(after_stamps.last_epoch_change_seen_at_ms)
            == stamp_secs(before_stamps.last_epoch_change_seen_at_ms);
    if idle {
        canaries += 1;
    }

    // …and nothing was delivered into this circle while it was quiet. A world
    // that never settled at the start cannot say that, so the precondition is
    // part of the claim rather than something swallowed above.
    world.drain_buses();
    if matches!(settled, Settled::Quiescent(_))
        && deliveries_for(world.device(quiet)?, circle_tag) == before_deliveries
    {
        canaries += 1;
    }

    // The resume: one freshly minted probe has to cross the circle that has
    // been silent all this time — and then one back the other way, because a
    // circle that has only ever been probed in one direction says nothing about
    // the return path.
    let pairs = [(sender, quiet), (quiet, sender)];
    let resumed = round(
        1,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &[],
        &[],
    );
    let graded = grade_round(
        world,
        &resumed,
        &[
            Invariant::Quiescence,
            Invariant::LocationRoundTrip,
            Invariant::SendPathLiveness,
        ],
    )
    .await?;

    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// Writes one last-known row through the product's own upsert and returns the
/// `purge_after` the PRODUCT derived for it.
///
/// Read back rather than assumed: the horizon this arm straddles has to be the
/// one the product wrote, or the two prunes below would be straddling a number
/// this file chose.
fn write_last_known<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group_id: &[u8; 32],
    sender_pubkey: &str,
    wall: WallNow,
) -> Result<i64, RigError> {
    world
        .device(device)?
        .manager()?
        .upsert_last_known_location(&LastKnownLocation {
            nostr_group_id: *group_id,
            sender_pubkey: sender_pubkey.to_owned(),
            latitude: 12.5,
            longitude: -3.25,
            geohash: String::new(),
            display_name: None,
            timestamp: wall.secs(),
            expires_at: wall.secs(),
            // Overwritten by the upsert from the retention constant; the value
            // this arm straddles is read back below, never assumed here.
            purge_after: wall.secs(),
            updated_at: wall.secs(),
        })
        .map_err(|_| RigError::Core(Step::OpenStore))?;

    world
        .device(device)?
        .manager()?
        .snapshot_last_known_for_circle(group_id, wall.secs())
        .map_err(|_| RigError::Core(Step::OpenStore))?
        .first()
        .map(|row| row.purge_after)
        .ok_or(RigError::Core(Step::OpenStore))
}

/// Prunes on both sides of the row's own horizon and returns how many of the two
/// expectations held.
///
/// The policy clock is stepped between the two, which is what makes a horizon a
/// minutes-long run could not otherwise touch reachable at all.
fn prune_straddles_the_rows_own_horizon<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    device: DeviceTag,
    group_id: &[u8; 32],
    purge_after: i64,
    wall: WallNow,
) -> Result<usize, RigError> {
    let mut caught = 0_usize;

    // A prune BELOW the row's own horizon retires nothing. Without this the
    // retention comparison could be deleted and the arm would stay green.
    let early = world
        .device(device)?
        .policy_now(WallNow::from_secs(purge_after - 1))?;
    let pruned_early = world
        .device(device)?
        .manager()?
        .prune_expired_last_known(
            i64::try_from(early.secs()).map_err(|_| RigError::Core(Step::OpenStore))?,
        )
        .map_err(|_| RigError::Core(Step::OpenStore))?;
    let still_there = world
        .device(device)?
        .manager()?
        .snapshot_last_known_for_circle(group_id, purge_after - 1)
        .map_err(|_| RigError::Core(Step::OpenStore))?
        .len();
    if pruned_early == 0 && still_there == 1 {
        caught += 1;
    }

    // The policy step, taken between two quiescent phases and sized from the
    // row's own horizon.
    let span = purge_after
        .checked_sub(wall.secs())
        .and_then(|delta| delta.checked_add(1))
        .ok_or(RigError::Clock(crate::clock::ClockError::BeforeEpoch))?;
    world.device_mut(device)?.step_policy_offset(span);
    let aged = world.device(device)?.policy_now(wall)?;

    // …and a prune past it retires exactly that row.
    let pruned_late = world
        .device(device)?
        .manager()?
        .prune_expired_last_known(
            i64::try_from(aged.secs()).map_err(|_| RigError::Core(Step::OpenStore))?,
        )
        .map_err(|_| RigError::Core(Step::OpenStore))?;
    let left = world
        .device(device)?
        .manager()?
        .snapshot_last_known_for_circle(group_id, purge_after + 1)
        .map_err(|_| RigError::Core(Step::OpenStore))?
        .len();
    if pruned_late >= 1 && left == 0 {
        caught += 1;
    }
    Ok(caught)
}

/// One device's epoch for one circle.
async fn epoch<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: crate::rig::CircleTag,
) -> Result<u64, RigError> {
    let group = world.circle(circle)?.mls_group_id().clone();
    world
        .device(device)?
        .manager()?
        .group_epoch(&group)
        .await
        .map_err(|_| RigError::Core(Step::ReadEpoch))
}

/// A rotation stamp in seconds. The stamps are milliseconds and every gate
/// takes seconds; the conversion lives in one place so two call sites cannot
/// drift by a second.
const fn stamp_secs(stamp: Option<i64>) -> Option<i64> {
    match stamp {
        Some(ms) => Some(millis_to_secs(ms)),
        None => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{stamp_secs, ARMS};
    use crate::oracle::Recovery;

    #[test]
    fn the_arm_grades_the_quiet_span_and_the_resume() {
        let arm = ARMS[0];
        assert!(arm.recovery == Recovery::Undisturbed);
        assert!(
            arm.probe_rounds == 1,
            "the span itself is read, not probed; the resume is the probe"
        );
        assert!(
            arm.floor.canaries_caught == 4,
            "the declined prune, the retiring prune, the idle read and the silence"
        );
    }

    #[test]
    fn a_stamp_is_converted_once_and_truncates_toward_the_past() {
        assert!(stamp_secs(Some(1_999)) == Some(1));
        assert!(stamp_secs(None).is_none());
    }
}
