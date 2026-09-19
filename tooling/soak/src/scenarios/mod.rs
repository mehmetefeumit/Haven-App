//! The seven scenarios Phase 1 runs.
//!
//! A scenario is a script with a grade attached: it puts the world into a
//! specific, deliberately broken state, watches the product come out of it, and
//! answers with the oracles' verdicts plus its own expectation floor. The floor
//! is what makes the verdicts worth reading — an arm that applied no fault and
//! delivered nothing passes every oracle in the registry, because there was
//! nothing for any of them to catch.
//!
//! # An enum, not a registry of trait objects
//!
//! The set is closed and the compiler checks it. A scenario that is not in
//! [`Scenario::REGISTRY`] cannot be listed, run or budgeted, and one that is
//! cannot be listed without an implementation — which is what `--list-scenarios`
//! reads, rather than the profile TOMLs it is supposed to be checked against.
//!
//! # Who applies which fault
//!
//! The nemesis schedule is the run's BACKGROUND: the world applies it, tick by
//! tick, whatever a scenario is doing. An arm that needs one exact fault on one
//! exact plane at one exact moment applies it itself, because an expectation
//! floor may never depend on a random draw having chosen the right relay. Both
//! go through the same `RelayPlane::apply`, so there is one mechanism and two
//! callers.
//!
//! # Every deadline is derived, never typed
//!
//! [`Arm::deadline`] is a composition of `oracle::bounds` terms — the recovery
//! the arm's world is coming out of, the re-subscribe ladder when a device
//! restarts, and one round-trip budget per probe round. `tests/budget.rs` sums
//! them per profile against that profile's own run budget, so a scenario that
//! grows past the PR lane cannot be added without the sum saying so.

pub mod s01_relay_outage;
pub mod s06_stuck_row;
pub mod s11_quiet_circle;
pub mod s13_quarantine;
pub mod s17_closed_prefixes;
pub mod s18_swallowed_ok;
pub mod s19_duplicate_reorder;

use std::fmt;
use std::time::Duration;

use nostr::Event;

use crate::oracle::bounds;
use crate::oracle::undecryptable;
use crate::oracle::vacuity::{grade, ExpectationFloor, Observed};
use crate::oracle::{Invariant, Reach, Recovery, Round, Verdict};
use crate::profiles::WorldShape;
use crate::rc::Rc;
use crate::relay::SimRelay;
use crate::rig::circle::WITNESS_BOUND;
use crate::rig::{
    poll_until, sim_magnitude, CircleTag, DeviceTag, LogDrain, PublishVerdict, RelayPlane,
    RigError, SimCircle, SimDevice, SimWorld, Step, TimelineSink,
};

/// The world every scenario runs against.
///
/// Concrete in its relay plane, generic in its timeline and its log drain. A
/// scenario needs a relay it can BREAK and then read the frames back off — the
/// `CLOSED` text a prefix arm compares byte for byte, the client-facing
/// acknowledgement Rule 13 turns on, the second `EVENT` frame a duplicate arm
/// counts — and none of that is expressible through a trait whose whole purpose
/// is to let the rig compile without a relay. The other two planes stay generic
/// because a scenario neither reads nor breaks them.
pub type ScenarioWorld<T, L> = SimWorld<SimRelay, T, L>;

/// The smallest world any scenario can be run in: two devices, one circle, one
/// relay.
///
/// A circle of one cannot be built, and a peer is what every liveness oracle
/// needs — so this is the floor rather than a choice.
pub const MINIMAL_SHAPE: WorldShape = WorldShape {
    members: 2,
    circles: 1,
    relays: 1,
};

/// How often a scenario re-reads a condition it is waiting for.
///
/// A harness poll interval and nothing else: no expectation is derived from it,
/// and shortening it only makes a satisfied wait return sooner.
const CONDITION_POLL: Duration = Duration::from_millis(20);

/// The most gating rows O1 tolerates per device per circle in an arm that has
/// not deliberately staged one.
const NO_GATING_ROWS: usize = 0;

/// One arm of one scenario.
///
/// The label is the contract with `profiles/*.toml`: a profile declares arms by
/// name, and `tests/budget.rs` fails on a label no scenario offers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Arm {
    /// The arm's label, as the profile TOMLs spell it.
    pub label: &'static str,
    /// The most disruptive thing this arm's world recovers from. Every bound
    /// the oracles use during the arm is derived from it.
    pub recovery: Recovery,
    /// How many O1 probe rounds the arm runs.
    pub probe_rounds: u32,
    /// Whether a device re-opens its own subscriptions during the arm (a
    /// restart), which puts the subscribe ladder in the path on top of the
    /// recovery.
    pub resubscribes: bool,
    /// An absence window the arm asserts over, on top of everything else.
    ///
    /// Carried separately because an absence window is the one span that may
    /// never be scaled: `HAVEN_TEST_WAIT_SCALE` stretches a delivery budget,
    /// and stretching "nothing happened for N seconds" would weaken the claim
    /// rather than the schedule.
    pub absence: Absence,
    /// Acknowledgements the arm deliberately never receives.
    ///
    /// An arm that withholds an ack pays the product's WHOLE publish ladder for
    /// every event it publishes into the silence, and then the rig's own witness
    /// bound once per publish call. That is not an oracle bound and it is not
    /// slack: it is the cost of the fault the arm exists to apply, and an arm
    /// that did not price it would time out on the very behaviour it tests.
    pub withheld_acks: WithheldAcks,
    /// What the arm must have done for its verdicts to mean anything.
    pub floor: ExpectationFloor,
}

impl Arm {
    /// The arm's derived deadline at `tick`, in a world of this `shape`.
    ///
    /// Composed from named terms and nothing else: the quiescence bound for the
    /// recovery this arm's world comes out of, the subscribe ladder when a
    /// device re-opens its REQs, one round-trip budget per probe round, any
    /// absence window the arm waits out, and the publish ladder every
    /// deliberately unacknowledged publish burns.
    ///
    /// The shape is an argument because one of those terms is a property of the
    /// WORLD rather than of the arm: a create publishes one welcome per invited
    /// member, so a swallowed-ack create costs strictly more in a wider world.
    #[must_use]
    pub fn deadline(&self, tick: Duration, shape: &WorldShape) -> Duration {
        bounds::quiescence(self.recovery, tick)
            + if self.resubscribes {
                bounds::subscribe_ladder()
            } else {
                Duration::ZERO
            }
            + bounds::round_trip(Recovery::Undisturbed) * self.probe_rounds
            + self.absence.window()
            + self.withheld_acks.cost(shape)
    }
}

/// How many acknowledgements an arm deliberately never receives.
///
/// Named rather than counted here, because for one of them the count is the
/// world's: a create publishes one welcome per member the admin invites.
///
/// The variants also say WHICH ladder the publish takes, because the product
/// has two: a commit, a welcome or a key package is published with retries
/// (Security Rule 13), while a location takes one bounded attempt and is
/// superseded by the next tick rather than re-sent. Pricing a withheld location
/// at the commit ladder would make an arm wait three attempts the product does
/// not make.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WithheldAcks {
    /// Every publish this arm makes is acknowledged.
    None,
    /// This many COMMIT-ladder publishes go unacknowledged, whatever the
    /// world's size.
    Fixed(u32),
    /// One per invited member: a create publishes a welcome for each of them,
    /// each on the commit ladder.
    PerInvitedMember,
    /// This many LOCATION publishes go unacknowledged: one bounded attempt
    /// each, with no retry behind it.
    Locations(u32),
}

impl WithheldAcks {
    /// How many publishes go unacknowledged in a world of this `shape`.
    #[must_use]
    pub fn count(self, shape: &WorldShape) -> u32 {
        match self {
            Self::None => 0,
            Self::Fixed(count) | Self::Locations(count) => count,
            // The admin welcomes everybody but itself; a circle of one cannot
            // be built, so this is never zero in a world the rig can construct.
            Self::PerInvitedMember => u32::try_from(shape.members)
                .unwrap_or(u32::MAX)
                .saturating_sub(1),
        }
    }

    /// What those unacknowledged publishes cost.
    ///
    /// Each event burns the product's own publish ladder FOR ITS KIND, and the
    /// rig's witness poll is then paid once for the call that published them —
    /// which is exactly what the measurement says: a three-member create
    /// withholds two welcomes and takes two commit ladders plus one witness
    /// bound, while a withheld location takes one bounded attempt and the same
    /// witness bound.
    #[must_use]
    pub fn cost(self, shape: &WorldShape) -> Duration {
        let count = self.count(shape);
        if count == 0 {
            return Duration::ZERO;
        }
        let ladder = match self {
            Self::Locations(_) => bounds::location_publish_window(),
            Self::None | Self::Fixed(_) | Self::PerInvitedMember => {
                bounds::withheld_publish_ladder()
            }
        };
        ladder * count + WITNESS_BOUND
    }
}

/// The absence an arm asserts over, named rather than measured.
///
/// A named term because `Arm`s are `const` and two of the product's own windows
/// are computed rather than constant — and because an absence that could be
/// spelled as a number here is an absence somebody can quietly shorten.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Absence {
    /// The arm asserts no absence.
    None,
    /// Haven's per-endpoint backoff floor: the earliest a THROTTLED `CLOSED`
    /// may be re-issued after.
    ThrottledBackoffFloor,
    /// The delivery-silence window: how long a group REQ may deliver neither an
    /// event nor an `EOSE` before it counts as silent.
    DeliverySilenceWindow,
}

impl Absence {
    /// The window this absence spans.
    #[must_use]
    pub fn window(self) -> Duration {
        match self {
            Self::None => Duration::ZERO,
            Self::ThrottledBackoffFloor => bounds::throttled_backoff_floor(),
            Self::DeliverySilenceWindow => bounds::silence_window(),
        }
    }
}

/// One scenario.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Scenario {
    /// **S01** — a relay goes away and comes back.
    RelayOutage,
    /// **S06** — a stored convergence input gates a circle until the sweep
    /// retires it.
    StuckRow,
    /// **S11** — a circle stays quiet across a long policy span and resumes.
    QuietCircle,
    /// **S13** — a device loses one group's `OpenMLS` state and reopens.
    HydrationQuarantine,
    /// **S17** — a relay refuses subscriptions, machine-readably.
    ClosedPrefixes,
    /// **S18** — a relay stores an event and the acknowledgement never reaches
    /// the publisher.
    SwallowedOk,
    /// **S19** — duplicated, reordered and cross-addressed delivery.
    DuplicateReorder,
}

impl Scenario {
    /// Every scenario Phase 1 runs.
    pub const REGISTRY: [Self; 7] = [
        Self::RelayOutage,
        Self::StuckRow,
        Self::QuietCircle,
        Self::HydrationQuarantine,
        Self::ClosedPrefixes,
        Self::SwallowedOk,
        Self::DuplicateReorder,
    ];

    /// The id the profiles, the timeline and `--list-scenarios` spell.
    #[must_use]
    pub const fn id(self) -> &'static str {
        match self {
            Self::RelayOutage => "S01",
            Self::StuckRow => "S06",
            Self::QuietCircle => "S11",
            Self::HydrationQuarantine => "S13",
            Self::ClosedPrefixes => "S17",
            Self::SwallowedOk => "S18",
            Self::DuplicateReorder => "S19",
        }
    }

    /// What the scenario breaks, in words.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::RelayOutage => "RELAY OUTAGE",
            Self::StuckRow => "STUCK CONVERGENCE ROW",
            Self::QuietCircle => "QUIET CIRCLE RESUME",
            Self::HydrationQuarantine => "HYDRATION QUARANTINE",
            Self::ClosedPrefixes => "CLOSED PREFIXES AND NOTICE",
            Self::SwallowedOk => "SWALLOWED ACKNOWLEDGEMENT",
            Self::DuplicateReorder => "DUPLICATE AND REORDERED DELIVERY",
        }
    }

    /// Every arm this scenario offers.
    #[must_use]
    pub const fn arms(self) -> &'static [Arm] {
        match self {
            Self::RelayOutage => &s01_relay_outage::ARMS,
            Self::StuckRow => &s06_stuck_row::ARMS,
            Self::QuietCircle => &s11_quiet_circle::ARMS,
            Self::HydrationQuarantine => &s13_quarantine::ARMS,
            Self::ClosedPrefixes => &s17_closed_prefixes::ARMS,
            Self::SwallowedOk => &s18_swallowed_ok::ARMS,
            Self::DuplicateReorder => &s19_duplicate_reorder::ARMS,
        }
    }

    /// The arm `label` names, if this scenario offers it.
    #[must_use]
    pub fn arm(self, label: &str) -> Option<&'static Arm> {
        self.arms().iter().find(|arm| arm.label == label)
    }

    /// The expectation floor of the arm `label` names.
    ///
    /// The floor lives on the arm, because two arms of one scenario demand
    /// different things of a world; this is the spelling a caller that holds
    /// only a label uses.
    #[must_use]
    pub fn floor(self, label: &str) -> Option<ExpectationFloor> {
        self.arm(label).map(|arm| arm.floor)
    }

    /// The scenario whose id is `id`.
    #[must_use]
    pub fn with_id(id: &str) -> Option<Self> {
        Self::REGISTRY.into_iter().find(|s| s.id() == id)
    }

    /// Runs one arm against `world`, at the profile's own tick period.
    ///
    /// `tick` is the settle loop's re-read period and the term the quiescence
    /// bound pays for its stability window. It is an argument rather than a
    /// constant here because it belongs to the PROFILE (`tick_ms`), and a
    /// scenario that carried its own copy would derive bounds at a period the
    /// run was not executing at.
    ///
    /// # Errors
    ///
    /// [`RigError`] when the RIG could not do its job — a read that failed, a
    /// world of the wrong shape, a leaked handle. A failure of the SUBJECT is a
    /// [`Verdict`] inside the report, never an error here.
    pub async fn run<T: TimelineSink, L: LogDrain>(
        self,
        world: &mut ScenarioWorld<T, L>,
        arm: &Arm,
        tick: Duration,
    ) -> Result<ScenarioReport, RigError> {
        let started = tokio::time::Instant::now();
        let outcome = match self {
            Self::RelayOutage => s01_relay_outage::run(world, arm, tick).await?,
            Self::StuckRow => s06_stuck_row::run(world, arm, tick).await?,
            Self::QuietCircle => s11_quiet_circle::run(world, arm, tick).await?,
            Self::HydrationQuarantine => s13_quarantine::run(world, arm, tick).await?,
            Self::ClosedPrefixes => s17_closed_prefixes::run(world, arm, tick).await?,
            Self::SwallowedOk => s18_swallowed_ok::run(world, arm, tick).await?,
            Self::DuplicateReorder => s19_duplicate_reorder::run(world, arm, tick).await?,
        };
        Ok(ScenarioReport {
            scenario: self,
            arm: arm.label,
            graded: outcome.graded,
            floor: grade(&arm.floor, &outcome.observed),
            observed: outcome.observed,
            elapsed: started.elapsed(),
            deadline: arm.deadline(outcome.tick, &shape_of(world)),
        })
    }
}

impl fmt::Display for Scenario {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} {}", self.id(), self.title())
    }
}

/// Every scenario, for `--list-scenarios` and for the budget test.
///
/// The registry, not the profile TOMLs: a list read from the files it is meant
/// to be checked against cannot catch a scenario that was declared and never
/// implemented.
#[must_use]
pub const fn registry() -> &'static [Scenario] {
    &Scenario::REGISTRY
}

/// What an arm's body produced, before it is graded.
pub(crate) struct ArmOutcome {
    /// The oracles the arm graded, in the order it graded them.
    pub(crate) graded: Vec<(Invariant, Verdict)>,
    /// What the arm actually did.
    pub(crate) observed: Observed,
    /// The world's tick, carried out so the deadline is derived at the same
    /// period the arm ran at.
    pub(crate) tick: Duration,
}

/// One scenario arm's whole answer.
#[derive(Clone, PartialEq, Eq)]
pub struct ScenarioReport {
    /// Which scenario.
    pub scenario: Scenario,
    /// Which arm.
    pub arm: &'static str,
    /// What each oracle the arm graded answered.
    pub graded: Vec<(Invariant, Verdict)>,
    /// Whether the arm did enough for those answers to mean anything.
    pub floor: Verdict,
    /// What it actually did.
    pub observed: Observed,
    /// How long it took. A measurement.
    pub elapsed: Duration,
    /// The bound it was entitled to take. A duration derived from the product's
    /// own constants, printed beside the measurement so a red run reads
    /// "expected within X, observed Y".
    pub deadline: Duration,
}

impl ScenarioReport {
    /// The verdict this arm folds into: the worst of its floor and its oracles.
    #[must_use]
    pub fn rc(&self) -> Rc {
        let mut rc = self.floor.rc();
        for (_, verdict) in &self.graded {
            rc = rc.folded(verdict.rc());
        }
        rc
    }

    /// Whether every oracle held and the floor was met.
    #[must_use]
    pub fn holds(&self) -> bool {
        self.rc() == Rc::Clean
    }

    /// Whether the arm finished inside its derived bound.
    #[must_use]
    pub const fn within_deadline(&self) -> bool {
        self.elapsed.as_secs() <= self.deadline.as_secs()
    }
}

// Handles, classifications, buckets and durations. The two spans are exact
// because they are durations, which is what a measurement is.
impl fmt::Debug for ScenarioReport {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ScenarioReport")
            .field("scenario", &self.scenario.id())
            .field("arm", &self.arm)
            .field("graded", &sim_magnitude(self.graded.len()))
            .field("floor", &self.floor)
            .field("observed", &self.observed)
            .field("elapsed_secs", &self.elapsed.as_secs())
            .field("deadline_secs", &self.deadline.as_secs())
            .finish()
    }
}

impl fmt::Display for ScenarioReport {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} arm={} rc={} elapsed={}s bound={}s",
            self.scenario,
            self.arm,
            self.rc().name(),
            self.elapsed.as_secs(),
            self.deadline.as_secs()
        )
    }
}

// ---------------------------------------------------------------------------
// Shared arm machinery
// ---------------------------------------------------------------------------

/// The shape of the world an arm is actually running in.
///
/// Read from the world rather than from the profile: two scenarios build a
/// further circle inside their own bodies, and a deadline derived from the
/// profile alone would be pricing a world the run no longer has.
pub(crate) fn shape_of<T: TimelineSink, L: LogDrain>(world: &ScenarioWorld<T, L>) -> WorldShape {
    WorldShape {
        members: world.devices().len(),
        circles: world.circles().len(),
        relays: world.relays().len(),
    }
}

/// The ordered pairs an intermediate round probes: a chain over the world's
/// devices, which spans every device without paying for every pair.
pub(crate) fn chain_pairs<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
) -> Vec<(DeviceTag, DeviceTag)> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    tags.windows(2).map(|pair| (pair[0], pair[1])).collect()
}

/// The ordered pairs a scenario's CLOSING round probes: every chain pair in
/// both directions, with `lead` sending before it receives.
///
/// Both directions because O1's promise is per ORDERED pair: two devices can
/// sit on branches that decrypt one way and not the other, and a round that
/// only ever probed `a -> b` would call that world converged.
///
/// `lead` first because the device a scenario just restarted, reopened or
/// resumed is the one whose epoch and exporter state was rebuilt from disk. A
/// reuse there is invisible to the device itself and shows up only as a PEER
/// failing to decrypt what it produced, so the closing round makes it send
/// before anything sends to it.
pub(crate) fn closing_pairs<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    lead: DeviceTag,
) -> Vec<(DeviceTag, DeviceTag)> {
    closing_over(&chain_pairs(world), lead)
}

/// The ordering rule behind [`closing_pairs`], over the chain alone so a test
/// can pin it without a world.
fn closing_over(chain: &[(DeviceTag, DeviceTag)], lead: DeviceTag) -> Vec<(DeviceTag, DeviceTag)> {
    let mut pairs = Vec::with_capacity(chain.len() * 2);
    for &(from, to) in chain {
        if to == lead {
            pairs.push((to, from));
            pairs.push((from, to));
        } else {
            pairs.push((from, to));
            pairs.push((to, from));
        }
    }
    pairs
}

/// Builds one round's declaration.
pub(crate) const fn round<'a>(
    ordinal: u32,
    reach: Reach<'a>,
    recovery: Recovery,
    tick: Duration,
    row_envelope: usize,
    burst_opened: &'a [DeviceTag],
    classified: &'a [undecryptable::Verdict],
) -> Round<'a> {
    Round {
        ordinal,
        reach,
        recovery,
        tick,
        row_envelope,
        burst_opened,
        classified,
    }
}

/// Grades `invariants` over one round and collects what each answered.
///
/// Every invariant is asked even after one fails: a run that stopped at the
/// first red would report one finding where there are three, and the snapshot a
/// reader gets is the whole point of the run.
pub(crate) async fn grade_round<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    round: &Round<'_>,
    invariants: &[Invariant],
) -> Result<Vec<(Invariant, Verdict)>, RigError> {
    let mut graded = Vec::with_capacity(invariants.len());
    for invariant in invariants {
        graded.push((*invariant, invariant.check(world, round).await?));
    }
    Ok(graded)
}

/// Waits, bounded, for every online device to see `connected` relays or more.
///
/// The observation an outage arm needs: a fault that was REQUESTED proves
/// nothing, and the product's own health probe is what says it landed.
///
/// A world with nobody online answers `false` rather than vacuously true: the
/// predicate over an empty set holds for any bound, so an outage nobody was
/// running to notice would otherwise read as an outage that was observed.
pub(crate) async fn await_connected<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &SimWorld<R, T, L>,
    at_least: usize,
    at_most: usize,
    bound: Duration,
) -> Result<bool, RigError> {
    let tags: Vec<DeviceTag> = world
        .devices()
        .iter()
        .filter(|device| !device.offline)
        .map(|device| device.tag)
        .collect();
    if tags.is_empty() {
        return Ok(false);
    }
    let held = poll_until(bound, CONDITION_POLL, || async {
        for tag in &tags {
            let health = world.device(*tag)?.engine()?.relay_health().await;
            if health.connected < at_least || health.connected > at_most {
                return Ok(false);
            }
        }
        Ok(true)
    })
    .await?;
    Ok(held.is_some())
}

/// Waits, bounded, for `condition` to hold, and answers whether it did.
pub(crate) async fn await_condition<F, Fut>(bound: Duration, condition: F) -> Result<bool, RigError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<bool, RigError>>,
{
    Ok(poll_until(bound, CONDITION_POLL, condition)
        .await?
        .is_some())
}

/// Waits out `window` and answers whether `condition` stayed false for all of
/// it.
///
/// The absence half of an expectation, and the reason it is written as a
/// bounded wait for the NEGATION rather than as a sleep: a run that satisfies
/// the condition early stops immediately and reports the violation, while one
/// that does not pays exactly the declared window. `HAVEN_TEST_WAIT_SCALE`
/// never reaches here — stretching "nothing happened for N seconds" would
/// weaken the claim rather than the schedule.
pub(crate) async fn stayed_absent<F, Fut>(window: Duration, condition: F) -> Result<bool, RigError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<bool, RigError>>,
{
    Ok(poll_until(window, CONDITION_POLL, condition)
        .await?
        .is_none())
}

/// Stages a relay-list commit on `device` and resolves it under Rule 13.
///
/// Returns the commit event and how it was resolved. The confirm happens ONLY
/// on a ledger-witnessed acknowledgement; without one the staged state is
/// rolled back, because a commit that was merged without being published forks
/// the group for every member that never sees it.
pub(crate) async fn relay_update<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: &SimCircle,
    relays: &[String],
) -> Result<(Event, PublishVerdict), RigError> {
    let guard = world.note_pending_staged();
    let sender = world.device(device)?;
    let manager = sender.manager()?;
    let staged = manager
        .update_circle_relays(circle.mls_group_id(), relays)
        .await
        .map_err(|_| RigError::Core(Step::CreateCircle))?;
    let event = staged.commit_event.clone();
    let witnessed = world
        .publish_witnessed(device, std::slice::from_ref(&event))
        .await?;
    let verdict = if witnessed.is_some() {
        manager
            .finalize_relay_update(staged.pending, circle.mls_group_id())
            .await
            .map_err(|_| RigError::Core(Step::ConfirmPublished))?;
        PublishVerdict::Confirmed
    } else {
        manager
            .publish_failed(staged.pending)
            .await
            .map_err(|_| RigError::Core(Step::RollBackPublish))?;
        PublishVerdict::RolledBack
    };
    drop(guard);
    Ok((event, verdict))
}

/// How many location deliveries `device` has folded for `circle`.
pub(crate) fn deliveries_for(device: &SimDevice, circle: CircleTag) -> u64 {
    device.ledger().deliveries_for(circle)
}

#[cfg(test)]
mod tests {
    use super::{
        registry, Absence, Arm, Scenario, WithheldAcks, MINIMAL_SHAPE, NO_GATING_ROWS,
        WITNESS_BOUND,
    };
    use crate::oracle::bounds;
    use crate::oracle::Recovery;
    use crate::profiles::WorldShape;
    use crate::profiles::{ProfileName, ProfileSpec};
    use crate::rig::{DeviceTag, SimWorld};
    use std::time::Duration;

    #[test]
    fn every_registered_scenario_has_a_distinct_id_and_at_least_one_arm() {
        let mut ids: Vec<&str> = registry().iter().map(|s| s.id()).collect();
        let before = ids.len();
        ids.sort_unstable();
        ids.dedup();
        assert!(ids.len() == before, "two scenarios share an id");
        for scenario in registry() {
            assert!(
                !scenario.arms().is_empty(),
                "{} offers no arm at all",
                scenario.id()
            );
        }
    }

    #[test]
    fn every_arm_label_is_unique_within_its_scenario() {
        for scenario in registry() {
            let mut labels: Vec<&str> = scenario.arms().iter().map(|arm| arm.label).collect();
            let before = labels.len();
            labels.sort_unstable();
            labels.dedup();
            assert!(
                labels.len() == before,
                "{} offers one label twice",
                scenario.id()
            );
        }
    }

    #[test]
    fn every_arm_demands_something_of_its_world() {
        // The whole point of a floor: an arm whose four terms are all zero would
        // pass every oracle on a world where nothing happened.
        for scenario in registry() {
            for arm in scenario.arms() {
                let floor = arm.floor;
                assert!(
                    floor.faults_applied > 0
                        || floor.epochs_crossed > 0
                        || floor.deliveries_observed > 0
                        || floor.canaries_caught > 0,
                    "{}/{} declares a floor that demands nothing",
                    scenario.id(),
                    arm.label
                );
            }
        }
    }

    #[test]
    fn every_arm_either_probes_or_catches_a_canary() {
        // An arm that neither round-trips a probe nor catches an induced
        // condition has no positive evidence at all.
        for scenario in registry() {
            for arm in scenario.arms() {
                assert!(
                    arm.probe_rounds > 0 || arm.floor.canaries_caught > 0,
                    "{}/{} would grade nothing",
                    scenario.id(),
                    arm.label
                );
            }
        }
    }

    /// A minimal arm, for the composition tests below.
    const fn bare(label: &'static str) -> Arm {
        Arm {
            label,
            recovery: Recovery::Undisturbed,
            probe_rounds: 1,
            resubscribes: false,
            absence: Absence::None,
            withheld_acks: WithheldAcks::None,
            floor: crate::oracle::vacuity::ExpectationFloor {
                faults_applied: 0,
                epochs_crossed: 0,
                deliveries_observed: 1,
                canaries_caught: 0,
            },
        }
    }

    #[test]
    fn a_deadline_is_derived_from_the_bounds_and_grows_with_the_recovery() {
        let tick = Duration::from_millis(250);
        let shape = MINIMAL_SHAPE;
        let quiet = bare("quiet");
        let mut reconnecting = quiet;
        reconnecting.recovery = Recovery::Reconnect;
        assert!(
            reconnecting.deadline(tick, &shape) > quiet.deadline(tick, &shape),
            "a reconnecting arm must be allowed the pool's own ladder"
        );
        assert!(
            quiet.deadline(tick, &shape)
                == bounds::quiescence(Recovery::Undisturbed, tick)
                    + bounds::round_trip(Recovery::Undisturbed),
            "a deadline is a composition of named bounds and nothing else"
        );

        let mut restarting = quiet;
        restarting.resubscribes = true;
        assert!(
            restarting
                .deadline(tick, &shape)
                .checked_sub(quiet.deadline(tick, &shape))
                == Some(bounds::subscribe_ladder()),
            "a restart pays exactly the subscribe ladder"
        );
    }

    #[test]
    fn an_arm_that_withholds_an_ack_pays_the_publish_ladder_for_every_one() {
        // The measurement this term exists for: a swallowed-ack create in a
        // three-member world publishes two welcomes into the silence, and every
        // one of them burns the product's whole commit ladder before the rig's
        // witness poll is paid once on top.
        let tick = Duration::from_millis(250);
        let quiet = bare("quiet");
        let mut create = quiet;
        create.withheld_acks = WithheldAcks::PerInvitedMember;

        let wide = WorldShape {
            members: 3,
            circles: 2,
            relays: 1,
        };
        assert!(
            create
                .deadline(tick, &wide)
                .checked_sub(quiet.deadline(tick, &wide))
                == Some(bounds::withheld_publish_ladder() * 2 + WITNESS_BOUND),
            "the term is one ladder per invited member plus one witness bound"
        );
        assert!(
            create.deadline(tick, &wide) > create.deadline(tick, &MINIMAL_SHAPE),
            "a wider world welcomes more members, so it costs strictly more"
        );

        let mut one = quiet;
        one.withheld_acks = WithheldAcks::Fixed(1);
        assert!(
            one.deadline(tick, &wide)
                == quiet.deadline(tick, &wide) + bounds::withheld_publish_ladder() + WITNESS_BOUND,
            "a single withheld publish pays one ladder and one witness bound"
        );
        assert!(
            quiet.withheld_acks.cost(&wide) == Duration::ZERO,
            "an arm that withholds nothing pays nothing"
        );

        // A location is not a commit: one bounded attempt, no retry behind it,
        // so an arm that withholds one pays strictly less than an arm that
        // withholds a commit. Pricing them the same would make the location arm
        // wait three attempts the product never makes.
        let mut located = quiet;
        located.withheld_acks = WithheldAcks::Locations(1);
        assert!(
            located.deadline(tick, &wide)
                == quiet.deadline(tick, &wide) + bounds::location_publish_window() + WITNESS_BOUND,
            "a withheld location pays one bounded attempt and one witness bound"
        );
        assert!(
            located.deadline(tick, &wide) < one.deadline(tick, &wide),
            "and strictly less than the same arm withholding a commit"
        );
    }

    #[test]
    fn an_absence_window_is_added_to_the_deadline_rather_than_hidden_in_it() {
        let tick = Duration::from_millis(250);
        let arm = Scenario::ClosedPrefixes
            .arm("closed-prefixes")
            .expect("the closed-prefix arm");
        assert!(
            arm.absence.window() >= bounds::throttled_backoff_floor(),
            "an arm asserting a throttle absence must wait the product's own floor"
        );
        assert!(
            arm.deadline(tick, &MINIMAL_SHAPE) > arm.absence.window(),
            "the deadline must pay for the absence it asserts"
        );
    }

    #[test]
    fn every_arm_named_by_a_profile_is_an_arm_a_scenario_offers() {
        for name in ProfileName::ALL {
            let spec = ProfileSpec::embedded(name).expect("embedded profile");
            for selection in &spec.scenarios {
                let scenario = Scenario::with_id(&selection.id)
                    .unwrap_or_else(|| panic!("{} names an unregistered scenario", name.as_str()));
                for label in &selection.arms {
                    assert!(
                        scenario.arm(label).is_some(),
                        "{} names an arm {} does not offer",
                        name.as_str(),
                        scenario.id()
                    );
                }
            }
        }
    }

    #[test]
    fn the_closing_round_leads_with_the_named_device_and_probes_every_pair_both_ways() {
        let (a, b, c) = (DeviceTag::new(0), DeviceTag::new(1), DeviceTag::new(2));
        let chain = [(a, b), (b, c)];
        let pairs = super::closing_over(&chain, b);
        assert_eq!(pairs.len(), chain.len() * 2);
        for &(from, to) in &chain {
            assert!(pairs.contains(&(from, to)) && pairs.contains(&(to, from)));
        }
        let first_send = pairs.iter().position(|&(from, _)| from == b);
        let first_receive = pairs.iter().position(|&(_, to)| to == b);
        assert!(
            first_send < first_receive,
            "the lead sends before anything sends to it"
        );
        // The rule holds whichever end of its pair the lead sits on.
        for lead in [a, c] {
            let pairs = super::closing_over(&chain, lead);
            let send = pairs.iter().position(|&(from, _)| from == lead);
            let receive = pairs.iter().position(|&(_, to)| to == lead);
            assert!(send < receive);
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn an_outage_nobody_was_online_to_observe_is_not_observed() {
        use crate::nemesis::types::Schedule;
        use crate::rig::doubles::{RecordingTimeline, StubDrain, TestRelay};
        use crate::rig::RelayTag;

        let relay = TestRelay::start(RelayTag::new(0)).await;
        let mut world = SimWorld::build(
            &MINIMAL_SHAPE,
            Schedule::new(Vec::new()),
            vec![relay],
            RecordingTimeline::default(),
            StubDrain::default(),
        )
        .await
        .unwrap_or_else(|failure| panic!("world builds: {failure}"));
        let bound = bounds::settle();
        assert!(
            super::await_connected(&world, 1, usize::MAX, bound)
                .await
                .expect("health reads"),
            "the control: a built world is connected"
        );
        for device in world.devices_mut() {
            device.go_offline().await.expect("pause");
        }
        assert!(
            !super::await_connected(&world, 0, usize::MAX, bound)
                .await
                .expect("health reads"),
            "a predicate over nobody must not read as an outage that was observed"
        );
        world.teardown().await.expect("teardown");
    }

    #[test]
    fn a_floor_is_reachable_from_a_label_alone() {
        for scenario in registry() {
            for arm in scenario.arms() {
                assert!(
                    scenario.floor(arm.label) == Some(arm.floor),
                    "a floor read by label is the arm's own"
                );
            }
            assert!(scenario.floor("no-such-arm").is_none());
        }
    }

    #[test]
    fn a_scenario_renders_its_id_and_title_and_no_value() {
        let rendered = Scenario::RelayOutage.to_string();
        assert!(rendered.contains("S01"), "{rendered}");
        assert!(rendered.contains("RELAY OUTAGE"), "{rendered}");
        assert!(Scenario::with_id("S01") == Some(Scenario::RelayOutage));
        assert!(Scenario::with_id("S99").is_none());
    }

    #[test]
    fn an_arm_that_stages_no_row_tolerates_no_gating_row() {
        const { assert!(NO_GATING_ROWS == 0) }
    }
}
