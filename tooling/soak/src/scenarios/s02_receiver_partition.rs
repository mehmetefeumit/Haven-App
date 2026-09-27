//! **S02** — a second publisher keeps publishing while one receiver is
//! partitioned from the relay, and the receiver recovers what it missed.
//!
//! The promise (ENV-13): a partition between the relay and ONE device costs
//! that device delivery, and nothing else. The relay stores and acknowledges as
//! it always did, the unpartitioned peer keeps receiving throughout, and when
//! the partition heals the device recovers the commit it missed from its own
//! persisted cursor and reads every fix minted after it.
//!
//! # A partition is a dropped frame, not a dropped socket
//!
//! `Fault::DropClass` withholds one class of server→client `EVENT` frame on one
//! device's own endpoint. No socket closes, so the pool's reconnect ladder is
//! genuinely not in the path: both arms recover from `Undisturbed`, and
//! `partitioned-receiver` pays `resubscribes` for the one thing it does to
//! recover — a pause and a resume, which re-issues every REQ from the persisted
//! cursor. That cursor never advanced during the partition (a generation spends
//! its one advance on its own `EOSE`, and no generation was opened), so the
//! relay replays everything the device missed.
//!
//! An endpoint holds ONE dropped class at a time, so the full partition is two
//! phases — the application class first, then the handshake class, each armed
//! ahead of the traffic it withholds. The second phase is also what makes both
//! absences at the victim's endpoint FINAL facts rather than races: a fix
//! published after the commit crosses that endpoint (its class is no longer
//! dropped), and one connection's frames are written in order, so once that fix
//! is on the ledger neither the first fix nor the commit is merely late. Every
//! partition canary is read behind that marker.
//!
//! # `commit-class-only` is the discriminator's control
//!
//! It drops only the application class, so the handshake must arrive LIVE and
//! the victim must converge with no re-subscribe at all. If the discriminator
//! ever inverted — a commit read as an application message, or the reverse —
//! this arm goes rc 3 (the victim never converges live) and so does the other
//! one (its probe reaches the victim).
//!
//! # The witness is what makes this a partition
//!
//! `dev#1`, unpartitioned, must fold every fix the publisher sends WHILE the
//! partition stands — before the commit and after it. If it does not, the
//! harness partitioned the wrong thing and the arm is rc 3, never green: a
//! partition is only a partition if somebody on the other side kept receiving.
//!
//! # No catch-up sweep during the partition
//!
//! Everything reaching storage keeps the plane's CANONICAL endpoint, and
//! `run_catchup_all_circles` reads its relay list out of storage — so a
//! scenario that partitions a device's ENGINE endpoint must not run a catch-up
//! sweep while the partition stands, or the withheld commit arrives by the
//! other path and the arm grades a heal it never performed. This scenario runs
//! none.
//!
//! # Deliberately NOT asserted: what the victim recovers past the horizon
//!
//! The catalogue's "the victim recovers no location published during the
//! partition" needs the TTL horizon — `UNRESOLVABLE_INPUT_MAX_AGE_SECS`
//! (`bounds::unresolvable_input_max_age`). In a minutes-long run the relay still
//! holds those 445s and the resume's replay delivers them. The expiry screen is
//! a WALL read (`PreAuthRejection::Expired` in `nostr/mls/manager.rs`) on the
//! wall side of the rig's clock partition, so no policy step can age an event
//! into it — do not "fix" this by stepping the policy clock; that is exactly
//! what `check_soak_clock_partition.sh` exists to catch. The escape hatch is
//! closed too: `encrypt_location`'s retention argument is unused and the
//! `expiration` is derived by the engine from the group's own component, so a
//! short-retention 445 cannot be minted through the public API at all. This
//! scenario asserts absence DURING the partition and convergence AFTER it; the
//! forged-expiry vector is S09's.

use std::time::Duration;

use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::nostr::mls::types::GroupId;
use haven_core::relay::live_sync::group_cursor_stream;
use nostr::{Event, EventId};

use crate::nemesis::types::{DropClass, Fault};
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{bounds, Invariant, ProbeToken, Reach, Recovery};
use crate::rig::{
    CircleTag, DeviceTag, LogDrain, PublishVerdict, RelayPlane, RigError, Step, TimelineSink,
};
use crate::scenarios::{
    await_condition, chain_pairs, closing_pairs, deliveries_for, grade_round, relay_update, round,
    Absence, Arm, ArmOutcome, Scenario, ScenarioReport, ScenarioWorld, WithheldAcks,
    NO_GATING_ROWS,
};
use tokio::time::{Instant, MissedTickBehavior};

/// The arms this scenario offers.
pub const ARMS: [Arm; 2] = [
    Arm {
        label: "partitioned-receiver",
        recovery: Recovery::Undisturbed,
        probe_rounds: 2,
        resubscribes: true,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            // Both classes, on the victim's endpoint of at least one plane.
            faults_applied: 2,
            epochs_crossed: 1,
            deliveries_observed: 2,
            canaries_caught: 4,
        },
    },
    Arm {
        label: "commit-class-only",
        recovery: Recovery::Undisturbed,
        probe_rounds: 2,
        // Nothing resumes: the handshake arrives live, or the arm is rc 3.
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 1,
            deliveries_observed: 2,
            canaries_caught: 3,
        },
    },
];

/// The round the fixes this arm mints are stamped with: neither graded round's
/// ordinal, so a fix the resume replays late can never satisfy a closing-round
/// probe.
const FIX_ROUND: u32 = 102;

/// How often a bounded wait for a delivery re-reads the ledger. A harness
/// cadence; no expectation is derived from it.
const DELIVERY_POLL: Duration = Duration::from_millis(20);

/// Runs one arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not one this scenario offers,
/// [`RigError::ShapeMismatch`] if the world has fewer than three devices — a
/// partition needs a publisher, a witness that keeps receiving and a victim
/// that does not — otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let (publisher, witness, victim) = roles(world)?;
    cast(world, arm, tick, publisher, witness, victim).await
}

/// `partitioned-receiver` with the publisher standing as its own witness.
///
/// A role no device can fill, because an engine folds no fix of its own: nobody
/// on the other side can be seen to keep receiving and the partition canaries
/// cannot hold, while the victim's partition and recovery still run and both
/// graded rounds are whole. The mis-configuration control in `tests/oracles.rs`
/// runs it and requires rc 3.
///
/// # Errors
///
/// As [`run`].
pub async fn unwitnessed_control<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
) -> Result<ScenarioReport, RigError> {
    let started = Instant::now();
    let (publisher, _, victim) = roles(world)?;
    let outcome = cast(world, &ARMS[0], tick, publisher, publisher, victim).await?;
    Ok(Scenario::ReceiverPartition.report(world, &ARMS[0], outcome, started))
}

/// The publisher, the witness and the victim: the first three devices.
fn roles<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
) -> Result<(DeviceTag, DeviceTag, DeviceTag), RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [publisher, witness, victim, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    Ok((publisher, witness, victim))
}

/// Runs one arm over the roles given.
async fn cast<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
    publisher: DeviceTag,
    witness: DeviceTag,
    victim: DeviceTag,
) -> Result<ArmOutcome, RigError> {
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;

    // The control round: the world delivers before anything is partitioned,
    // so a closing round that fails is a failure of the heal rather than of
    // the world.
    let pairs = chain_pairs(world);
    let control = round(
        1,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &[],
        &[],
    );
    let mut graded = grade_round(world, &control, &[Invariant::LocationRoundTrip]).await?;

    let (canaries, resumed) = match arm.label {
        "partitioned-receiver" => (
            partitioned(world, publisher, witness, victim, circle_tag).await?,
            true,
        ),
        "commit-class-only" => (
            commit_class_only(world, publisher, witness, victim, circle_tag).await?,
            false,
        ),
        _ => return Err(RigError::UnknownTarget),
    };

    // The victim SENDS first: its view of the group was rebuilt from a
    // persisted cursor, and a reuse there is invisible to it and shows only as
    // a peer that cannot read what it produced.
    let pairs = closing_pairs(world, victim);
    let resumed_victim = [victim];
    let opened: &[DeviceTag] = if resumed { &resumed_victim } else { &[] };
    let closing = round(
        2,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        opened,
        &[],
    );
    graded.extend(
        grade_round(
            world,
            &closing,
            &[
                Invariant::Quiescence,
                Invariant::LocationRoundTrip,
                Invariant::SendPathLiveness,
            ],
        )
        .await?,
    );

    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// Both classes withheld from the victim, then healed and recovered by a
/// resume.
async fn partitioned<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    publisher: DeviceTag,
    witness: DeviceTag,
    victim: DeviceTag,
    circle_tag: CircleTag,
) -> Result<usize, RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let stream = group_cursor_stream(world.circle(circle_tag)?.group_id_hex());
    let bound = bounds::round_trip(Recovery::Undisturbed);
    let mut cursors = vec![cursor_of(world, victim, &stream)?];
    let mut canaries = 0_usize;

    // Phase 1: the application class is withheld from the victim on every
    // plane.
    aim(world, victim, Fault::DropClass(DropClass::Application)).await?;
    world.drain_buses();
    let victim_before = deliveries_for(world.device(victim)?, circle_tag);
    let witness_before = deliveries_for(world.device(witness)?, circle_tag);
    let probe_a = publish_fix(world, publisher, circle_tag, 1).await?;
    let witness_took_a = await_delivery(world, witness, circle_tag, witness_before, bound).await?
        && carried_to(world, witness, &probe_a.id, bound).await?;
    cursors.push(cursor_of(world, victim, &stream)?);

    // Phase 2: the handshake class replaces it, ahead of the commit.
    aim(world, victim, Fault::DropClass(DropClass::Handshake)).await?;
    let commit = confirmed_commit(world, publisher, circle_tag, "withheld").await?;
    let ahead = await_condition(bound, || async {
        Ok(epoch_of(world, witness, &group).await? > epoch_of(world, victim, &group).await?)
    })
    .await?;
    // The fix published AFTER the commit is the witness's "throughout" and the
    // victim endpoint's marker at once (see the module docs).
    let witness_before = deliveries_for(world.device(witness)?, circle_tag);
    let probe_b = publish_fix(world, publisher, circle_tag, 2).await?;
    let witness_took_b = await_delivery(world, witness, circle_tag, witness_before, bound).await?;
    let marker = carried_to(world, victim, &probe_b.id, bound).await?;
    // 1. The ENV-13 control: the witness folded the first fix and its own
    //    endpoint on every plane carried it, while the victim's endpoint carried
    //    nothing and its bus folded nothing. Read only now, behind the marker:
    //    an absence read before a later frame crossed the same connection is
    //    "not yet", not "withheld". The victim's bus stays at its phase-1 count
    //    because the one fix that DID cross is sealed above its epoch.
    if witness_took_a
        && marker
        && withheld_from(world, victim, &probe_a.id)
        && deliveries_for(world.device(victim)?, circle_tag) == victim_before
    {
        canaries += 1;
    }
    // 2. The victim is strictly behind, the commit never crossed its endpoint
    //    (final, per the marker), and the witness kept receiving after it.
    if ahead
        && witness_took_b
        && marker
        && withheld_from(world, victim, &commit.id)
        && epoch_of(world, victim, &group).await? < epoch_of(world, witness, &group).await?
    {
        canaries += 1;
    }
    cursors.push(cursor_of(world, victim, &stream)?);

    // Heal, then pause and resume: the replay from the persisted cursor is the
    // recovery, and nothing else is done for it.
    aim(world, victim, Fault::Heal).await?;
    world.device_mut(victim)?.go_offline().await?;
    world.device_mut(victim)?.come_online().await?;
    // 3. …and the victim reaches both peers' epoch inside the round trip plus
    //    the ladder, holding the epoch's own exporter secret rather than
    //    merely its number.
    let caught_up = await_condition(bound + bounds::subscribe_ladder(), || async {
        let reached = epoch_of(world, victim, &group).await?;
        Ok(reached == epoch_of(world, witness, &group).await?
            && reached == epoch_of(world, publisher, &group).await?)
    })
    .await?;
    if caught_up && has_current_secret(world, victim, &group).await? {
        canaries += 1;
    }
    cursors.push(cursor_of(world, victim, &stream)?);
    // 4. The persisted cursor never went backwards across the whole arm: not
    //    during the partition, and not on the resume that advanced it.
    if monotone(&cursors) {
        canaries += 1;
    }
    Ok(canaries)
}

/// Only the application class withheld: the handshake arrives live and the
/// victim converges with no resume at all.
async fn commit_class_only<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    publisher: DeviceTag,
    witness: DeviceTag,
    victim: DeviceTag,
    circle_tag: CircleTag,
) -> Result<usize, RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let bound = bounds::round_trip(Recovery::Undisturbed);
    let mut canaries = 0_usize;

    aim(world, victim, Fault::DropClass(DropClass::Application)).await?;
    world.drain_buses();
    let victim_before = deliveries_for(world.device(victim)?, circle_tag);
    let witness_before = deliveries_for(world.device(witness)?, circle_tag);
    let probe_a = publish_fix(world, publisher, circle_tag, 1).await?;
    let witness_took_a = await_delivery(world, witness, circle_tag, witness_before, bound).await?
        && carried_to(world, witness, &probe_a.id, bound).await?;

    // The commit is the class that still crosses.
    let commit = confirmed_commit(world, publisher, circle_tag, "class").await?;
    let live = await_condition(bound, || async {
        let reached = epoch_of(world, victim, &group).await?;
        Ok(reached == epoch_of(world, publisher, &group).await?
            && reached == epoch_of(world, witness, &group).await?)
    })
    .await?;
    let crossed = carried_to(world, victim, &commit.id, bound).await?;
    // 1. The partition is real. Read AFTER the commit crossed the victim's
    //    endpoints: one connection's frames are written in order, so the fix's
    //    absence there is final rather than in flight.
    if witness_took_a
        && crossed
        && withheld_from(world, victim, &probe_a.id)
        && deliveries_for(world.device(victim)?, circle_tag) == victim_before
    {
        canaries += 1;
    }
    // 2. The handshake arrived live and APPLIED: no resume, one epoch, and the
    //    epoch's own secret.
    if live && crossed && has_current_secret(world, victim, &group).await? {
        canaries += 1;
    }
    // 3. …and the witness kept receiving after the commit, while the
    //    partition still stood.
    let witness_before = deliveries_for(world.device(witness)?, circle_tag);
    let _probe_b = publish_fix(world, publisher, circle_tag, 2).await?;
    if await_delivery(world, witness, circle_tag, witness_before, bound).await? {
        canaries += 1;
    }

    aim(world, victim, Fault::Heal).await?;
    Ok(canaries)
}

/// Applies `fault` to `device`'s own endpoint on every plane.
async fn aim<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    device: DeviceTag,
    fault: Fault,
) -> Result<(), RigError> {
    for plane in world.relays_mut() {
        plane.apply_for(device, fault).await?;
    }
    Ok(())
}

/// Waits, bounded, for `device`'s own endpoint on every plane to have carried
/// `event_id`.
async fn carried_to<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    event_id: &EventId,
    bound: Duration,
) -> Result<bool, RigError> {
    await_condition(bound, || async {
        Ok(world
            .relays()
            .iter()
            .all(|plane| plane.ledger().delivered_to(device, event_id)))
    })
    .await
}

/// Whether no plane's endpoint for `device` carried `event_id`.
fn withheld_from<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    event_id: &EventId,
) -> bool {
    world
        .relays()
        .iter()
        .all(|plane| !plane.ledger().delivered_to(device, event_id))
}

/// Whether every sample is at or above the one before it.
fn monotone(samples: &[Option<i64>]) -> bool {
    samples.windows(2).all(|pair| pair[0] <= pair[1])
}

/// `device`'s persisted group cursor for `stream`.
fn cursor_of<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    stream: &str,
) -> Result<Option<i64>, RigError> {
    world
        .device(device)?
        .manager()?
        .read_sync_cursor(stream)
        .map_err(|_| RigError::Core(Step::ReadCursor))
}

/// One confirmed relay-list commit from `device`, carrying a relay list the
/// group does not already hold — a repeat is a no-op and advances no epoch.
async fn confirmed_commit<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle_tag: CircleTag,
    salt: &str,
) -> Result<Event, RigError> {
    let mut relays = world.relay_urls();
    relays.push(format!("wss://s02-{salt}.example.com"));
    let circle = world.circle(circle_tag)?;
    let (event, verdict) = relay_update(world, device, circle, &relays).await?;
    if verdict != PublishVerdict::Confirmed {
        // Nothing merged, so there is no commit for the victim to be behind.
        return Err(RigError::PublishNeverAcked);
    }
    Ok(event)
}

/// Waits, bounded, for `device`'s folded delivery count for `circle` to rise
/// above `above`, draining the buses on every read.
async fn await_delivery<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: CircleTag,
    above: u64,
    bound: Duration,
) -> Result<bool, RigError> {
    let started = Instant::now();
    let mut ticker = tokio::time::interval(DELIVERY_POLL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        world.drain_buses();
        if deliveries_for(world.device(device)?, circle) > above {
            return Ok(true);
        }
        if started.elapsed() >= bound {
            return Ok(false);
        }
        ticker.tick().await;
    }
}

/// Publishes one fix into `circle` from `sender` and waits for a relay's own
/// ack.
async fn publish_fix<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    sender: DeviceTag,
    circle_tag: CircleTag,
    index: u32,
) -> Result<Event, RigError> {
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let device = world.device(sender)?;
    let (event, _, _) = device
        .manager()?
        .encrypt_location(
            &group,
            &device.keys.public_key(),
            &ProbeToken::mint(FIX_ROUND, index).as_location(),
            LOCATION_MESSAGE_RETENTION_SECS,
        )
        .await
        .map_err(|_| RigError::Core(Step::Publish))?;
    if world
        .publish_witnessed(sender, std::slice::from_ref(&event))
        .await?
        .is_none()
    {
        // Nothing was acked, so nothing is stored for the victim to recover.
        return Err(RigError::PublishNeverAcked);
    }
    Ok(event)
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

/// Whether `device` holds the CURRENT epoch's exporter secret for `group`.
async fn has_current_secret<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
) -> Result<bool, RigError> {
    world
        .device(device)?
        .session()?
        .has_current_exporter_secret(group)
        .await
        .map_err(|_| RigError::Core(Step::ReadEpoch))
}

#[cfg(test)]
mod tests {
    use super::{monotone, ARMS, FIX_ROUND};
    use crate::oracle::Recovery;

    #[test]
    fn the_partition_arm_pays_for_its_resume_and_the_control_arm_never_resumes() {
        assert!(
            ARMS[0].resubscribes,
            "the victim re-opens its own REQs, so the subscribe ladder is in the path"
        );
        assert!(
            !ARMS[1].resubscribes,
            "the handshake arrives live or the arm is rc 3; a resume would hide that"
        );
        for arm in &ARMS {
            assert!(
                arm.recovery == Recovery::Undisturbed,
                "a dropped frame costs no socket, so the pool's ladder is not in the path"
            );
            assert!(
                arm.probe_rounds == 2,
                "a control round before the partition and a closing round after the heal"
            );
            assert!(
                arm.floor.epochs_crossed == 1,
                "one confirmed commit is what the victim is behind"
            );
        }
    }

    #[test]
    fn each_floor_counts_the_classes_its_arm_drops() {
        assert!(
            ARMS[0].floor.faults_applied == 2,
            "both classes, on the victim's endpoint of at least one plane"
        );
        assert!(
            ARMS[1].floor.faults_applied == 1,
            "the application class alone"
        );
        assert!(
            ARMS[0].floor.canaries_caught == 4,
            "the partition, the withheld commit, the recovery and the monotone cursor"
        );
        assert!(
            ARMS[1].floor.canaries_caught == 3,
            "the partition, the live handshake and the witness throughout"
        );
    }

    #[test]
    fn arm_fixes_are_stamped_outside_both_graded_rounds() {
        // A replayed fix must never satisfy a closing-round probe.
        const { assert!(FIX_ROUND != 1 && FIX_ROUND != 2) }
    }

    #[test]
    fn a_cursor_that_moved_backwards_is_not_monotone() {
        assert!(monotone(&[None, Some(1), Some(1), Some(3)]));
        assert!(!monotone(&[Some(2), Some(1)]));
        assert!(
            !monotone(&[Some(2), None]),
            "a cursor that vanished went backwards"
        );
    }
}
