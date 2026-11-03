//! **S05** — the publish→confirm window, and what a failure inside it is NOT.
//!
//! Security Rule 13's newest clause has one shape and it is counter-intuitive:
//! an `Err` from `confirm_published` is **not** a publish failure. The relay
//! acknowledged the commit, the engine may already have merged it, and only the
//! replay that follows the merge failed — so rolling the commit back would
//! discard a commit the group may already have, and retrying it would apply one
//! twice. The disposition is: fold what the failing call already delivered,
//! return the original error, and leave the staged commit exactly as staged.
//!
//! # What the rig adds over the unit pin
//!
//! `haven-core`'s own `commit_gap_replay_e2e` proves the fold and
//! `security_rule_gates` pins the rung. What this arm adds is the same
//! disposition over a real relay: a commit that a relay really acknowledged, a
//! peer fix that really crossed a real MLS session, and a device that goes on
//! serving every other circle afterwards.
//!
//! # The victim circle is not one of the world's, and it stays staged
//!
//! A confirm that fails mid-replay leaves the group in its publish-before-apply
//! transition — measured, and asserted here as canary 5, because that is exactly
//! what a rollback would have undone. A circle in that state refuses sends, so
//! it may not be one a world-wide oracle grades: the arm would then be reporting
//! a violation Rule 13 itself requires. Both circles this arm uses are built
//! with `build_extra_circle`, which keeps them out of `world.circles()` for that
//! reason — and it is also why this arm declares `epochs_crossed: 0`, since
//! `Observed::measure` walks the world's table and cannot see them.
//!
//! # A kill inside the window
//!
//! `kill-send-plane` kills a device between SEND and confirm: the relay has the
//! commit, the device never heard so, and the process goes. A restart here is a
//! clean cancel, not a SIGKILL — the worker's panic-isolation spawn runs to
//! completion and no WAL is torn; torn-storage fidelity is Tier 2's `avd
//! snapshot` nemesis. A green arm is therefore coverage of a process-lifetime
//! restart, which is what clears the engine's in-memory state, and never of a
//! torn store.
//!
//! Rule 14 is kept the way `rig/restart.rs` keeps it: the key is the
//! `session.sqlite` file path, never the directory; the session is asserted live
//! BEFORE the drop; the engine AND the harness's `Arc<CircleManager>` are
//! dropped; the release is bounded-polled to false and its latency recorded
//! (`Restarted { release_ms, reopen_ms }` — the C1 measurement); the reopen is a
//! bounded retry.
//!
//! `kill-receive-auto-commit` kills a device between the SEND and the `OK` of
//! a peer's eviction its own live engine made in the foreground — after a
//! background burst received the leave and made nothing of it — and reads
//! what the reopened device does with the record: see [`kill_receive`]. The
//! label is historical: no receive path makes that commit any more, the
//! foreground's drive does. (At MDK `e391adc` the arm was EXPECTED RED, C9.)
//!
//! `kill-sweep-eviction` kills a device after a wake sweep took a departure in
//! — the sweep makes no commit, so there is no window to kill it in — and
//! reads the foreground's drive making the eviction: see [`kill_sweep`].
//!
//! # The OD4-c verdict must stay silent where nothing is wedged
//!
//! `negative-gates-silent` induces, in one world holding one staged eviction,
//! each of the five states `od4c_removal_deferral_e2e.rs` pins as NOT a wedge,
//! and reads the verdict at each of them — five canaries, one arm. A single read
//! at the end would pass on a verdict that fired spuriously and cleared.

use std::time::Duration;

use haven_core::circle::CircleError;
use haven_core::nostr::mls::storage::{set_stored_message_write_fault_for_test, StorageConfig};
use haven_core::nostr::mls::types::{EpochState, GroupId};
use haven_core::relay::catchup::run_catchup_all_circles;
use haven_core::relay::fanout::{FanoutClock as _, WallClock};
use haven_core::relay::live_sync::{
    GroupProcessOutcome, Lifecycle, LiveSyncEvent, StopOutcome, SyncStatusReason,
};
use nostr::{Event, Kind};
use tokio::sync::broadcast::error::TryRecvError;
use tokio::sync::broadcast::Receiver;
use tokio::time::Instant;

use crate::nemesis::types::{DropClass, Fault};
use crate::oracle::undecryptable::{classify_send, Verdict as Classification};
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{bounds, Invariant, ProbeToken, Reach, Recovery};
use crate::rig::{
    kill_and_reopen, DeviceTag, KillKind, LogDrain, PacingClock, PublishVerdict, RelayPlane,
    ReopenReport, RigError, SimCircle, Step, TimelineRecord, TimelineSink,
    AFTER_KILL_REMOVAL_PUBLISHED, AFTER_KILL_REMOVAL_REPORTED, AFTER_KILL_SENDS_RESUMED,
    AFTER_KILL_SEND_CLASSIFIED,
};
use crate::scenarios::{
    await_condition, closing_pairs, drive_until_settled, grade_round, pending_record, relay_update,
    round, surface_eviction, Absence, Arm, ArmOutcome, Scenario, ScenarioReport, ScenarioWorld,
    WithheldAcks, NO_GATING_ROWS,
};

/// The arms this scenario offers.
pub const ARMS: [Arm; 5] = [
    Arm {
        label: "confirm-err-is-not-a-failure",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        // Nothing restarts and nothing pauses: the failure is a storage fault
        // inside one call.
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            // A storage fault is not something a relay plane does, so the plane's
            // own counter must stay at zero: an arm that reported one here would be
            // counting a fault it never applied.
            faults_applied: 0,
            // Both circles are outside the world's table (see the module docs), so
            // this term cannot see their epochs and the canaries carry the claims.
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 5,
        },
    },
    Arm {
        label: "kill-send-plane",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        // The killed device's engine re-opens every REQ it held.
        resubscribes: true,
        absence: Absence::None,
        // The one commit the kill lands behind.
        withheld_acks: WithheldAcks::Fixed(1),
        floor: ExpectationFloor {
            faults_applied: 1,
            // The victim circle is outside the world's table (see
            // [`kill_send_plane`]), so this term cannot see it: its epoch
            // claims are canaries, and its acked twin is a precondition.
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 4,
        },
    },
    Arm {
        label: "kill-receive-auto-commit",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: true,
        absence: Absence::None,
        // The one send of the eviction the kill cuts: its record is sent
        // again when its relay is next due.
        withheld_acks: WithheldAcks::FanoutResends(1),
        floor: ExpectationFloor {
            faults_applied: 1,
            // The acked twin: a world circle's commit the reopened device
            // takes. The wedged circle itself is outside the world's table.
            epochs_crossed: 1,
            deliveries_observed: 1,
            canaries_caught: 4,
        },
    },
    Arm {
        label: "negative-gates-silent",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        // The paused committer re-opens its REQs when it resumes.
        resubscribes: true,
        absence: Absence::None,
        // Nothing is published into a silence: the obligation is released on an
        // acked publish, and no gate needs an attempt that fails.
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            // The outage gate's endpoint.
            faults_applied: 1,
            // The future-epoch gate's commit, on one of the world's circles.
            epochs_crossed: 1,
            deliveries_observed: 1,
            canaries_caught: 5,
        },
    },
    Arm {
        label: "kill-sweep-eviction",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        // The committer's engine starts again and the paused member resumes.
        resubscribes: true,
        absence: Absence::None,
        // The sweep sends nothing into the silence: it makes no commit.
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 1,
            // The circle is outside the world's table (see [`kill_sweep`]).
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 3,
        },
    },
];

/// Runs the arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not the one this scenario
/// offers, [`RigError::PublishNeverAcked`] if no relay acknowledged the commit —
/// Rule 13 then forbids confirming it, so there is no confirm that could fail —
/// otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [admin, peer, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    match arm.label {
        "confirm-err-is-not-a-failure" => {
            let canaries = confirm_err(world, admin, peer).await?;
            // Graded over the WORLD's circles, which this arm never touches:
            // the failure is scoped to one circle's transition, and the device
            // goes on serving every other one.
            close(world, admin, tick, &[], canaries).await
        }
        "kill-send-plane" => kill_send_plane(world, admin, tick, true).await,
        "kill-receive-auto-commit" => {
            let committer = tags.get(2).copied().ok_or(RigError::ShapeMismatch)?;
            kill_receive(world, admin, peer, committer, tick, true).await
        }
        "negative-gates-silent" => {
            let committer = tags.get(2).copied().ok_or(RigError::ShapeMismatch)?;
            negative_gates(world, admin, peer, committer, tick).await
        }
        "kill-sweep-eviction" => {
            let committer = tags.get(2).copied().ok_or(RigError::ShapeMismatch)?;
            kill_sweep(world, peer, committer, tick, true).await
        }
        // A label this scenario does not offer means the dispatch table and the
        // registry disagree, which is the rig being wrong about itself.
        _ => Err(RigError::UnknownTarget),
    }
}

/// A kill arm (`label`) with every acknowledgement delivered.
///
/// The mis-configuration control in `tests/oracles.rs` runs it and requires rc
/// 3: the publish is acked, Rule 13 confirms it, and the kill that follows has
/// no publish→confirm window to land in.
///
/// # Errors
///
/// As [`run`].
pub async fn acked_kill_control<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    label: &str,
    tick: Duration,
) -> Result<ScenarioReport, RigError> {
    let started = Instant::now();
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [admin, peer, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    let (arm, outcome) = match label {
        "kill-send-plane" => (&ARMS[1], kill_send_plane(world, admin, tick, false).await?),
        "kill-receive-auto-commit" => {
            let committer = tags.get(2).copied().ok_or(RigError::ShapeMismatch)?;
            (
                &ARMS[2],
                kill_receive(world, admin, peer, committer, tick, false).await?,
            )
        }
        "kill-sweep-eviction" => {
            let committer = tags.get(2).copied().ok_or(RigError::ShapeMismatch)?;
            (
                &ARMS[4],
                kill_sweep(world, peer, committer, tick, false).await?,
            )
        }
        _ => return Err(RigError::UnknownTarget),
    };
    Ok(Scenario::PublishConfirmWindow.report(world, arm, outcome, started))
}

/// The closing round every arm ends in, over the WORLD's circles, led by the
/// device the arm disturbed.
///
/// O5 joins only when the arm classified something: a refusal handed to it is
/// graded, and a `Defect` among them is a red the arm did not get to explain
/// away.
async fn close<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    lead: DeviceTag,
    tick: Duration,
    classified: &[Classification],
    canaries: usize,
) -> Result<ArmOutcome, RigError> {
    let pairs = closing_pairs(world, lead);
    let closing = round(
        1,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &[],
        classified,
    );
    let invariants: &[Invariant] = if classified.is_empty() {
        &[
            Invariant::Quiescence,
            Invariant::LocationRoundTrip,
            Invariant::SendPathLiveness,
        ]
    } else {
        &[
            Invariant::Quiescence,
            Invariant::Undecryptable,
            Invariant::LocationRoundTrip,
            Invariant::SendPathLiveness,
        ]
    };
    let graded = grade_round(world, &closing, invariants).await?;

    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// How every kill in this scenario lands: nothing is stopped and nothing is
/// joined (decision 0.2).
const KILL: KillKind = KillKind::Hard;

/// How many paced drives a pending record gets to be confirmed in: the first
/// may find its relay not yet due again (a wait an earlier attempt earned),
/// the clock is stepped past it, and the next sends it; the third is the
/// margin for one more unanswered re-send.
const SETTLE_DRIVES: usize = 3;

/// Kills `victim` between SEND and confirm of its own relay-list commit.
///
/// # The kill kind is not what this arm measures
///
/// The commit is staged under its durable record, so what dies either way is
/// the process; the staged commit and its record outlive it on disk, and the
/// reopen restores the commit as it was. The kind is `Hard` because that is
/// the shape of the background kill C1 names, and because the release latency
/// it records is the undrained one.
///
/// # The victim circle is not one of the world's
///
/// The circle is built with `build_extra_circle`, so no world-wide oracle
/// grades a circle whose commit the arm leaves pending on purpose, and the
/// world's own circles are what the closing round grades, with the restarted
/// device sending first.
///
/// # The acked twin comes first
///
/// The same relay update on the same circle, acknowledged, must confirm and
/// advance the epoch before the withheld one is staged — otherwise every
/// canary below would hold on a circle that cannot move at all. It is a
/// precondition rather than a canary: without it the arm proves nothing, which
/// is [`RigError::PublishNeverAcked`] (rc 3), never a count one short.
async fn kill_send_plane<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    victim: DeviceTag,
    tick: Duration,
    swallow: bool,
) -> Result<ArmOutcome, RigError> {
    let circle = world.build_extra_circle().await?;
    let group = circle.mls_group_id().clone();

    let origin = epoch_of(world, victim, &group).await?;
    let (_, twin) = relay_update(
        world,
        victim,
        &circle,
        &extended_relays(world, "s05-kill-send-twin"),
    )
    .await?;
    if twin != PublishVerdict::Confirmed || epoch_of(world, victim, &group).await? <= origin {
        return Err(RigError::PublishNeverAcked);
    }

    if swallow {
        swallow_every_plane(world, Fault::SwallowOk).await?;
    }
    let (commit, verdict) = relay_update(
        world,
        victim,
        &circle,
        &extended_relays(world, "s05-kill-send"),
    )
    .await?;
    // Acked means confirmed (Rule 13), so the kill below has no window left to
    // land in. Unacknowledged, the driver keeps the commit pending under its
    // record: the relay holds it and the device never heard so.
    let window =
        verdict == PublishVerdict::Unresolved && stored_but_unacked(world, &commit).await?;

    let report = kill_and_reopen(world.device_mut(victim)?, KILL).await?;
    record_restart(world, victim, KILL, report);
    if swallow {
        swallow_every_plane(world, Fault::Heal).await?;
    }

    let mut canaries = 0_usize;
    let mut classified: Vec<Classification> = Vec::new();
    // 1. The kill landed inside the window — the relay holds the commit and no
    //    acknowledgement ever reached the device — and the process really
    //    died: the session was held, released and retaken (asserted inside
    //    `kill_and_reopen`), and the engine came back with it.
    if window && report.engine_restarted {
        canaries += 1;
    }
    // 2. Nothing the reopen found is reported unrecoverable: an unconfirmed
    //    commit that removes nobody is the engine's to clear, not a wedge.
    if world
        .device(victim)?
        .manager()?
        .unrecoverable_circles()
        .await
        .is_empty()
    {
        canaries += 1;
    }
    // 3. …nothing it left behind gates the circle, and the record outlived
    //    the process: a later drive sends the SAME event again and it is
    //    confirmed — the commit was never rolled back, and never re-staged.
    let ungated = world
        .device(victim)?
        .session()?
        .gating_input_count(&group)
        .await
        .map_err(|_| RigError::Core(Step::ReadGatingRows))?
        == 0;
    let clock = PacingClock::default();
    let landed = drive_until_settled(world, victim, &group, &clock, SETTLE_DRIVES).await?
        && world
            .relays()
            .iter()
            .any(|plane| plane.witnessed_ok(&commit.id));
    if ungated && (!swallow || landed) {
        canaries += 1;
    }
    // 4. Sends either resume or the refusal is one the classifier accounts for,
    //    and whichever it is is recorded: the catalogue's own disjunction.
    let outcome = match try_seal(world, victim, &circle, 4).await? {
        Ok(_) => {
            canaries += 1;
            AFTER_KILL_SENDS_RESUMED
        }
        Err(error) => {
            let verdict = classify_send(&error);
            classified.push(verdict);
            if !matches!(verdict, Classification::Defect(_)) {
                canaries += 1;
            }
            AFTER_KILL_SEND_CLASSIFIED
        }
    };
    world.timeline().record(TimelineRecord::AfterKill {
        tick: world.current_tick(),
        device: victim,
        circle: circle.tag,
        outcome,
    });

    close(world, victim, tick, &classified, canaries).await
}

/// The five OD4-c states that are NOT a wedge, induced in turn around one
/// staged eviction, each read at the moment it holds.
///
/// Mirrors `haven-core/tests/od4c_removal_deferral_e2e.rs`: `a_circle_awaiting
/// _its_own_ack_…` (`:828`), `a_paused_engine_…` (`:857`), `a_relay_outage_…`
/// (`:887`), `a_future_epoch_backlog_…` (`:911`) and `an_unprocessable_event_…`
/// (`:968`). The verdict is read where production reads it — the committer's
/// OWN live engine's sweep, on its own bus — plus the engine latch behind it
/// (`unrecoverable_circles()`).
///
/// # Where the soak's inductions differ from the unit tests', and why
///
/// Both no-ack gates there hand a processor a publisher that answers `false`.
/// Here nothing is published into a silence: this arm is priced with no
/// withheld acknowledgement. So "awaiting its own ack" is the eviction staged
/// under its record by the app's poll while the committer's own endpoint is
/// dark — its drive reached no relay, so nothing a relay could hold, nothing
/// acknowledged — and "a relay outage" is that endpoint staying dark while
/// the committer's engine is connected to nothing, observed by that engine.
///
/// # The staged eviction is released, and the committer paused, in a set order
///
/// The pending record is a property of the DEVICE, so O2 and O6 would report
/// it for every later round; once every gate has been read the arm lets the
/// product's driver send it, paced, until it is confirmed (S22's release, for
/// S22's reason). It does so while the committer is still paused, BEFORE the
/// resume.
#[allow(clippy::too_many_lines)]
async fn negative_gates<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    leaver: DeviceTag,
    committer: DeviceTag,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let circle = world.build_extra_circle().await?;
    let shared = world.circles().first().ok_or(RigError::ShapeMismatch)?;
    let (shared_tag, shared_routing) = (shared.tag, *shared.nostr_group_id());
    let bound = bounds::round_trip(Recovery::Undisturbed);

    // The committer's endpoints go dark before the eviction is staged: its
    // drive reaches no relay, so the commit waits under its record, and its
    // engine — circles and inbox alike — is connected to nothing.
    for tag in world.engine_plane_tags() {
        world
            .plane_mut(tag)?
            .apply_for(committer, Fault::Down)
            .await?;
    }
    let eviction = surface_eviction(world, committer, leaver, (admin, 105), &circle).await?;
    let group = circle.mls_group_id().clone();
    let mut bus = world.device(committer)?.engine()?.bus().subscribe();
    let mut canaries = 0_usize;

    // 1. Awaiting its own ack: the eviction is staged under its record, no
    //    relay holds it or acknowledged it, and the sweep names nothing.
    let awaiting = !published_anywhere(world, &eviction.commit.id).await?;
    let recorded = !world
        .device(committer)?
        .session()?
        .fanout_ids_for_test(&group)
        .await
        .map_err(|_| RigError::Core(Step::ReadConvergenceState))?
        .is_empty();
    if awaiting && recorded && sweep(world, committer, &mut bus).await?.silent {
        canaries += 1;
    }

    // 2. A relay outage: the committer's endpoint is dark, its engine sees no
    //    relay at all, and the sweep still names nothing.
    let dark = await_condition(bound, || async {
        Ok(world
            .device(committer)?
            .engine()?
            .relay_health()
            .await
            .connected
            == 0)
    })
    .await?;
    if dark && sweep(world, committer, &mut bus).await?.silent {
        canaries += 1;
    }

    // 3. A paused engine: it holds no REQ and no socket, and the sweep names
    //    nothing. The endpoint comes back while it is paused, so the resume
    //    below is a fresh connect rather than the pool's reconnect ladder.
    world.device_mut(committer)?.go_offline().await?;
    let paused = world.device(committer)?.engine()?.is_paused();
    if paused && sweep(world, committer, &mut bus).await?.silent {
        canaries += 1;
    }
    for tag in world.engine_plane_tags() {
        world
            .plane_mut(tag)?
            .apply_for(committer, Fault::Heal)
            .await?;
    }

    // 4. A future-epoch backlog (Rule 12): the admin commits on a world circle
    //    the paused committer does not see, and its next fix reaches the
    //    committer's receive plane one epoch ahead. It is backlog, not a wedge.
    let (_, advanced) = relay_update(
        world,
        admin,
        world.circle(shared_tag)?,
        &extended_relays(world, "s05-gates-future"),
    )
    .await?;
    if advanced != PublishVerdict::Confirmed {
        return Err(RigError::PublishNeverAcked);
    }
    let ahead = seal(world, admin, world.circle(shared_tag)?, 11).await?;
    let outcome = world
        .device(committer)?
        .engine()?
        .processor()
        .process_group_event(&ahead, &shared_routing)
        .await;
    let still_owed = pending_record(world.device(committer)?, &group)
        .await?
        .is_some_and(|record| record.id == eviction.id);
    if outcome != GroupProcessOutcome::Applied
        && still_owed
        && sweep(world, committer, &mut bus).await?.silent
    {
        canaries += 1;
    }

    // 5. An unprocessable event: reported as the per-event status it is, never
    //    as a circle verdict. At MDK v0.10.4 an envelope nobody can open is the
    //    engine's own terminal verdict, not a failure, so the one ingest that
    //    still fails is induced: a storage write fault under a genuine fix, in a
    //    circle of its own so the fix it costs (tracker T-FAULTED-INGEST-SEEN)
    //    is in no graded circle.
    let faulted = world.build_extra_circle().await?;
    let genuine = seal(world, admin, &faulted, 12).await?;
    let db = world.device(committer)?.session_db_path();
    let key = StorageConfig::test_sqlcipher_key().map_err(|_| RigError::Core(Step::OpenStore))?;
    set_stored_message_write_fault_for_test(&db, &key, true)
        .map_err(|_| RigError::Core(Step::OpenStore))?;
    let failed = world
        .device(committer)?
        .engine()?
        .processor()
        .process_group_event(&genuine, faulted.nostr_group_id())
        .await;
    set_stored_message_write_fault_for_test(&db, &key, false)
        .map_err(|_| RigError::Core(Step::OpenStore))?;
    let after_junk = sweep(world, committer, &mut bus).await?;
    if failed == GroupProcessOutcome::Unprocessable && after_junk.unprocessable && after_junk.silent
    {
        canaries += 1;
    }

    // Back in the foreground first: a driver sends a commit only in the full
    // mode a claimed foreground gives it, as the bridge's does.
    world.device_mut(committer)?.come_online().await?;
    let clock = PacingClock::default();
    if !drive_until_settled(world, committer, &group, &clock, SETTLE_DRIVES).await? {
        return Err(RigError::PublishNeverAcked);
    }
    let shared_group = world.circle(shared_tag)?.mls_group_id().clone();
    // The resumed committer takes the commit it missed before the closing round
    // grades the circle; the round itself is what says whether it did.
    await_condition(bound + bounds::subscribe_ladder(), || async {
        Ok(epoch_of(world, committer, &shared_group).await?
            == epoch_of(world, admin, &shared_group).await?)
    })
    .await?;

    close(world, committer, tick, &[], canaries).await
}

/// Kills `committer` between the SEND and the `OK` of a peer's eviction its
/// own live engine made, and reads what the reopened device does with it.
///
/// A restart here is a clean cancel, not a SIGKILL — the worker's
/// panic-isolation spawn runs to completion and no WAL is torn; torn-storage
/// fidelity is Tier 2's `avd snapshot` nemesis. Rule 14's discipline is
/// [`kill_send_plane`]'s, inside `kill_and_reopen`.
///
/// # The engine does the work, and only the committer's engine sees the circle
///
/// `leaver`'s `propose_leave` is PUBLISHED, and `committer`'s live engine takes
/// it in — the product's receive path, over the device's own endpoint. The
/// circle is an extra one and only the committer's engine is subscribed to it:
/// a second remaining engine would commit the same eviction and there would be
/// no single committer to kill, and a leave on one of the world's circles
/// would leave the leaver in a roster every world-wide oracle reads.
///
/// # A burst makes nothing of it, the foreground makes it, then the kill
///
/// The leave arrives inside a background burst (`open_background_burst`), which
/// makes no commit (OD4-c (iv)): the eviction comes due in the engine and stays
/// due, with nothing staged, nothing owed and nothing on the wire — canary 1.
/// The foreground open that follows makes it: its drive stages the eviction
/// under a durable record and sends it into an `OK` the committer's own
/// endpoint swallows (device-scoped: the claim is that THIS device never hears
/// its acknowledgement, and the leaver's and the admin's planes stay whole).
/// The process is killed with that call out: the commit stored on a relay,
/// unacknowledged, and staged under its record.
///
/// # The kill kind is not what this arm measures either
///
/// What survives the process is the stored record and the commit staged under
/// it, whichever way the process goes; a soft stop gives the call up and stores
/// the same attempt that never returned.
///
/// # What the product does after the kill
///
/// The record outlived the process. The reopened device holds the commit
/// staged under it and is not wedged —
/// its own sweep names nothing — and a location asked for meanwhile is
/// deferred, typed. When the record's relay is next due the SAME event is sent
/// again — from a background burst, whose drive only finishes — acknowledged
/// this time, and confirmed there; the circle then sends. (At
/// MDK `e391adc` this arm was `EXPECTED_RED` with C9's wedge.)
async fn kill_receive<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    leaver: DeviceTag,
    committer: DeviceTag,
    tick: Duration,
    swallow: bool,
) -> Result<ArmOutcome, RigError> {
    let circle = world.build_extra_circle().await?;
    let spec = circle.spec_for(committer, world.relays());
    world.device_mut(committer)?.subscribe_circle(spec).await?;
    let bound = bounds::round_trip(Recovery::Undisturbed);

    world.device_mut(committer)?.go_offline().await?;
    world
        .device(committer)?
        .engine()?
        .open_background_burst()
        .await
        .map_err(|_| RigError::Core(Step::ResumeEngine))?;
    let (_, sent, _) = world.leave(leaver, circle.mls_group_id()).await?;
    let proposal = sent
        .into_iter()
        .find(|event| DropClass::of(event) == Some(DropClass::Handshake))
        .ok_or(RigError::Core(Step::StageCommit))?;
    if !world
        .relays()
        .iter()
        .any(|plane| plane.witnessed_ok(&proposal.id))
    {
        return Err(RigError::PublishNeverAcked);
    }

    let mut canaries = 0_usize;
    // 1. The burst makes nothing of the departure: the eviction is due on the
    //    committer, and nothing is staged, recorded, or on the wire for it.
    let left_due = await_condition(bound, || async {
        Ok(eviction_due(world, committer, &circle).await?
            && !staged(world, committer, &circle).await?
            && unrecorded(world, committer, &circle).await?
            && commits_besides(world, &circle, &proposal).await?.is_empty())
    })
    .await?;
    if left_due {
        canaries += 1;
    }

    if swallow {
        for plane in world.relays_mut() {
            plane.apply_for(committer, Fault::SwallowOk).await?;
        }
    }
    // The foreground open's drive makes the eviction, under a record, and
    // sends it.
    world.device_mut(committer)?.come_online().await?;
    await_condition(bound, || async {
        Ok(!commits_besides(world, &circle, &proposal).await?.is_empty())
    })
    .await?;
    let commits = commits_besides(world, &circle, &proposal).await?;
    let [commit] = *commits.as_slice() else {
        return Err(RigError::Core(Step::Publish));
    };
    let unacked = !world
        .relays()
        .iter()
        .any(|plane| plane.witnessed_ok(&commit));
    let still_staged = staged(world, committer, &circle).await?;

    let report = kill_and_reopen(world.device_mut(committer)?, KILL).await?;
    record_restart(world, committer, KILL, report);
    if swallow {
        for plane in world.relays_mut() {
            plane.apply_for(committer, Fault::Heal).await?;
        }
    }
    // 3. The kill landed between the send and its `OK`, with the removal
    //    staged under its record — never rolled back — and the process really
    //    died: held, released, retaken.
    if unacked && still_staged && report.engine_restarted {
        canaries += 1;
    }

    // 4, first half: a location asked for while the record still awaits its
    //    relay is deferred, and the deferral is typed.
    let held_typed = matches!(
        try_seal(world, committer, &circle, 21).await?,
        Err(ref error) if !matches!(classify_send(error), Classification::Defect(_))
    );

    // 2. The record survived the process and the device is not wedged; a
    //    burst sends the same event again when its relay is due, and confirms
    //    it.
    let (published, taken) = after_reopen(world, committer, &circle, commit).await?;
    if taken {
        canaries += 1;
    }

    // 4, second half: once the eviction is confirmed the circle sends.
    if held_typed && published && try_seal(world, committer, &circle, 22).await?.is_ok() {
        canaries += 1;
    }

    // The acked twin: a commit the reopened device takes like any other.
    let shared = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let (_, advanced) = relay_update(
        world,
        admin,
        world.circle(shared)?,
        &extended_relays(world, "s05-kill-receive-twin"),
    )
    .await?;
    if advanced != PublishVerdict::Confirmed {
        return Err(RigError::PublishNeverAcked);
    }
    let group = world.circle(shared)?.mls_group_id().clone();
    await_condition(bound, || async {
        Ok(epoch_of(world, committer, &group).await? == epoch_of(world, admin, &group).await?)
    })
    .await?;

    close(world, committer, tick, &[], canaries).await
}

/// Kills `committer` after a wake sweep took a departure in, and reads what
/// the foreground that follows makes of it.
///
/// # The path this arm grades (decision 27)
///
/// The sweep a background wake runs (`run_catchup_all_circles`) makes no
/// commit: nothing in it can tell a background wake from the foreground, so it
/// drives in the mode that only finishes. The eviction of a member who left
/// comes due in the engine and stays due, under no record and on no relay, and
/// a kill then has no publish→confirm window to land in. The foreground's
/// drive makes the eviction under a durable record and sends it.
///
/// # The shape of the wake
///
/// A background wake runs where no engine does: the committer's engine is
/// stopped, and every other remaining member is paused so no live plane takes
/// the leave in. The sweep takes the leave in itself, under a silence on every
/// plane that would swallow the `OK` of anything it sent, and the process
/// dies. The foreground then comes back: the engine starts and the product's
/// driver resumes.
async fn kill_sweep<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    leaver: DeviceTag,
    committer: DeviceTag,
    tick: Duration,
    swallow: bool,
) -> Result<ArmOutcome, RigError> {
    let swept = sweep_over_a_departure(world, leaver, committer, swallow).await?;
    let (circle, proposal, others) = (swept.circle, swept.proposal, swept.others);
    let mut canaries = 0_usize;
    // 1. The sweep made nothing of the departure: the eviction is due on the
    //    committer, and nothing is staged, recorded, or on the wire for it.
    if eviction_due(world, committer, &circle).await?
        && !staged(world, committer, &circle).await?
        && unrecorded(world, committer, &circle).await?
        && commits_besides(world, &circle, &proposal).await?.is_empty()
    {
        canaries += 1;
    }

    let report = kill_and_reopen(world.device_mut(committer)?, KILL).await?;
    record_restart(world, committer, KILL, report);
    if swallow {
        swallow_every_plane(world, Fault::Heal).await?;
    }
    // 2. The wake's process died — held, released and retaken — with no
    //    engine to bring back.
    if !report.engine_restarted {
        canaries += 1;
    }

    // 3. The foreground came back: the engine starts, and the driver's resume
    //    makes the eviction under a record, sends it once, and applies it on
    //    the relay's acknowledgement.
    {
        let device = world.device_mut(committer)?;
        let specs = device.specs().to_vec();
        device.start_engine(specs).await?;
    }
    let clock = PacingClock::default();
    // The circle has no engine subscription (it is outside the world's
    // table): the mark stands for the end of stored events the foreground's
    // REQ would have brought, without which no drive stages an eviction.
    world
        .device(committer)?
        .session()?
        .mark_caught_up_for_test(circle.mls_group_id());
    let resumed = world.resume_paced(committer, &clock).await?;
    // The started engine's own drive may hold the record the resume just
    // staged — one that only finishes, so it sends nothing new — and the
    // resume then finds it busy: the next drive takes it up once that drive
    // lets go (`drive_until_settled`), the product's own order, never a
    // margin of the rig's.
    if pending_record(world.device(committer)?, circle.mls_group_id())
        .await?
        .is_some()
    {
        let _ = drive_until_settled(
            world,
            committer,
            circle.mls_group_id(),
            &clock,
            SETTLE_DRIVES,
        )
        .await?;
    }
    let commits = commits_besides(world, &circle, &proposal).await?;
    if !resumed.errored
        && matches!(commits.as_slice(), [commit] if world
            .relays()
            .iter()
            .any(|plane| plane.witnessed_ok(commit)))
        && !staged(world, committer, &circle).await?
    {
        canaries += 1;
    }
    for &other in &others {
        world.device_mut(other)?.come_online().await?;
    }

    let classified: Vec<Classification> = match try_seal(world, committer, &circle, 23).await? {
        Ok(_) => Vec::new(),
        Err(error) => vec![classify_send(&error)],
    };
    close(world, committer, tick, &classified, canaries).await
}

/// How long one wake sweep may run.
const SWEEP_SECS: u64 = 30;

/// What [`sweep_over_a_departure`] left.
struct Swept {
    /// The circle the leaver left, outside the world's table.
    circle: SimCircle,
    /// The leaver's proposal, acknowledged.
    proposal: Event,
    /// The devices paused for the sweep.
    others: Vec<DeviceTag>,
}

/// A wake sweep over a departure, in a circle of its own.
///
/// `leaver` proposes its leave with every other member but `committer` paused
/// and `committer`'s engine stopped (a background wake has none), and ONE
/// sweep on `committer` takes the leave in — every plane swallowing the `OK`
/// of anything sent meanwhile when `swallow`.
///
/// # Errors
///
/// [`RigError::PublishNeverAcked`] if the proposal was never acknowledged,
/// otherwise [`RigError`] naming the step that failed.
async fn sweep_over_a_departure<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    leaver: DeviceTag,
    committer: DeviceTag,
    swallow: bool,
) -> Result<Swept, RigError> {
    let circle = world.build_extra_circle().await?;
    let others: Vec<DeviceTag> = world
        .devices()
        .iter()
        .map(|device| device.tag)
        .filter(|tag| *tag != leaver && *tag != committer)
        .collect();
    for &other in &others {
        world.device_mut(other)?.go_offline().await?;
    }
    if let Some(core) = world.device_mut(committer)?.take_engine() {
        if core.stop().await == StopOutcome::TimedOut {
            return Err(RigError::StopTimedOut);
        }
    }
    let (_, sent, _) = world.leave(leaver, circle.mls_group_id()).await?;
    let proposal = sent
        .into_iter()
        .find(|event| DropClass::of(event) == Some(DropClass::Handshake))
        .ok_or(RigError::Core(Step::StageCommit))?;
    if !world
        .relays()
        .iter()
        .any(|plane| plane.witnessed_ok(&proposal.id))
    {
        return Err(RigError::PublishNeverAcked);
    }
    if swallow {
        swallow_every_plane(world, Fault::SwallowOk).await?;
    }
    let device = world.device(committer)?;
    let _ = run_catchup_all_circles(device.manager()?, &device.relays, SWEEP_SECS).await;
    Ok(Swept {
        circle,
        proposal,
        others,
    })
}

/// Canary 2's reading: the record survived the process — the reopened device
/// holds the commit staged under it, and its own verdict sweep names nothing —
/// and the next background burst sends the
/// same event again when its relay is due and confirms it on the
/// acknowledgement, in the mode that only finishes: the device is still in
/// that burst when the confirm is read.
///
/// Returns whether it was confirmed, and whether the canary holds.
async fn after_reopen<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    committer: DeviceTag,
    circle: &SimCircle,
    commit: nostr::EventId,
) -> Result<(bool, bool), RigError> {
    let owing = *circle.nostr_group_id();
    let survived =
        staged(world, committer, circle).await? && !unrecorded(world, committer, circle).await?;
    let mut bus = world.device(committer)?.engine()?.bus().subscribe();
    // A background burst, not the foreground: its drive only finishes, and
    // finishing this record is all that is left to do.
    world.device_mut(committer)?.go_offline().await?;
    world
        .device(committer)?
        .engine()?
        .open_background_burst()
        .await
        .map_err(|_| RigError::Core(Step::ResumeEngine))?;
    let resent = bounds::fanout_resend_after_silence() + bounds::round_trip(Recovery::Undisturbed);
    let published = await_condition(resent, || async {
        Ok(!staged(world, committer, circle).await?
            && world
                .relays()
                .iter()
                .any(|plane| plane.witnessed_ok(&commit)))
    })
    .await?;
    // Read before anything of this arm changes the lifecycle again: the
    // confirm was a burst's, not the foreground's.
    let in_burst = world.device(committer)?.engine()?.processor().lifecycle() == Lifecycle::Burst;
    world.device_mut(committer)?.come_online().await?;
    let named = names(&mut bus, owing);
    let branch = if published {
        AFTER_KILL_REMOVAL_PUBLISHED
    } else {
        AFTER_KILL_REMOVAL_REPORTED
    };
    world.timeline().record(TimelineRecord::AfterKill {
        tick: world.current_tick(),
        device: committer,
        circle: circle.tag,
        outcome: branch,
    });
    Ok((published, survived && published && in_burst && !named))
}

/// Whether `device`'s engine announces the eviction of a member who left
/// `circle` as due now.
async fn eviction_due<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: &SimCircle,
) -> Result<bool, RigError> {
    Ok(world
        .device(device)?
        .session()?
        .eviction_due_after_for_test(circle.mls_group_id())
        .await
        .is_some_and(|wait| wait.is_zero()))
}

/// Whether `device`'s engine holds a commit of its own staged for `circle`.
async fn staged<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: &SimCircle,
) -> Result<bool, RigError> {
    Ok(matches!(
        world
            .device(device)?
            .session()?
            .epoch_state(circle.mls_group_id())
            .await,
        Some(EpochState::PendingPublish(_))
    ))
}

/// Whether `device` stores no fanout record for `circle`.
async fn unrecorded<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: &SimCircle,
) -> Result<bool, RigError> {
    Ok(world
        .device(device)?
        .session()?
        .fanout_ids_for_test(circle.mls_group_id())
        .await
        .map_err(|_| RigError::Core(Step::ReadConvergenceState))?
        .is_empty())
}

/// Every commit on the planes for `circle` other than `proposal`: its
/// handshake-class kind-445s.
async fn commits_besides<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    circle: &SimCircle,
    proposal: &Event,
) -> Result<Vec<nostr::EventId>, RigError> {
    let mut commits = Vec::new();
    for plane in world.relays() {
        for event in plane
            .stored_page(nostr::Filter::new().kind(Kind::Custom(445)))
            .await?
        {
            let routed = event.tags.iter().any(|tag| {
                tag.as_slice().first().is_some_and(|name| name == "h")
                    && tag
                        .as_slice()
                        .get(1)
                        .is_some_and(|value| value == circle.group_id_hex())
            });
            if routed
                && event.id != proposal.id
                && DropClass::of(&event) == Some(DropClass::Handshake)
                && !commits.contains(&event.id)
            {
                commits.push(event.id);
            }
        }
    }
    Ok(commits)
}

/// Whether the bus named `owing` as unrecoverable since `bus` subscribed.
fn names(bus: &mut Receiver<LiveSyncEvent>, owing: [u8; 32]) -> bool {
    let mut named = false;
    while let Ok(event) = bus.try_recv() {
        if let LiveSyncEvent::GroupUnrecoverable { nostr_group_id } = event {
            named |= nostr_group_id.as_slice() == owing.as_slice();
        }
    }
    named
}

/// What one reading of the OD4-c verdict saw.
struct Sweep {
    /// No circle was named, on the bus or by the engine latch, and no bus event
    /// was lost that could have been a naming.
    silent: bool,
    /// The bus carried the per-event unprocessable status.
    unprocessable: bool,
}

/// Reads what `device`'s own live engine said on its bus, and MDK's durable
/// verdict on every circle of the device.
async fn sweep<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    bus: &mut Receiver<LiveSyncEvent>,
) -> Result<Sweep, RigError> {
    let sim = world.device(device)?;
    let mut named = false;
    let mut unprocessable = false;
    loop {
        match bus.try_recv() {
            // A lost event could have been the naming: fail closed.
            Ok(LiveSyncEvent::GroupUnrecoverable { .. }) | Err(TryRecvError::Lagged(_)) => {
                named = true;
            }
            Ok(LiveSyncEvent::Status {
                reason: SyncStatusReason::Unprocessable,
            }) => unprocessable = true,
            Ok(_) => {}
            Err(TryRecvError::Empty | TryRecvError::Closed) => break,
        }
    }
    Ok(Sweep {
        silent: !named && sim.manager()?.unrecoverable_circles().await.is_empty(),
        unprocessable,
    })
}

/// Records a restart with the two latencies that ARE the Rule-14 measurement.
fn record_restart<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    kind: KillKind,
    report: ReopenReport,
) {
    world.timeline().record(TimelineRecord::Restarted {
        tick: world.current_tick(),
        device,
        kind,
        release_ms: millis(report.release),
        reopen_ms: millis(report.reopen),
    });
}

/// A span in whole milliseconds, saturating.
fn millis(span: Duration) -> u64 {
    u64::try_from(span.as_millis()).unwrap_or(u64::MAX)
}

/// The world's relay list plus one address it does not hold, so the commit is a
/// real change rather than a no-op.
fn extended_relays<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    salt: &str,
) -> Vec<String> {
    let mut relays = world.relay_urls();
    relays.push(format!("wss://{salt}.example.com"));
    relays
}

/// Turns `fault` on across every plane.
async fn swallow_every_plane<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    fault: Fault,
) -> Result<(), RigError> {
    for plane in world.relays_mut() {
        plane.apply(fault).await?;
    }
    Ok(())
}

/// Whether any plane holds `id` or acknowledged it.
async fn published_anywhere<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    id: &nostr::EventId,
) -> Result<bool, RigError> {
    for plane in world.relays() {
        if plane.stored(id).await? || plane.witnessed_ok(id) {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Whether some plane holds `event` while none acknowledged it client-ward.
async fn stored_but_unacked<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    event: &Event,
) -> Result<bool, RigError> {
    let mut stored = false;
    for plane in world.relays() {
        if plane.stored(&event.id).await? {
            stored = true;
        }
        if plane.witnessed_ok(&event.id) {
            return Ok(false);
        }
    }
    Ok(stored)
}

/// One device's epoch for one circle.
async fn epoch_of<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
) -> Result<u64, RigError> {
    world
        .device(device)?
        .manager()?
        .group_epoch(group)
        .await
        .map_err(|_| RigError::Core(Step::ReadEpoch))
}

/// Forces the driver's confirm of an ACKNOWLEDGED commit to fail, and reads
/// what the product does with it (W9f): the stored record decides, the commit
/// is never rolled back, and the next drive confirms it.
///
/// # How the failure is induced, and why it is the honest shape
///
/// A write fault on the engine's stored message table makes the confirm's
/// transaction fail after the relay has acknowledged the commit — a caller
/// that gets an `Err` with the acknowledgement already stored on the record.
/// The same fault aborts an ingest first, which is the strand: a peer's fix,
/// minted for a SECOND circle on purpose, so "the batch was folded" is a claim
/// about the drain and not about the commit.
async fn confirm_err<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    peer: DeviceTag,
) -> Result<usize, RigError> {
    let victim = world.build_extra_circle().await?;
    let sibling = world.build_extra_circle().await?;
    let db = world.device(admin)?.session_db_path();
    let key = StorageConfig::test_sqlcipher_key().map_err(|_| RigError::Core(Step::OpenStore))?;
    let mut canaries = 0_usize;

    let mut relays = world.relay_urls();
    relays.push("wss://s05-confirm-err.example.com".to_string());
    world.note_routing_of(victim.mls_group_id(), &relays);
    let staged = world
        .device(admin)?
        .manager()?
        .update_circle_relays_staging(victim.mls_group_id(), &relays, WallClock.now_ms())
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    let id = staged.commit.ok_or(RigError::Core(Step::StageCommit))?;
    let commit = world
        .device(admin)?
        .session()?
        .fanout_probe_for_test(&id)
        .await
        .ok()
        .flatten()
        .ok_or(RigError::Core(Step::StageCommit))?
        .event_id;

    // 1. The window is real: with the commit staged under its record and not
    //    yet sent, the circle's own outbound path is held shut.
    if seal(world, admin, &victim, 1).await.is_err() {
        canaries += 1;
    }

    set_stored_message_write_fault_for_test(&db, &key, true)
        .map_err(|_| RigError::Core(Step::OpenStore))?;
    // A peer's fix for the OTHER circle, ingested while the fault stands: the
    // ingest aborts on the state write. Deliberately NOT classified — a
    // storage fault this arm induced is not an ingest disposition, and feeding
    // it to O5 would report the harness's own plant as an outcome the product
    // could not account for.
    let stranded = seal(world, peer, &sibling, 2).await?;
    let refused = world
        .device(admin)?
        .session()?
        .process_event_typed_for_test(&stranded)
        .await
        .is_err();
    // 2. The strand's premise: the fault really did abort that ingest.
    if refused {
        canaries += 1;
    }

    // The driver sends the commit, a relay acknowledges it, and the confirm
    // fails on the fault.
    let before = epoch_of(world, admin, victim.mls_group_id()).await?;
    let failed = world.resume(admin).await?;
    let acked = world
        .relays()
        .iter()
        .any(|plane| plane.witnessed_ok(&commit));
    set_stored_message_write_fault_for_test(&db, &key, false)
        .map_err(|_| RigError::Core(Step::OpenStore))?;

    // 3. The confirm really failed, on an acknowledged commit.
    if failed.errored && acked {
        canaries += 1;
    }
    // 4. RECORDED EXPECTATION, not a graded promise. At MDK `e391adc` the
    //    faulted ingest had already pushed the fix into the effect buffer, and
    //    the failing confirm's drain folded it. At v0.10.4 the engine writes
    //    before it emits, so a faulted ingest delivers nothing — and records the
    //    object as seen, so no redelivery brings it back (tracker
    //    T-FAULTED-INGEST-SEEN). The fix is therefore absent; the day it is
    //    present again, this canary is unmet and the arm goes rc 3, the signal
    //    that the expectation is stale.
    if !folded(world, admin, peer, &sibling)? {
        canaries += 1;
    }
    // 5. W9f: the stored record decided, and the commit was neither rolled
    //    back nor stranded — the next drive confirms it, the epoch moves, the
    //    circle sends again, and no circle is reported unrecoverable over it.
    let clock = PacingClock::default();
    let settled =
        drive_until_settled(world, admin, victim.mls_group_id(), &clock, SETTLE_DRIVES).await?;
    let applied = epoch_of(world, admin, victim.mls_group_id()).await? > before;
    let quiet = world
        .device(admin)?
        .manager()?
        .unrecoverable_circles()
        .await
        .is_empty();
    if settled && applied && quiet && seal(world, admin, &victim, 3).await.is_ok() {
        canaries += 1;
    }
    Ok(canaries)
}

/// Whether `peer`'s fix for `circle` reached `admin`'s durable last-known store.
fn folded<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    peer: DeviceTag,
    circle: &SimCircle,
) -> Result<bool, RigError> {
    let peer_hex = world.device(peer)?.pubkey_hex();
    let rows = world
        .device(admin)?
        .manager()?
        .snapshot_last_known_for_circle(
            circle.nostr_group_id(),
            crate::clock::WallNow::now().secs(),
        )
        .map_err(|_| RigError::Core(Step::OpenStore))?;
    Ok(rows.iter().any(|row| row.sender_pubkey == peer_hex))
}

/// Seals one location for `circle` at `device`'s current epoch, unpublished.
async fn seal<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: &SimCircle,
    index: u32,
) -> Result<Event, RigError> {
    try_seal(world, device, circle, index)
        .await?
        .map_err(|_| RigError::Core(Step::Publish))
}

/// [`seal`], handing the product's refusal back typed so it can be classified.
async fn try_seal<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: &SimCircle,
    index: u32,
) -> Result<Result<Event, CircleError>, RigError> {
    let sender = world.device(device)?;
    Ok(sender
        .manager()?
        .seal_location_for_test(
            circle.mls_group_id(),
            &ProbeToken::mint(5, index).as_location(),
        )
        .await
        .map(|(event, _, _)| event))
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::ARMS;
    use crate::oracle::vacuity::ExpectationFloor;
    use crate::oracle::Recovery;
    use crate::scenarios::{WithheldAcks, MINIMAL_SHAPE};

    #[test]
    fn the_arm_breaks_no_relay_and_demands_all_five_observations() {
        let arm = ARMS[0];
        assert!(
            arm.recovery == Recovery::Undisturbed,
            "nothing is unplugged: the failure is a storage abort inside one call"
        );
        assert!(
            arm.floor.faults_applied == 0,
            "a storage fault is not something a relay plane does"
        );
        assert!(
            !arm.resubscribes,
            "no device re-opens a REQ, so the subscribe ladder is not in the bound"
        );
        assert!(
            arm.floor.canaries_caught == 5,
            "the window, the strand, the error, the fold, and the commit that was \
             neither rolled back nor retried"
        );
        assert!(
            arm.floor.deliveries_observed == 1,
            "the closing round over the world's own circles still has to deliver"
        );
    }

    #[test]
    fn the_kill_arm_withholds_one_commit_and_pays_the_resubscribe() {
        let arm = ARMS[1];
        assert!(
            arm.label == "kill-send-plane",
            "the arm the control reports"
        );
        assert!(
            arm.withheld_acks == WithheldAcks::Fixed(1),
            "the one commit the kill lands behind burns the whole ladder"
        );
        assert!(
            arm.resubscribes,
            "the killed engine re-opens every REQ it held"
        );
        assert!(
            arm.floor
                == ExpectationFloor {
                    faults_applied: 1,
                    epochs_crossed: 0,
                    deliveries_observed: 1,
                    canaries_caught: 4,
                },
            "the swallowed acknowledgement, a victim circle outside the world's \
             table, and the transition, the silence, the gating rows and the send"
        );
    }

    #[test]
    fn the_receive_kill_arm_crosses_a_world_epoch_with_its_acked_twin() {
        let arm = ARMS[2];
        assert!(
            arm.label == "kill-receive-auto-commit",
            "the receive-plane kill"
        );
        assert!(
            arm.withheld_acks == WithheldAcks::FanoutResends(1),
            "the one send the kill cuts is made again when its relay is next due"
        );
        assert!(
            arm.floor
                == ExpectationFloor {
                    faults_applied: 1,
                    epochs_crossed: 1,
                    deliveries_observed: 1,
                    canaries_caught: 4,
                },
            "the swallowed acknowledgement, the twin's world epoch, and what a \
             burst made of the departure, the kill inside the window, the \
             record after the reopen, and the send held and then made"
        );
    }

    #[test]
    fn the_gates_arm_reads_five_moments_and_withholds_nothing() {
        let arm = ARMS[3];
        assert!(arm.label == "negative-gates-silent", "the five-gate arm");
        assert!(
            arm.withheld_acks == WithheldAcks::None,
            "no gate publishes into a silence, so no ladder is priced"
        );
        assert!(
            arm.floor
                == ExpectationFloor {
                    faults_applied: 1,
                    epochs_crossed: 1,
                    deliveries_observed: 1,
                    canaries_caught: 5,
                },
            "the outage's endpoint, the future-epoch commit, and one canary per \
             gate: a single read at the end would pass a verdict that fired and \
             cleared"
        );
    }

    #[test]
    fn the_sweep_kill_arm_withholds_nothing() {
        let arm = ARMS[4];
        assert!(arm.label == "kill-sweep-eviction", "the wake sweep's kill");
        assert!(
            arm.withheld_acks == WithheldAcks::None,
            "the sweep makes no commit, so it sends nothing into the silence"
        );
        assert!(
            arm.floor
                == ExpectationFloor {
                    faults_applied: 1,
                    epochs_crossed: 0,
                    deliveries_observed: 1,
                    canaries_caught: 3,
                },
            "the swallowed acknowledgement, a circle outside the world's table, \
             and the sweep that made nothing, the engine-less death and the \
             foreground's drive making the eviction"
        );
    }

    #[test]
    fn the_derived_bounds_are_the_plans() {
        let tick = Duration::from_millis(250);
        let shape = MINIMAL_SHAPE;
        assert!(
            ARMS[1].deadline(tick, &shape) == Duration::from_millis(79_750),
            "13.75 + 9 + 13 + (34 + 10)"
        );
        assert!(
            ARMS[2].deadline(tick, &shape) == Duration::from_millis(65_750),
            "13.75 + 9 + 13 + 30"
        );
        assert!(
            ARMS[3].deadline(tick, &shape) == Duration::from_millis(35_750),
            "13.75 + 9 + 13"
        );
    }
}
