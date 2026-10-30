//! **S06** — a stored input the engine can never resolve neither wedges the
//! circle nor outlives the window a relay would redeliver it in.
//!
//! The field incident this scenario exists for: one unresolvable row —
//! application bytes sealed at an epoch this device will never reach — used to
//! gate the circle's outbound path until a sweep retired it. At MDK v0.10.4 an
//! application row gates only while competing commit edges make it a branch
//! witness (`ConvergenceInputContext::gates_outbound`), so the row no longer
//! gates at all, and the circle keeps sending. The sweep's half is unchanged and
//! still graded: the row survives a sweep below the horizon (retiring it sooner
//! would discard a message the group could still converge on) and is retired by
//! one past it.
//!
//! # The row is real, and so is the gate
//!
//! The stuck row is a REAL record another member really stored, copied into this
//! device's store with the id production writes. Nothing is fabricated: a
//! hand-built row would carry an id the engine can never dispose of, and the
//! scenario would then "prove" a wedge the product cannot reach.
//!
//! # Why the horizon is crossed on the POLICY clock
//!
//! The age rule compares the row's own timestamp against the instant the caller
//! passes, and that instant is a POLICY instant — the one clock the rig may step
//! (see [`crate::clock`]). Stepping it is what makes a 288-second horizon
//! reachable inside a run that lasts minutes, and it is stepped between two
//! quiescent phases, with the sweep BELOW the horizon proving the rule declined
//! the row rather than never having looked at it.

use std::time::Duration;

use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{MessageState, OpenMlsContentKind};

use crate::clock::WallNow;
use crate::oracle::bounds;
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{Invariant, Reach, Recovery};
use crate::rig::{DeviceTag, LogDrain, RigError, Step, TimelineSink};
use crate::scenarios::{
    grade_round, hand_off_admin, round, Absence, Arm, ArmOutcome, ScenarioWorld, WithheldAcks,
};

/// The arm this scenario offers.
pub const ARMS: [Arm; 1] = [Arm {
    label: "stuck-row-sweep",
    recovery: Recovery::Undisturbed,
    probe_rounds: 1,
    resubscribes: false,
    absence: Absence::None,
    withheld_acks: WithheldAcks::None,
    floor: ExpectationFloor {
        faults_applied: 0,
        epochs_crossed: 1,
        deliveries_observed: 1,
        canaries_caught: 4,
    },
}];

/// How many gating rows the recovery round tolerates: none. The whole arm is
/// about the row being gone by then.
const NO_GATING_ROWS: usize = 0;

/// Runs the arm.
///
/// # Errors
///
/// [`RigError::ShapeMismatch`] if the world has fewer than two devices or no
/// circle, otherwise [`RigError`] naming the step that failed.
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
    let (sender, stuck) = two_devices(world)?;
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let group = world.circle(circle_tag)?.mls_group_id().clone();

    let row = stage_stuck_row(world, sender, stuck, circle_tag, &group).await?;

    let mut canaries = 0_usize;

    // 1. The row really is stored, with the disposition a crash leaves — and it
    //    does not gate the circle.
    let state = world
        .device(stuck)?
        .session()?
        .stored_message_record_for_test(&row)
        .await
        .map_err(|_| RigError::Core(Step::ReadGatingRows))?
        .map(|probe| probe.state);
    if gating(world, stuck, &group).await? == 0 && state == Some(MessageState::Retryable) {
        canaries += 1;
    }

    // 2. …so the send path stays open.
    let sent = world
        .device(stuck)?
        .manager()?
        .seal_location_for_test(&group, &LocationMessage::new(3.0, 4.0))
        .await;
    if sent.is_ok() {
        canaries += 1;
    }

    // 3. A sweep BELOW the horizon must decline the row. Without this the age
    //    rule could be deleted and the arm would stay green.
    let now = world.device(stuck)?.policy_now(WallNow::now())?;
    let early = world
        .device(stuck)?
        .manager()?
        .sweep_unresolvable_inputs(now.secs())
        .await
        .map_err(|_| RigError::Core(Step::ReadGatingRows))?;
    if early.disposed_messages == 0 && still_pending(world, stuck, &row).await? {
        canaries += 1;
    }

    // 4. …and a sweep past it must retire exactly that row. The step is a
    //    POLICY step, taken between two quiescent phases, and the horizon is
    //    the product's own constant.
    let horizon = i64::try_from(bounds::unresolvable_input_max_age().as_secs())
        .map_err(|_| RigError::Clock(crate::clock::ClockError::BeforeEpoch))?;
    world.device_mut(stuck)?.step_policy_offset(horizon + 1);
    let aged = world.device(stuck)?.policy_now(WallNow::now())?;
    let swept = world
        .device(stuck)?
        .manager()?
        .sweep_unresolvable_inputs(aged.secs())
        .await
        .map_err(|_| RigError::Core(Step::ReadGatingRows))?;
    if swept.disposed_messages > 0 && !still_pending(world, stuck, &row).await? {
        canaries += 1;
    }

    // The world may resume and be graded. The device that held the row SENDS
    // first, and the reverse direction follows, because a branch can decrypt
    // one way and not the other.
    world.device_mut(stuck)?.come_online().await?;
    let pairs = [(stuck, sender), (sender, stuck)];
    let opened = [stuck];
    let recovery = round(
        1,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &opened,
        &[],
    );
    let graded = grade_round(
        world,
        &recovery,
        &[Invariant::Quiescence, Invariant::LocationRoundTrip],
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

/// Puts one unresolvable row into `stuck`'s store and returns its id.
///
/// The row is a REAL record `sender` really stored, at an epoch `stuck` will
/// never reach, copied in with the id production writes. A hand-built row would
/// carry an id the engine can never dispose of, and the arm would then "prove" a
/// wedge the product cannot reach.
async fn stage_stuck_row<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    sender: DeviceTag,
    stuck: DeviceTag,
    circle_tag: crate::rig::CircleTag,
    group: &haven_core::nostr::mls::types::GroupId,
) -> Result<haven_core::nostr::mls::types::MessageId, RigError> {
    // The gated device stops receiving first, so the commit below leaves it a
    // genuine epoch behind rather than one it would immediately catch up on.
    world.device_mut(stuck)?.go_offline().await?;

    // One real commit, resolved under Rule 13: an admin hand-over, so the
    // circle's routing is unchanged and the only effect is the epoch advance
    // this arm needs (a repeat of the relay list the circle holds stages
    // nothing, and a new one moves the circle's REQ inside the resume).
    let circle = world.circle(circle_tag)?;
    let (_, verdict) = hand_off_admin(world, sender, circle, stuck).await?;
    if verdict != crate::rig::PublishVerdict::Confirmed {
        // Nothing was merged, so there is no epoch above the gated device and
        // the whole arm would be vacuous.
        return Err(RigError::WelcomeNeverAcked);
    }

    let ahead = world
        .device(sender)?
        .manager()?
        .group_epoch(group)
        .await
        .map_err(|_| RigError::Core(Step::ReadEpoch))?;

    // Application bytes sealed at the higher epoch: the one shape the engine
    // deliberately never resolves.
    world
        .device(sender)?
        .manager()?
        .seal_location_for_test(group, &LocationMessage::new(1.0, 2.0))
        .await
        .map_err(|_| RigError::Core(Step::Publish))?;
    let source = world
        .device(sender)?
        .session()?
        .stored_convergence_input_for_test(group, OpenMlsContentKind::Application, ahead)
        .await
        .map_err(|_| RigError::Core(Step::ReadGatingRows))?;

    world
        .device(stuck)?
        .session()?
        .stage_convergence_input_for_test(&source, MessageState::Retryable, 0)
        .await
        .map_err(|_| RigError::Core(Step::ReadGatingRows))
}

/// The first two devices: the one that commits and the one that gets stuck.
fn two_devices<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
) -> Result<(DeviceTag, DeviceTag), RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [sender, stuck, ..] = tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    Ok((*sender, *stuck))
}

/// How many rows are gating `group` on `device`.
async fn gating<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &haven_core::nostr::mls::types::GroupId,
) -> Result<usize, RigError> {
    world
        .device(device)?
        .session()?
        .gating_input_count(group)
        .await
        .map_err(|_| RigError::Core(Step::ReadGatingRows))
}

/// Whether `row` still awaits a disposition in `device`'s store.
async fn still_pending<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    row: &haven_core::nostr::mls::types::MessageId,
) -> Result<bool, RigError> {
    Ok(world
        .device(device)?
        .session()?
        .stored_message_record_for_test(row)
        .await
        .map_err(|_| RigError::Core(Step::ReadGatingRows))?
        .is_some_and(|probe| probe.state == MessageState::Retryable))
}

#[cfg(test)]
mod tests {
    use super::ARMS;
    use crate::oracle::Recovery;

    #[test]
    fn the_arm_demands_the_commit_and_all_four_observations() {
        let arm = ARMS[0];
        assert!(
            arm.recovery == Recovery::Undisturbed,
            "nothing is unplugged"
        );
        assert!(
            arm.floor.epochs_crossed >= 1,
            "an arm that crossed no epoch staged no future-epoch row"
        );
        assert!(
            arm.floor.canaries_caught == 4,
            "gating, deferral, the declined sweep and the retiring sweep are the arm"
        );
        assert!(
            arm.floor.faults_applied == 0,
            "no relay fault takes part: the row is the fault"
        );
    }
}
