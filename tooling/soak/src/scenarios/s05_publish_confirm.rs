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
//! `kill-receive-auto-commit` kills a device while it owes the publish of a
//! peer's eviction its own live engine staged. It is EXPECTED RED (C9): the
//! reopened device is left owing an eviction that neither it nor a peer's
//! identical commit can land — see [`kill_receive`].
//!
//! # The OD4-c verdict must stay silent where nothing is wedged
//!
//! `negative-gates-silent` induces, in one world holding one staged eviction,
//! each of the five states `od4c_removal_deferral_e2e.rs` pins as NOT a wedge,
//! and reads the verdict at each of them — five canaries, one arm. A single read
//! at the end would pass on a verdict that fired spuriously and cleared.

use std::time::Duration;

use haven_core::circle::{CircleError, CommitToPublish};
use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::nostr::mls::storage::{set_stored_message_write_fault_for_test, StorageConfig};
use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::live_sync::{GroupProcessOutcome, LiveSyncEvent, SyncStatusReason};
use nostr::{Event, EventBuilder, Keys, Kind, Tag, TagKind};
use tokio::sync::broadcast::error::TryRecvError;
use tokio::sync::broadcast::Receiver;
use tokio::time::Instant;

use crate::nemesis::types::{DropClass, Fault};
use crate::oracle::undecryptable::{classify_send, Verdict as Classification};
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{bounds, Invariant, ProbeToken, Reach, Recovery};
use crate::rig::{
    kill_and_reopen, DeviceTag, KillKind, LogDrain, PublishVerdict, RelayPlane, ReopenReport,
    RigError, SimCircle, Step, TimelineRecord, TimelineSink, AFTER_KILL_REMOVAL_PUBLISHED,
    AFTER_KILL_REMOVAL_REPORTED, AFTER_KILL_SENDS_RESUMED, AFTER_KILL_SEND_CLASSIFIED,
};
use crate::scenarios::{
    await_condition, closing_pairs, grade_round, relay_update, round, Absence, Arm, ArmOutcome,
    Scenario, ScenarioReport, ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// The arms this scenario offers.
pub const ARMS: [Arm; 4] = [
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
        // The one foreground publish of the eviction the kill lands behind.
        withheld_acks: WithheldAcks::Fixed(1),
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

/// Kills `victim` between SEND and confirm of its own relay-list commit.
///
/// # The kill kind is not what this arm measures
///
/// Measured: the arm holds with [`KillKind::Soft`] too. The commit was
/// published by the rig's own publish plane and its circle has no engine
/// subscription, so a soft stop has nothing of the victim circle's to drain —
/// what dies either way is the process's one `PendingStateRef`, and the staged
/// commit outlives it on disk. The kind is `Hard` because that is the shape of
/// the background kill C1 names, and because the release latency it records is
/// the undrained one.
///
/// # The victim circle is not one of the world's
///
/// A relay under a swallowed acknowledgement still stores and delivers what it
/// was sent. A peer that applied the commit would then sit on a branch the
/// restarted device has discarded — the reopen rewinds an unconfirmed staged
/// commit — and which branch a later merge keeps is a coin toss per run (S14's
/// `race-restart-before-confirm` records the same). So the commit is staged on
/// a circle built with `build_extra_circle`: no engine subscribes to it, nobody
/// is handed the commit, and the world's own circles are what the closing round
/// grades, with the restarted device sending first.
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
    let guard = world.note_pending_staged();
    let staged = world
        .device(victim)?
        .manager()?
        .update_circle_relays(&group, &extended_relays(world, "s05-kill-send"))
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    let window = if world
        .publish_witnessed(victim, std::slice::from_ref(&staged.commit_event))
        .await?
        .is_some()
    {
        // Acked means confirmed (Rule 13), so the kill below has no
        // publish→confirm window left to land in.
        let ingest = world
            .device(victim)?
            .manager()?
            .finalize_relay_update(staged.pending, &group)
            .await
            .map_err(|_| RigError::Core(Step::ConfirmPublished))?;
        world.resolve_ingest(victim, ingest).await?;
        false
    } else {
        stored_but_unacked(world, &staged.commit_event).await?
    };

    let report = kill_and_reopen(world.device_mut(victim)?, KILL).await?;
    // The kill IS the resolution, in the only honest sense there is: the
    // process that staged the commit is gone, and with it the one ref that could
    // have confirmed or rolled it back. The rig's count cannot see a kill, so it
    // is released here, explicitly, once the reopen has returned — held any
    // longer, the closing round could never settle and the arm would report a
    // violation it manufactured.
    drop(guard);
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
        .is_empty()
    {
        canaries += 1;
    }
    // 3. …and nothing it left behind gates the circle.
    if world
        .device(victim)?
        .session()?
        .gating_input_count(&group)
        .await
        .map_err(|_| RigError::Core(Step::ReadGatingRows))?
        == 0
    {
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
/// Here nothing is published into a silence: every publish path the rig has
/// pays an unpriced wait on a relay that never answers (the commit ladder, or a
/// pool's ten-second wait for an `OK`), and this arm is priced with no withheld
/// acknowledgement. So "awaiting its own ack" is the state before that publish
/// — the eviction surfaced through the FFI plane and held live, owed in this
/// session, nothing yet published or acknowledged — and "a relay outage" is the
/// committer's own endpoint going dark while its engine is connected, observed
/// by that engine.
///
/// # The staged eviction is released, and the committer paused, in a set order
///
/// The obligation is a property of the DEVICE, so O2 and O6 would report it for
/// every later round; the arm lands it on an acked publish once every gate has
/// been read (S22's release, for S22's reason). It does so while the committer
/// is still paused, BEFORE the resume, so the foreground open that resume
/// performs finds nothing owed and redeems nothing: the release is the rig's
/// own Rule-13 resolution of the ref it holds, never a race with the product's.
async fn negative_gates<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    leaver: DeviceTag,
    committer: DeviceTag,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let circle = world.build_extra_circle().await?;
    let owing = *circle.nostr_group_id();
    let shared = world.circles().first().ok_or(RigError::ShapeMismatch)?;
    let (shared_tag, shared_routing) = (shared.tag, *shared.nostr_group_id());
    let bound = bounds::round_trip(Recovery::Undisturbed);

    let guard = world.note_pending_staged();
    let eviction = surface_eviction(world, committer, leaver, admin, &circle).await?;
    let mut bus = world.device(committer)?.engine()?.bus().subscribe();
    let mut canaries = 0_usize;

    // 1. Awaiting its own ack: the eviction is surfaced through the FFI plane
    //    and held live (nothing is published yet), the obligation is owed and
    //    live in THIS session — so redeemable, not orphaned — and the sweep
    //    names nothing.
    let owed = world.device(committer)?.manager()?.owed_removal_commits() == vec![owing];
    let live = world
        .device(committer)?
        .manager()?
        .orphaned_removal_deferrals()
        .is_empty();
    if owed && live && sweep(world, committer, &mut bus)?.silent {
        canaries += 1;
    }

    // 2. A relay outage: the committer's endpoint goes dark, its engine sees no
    //    relay at all, and the sweep still names nothing.
    for plane in world.relays_mut() {
        plane.apply_for(committer, Fault::Down).await?;
    }
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
    if dark && sweep(world, committer, &mut bus)?.silent {
        canaries += 1;
    }

    // 3. A paused engine: it holds no REQ and no socket, and the sweep names
    //    nothing. The endpoint comes back while it is paused, so the resume
    //    below is a fresh connect rather than the pool's reconnect ladder.
    world.device_mut(committer)?.go_offline().await?;
    let paused = world.device(committer)?.engine()?.is_paused();
    if paused && sweep(world, committer, &mut bus)?.silent {
        canaries += 1;
    }
    for plane in world.relays_mut() {
        plane.apply_for(committer, Fault::Heal).await?;
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
    let still_owed = world.device(committer)?.manager()?.owed_removal_commits() == vec![owing];
    if outcome != GroupProcessOutcome::Applied
        && still_owed
        && sweep(world, committer, &mut bus)?.silent
    {
        canaries += 1;
    }

    // 5. An unprocessable event: reported as the per-event status it is, never
    //    as a circle verdict.
    let junk = EventBuilder::new(Kind::Custom(445), "not-ciphertext")
        .tag(Tag::custom(
            TagKind::custom("h"),
            [hex::encode(shared_routing)],
        ))
        .sign_with_keys(&Keys::generate())
        .map_err(|_| RigError::Core(Step::Publish))?;
    world
        .device(committer)?
        .engine()?
        .processor()
        .process_group_event(&junk, &shared_routing)
        .await;
    let after_junk = sweep(world, committer, &mut bus)?;
    if after_junk.unprocessable && after_junk.silent {
        canaries += 1;
    }

    release(world, committer, &eviction).await?;
    drop(guard);

    world.device_mut(committer)?.come_online().await?;
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

/// Kills `committer` while it owes the publish of a peer's eviction its own
/// live engine staged, and reads what the reopened device does with it.
///
/// A restart here is a clean cancel, not a SIGKILL — the worker's
/// panic-isolation spawn runs to completion and no WAL is torn; torn-storage
/// fidelity is Tier 2's `avd snapshot` nemesis. Rule 14's discipline is
/// [`kill_send_plane`]'s, inside `kill_and_reopen`.
///
/// # The engine does the work, and only the committer's engine sees the circle
///
/// `leaver`'s `propose_leave` is PUBLISHED, and `committer`'s live engine folds
/// it and stages the auto-commit itself — the product's receive path, over the
/// device's own endpoint. The circle is an extra one and only the committer's
/// engine is subscribed to it: a second remaining engine would commit the same
/// eviction and there would be no single committer to kill, and a leave on one
/// of the world's circles would leave the leaver in a roster every world-wide
/// oracle reads.
///
/// # Burst, then the foreground publish, then the kill
///
/// The fold happens inside a background burst (`open_background_burst`), which
/// parks the commit as a durable obligation without publishing it (OD4-c (iv))
/// — which is what lets canary 1 read the obligation BEFORE any publish. The
/// foreground open that follows publishes it into a swallowed `OK` on the
/// committer's own endpoint (device-scoped: the claim is that THIS device never
/// hears its acknowledgement, and the leaver's and the admin's planes stay
/// whole), and the process is killed with the commit stored, unacknowledged and
/// owed.
///
/// # The kill kind is not what this arm measures either
///
/// Measured: `KillKind::Soft` reaches the same outcome. The publish has already
/// returned unacknowledged when the process goes, so a soft stop has nothing in
/// flight to drain; what dies is the in-memory obligation, and the durable row
/// outlives it either way.
///
/// # Expected red: what the product does after the kill (C9, measured 2026-09-27)
///
/// The obligation survives and is ORPHANED: the next foreground pass publishes
/// nothing, `orphaned_removal_deferrals()` names the circle and the device's
/// own verdict sweep emits `GroupUnrecoverable` for it (`unrecoverable_circles()`
/// stays empty — it is the engine's latch alone). That is the branch recorded.
///
/// Two findings follow, and they are why this arm is `EXPECTED_RED` rather than
/// swept:
///
/// * **A** — the wedged circle's send is refused with NO typed reason at either
///   layer (`CircleError::Mls`, and the session's own send likewise), so the
///   classifier can only call it a `Defect`: hydrate marks the group stable at
///   the epoch the staged commit projected while `OpenMLS` still holds that
///   removal-bearing commit. Canary 4 records the refusal (a refusal iff the
///   eviction was not published) and hands O5 nothing.
/// * **B** — the peer's heal does not heal. `admin` commits the same eviction on
///   its own, acknowledged, and the reopened committer answers it `Buffered`
///   and keeps refusing sends, so O2 and O6 report the owed eviction in the
///   closing round: rc 1. `od4c_removal_deferral_e2e.rs`'s
///   `a_deferral_a_peer_healed_after_a_restart_is_not_reported` heals on a bare
///   processor over a reborn manager, and a replica of it still does; the
///   difference lies in the live-engine restart path and is NOT pinned, so
///   whether this is the product's or the rig's is OPEN (PLAN §8 OQ-U; the
///   reproduction is in `PLAN_PHASE2`'s 2c S05 implementation notes).
async fn kill_receive<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    leaver: DeviceTag,
    committer: DeviceTag,
    tick: Duration,
    swallow: bool,
) -> Result<ArmOutcome, RigError> {
    let circle = world.build_extra_circle().await?;
    let owing = *circle.nostr_group_id();
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
    let proposal = world
        .device(leaver)?
        .manager()?
        .propose_leave(circle.mls_group_id())
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    if world
        .publish_witnessed(leaver, std::slice::from_ref(&proposal))
        .await?
        .is_none()
    {
        return Err(RigError::PublishNeverAcked);
    }

    let mut canaries = 0_usize;
    // 1. The obligation is durable BEFORE any publish: the burst parked the
    //    eviction its engine staged, and nothing is on the wire for it.
    let parked = await_condition(bound, || async {
        Ok(owes(world, committer, owing)?
            && commits_besides(world, &circle, &proposal).await?.is_empty())
    })
    .await?;
    if parked {
        canaries += 1;
    }

    if swallow {
        for plane in world.relays_mut() {
            plane.apply_for(committer, Fault::SwallowOk).await?;
        }
    }
    // The foreground open publishes the parked commit, inline.
    world.device_mut(committer)?.come_online().await?;
    let commits = commits_besides(world, &circle, &proposal).await?;
    let [commit] = *commits.as_slice() else {
        return Err(RigError::Core(Step::Publish));
    };
    let unacked = !world
        .relays()
        .iter()
        .any(|plane| plane.witnessed_ok(&commit));
    let still_owed = owes(world, committer, owing)?;

    let report = kill_and_reopen(world.device_mut(committer)?, KILL).await?;
    record_restart(world, committer, KILL, report);
    if swallow {
        for plane in world.relays_mut() {
            plane.apply_for(committer, Fault::Heal).await?;
        }
    }
    // 3. The kill landed inside the window with the removal still owed — never
    //    rolled back — and the process really died: held, released, retaken.
    if unacked && still_owed && report.engine_restarted {
        canaries += 1;
    }

    // 2. The row survived the process, and the next foreground pass EITHER
    //    publishes that same commit and discharges it, OR the obligation is
    //    orphaned and the device's own verdict sweep names the circle.
    //    Recorded which: that is the OD4-c answer for a hard kill here.
    let (published, taken) = after_reopen(world, committer, &circle, commit).await?;
    if taken {
        canaries += 1;
    }

    // 4. The send on that circle is refused exactly when canary 2 took the
    //    orphaned branch: a wedge refuses it, a redeemed eviction must not. Read
    //    against `published` so a product fix that redeems the eviction lands
    //    here met and reaches the STALE promotion pin, rather than going unmet
    //    and reporting rc 3 about the wrong thing. Deliberately NOT handed to O5:
    //    the refusal has no typed classification at either layer (Finding A in
    //    the docs above), so `classify_send` could only call it a `Defect` —
    //    which would be the classifier's gap, not this arm's grade.
    if try_seal(world, committer, &circle, 21).await?.is_err() != published {
        canaries += 1;
    }

    if !published {
        heal_by_peer(world, admin, committer, &circle, &proposal).await?;
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

/// Canary 2's reading, and the record of which branch the product took: the
/// row survived the process, and the next foreground pass EITHER publishes that
/// same commit and discharges it, OR the obligation is orphaned and the
/// device's own verdict sweep names the circle.
///
/// Returns whether it published, and whether the canary holds.
async fn after_reopen<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    committer: DeviceTag,
    circle: &SimCircle,
    commit: nostr::EventId,
) -> Result<(bool, bool), RigError> {
    let owing = *circle.nostr_group_id();
    let survived = owes(world, committer, owing)?;
    let mut bus = world.device(committer)?.engine()?.bus().subscribe();
    world.device_mut(committer)?.go_offline().await?;
    world.device_mut(committer)?.come_online().await?;
    let published = !owes(world, committer, owing)?
        && world
            .relays()
            .iter()
            .any(|plane| plane.witnessed_ok(&commit));
    let orphaned = world
        .device(committer)?
        .manager()?
        .orphaned_removal_deferrals()
        == vec![owing];
    let named = names(&mut bus, owing);
    let (branch, taken) = if published {
        (AFTER_KILL_REMOVAL_PUBLISHED, true)
    } else {
        (AFTER_KILL_REMOVAL_REPORTED, orphaned && named)
    };
    world.timeline().record(TimelineRecord::AfterKill {
        tick: world.current_tick(),
        device: committer,
        circle: circle.tag,
        outcome: branch,
    });
    Ok((published, survived && taken))
}

/// `admin` commits `leaver`'s eviction on its own, acknowledged, and the
/// wedged `committer` takes it and sends again — which discharges its row.
async fn heal_by_peer<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    committer: DeviceTag,
    circle: &SimCircle,
    proposal: &Event,
) -> Result<(), RigError> {
    let ingest = world
        .device(admin)?
        .manager()?
        .decrypt_location_collecting_commits(proposal)
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    let Some(eviction) = ingest.auto_commits.into_iter().next() else {
        return Err(RigError::Core(Step::StageCommit));
    };
    release(world, admin, &eviction).await?;
    let bound = bounds::round_trip(Recovery::Undisturbed);
    // The committer's engine is subscribed to the circle and takes the
    // admin's commit live; a send it accepts is what clears the row.
    await_condition(bound, || async {
        Ok(try_seal(world, committer, circle, 22).await?.is_ok())
    })
    .await?;
    Ok(())
}

/// Whether `device` owes exactly the eviction for `owing`.
fn owes<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    owing: [u8; 32],
) -> Result<bool, RigError> {
    Ok(world.device(device)?.manager()?.owed_removal_commits() == vec![owing])
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

/// Lands the eviction every gate held, on an acknowledged publish — which is
/// also what proves the obligation was real.
///
/// The rig's own Rule-13 resolution of the ref it was handed: confirmed only on
/// an acknowledgement a relay's client-facing stream carried.
async fn release<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    committer: DeviceTag,
    eviction: &CommitToPublish,
) -> Result<(), RigError> {
    if world
        .publish_witnessed(committer, std::slice::from_ref(&eviction.commit_event))
        .await?
        .is_none()
    {
        return Err(RigError::PublishNeverAcked);
    }
    let ingest = world
        .device(committer)?
        .manager()?
        .confirm_published(eviction.pending)
        .await
        .map_err(|_| RigError::Core(Step::ConfirmPublished))?;
    world.resolve_ingest(committer, ingest).await
}

/// What one reading of the OD4-c verdict saw.
struct Sweep {
    /// No circle was named, on the bus or by the engine latch, and no bus event
    /// was lost that could have been a naming.
    silent: bool,
    /// The bus carried the per-event unprocessable status.
    unprocessable: bool,
}

/// Runs `device`'s own live engine's verdict sweep and reads what it said.
fn sweep<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    bus: &mut Receiver<LiveSyncEvent>,
) -> Result<Sweep, RigError> {
    let sim = world.device(device)?;
    sim.engine()?.processor().report_unrecoverable_circles();
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
        silent: !named && sim.manager()?.unrecoverable_circles().is_empty(),
        unprocessable,
    })
}

/// Drives `leaver`'s `SelfRemove` through `committer`'s FFI receive plane
/// until the eviction surfaces with its obligation recorded.
///
/// S22's surfacing, for S22's reason: the engine schedules the auto-commit
/// behind a short jitter and surfaces it on the next convergence tick, so the
/// loop re-ticks with a fresh fix from `ticker` rather than waiting on a clock.
async fn surface_eviction<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    committer: DeviceTag,
    leaver: DeviceTag,
    ticker: DeviceTag,
    circle: &SimCircle,
) -> Result<CommitToPublish, RigError> {
    let proposal = world
        .device(leaver)?
        .manager()?
        .propose_leave(circle.mls_group_id())
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    let mut ingest = world
        .device(committer)?
        .manager()?
        .decrypt_location_collecting_commits(&proposal)
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    let bound = bounds::round_trip(Recovery::Undisturbed);
    let started = Instant::now();
    let mut index = 100_u32;
    loop {
        if let Some(commit) = ingest.auto_commits.pop() {
            return Ok(commit);
        }
        if started.elapsed() >= bound {
            // The eviction never surfaced, so no gate below could be induced:
            // "this proved nothing", not a finding.
            return Err(RigError::Core(Step::StageCommit));
        }
        index = index.wrapping_add(1);
        let tick = seal(world, ticker, circle, index).await?;
        ingest = world
            .device(committer)?
            .manager()?
            .decrypt_location_collecting_commits(&tick)
            .await
            .map_err(|_| RigError::Core(Step::StageCommit))?;
    }
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

/// Forces one `confirm_published` to fail after the engine has already
/// delivered, and reads what the product did with the wreckage.
///
/// # How the failure is induced, and why it is the honest shape
///
/// The engine writes each replayed message's terminal state through its stored
/// message table AFTER it has pushed that message's decrypted content into its
/// own effect buffer. An abort trigger on that table therefore reproduces
/// exactly the state a mid-replay fork abort produces — a caller that gets an
/// `Err` and no effects, with a peer's fix already delivered into a buffer only
/// the next drain will ever see — without having to build two sibling commits to
/// get there.
///
/// The stranded fix is minted for a SECOND circle on purpose. The engine's
/// effect buffers are global, so one failing resolution drains every circle's
/// work; keying the assertion on a circle other than the one whose commit is
/// staged is what makes "the batch was folded" a claim about the drain rather
/// than about the commit.
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
    let guard = world.note_pending_staged();
    let staged = world
        .device(admin)?
        .manager()?
        .update_circle_relays(victim.mls_group_id(), &relays)
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;

    // 1. The window is real: with the commit staged and unresolved, the
    //    circle's own outbound path is held shut until Rule 13 says what
    //    happened to the publish.
    if seal(world, admin, &victim, 1).await.is_err() {
        canaries += 1;
    }

    // Rule 13: only an acknowledgement a relay's own client-facing stream
    // carried licenses a confirm.
    if world
        .publish_witnessed(admin, std::slice::from_ref(&staged.commit_event))
        .await?
        .is_none()
    {
        let ingest = world
            .device(admin)?
            .manager()?
            .publish_failed(staged.pending)
            .await
            .map_err(|_| RigError::Core(Step::RollBackPublish))?;
        world.resolve_ingest(admin, ingest).await?;
        drop(guard);
        return Err(RigError::PublishNeverAcked);
    }

    set_stored_message_write_fault_for_test(&db, &key, true)
        .map_err(|_| RigError::Core(Step::OpenStore))?;
    // A peer's fix for the OTHER circle, ingested while the fault stands: the
    // ingest aborts on the state write with the content already in the engine's
    // buffer. Deliberately NOT classified — a storage fault this arm induced is
    // not an ingest disposition, and feeding it to O5 would report the harness's
    // own plant as an outcome the product could not account for.
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

    let outcome = world
        .device(admin)?
        .manager()?
        .confirm_published(staged.pending)
        .await;
    set_stored_message_write_fault_for_test(&db, &key, false)
        .map_err(|_| RigError::Core(Step::OpenStore))?;
    // The pending state is NOT resolved, and that is the point of the arm: Rule
    // 13 forbids turning this error into a `publish_failed`. The rig's own
    // staged-commit count may not outlive the call, or the closing round could
    // never settle — so the guard goes here and the engine's staged commit
    // stays, which canary 5 reads back.
    drop(guard);

    // 3. The confirm really failed.
    if outcome.is_err() {
        canaries += 1;
    }
    // 4. …and the fix the engine had already delivered is in the durable store
    //    anyway, written by the failing call's own drain. Nothing will ever
    //    deliver it again: the engine hands a replayed message back exactly
    //    once.
    if folded(world, admin, peer, &sibling)? {
        canaries += 1;
    }
    // 5. …and nothing was rolled back or retried: the commit is still staged,
    //    which is precisely what a `publish_failed` would have undone, and the
    //    device reports no circle unrecoverable over it.
    let still_staged = seal(world, admin, &victim, 3).await.is_err();
    let quiet = world
        .device(admin)?
        .manager()?
        .unrecoverable_circles()
        .is_empty();
    if still_staged && quiet {
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
        .encrypt_location(
            circle.mls_group_id(),
            &sender.keys.public_key(),
            &ProbeToken::mint(5, index).as_location(),
            LOCATION_MESSAGE_RETENTION_SECS,
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
            arm.withheld_acks == WithheldAcks::Fixed(1),
            "the one foreground publish of the eviction burns the whole ladder"
        );
        assert!(
            arm.floor
                == ExpectationFloor {
                    faults_applied: 1,
                    epochs_crossed: 1,
                    deliveries_observed: 1,
                    canaries_caught: 4,
                },
            "the swallowed acknowledgement, the twin's world epoch, and the \
             obligation before the publish, after the reopen, across the kill, \
             and the send"
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
    fn the_derived_bounds_are_the_plans() {
        let tick = Duration::from_millis(250);
        let shape = MINIMAL_SHAPE;
        assert!(
            ARMS[1].deadline(tick, &shape) == Duration::from_millis(79_750),
            "13.75 + 9 + 13 + (34 + 10)"
        );
        assert!(
            ARMS[2].deadline(tick, &shape) == Duration::from_millis(79_750),
            "13.75 + 9 + 13 + (34 + 10)"
        );
        assert!(
            ARMS[3].deadline(tick, &shape) == Duration::from_millis(35_750),
            "13.75 + 9 + 13"
        );
    }
}
