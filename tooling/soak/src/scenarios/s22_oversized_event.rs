//! **S22** — the event a relay will not take, and the one removal that can
//! never be retried.
//!
//! A relay caps the size of an event it will accept. Below that cap everything
//! works; at it, a publish comes back `OK false invalid:` and Rule 13's
//! disposition follows — no confirm, nothing applied locally, the staged commit
//! rolled back by the product's driver. Three of this scenario's arms grade
//! exactly that. The fourth records what happens when the refused commit
//! carries a REMOVAL, which can never be published and so never lands.
//!
//! # The cap is MEASURED off this run's own event
//!
//! `nostr-relay-builder` has no event-size knob, and no Tier-1 roster reaches
//! strfry's 65 536, so the ceiling here is synthetic: the arm stages the commit
//! under its record — the product's staging call, which sends nothing —
//! measures the frozen event's own JSON length, and arms the plane one byte
//! below it before the driver sends it. That is a measurement of THIS commit — never a
//! literal, and never a restatement of a production relay's configuration. The
//! matched pair one byte the other way is what proves the SIZE is the variable
//! and not the roster, the plane or the fan-out. The real caps of a real relay
//! are T2-19's subject, and neither run subsumes the other.
//!
//! # What this scenario is NOT about
//!
//! NIP-44's own plaintext ceiling is a client-side refusal that happens before a
//! socket opens: `MAX_SUPPORTED_PLAINTEXT_SIZE` is private to the `nostr` crate
//! and the error comes back without anything crossing the wire. That is a
//! dependency invariant, and paying for a whole soak world to observe it would
//! buy nothing — it is proved in haven-core
//! (`haven-core/tests/nip44_plaintext_ceiling.rs`), not by a soak arm. The
//! Welcome arm below is a RELAY-side refusal and says so, so a reader does not
//! take it for the other thing.
//!
//! # The oversized removal is a RECORDED EXPECTATION, tied to OD-1 and OQ-A
//!
//! A removal commit too large for every relay can never be published, whatever
//! Haven does with it. Which shape that takes is a property of the relays, and
//! this arm MEASURES it off the rig's own: the relay double refuses an
//! oversized frame `OK false invalid:` (`relay/policies.rs` `OVERSIZE_PREFIX`),
//! a machine-readable rejection. So every target proved it refused and none may
//! hold the commit, and the product's driver rolls the eviction back (Rule 13,
//! the product's own); the engine arms the eviction again, and Haven's refused
//! eviction wait (`RESTAGE_BASE_MS`, doubling to `RETRY_MAX_MS`) holds the
//! circle's location sends — deferred, typed `DepartureDue` — while it runs.
//! The circle is never held in a publish-before-apply transition, the evictee
//! stays in every remaining member's roster, and Haven raises no dedicated
//! verdict about it. (A relay that dropped the frame with no answer would
//! produce the other shape: possibly exposed, so pending with paced retries
//! and the circle's sends waiting behind it. The rig's relays do not; the
//! tracker row T-OQA records which one was measured.)
//!
//! The arm asserts that whole state as its EXPECTATION rather than grading it.
//! Both directions are therefore covered: if the shape changes — the commit
//! left pending, or the eviction not re-armed — a canary is unmet and the arm
//! is **rc 3**, "the recorded expectation is stale"; if a verdict starts
//! appearing, the silence canary is unmet and it is **rc 3** again, which is
//! the correct signal, because the recorded expectation must then be replaced
//! by a graded one in the same commit. Changing it in either direction
//! without citing OD-1 (BUILT — one per-circle card in the circle's details
//! sheet, read from `circle_recovery`, which no arm reads yet) and owner
//! decision OQ-A (name the state as its own cause) is a regression. The cause
//! keeps the existing neutral wording until W9r names it.
//!
//! # The circle is not one of the world's, and the eviction is released at the
//! end
//!
//! The circle cannot be one of the world's: its sends wait while the refused
//! eviction's wait runs. `build_extra_circle` keeps it out of
//! `world.circles()`, so no world-wide oracle grades a circle this arm froze
//! on purpose — which is also why that arm declares `epochs_crossed: 0` and
//! carries its epoch claims as canaries instead.
//!
//! Once every canary has been read, the arm lifts the cap and lets the product
//! land the eviction it re-armed. That release is not a softening: it is the
//! arm's own matched pair, and without it the canaries would be satisfied by a
//! world in which nothing can be published at all. A REAL oversized removal has
//! no such release — every relay refuses the same bytes for the same reason,
//! for ever — and that permanence is exactly the state OQ-A has to name.

use std::time::Duration;

use haven_core::nostr::mls::types::{ConvergedRoster, EpochState, FanoutMls, GroupId};
use haven_core::relay::fanout::{FanoutClock as _, LocationSeal, SendHeld, WallClock};
use nostr::{Event, EventId, Filter, JsonUtil, Kind};

use crate::nemesis::types::{ByteCap, Fault};
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{bounds, Invariant, ProbeToken, Reach, Recovery};
use crate::relay::OVERSIZE_PREFIX;
use crate::rig::{
    DeviceTag, LogDrain, PacingClock, PublishVerdict, RelayPlane, RigError, Step, TimelineSink,
};
use crate::scenarios::{
    await_condition, await_connected, closing_pairs, grade_round, pending_record, round,
    surface_eviction, Absence, Arm, ArmOutcome, Recorded, ScenarioWorld, WithheldAcks,
    NO_GATING_ROWS,
};

/// How many paced drives the wedge arm gives the eviction's record to end in:
/// the first finds the relays not yet due again (the unreachable attempt the
/// staging made earned a wait), the clock is stepped past it, and the next
/// sends into the refusal; the third is the margin for one more wait.
const WEDGE_DRIVES: usize = 3;

/// How far the release steps the pacing clock before each drive: past the
/// longest wait a refused eviction earns (Haven's `RESTAGE_BASE_MS`, doubling
/// to `RETRY_MAX_MS`), so the wait the refusal earned is behind it at the
/// first drive. A policy clock; nothing a relay produced is compared with it.
const REFUSAL_WAIT_STEP_MS: u64 = haven_core::relay::fanout::RETRY_MAX_MS;

/// The arms this scenario offers.
pub const ARMS: [Arm; 4] = [
    Arm {
        label: "oversized-commit",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        // The refusal is an answer: the drive into it waits for nothing.
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 1,
            // The matched pair re-stages the same commit under a cap one byte
            // ABOVE it and confirms it, on one of the world's own circles — so
            // an arm that reached its canaries without moving an epoch never
            // ran the half that proves the plane was not simply broken.
            epochs_crossed: 1,
            deliveries_observed: 1,
            canaries_caught: 4,
        },
    },
    Arm {
        label: "refusal-is-relay-count-invariant",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            // One cap per plane: the arm's whole claim is that a second relay
            // changes nothing, so a world where only one took the fault would
            // be proving it against one relay.
            faults_applied: 2,
            // Its matched pair confirms on a world circle too, for the same
            // reason the arm above pins one.
            epochs_crossed: 1,
            deliveries_observed: 1,
            canaries_caught: 2,
        },
    },
    Arm {
        label: "oversized-welcome",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        // A create publishes one welcome per invited member, every one of them
        // into the refusal.
        withheld_acks: WithheldAcks::PerInvitedMember,
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 3,
        },
    },
    Arm {
        label: "oversized-removal-wedges-the-circle",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        // The staging drive into planes that are down: one call of MDK's
        // relay client at most. The refusal after it is an answer.
        withheld_acks: WithheldAcks::FanoutDrives(1),
        floor: ExpectationFloor {
            // The size cap; the outage the staging drive meets is the arm's
            // own instrument.
            faults_applied: 1,
            // The circle is outside the world's table, so this term cannot see
            // it and the canaries carry every epoch claim.
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 6,
        },
    },
];

/// Runs one arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not one this scenario offers,
/// [`RigError::ShapeMismatch`] if the world is too small for it — the
/// relay-count arm needs a second plane, and the wedge arm needs a third device
/// so a member remains after the leaver goes — otherwise [`RigError`] naming the
/// step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [admin, second, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };

    let canaries = match arm.label {
        "oversized-commit" => oversized_commit(world, admin).await?,
        "refusal-is-relay-count-invariant" => relay_count_invariant(world, admin).await?,
        "oversized-welcome" => oversized_welcome(world).await?,
        "oversized-removal-wedges-the-circle" => {
            let remaining = tags.get(2).copied().ok_or(RigError::ShapeMismatch)?;
            wedge(world, admin, second, remaining).await?
        }
        _ => return Err(RigError::UnknownTarget),
    };
    heal(world).await?;
    // A heal is a bring-up too, and the closing round is priced `Undisturbed`:
    // it may begin only once every engine sees every plane again — at once in
    // this scenario's own worlds, where no socket ever closed, and after the
    // pool's ladder in a control that took a plane down.
    await_connected(
        world,
        world.relays().len(),
        usize::MAX,
        bounds::round_trip(Recovery::Reconnect),
    )
    .await?;

    // Graded over the WORLD's circles. Three arms touch one of them and put it
    // back; the fourth touches none, because a circle that never sends again
    // may not be one a world-wide oracle grades.
    let pairs = closing_pairs(world, admin);
    let closing = round(
        1,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &[],
        &[],
    );
    let graded = grade_round(
        world,
        &closing,
        &[
            Invariant::Quiescence,
            Invariant::LocationRoundTrip,
            Invariant::SendPathLiveness,
        ],
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

/// A commit one byte over the cap: refused, rolled back by the driver,
/// nothing applied — and the same commit one byte under it, acked and applied.
async fn oversized_commit<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
) -> Result<usize, RigError> {
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let relays = extended_relay_list(world, "s22-oversized");
    let before = agreement(world, &group).await?;
    let gating_before = gating(world, admin, &group).await?;

    let mut canaries = 0_usize;
    let refused = stage(world, admin, &group, &relays).await?;
    let cap = ByteCap::new(refused.commit.as_json().len().saturating_sub(1));
    cap_every_plane(world, cap).await?;
    let verdict = drive(world, admin, &group, &refused).await?;
    // 1. The refusal is machine-readable and the relay never took the event:
    //    the client heard `OK false invalid:` and no store holds it. A plane
    //    that stored it and said no would let this arm pass on the store.
    if refused_machine_readably(world, &refused.commit.id).await? {
        canaries += 1;
    }
    // 2. Rule 13, the product's: every relay proved it refused and none may
    //    hold the commit, so the driver rolled it back.
    if verdict == PublishVerdict::RolledBack {
        canaries += 1;
    }
    // 3. …and nothing was applied locally: every device holds the epoch and the
    //    roster it held before, and the publisher carries no new gating row.
    if agreement(world, &group).await? == before
        && gating(world, admin, &group).await? == gating_before
    {
        canaries += 1;
    }

    // 4. The matched pair: the same commit, re-staged, one byte of cap the
    //    other way — acked, confirmed, and the epoch moves. Without it the arm
    //    would pass on a plane that was simply broken.
    let accepted = stage(world, admin, &group, &relays).await?;
    let room = ByteCap::new(accepted.commit.as_json().len().saturating_add(1));
    cap_every_plane(world, room).await?;
    // Every device follows it: the peers apply it once MDK's quiescence window
    // closes, so the agreement is awaited, bounded, rather than read once.
    if drive(world, admin, &group, &accepted).await? == PublishVerdict::Confirmed
        && await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
            Ok(agreement(world, &group).await? > before)
        })
        .await?
    {
        canaries += 1;
    }
    Ok(canaries)
}

/// The same bytes to two relays: two refusals, never one success.
async fn relay_count_invariant<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
) -> Result<usize, RigError> {
    if world.relays().len() < 2 {
        // One plane cannot say anything about relay redundancy, and an arm that
        // ran here would be the single-relay arm wearing this one's label.
        return Err(RigError::ShapeMismatch);
    }
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let relays = extended_relay_list(world, "s22-invariant");

    let mut canaries = 0_usize;
    let refused = stage(world, admin, &group, &relays).await?;
    let id = refused.commit.id;
    let cap = ByteCap::new(refused.commit.as_json().len().saturating_sub(1));
    cap_every_plane(world, cap).await?;
    let verdict = drive(world, admin, &group, &refused).await?;

    // 1. EVERY plane refused the same bytes, and none of them acked: relay
    //    redundancy is the mitigation for every other publish failure in this
    //    plan, and it is the one that does nothing here. A quorum that demands
    //    more acks can only make an oversized event LESS publishable.
    if verdict == PublishVerdict::RolledBack && refusals_everywhere(world, &id).await? {
        canaries += 1;
    }

    // 2. The matched pair, on both planes at once: the same-shaped commit under
    //    a cap above it is carried by every plane.
    let accepted = stage(world, admin, &group, &relays).await?;
    let room = ByteCap::new(accepted.commit.as_json().len().saturating_add(1));
    let id = accepted.commit.id;
    cap_every_plane(world, room).await?;
    if drive(world, admin, &group, &accepted).await? == PublishVerdict::Confirmed
        && stored_everywhere(world, &id).await?
    {
        canaries += 1;
    }
    Ok(canaries)
}

/// A create whose welcomes are over the cap is not a create.
///
/// This is a RELAY-side refusal — the welcome crossed the socket and came back
/// `OK false invalid:` — and deliberately not the NIP-44 plaintext ceiling,
/// which refuses client-side before a socket opens and is a dependency
/// invariant rather than a durability scenario.
async fn oversized_welcome<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
) -> Result<usize, RigError> {
    let group = world.circles().first().ok_or(RigError::ShapeMismatch)?;
    let group = group.mls_group_id().clone();
    let before = agreement(world, &group).await?;
    let mut canaries = 0_usize;

    // 1. The control, in this same world: an uncapped create succeeds and its
    //    welcomes really reach the planes. It is also where the cap comes from.
    if world.build_extra_circle().await.is_ok() {
        canaries += 1;
    }
    let smallest = smallest_welcome(world).await?;
    let cap = ByteCap::new(smallest.saturating_sub(1));
    cap_every_plane(world, cap).await?;

    let published_before = published_ids(world);
    let refused = world.build_extra_circle().await;
    // 2. Under the cap the create is rolled back for want of an acked welcome,
    //    and the planes really refused rather than fell silent: every welcome
    //    the client put on the wire came back `OK false invalid:`. A silence
    //    would be an outage wearing this arm's label.
    if matches!(refused, Err(RigError::WelcomeNeverAcked))
        && every_new_publish_was_refused(world, &published_before).await?
    {
        canaries += 1;
    }
    // 3. …and the world's own circles are untouched by a create that failed.
    if agreement(world, &group).await? == before {
        canaries += 1;
    }
    Ok(canaries)
}

/// The recorded expectation, measured off the rig's relays: what the product
/// does with a REMOVAL commit no relay will take.
///
/// The relays answer `OK false invalid:` — a machine-readable rejection — so
/// every target proved it refused and none may hold the commit: the driver
/// rolls the eviction back, and the engine arms it again. The circle is never
/// held in a publish-before-apply transition, the removal stays undone, and
/// Haven says nothing about it. See the module docs for what makes this stale
/// in either direction, and for the two decisions it is tied to.
async fn wedge<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    leaver: DeviceTag,
    remaining: DeviceTag,
) -> Result<usize, RigError> {
    let circle = world.build_extra_circle().await?;
    let group = circle.mls_group_id().clone();
    let leaver_hex = world.device(leaver)?.pubkey_hex();
    // Every plane down while the eviction is staged: its first drive sends
    // nothing a relay could hold, and the commit is measured off its record.
    for plane in world.relays_mut() {
        plane.apply(Fault::Down).await?;
    }
    let eviction = surface_eviction(world, admin, leaver, (remaining, 22), &circle).await?;
    heal(world).await?;
    let cap = ByteCap::new(eviction.commit.as_json().len().saturating_sub(1));
    cap_every_plane(world, cap).await?;

    // The refused send: drives, the clock stepped past each wait the drive
    // announces, until the eviction's record has ended — the unreachable
    // attempt's wait first, then the refusal.
    let clock = PacingClock::default();
    let mut ended = false;
    for _ in 0..WEDGE_DRIVES {
        let outcome = world.resume_paced(admin, &clock).await?;
        if pending_record(world.device(admin)?, &group)
            .await?
            .is_none()
        {
            ended = true;
            break;
        }
        clock.step(outcome.retry_after_ms.unwrap_or(0));
    }
    // Read inside the wait the refusal earned, before the clock moves again.
    let held = world
        .seal_fix(
            admin,
            &group,
            &ProbeToken::mint(22, 1).as_location(),
            &clock,
        )
        .await?
        .seal;
    // …and once that wait is over, before the cap is lifted: the eviction is
    // still due and unmade. MDK re-arms it 10–50 ms of its own monotonic time
    // after the rollback (`message_processor/mod.rs:50-51,1310-1321`); the
    // send is made once the engine announces it due, so its preflight makes
    // the eviction again and the cap refuses it again, never a race with
    // that deadline.
    clock.step(REFUSAL_WAIT_STEP_MS);
    let due = await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
        Ok(world
            .device(admin)?
            .session()?
            .eviction_due_after_for_test(&group)
            .await
            == Some(Duration::ZERO))
    })
    .await?;
    let after = world
        .seal_fix(
            admin,
            &group,
            &ProbeToken::mint(22, 2).as_location(),
            &clock,
        )
        .await?
        .seal;

    let mut canaries = 0_usize;
    // 1. The shape the relays produce: a machine-readable rejection, and no
    //    store holds the commit.
    if ended && refused_machine_readably(world, &eviction.commit.id).await? {
        canaries += 1;
    }
    // 2. …so the driver rolled the eviction back — no record of it is left
    //    pending, and the circle is not held in a publish-before-apply
    //    transition — and the engine armed it again.
    let rearmed = world
        .device(admin)?
        .session()?
        .eviction_due_after_for_test(&group)
        .await
        .is_some();
    if ended
        && !matches!(
            world.device(admin)?.session()?.epoch_state(&group).await,
            Some(EpochState::PendingPublish(_))
        )
        && rearmed
    {
        canaries += 1;
    }
    // 3. The removal stays undone: the evictee is still in the roster of the
    //    member that never saw a commit, and still derives the circle's keys.
    if roster_of(world, remaining, &group)
        .await?
        .contains(&leaver_hex)
    {
        canaries += 1;
    }
    // 4. From the refusal until the release no location is sealed for the
    //    member who left: inside the wait the refusal earned and after it, a
    //    location is deferred, typed — the departure is due.
    if due
        && matches!(held, LocationSeal::Deferred(SendHeld::DepartureDue))
        && matches!(after, LocationSeal::Deferred(SendHeld::DepartureDue))
    {
        canaries += 1;
    }
    // 5. And Haven says nothing: no circle is reported unrecoverable, on either
    //    surface. The recorded silence — OQ-A's subject.
    world.drain_buses();
    if silent_about_the_wedge(world, admin).await {
        canaries += 1;
    }
    // 6. The SIZE is the only thing holding it: with the cap lifted the
    //    re-armed eviction is staged again, accepted and applied — the evictee
    //    leaves the roster and nothing is left pending. Without that, the
    //    canaries above would be satisfied by a world in which nothing can be
    //    published at all. A REAL oversized removal has no such release: every
    //    relay refuses the same bytes for the same reason, for ever.
    if released(world, admin, &group, &leaver_hex, &clock).await? {
        canaries += 1;
    }
    Ok(canaries)
}

/// Lifts every cap and lets the product land the eviction it re-armed: the
/// foreground drive (`Publishing::resume`) stages an eviction left due in a
/// circle the session has caught up with, so the circle is marked caught up —
/// it has no engine subscription, and the mark stands for the sweep the app
/// would have run — and drives run on `clock` until the eviction is staged
/// again (the engine's own deadline, and the wait the refusal earned), sent,
/// accepted and applied. Whether it got there inside the round trip.
async fn released<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    group: &GroupId,
    leaver_hex: &str,
    clock: &PacingClock,
) -> Result<bool, RigError> {
    heal(world).await?;
    let world: &ScenarioWorld<T, L> = world;
    world
        .device(admin)?
        .session()?
        .mark_caught_up_for_test(group);
    await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
        clock.step(REFUSAL_WAIT_STEP_MS);
        let _ = world.resume_paced(admin, clock).await?;
        Ok(pending_record(world.device(admin)?, group).await?.is_none()
            && !roster_of(world, admin, group)
                .await?
                .iter()
                .any(|member| member == leaver_hex))
    })
    .await
}

/// Whether neither surface reports the wedged circle as unrecoverable.
async fn silent_about_the_wedge<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
) -> bool {
    let quiet_bus = world
        .devices()
        .iter()
        .all(|device| device.ledger().unrecoverable() == 0);
    if !quiet_bus {
        return false;
    }
    match world.device(admin).and_then(|device| device.manager()) {
        Ok(manager) => manager.unrecoverable_circles().await.is_empty(),
        Err(_) => false,
    }
}

/// Stages a relay-list commit on `device` under its record, sending nothing:
/// the product's staging call, so the commit can be measured before any relay
/// is handed it.
async fn stage<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
    relays: &[String],
) -> Result<Recorded, RigError> {
    let staged = world
        .device(device)?
        .manager()?
        .update_circle_relays_staging(group, relays, WallClock.now_ms())
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    let id = staged.commit.ok_or(RigError::Core(Step::StageCommit))?;
    let probe = world
        .device(device)?
        .session()?
        .fanout_probe_for_test(&id)
        .await
        .ok()
        .flatten()
        .ok_or(RigError::Core(Step::StageCommit))?;
    let commit = Event::from_json(&probe.payload).map_err(|_| RigError::Core(Step::StageCommit))?;
    Ok(Recorded { id, commit })
}

/// One foreground drive of `device` (`Publishing::resume`), and where
/// `staged`'s commit stands after it.
async fn drive<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
    staged: &Recorded,
) -> Result<PublishVerdict, RigError> {
    let before = world
        .device(device)?
        .manager()?
        .group_epoch(group)
        .await
        .map_err(|_| RigError::Core(Step::ReadEpoch))?;
    let _ = world.resume(device).await?;
    stood(world, device, group, staged, Some(before)).await
}

/// Where `staged`'s commit stands on `device`: read off its record while it
/// stands, and, once the record is gone, off the epoch it would have moved
/// (`before`, when the caller read one) — or the engine's own state.
async fn stood<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
    staged: &Recorded,
    before: Option<u64>,
) -> Result<PublishVerdict, RigError> {
    let session = world.device(device)?.session()?;
    let probe = session
        .fanout_probe_for_test(&staged.id)
        .await
        .map_err(|_| RigError::Core(Step::ReadConvergenceState))?;
    if let Some(probe) = probe {
        return Ok(match probe.mls {
            FanoutMls::Pending => PublishVerdict::Unresolved,
            FanoutMls::Confirmed => PublishVerdict::Confirmed,
            FanoutMls::RolledBack | FanoutMls::NotApplicable => PublishVerdict::RolledBack,
        });
    }
    let now = world
        .device(device)?
        .manager()?
        .group_epoch(group)
        .await
        .map_err(|_| RigError::Core(Step::ReadEpoch))?;
    Ok(if before.is_some_and(|before| now > before) {
        PublishVerdict::Confirmed
    } else {
        PublishVerdict::RolledBack
    })
}

/// The world's relay list plus one address it does not already hold, so the
/// commit is a real change rather than a no-op.
fn extended_relay_list<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    salt: &str,
) -> Vec<String> {
    let mut relays = world.relay_urls();
    relays.push(format!("wss://{salt}.example.com"));
    relays
}

/// Arms every plane with the same cap.
async fn cap_every_plane<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    max_bytes: ByteCap,
) -> Result<(), RigError> {
    for plane in world.relays_mut() {
        plane.apply(Fault::RefuseOversize { max_bytes }).await?;
    }
    Ok(())
}

/// Undoes every cap.
async fn heal<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
) -> Result<(), RigError> {
    for plane in world.relays_mut() {
        plane.apply(Fault::Heal).await?;
    }
    Ok(())
}

/// Whether some plane refused `id` machine-readably and none stored it.
async fn refused_machine_readably<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    id: &EventId,
) -> Result<bool, RigError> {
    let mut refused = false;
    for plane in world.relays() {
        if plane.stored(id).await? || plane.witnessed_ok(id) {
            return Ok(false);
        }
        refused |= plane
            .ledger()
            .refusal(id)
            .is_some_and(|message| message.starts_with(OVERSIZE_PREFIX.as_str()));
    }
    Ok(refused)
}

/// Whether EVERY plane refused `id` machine-readably and none stored it.
async fn refusals_everywhere<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    id: &EventId,
) -> Result<bool, RigError> {
    for plane in world.relays() {
        if plane.stored(id).await? || plane.witnessed_ok(id) {
            return Ok(false);
        }
        if !plane
            .ledger()
            .refusal(id)
            .is_some_and(|message| message.starts_with(OVERSIZE_PREFIX.as_str()))
        {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Whether every plane's store holds `id`.
async fn stored_everywhere<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    id: &EventId,
) -> Result<bool, RigError> {
    for plane in world.relays() {
        if !plane.stored(id).await? {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Every event id the planes have seen a client publish.
fn published_ids<T: TimelineSink, L: LogDrain>(world: &ScenarioWorld<T, L>) -> Vec<EventId> {
    world
        .relays()
        .iter()
        .flat_map(|plane| plane.ledger().published_ids())
        .collect()
}

/// Whether every event published since `before` was refused with the oversize
/// prefix by the plane that saw it.
///
/// The refused welcome's id cannot be read off a store — a refused event is
/// never stored — so it is read off the publish side of the ledger, which the
/// proxy records before it decides anything.
async fn every_new_publish_was_refused<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    before: &[EventId],
) -> Result<bool, RigError> {
    let mut seen_one = false;
    for plane in world.relays() {
        for id in plane.ledger().published_ids() {
            if before.contains(&id) {
                continue;
            }
            if plane.stored(&id).await? {
                return Ok(false);
            }
            if !plane
                .ledger()
                .refusal(&id)
                .is_some_and(|message| message.starts_with(OVERSIZE_PREFIX.as_str()))
            {
                return Ok(false);
            }
            seen_one = true;
        }
    }
    Ok(seen_one)
}

/// The smallest gift wrap any plane is holding, in the bytes a cap measures.
///
/// Measured off the welcomes this run really minted. The smallest, because a cap
/// one byte below it refuses every welcome at or above it: NIP-44 pads in
/// buckets, so welcomes of one world land on one size, and taking the minimum is
/// what keeps the refusal a property of the size rather than of a draw.
async fn smallest_welcome<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
) -> Result<usize, RigError> {
    let mut smallest: Option<usize> = None;
    for plane in world.relays() {
        for event in plane
            .stored_page(Filter::new().kind(Kind::GiftWrap))
            .await?
        {
            let len = event.as_json().len();
            smallest = Some(smallest.map_or(len, |best: usize| best.min(len)));
        }
    }
    // A world with no welcome on any plane never created a circle, so there is
    // nothing this arm could cap.
    smallest.ok_or(RigError::ShapeMismatch)
}

/// The epoch every device holds for `group`, or `None` when they disagree.
async fn agreement<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    group: &GroupId,
) -> Result<Option<u64>, RigError> {
    let mut agreed: Option<u64> = None;
    for device in world.devices() {
        let epoch = world
            .device(device.tag)?
            .manager()?
            .group_epoch(group)
            .await
            .map_err(|_| RigError::Core(Step::ReadEpoch))?;
        match agreed {
            None => agreed = Some(epoch),
            Some(first) if first == epoch => {}
            Some(_) => return Ok(None),
        }
    }
    Ok(agreed)
}

/// How many stored rows gate `device`'s outbound path for `group`.
async fn gating<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
) -> Result<usize, RigError> {
    world
        .device(device)?
        .session()?
        .gating_input_count(group)
        .await
        .map_err(|_| RigError::Core(Step::ReadGatingRows))
}

/// One device's converged roster for one circle, sorted. Empty when the device
/// holds no converged roster at all.
async fn roster_of<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
) -> Result<Vec<String>, RigError> {
    let roster = world
        .device(device)?
        .session()?
        .converged_member_pubkeys(group)
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
    use super::{ARMS, WEDGE_DRIVES};
    use crate::oracle::Recovery;
    use crate::scenarios::WithheldAcks;

    #[test]
    fn every_arm_caps_a_plane_and_recovers_from_nothing_else() {
        for arm in &ARMS {
            assert!(
                arm.recovery == Recovery::Undisturbed,
                "{}: a size cap closes no socket",
                arm.label
            );
            assert!(
                !arm.resubscribes,
                "{}: nothing re-opens a REQ, so the subscribe ladder is not in the bound",
                arm.label
            );
            assert!(
                arm.floor.faults_applied >= 1,
                "{}: the cap IS the fault, and an arm that applied none proves nothing",
                arm.label
            );
        }
    }

    #[test]
    fn the_relay_count_arm_is_the_only_one_that_demands_a_second_plane() {
        assert!(
            ARMS[1].floor.faults_applied == 2,
            "one cap per plane: the claim is that a second relay changes nothing"
        );
        for arm in [ARMS[0], ARMS[2], ARMS[3]] {
            assert!(
                arm.floor.faults_applied == 1,
                "{}: one plane's cap is the whole fault",
                arm.label
            );
        }
    }

    #[test]
    fn a_refused_commit_is_priced_as_the_answer_it_is() {
        for arm in [ARMS[0], ARMS[1]] {
            assert!(
                arm.withheld_acks == WithheldAcks::None,
                "{}: a relay that refuses has answered; the drive waits for nothing",
                arm.label
            );
        }
    }

    #[test]
    fn the_removal_arm_prices_its_one_unanswered_drive_and_reads_the_measured_shape() {
        assert!(
            ARMS[3].withheld_acks == WithheldAcks::FanoutDrives(1) && WEDGE_DRIVES == 3,
            "the staging drive into planes that are down is the arm's one call nobody \
             answers; the refusal after it is an answer"
        );
        assert!(
            ARMS[3].floor.canaries_caught == 6,
            "the machine-readable refusal, the rollback and the re-arm, the evictee still \
             in the roster, the send deferred inside the refusal's wait, the silence, and \
             the eviction that lands the moment the size stops being the problem"
        );
        assert!(
            ARMS[3].floor.epochs_crossed == 0,
            "the circle is outside the world's table, so a term that cannot see it may \
             not be declared as if it could"
        );
    }

    #[test]
    fn the_welcome_arm_prices_one_withheld_ack_per_invited_member() {
        assert!(
            ARMS[2].withheld_acks == WithheldAcks::PerInvitedMember,
            "a create publishes a welcome for every member the admin invites, and \
             under the cap every one of them is refused"
        );
        assert!(
            ARMS[2].floor.canaries_caught == 3,
            "the uncapped control, the refusal that is not a silence, and the \
             world's own circles left untouched"
        );
    }
}
