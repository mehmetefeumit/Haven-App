//! **S18** — the relay has the event and the publisher never hears so.
//!
//! This is Rule 13's scenario. "Acked" means a relay's acknowledgement REACHED
//! the publisher; it never means the relay has the event. Under a swallowed
//! acknowledgement those two come apart, and every staged commit must be rolled
//! back rather than merged: a commit merged locally and invisible to every other
//! member forks the group, which is a confidentiality-relevant divergence and
//! not a bookkeeping detail.
//!
//! # The gap is proven from both sides
//!
//! The plane's own store says the event is there, and the plane's client-facing
//! ledger says no `OK … true` was ever written towards the client. An arm that
//! only checked the second half would pass on a plane that simply dropped the
//! event, and would then be testing an outage under another name.
//!
//! # The acked half is the control
//!
//! Every arm heals and repeats itself. Without that, "the epoch did not advance"
//! would be satisfied by a world where nothing can advance at all.
//!
//! # The peers are paused for the swallowed leg
//!
//! A relay under a swallowed acknowledgement still STORES what it was sent and
//! still delivers it. An online peer would therefore apply the very commit the
//! publisher is about to roll back — a fork with the membership on the new
//! epoch and the admin on the old one, which is the OPPOSITE of the divergence
//! this scenario is about and one the arm would be causing rather than
//! observing. So the commit arm pauses every peer for the swallowed leg, and
//! then asserts the expectation that follows: a rolled-back commit leaves the
//! whole circle on one epoch.
//!
//! # No socket went away while the acknowledgement was withheld
//!
//! [`crate::oracle::bounds::withheld_publish_ladder`] deliberately excludes the
//! connection timeout: under this fault the socket connects and only the `OK`
//! never comes. Every arm reads the planes' rebind counters across its withheld
//! publish and requires them unchanged, so that derivation is checked by the
//! arms that depend on it instead of being remembered.

use std::time::Duration;

use haven_core::location::{LocationMessage, LOCATION_MESSAGE_RETENTION_SECS};
use nostr::{Event, EventId};

use crate::nemesis::types::Fault;
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{Invariant, Reach, Recovery};
use crate::rig::{DeviceTag, LogDrain, PublishVerdict, RelayPlane, RigError, Step, TimelineSink};
use crate::scenarios::{
    closing_pairs, grade_round, relay_update, round, Absence, Arm, ArmOutcome, ScenarioWorld,
    WithheldAcks, NO_GATING_ROWS,
};

/// The arms this scenario offers.
pub const ARMS: [Arm; 3] = [
    Arm {
        label: "swallowed-ok-create",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        // One welcome per invited member, every one of them published into a
        // silence this arm created on purpose.
        withheld_acks: WithheldAcks::PerInvitedMember,
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 3,
        },
    },
    Arm {
        label: "swallowed-ok-relay-update",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        // The one staged commit.
        withheld_acks: WithheldAcks::Fixed(1),
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 1,
            deliveries_observed: 1,
            canaries_caught: 5,
        },
    },
    Arm {
        label: "swallowed-ok-location-send",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        // The one location published into the silence — one bounded attempt,
        // not the commit ladder: the product never re-sends a location.
        withheld_acks: WithheldAcks::Locations(1),
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 4,
        },
    },
];

/// Runs one arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not one this scenario offers,
/// otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let admin = world
        .devices()
        .first()
        .map(|device| device.tag)
        .ok_or(RigError::ShapeMismatch)?;

    let canaries = match arm.label {
        "swallowed-ok-create" => create(world, admin).await?,
        "swallowed-ok-relay-update" => relay_update_arm(world, admin).await?,
        "swallowed-ok-location-send" => location_send(world, admin).await?,
        _ => return Err(RigError::UnknownTarget),
    };

    // Both directions: a rollback that forked the circle is visible as a peer
    // that can no longer decrypt what the publisher sends, or the reverse.
    let pairs = closing_pairs(world, admin);
    let healed = round(
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
        &healed,
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

/// A circle whose welcomes are stored and never acknowledged is not created.
async fn create<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    _admin: DeviceTag,
) -> Result<usize, RigError> {
    let mut canaries = 0_usize;
    swallow(world, true).await?;
    let rebound = rebinds(world);

    // Two members at least, by construction: a circle of one cannot be built,
    // and a create with nobody to welcome would publish nothing to swallow.
    //
    // Through the world, so both creates are declared like every other value
    // the run minted — the acked one below above all, which really does exist.
    let refused = world.build_extra_circle().await;
    // 1. No welcome was acked, so the staged state was rolled back and there is
    //    no circle. A create that had "succeeded" here would be a group only its
    //    admin knows about.
    if matches!(refused, Err(RigError::WelcomeNeverAcked)) {
        canaries += 1;
    }
    // 2. Every welcome burned the publish ladder with the socket UP: see the
    //    module docs.
    if rebinds(world) == rebound {
        canaries += 1;
    }

    swallow(world, false).await?;
    // 3. …and the same create, acked, works. Without this the arm would pass on
    //    a world where no circle can be created at all.
    if world.build_extra_circle().await.is_ok() {
        canaries += 1;
    }
    Ok(canaries)
}

/// A commit whose acknowledgement never arrives does not advance the epoch.
async fn relay_update_arm<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
) -> Result<usize, RigError> {
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let urls = world.relay_urls();
    let mut canaries = 0_usize;

    let before = epoch_of(world, admin, &group).await?;

    // The peers are paused for the swallowed leg: a stored-and-unacked commit
    // is still DELIVERED, and a peer that applied it while the publisher rolled
    // back would be a fork this arm caused (see the module docs).
    let peers: Vec<DeviceTag> = world
        .devices()
        .iter()
        .map(|device| device.tag)
        .filter(|tag| *tag != admin)
        .collect();
    for peer in &peers {
        world.device_mut(*peer)?.go_offline().await?;
    }

    swallow(world, true).await?;
    let rebound = rebinds(world);
    let circle = world.circle(circle_tag)?;
    let (event, verdict) = relay_update(world, admin, circle, &urls).await?;
    let after = epoch_of(world, admin, &group).await?;
    // 1. Rolled back, and the epoch stayed where it was.
    if verdict == PublishVerdict::RolledBack && after == before {
        canaries += 1;
    }
    // 2. The gap itself: the relay HAS the commit, and the publisher was never
    //    told so.
    if stored_but_unacked(world, &event).await? {
        canaries += 1;
    }
    // 3. The socket never went away while the acknowledgement was withheld.
    if rebinds(world) == rebound {
        canaries += 1;
    }
    // 4. The stated expectation of a rollback: NO fork. The publisher unmerged
    //    the commit and no member ever applied it, so the whole circle is still
    //    on the epoch it started on. A peer sitting one epoch ahead of its own
    //    admin is the confidentiality-relevant divergence Rule 13 exists to
    //    prevent, and it would show up here as a disagreement.
    if agreed_epoch(world, &group).await? == Some(before) {
        canaries += 1;
    }

    for peer in &peers {
        world.device_mut(*peer)?.come_online().await?;
    }

    swallow(world, false).await?;
    let circle = world.circle(circle_tag)?;
    let (_, healed) = relay_update(world, admin, circle, &urls).await?;
    let advanced = epoch_of(world, admin, &group).await?;
    // 5. …and an acked commit does advance it.
    if healed == PublishVerdict::Confirmed && advanced > before {
        canaries += 1;
    }
    Ok(canaries)
}

/// One device's epoch for one circle.
async fn epoch_of<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &haven_core::nostr::mls::types::GroupId,
) -> Result<u64, RigError> {
    world
        .device(device)?
        .manager()?
        .group_epoch(group)
        .await
        .map_err(|_| RigError::Core(Step::ReadEpoch))
}

/// The epoch every device holds for one circle, or `None` when they disagree.
async fn agreed_epoch<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    group: &haven_core::nostr::mls::types::GroupId,
) -> Result<Option<u64>, RigError> {
    let mut agreed: Option<u64> = None;
    for device in world.devices() {
        let epoch = epoch_of(world, device.tag, group).await?;
        match agreed {
            None => agreed = Some(epoch),
            Some(first) if first == epoch => {}
            Some(_) => return Ok(None),
        }
    }
    Ok(agreed)
}

/// What every plane's rebind counter reads right now.
///
/// Compared across a withheld-ack publish: an endpoint that went away and came
/// back would put the pool's connect term inside a window the arm's deadline
/// prices without it.
fn rebinds<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
) -> Vec<Option<(u32, Duration)>> {
    world.relays().iter().map(RelayPlane::last_rebind).collect()
}

/// A location whose acknowledgement never arrives is not a published location.
async fn location_send<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    sender: DeviceTag,
) -> Result<usize, RigError> {
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let mut canaries = 0_usize;

    swallow(world, true).await?;
    let rebound = rebinds(world);
    let event = mint_location(world, sender, &group, 21.5, -1.25).await?;
    // 1. Nothing acknowledged it…
    if world
        .publish_witnessed(sender, std::slice::from_ref(&event))
        .await?
        .is_none()
    {
        canaries += 1;
    }
    // 2. …while the relay had it all along.
    if stored_but_unacked(world, &event).await? {
        canaries += 1;
    }
    // 3. …and the socket stayed up throughout: see the module docs.
    if rebinds(world) == rebound {
        canaries += 1;
    }

    swallow(world, false).await?;
    let healed = mint_location(world, sender, &group, 21.75, -1.5).await?;
    // 4. A fresh location, on a healed plane, IS acknowledged. A re-publish of
    //    the first one would be answered from the relay's duplicate path, which
    //    is a different claim.
    if world
        .publish_witnessed(sender, std::slice::from_ref(&healed))
        .await?
        .is_some()
    {
        canaries += 1;
    }
    Ok(canaries)
}

/// One real location event from `sender`, encrypted at its current epoch.
async fn mint_location<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    sender: DeviceTag,
    group: &haven_core::nostr::mls::types::GroupId,
    latitude: f64,
    longitude: f64,
) -> Result<Event, RigError> {
    let device = world.device(sender)?;
    device
        .manager()?
        .encrypt_location(
            group,
            &device.keys.public_key(),
            &LocationMessage::new(latitude, longitude),
            LOCATION_MESSAGE_RETENTION_SECS,
        )
        .await
        .map(|(event, _, _)| event)
        .map_err(|_| RigError::Core(Step::Publish))
}

/// Whether some plane holds `event` while none acknowledged it client-ward.
async fn stored_but_unacked<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    event: &Event,
) -> Result<bool, RigError> {
    let id: EventId = event.id;
    let mut stored = false;
    for plane in world.relays() {
        if plane.stored(&id).await? {
            stored = true;
        }
        if plane.witnessed_ok(&id) {
            return Ok(false);
        }
    }
    Ok(stored)
}

/// Turns the swallowed acknowledgement on or off across every plane.
async fn swallow<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    on: bool,
) -> Result<(), RigError> {
    let fault = if on { Fault::SwallowOk } else { Fault::Heal };
    for plane in world.relays_mut() {
        plane.apply(fault).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::ARMS;

    #[test]
    fn every_arm_breaks_one_plane_behaviour_and_repeats_itself_healed() {
        for arm in ARMS {
            assert!(
                arm.floor.faults_applied == 1,
                "{} applies exactly the swallowed acknowledgement",
                arm.label
            );
            assert!(
                arm.floor.canaries_caught >= 3,
                "{} must observe the refusal, the healed control AND the socket \
                 staying up while the acknowledgement was withheld",
                arm.label
            );
        }
    }

    #[test]
    fn the_commit_arm_demands_the_no_fork_observation_the_others_cannot_make() {
        // Only a commit can fork a circle, so only this arm can assert that a
        // rolled-back one did not. An arm that demanded the same count as the
        // others would be satisfied without ever reading the peers' epochs.
        assert!(ARMS[1].floor.canaries_caught > ARMS[0].floor.canaries_caught);
        assert!(ARMS[1].floor.canaries_caught > ARMS[2].floor.canaries_caught);
    }

    #[test]
    fn only_the_commit_arm_crosses_an_epoch() {
        // A create that was rolled back crosses none, and a location send never
        // does: an arm claiming otherwise would be graded on a commit it did
        // not make.
        assert!(ARMS[0].floor.epochs_crossed == 0);
        assert!(ARMS[1].floor.epochs_crossed == 1);
        assert!(ARMS[2].floor.epochs_crossed == 0);
    }
}
