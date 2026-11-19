//! **S24** — two circles on distinct relays come to share one routing id, and
//! each is left.
//!
//! The promise (tracker T-ROUTING-ROTATION): when a routing update moves one
//! circle onto the routing id another circle on the device holds, MDK gives
//! that id's route to one group, so Haven holds BOTH circles — no location is
//! sealed for either — and makes nothing for them but each leave, every event
//! of which is sent to its own circle's relays alone. Graded over real
//! relays, each circle on a plane of its own, so which plane holds an event
//! says which circle it was sent for.
//!
//! # How the collision is made
//!
//! The admin commits a routing update that moves circle X onto circle Y's
//! routing id, X's relays unchanged, as another client's admin can (Haven
//! never does): the component is encoded here, staged through the session
//! under its durable record, and sent and confirmed by the product's driver.
//! The admin's own device then holds one id under two circles, and so does
//! every member that takes the commit in.
//!
//! # The leaves
//!
//! A member leaves X, and the admin leaves Y — handing Y over first, a commit
//! in Y after which MDK may route the shared id to Y again. Neither circle may
//! be sealed for at any point, and no event of either may reach a relay only
//! the other names: every event the arm's drivers send, recorded or not, is
//! read off both planes, and every handshake either plane holds under the
//! shared id must be one the arm sent for that plane's own circle — one sent
//! for the other circle crossed, one sent for neither is something Haven made
//! for a held circle unasked.
//!
//! # Both circles are outside the world's table
//!
//! Built with `build_extra_circle_on`, so no world-wide oracle grades two
//! circles the arm holds on purpose; that is also why the arm declares
//! `epochs_crossed: 0` and carries its epoch claim as a canary.

use std::time::Duration;

use cgka_traits::app_components::{
    encode_nostr_routing_v1, NostrRoutingV1, NOSTR_ROUTING_COMPONENT_ID,
};
use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::{AppComponentData, FanoutId, SendIntent};
use haven_core::nostr::KIND_GROUP_MESSAGE;
use haven_core::relay::fanout::{
    drive_one, DriveMode, FanoutClock as _, FanoutStatus, LeaveStatus, LocationSeal, WallClock,
};
use nostr::{Alphabet, Event, Filter, JsonUtil as _, Kind, SingleLetterTag};

use crate::nemesis::types::DropClass;
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{bounds, Finding, Invariant, Reach, Recovery, Verdict};
use crate::rig::{DeviceTag, LogDrain, RigError, SimCircle, Step, TimelineSink};
use crate::scenarios::{
    await_condition, closing_pairs, grade_round, round, Absence, Arm, ArmOutcome, Scenario,
    ScenarioReport, ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// The arm this scenario offers.
pub const ARMS: [Arm; 1] = [Arm {
    label: "collided-circles-leave-apart",
    recovery: Recovery::Undisturbed,
    probe_rounds: 1,
    resubscribes: false,
    absence: Absence::None,
    withheld_acks: WithheldAcks::None,
    floor: ExpectationFloor {
        faults_applied: 0,
        // Both circles are outside the world's table (module docs).
        epochs_crossed: 0,
        deliveries_observed: 1,
        canaries_caught: 3,
    },
}];

/// Runs the arm.
///
/// # Errors
///
/// [`RigError::ShapeMismatch`] if the world has fewer than two devices or two
/// relays, otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    _arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    collided(world, tick, true).await
}

/// The arm with no collision: the same circles and leaves, no routing update.
///
/// The mis-configuration control in `tests/oracles.rs` requires rc 3 —
/// nothing was held, so the arm proved nothing.
///
/// # Errors
///
/// As [`run`].
pub async fn uncollided_control<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
) -> Result<ScenarioReport, RigError> {
    let started = tokio::time::Instant::now();
    let outcome = collided(world, tick, false).await?;
    Ok(Scenario::RoutingCollision.report(world, &ARMS[0], outcome, started))
}

async fn collided<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
    collide: bool,
) -> Result<ArmOutcome, RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [admin, member, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    let urls = world.relay_urls();
    let [y_url, x_url, ..] = urls.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    let x = world
        .build_extra_circle_on(std::slice::from_ref(x_url))
        .await?;
    let y = world
        .build_extra_circle_on(std::slice::from_ref(y_url))
        .await?;
    let (x_plane, y_plane) = (1, 0);
    let mut canaries = 0_usize;
    let mut extra: Vec<(Invariant, Verdict)> = Vec::new();

    let shared = routing_of(world, admin, &y).await?;
    // Everything the arm sends for each circle, recorded or not: what each
    // plane may carry under the shared id.
    let mut asked_x: Vec<Event> = Vec::new();
    let mut asked_y: Vec<Event> = Vec::new();
    if collide {
        let commit = rotate_onto(world, admin, &x, shared).await?;
        asked_x.push(commit.clone());
        for &peer in tags.iter().filter(|tag| **tag != admin) {
            let _ = world.ingest(peer, &commit).await?;
        }
    }
    // 1. The collision is real: the admin and the member both route X by
    //    Y's id, and the two circles name no relay in common.
    let bound = bounds::round_trip(Recovery::Undisturbed);
    let routed = await_condition(bound, || async {
        for device in [admin, member] {
            if routing_of(world, device, &x).await? != shared {
                // A peer commit MDK holds for its quiescence window is
                // applied by the next drive that serves the engine's deadline.
                let _ = world.resume(device).await?;
                return Ok(false);
            }
        }
        Ok(true)
    })
    .await?;
    // Every grade below is a promise about a collision, so it is graded only
    // where one was made.
    let held = routed && x_url != y_url;
    if held {
        canaries += 1;
        grade_held(world, &[admin, member], &[&x, &y], &mut extra).await?;
    }

    // 2. The member's leave of X is proposed, its proposal on X's relays.
    let (left, sent_x, unrecorded_x) = world.leave(member, x.mls_group_id()).await?;
    if left == LeaveStatus::Proposed && on_plane(world, x_plane, &sent_x).await? {
        canaries += 1;
    }
    asked_x.extend(sent_x.iter().chain(&unrecorded_x).cloned());
    if held {
        grade_kept(world, &x, y_plane, &asked_x, &mut extra).await?;
    }

    // 3. The admin's leave of Y hands it over — a commit in Y that moves its
    //    epoch — and is proposed.
    let (left_y, sent_y) = admin_leaves(world, admin, &y, y_plane).await?;
    if left_y {
        canaries += 1;
    }
    asked_y.extend(sent_y);
    if held {
        grade_kept(world, &y, x_plane, &asked_y, &mut extra).await?;
        // The hand-over is applied: neither circle is sealed for after it
        // either.
        grade_held(world, &[admin, member], &[&x, &y], &mut extra).await?;
        // And every handshake under the shared id that either plane holds is
        // one the arm sent for that plane's own circle.
        let planes = [
            (x_plane, &x, asked_x.as_slice()),
            (y_plane, &y, asked_y.as_slice()),
        ];
        grade_attributed(world, &hex::encode(shared), planes, &mut extra).await?;
    }

    // Graded over the WORLD's circles, which no step here touches.
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
    let mut graded = grade_round(
        world,
        &closing,
        &[
            Invariant::Quiescence,
            Invariant::LocationRoundTrip,
            Invariant::SendPathLiveness,
        ],
    )
    .await?;
    graded.extend(extra);

    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// Commits, on `admin`, a routing update that moves `circle` onto `onto`,
/// its relays unchanged, through the product's driver; the commit.
async fn rotate_onto<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    circle: &SimCircle,
    onto: [u8; 32],
) -> Result<Event, RigError> {
    let device = world.device(admin)?;
    let session = device.session()?;
    let (_, relays) = session
        .group_routing(circle.mls_group_id())
        .await
        .map_err(|_| RigError::Core(Step::StageCommit))?;
    let routing =
        NostrRoutingV1::new(onto, relays).map_err(|_| RigError::Core(Step::StageCommit))?;
    let data = encode_nostr_routing_v1(&routing).map_err(|_| RigError::Core(Step::StageCommit))?;
    // The rig's decision, at staging: `onto` now routes over its own relays
    // and over the ones the rig built `circle` on — never the product's read.
    let onto_hex = hex::encode(onto);
    let mut joined = world.routing_current(&onto_hex);
    joined.extend(world.routing_current(circle.group_id_hex()));
    world.note_routing(&onto_hex, &joined);
    let staged = session
        .send_staging(
            SendIntent::UpdateAppComponents {
                group_id: circle.mls_group_id().clone(),
                updates: vec![AppComponentData {
                    component_id: NOSTR_ROUTING_COMPONENT_ID,
                    data,
                }],
            },
            WallClock.now_ms(),
        )
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
    if outcome.status != FanoutStatus::Confirmed {
        return Err(RigError::PublishNeverAcked);
    }
    Ok(commit)
}

/// Grades that no circle of `circles` is sealed for on any of `devices`.
async fn grade_held<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    devices: &[DeviceTag],
    circles: &[&SimCircle],
    extra: &mut Vec<(Invariant, Verdict)>,
) -> Result<(), RigError> {
    for &device in devices {
        for circle in circles {
            let seal = world
                .seal_fix(
                    device,
                    circle.mls_group_id(),
                    &LocationMessage::new(24.0, 24.0),
                    &WallClock,
                )
                .await?
                .seal;
            if matches!(seal, LocationSeal::Sealed { .. }) {
                extra.push((
                    Invariant::SendPathLiveness,
                    Verdict::Failed(Finding::HeldCircleSealed {
                        device,
                        circle: circle.tag,
                    }),
                ));
            }
        }
    }
    Ok(())
}

/// Grades that no event of `sent`, all of `circle`'s, reached the plane
/// `other` — a relay only the other circle names.
async fn grade_kept<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    circle: &SimCircle,
    other: usize,
    sent: &[Event],
    extra: &mut Vec<(Invariant, Verdict)>,
) -> Result<(), RigError> {
    let plane = world.relays().get(other).ok_or(RigError::ShapeMismatch)?;
    for event in sent {
        if plane.ledger().published(&event.id) > 0 || plane.stored(&event.id).await? {
            extra.push((
                Invariant::SendPathLiveness,
                Verdict::Failed(Finding::CircleTrafficCrossed { circle: circle.tag }),
            ));
            return Ok(());
        }
    }
    Ok(())
}

/// The admin's leave of `y`: handed over, then proposed. Whether it went as
/// promised — proposed, the hand-over and the proposal both on `y`'s plane,
/// `y`'s epoch moved — and every event the driver sent for it, recorded or not.
async fn admin_leaves<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    admin: DeviceTag,
    y: &SimCircle,
    y_plane: usize,
) -> Result<(bool, Vec<Event>), RigError> {
    let before = epoch_of(world, admin, y).await?;
    let (_, mut sent, unrecorded) = world.leave(admin, y.mls_group_id()).await?;
    let (proposed, more, unrecorded_more) = world.resume_leave(admin, y.mls_group_id()).await?;
    sent.extend(more);
    let asked: Vec<Event> = sent
        .iter()
        .chain(&unrecorded)
        .chain(&unrecorded_more)
        .cloned()
        .collect();
    let mut seen = std::collections::HashSet::new();
    sent.retain(|event| seen.insert(event.id));
    let left = proposed == LeaveStatus::Proposed
        && sent.len() >= 2
        && epoch_of(world, admin, y).await? > before
        && on_plane(world, y_plane, &sent).await?;
    Ok((left, asked))
}

/// Grades that every handshake-class event each plane holds under
/// `shared_hex` is one the arm sent for that plane's own circle: one the arm
/// sent for the other circle crossed, and one it sent for neither is
/// something Haven made for a held circle unasked.
async fn grade_attributed<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    shared_hex: &str,
    planes: [(usize, &SimCircle, &[Event]); 2],
    extra: &mut Vec<(Invariant, Verdict)>,
) -> Result<(), RigError> {
    for (own, other) in [(0, 1), (1, 0)] {
        let (index, circle, asked) = planes[own];
        let (_, other_circle, other_asked) = planes[other];
        let plane = world.relays().get(index).ok_or(RigError::ShapeMismatch)?;
        let held = plane
            .stored_page(
                Filter::new()
                    .kind(Kind::Custom(KIND_GROUP_MESSAGE))
                    .custom_tag(SingleLetterTag::lowercase(Alphabet::H), shared_hex),
            )
            .await?;
        let stray = held.iter().find(|event| {
            DropClass::of(event) == Some(DropClass::Handshake)
                && !asked.iter().any(|sent| sent.id == event.id)
        });
        if let Some(event) = stray {
            let finding = if other_asked.iter().any(|sent| sent.id == event.id) {
                Finding::CircleTrafficCrossed {
                    circle: other_circle.tag,
                }
            } else {
                Finding::UnaskedHandshake { circle: circle.tag }
            };
            extra.push((Invariant::SendPathLiveness, Verdict::Failed(finding)));
        }
    }
    Ok(())
}

/// Whether every event of `sent` is stored on the plane `index`.
async fn on_plane<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    index: usize,
    sent: &[Event],
) -> Result<bool, RigError> {
    let plane = world.relays().get(index).ok_or(RigError::ShapeMismatch)?;
    for event in sent {
        if !plane.stored(&event.id).await? {
            return Ok(false);
        }
    }
    Ok(!sent.is_empty())
}

/// The routing id `device`'s engine routes `circle` by.
async fn routing_of<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
    circle: &SimCircle,
) -> Result<[u8; 32], RigError> {
    world
        .device(device)?
        .session()?
        .group_routing(circle.mls_group_id())
        .await
        .map(|(routing_id, _)| routing_id)
        .map_err(|_| RigError::Core(Step::ReadEpoch))
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

#[cfg(test)]
mod tests {
    use haven_core::relay::fanout::{before_next_change_drive_for_test, hold_fanout_row_for_test};

    use super::{
        admin_leaves, await_condition, bounds, grade_attributed, rotate_onto, routing_of, Event,
        Finding, Kind, ScenarioWorld, SimCircle, Verdict, ARMS, KIND_GROUP_MESSAGE,
    };
    use crate::nemesis::types::Schedule;
    use crate::oracle::Recovery;
    use crate::profiles::WorldShape;
    use crate::relay::SimRelay;
    use crate::rig::doubles::{RecordingTimeline, StubDrain};
    use crate::rig::{DeviceTag, SimWorld};
    use crate::scenarios::WithheldAcks;

    /// A handshake under routing id `h`, by nobody.
    fn handshake(h: &str) -> Event {
        nostr::EventBuilder::new(Kind::Custom(KIND_GROUP_MESSAGE), "unasked")
            .tag(nostr::Tag::custom(nostr::TagKind::h(), [h.to_owned()]))
            .sign_with_keys(&nostr::Keys::generate())
            .expect("a signed event")
    }

    /// Plants `event` on `plane` as one `device`'s own endpoint handed over
    /// and the plane's store kept, and answers whether the store took it.
    async fn plant(plane: &SimRelay, device: DeviceTag, event: &Event) -> bool {
        plane.ledger().note_published(Some(device), event.id);
        plane.store(std::slice::from_ref(event)).await == Ok(1)
    }

    /// The device's engine makes a handshake nobody asked for while the
    /// admin leaves Y — one onto Y's plane, one onto X's, both under the id
    /// the two circles share. Neither is a step of the leave, so neither is
    /// among what the leave sent, and each plane's is reported as made
    /// unasked for its own circle.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_handshake_made_unasked_during_a_leave_is_reported_on_its_own_plane() {
        let shape = WorldShape {
            members: 2,
            circles: 1,
            relays: 2,
            account_relays: 1,
            profile_relays: 0,
        };
        let world: ScenarioWorld<RecordingTimeline, StubDrain> = SimWorld::build(
            &shape,
            Schedule::new(Vec::new()),
            crate::relay::planes_for(&shape)
                .await
                .expect("the relay planes start"),
            RecordingTimeline::default(),
            StubDrain::default(),
        )
        .await
        .expect("the world builds");
        let admin = world.devices()[0].tag;
        let urls = world.relay_urls();
        let (x_plane, y_plane) = (1, 0);
        let x: SimCircle = world
            .build_extra_circle_on(&urls[x_plane..=x_plane])
            .await
            .expect("circle X builds");
        let y: SimCircle = world
            .build_extra_circle_on(&urls[y_plane..=y_plane])
            .await
            .expect("circle Y builds");
        let shared = routing_of(&world, admin, &y).await.expect("Y's routing");
        let rotated = rotate_onto(&world, admin, &x, shared)
            .await
            .expect("X is moved onto Y's routing id");
        // As the arm: the member takes the rotation in, and both route X by
        // Y's id before either circle is left.
        let member = world.devices()[1].tag;
        let _ = world
            .ingest(member, &rotated)
            .await
            .expect("the member ingests");
        let routed = await_condition(bounds::round_trip(Recovery::Undisturbed), || async {
            for device in [admin, member] {
                if routing_of(&world, device, &x).await? != shared {
                    let _ = world.resume(device).await?;
                    return Ok(false);
                }
            }
            Ok(true)
        })
        .await
        .expect("the routing reads");
        let shared_hex = hex::encode(shared);
        let (unasked_y, unasked_x) = (handshake(&shared_hex), handshake(&shared_hex));

        // Held at its hand-over — unless the admin's own engine has taken it
        // already — so both are handed over during the leave. The engine
        // runs, as in the arm: a collided circle is left only beside one.
        let (hand_over, handed) = tokio::sync::oneshot::channel();
        before_next_change_drive_for_test(y.mls_group_id(), move |id| {
            let _ = hand_over.send(hold_fanout_row_for_test(id));
        });
        let (left, planted) = tokio::join!(admin_leaves(&world, admin, &y, y_plane), async {
            let hold = handed.await.expect("the leave reaches its hand-over");
            let planted = plant(&world.relays()[y_plane], admin, &unasked_y).await
                && plant(&world.relays()[x_plane], admin, &unasked_x).await;
            drop(hold);
            planted
        });
        let (_, asked_y) = left.expect("the leave is driven");
        let mut graded = Vec::new();
        let planes = [
            (x_plane, &x, std::slice::from_ref(&rotated)),
            (y_plane, &y, asked_y.as_slice()),
        ];
        grade_attributed(&world, &shared_hex, planes, &mut graded)
            .await
            .expect("the planes read");
        let unasked_for = |circle: &SimCircle| {
            graded.iter().any(|(_, verdict)| {
                matches!(
                    verdict,
                    Verdict::Failed(Finding::UnaskedHandshake { circle: flagged })
                        if *flagged == circle.tag
                )
            })
        };
        let listed = asked_y
            .iter()
            .any(|event| event.id == unasked_y.id || event.id == unasked_x.id);

        assert!(
            routed && planted,
            "premise: the circles collided, and two handshakes were planted during the \
             admin's leave (collided {routed}, planted {planted})"
        );
        assert!(
            !listed && graded.len() == 2 && unasked_for(&y) && unasked_for(&x),
            "a handshake made unasked during the leave was taken for the leave's, or not \
             reported for its own circle (among what the leave sent {listed}, reported for Y \
             {}, reported for X {})",
            unasked_for(&y),
            unasked_for(&x)
        );

        world.teardown().await.expect("teardown");
    }

    #[test]
    fn the_arm_breaks_no_relay_and_withholds_nothing() {
        let arm = ARMS[0];
        assert!(arm.recovery == Recovery::Undisturbed && arm.floor.faults_applied == 0);
        assert!(
            arm.withheld_acks == WithheldAcks::None,
            "every publish the arm makes is acknowledged"
        );
        assert!(
            arm.floor.canaries_caught == 3,
            "the collision, the member's leave and the admin's"
        );
    }
}
