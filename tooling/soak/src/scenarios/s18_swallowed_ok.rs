//! **S18** — the relay has the event and the publisher never hears so.
//!
//! This is Rule 13's scenario. "Acked" means a relay's acknowledgement REACHED
//! the publisher; it never means the relay has the event. Under a swallowed
//! acknowledgement those two come apart, and the product's driver keeps the
//! commit PENDING — a commit a relay may hold is never rolled back, because
//! other members may build on it — and sends the same bytes again on its
//! relay's schedule until an acknowledgement reaches the device, and confirms
//! it then.
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
//! Every arm heals and repeats itself. Without that, "nothing was confirmed"
//! would be satisfied by a world where nothing can be confirmed at all.
//!
//! # Paused peers, and online ones
//!
//! A relay under a swallowed acknowledgement still STORES what it was sent and
//! still delivers it. `swallowed-ok-relay-update` pauses every peer for the
//! swallowed leg, so the circle is read with the commit nowhere but on the
//! relay and pending on its publisher: no member is ahead of it.
//! `swallowed-ok-peers-online-converge` leaves them online, so the peers apply
//! the commit the relay delivered while the publisher's own stays pending —
//! and the circle converges once the re-sent copy is acknowledged.
//!
//! # No socket went away while the acknowledgement was withheld
//!
//! [`crate::oracle::bounds::withheld_publish_ladder`] deliberately excludes the
//! connection timeout: under this fault the socket connects and only the `OK`
//! never comes. Every arm reads the planes' rebind counters across its withheld
//! publish and requires them unchanged, so that derivation is checked by the
//! arms that depend on it instead of being remembered.

use std::time::Duration;

use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{EpochState, GroupId};
use haven_core::relay::fanout::{LocationPublish, LocationSeal, SendHeld};
use nostr::{Event, EventId};

use crate::nemesis::types::{DropClass, Fault};
use crate::oracle::bounds;
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{Invariant, Reach, Recovery};
use crate::rig::{
    Change, DeviceTag, LogDrain, PacingClock, PublishVerdict, RelayPlane, RigError, Step,
    TimelineSink,
};
use crate::scenarios::{
    await_condition, closing_pairs, drive_until_settled, grade_round, round, Absence, Arm,
    ArmOutcome, ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// The arms this scenario offers.
pub const ARMS: [Arm; 5] = [
    Arm {
        label: "swallowed-ok-founding-welcome",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        // One welcome per invited member, every one of them published into a
        // silence this arm created on purpose. A founding create stages no
        // commit: its welcomes are all there is to publish.
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
        // The paused peers re-open their REQs when they resume.
        resubscribes: true,
        absence: Absence::None,
        // The one drive whose acknowledgement is swallowed.
        withheld_acks: WithheldAcks::FanoutDrives(1),
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 1,
            deliveries_observed: 1,
            canaries_caught: 7,
        },
    },
    Arm {
        label: "swallowed-ok-peers-online-converge",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::FanoutDrives(1),
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
            canaries_caught: 5,
        },
    },
    Arm {
        label: "location-resumes-after-the-ack",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        // The commit's one drive whose acknowledgement is swallowed.
        withheld_acks: WithheldAcks::FanoutDrives(1),
        floor: ExpectationFloor {
            faults_applied: 1,
            epochs_crossed: 1,
            deliveries_observed: 1,
            canaries_caught: 3,
        },
    },
];

/// How many paced drives a pending commit gets once the planes are healed: the
/// first may find its relay not yet due again (the unanswered attempt earned a
/// wait), the clock is stepped past it, and the next sends it; the third is the
/// margin for one more unanswered re-send.
const SETTLE_DRIVES: usize = 3;

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
        "swallowed-ok-founding-welcome" => founding_welcome(world).await?,
        "swallowed-ok-relay-update" => relay_update_arm(world, admin, Peers::Paused).await?,
        "swallowed-ok-peers-online-converge" => {
            relay_update_arm(world, admin, Peers::Online).await?
        }
        "swallowed-ok-location-send" => location_send(world, admin).await?,
        "location-resumes-after-the-ack" => location_resumes(world, admin).await?,
        _ => return Err(RigError::UnknownTarget),
    };

    // Both directions: a commit that forked the circle is visible as a peer
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

/// A founding create whose welcomes are stored and never acknowledged is
/// reported unacknowledged: nobody joins, and the circle stays on the admin's
/// device alone. A founding create stages no commit — it is canonical the moment
/// it returns (MDK v0.10.4 `FoundingGroupCreated`) — so its welcomes are its
/// only publishes, each its own obligation.
async fn founding_welcome<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
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
    // 1. No welcome was acked, so the create is reported unacknowledged rather
    //    than as a circle its members are in.
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

/// Whether the peers are paused for the swallowed leg, or stay online.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Peers {
    /// Paused: nothing but the relay holds the commit while it is pending.
    Paused,
    /// Online: they apply the commit the relay delivers.
    Online,
}

/// A commit whose acknowledgement never arrives stays pending under its
/// record; the same bytes are sent again once the plane is healed, confirmed
/// on that acknowledgement, and the circle converges.
async fn relay_update_arm<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
    peers_are: Peers,
) -> Result<usize, RigError> {
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let routing = world.circle(circle_tag)?.group_id_hex().to_owned();
    let mut urls = world.relay_urls();
    urls.push("wss://s18-swallowed.example.com".to_owned());
    let mut canaries = 0_usize;

    let before = epoch_of(world, admin, &group).await?;
    let peers: Vec<DeviceTag> = world
        .devices()
        .iter()
        .map(|device| device.tag)
        .filter(|tag| *tag != admin)
        .collect();
    if peers_are == Peers::Paused {
        for peer in &peers {
            world.device_mut(*peer)?.go_offline().await?;
        }
    }

    swallow(world, true).await?;
    let rebound = rebinds(world);
    let clock = PacingClock::default();
    let changed = world
        .change_on(
            admin,
            Change::Relays {
                group: &group,
                relays: &urls,
            },
            &clock,
        )
        .await?;
    let commit = changed.commit.ok_or(RigError::Core(Step::StageCommit))?;
    // 1. It stays pending: the driver kept it staged under its record, and no
    //    relay's acknowledgement reached the device.
    if changed.verdict == PublishVerdict::Unresolved && pending(world, admin, &group).await? {
        canaries += 1;
    }
    // 2. The gap itself: the relay HAS the commit, and the publisher was never
    //    told so.
    if stored_but_unacked(world, &commit).await? {
        canaries += 1;
    }
    let peer_saw = match peers_are {
        // 3. The socket never went away while the acknowledgement was withheld.
        Peers::Paused => rebinds(world) == rebound,
        // 3. Online, a peer applied the commit the relay delivered while the
        //    publisher's own copy is still pending: the relay's store, not the
        //    acknowledgement, is what the group runs on.
        Peers::Online => {
            await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
                Ok(epoch_of(world, peers[0], &group).await? > before)
            })
            .await?
        }
    };
    if peer_saw {
        canaries += 1;
    }
    if peers_are == Peers::Paused {
        // 4. No member is ahead of the pending commit: every paused peer is
        //    still on the epoch the circle started on.
        let mut behind = true;
        for peer in &peers {
            behind &= epoch_of(world, *peer, &group).await? == before;
        }
        if behind {
            canaries += 1;
        }
    }

    swallow(world, false).await?;
    let same_bytes = resent_as_is(world, admin, (&group, &routing), &commit, &clock).await?;
    let confirmed = epoch_of(world, admin, &group).await? > before;
    if peers_are == Peers::Paused {
        // 5. The same bytes, re-sent and acknowledged.
        if same_bytes {
            canaries += 1;
        }
        // 6. Confirmed on that acknowledgement.
        if confirmed {
            canaries += 1;
        }
        for peer in &peers {
            world.device_mut(*peer)?.come_online().await?;
        }
    } else if same_bytes && confirmed {
        // 4. Online: the same bytes re-sent, acknowledged, and confirmed.
        canaries += 1;
    }
    // Last: the whole circle converges on the confirmed commit's epoch.
    let target = epoch_of(world, admin, &group).await?;
    if confirmed
        && await_condition(
            bounds::round_trip(Recovery::Undisturbed) + bounds::subscribe_ladder(),
            || async { Ok(agreed_epoch(world, &group).await? == Some(target)) },
        )
        .await?
    {
        canaries += 1;
    }
    Ok(canaries)
}

/// How many commit-class events for the circle routed by `routing` the planes
/// hold besides `commit`, at or after it — none, for a re-send that is the same
/// bytes.
async fn handshakes_since<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    routing: &str,
    commit: &Event,
) -> Result<usize, RigError> {
    let mut others = 0_usize;
    for plane in world.relays() {
        for event in plane
            .stored_page(
                nostr::Filter::new()
                    .kind(nostr::Kind::Custom(445))
                    .since(commit.created_at),
            )
            .await?
        {
            let routed = event.tags.iter().any(|tag| {
                tag.as_slice().first().is_some_and(|name| name == "h")
                    && tag.as_slice().get(1).is_some_and(|value| value == routing)
            });
            if routed
                && event.id != commit.id
                && DropClass::of(&event) == Some(DropClass::Handshake)
            {
                others += 1;
            }
        }
    }
    Ok(others)
}

/// Drives `admin`'s records on the healed plane until `group` holds no
/// pending commit, and answers whether that settled it with the
/// byte-identical re-send: the very event first sent, offered again and
/// acknowledged this time — and no second commit ever staged for it.
async fn resent_as_is<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    (group, routing): (&GroupId, &str),
    commit: &Event,
    clock: &PacingClock,
) -> Result<bool, RigError> {
    let offered = |world: &ScenarioWorld<T, L>| -> usize {
        world
            .relays()
            .iter()
            .map(|plane| plane.ledger().published(&commit.id))
            .sum()
    };
    let before = offered(world);
    let settled = drive_until_settled(world, admin, group, clock, SETTLE_DRIVES).await?;
    Ok(settled
        && offered(world) > before
        && world
            .relays()
            .iter()
            .any(|plane| plane.witnessed_ok(&commit.id))
        && handshakes_since(world, routing, commit).await? == 0)
}

/// Whether `device` holds `group`'s commit staged and unresolved.
async fn pending<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    group: &GroupId,
) -> Result<bool, RigError> {
    Ok(matches!(
        world.device(device)?.session()?.epoch_state(group).await,
        Some(EpochState::PendingPublish(_))
    ))
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
    world.all_planes().map(RelayPlane::last_rebind).collect()
}

/// A location whose acknowledgement never arrives is not a published location,
/// and the product does not send it again: its application fanout ends with
/// its one offer.
async fn location_send<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    sender: DeviceTag,
) -> Result<usize, RigError> {
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let clock = PacingClock::default();
    let mut canaries = 0_usize;

    swallow(world, true).await?;
    let rebound = rebinds(world);
    let event = sealed(world, sender, &group, (21.5, -1.25), &clock).await?;
    let published = world.publish_location(sender, &event, &clock).await?;
    // 1. Nothing acknowledged it…
    if !acknowledged(&published)
        && !world
            .relays()
            .iter()
            .any(|plane| plane.witnessed_ok(&event.id))
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
    // 4. The application fanout ended with its one offer: no record of the
    //    location is left, and asking the driver to send it again finds none.
    let left = world
        .device(sender)?
        .session()?
        .location_records_for_test(&group)
        .await
        .map_err(|_| RigError::Core(Step::ReadConvergenceState))?;
    if left.is_empty()
        && matches!(
            world.publish_location(sender, &event, &clock).await?,
            LocationPublish::Ended
        )
    {
        canaries += 1;
    }

    swallow(world, false).await?;
    // 5. A fresh location, on a healed plane, IS acknowledged. A re-publish of
    //    the first one would be answered from the relay's duplicate path, which
    //    is a different claim.
    let healed = sealed(world, sender, &group, (21.75, -1.5), &clock).await?;
    if acknowledged(&world.publish_location(sender, &healed, &clock).await?) {
        canaries += 1;
    }
    Ok(canaries)
}

/// A circle's location sends wait while its commit is pending on its relays —
/// deferred, typed — and resume once the commit's re-sent copy is acknowledged.
async fn location_resumes<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    admin: DeviceTag,
) -> Result<usize, RigError> {
    let circle_tag = world.circles().first().ok_or(RigError::ShapeMismatch)?.tag;
    let group = world.circle(circle_tag)?.mls_group_id().clone();
    let mut urls = world.relay_urls();
    urls.push("wss://s18-resumes.example.com".to_owned());
    let clock = PacingClock::default();
    let mut canaries = 0_usize;

    let before = epoch_of(world, admin, &group).await?;
    swallow(world, true).await?;
    let changed = world
        .change_on(
            admin,
            Change::Relays {
                group: &group,
                relays: &urls,
            },
            &clock,
        )
        .await?;
    // 1. While the commit is pending, a location is not sealed: it is
    //    deferred, awaiting relays.
    let held = world
        .seal_fix(admin, &group, &LocationMessage::new(22.0, -1.0), &clock)
        .await?
        .seal;
    if changed.verdict == PublishVerdict::Unresolved
        && matches!(held, LocationSeal::Deferred(SendHeld::AwaitingRelays))
    {
        canaries += 1;
    }

    swallow(world, false).await?;
    // 2. The re-sent commit is acknowledged and confirmed.
    if drive_until_settled(world, admin, &group, &clock, SETTLE_DRIVES).await?
        && epoch_of(world, admin, &group).await? > before
    {
        canaries += 1;
    }
    // 3. …and the circle sends again: a location is sealed and acknowledged.
    let resumed = sealed(world, admin, &group, (22.25, -1.25), &clock).await?;
    if acknowledged(&world.publish_location(admin, &resumed, &clock).await?) {
        canaries += 1;
    }
    Ok(canaries)
}

/// A location `sender`'s driver sealed for `group`; an error when it was held.
async fn sealed<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    sender: DeviceTag,
    group: &GroupId,
    (latitude, longitude): (f64, f64),
    clock: &PacingClock,
) -> Result<Event, RigError> {
    match world
        .seal_fix(
            sender,
            group,
            &LocationMessage::new(latitude, longitude),
            clock,
        )
        .await?
        .seal
    {
        LocationSeal::Sealed { event, .. } => Ok(*event),
        LocationSeal::Deferred(_) => Err(RigError::Core(Step::Publish)),
    }
}

/// Whether a location's one offer was acknowledged by a relay.
const fn acknowledged(published: &LocationPublish) -> bool {
    matches!(published, LocationPublish::Sent(Ok(result)) if result.is_success())
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

/// Turns the swallowed acknowledgement on or off across every plane, the
/// inbox plane a founding Welcome goes to among them.
async fn swallow<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    on: bool,
) -> Result<(), RigError> {
    let fault = if on { Fault::SwallowOk } else { Fault::Heal };
    for plane in world.all_planes_mut() {
        plane.apply(fault).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::ARMS;
    use crate::scenarios::WithheldAcks;

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
                "{} must observe the withheld acknowledgement and the healed control",
                arm.label
            );
        }
    }

    #[test]
    fn a_commit_arm_prices_the_one_drive_whose_acknowledgement_it_swallows() {
        for arm in [ARMS[1], ARMS[2], ARMS[4]] {
            assert!(
                arm.withheld_acks == WithheldAcks::FanoutDrives(1),
                "{}: the product's driver sends the commit once into the silence",
                arm.label
            );
            assert_eq!(
                arm.floor.epochs_crossed, 1,
                "{} confirms its commit",
                arm.label
            );
        }
    }

    #[test]
    fn the_paused_arm_reads_more_than_the_online_one() {
        // Only with the peers paused can the arm say no member got ahead of the
        // pending commit, and read the re-send and the confirm apart.
        assert!(ARMS[1].floor.canaries_caught > ARMS[2].floor.canaries_caught);
    }

    #[test]
    fn neither_a_founding_create_nor_a_location_crosses_an_epoch() {
        assert_eq!(ARMS[0].floor.epochs_crossed, 0);
        assert_eq!(ARMS[3].floor.epochs_crossed, 0);
    }
}
