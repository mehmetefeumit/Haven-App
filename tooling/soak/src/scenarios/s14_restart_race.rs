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
//! keeps the circle out of `world.circles()`, which buys two things at once. No
//! world-wide oracle grades it, so the forked arm cannot redden a lane for
//! behaviour the product is known to have; and no device's engine subscribes to
//! it, so the siblings reach a peer only when this module hands them over —
//! which is what makes "neither device has ingested the other's commit" a
//! property of the arm rather than of a pause that has to be timed. The world's
//! own circles are untouched by every arm and are what the closing round grades.
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

use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::nostr::mls::max_rewind_commits;
use haven_core::nostr::mls::types::{ConvergedRoster, OpenMlsContentKind, PendingStateRef};
use nostr::Event;

use crate::oracle::undecryptable::{self, Probe, StoredRow};
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{Finding, Invariant, ProbeToken, Reach, Recovery, Verdict};
use crate::rig::{
    kill_and_reopen, DeviceTag, KillKind, LogDrain, PublishVerdict, RigError, SimCircle, Step,
    TimelineSink,
};
use crate::scenarios::{
    closing_pairs, grade_round, hand_off_admin, round, Absence, Arm, ArmOutcome, ScenarioWorld,
    WithheldAcks, NO_GATING_ROWS,
};

/// The arms this scenario offers.
pub const ARMS: [Arm; 4] = [
    Arm {
        label: "race-no-restart",
        recovery: Recovery::Undisturbed,
        probe_rounds: 2,
        // Nothing restarts, so no device re-opens a REQ.
        resubscribes: false,
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
        withheld_acks: WithheldAcks::None,
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
    /// acknowledged — the premise without which nothing below is a race.
    pub genuine: bool,
}

/// What the second device does with its own staged commit.
///
/// No `Debug`, like everything else here: a knob nothing renders needs no
/// rendering, and every one this crate defines has to carry a sample.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum SecondCommit {
    /// Published, acknowledged and confirmed, like the first.
    Confirmed,
    /// Published and acknowledged, and then deliberately left staged, so a
    /// caller can end the process inside the publish→confirm window.
    LeftStaged,
}

/// Makes `successor` a co-admin of `circle` and applies the handoff on its own
/// engine.
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
    // The successor's own engine has to have APPLIED the handoff before it can
    // use it, and nothing delivers this circle: it is deliberately outside the
    // world's table, so no engine subscribes to it.
    world
        .device(successor)?
        .session()?
        .process_event_typed_for_test(&commit)
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
/// `circle` must be one no engine subscribes to (an extra circle), or the live
/// plane delivers the first commit to the second device before it stages: the
/// engine records every message's disposition, and the second look at one MLS
/// message is a duplicate, so a race ingested live would classify as one.
///
/// [`SecondCommit::LeftStaged`] drops the second pending state ON PURPOSE. The
/// caller is about to end the process that owns it, which IS the resolution in
/// the only sense left — nothing can confirm or roll back a ref that died with
/// its process — and the rig's staged-commit count may not outlive this call, or
/// the caller's own closing round could never settle.
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
    let group = circle.mls_group_id().clone();
    let (first_tag, second_tag) = racers;
    let mut commits: Vec<Event> = Vec::with_capacity(2);
    let mut staged_from: Vec<u64> = Vec::with_capacity(2);
    let mut acked = true;

    for (index, tag) in [first_tag, second_tag].into_iter().enumerate() {
        staged_from.push(epoch_of(world, tag, circle).await?);
        // A relay list the circle does not already hold: a repeat is a no-op,
        // and a no-op advances no epoch and stages no branch.
        let mut relays = world.relay_urls();
        relays.push(format!("wss://s14-race-{index}.example.com"));
        let staged = world
            .device(tag)?
            .manager()?
            .update_circle_relays(&group, &relays)
            .await
            .map_err(|_| RigError::Core(Step::StageCommit))?;
        let commit = staged.commit_event.clone();
        let guard = world.note_pending_staged();
        let witnessed = world
            .publish_witnessed(tag, std::slice::from_ref(&commit))
            .await?;
        acked &= witnessed.is_some();
        if witnessed.is_none() {
            // Rule 13: nothing was acknowledged, so the commit may not be
            // merged. Roll it back rather than leaving a ref nobody resolves,
            // and report that the arm has no race to grade.
            let ingest = world
                .device(tag)?
                .manager()?
                .publish_failed(staged.pending)
                .await
                .map_err(|_| RigError::Core(Step::RollBackPublish))?;
            world.resolve_ingest(tag, ingest).await?;
            drop(guard);
            return Err(RigError::PublishNeverAcked);
        }
        if tag == second_tag && second == SecondCommit::LeftStaged {
            let _: PendingStateRef = staged.pending;
            commits.push(commit);
            drop(guard);
            continue;
        }
        let ingest = world
            .device(tag)?
            .manager()?
            .finalize_relay_update(staged.pending, &group)
            .await
            .map_err(|_| RigError::Core(Step::ConfirmPublished))?;
        world.resolve_ingest(tag, ingest).await?;
        drop(guard);
        commits.push(commit);
    }

    let [first, second_commit] = commits
        .try_into()
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    Ok(RaceStage {
        first,
        second: second_commit,
        genuine: acked && staged_from.first() == staged_from.last(),
    })
}

/// One device ingests one sibling commit, exactly once, classified.
///
/// The stored row is located AFTER the ingest and never before: the engine keys
/// every row on its hash over the PEELED MLS bytes, so a caller holding only the
/// signed event cannot name the row its own ingest is about to write. Without
/// that row an `AlreadyAtEpoch` disposition is undetermined rather than
/// cheerfully "no branch was lost", which would under-report forks.
///
/// # Errors
///
/// [`RigError`] naming the read that failed.
pub async fn ingest_sibling<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    circle: &SimCircle,
    ingester: DeviceTag,
    sibling: &Event,
) -> Result<undecryptable::Verdict, RigError> {
    let session = world.device(ingester)?.session()?;
    let outcome = session.process_event_typed_for_test(sibling).await;
    let probe = match session
        .stored_convergence_input_for_test(circle.mls_group_id(), OpenMlsContentKind::Commit, 1)
        .await
    {
        Ok(record) => session
            .stored_message_record_for_test(&record.id)
            .await
            .map_or(Probe::Unreadable, Probe::Read),
        Err(_) => Probe::Read(None),
    };
    Ok(undecryptable::classify_ingest(&outcome, probe))
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

    // Graded over the WORLD's circles, which no arm here touches. The device
    // that was restarted sends first: its epoch and exporter state came back
    // off disk, and a reuse there is invisible to it and visible only to a peer
    // that cannot read what it produced.
    let pairs = closing_pairs(world, bob);
    let opened = [bob];
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
    //    retaken (Rule 14, asserted inside `kill_and_reopen`), and the engine
    //    came back with it.
    let report = kill_and_reopen(world.device_mut(racers.1)?, KillKind::Hard).await?;
    if report.engine_restarted {
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

/// The kill lands between SEND and confirm, so the group never advanced and the
/// staged commit outlives the process that staged it.
///
/// # What the reopen does with it, and what this arm can actually see
///
/// The engine's hydrate clears such a commit transactionally and rewinds the
/// group to its pre-stage epoch, pushing a `PendingCommitRecovered` event into
/// its buffer. That event is NOT delivered by the reopen: it surfaces on the
/// first session call that collects effects, and in a world whose engine
/// restarts with the device, the engine's own processor is a receive path and
/// gets there first — so the event itself is not deterministically observable
/// from an arm. What IS observable, and is what canary 2 reads, is the rewind's
/// own consequence: the circle's send path was gated while the commit was
/// staged and is open again after the reopen. Nothing else could have opened it
/// — the `PendingStateRef` that could have confirmed or rolled the commit back
/// died with the process.
///
/// # What this arm deliberately does NOT deliver, and why
///
/// The abandoned commit is never handed to the peer. It really was published, so
/// a live circle's peer really would receive it — and at this engine the peer's
/// fork resolver may pick EITHER branch by its content-derived ordering, while
/// the device that staged it has already discarded it. Which side wins is then a
/// fresh coin toss per run, and an arm that asserted either outcome would be
/// flaky rather than informative. What this arm claims is the RESTARTED device's
/// own disposition; the peer's is an open question and is recorded as one.
async fn restart_before_confirm<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    circle: &SimCircle,
    racers: (DeviceTag, DeviceTag),
    classified: &mut Vec<undecryptable::Verdict>,
    extra: &mut Vec<(Invariant, Verdict)>,
) -> Result<usize, RigError> {
    let mut canaries = 0_usize;
    let stage = stage_race(world, circle, racers, SecondCommit::LeftStaged).await?;
    // 1. The window is real: the commit crossed the wire and was acknowledged,
    //    AND the circle's own send path is held shut while it is staged.
    if stage.genuine && !can_send(world, racers.1, circle).await? {
        canaries += 1;
    }

    kill_and_reopen(world.device_mut(racers.1)?, KillKind::Hard).await?;

    // 2. The staged commit did not survive the process: the send path is open
    //    again, which only the hydrate's clear-and-rewind can have done.
    if can_send(world, racers.1, circle).await? {
        canaries += 1;
    }
    let verdict = ingest_sibling(world, circle, racers.1, &stage.first).await?;
    classified.push(verdict);
    // 3. The rewind put the device back at the epoch the sibling was sealed
    //    from, so the sibling arrives at `msg_epoch == current_epoch` and
    //    APPLIES rather than being refused as a past epoch.
    if verdict == undecryptable::Verdict::Applied {
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
/// window. OD-1 is DECIDED and NOT BUILT; this arm records the silence — an
/// empty `unrecoverable_circles()` and no `GroupUnrecoverable` on either bus —
/// rather than grading it, so the day a verdict starts appearing the canary is
/// unmet and the arm goes rc 3, which is the correct signal: the recorded
/// expectation must be replaced by a graded one in the same commit. The 684-
/// second form of that silence is OWED TO S03's weekly arm, which is not yet
/// built; a second eleven-minute absence here would buy no further claim, which
/// is why every arm in this scenario declares `Absence::None`.
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
    // 5. …and Haven says nothing about it. The OD-1 gap, recorded.
    if silent_about_the_fork(world, racers) {
        canaries += 1;
    }
    Ok(canaries)
}

/// Whether neither racer reports the circle as unrecoverable, on either surface.
fn silent_about_the_fork<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    racers: (DeviceTag, DeviceTag),
) -> bool {
    [racers.0, racers.1].into_iter().all(|tag| {
        world.device(tag).is_ok_and(|device| {
            device.ledger().unrecoverable() == 0
                && device
                    .manager()
                    .is_ok_and(|manager| manager.unrecoverable_circles().is_empty())
        })
    })
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
/// engine reports it as a peel failure (measured at this pin: six runs in ten,
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
    let group = circle.mls_group_id().clone();
    for index in 0..count {
        let mut relays = world.relay_urls();
        relays.push(format!("wss://s14-walk-{salt}-{index}.example.com"));
        let staged = world
            .device(device)?
            .manager()?
            .update_circle_relays(&group, &relays)
            .await
            .map_err(|_| RigError::Core(Step::StageCommit))?;
        let commit = staged.commit_event.clone();
        let verdict = world
            .publish_and_confirm(device, staged.pending, std::slice::from_ref(&commit))
            .await?;
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
        .encrypt_location(
            circle.mls_group_id(),
            &sender.keys.public_key(),
            &ProbeToken::mint(14, index).as_location(),
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
    fn the_control_arm_restarts_nothing_and_the_other_three_do() {
        assert!(
            !ARMS[0].resubscribes,
            "the control's whole content is that nothing was interrupted"
        );
        for arm in &ARMS[1..] {
            assert!(
                arm.resubscribes,
                "a restarted device re-opens its own REQs, so the ladder is in the bound"
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
