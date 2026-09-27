//! **S22** — the event a relay will not take, and the one removal that can
//! never be retried.
//!
//! A relay caps the size of an event it will accept. Below that cap everything
//! works; at it, a publish comes back `OK false invalid:` and Rule 13's
//! disposition follows — no confirm, nothing applied locally, the staged commit
//! rolled back. Three of this scenario's arms grade exactly that. The fourth
//! grades what happens when the refused commit carries a REMOVAL, which is the
//! one case where the disposition is deliberately not a rollback and the circle
//! never recovers.
//!
//! # The cap is MEASURED off this run's own event
//!
//! `nostr-relay-builder` has no event-size knob, and no Tier-1 roster reaches
//! strfry's 65 536, so the ceiling here is synthetic: the arm stages the commit
//! it is about to publish, measures that event's own JSON length, and arms the
//! plane one byte below it. That is a measurement of THIS commit — never a
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
//! buy nothing — it belongs in a `haven-core` gate over the same public API. The
//! Welcome arm below is a RELAY-side refusal and says so, so a reader does not
//! take it for the other thing.
//!
//! # The removal wedge is a RECORDED EXPECTATION, tied to OD-1 and OQ-A
//!
//! `CircleManager::publish_failed` deliberately refuses to roll back a
//! removal-bearing commit IT OWES A PUBLISH FOR — a peer's `SelfRemove`
//! auto-commit, whose obligation the receive path records before it opens the
//! publish window (`circle/manager.rs:2723`, driven from
//! `relay/auto_commit.rs:407`). The admin's own `remove_members` records no such
//! obligation and rolls back normally; the distinction is the whole reason the
//! predicate exists. Rolling an OWED one back is a silent, permanent drop of the
//! eviction, and the leaver would keep deriving the group's keys until some
//! unrelated commit moved the epoch. Parking is therefore correct. What is
//! UNDECIDED is what should happen to an obligation that can never be
//! discharged — and an oversized removal commit is exactly that, because every
//! retry refuses for the same reason the first one did. The circle then stays in
//! its publish-before-apply transition for ever: no send succeeds, every inbound
//! event is buffered, the evictee stays in every remaining member's roster, and
//! Haven reports no verdict at all.
//!
//! The arm asserts that whole state as its EXPECTATION rather than grading it.
//! Both directions are therefore covered: if the wedge stops happening, the
//! canary is unmet and the arm is **rc 3** — "the recorded expectation is
//! stale"; if a verdict starts appearing, the silence canary is unmet and it is
//! **rc 3** again, which is the correct signal, because the recorded expectation
//! must then be replaced by a graded one in the same commit. Changing it in
//! either direction without citing OD-1 (DECIDED — a per-circle verdict in the
//! circle's details sheet — and NOT BUILT) and owner decision OQ-A (name the
//! undischargeable obligation as its own cause) is a regression.
//!
//! # The wedged circle is not one of the world's, and the wedge is released at
//! the end
//!
//! The circle cannot be one of the world's: it does not send while the wedge
//! stands. `build_extra_circle` keeps it out of `world.circles()`, so no
//! world-wide oracle grades a circle this arm froze on purpose — which is also
//! why that arm declares `epochs_crossed: 0` and carries its epoch claims as
//! canaries instead.
//!
//! The obligation, though, is a property of the DEVICE and not of the circle:
//! `owed_removal_commits()` is a per-device read, so O2 and O6 would report an
//! unredeemed eviction — correctly — for every round after this arm, and the arm
//! would then be grading the world on a state it induced on purpose. So once
//! every canary above has been read, the arm lifts the cap and lands the same
//! commit, which discharges the obligation. That release is not a softening: it
//! is the arm's own matched pair, and without it "still owed after three passes"
//! would be satisfied by a world in which nothing can be published at all. A
//! REAL oversized removal has no such release — every relay refuses the same
//! bytes for the same reason, for ever — and that permanence is exactly the
//! undischargeable obligation OQ-A has to name.

use std::time::Duration;

use haven_core::circle::CommitToPublish;
use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::nostr::mls::types::{ConvergedRoster, GroupId};
use nostr::{Event, EventId, Filter, JsonUtil, Kind};

use crate::nemesis::types::{ByteCap, Fault};
use crate::oracle::undecryptable::{self, StoredRow};
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{bounds, Invariant, ProbeToken, Reach, Recovery};
use crate::relay::OVERSIZE_PREFIX;
use crate::rig::{DeviceTag, LogDrain, RelayPlane, RigError, SimCircle, Step, TimelineSink};
use crate::scenarios::{
    await_connected, closing_pairs, grade_round, round, Absence, Arm, ArmOutcome, ScenarioWorld,
    WithheldAcks, NO_GATING_ROWS,
};

/// How many foreground publish passes the wedge arm makes.
///
/// Three, and the count is the claim: one refused attempt proves "not yet", and
/// the finding is the NEVER-ness. Two further passes after the first is the
/// smallest number that makes the obligation's survival a sequence rather than a
/// point, and it is what the arm's `WithheldAcks::Fixed(3)` prices.
const WEDGE_PUBLISH_PASSES: usize = 3;

/// The arms this scenario offers.
pub const ARMS: [Arm; 4] = [
    Arm {
        label: "oversized-commit",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        // The one commit published into the refusal.
        withheld_acks: WithheldAcks::Fixed(1),
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
        withheld_acks: WithheldAcks::Fixed(1),
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
        // One publish per foreground pass: the never-ness is the finding, and
        // the arm pays for every attempt it makes.
        withheld_acks: WithheldAcks::Fixed(3),
        floor: ExpectationFloor {
            faults_applied: 1,
            // The wedged circle is outside the world's table, so this term
            // cannot see it and the canaries carry every epoch claim.
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

    let mut classified: Vec<undecryptable::Verdict> = Vec::new();
    let canaries = match arm.label {
        "oversized-commit" => oversized_commit(world, admin).await?,
        "refusal-is-relay-count-invariant" => relay_count_invariant(world, admin).await?,
        "oversized-welcome" => oversized_welcome(world).await?,
        "oversized-removal-wedges-the-circle" => {
            let remaining = tags.get(2).copied().ok_or(RigError::ShapeMismatch)?;
            wedge(world, admin, second, remaining, &mut classified).await?
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
        &classified,
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

/// A commit one byte over the cap: refused, not confirmed, nothing applied —
/// and the same commit one byte under it, acked and applied.
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
    let cap = ByteCap::new(refused.commit_event.as_json().len().saturating_sub(1));
    cap_every_plane(world, cap).await?;

    let acked = world
        .publish_witnessed(admin, std::slice::from_ref(&refused.commit_event))
        .await?;
    // 1. The refusal is machine-readable and the relay never took the event:
    //    the client heard `OK false invalid:` and no store holds it. A plane
    //    that stored it and said no would let this arm pass on the store.
    if refused_machine_readably(world, &refused.commit_event.id).await? {
        canaries += 1;
    }
    // 2. Rule 13: no acknowledgement reached the publisher, so the commit may
    //    not be confirmed, and the arm rolls it back instead.
    let rolled_back = acked.is_none()
        && world
            .device(admin)?
            .manager()?
            .publish_failed(refused.pending)
            .await
            .is_ok();
    if rolled_back {
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
    let room = ByteCap::new(accepted.commit_event.as_json().len().saturating_add(1));
    cap_every_plane(world, room).await?;
    if confirmed(world, admin, &group, accepted).await? && agreement(world, &group).await? > before
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
    let id = refused.commit_event.id;
    let cap = ByteCap::new(refused.commit_event.as_json().len().saturating_sub(1));
    cap_every_plane(world, cap).await?;
    let acked = world
        .publish_witnessed(admin, std::slice::from_ref(&refused.commit_event))
        .await?;
    let _ = world
        .device(admin)?
        .manager()?
        .publish_failed(refused.pending)
        .await
        .map_err(|_| RigError::Core(Step::RollBackPublish))?;

    // 1. EVERY plane refused the same bytes, and none of them acked: relay
    //    redundancy is the mitigation for every other publish failure in this
    //    plan, and it is the one that does nothing here. A quorum that demands
    //    more acks can only make an oversized event LESS publishable.
    if acked.is_none() && refusals_everywhere(world, &id).await? {
        canaries += 1;
    }

    // 2. The matched pair, on both planes at once: the same-shaped commit under
    //    a cap above it is carried by every plane.
    let accepted = stage(world, admin, &group, &relays).await?;
    let room = ByteCap::new(accepted.commit_event.as_json().len().saturating_add(1));
    let id = accepted.commit_event.id;
    cap_every_plane(world, room).await?;
    if confirmed(world, admin, &group, accepted).await? && stored_everywhere(world, &id).await? {
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

/// The recorded expectation: an oversized REMOVAL commit wedges its circle for
/// ever, and Haven says nothing about it.
///
/// See the module docs for what makes this stale in either direction, and for
/// the two decisions it is tied to.
async fn wedge<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    leaver: DeviceTag,
    remaining: DeviceTag,
    classified: &mut Vec<undecryptable::Verdict>,
) -> Result<usize, RigError> {
    let circle = world.build_extra_circle().await?;
    let group = circle.mls_group_id().clone();
    let leaver_hex = world.device(leaver)?.pubkey_hex();
    let commit = surface_eviction(world, admin, leaver, remaining, &circle).await?;

    let cap = ByteCap::new(commit.commit_event.as_json().len().saturating_sub(1));
    cap_every_plane(world, cap).await?;

    let mut owed_after_every_pass = true;
    for _ in 0..WEDGE_PUBLISH_PASSES {
        let acked = world
            .publish_witnessed(admin, std::slice::from_ref(&commit.commit_event))
            .await?;
        // The FFI's own no-ack rung, called exactly as every publishing plane
        // calls it. It does not roll a removal back; the obligation stands.
        let _ = world
            .device(admin)?
            .manager()?
            .publish_failed(commit.pending)
            .await
            .map_err(|_| RigError::Core(Step::RollBackPublish))?;
        owed_after_every_pass &= acked.is_none()
            && !world
                .device(admin)?
                .manager()?
                .owed_removal_commits()
                .is_empty();
    }

    let mut canaries = 0_usize;
    // 1. The S2 harm: the evictee is still in the roster of the member that
    //    never saw the commit, and still derives the circle's keys.
    if roster_of(world, remaining, &group)
        .await?
        .contains(&leaver_hex)
    {
        canaries += 1;
    }
    // 2. The circle cannot send. Every projected read — the epoch, the roster —
    //    reports the POST-merge state from the moment the commit is staged, so
    //    the send gate is the only thing that can tell the wedge from a merge.
    if seal(world, admin, &group, 1).await.is_err() {
        canaries += 1;
    }
    // 3. …and it cannot receive either: an inbound fix from the remaining
    //    member is BUFFERED before the peel, never applied. This is the receive
    //    half of the freeze, and no other scenario covers it.
    let inbound = seal(world, remaining, &group, 2).await?;
    let verdict =
        undecryptable::classify(world.device(admin)?, &inbound, StoredRow::Unknown).await?;
    classified.push(verdict);
    if matches!(
        verdict,
        undecryptable::Verdict::CommitGap | undecryptable::Verdict::ForwardDistance
    ) {
        canaries += 1;
    }
    // 4. And Haven says nothing: no circle is reported unrecoverable, on either
    //    surface. The recorded silence — OD-1's gap, and OQ-A's subject.
    world.drain_buses();
    if silent_about_the_wedge(world, admin) {
        canaries += 1;
    }
    // 5. The state is `PendingPublish` and not the `PendingProposal` dead end a
    //    rollback would have left: `do_publish_failed` clears a staged COMMIT
    //    but not the stored PROPOSAL behind it, so the day the disposition
    //    changes, this is where it shows.
    if !world
        .device(admin)?
        .session()?
        .has_pending_proposal(&group)
        .await
        .map_err(|_| RigError::Core(Step::ReadConvergenceState))?
    {
        canaries += 1;
    }

    // 6. The obligation outlived every refused pass — AND the SIZE is the only
    //    thing that was holding it: with the cap lifted, the very same commit is
    //    acked, confirmed and the obligation discharged. Without that second
    //    half, "still owed after three passes" would be satisfied by a world in
    //    which nothing can ever be published at all.
    //
    //    Releasing it is also what keeps this arm honest about the rest of the
    //    run: an unredeemed eviction obligation is a property of the DEVICE, not
    //    of the circle, so O2 and O6 would report it — correctly — for every
    //    later round, and the arm would be grading the world on a state it
    //    induced on purpose. A real oversized removal has no such release: every
    //    relay refuses the same bytes for the same reason, for ever, which is
    //    the undischargeable obligation OQ-A is about.
    if owed_after_every_pass && released(world, admin, &group, &commit).await? {
        canaries += 1;
    }
    Ok(canaries)
}

/// Lifts every cap and lands the eviction the wedge was holding.
///
/// The pending ref is still alive: the kept-owed rung returns before it touches
/// the engine, so three refused passes consumed nothing. With the planes taking
/// the event again, Rule 13 licenses the confirm on the relay's own
/// acknowledgement — and the confirm is what discharges the obligation.
async fn released<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    group: &GroupId,
    commit: &CommitToPublish,
) -> Result<bool, RigError> {
    heal(world).await?;
    if world
        .publish_witnessed(admin, std::slice::from_ref(&commit.commit_event))
        .await?
        .is_none()
    {
        return Ok(false);
    }
    let ingest = world
        .device(admin)?
        .manager()?
        .confirm_published(commit.pending)
        .await
        .map_err(|_| RigError::Core(Step::ConfirmPublished))?;
    world.resolve_ingest(admin, ingest).await?;
    Ok(world
        .device(admin)?
        .manager()?
        .owed_removal_commits()
        .is_empty()
        && seal(world, admin, group, 3).await.is_ok())
}

/// Drives a peer's `SelfRemove` proposal until the eviction commit surfaces to
/// the caller with its obligation recorded.
///
/// The engine schedules the auto-commit behind a short jitter and surfaces it on
/// the next convergence tick, so the loop re-ticks with a fresh location from a
/// third member rather than waiting: a tick is what advances convergence, and a
/// sleep would be waiting for a clock instead of for the state.
async fn surface_eviction<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    leaver: DeviceTag,
    remaining: DeviceTag,
    circle: &SimCircle,
) -> Result<CommitToPublish, RigError> {
    let group = circle.mls_group_id().clone();
    let proposal = world
        .device(leaver)?
        .manager()?
        .propose_leave(&group)
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    let mut ingest = world
        .device(admin)?
        .manager()?
        .decrypt_location_collecting_commits(&proposal)
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;

    let bound = bounds::round_trip(Recovery::Undisturbed);
    let started = tokio::time::Instant::now();
    let mut index = 0_u32;
    loop {
        if let Some(commit) = ingest.auto_commits.pop() {
            return Ok(commit);
        }
        if started.elapsed() >= bound {
            // The eviction never surfaced, so the arm never reached the state
            // it records: that is "this proved nothing", not a finding.
            return Err(RigError::Core(Step::StageCommit));
        }
        index = index.wrapping_add(1);
        let tick = seal(world, remaining, &group, index).await?;
        ingest = world
            .device(admin)?
            .manager()?
            .decrypt_location_collecting_commits(&tick)
            .await
            .map_err(|_| RigError::Core(Step::StageCommit))?;
    }
}

/// Whether neither surface reports the wedged circle as unrecoverable.
fn silent_about_the_wedge<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
) -> bool {
    let quiet_bus = world
        .devices()
        .iter()
        .all(|device| device.ledger().unrecoverable() == 0);
    quiet_bus
        && world.device(admin).is_ok_and(|device| {
            device
                .manager()
                .is_ok_and(|manager| manager.unrecoverable_circles().is_empty())
        })
}

/// One staged relay-list commit, unresolved.
struct Staged {
    commit_event: Event,
    pending: haven_core::nostr::mls::types::PendingStateRef,
}

/// Stages a relay-list commit on `device` without resolving it.
async fn stage<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
    relays: &[String],
) -> Result<Staged, RigError> {
    let staged = world
        .device(device)?
        .manager()?
        .update_circle_relays(group, relays)
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    Ok(Staged {
        commit_event: staged.commit_event,
        pending: staged.pending,
    })
}

/// Publishes `staged` and confirms it on a witnessed acknowledgement.
async fn confirmed<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
    staged: Staged,
) -> Result<bool, RigError> {
    let guard = world.note_pending_staged();
    let acked = world
        .publish_witnessed(device, std::slice::from_ref(&staged.commit_event))
        .await?;
    let manager = world.device(device)?.manager()?;
    let ingest = if acked.is_some() {
        manager
            .finalize_relay_update(staged.pending, group)
            .await
            .map_err(|_| RigError::Core(Step::ConfirmPublished))?
    } else {
        manager
            .publish_failed(staged.pending)
            .await
            .map_err(|_| RigError::Core(Step::RollBackPublish))?
    };
    world.resolve_ingest(device, ingest).await?;
    drop(guard);
    Ok(acked.is_some())
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

/// Seals one location at `device`'s current epoch, unpublished.
async fn seal<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
    index: u32,
) -> Result<Event, RigError> {
    let sender = world.device(device)?;
    sender
        .manager()?
        .encrypt_location(
            group,
            &sender.keys.public_key(),
            &ProbeToken::mint(22, index).as_location(),
            LOCATION_MESSAGE_RETENTION_SECS,
        )
        .await
        .map(|(event, _, _)| event)
        .map_err(|_| RigError::Core(Step::Publish))
}

#[cfg(test)]
mod tests {
    use super::{ARMS, WEDGE_PUBLISH_PASSES};
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
    fn the_wedge_arm_pays_for_every_pass_it_makes_and_reads_the_whole_freeze() {
        assert!(
            ARMS[3].withheld_acks == WithheldAcks::Fixed(3) && WEDGE_PUBLISH_PASSES == 3,
            "one unacknowledged publish per foreground pass, and three of them: \
             one attempt proves `not yet`, and the never-ness needs a sequence"
        );
        assert!(
            ARMS[3].floor.canaries_caught == 6,
            "the evictee still in the roster, the send that fails, the receive \
             that buffers, the silence, the staged commit that is not a stranded \
             proposal, and the obligation that outlives every refused pass and is \
             discharged the moment the size stops being the problem"
        );
        assert!(
            ARMS[3].floor.epochs_crossed == 0,
            "the wedged circle is outside the world's table, so a term that cannot \
             see it may not be declared as if it could"
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
