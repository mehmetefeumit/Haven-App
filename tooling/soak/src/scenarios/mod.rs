//! The scenarios this crate runs.
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
pub mod s02_receiver_partition;
pub mod s03_lost_commit;
pub mod s04_offline_member;
pub mod s05_publish_confirm;
pub mod s06_stuck_row;
pub mod s08_live_plane_burial;
pub mod s09_cursor_poisoning;
pub mod s10_ten_circles;
pub mod s11_quiet_circle;
pub mod s12_key_package_rotation;
pub mod s13_quarantine;
pub mod s14_restart_race;
pub mod s16_storage_growth;
pub mod s17_closed_prefixes;
pub mod s18_swallowed_ok;
pub mod s19_duplicate_reorder;
pub mod s20_catchup_sweep;
pub mod s21_removal_effectiveness;
pub mod s22_oversized_event;
pub mod s23_chained_backlog;

use std::fmt;
use std::time::Duration;

use haven_core::circle::MemberKeyPackage;
use haven_core::relay::maintenance::build_kp_maintenance_events;
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
    /// The tail after a removal is confirmed, during which a remaining member's
    /// NEXT fix must already carry the post-removal epoch.
    ///
    /// `location_publish_window()` — one bounded location attempt, no retry
    /// behind it (`haven-core/src/relay/manager.rs`'s
    /// `LOCATION_PUBLISH_ATTEMPTS` × `LOCATION_ACK_WINDOW`). NOT the 168-second
    /// `kLocationPublishMaxInterval`: that is a Dart constant with no
    /// haven-core equivalent, and in Tier 1 the rig is its own publish
    /// scheduler, so the tail it owes is one publish attempt per remaining
    /// member rather than a scheduler's own period.
    RemovalPublishTail,
    /// Haven's resubscribe lookback plus one wall second: the least time after
    /// an event's own second at which a re-anchor, and the catch-up sweep
    /// behind it, no longer ask for that event.
    ///
    /// Not an absence the arm asserts but a span it lets pass, carried here
    /// for the same two reasons: it is priced, and it may never be scaled — a
    /// scaled lookback would wait past the product's window rather than to its
    /// edge, and a shortened one would let the sweep recover what the arm set
    /// out to bury.
    ResubscribeLookback,
}

impl Absence {
    /// The window this absence spans.
    ///
    /// A pure function of the variant, which is all it can structurally be: an
    /// arm's absence is priced from `Arm::deadline` with nothing but `self` in
    /// hand, so an absence whose length depended on the arm's world could not
    /// be expressed here at all — and an unpriced wait is a budget hole and a
    /// flake generator at once.
    #[must_use]
    pub fn window(self) -> Duration {
        match self {
            Self::None => Duration::ZERO,
            Self::ThrottledBackoffFloor => bounds::throttled_backoff_floor(),
            Self::DeliverySilenceWindow => bounds::silence_window(),
            Self::RemovalPublishTail => bounds::location_publish_window(),
            Self::ResubscribeLookback => bounds::resubscribe_lookback(),
        }
    }
}

/// One scenario.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Scenario {
    /// **S01** — a relay goes away and comes back.
    RelayOutage,
    /// **S02** — one receiver is partitioned from the relay while a second
    /// publisher keeps publishing, and recovers what it missed.
    ReceiverPartition,
    /// **S03** — a relay forgets a commit before a paused member returns, and
    /// the member is stranded behind it.
    LostCommit,
    /// **S04** — a member is away across a span, and comes back.
    OfflineMember,
    /// **S05** — a resolution fails inside the publish→confirm window.
    PublishConfirmWindow,
    /// **S06** — a stored convergence input gates a circle until the sweep
    /// retires it.
    StuckRow,
    /// **S08** — a commit buried on the live plane under a page of forgeries
    /// past the relay's replay cap. Expected red until C8 is fixed.
    LivePlaneBurial,
    /// **S09** — an adversary forges at a circle's public routing id for the
    /// whole run, and neither receive plane's anchor takes a number from it.
    CursorPoisoning,
    /// **S11** — a circle stays quiet across a long policy span and resumes.
    QuietCircle,
    /// **S12** — a `KeyPackage` reaches the rotation point of its own lifetime.
    KeyPackageRotation,
    /// **S13** — a device loses one group's `OpenMLS` state and reopens.
    HydrationQuarantine,
    /// **S14** — two devices commit from one epoch, and one of them restarts in
    /// the middle of it.
    RestartRace,
    /// **S17** — a relay refuses subscriptions, machine-readably.
    ClosedPrefixes,
    /// **S18** — a relay stores an event and the acknowledgement never reaches
    /// the publisher.
    SwallowedOk,
    /// **S19** — duplicated, reordered and cross-addressed delivery.
    DuplicateReorder,
    /// **S22** — an event a relay will not take, and the removal that can never
    /// be retried.
    OversizedEvent,
    /// **S10** — the whole roster: ten circles on one account, one outage
    /// across all of them.
    TenCircleRoster,
    /// **S23** — a device misses two chained commits and never converges
    /// again. Expected red until C7 is fixed.
    ChainedBacklog,
    /// **S16** — durable-storage growth: three floods, three stores, one cap.
    StorageGrowth,
    /// **S21** — a removed member stops reading the circle, on both delivery
    /// paths, and the removal-effectiveness lag is bounded (invariant S8).
    RemovalEffectiveness,
    /// **S20** — the catch-up sweep against clamped, refused, cold and forged
    /// pages (RLY-05).
    CatchupSweep,
}

impl Scenario {
    /// Every scenario this crate runs.
    pub const REGISTRY: [Self; 21] = [
        Self::RelayOutage,
        Self::ReceiverPartition,
        Self::LostCommit,
        Self::OfflineMember,
        Self::PublishConfirmWindow,
        Self::StuckRow,
        Self::LivePlaneBurial,
        Self::CursorPoisoning,
        Self::TenCircleRoster,
        Self::QuietCircle,
        Self::KeyPackageRotation,
        Self::HydrationQuarantine,
        Self::RestartRace,
        Self::StorageGrowth,
        Self::ClosedPrefixes,
        Self::SwallowedOk,
        Self::DuplicateReorder,
        Self::CatchupSweep,
        Self::RemovalEffectiveness,
        Self::OversizedEvent,
        Self::ChainedBacklog,
    ];

    /// The id the profiles, the timeline and `--list-scenarios` spell.
    #[must_use]
    pub const fn id(self) -> &'static str {
        match self {
            Self::RelayOutage => "S01",
            Self::ReceiverPartition => "S02",
            Self::LostCommit => "S03",
            Self::OfflineMember => "S04",
            Self::PublishConfirmWindow => "S05",
            Self::StuckRow => "S06",
            Self::LivePlaneBurial => "S08",
            Self::CursorPoisoning => "S09",
            Self::QuietCircle => "S11",
            Self::KeyPackageRotation => "S12",
            Self::HydrationQuarantine => "S13",
            Self::RestartRace => "S14",
            Self::ClosedPrefixes => "S17",
            Self::SwallowedOk => "S18",
            Self::DuplicateReorder => "S19",
            Self::OversizedEvent => "S22",
            Self::TenCircleRoster => "S10",
            Self::ChainedBacklog => "S23",
            Self::StorageGrowth => "S16",
            Self::RemovalEffectiveness => "S21",
            Self::CatchupSweep => "S20",
        }
    }

    /// What the scenario breaks, in words.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::RelayOutage => "RELAY OUTAGE",
            Self::ReceiverPartition => "RECEIVER PARTITION BEHIND A SECOND PUBLISHER",
            Self::LostCommit => "LOST COMMIT BEHIND A RELAY WIPE",
            Self::OfflineMember => "MEMBER OFFLINE ACROSS A SPAN",
            Self::PublishConfirmWindow => "PUBLISH-CONFIRM WINDOW",
            Self::StuckRow => "STUCK CONVERGENCE ROW",
            Self::LivePlaneBurial => "LIVE-PLANE BURIAL PAST THE RELAY CAP",
            Self::CursorPoisoning => "CURSOR-POISONING STANDING ADVERSARY",
            Self::QuietCircle => "QUIET CIRCLE RESUME",
            Self::KeyPackageRotation => "KEYPACKAGE ROTATION SLOT",
            Self::HydrationQuarantine => "HYDRATION QUARANTINE",
            Self::RestartRace => "RESTART DURING A COMMIT RACE",
            Self::ClosedPrefixes => "CLOSED PREFIXES AND NOTICE",
            Self::SwallowedOk => "SWALLOWED ACKNOWLEDGEMENT",
            Self::DuplicateReorder => "DUPLICATE AND REORDERED DELIVERY",
            Self::OversizedEvent => "OVERSIZED COMMIT AND WELCOME",
            Self::TenCircleRoster => "TEN-CIRCLE ROSTER",
            Self::ChainedBacklog => "CHAINED-COMMIT BACKLOG",
            Self::StorageGrowth => "DURABLE-STORAGE GROWTH",
            Self::RemovalEffectiveness => "BOUNDED REMOVAL EFFECTIVENESS",
            Self::CatchupSweep => "CATCH-UP SWEEP UNDER PAGE FAULTS",
        }
    }

    /// Every arm this scenario offers.
    #[must_use]
    pub const fn arms(self) -> &'static [Arm] {
        match self {
            Self::RelayOutage => &s01_relay_outage::ARMS,
            Self::ReceiverPartition => &s02_receiver_partition::ARMS,
            Self::LostCommit => &s03_lost_commit::ARMS,
            Self::OfflineMember => &s04_offline_member::ARMS,
            Self::PublishConfirmWindow => &s05_publish_confirm::ARMS,
            Self::StuckRow => &s06_stuck_row::ARMS,
            Self::LivePlaneBurial => &s08_live_plane_burial::ARMS,
            Self::CursorPoisoning => &s09_cursor_poisoning::ARMS,
            Self::QuietCircle => &s11_quiet_circle::ARMS,
            Self::KeyPackageRotation => &s12_key_package_rotation::ARMS,
            Self::HydrationQuarantine => &s13_quarantine::ARMS,
            Self::RestartRace => &s14_restart_race::ARMS,
            Self::ClosedPrefixes => &s17_closed_prefixes::ARMS,
            Self::SwallowedOk => &s18_swallowed_ok::ARMS,
            Self::DuplicateReorder => &s19_duplicate_reorder::ARMS,
            Self::OversizedEvent => &s22_oversized_event::ARMS,
            Self::TenCircleRoster => &s10_ten_circles::ARMS,
            Self::ChainedBacklog => &s23_chained_backlog::ARMS,
            Self::StorageGrowth => &s16_storage_growth::ARMS,
            Self::RemovalEffectiveness => &s21_removal_effectiveness::ARMS,
            Self::CatchupSweep => &s20_catchup_sweep::ARMS,
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
            Self::ReceiverPartition => s02_receiver_partition::run(world, arm, tick).await?,
            Self::LostCommit => s03_lost_commit::run(world, arm, tick).await?,
            Self::OfflineMember => s04_offline_member::run(world, arm, tick).await?,
            Self::PublishConfirmWindow => s05_publish_confirm::run(world, arm, tick).await?,
            Self::StuckRow => s06_stuck_row::run(world, arm, tick).await?,
            Self::LivePlaneBurial => s08_live_plane_burial::run(world, arm, tick).await?,
            Self::CursorPoisoning => s09_cursor_poisoning::run(world, arm, tick).await?,
            Self::QuietCircle => s11_quiet_circle::run(world, arm, tick).await?,
            Self::KeyPackageRotation => s12_key_package_rotation::run(world, arm, tick).await?,
            Self::HydrationQuarantine => s13_quarantine::run(world, arm, tick).await?,
            Self::RestartRace => s14_restart_race::run(world, arm, tick).await?,
            Self::ClosedPrefixes => s17_closed_prefixes::run(world, arm, tick).await?,
            Self::SwallowedOk => s18_swallowed_ok::run(world, arm, tick).await?,
            Self::DuplicateReorder => s19_duplicate_reorder::run(world, arm, tick).await?,
            Self::OversizedEvent => s22_oversized_event::run(world, arm, tick).await?,
            Self::TenCircleRoster => s10_ten_circles::run(world, arm, tick).await?,
            Self::ChainedBacklog => s23_chained_backlog::run(world, arm, tick).await?,
            Self::StorageGrowth => s16_storage_growth::run(world, arm, tick).await?,
            Self::RemovalEffectiveness => s21_removal_effectiveness::run(world, arm, tick).await?,
            Self::CatchupSweep => s20_catchup_sweep::run(world, arm, tick).await?,
        };
        Ok(self.report(world, arm, outcome, started))
    }

    /// Grades what an arm's body produced against its floor.
    pub(crate) fn report<T: TimelineSink, L: LogDrain>(
        self,
        world: &ScenarioWorld<T, L>,
        arm: &Arm,
        outcome: ArmOutcome,
        started: tokio::time::Instant,
    ) -> ScenarioReport {
        ScenarioReport {
            scenario: self,
            arm: arm.label,
            graded: outcome.graded,
            floor: grade(&arm.floor, &outcome.observed),
            observed: outcome.observed,
            elapsed: started.elapsed(),
            deadline: arm.deadline(outcome.tick, &shape_of(world)),
        }
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
///
/// The retention edges are the one term this does not take: O4's subject is fed
/// by exactly one arm, and an eighth parameter on every call site would price
/// it on all of them. An arm that has edges attaches them with
/// [`Round::with_retention`]; the empty slice here is the declaration that this
/// round tested no window edge.
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
        retention: &[],
        forward_secrecy: &[],
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
    // Either rung ends in the engine's replay, so either can hand back work.
    // It goes down the rig's one Rule-13 ladder rather than on the floor.
    let (verdict, ingest) = if witnessed.is_some() {
        let ingest = manager
            .finalize_relay_update(staged.pending, circle.mls_group_id())
            .await
            .map_err(|_| RigError::Core(Step::ConfirmPublished))?;
        (PublishVerdict::Confirmed, ingest)
    } else {
        let ingest = manager
            .publish_failed(staged.pending)
            .await
            .map_err(|_| RigError::Core(Step::RollBackPublish))?;
        (PublishVerdict::RolledBack, ingest)
    };
    world.resolve_ingest(device, ingest).await?;
    drop(guard);
    Ok((event, verdict))
}

/// Removes `victim` from `circle` under `admin`, resolved under Rule 13.
///
/// Public, unlike [`relay_update`], because the rig's membership ops are a
/// capability of this crate rather than of one scenario: the arms that need
/// them are not all written yet, and the crate's own tests drive them
/// meanwhile.
///
/// The membership sibling of [`relay_update`], and the same shape: stage,
/// publish-and-witness, confirm on an ack or roll back without one, drain the
/// engine's replay. The commit event comes back so a scenario can withhold it,
/// forge against it or watch for it on a plane.
///
/// The world's own roster table is NOT updated, deliberately: no oracle reads
/// [`SimCircle::members`] — every roster verdict is read from the product's own
/// converged roster — so a second, harness-side copy of the membership could
/// only ever disagree with the subject.
///
/// # Errors
///
/// [`RigError::Core`] naming the step that failed: staging (the engine refused
/// the removal, e.g. the caller is not an admin) or the Rule-13 resolution.
pub async fn remove_member<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    circle: &SimCircle,
    victim: DeviceTag,
) -> Result<(Event, PublishVerdict), RigError> {
    let victim_pubkey = world.device(victim)?.pubkey_hex();
    let staged = world
        .device(admin)?
        .manager()?
        .remove_members(circle.mls_group_id(), std::slice::from_ref(&victim_pubkey))
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    let commit = staged.commit_event.clone();
    let verdict = world
        .publish_and_confirm(admin, staged.pending, std::slice::from_ref(&commit))
        .await?;
    Ok((commit, verdict))
}

/// Adds `joiner` to `circle` under `admin`, and joins it from its own welcome.
///
/// The welcomes go out with the commit and the whole batch is resolved once:
/// haven-core stages one pending state for an add, and a rig that confirmed the
/// commit while a welcome was still in flight would be inventing a second
/// Rule-13 window the product does not have.
///
/// The joiner processes its welcome only on a CONFIRMED add: a rolled-back
/// commit means the group never advanced, and a member that joined from its
/// welcome anyway would be a member of an epoch nobody else holds.
///
/// # Errors
///
/// [`RigError::Core`] naming the step that failed: minting the joiner's key
/// package, staging the add, the Rule-13 resolution, or the join itself.
pub async fn add_member<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    circle: &SimCircle,
    joiner: DeviceTag,
) -> Result<(Event, PublishVerdict), RigError> {
    let urls = world.relay_urls();
    let joining = world.device(joiner)?;
    let key_package =
        build_kp_maintenance_events(joining.session()?, &joining.keys, &urls, None, None)
            .await
            .map_err(|_| RigError::Core(Step::MintKeyPackage))?;
    let sender = world.device(admin)?;
    let staged = sender
        .manager()?
        .add_members_with_welcomes(
            &sender.keys,
            circle.mls_group_id(),
            vec![MemberKeyPackage {
                key_package_event: key_package.event,
                // Explicit, always: an empty relay set falls back to the
                // PRODUCTION default pool, which would take the welcome off
                // this world's relay and onto the public network.
                inbox_relays: urls.clone(),
                nip65_relays: Vec::new(),
            }],
            &urls,
        )
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;

    let commit = staged.commit_event.clone();
    let mut batch = vec![commit.clone()];
    batch.extend(
        staged
            .welcome_events
            .iter()
            .map(|welcome| welcome.event.clone()),
    );
    let verdict = world
        .publish_and_confirm(admin, staged.pending, &batch)
        .await?;
    if verdict == PublishVerdict::Confirmed {
        for welcome in &staged.welcome_events {
            if welcome.recipient_pubkey != joining.pubkey_hex() {
                continue;
            }
            joining
                .manager()?
                .process_gift_wrapped_invitation(&joining.keys, &welcome.event)
                .await
                .map_err(|_| RigError::Core(Step::ProcessInvitation))?;
            joining
                .manager()?
                .accept_invitation(&welcome.event.id)
                .await
                .map_err(|_| RigError::Core(Step::AcceptInvitation))?;
        }
    }
    Ok((commit, verdict))
}

/// Makes `successor` an admin of `circle`, resolved under Rule 13.
///
/// An ADDITIVE policy update, which is what the product's own call is: the
/// existing admins keep the bit. A scenario that needs the handing-off device
/// to lose it demotes itself afterwards, which is a second commit and a second
/// Rule-13 window.
///
/// # Errors
///
/// [`RigError::Core`] naming the step that failed: staging (the caller is not
/// an admin, or the successor holds no leaf in the group) or the resolution.
pub async fn hand_off_admin<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    circle: &SimCircle,
    successor: DeviceTag,
) -> Result<(Event, PublishVerdict), RigError> {
    let successor_pubkey = world.device(successor)?.keys.public_key();
    let staged = world
        .device(admin)?
        .manager()?
        .propose_admin_handoff(circle.mls_group_id(), &successor_pubkey)
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    let commit = staged.commit_event.clone();
    let verdict = world
        .publish_and_confirm(admin, staged.pending, std::slice::from_ref(&commit))
        .await?;
    Ok((commit, verdict))
}

/// How many location deliveries `device` has folded for `circle`.
pub(crate) fn deliveries_for(device: &SimDevice, circle: CircleTag) -> u64 {
    device.ledger().deliveries_for(circle)
}

#[cfg(test)]
mod tests {
    use super::{
        add_member, hand_off_admin, registry, remove_member, Absence, Arm, PublishVerdict,
        Scenario, SimCircle, WithheldAcks, MINIMAL_SHAPE, NO_GATING_ROWS, WITNESS_BOUND,
    };
    use crate::nemesis::types::Schedule;
    use crate::oracle::bounds;
    use crate::oracle::Recovery;
    use crate::profiles::WorldShape;
    use crate::profiles::{ProfileName, ProfileSpec};
    use crate::relay::SimRelay;
    use crate::rig::circle::build_circle;
    use crate::rig::doubles::{RecordingTimeline, StubDrain};
    use crate::rig::{CircleTag, DeviceTag, RelayPlane, RelayTag, SimWorld};
    use haven_core::nostr::mls::types::ConvergedRoster;
    use std::sync::atomic::AtomicUsize;
    use std::sync::Arc;
    use std::time::Duration;

    /// The world the membership cases run in: three real devices on a real
    /// plane, so a removal still leaves a pair that can talk.
    type MembershipWorld = super::ScenarioWorld<RecordingTimeline, StubDrain>;

    async fn membership_world() -> MembershipWorld {
        let relay = SimRelay::start(RelayTag::new(0))
            .await
            .expect("the relay plane starts");
        SimWorld::build(
            &WorldShape {
                members: 3,
                circles: 1,
                relays: 1,
            },
            Schedule::new(Vec::new()),
            vec![relay],
            RecordingTimeline::default(),
            StubDrain::default(),
        )
        .await
        .expect("the world builds")
    }

    /// A circle over the world's FIRST TWO devices only.
    ///
    /// Every circle a world builds holds every device, so this is the only
    /// shape in which "add somebody" is a thing that can happen at all. It is
    /// deliberately outside `world.circles()` — nothing world-wide grades it —
    /// which is exactly the disposition `build_extra_circle` documents.
    async fn circle_without_the_third_device(world: &MembershipWorld) -> SimCircle {
        build_circle(
            CircleTag::new(9),
            &world.devices()[..2],
            world.relays(),
            &world.relay_urls(),
            &Arc::new(AtomicUsize::new(0)),
        )
        .await
        .expect("a two-member circle is created")
    }

    /// `device`'s own view of who is in `circle`.
    async fn roster_of(
        world: &MembershipWorld,
        device: DeviceTag,
        circle: &SimCircle,
    ) -> Vec<String> {
        let roster = world
            .device(device)
            .expect("a device")
            .session()
            .expect("a session")
            .converged_member_pubkeys(circle.mls_group_id())
            .await
            .expect("a roster reads");
        let ConvergedRoster::Converged {
            mut member_pubkeys_hex,
            ..
        } = roster
        else {
            panic!("a device that just committed must hold a converged roster");
        };
        member_pubkeys_hex.sort();
        member_pubkeys_hex
    }

    async fn epoch_of(world: &MembershipWorld, device: DeviceTag, circle: &SimCircle) -> u64 {
        world
            .device(device)
            .expect("a device")
            .manager()
            .expect("a manager")
            .group_epoch(circle.mls_group_id())
            .await
            .expect("an epoch reads")
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_removal_is_confirmed_under_rule_13_and_takes_the_victim_off_the_roster() {
        let world = membership_world().await;
        let circle = circle_without_the_third_device(&world).await;
        let (admin, victim) = (DeviceTag::new(0), DeviceTag::new(1));
        let victim_pubkey = world.device(victim).expect("a device").pubkey_hex();

        let before = epoch_of(&world, admin, &circle).await;
        assert!(
            roster_of(&world, admin, &circle)
                .await
                .contains(&victim_pubkey),
            "the victim must be in the circle before it can be removed from one"
        );

        let (commit, verdict) = remove_member(&world, admin, &circle, victim)
            .await
            .expect("the removal stages and resolves");

        assert!(
            verdict == PublishVerdict::Confirmed,
            "a witnessed ack is what licenses the merge (Rule 13)"
        );
        assert!(
            epoch_of(&world, admin, &circle).await > before,
            "a confirmed removal advances the epoch"
        );
        assert!(
            !roster_of(&world, admin, &circle)
                .await
                .contains(&victim_pubkey),
            "the roster the product reports is what the removal has to change"
        );
        assert!(
            world.relays()[0].witnessed_ok(&commit.id),
            "the commit the caller gets back is the one that really crossed the wire"
        );
        assert!(
            world.outstanding_pending_refs() == 0,
            "a staged commit nobody resolved forks the group"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn an_add_is_confirmed_under_rule_13_and_the_joiner_ends_up_in_the_group() {
        let world = membership_world().await;
        let circle = circle_without_the_third_device(&world).await;
        let (admin, joiner) = (DeviceTag::new(0), DeviceTag::new(2));
        let joiner_pubkey = world.device(joiner).expect("a device").pubkey_hex();

        let before = epoch_of(&world, admin, &circle).await;
        assert!(
            !roster_of(&world, admin, &circle)
                .await
                .contains(&joiner_pubkey),
            "the joiner must be outside the circle, or the add proves nothing"
        );

        let (commit, verdict) = add_member(&world, admin, &circle, joiner)
            .await
            .expect("the add stages, resolves and is joined");

        assert!(
            verdict == PublishVerdict::Confirmed,
            "a witnessed ack is what licenses the merge (Rule 13)"
        );
        assert!(
            epoch_of(&world, admin, &circle).await > before,
            "a confirmed add advances the epoch"
        );
        assert!(
            roster_of(&world, admin, &circle)
                .await
                .contains(&joiner_pubkey),
            "the admin's own roster must carry the member it just added"
        );
        assert!(
            roster_of(&world, joiner, &circle)
                .await
                .contains(&joiner_pubkey),
            "and the joiner must hold the group it was welcomed into, not merely a welcome"
        );
        assert!(
            world.relays()[0].witnessed_ok(&commit.id),
            "the commit the caller gets back is the one that really crossed the wire"
        );
        assert!(
            world.outstanding_pending_refs() == 0,
            "a staged commit nobody resolved forks the group"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_handoff_is_confirmed_and_the_successor_can_then_commit_itself() {
        let world = membership_world().await;
        let circle = circle_without_the_third_device(&world).await;
        let (admin, successor) = (DeviceTag::new(0), DeviceTag::new(1));

        // The successor cannot commit before the handoff: the engine refuses a
        // membership change from a non-admin, which is what makes the handoff
        // the cause of the second half of this test.
        let refused = remove_member(&world, successor, &circle, admin).await;
        assert!(
            refused.is_err(),
            "a non-admin must not be able to remove anybody"
        );

        let (commit, verdict) = hand_off_admin(&world, admin, &circle, successor)
            .await
            .expect("the handoff stages and resolves");
        assert!(
            verdict == PublishVerdict::Confirmed,
            "a witnessed ack is what licenses the merge (Rule 13)"
        );
        assert!(
            world.relays()[0].witnessed_ok(&commit.id),
            "the handoff commit really crossed the wire"
        );

        // The successor's own engine has to have APPLIED the handoff before it
        // can use it, and in this world nothing delivers it: the commit goes
        // in through the same ingest a live plane would use.
        world
            .device(successor)
            .expect("a device")
            .session()
            .expect("a session")
            .process_event_typed_for_test(&commit)
            .await
            .expect("the successor ingests the handoff commit")
            .ingested()
            .expect("a handoff commit is not screened before authentication");

        let (_, verdict) = hand_off_admin(&world, successor, &circle, admin)
            .await
            .expect("the new admin can now commit a policy change of its own");
        assert!(
            verdict == PublishVerdict::Confirmed,
            "the successor holds the admin bit the handoff gave it"
        );
        assert!(
            world.outstanding_pending_refs() == 0,
            "a staged commit nobody resolved forks the group"
        );
    }

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
    fn every_absence_is_a_named_product_window_and_every_one_of_them_is_priced() {
        // Exhaustive on purpose: an absence whose window nothing derives is a
        // wait somebody can quietly shorten, and one nothing prices is a budget
        // hole that shows up as a flake.
        for absence in [
            Absence::None,
            Absence::ThrottledBackoffFloor,
            Absence::DeliverySilenceWindow,
            Absence::RemovalPublishTail,
            Absence::ResubscribeLookback,
        ] {
            let window = absence.window();
            assert!(
                (absence == Absence::None) == window.is_zero(),
                "only the absence that asserts nothing may span nothing"
            );
            let arm = Arm {
                label: "priced",
                recovery: Recovery::Undisturbed,
                probe_rounds: 0,
                resubscribes: false,
                absence,
                withheld_acks: WithheldAcks::None,
                floor: crate::oracle::vacuity::ExpectationFloor {
                    faults_applied: 1,
                    epochs_crossed: 0,
                    deliveries_observed: 0,
                    canaries_caught: 0,
                },
            };
            let without = Arm {
                absence: Absence::None,
                ..arm
            };
            assert!(
                arm.deadline(Duration::from_millis(250), &MINIMAL_SHAPE)
                    == without.deadline(Duration::from_millis(250), &MINIMAL_SHAPE) + window,
                "an arm's deadline must grow by exactly the window it waits out"
            );
        }
        assert!(
            Absence::RemovalPublishTail.window() == bounds::location_publish_window(),
            "the removal tail is the product's own location publish window: one bounded \
             attempt, with no retry behind it"
        );
        assert!(
            Absence::ResubscribeLookback.window() == bounds::resubscribe_lookback(),
            "the lookback is the product's own resubscribe buffer plus one wall second"
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
        assert_eq!(Scenario::with_id("S01"), Some(Scenario::RelayOutage));
        assert!(Scenario::with_id("S99").is_none());
    }

    #[test]
    fn an_arm_that_stages_no_row_tolerates_no_gating_row() {
        const { assert!(NO_GATING_ROWS == 0) }
    }
}
