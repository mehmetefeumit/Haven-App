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
    /// The ordinals of the conditions it checked and did NOT observe, as a
    /// bit set (bit `n - 1` for ordinal `n`); empty when the arm counts
    /// without naming. The one thing a count cannot say about an unmet floor.
    pub canaries_missed: u32,
}

/// An arm's canaries, each checked in turn: how many were caught, and which
/// were not.
///
/// A count alone grades the floor; the ordinals are for the reader of a red
/// run, who otherwise knows only that one of several instantaneous checks
/// missed. Ordinals are the arm's own vocabulary, never a value of the world.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Canaries {
    caught: usize,
    missed: u32,
    checked: u32,
}

impl Canaries {
    /// No canary checked yet.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            caught: 0,
            missed: 0,
            checked: 0,
        }
    }

    /// Records the next canary, in checking order, as caught or missed.
    ///
    /// Only the first 32 can be named; a later miss still counts.
    pub const fn check(&mut self, caught: bool) {
        self.checked = self.checked.saturating_add(1);
        if caught {
            self.caught += 1;
        } else if self.checked <= u32::BITS {
            self.missed |= 1 << (self.checked - 1);
        }
    }

    /// How many were caught.
    #[must_use]
    pub const fn caught(&self) -> usize {
        self.caught
    }
}

impl Default for Canaries {
    fn default() -> Self {
        Self::new()
    }
}

/// A count alone: the ordinals are unknown.
impl From<usize> for Canaries {
    fn from(caught: usize) -> Self {
        Self {
            caught,
            missed: 0,
            checked: 0,
        }
    }
}

/// The ordinals a missed-canary bit set names, ascending.
fn missed_ordinals(missed: u32) -> impl Iterator<Item = u32> {
    (1..=u32::BITS).filter(move |ordinal| missed & (1 << (ordinal - 1)) != 0)
}

/// Renders a missed-canary bit set as `1,3`.
#[must_use]
pub fn render_missed(missed: u32) -> String {
    missed_ordinals(missed)
        .map(|ordinal| ordinal.to_string())
        .collect::<Vec<_>>()
        .join(",")
}

impl Observed {
    /// Reads the three measurable terms out of `world` and takes the one only
    /// the arm can know.
    ///
    /// `faults_applied` is summed from the PLANES of every role, never taken
    /// from the caller:
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
        canaries: impl Into<Canaries>,
    ) -> Result<Self, RigError> {
        let canaries = canaries.into();
        let faults_applied = world.all_planes().map(RelayPlane::faults_applied).sum();
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
            canaries_caught: canaries.caught,
            canaries_missed: canaries.missed,
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
            None,
        )
    }
}

// Bucketed for the same reason as [`ExpectationFloor`]; the missed ordinals
// are the arm's own vocabulary, so they are exact.
impl fmt::Debug for Observed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        render(
            f,
            "Observed",
            self.faults_applied,
            self.epochs_crossed,
            self.deliveries_observed,
            self.canaries_caught,
            Some(self.canaries_missed),
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
    canaries_missed: Option<u32>,
) -> fmt::Result {
    let mut out = f.debug_struct(name);
    out.field("faults_applied", &sim_magnitude(faults_applied))
        .field("epochs_crossed", &epochs_crossed)
        .field(
            "deliveries_observed",
            &sim_magnitude(usize::try_from(deliveries_observed).unwrap_or(usize::MAX)),
        )
        .field("canaries_caught", &sim_magnitude(canaries_caught));
    if let Some(missed) = canaries_missed {
        out.field("canaries_missed", &render_missed(missed));
    }
    out.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rc::Rc;
    use crate::rig::doubles::{test_planes, RecordingTimeline, StubDrain, TestRelay};
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
            canaries_missed: 0,
        }
    }

    #[test]
    fn canaries_count_the_caught_and_name_the_missed_in_checking_order() {
        let mut canaries = Canaries::new();
        canaries.check(true);
        canaries.check(false);
        canaries.check(true);
        canaries.check(false);
        assert_eq!(canaries.caught(), 2);
        assert_eq!(render_missed(canaries.missed), "2,4");
        assert_eq!(
            render_missed(Canaries::from(3).missed),
            "",
            "a count alone names nothing"
        );
        assert_eq!(Canaries::from(3).caught(), 3);
        assert_eq!(render_missed(0), "");
    }

    #[test]
    fn a_miss_past_the_thirty_second_canary_still_counts_against_the_floor() {
        let mut canaries = Canaries::new();
        for _ in 0..u32::BITS {
            canaries.check(true);
        }
        canaries.check(false);
        canaries.check(true);
        assert_eq!(canaries.caught(), 33);
        assert_eq!(render_missed(canaries.missed), "");
    }

    #[test]
    fn observed_debug_redacts_magnitudes_and_names_the_missed_ordinals() {
        let mut shown = observed(7, 2, 9, 1);
        shown.canaries_missed = 0b101;
        let rendered = format!("{shown:?}");
        assert!(rendered.contains("canaries_missed: \"1,3\""), "{rendered}");
        assert!(
            !rendered.contains('7') && !rendered.contains('9'),
            "{rendered}"
        );
    }

    /// The smallest world a measurement can be taken over.
    async fn world() -> SimWorld<TestRelay, RecordingTimeline, StubDrain> {
        let shape = crate::profiles::WorldShape {
            members: 2,
            circles: 1,
            relays: 1,
            account_relays: 1,
            profile_relays: 0,
        };
        SimWorld::build(
            &shape,
            crate::nemesis::types::Schedule::new(Vec::new()),
            test_planes(&shape).await,
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

        // An account plane's fault is a fault the world took: the inbox and
        // key-package planes are faulted by the arms that aim at a Welcome.
        let account = world.account_relays()[0].tag();
        assert_eq!(
            account,
            RelayTag::new(1),
            "the account planes follow the location ones"
        );
        world
            .plane_mut(account)
            .expect("the account plane is the world's")
            .apply(crate::nemesis::types::Fault::SwallowOk)
            .await
            .expect("the fault applies");
        assert!(
            Observed::measure(&world, 0)
                .await
                .expect("the measurement reads")
                .faults_applied
                == 2,
            "every role's planes are counted, not the location ones alone"
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
