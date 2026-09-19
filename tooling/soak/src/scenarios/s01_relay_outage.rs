//! **S01** — a relay goes away and comes back.
//!
//! The promise: an outage costs delivery LATENCY and nothing else. When the
//! endpoint returns, every circle still converges and a freshly minted probe
//! still crosses it — within the pool's own reconnect ladder plus the subscribe
//! ladder, never within a number this file chose.
//!
//! # The anti-vacuity control
//!
//! Two things have to be observed, not requested. The outage itself is proven
//! by a bounded poll of the product's own health probe reaching zero connected
//! relays (or, in a multi-relay world, exactly as many as are still up), and the
//! recovery by the same probe coming back — both against a derived bound that is
//! printed beside the measurement. A scenario that merely called `apply(Down)`
//! and then asserted a delivery would pass on a plane that ignored the fault.
//!
//! The control ROUND is the other half: the same probe round runs before the
//! fault, so a world that could not deliver at all cannot be mistaken for one an
//! outage broke.

use std::time::Duration;

use crate::nemesis::types::Fault;
use crate::oracle::bounds;
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{Invariant, Reach, Recovery};
use crate::rig::{LogDrain, RelayPlane, RelayTag, RigError, TimelineSink};

use crate::scenarios::{
    await_connected, chain_pairs, closing_pairs, grade_round, round, Absence, Arm, ArmOutcome,
    ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// The arms this scenario offers.
pub const ARMS: [Arm; 3] = [
    Arm {
        label: "single-relay-outage",
        recovery: Recovery::Reconnect,
        probe_rounds: 2,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 0,
            deliveries_observed: 2,
            canaries_caught: 2,
        },
    },
    Arm {
        label: "all-relay-outage",
        recovery: Recovery::Reconnect,
        probe_rounds: 2,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 2,
            epochs_crossed: 0,
            deliveries_observed: 2,
            canaries_caught: 2,
        },
    },
    Arm {
        label: "rolling-outage",
        recovery: Recovery::Reconnect,
        probe_rounds: 2,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 2,
            epochs_crossed: 0,
            deliveries_observed: 2,
            canaries_caught: 4,
        },
    },
];

/// How the arm takes its planes down.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Outage {
    /// One plane goes away and comes back.
    Single,
    /// Every plane goes away at once and comes back together.
    All,
    /// Each plane in turn goes away and comes back before the next one does.
    Rolling,
}

impl Outage {
    fn of(arm: &Arm) -> Option<Self> {
        match arm.label {
            "single-relay-outage" => Some(Self::Single),
            "all-relay-outage" => Some(Self::All),
            "rolling-outage" => Some(Self::Rolling),
            _ => None,
        }
    }
}

/// Runs one arm.
///
/// # Errors
///
/// [`RigError::ShapeMismatch`] if the arm needs more relay planes than the
/// world has — an all-relay or rolling outage over one plane is a single-relay
/// outage wearing another arm's label, and would report coverage this run does
/// not have. Otherwise [`RigError`] naming the read that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let outage = Outage::of(arm).ok_or(RigError::UnknownTarget)?;
    let planes = world.relays().len();
    if outage != Outage::Single && planes < 2 {
        return Err(RigError::ShapeMismatch);
    }

    // The control round: the same probe over the same pairs BEFORE anything is
    // broken, so a world that never delivered cannot read as a world an outage
    // broke.
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

    let tags: Vec<RelayTag> = world.relays().iter().map(RelayPlane::tag).collect();
    // How many faults this applies is not counted here: the PLANES record what
    // they took, and the floor is graded against that.
    let mut canaries = 0_usize;

    match outage {
        Outage::Single => canaries += break_and_heal(world, &tags[..1], planes).await?,
        Outage::All => canaries += break_and_heal(world, &tags, planes).await?,
        Outage::Rolling => {
            for tag in &tags {
                canaries += break_and_heal(world, std::slice::from_ref(tag), planes).await?;
            }
        }
    }

    // The liveness round, AFTER the heal and against the reconnect bound: a
    // miss during an unhealed fault is not a violation, and this run never
    // asserts one. Both directions: an outage drops every device's socket, and
    // a chain probed one way would leave the return path untested.
    let lead = world
        .devices()
        .first()
        .map(|device| device.tag)
        .ok_or(RigError::ShapeMismatch)?;
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
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// Takes `downed` planes away, proves the product noticed, brings them back,
/// and proves it noticed that too. Returns how many of those two observations
/// held.
async fn break_and_heal<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    downed: &[RelayTag],
    planes: usize,
) -> Result<usize, RigError> {
    for tag in downed {
        apply(world, *tag, Fault::Down).await?;
    }
    let mut caught = 0_usize;
    // The bound is composed, not invented: a dropped socket is noticed inside
    // the engine's own settle window plus the backlog wait a re-opened endpoint
    // spends, which is what `round_trip` of an undisturbed world is made of.
    if await_connected(
        world,
        0,
        planes - downed.len(),
        bounds::round_trip(Recovery::Undisturbed),
    )
    .await?
    {
        caught += 1;
    }

    for tag in downed {
        apply(world, *tag, Fault::Heal).await?;
    }
    if await_connected(
        world,
        planes,
        planes,
        bounds::pool_reconnect() + bounds::subscribe_ladder(),
    )
    .await?
    {
        caught += 1;
    }
    Ok(caught)
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
    use super::{Outage, ARMS};
    use crate::oracle::Recovery;

    #[test]
    fn every_arm_recovers_from_a_reconnect_and_pays_for_its_ladder() {
        for arm in ARMS {
            assert!(
                arm.recovery == Recovery::Reconnect,
                "{} must be graded against the pool's own ladder",
                arm.label
            );
            assert!(
                arm.probe_rounds >= 2,
                "{} must run a control round as well as a recovery round",
                arm.label
            );
        }
    }

    #[test]
    fn each_label_selects_exactly_one_outage_shape() {
        assert!(Outage::of(&ARMS[0]) == Some(Outage::Single));
        assert!(Outage::of(&ARMS[1]) == Some(Outage::All));
        assert!(Outage::of(&ARMS[2]) == Some(Outage::Rolling));
    }

    #[test]
    fn a_rolling_outage_demands_more_observations_than_a_single_one() {
        // Two planes, two observations each: an arm that broke three planes and
        // observed two of them would be reporting one plane it never proved.
        assert!(ARMS[2].floor.canaries_caught > ARMS[0].floor.canaries_caught);
    }
}
