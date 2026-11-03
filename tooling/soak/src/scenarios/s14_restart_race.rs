//! **S14** — two devices commit from one epoch, and one of them restarts in the
//! middle of it.
//!
//! The promise: a same-epoch commit race converges, and a restart does not
//! change that. The engine's `CommitOrderingKey` reorg picks one branch and the
//! loser withdraws its own confirmed commit by its stamped origin — even when
//! the loser was rebuilt from disk in between, which is the case that clears the
//! in-memory `we_committed_from` guard and so takes a different route through
//! the engine.
//!
//! # The one arm that does NOT converge, and why it is recorded rather than
//! graded
//!
//! A branch is convergeable only while both the rewind horizon and the retained
//! anchor still reach back to the fork. Walk each branch far enough and neither
//! does, and the two devices are left on two branches wearing one epoch number:
//! the same epoch, the same roster, a healthy send path, and no cross-decrypt in
//! either direction. `race-anchor-exhausted` asserts exactly that outcome as its
//! expectation, so the day the product stops producing it the arm goes rc 3 —
//! "the recorded expectation is stale" — rather than green.
//!
//! # Every arm runs in a circle of its own, outside the world's table
//!
//! [`SimWorld::build_extra_circle`](crate::rig::SimWorld::build_extra_circle)
//! keeps the circle out of `world.circles()`, so no world-wide oracle grades
//! it and the forked arm cannot redden a lane for behaviour the product is
//! known to have. The world's own circles are untouched by every arm and are
//! what the closing round grades.
//!
//! # The racers' engines are stopped for the race
//!
//! An engine listens to every circle its device holds — it follows each
//! circle's routing at its start and whenever a row moves — so a running
//! engine would hand a racer its sibling the moment the sibling reached the
//! relay, and the engine answers a second look at one MLS message with a
//! duplicate: the arm's own ingest would then read the duplicate, not the
//! race. Each arm therefore stops both racers' engines before the race
//! ([`deafen`]) and starts them again once its reads are done ([`rehear`]),
//! which is what makes "neither device has ingested the other's commit" a
//! property of the arm rather than of a pause that has to be timed. A restart
//! inside the arm rebuilds the session from disk with no engine to restart.
//!
//! The cost of that isolation is that [`Observed::measure`] cannot see the
//! circle's epochs (`WorldFingerprint` walks `world.circles()`), so every arm
//! here declares `epochs_crossed: 0` and asserts the epoch distance it really
//! crossed as a CANARY against its own circle instead. The control arm and the
//! known-bad arm have to differ in nothing but the interruption, and only one
//! kind of circle can hold both.
//!
//! # A restart here is a clean cancel, not a `SIGKILL`
//!
//! [`KillKind::Hard`] drops the engine without stopping it, which is the shape
//! of a background kill: the worker's panic-isolation spawn still runs to
//! completion and no write-ahead log is torn. Torn-storage fidelity belongs to
//! Tier 2's snapshot nemesis, and a reader must not take a green arm here as
//! coverage of it.

use std::time::Duration;

use haven_core::nostr::mls::types::{ConvergedRoster, FanoutId, FanoutMls, OpenMlsContentKind};
use haven_core::nostr::mls::{max_rewind_commits, SessionManager};
use haven_core::relay::fanout::{
    drive_due, drive_one, DriveMode, FanoutClock, FanoutStatus, WallClock,
};
use haven_core::relay::live_sync::StopOutcome;
use nostr::{Event, JsonUtil as _};

use crate::nemesis::types::Fault;

use crate::oracle::undecryptable::{self, Probe, StoredRow};
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{Finding, Invariant, ProbeToken, Reach, Recovery, Verdict};
use crate::rig::circle::PacingClock;
use crate::rig::{
    kill_and_reopen, DeviceTag, KillKind, LogDrain, PublishVerdict, RelayPlane as _, RigError,
    SimCircle, Step, TimelineSink,
};
use crate::scenarios::{
    closing_pairs, grade_round, hand_off_admin, relay_update, round, Absence, Arm, ArmOutcome,
    ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// The arms this scenario offers.
pub const ARMS: [Arm; 4] = [
    Arm {
        label: "race-no-restart",
        recovery: Recovery::Undisturbed,
        probe_rounds: 2,
        // The racers' engines start again after the race ([`rehear`]).
        resubscribes: true,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 0,
            // See the module docs: the race's own circle is outside the world's
            // table, so this term cannot see it and canary 2 carries the claim.
            epochs_crossed: 0,
            deliveries_observed: 2,
            canaries_caught: 3,
        },
    },
    Arm {
        label: "race-restart-after-confirm",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: true,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 0,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 4,
        },
    },
    Arm {
        label: "race-restart-before-confirm",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: true,
        absence: Absence::None,
        // The second commit's drive: its relays store the commit and their
        // acknowledgements never reach the device.
        withheld_acks: WithheldAcks::FanoutDrives(1),
        floor: ExpectationFloor {
            faults_applied: 0,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 4,
        },
    },
    Arm {
        label: "race-anchor-exhausted",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: true,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 0,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 5,
        },
    },
];

/// What one same-epoch race staged.
///
/// No `Debug`: two of the three fields are signed events, and an event id is an
/// identifier (Security Rule 15).
pub struct RaceStage {
    /// The first device's commit, confirmed under Rule 13.
    pub first: Event,
    /// The second device's commit.
    pub second: Event,
    /// Whether both devices really staged from ONE epoch and both commits were
    /// accepted by a relay — the premise without which nothing below is a race.
    pub genuine: bool,
    /// The second commit's durable fanout, when it was left staged.
    pub left_staged: Option<FanoutId>,
}

/// What the second device does with its own staged commit.
///
/// No `Debug`, like everything else here: a knob nothing renders needs no
/// rendering, and every one this crate defines has to carry a sample.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum SecondCommit {
    /// Published, acknowledged and confirmed, like the first.
    Confirmed,
    /// Staged with its durable fanout and driven by the product's own driver
    /// into relays that store it and whose acknowledgements never arrive: it
    /// stays staged, inside the publish→confirm window, for a caller to end
    /// the process in. The caller arms that fault on the device first.
    LeftStaged,
}

/// Stops both racers' engines (see the module docs).
///
/// # Errors
///
/// [`RigError::StopTimedOut`] if an engine's stop did not drain, or
/// [`RigError::UnknownTarget`] if a racer is not in the world.
pub async fn deafen<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    racers: (DeviceTag, DeviceTag),
) -> Result<(), RigError> {
    for tag in <[DeviceTag; 2]>::from(racers) {
        if let Some(core) = world.device_mut(tag)?.take_engine() {
            if core.stop().await == StopOutcome::TimedOut {
                return Err(RigError::StopTimedOut);
            }
        }
    }
    Ok(())
}

/// Starts both racers' engines again over their own circles.
///
/// # Errors
///
/// [`RigError::Core`] with [`Step::StartEngine`] if a start failed.
pub async fn rehear<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    racers: (DeviceTag, DeviceTag),
) -> Result<(), RigError> {
    for tag in <[DeviceTag; 2]>::from(racers) {
        let device = world.device_mut(tag)?;
        let specs = device.specs().to_vec();
        device.start_engine(specs).await?;
    }
    Ok(())
}

/// Makes `successor` a co-admin of `circle` and applies the handoff on its own
/// session.
///
/// Without it there is no race to have: the engine refuses a membership or
/// policy commit from a non-admin, so only one device in a circle can stage one.
///
/// # Errors
///
/// [`RigError`] naming the step that failed, or [`RigError::PublishNeverAcked`]
/// if no relay acknowledged the handoff — Rule 13 then rolled it back and the
/// successor never got the bit.
pub async fn co_admin<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    circle: &SimCircle,
    admin: DeviceTag,
    successor: DeviceTag,
) -> Result<(), RigError> {
    let (commit, verdict) = hand_off_admin(world, admin, circle, successor).await?;
    if verdict != PublishVerdict::Confirmed {
        return Err(RigError::PublishNeverAcked);
    }
    // The successor's own session has to have APPLIED the handoff before it
    // can use it, and nothing delivers this circle: the racers' engines are
    // stopped (module docs). MDK v0.10.4 holds a peer
    // commit for its quiescence window, so the deadline it announces is served
    // the way a receive plane serves it.
    let session = world.device(successor)?.session()?;
    session
        .process_event_typed_for_test(&commit)
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    session
        .settle_receive_for_test(circle.mls_group_id())
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    Ok(())
}

/// Stages one genuine same-epoch commit race in `circle`.
///
/// Both devices must already be admins ([`co_admin`]). Each reads its own epoch,
/// stages a relay-list commit, publishes it and waits for a relay's own
/// acknowledgement before confirming — Rule 13 on both sides — so the two
/// branches are branches the group could really be on.
///
/// Both racers' engines must be stopped ([`deafen`]), or the live plane
/// delivers the first commit to the second device before it stages: the
/// engine records every message's disposition, and the second look at one MLS
/// message is a duplicate, so a race ingested live would classify as one.
///
/// [`SecondCommit::LeftStaged`] stages the second commit the way the product
/// does — in staging mode, its durable fanout written with it — and hands it
/// to the product's driver. The caller has armed a swallowed acknowledgement
/// on that device, so the drive ends with the commit on the relay, unresolved
/// on the device, and the process can be ended in exactly that window. The
/// rig's staged-commit count does not hold it: the fanout row does, and the
/// caller resumes it after the restart.
///
/// # Errors
///
/// [`RigError`] naming the step that failed, or [`RigError::PublishNeverAcked`]
/// if a commit went unacknowledged — Rule 13 forbids confirming it, so there is
/// no second branch and no race.
pub async fn stage_race<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    circle: &SimCircle,
    racers: (DeviceTag, DeviceTag),
    second: SecondCommit,
) -> Result<RaceStage, RigError> {
    let (first_tag, second_tag) = racers;
    let mut commits: Vec<Event> = Vec::with_capacity(2);
    let mut staged_from: Vec<u64> = Vec::with_capacity(2);
    let mut acked = true;
    let mut left_staged = None;

    for (index, tag) in [first_tag, second_tag].into_iter().enumerate() {
        staged_from.push(epoch_of(world, tag, circle).await?);
        // A relay list the circle does not already hold: the product answers
        // a repeat already so, which advances no epoch and stages no branch.
        let mut relays = world.relay_urls();
        relays.push(format!("wss://s14-race-{index}.example.com"));
        if tag == second_tag && second == SecondCommit::LeftStaged {
            let (commit, id, stored) =
                stage_and_drive_unacknowledged(world, tag, circle, relays).await?;
            acked &= stored;
            commits.push(commit);
            left_staged = Some(id);
            continue;
        }
        let (commit, verdict) = relay_update(world, tag, circle, &relays).await?;
        if verdict != PublishVerdict::Confirmed {
            // No relay acknowledged it, so the product did not apply it and
            // the arm has no race to grade.
            return Err(RigError::PublishNeverAcked);
        }
        commits.push(commit);
    }

    let [first, second_commit] = commits
        .try_into()
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    Ok(RaceStage {
        first,
        second: second_commit,
        genuine: acked && staged_from.first() == staged_from.last(),
        left_staged,
    })
}

/// Stages a relay-list commit on `tag` in staging mode and drives it once
/// through the product's durable-fanout driver, expecting NO acknowledgement:
/// the commit and its fanout, and whether a relay plane stored the commit
/// while none of them saw its `OK` reach the device.
async fn stage_and_drive_unacknowledged<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    tag: DeviceTag,
    circle: &SimCircle,
    relays: Vec<String>,
) -> Result<(Event, FanoutId, bool), RigError> {
    world.note_routing_of(circle.mls_group_id(), &relays);
    let device = world.device(tag)?;
    let session = device.session()?;
    let staged = session
        .update_relays_staging(circle.mls_group_id(), relays, WallClock.now_ms())
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    let [id] =
        <[FanoutId; 1]>::try_from(staged.fanouts).map_err(|_| RigError::Core(Step::StageCommit))?;
    let frozen = session
        .fanout_probe_for_test(&id)
        .await
        .ok()
        .flatten()
        .ok_or(RigError::Core(Step::StageCommit))?;
    let commit =
        Event::from_json(&frozen.payload).map_err(|_| RigError::Core(Step::StageCommit))?;

    let outcome = drive_one(
        device.manager()?,
        &device.fanout_transport(),
        &WallClock,
        &id,
        &DriveMode::Full,
    )
    .await
    .map_err(|_| RigError::Core(Step::Publish))?;
    let mut stored = false;
    for plane in world.relays() {
        stored |= plane.stored(&commit.id).await?;
    }
    Ok((
        commit,
        id,
        stored && outcome.status == FanoutStatus::Unresolved,
    ))
}

/// Arms, or heals, a swallowed acknowledgement on `device`'s own endpoint of
/// every relay plane.
async fn swallow_acks<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    device: DeviceTag,
    on: bool,
) -> Result<(), RigError> {
    let fault = if on { Fault::SwallowOk } else { Fault::Heal };
    for plane in world.relays_mut() {
        plane.apply_for(device, fault).await?;
    }
    Ok(())
}

/// One device ingests one sibling commit, exactly once, classified — and, if
/// the engine holds it for the convergence pass that adjudicates the race,
/// classified again once that pass has closed.
///
/// The stored row is located AFTER the ingest and never before: the engine keys
/// every row on its hash over the PEELED MLS bytes, so a caller holding only the
/// signed event cannot name the row its own ingest is about to write. Without
/// that row a branch loss is undetermined rather than cheerfully "no branch was
/// lost", which would under-report forks.
///
/// # Errors
///
/// [`RigError`] naming the read or the convergence service that failed.
pub async fn ingest_sibling<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    circle: &SimCircle,
    ingester: DeviceTag,
    sibling: &Event,
) -> Result<undecryptable::Verdict, RigError> {
    let session = world.device(ingester)?.session()?;
    let outcome = session.process_event_typed_for_test(sibling).await;
    let verdict = undecryptable::classify_ingest(&outcome, sibling_row(session, circle).await);
    if verdict != undecryptable::Verdict::CommitGap {
        return Ok(verdict);
    }
    session
        .settle_receive_for_test(circle.mls_group_id())
        .await
        .map_err(|_| RigError::Core(Step::ServeConvergence))?;
    Ok(undecryptable::classify_settled_sibling(
        sibling_row(session, circle).await,
    ))
}

/// The most recently stored commit row in `circle` — the sibling's, after its
/// ingest.
async fn sibling_row(session: &SessionManager, circle: &SimCircle) -> Probe {
    match session
        .stored_convergence_input_for_test(circle.mls_group_id(), OpenMlsContentKind::Commit, 1)
        .await
    {
        Ok(record) => session
            .stored_message_record_for_test(&record.id)
            .await
            .map_or(Probe::Unreadable, Probe::Read),
        Err(_) => Probe::Read(None),
    }
}

/// Each racer ingests the OTHER's commit exactly once, classified.
///
/// # Errors
///
/// [`RigError`] naming the read that failed.
pub async fn merge_race<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    circle: &SimCircle,
    racers: (DeviceTag, DeviceTag),
    stage: &RaceStage,
) -> Result<Vec<undecryptable::Verdict>, RigError> {
    let mut verdicts = Vec::with_capacity(2);
    for (ingester, sibling) in [(racers.1, &stage.first), (racers.0, &stage.second)] {
        verdicts.push(ingest_sibling(world, circle, ingester, sibling).await?);
    }
    Ok(verdicts)
}

/// Where two devices stand on one circle, branch and all.
///
/// Equal epoch NUMBERS are not convergence: two branches at one number derive
/// different exporter secrets, so the bidirectional current-epoch cross-decrypt
/// is the only evidence either way.
pub struct BranchState {
    /// Whether both devices report one epoch.
    pub same_epoch: bool,
    /// Whether both report one roster.
    pub same_roster: bool,
    /// What the second device made of a location the first just sealed.
    pub b_reads_a: undecryptable::Verdict,
    /// …and the other direction.
    pub a_reads_b: undecryptable::Verdict,
}

impl BranchState {
    /// One branch: one epoch, one roster, and both directions readable.
    #[must_use]
    pub fn converged(&self) -> bool {
        self.same_epoch
            && self.same_roster
            && self.b_reads_a == undecryptable::Verdict::Applied
            && self.a_reads_b == undecryptable::Verdict::Applied
    }

    /// Two branches wearing one epoch number — the failure with no Haven-side
    /// symptom.
    #[must_use]
    pub fn twin_fork(&self) -> bool {
        self.same_epoch
            && self.same_roster
            && self.b_reads_a != undecryptable::Verdict::Applied
            && self.a_reads_b != undecryptable::Verdict::Applied
    }

    /// Both cross-decrypt dispositions, for O5 to account for.
    #[must_use]
    pub const fn classified(&self) -> [undecryptable::Verdict; 2] {
        [self.b_reads_a, self.a_reads_b]
    }
}

/// Reads [`BranchState`] for `racers` over `circle`.
///
/// Each direction mints a FRESH location at the sender's current epoch and has
/// the peer ingest it once. Nothing is published: the circle is outside the
/// world's table, so the peer would never receive it anyway, and one MLS message
/// may only be ingested once.
///
/// # Errors
///
/// [`RigError`] naming the read that failed.
pub async fn branch_state<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    circle: &SimCircle,
    racers: (DeviceTag, DeviceTag),
) -> Result<BranchState, RigError> {
    let (alice, bob) = racers;
    let same_epoch = epoch_of(world, alice, circle).await? == epoch_of(world, bob, circle).await?;
    let same_roster =
        roster_of(world, alice, circle).await? == roster_of(world, bob, circle).await?;
    let from_a = seal(world, alice, circle, 1).await?;
    let from_b = seal(world, bob, circle, 2).await?;
    let b_reads_a =
        undecryptable::classify(world.device(bob)?, &from_a, StoredRow::Unknown).await?;
    let a_reads_b =
        undecryptable::classify(world.device(alice)?, &from_b, StoredRow::Unknown).await?;
    Ok(BranchState {
        same_epoch,
        same_roster,
        b_reads_a,
        a_reads_b,
    })
}

/// Runs one arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not one this scenario offers,
/// [`RigError::ShapeMismatch`] if the world has fewer than two devices,
/// otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [alice, bob, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    let racers = (alice, bob);

    let mut classified: Vec<undecryptable::Verdict> = Vec::new();
    let mut extra: Vec<(Invariant, Verdict)> = Vec::new();

    // The control round runs BEFORE the circle the race forks is built, so the
    // world it grades is the one every other arm's closing round grades.
    let opening = if arm.probe_rounds > 1 {
        let pairs = crate::scenarios::chain_pairs(world);
        let control = round(
            1,
            Reach::These(&pairs),
            Recovery::Undisturbed,
            tick,
            NO_GATING_ROWS,
            &[],
            &[],
        );
        grade_round(world, &control, &[Invariant::LocationRoundTrip]).await?
    } else {
        Vec::new()
    };

    let circle = world.build_extra_circle().await?;
    deafen(world, racers).await?;
    co_admin(world, &circle, alice, bob).await?;

    let canaries = match arm.label {
        "race-no-restart" => {
            no_restart(world, &circle, racers, &mut classified, &mut extra).await?
        }
        "race-restart-after-confirm" => {
            restart_after_confirm(world, &circle, racers, &mut classified, &mut extra).await?
        }
        "race-restart-before-confirm" => {
            restart_before_confirm(world, &circle, racers, &mut classified, &mut extra).await?
        }
        "race-anchor-exhausted" => {
            anchor_exhausted(world, &circle, racers, &mut classified).await?
        }
        _ => return Err(RigError::UnknownTarget),
    };
    rehear(world, racers).await?;

    // Graded over the WORLD's circles, which no arm here touches. The device
    // that was restarted sends first: its epoch and exporter state came back
    // off disk, and a reuse there is invisible to it and visible only to a peer
    // that cannot read what it produced.
    let pairs = closing_pairs(world, bob);
    let opened = [alice, bob];
    let closing = round(
        2,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &opened,
        &classified,
    );
    let mut graded = grade_round(
        world,
        &closing,
        &[
            Invariant::Quiescence,
            Invariant::Undecryptable,
            Invariant::LocationRoundTrip,
            Invariant::SendPathLiveness,
        ],
    )
    .await?;
    graded.extend(opening);
    graded.extend(extra);

    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// The control: a race and nothing else, which must converge.
///
/// It is what proves the other three arms' interruptions are the variable. The
/// engine's `CommitOrderingKey` reorg costs exactly one branch — one device
/// applies the winner, the other's own confirmed commit is withdrawn by its
/// stamped origin — and both end on one branch.
async fn no_restart<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    circle: &SimCircle,
    racers: (DeviceTag, DeviceTag),
    classified: &mut Vec<undecryptable::Verdict>,
    extra: &mut Vec<(Invariant, Verdict)>,
) -> Result<usize, RigError> {
    let mut canaries = 0_usize;
    let stage = stage_race(world, circle, racers, SecondCommit::Confirmed).await?;
    // 1. Both devices really staged from ONE epoch and both commits were really
    //    acknowledged. Without that there is no race, only two commits.
    if stage.genuine {
        canaries += 1;
    }
    let verdicts = merge_race(world, circle, racers, &stage).await?;
    classified.extend(verdicts.iter().copied());
    // 2. Exactly one branch is lost, and exactly one commit applies. Which side
    //    loses is the engine's content-derived ordering, never this arm's to
    //    name.
    if one_branch_lost(&verdicts) {
        canaries += 1;
    }
    let branches = branch_state(world, circle, racers).await?;
    classified.extend(branches.classified());
    // 3. …and the two devices end on ONE branch, cross-decrypt and all.
    if branches.converged() {
        canaries += 1;
    }
    grade_convergence(circle, &branches, extra);
    Ok(canaries)
}

/// The same race, with the second device rebuilt from disk between its own
/// confirm and the merge.
///
/// A restart clears the in-memory `we_committed_from` guard, so the sibling
/// takes the STORED convergence route rather than the direct fork-recovery one
/// — and upstream's own
/// `rebuilt_engine_convergence_withdraws_own_confirmed_rename_by_stamped_origin`
/// asserts both devices still settle on the winner.
///
/// That change of route changes what the LOSER's refusal looks like, which is
/// why canary 3 is the weaker of the two branch predicates here (see
/// [`exactly_one_branch_survived`]). The outcome it does not change is the one
/// the arm is about, and that one is GRADED rather than counted.
async fn restart_after_confirm<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    circle: &SimCircle,
    racers: (DeviceTag, DeviceTag),
    classified: &mut Vec<undecryptable::Verdict>,
    extra: &mut Vec<(Invariant, Verdict)>,
) -> Result<usize, RigError> {
    let mut canaries = 0_usize;
    let stage = stage_race(world, circle, racers, SecondCommit::Confirmed).await?;
    // 1. The race is genuine.
    if stage.genuine {
        canaries += 1;
    }
    // 2. …and the restart really happened: the session was held, released and
    //    retaken (Rule 14, asserted inside `kill_and_reopen`), and the device
    //    came back at the epoch its own confirmed commit left it — read off
    //    disk, its in-memory guard gone with the process.
    let confirmed_at = epoch_of(world, racers.1, circle).await?;
    kill_and_reopen(world.device_mut(racers.1)?, KillKind::Hard).await?;
    if epoch_of(world, racers.1, circle).await? == confirmed_at {
        canaries += 1;
    }
    let verdicts = merge_race(world, circle, racers, &stage).await?;
    classified.extend(verdicts.iter().copied());
    // 3. Exactly one sibling survives, and the refusal of the other is one the
    //    classifier accounts for.
    if exactly_one_branch_survived(&verdicts) {
        canaries += 1;
    }
    let branches = branch_state(world, circle, racers).await?;
    classified.extend(branches.classified());
    // 4. …and both end on one branch.
    if branches.converged() {
        canaries += 1;
    }
    grade_convergence(circle, &branches, extra);
    Ok(canaries)
}

/// The kill lands between the relay's acknowledgement and the local confirm:
/// the relay holds the second commit, the device never saw the `OK`, and the
/// process that staged it is gone.
///
/// # What the reopen does with it
///
/// The commit was staged with its durable fanout row, so MDK's hydrate
/// restores it as it was — staged, under its own pending ref — instead of
/// clearing it. The circle's send path is therefore STILL shut after the
/// reopen (canary 2), and what holds it is one pending fanout carrying the
/// very event the relay stored. The product's driver then sends that event
/// again, byte for byte, once its relay is due — a wait this arm steps the
/// driver's pacing clock over rather than sits through — and applies the
/// commit on the relay's answer. The arm stops there if it does not: a
/// device that cannot finish its own acknowledged commit has no race to
/// grade.
///
/// A commit cleared at the open instead — the shape this arm had while the
/// rig published commits itself and dropped the pending ref — is merged by
/// the reopened device's first convergence pass on its own, whatever its
/// peer holds, which is how the two devices used to end on two branches
/// wearing one epoch number.
///
/// # Both commits reach both devices
///
/// Both are on the relay, so each device is handed the other's, and the
/// promise is the one every other arm here grades: exactly one branch
/// survives, on both devices.
async fn restart_before_confirm<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    circle: &SimCircle,
    racers: (DeviceTag, DeviceTag),
    classified: &mut Vec<undecryptable::Verdict>,
    extra: &mut Vec<(Invariant, Verdict)>,
) -> Result<usize, RigError> {
    let mut canaries = 0_usize;
    swallow_acks(world, racers.1, true).await?;
    let stage = stage_race(world, circle, racers, SecondCommit::LeftStaged).await?;
    swallow_acks(world, racers.1, false).await?;
    let id = stage
        .left_staged
        .clone()
        .ok_or(RigError::Core(Step::StageCommit))?;
    // 1. The window is real: a relay holds the commit, the device was never
    //    told, AND the circle's own send path is held shut while it is staged.
    if stage.genuine && !can_send(world, racers.1, circle).await? {
        canaries += 1;
    }

    kill_and_reopen(world.device_mut(racers.1)?, KillKind::Hard).await?;

    // 2. The staged commit survived the process: the send path is STILL shut,
    //    and what holds it is one pending fanout with the staged commit's id.
    if !can_send(world, racers.1, circle).await?
        && holds_only(world, racers.1, circle, &id, &stage.second).await?
    {
        canaries += 1;
    }
    resume(world, racers.1, circle, &id).await?;

    let verdicts = merge_race(world, circle, racers, &stage).await?;
    classified.extend(verdicts.iter().copied());
    // 3. The second commit was acknowledged before the kill, so it is a real
    //    branch on the relay, and the reopened device has applied it. Once
    //    each side holds the other's commit the race costs exactly one branch,
    //    whichever the engine's content-derived ordering picks.
    if one_branch_lost(&verdicts) {
        canaries += 1;
    }
    let branches = branch_state(world, circle, racers).await?;
    classified.extend(branches.classified());
    // 4. …and both devices end on one branch.
    if branches.converged() {
        canaries += 1;
    }
    grade_convergence(circle, &branches, extra);
    Ok(canaries)
}

/// Whether `device` holds exactly one fanout for `circle`: `id`, pending, and
/// carrying `commit`.
async fn holds_only<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: &SimCircle,
    id: &FanoutId,
    commit: &Event,
) -> Result<bool, RigError> {
    let session = world.device(device)?.session()?;
    let rows = session
        .fanout_ids_for_test(circle.mls_group_id())
        .await
        .map_err(|_| RigError::Core(Step::ReadEpoch))?;
    let row = session
        .fanout_probe_for_test(id)
        .await
        .map_err(|_| RigError::Core(Step::ReadEpoch))?;
    Ok(rows.as_slice() == std::slice::from_ref(id)
        && row.is_some_and(|row| row.event_id == commit.id && row.mls == FanoutMls::Pending))
}

/// Resumes `device`'s pending commit fanouts for `circle` through the
/// product's driver: asks it what is due, steps its pacing clock over the
/// wait it names, and lets it send.
///
/// # Errors
///
/// [`RigError::PublishNeverAcked`] if the commit `id` names is not applied
/// afterwards; [`RigError`] naming the step that failed otherwise.
async fn resume<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: &SimCircle,
    id: &FanoutId,
) -> Result<(), RigError> {
    let device = world.device(device)?;
    let transport = device.fanout_transport();
    let clock = PacingClock::default();
    let group = Some(circle.mls_group_id());
    for _ in 0..2 {
        let due = drive_due(
            device.manager()?,
            &transport,
            &clock,
            group,
            None,
            &DriveMode::Full,
        )
        .await;
        if due.error.is_some() {
            return Err(RigError::Core(Step::ConfirmPublished));
        }
        if due
            .driven
            .iter()
            .any(|(driven, outcome)| driven == id && outcome.status == FanoutStatus::Confirmed)
        {
            return Ok(());
        }
        clock.step(due.retry_after_ms.unwrap_or(0));
    }
    Err(RigError::PublishNeverAcked)
}

/// The recorded known-bad: each branch walks past the distance at which a
/// sibling can still be converged, and the two devices are left forked.
///
/// # The distance, and which bound really fires at this pin
///
/// `max_rewind_commits()` is READ from the policy the session installs
/// (`haven-core`'s `max_rewind_commits`), never restated: the horizon and the
/// retained anchor are pruned at exactly that distance, so `rewind + 1` advances
/// on each branch trips both terms together. What the arm then MEASURES at this
/// engine is a peel failure rather than the epoch-state fall-through: the
/// session's exporter retention (`DEFAULT_MAX_PAST_EPOCHS`) is the SAME 5, so
/// any distance that exhausts the anchor has already exhausted the secret the
/// sibling's outer layer is keyed with. Both are refusals to converge and both
/// leave the twin fork this arm records; the arm keys on the fork, not on which
/// of the two coincident bounds answered first.
///
/// # Recorded expectation, tied to OD-1
///
/// A twin fork is the one failure with no Haven-side symptom: both devices
/// report the same epoch, the same roster and a healthy send path, and only a
/// cross-decrypt says otherwise. There is no peer epoch on the wire, so the only
/// detector Haven could have is receive silence past the delivery-silence
/// window. OD-1 is BUILT (one per-circle card in the circle's details sheet,
/// read from `circle_recovery`, which no arm reads yet); this arm records the
/// silence — an empty `unrecoverable_circles()` and no `GroupUnrecoverable` on
/// either bus — rather than grading it, so the day a verdict starts appearing
/// the canary is unmet and the arm goes rc 3, which is the correct signal: the
/// recorded expectation must be replaced by a graded one in the same commit.
/// The 684-second form of that silence is asserted by S03's weekly arm
/// `lost-commit-unnamed`; a second eleven-minute absence here would buy no
/// further claim, which is why every arm in this scenario declares
/// `Absence::None`.
async fn anchor_exhausted<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    circle: &SimCircle,
    racers: (DeviceTag, DeviceTag),
    classified: &mut Vec<undecryptable::Verdict>,
) -> Result<usize, RigError> {
    let mut canaries = 0_usize;
    let stage = stage_race(world, circle, racers, SecondCommit::Confirmed).await?;
    // 1. The race is genuine.
    if stage.genuine {
        canaries += 1;
    }

    let distance = max_rewind_commits() + 1;
    let before = (
        epoch_of(world, racers.0, circle).await?,
        epoch_of(world, racers.1, circle).await?,
    );
    walk_branch(world, racers.0, circle, distance, "a").await?;
    walk_branch(world, racers.1, circle, distance, "b").await?;
    let after = (
        epoch_of(world, racers.0, circle).await?,
        epoch_of(world, racers.1, circle).await?,
    );
    // 2. Both branches really walked the distance that exhausts the rewind
    //    horizon and the retained anchor together — read at runtime, so an
    //    engine that widened the window moves the arm rather than breaking it.
    if after.0 - before.0 >= distance && after.1 - before.1 >= distance {
        canaries += 1;
    }

    kill_and_reopen(world.device_mut(racers.1)?, KillKind::Hard).await?;

    let verdicts = merge_race(world, circle, racers, &stage).await?;
    classified.extend(verdicts.iter().copied());
    // 3. Neither sibling converges, and every refusal is one the classifier
    //    ACCOUNTS for: a defect here would mean the arm recorded an expectation
    //    nothing can explain.
    if verdicts.len() == 2
        && verdicts.iter().all(|verdict| {
            !matches!(
                verdict,
                undecryptable::Verdict::Applied | undecryptable::Verdict::Defect(_)
            )
        })
    {
        canaries += 1;
    }
    let branches = branch_state(world, circle, racers).await?;
    classified.extend(branches.classified());
    // 4. The twin fork itself: one epoch, one roster, and no cross-decrypt in
    //    either direction. Asserted as the EXPECTED outcome and never graded —
    //    if the fork stops happening, this canary is unmet and the arm is rc 3,
    //    "the recorded expectation is stale".
    if branches.twin_fork() {
        canaries += 1;
    }
    // 5. …and no surface the rig reads says anything about it, recorded.
    if silent_about_the_fork(world, racers).await {
        canaries += 1;
    }
    Ok(canaries)
}

/// Whether neither racer reports the circle as unrecoverable, on either surface.
async fn silent_about_the_fork<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    racers: (DeviceTag, DeviceTag),
) -> bool {
    for tag in <[DeviceTag; 2]>::from(racers) {
        let Ok(device) = world.device(tag) else {
            return false;
        };
        let quiet = device.ledger().unrecoverable() == 0
            && match device.manager() {
                Ok(manager) => manager.unrecoverable_circles().await.is_empty(),
                Err(_) => false,
            };
        if !quiet {
            return false;
        }
    }
    true
}

/// Grades the convergence the three convergent arms assert.
///
/// A fork in any of them is a finding about the SUBJECT rather than an arm that
/// proved nothing, so it is graded at rc 1 rather than counted as an unmet
/// canary. The registry's own O1 cannot see it: that oracle probes the WORLD's
/// circles, and this scenario's circle is deliberately outside them — so the
/// arm grades the same promise, in the same vocabulary, over its own.
///
/// The three shapes are distinguished because they send a reader to three
/// different places: disagreeing epochs read as a catch-up bug, disagreeing
/// rosters as a membership one, and two branches wearing ONE epoch number as
/// neither — which is why that last one has a finding of its own.
fn grade_convergence(
    circle: &SimCircle,
    branches: &BranchState,
    extra: &mut Vec<(Invariant, Verdict)>,
) {
    if branches.converged() {
        return;
    }
    let finding = if branches.same_epoch && branches.same_roster {
        Finding::BranchDiverged { circle: circle.tag }
    } else if branches.same_epoch {
        Finding::RosterDiverged { circle: circle.tag }
    } else {
        Finding::EpochDiverged { circle: circle.tag }
    };
    extra.push((Invariant::LocationRoundTrip, Verdict::Failed(finding)));
}

/// Whether exactly one sibling survived, whichever way the loser was refused.
///
/// A restart changes the SHAPE of the refusal without changing the outcome, and
/// this is the predicate that spans both. A device that still holds its
/// in-memory `we_committed_from` guard takes the direct fork-recovery route and
/// reports the losing sibling as a past-epoch branch loss; a rebuilt one takes
/// STORED convergence, where a losing sibling is a dropped message and the
/// engine reported it as a peel failure (measured at `e391adc`: six runs in ten,
/// tracking which branch the content-derived ordering picked). Both mean "one
/// branch, and it is not this one".
fn exactly_one_branch_survived(verdicts: &[undecryptable::Verdict]) -> bool {
    verdicts.len() == 2
        && verdicts
            .iter()
            .filter(|verdict| **verdict == undecryptable::Verdict::Applied)
            .count()
            == 1
        && !verdicts
            .iter()
            .any(|verdict| matches!(verdict, undecryptable::Verdict::Defect(_)))
}

/// Whether exactly one of the two dispositions applied and exactly one lost a
/// branch.
///
/// The stronger form of [`exactly_one_branch_survived`], and the one the
/// uninterrupted race really does produce every time: with both devices' own
/// `we_committed_from` guard intact, the loser goes through fork recovery and
/// its row is the branch-loss disposition in so many words.
fn one_branch_lost(verdicts: &[undecryptable::Verdict]) -> bool {
    let applied = verdicts
        .iter()
        .filter(|verdict| **verdict == undecryptable::Verdict::Applied)
        .count();
    let lost = verdicts
        .iter()
        .filter(|verdict| {
            matches!(
                verdict,
                undecryptable::Verdict::PastEpochOrBranchLoss { .. }
            )
        })
        .count();
    applied == 1 && lost == 1
}

/// Advances one device's OWN branch by `count` confirmed commits.
async fn walk_branch<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: &SimCircle,
    count: u64,
    salt: &str,
) -> Result<(), RigError> {
    for index in 0..count {
        let mut relays = world.relay_urls();
        relays.push(format!("wss://s14-walk-{salt}-{index}.example.com"));
        let (_, verdict) = relay_update(world, device, circle, &relays).await?;
        if verdict != PublishVerdict::Confirmed {
            return Err(RigError::PublishNeverAcked);
        }
    }
    Ok(())
}

/// Whether `device` can encrypt for `circle` right now.
///
/// The product's own read of "is this circle's outbound path open": a staged
/// commit holds it shut until Rule 13 says what happened to the publish.
async fn can_send<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: &SimCircle,
) -> Result<bool, RigError> {
    Ok(seal(world, device, circle, 3).await.is_ok())
}

/// Seals one location for `circle` at `device`'s current epoch, unpublished.
async fn seal<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: &SimCircle,
    index: u32,
) -> Result<Event, RigError> {
    let sender = world.device(device)?;
    sender
        .manager()?
        .seal_location_for_test(
            circle.mls_group_id(),
            &ProbeToken::mint(14, index).as_location(),
        )
        .await
        .map(|(event, _, _)| event)
        .map_err(|_| RigError::Core(Step::Publish))
}

/// One device's epoch for one circle.
async fn epoch_of<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: &SimCircle,
) -> Result<u64, RigError> {
    world
        .device(device)?
        .manager()?
        .group_epoch(circle.mls_group_id())
        .await
        .map_err(|_| RigError::Core(Step::ReadEpoch))
}

/// One device's converged roster for one circle, sorted.
async fn roster_of<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: &SimCircle,
) -> Result<Vec<String>, RigError> {
    let roster = world
        .device(device)?
        .session()?
        .converged_member_pubkeys(circle.mls_group_id())
        .await
        .map_err(|_| RigError::Core(Step::ReadRoster))?;
    let ConvergedRoster::Converged {
        mut member_pubkeys_hex,
        ..
    } = roster
    else {
        return Ok(Vec::new());
    };
    member_pubkeys_hex.sort();
    Ok(member_pubkeys_hex)
}

#[cfg(test)]
mod tests {
    use super::ARMS;
    use crate::oracle::Recovery;

    #[test]
    fn every_arm_pays_for_the_racers_engines_starting_again() {
        for arm in &ARMS {
            assert!(
                arm.resubscribes,
                "both racers' engines are stopped for the race and started after it, \
                 re-opening their REQs, so the ladder is in every bound"
            );
        }
        for arm in &ARMS {
            assert!(
                arm.recovery == Recovery::Undisturbed,
                "no endpoint is unplugged in this scenario"
            );
            assert!(
                arm.floor.faults_applied == 0,
                "a commit race is not something a relay does"
            );
        }
    }

    #[test]
    fn every_arm_declares_no_epoch_floor_and_carries_the_claim_as_a_canary() {
        // The race runs in a circle outside the world's table, which is what
        // keeps the forked arm from reddening a lane — and what puts its epochs
        // beyond the reach of `Observed::measure`. Each arm asserts the epoch
        // distance it crossed itself.
        for arm in &ARMS {
            assert!(
                arm.floor.epochs_crossed == 0,
                "a term that cannot see this scenario's circle may not be declared \
                 as if it could"
            );
            assert!(
                arm.floor.canaries_caught >= 3,
                "every arm carries its own premise, its own interruption and its own outcome"
            );
        }
    }

    #[test]
    fn the_known_bad_arm_demands_one_more_observation_than_the_convergent_ones() {
        assert!(
            ARMS[3].floor.canaries_caught == 5,
            "the race, the distance, the two refusals, the twin fork and Haven's silence about it"
        );
        for arm in &ARMS[..3] {
            assert!(
                arm.floor.canaries_caught < ARMS[3].floor.canaries_caught,
                "only the recorded arm asserts the fork and the absent verdict"
            );
        }
    }
}
