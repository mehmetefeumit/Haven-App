//! Expectation floors: what an arm must actually have DONE before its verdicts
//! mean anything.
//!
//! A soak arm that applied no fault, crossed no epoch and delivered nothing will
//! pass every invariant in the registry, because there was nothing for any of
//! them to catch. That is the one failure mode a green run cannot report on its
//! own, so every arm declares a floor and an unmet floor is
//! [`Rc::Unusable`](crate::rc::Rc::Unusable) — rc 3, "the world proves nothing"
//! — never rc 0.
//!
//! # Measured where it can be, declared where it cannot
//!
//! [`Observed::measure`] reads the two terms the world already knows — how far
//! its epochs moved and how much its devices were delivered — out of the world
//! itself, so an arm cannot mis-report them. The other two are things only the
//! arm knows: how many scheduled faults it actually applied, and how many
//! deliberately induced conditions it actually caught. Those are arguments.

use std::fmt;

use crate::oracle::{Finding, Verdict};
use crate::rig::{sim_magnitude, LogDrain, RelayPlane, RigError, SimWorld, TimelineSink};

/// Which floor an arm fell short of.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FloorTerm {
    /// Fewer scheduled faults fired than the arm declared. A fault that never
    /// fired makes every bound derived from it a fiction.
    FaultsApplied,
    /// The world's epochs did not move as far as the arm declared. A membership
    /// or commit arm that crossed no epoch tested no commit path.
    EpochsCrossed,
    /// Fewer deliveries were folded than the arm declared. A round-trip arm
    /// that delivered nothing proves only that nothing crashed.
    DeliveriesObserved,
    /// Fewer deliberately induced conditions were observed than the arm
    /// declared — the induction mechanism no longer reaches the state it names.
    CanariesCaught,
}

/// The minimum an arm must have done for its verdicts to be worth reading.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct ExpectationFloor {
    /// Scheduled faults that must have fired.
    pub faults_applied: usize,
    /// Epochs the world must have advanced past its origin.
    pub epochs_crossed: u64,
    /// Bus events that must have been folded into device ledgers.
    pub deliveries_observed: u64,
    /// Deliberately induced conditions the arm must have observed.
    pub canaries_caught: usize,
}

/// What an arm actually did.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Observed {
    /// Scheduled faults that fired.
    pub faults_applied: usize,
    /// The furthest any device's view of any circle moved from the world's
    /// origin epoch.
    pub epochs_crossed: u64,
    /// Bus events folded into device ledgers.
    pub deliveries_observed: u64,
    /// Deliberately induced conditions the arm observed.
    pub canaries_caught: usize,
}

impl Observed {
    /// Reads the three measurable terms out of `world` and takes the one only
    /// the arm can know.
    ///
    /// `faults_applied` is summed from the PLANES, never taken from the caller:
    /// an arm declares how many faults it means to apply in its own
    /// [`ExpectationFloor`], and counting the same number twice would grade the
    /// arm against itself. The plane records what it really took, so an arm
    /// whose fault silently did not fire can no longer meet the floor it wrote.
    ///
    /// `epochs_crossed` is the furthest delta any device's view of any circle
    /// reached, not a sum: two devices agreeing on one advance is one epoch
    /// crossed, and adding them would let a wider world satisfy a floor it never
    /// reached.
    ///
    /// # Errors
    ///
    /// [`RigError`] naming the read that failed.
    pub async fn measure<R: RelayPlane, T: TimelineSink, L: LogDrain>(
        world: &SimWorld<R, T, L>,
        canaries_caught: usize,
    ) -> Result<Self, RigError> {
        let faults_applied = world.relays().iter().map(RelayPlane::faults_applied).sum();
        let fingerprint = world.fingerprint().await?;
        let epochs_crossed = fingerprint
            .devices
            .iter()
            .flat_map(|device| device.circles.iter())
            .map(|circle| circle.epoch_delta)
            .max()
            .unwrap_or(0);
        let deliveries_observed = world
            .devices()
            .iter()
            .map(|device| device.ledger().total())
            .sum();
        Ok(Self {
            faults_applied,
            epochs_crossed,
            deliveries_observed,
            canaries_caught,
        })
    }
}

/// Grades `observed` against `floor`.
///
/// Reports the FIRST unmet term rather than all of them: an arm that fired no
/// fault has an unmet delivery floor too, and naming both would suggest two
/// defects where there is one.
#[must_use]
pub const fn grade(floor: &ExpectationFloor, observed: &Observed) -> Verdict {
    if observed.faults_applied < floor.faults_applied {
        return Verdict::Failed(Finding::FloorUnmet(FloorTerm::FaultsApplied));
    }
    if observed.epochs_crossed < floor.epochs_crossed {
        return Verdict::Failed(Finding::FloorUnmet(FloorTerm::EpochsCrossed));
    }
    if observed.deliveries_observed < floor.deliveries_observed {
        return Verdict::Failed(Finding::FloorUnmet(FloorTerm::DeliveriesObserved));
    }
    if observed.canaries_caught < floor.canaries_caught {
        return Verdict::Failed(Finding::FloorUnmet(FloorTerm::CanariesCaught));
    }
    Verdict::Holds
}

// Bucketed: three of the four are magnitudes of a world's behaviour. The epoch
// term is exact because it is a delta from the world's own origin, which names
// no epoch.
impl fmt::Debug for ExpectationFloor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        render(
            f,
            "ExpectationFloor",
            self.faults_applied,
            self.epochs_crossed,
            self.deliveries_observed,
            self.canaries_caught,
        )
    }
}

// Bucketed for the same reason as [`ExpectationFloor`].
impl fmt::Debug for Observed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        render(
            f,
            "Observed",
            self.faults_applied,
            self.epochs_crossed,
            self.deliveries_observed,
            self.canaries_caught,
        )
    }
}

/// The one rendering both floor types share.
fn render(
    f: &mut fmt::Formatter<'_>,
    name: &'static str,
    faults_applied: usize,
    epochs_crossed: u64,
    deliveries_observed: u64,
    canaries_caught: usize,
) -> fmt::Result {
    f.debug_struct(name)
        .field("faults_applied", &sim_magnitude(faults_applied))
        .field("epochs_crossed", &epochs_crossed)
        .field(
            "deliveries_observed",
            &sim_magnitude(usize::try_from(deliveries_observed).unwrap_or(usize::MAX)),
        )
        .field("canaries_caught", &sim_magnitude(canaries_caught))
        .finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rc::Rc;
    use crate::rig::doubles::{RecordingTimeline, StubDrain, TestRelay};
    use crate::rig::RelayTag;

    const fn floor(
        faults: usize,
        epochs: u64,
        deliveries: u64,
        canaries: usize,
    ) -> ExpectationFloor {
        ExpectationFloor {
            faults_applied: faults,
            epochs_crossed: epochs,
            deliveries_observed: deliveries,
            canaries_caught: canaries,
        }
    }

    const fn observed(faults: usize, epochs: u64, deliveries: u64, canaries: usize) -> Observed {
        Observed {
            faults_applied: faults,
            epochs_crossed: epochs,
            deliveries_observed: deliveries,
            canaries_caught: canaries,
        }
    }

    /// The smallest world a measurement can be taken over.
    async fn world() -> SimWorld<TestRelay, RecordingTimeline, StubDrain> {
        let relay = TestRelay::start(RelayTag::new(0)).await;
        SimWorld::build(
            &crate::profiles::WorldShape {
                members: 2,
                circles: 1,
                relays: 1,
            },
            crate::nemesis::types::Schedule::new(Vec::new()),
            vec![relay],
            RecordingTimeline::default(),
            StubDrain::default(),
        )
        .await
        .unwrap_or_else(|failure| panic!("world builds: {failure}"))
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn the_faults_a_floor_is_graded_against_are_the_planes_own_count() {
        // The two halves of this term come from different places on purpose: an
        // arm DECLARES its faults in a floor, and the plane RECORDS what it
        // really took. An arm that passed its own number would be grading
        // itself, and a fault that silently did not fire would still satisfy
        // the floor derived from it.
        let mut world = world().await;
        assert!(
            Observed::measure(&world, 0)
                .await
                .expect("the measurement reads")
                .faults_applied
                == 0,
            "a world nothing was done to reports no fault"
        );

        world.relays_mut()[0]
            .apply(crate::nemesis::types::Fault::SwallowOk)
            .await
            .expect("the fault applies");
        world.relays_mut()[0]
            .apply(crate::nemesis::types::Fault::Heal)
            .await
            .expect("the heal applies");

        assert!(
            Observed::measure(&world, 0)
                .await
                .expect("the measurement reads")
                .faults_applied
                == 1,
            "the plane took one fault and one heal, and counts one: a floor that \
             counted the heal too would be met by a world nothing stayed broken in"
        );
        world.teardown().await.expect("teardown");
    }

    #[test]
    fn an_arm_that_did_everything_it_declared_grades_clean() {
        assert_eq!(
            grade(&floor(1, 1, 1, 1), &observed(2, 3, 9, 4)),
            Verdict::Holds,
            "a floor is a minimum, so exceeding it is not a finding"
        );
    }

    #[test]
    fn each_unmet_term_is_named_and_is_unusable_rather_than_a_violation() {
        for (short, term) in [
            (observed(0, 1, 1, 1), FloorTerm::FaultsApplied),
            (observed(1, 0, 1, 1), FloorTerm::EpochsCrossed),
            (observed(1, 1, 0, 1), FloorTerm::DeliveriesObserved),
            (observed(1, 1, 1, 0), FloorTerm::CanariesCaught),
        ] {
            let verdict = grade(&floor(1, 1, 1, 1), &short);
            assert_eq!(verdict, Verdict::Failed(Finding::FloorUnmet(term)));
            assert_eq!(
                verdict.rc(),
                Rc::Unusable,
                "an arm that proved nothing is unusable, never a violation of the subject"
            );
        }
    }

    #[test]
    fn the_first_unmet_term_is_the_one_reported() {
        assert_eq!(
            grade(&floor(1, 1, 1, 1), &observed(0, 0, 0, 0)),
            Verdict::Failed(Finding::FloorUnmet(FloorTerm::FaultsApplied)),
            "an arm that fired no fault has every later floor unmet too, and \
             naming them all would suggest four defects where there is one"
        );
    }

    #[test]
    fn a_floors_debug_buckets_its_magnitudes_and_keeps_its_epoch_delta() {
        let rendered = format!("{:?}", observed(7, 2, 9, 3));
        assert!(rendered.contains("Observed"), "{rendered}");
        assert!(rendered.contains("epoch_delta: 2") || rendered.contains("epochs_crossed: 2"));
        assert!(!rendered.contains(": 7"), "{rendered}");
        assert!(!rendered.contains(": 9"), "{rendered}");
        assert!(rendered.contains("5+"), "{rendered}");
        assert!(rendered.contains("2-4"), "{rendered}");
        assert!(format!("{:?}", floor(1, 1, 1, 1)).contains("ExpectationFloor"));
    }
}
