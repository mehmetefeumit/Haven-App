//! **S28** — member bridging end to end (T-BRIDGE-9,
//! `docs/BLUETOOTH_MESH_PLAN.md` §5.5).
//!
//! Three members of one circle have a part. One is offline and on mesh: no
//! relay takes its events, and it hears nothing of the circle from one. One
//! is online and in its radio range. One is far away, with a relay and no
//! mesh. The online member passes the offline member's update on to the
//! circle's relay behind its own send, and the far member reads it from
//! there. A world of more devices puts them all in the circle
//! (`build_extra_circle`); the others' engines are never told of it.
//!
//! * `bridged-to-the-far-member` — first a drive whose caller says its relay
//!   receive had NOT completed: the relay takes the online member's own
//!   send and nothing of the offline member's reaches it, then or later.
//!   Then a drive whose receive completed: the offline member's next update
//!   is passed on once, byte for byte, and the far member's live plane
//!   delivers it.
//! * `removed-member-finds-nothing` — the online member removes the far one,
//!   and the offline member, which never hears of it, seals its next update
//!   at the epoch the removed member can still read. The online member reads
//!   it from the mesh and sends with its receive completed: nothing of the
//!   offline member's reaches the relay, in its store or in the removed
//!   member's own view of it.
//!
//! # Offline, without an unplugged socket
//!
//! The offline member's own endpoint refuses its events (`refuse-oversize`),
//! and its engine is never told of the circle, so it asks no relay for it.
//! No socket is closed, so the arm ends with nothing to reconnect.
//!
//! # The circle
//!
//! Built with `build_extra_circle`, outside the world's own table: a circle
//! one member cannot receive in, and one a member is removed from, is not one
//! a world-wide oracle may grade.
//!
//! # Something was waiting to be passed on
//!
//! Each send that must pass nothing on is made only after the bridger's
//! session shows it KEEPS the update to pass on: reading it from the mesh is
//! not that. A bridger that kept nothing — no longer caught up, or a packet
//! no longer marked as one a member may pass on — would pass nothing on
//! whatever its gates did, so an arm that finds nothing kept answers rc 3.
//!
//! # One wait may run out
//!
//! The arms' own bounded waits — the foreground entries, the bridger's
//! catching up, the far member's delivery, its view of the relay — share
//! one [`Allowance`]: after the first that runs out, none is made, and a
//! wait that was not made grades nothing. An update the far member was
//! waited for and never delivered is the finding, by name. A wait of the
//! setting-up that ran out — an entry's pass, the bridger's catching up — is
//! none of these arms': nothing they grade was observed, so the run is
//! unusable (rc 3).
//!
//! # What the second arm is not
//!
//! With three devices the bridger is also the remover: it knows of the
//! removal from its own commit, not from a relay. A bridger that has not yet
//! fetched a removal another member made is the first arm's unreceived drive.
//!
//! # The controls
//!
//! [`out_of_range_control`] runs the first arm with the two mesh members out
//! of radio range: nothing is read from the mesh, so nothing could be passed
//! on — rc 3. [`late_setup_control`] runs it as after a setting-up wait that
//! ran out: rc 3, and no delivery named that nobody waited for.

use std::time::Duration;

use haven_core::nostr::mls::types::LocationMessageResult;
use haven_core::relay::fanout::{LocationPublish, WallClock};
use nostr::{Alphabet, Event, EventId, Filter, Kind, SingleLetterTag};

use crate::clock::WallNow;
use crate::nemesis::types::{ByteCap, Fault};
use crate::oracle::vacuity::{Canaries, ExpectationFloor, Observed};
use crate::oracle::{Finding, Invariant, ProbeToken, Reach, Recovery, Verdict};
use crate::rig::mesh::turn_on;
use crate::rig::{
    DeviceTag, LogDrain, MeshPlane, PublishVerdict, RelayPlane, RigError, SimCircle, Step,
    TimelineSink,
};
use crate::scenarios::{
    await_condition, closing_pairs, grade_round, listen, remove_member, round, seal_probe,
    undelivered_to, Absence, Allowance, Arm, ArmOutcome, Scenario, ScenarioReport, ScenarioWorld,
    WithheldAcks, NO_GATING_ROWS,
};

const fn arm(label: &'static str) -> Arm {
    Arm {
        label,
        recovery: Recovery::Undisturbed,
        // The closing round, and the one wait of the arm that may run out.
        probe_rounds: 2,
        resubscribes: false,
        absence: Absence::None,
        // A refused send is answered at once: nothing waits out a silence.
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            // The offline member's refusing endpoint.
            faults_applied: 1,
            // The circle is outside the world's table, which is where this
            // is measured.
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 5,
        },
    }
}

/// The arms this scenario offers.
pub const ARMS: [Arm; 2] = [
    arm("bridged-to-the-far-member"),
    arm("removed-member-finds-nothing"),
];

/// The probe round every location of the arms is minted from.
const BRIDGE_ROUND: u32 = 128;

/// Smaller than any event: the endpoint it is armed on refuses them all.
const REFUSES_EVERY_EVENT: usize = 1;

/// Runs one arm.
///
/// # Errors
///
/// [`RigError::ShapeMismatch`] if the world has fewer than three devices,
/// [`RigError::UnknownTarget`] for a label this scenario does not offer,
/// otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    if arm.label == ARMS[0].label {
        bridged(world, tick, true, Allowance::new()).await
    } else if arm.label == ARMS[1].label {
        removed(world, tick).await
    } else {
        Err(RigError::UnknownTarget)
    }
}

/// The first arm with the two mesh members out of radio range.
///
/// The mis-configuration control in `tests/oracles.rs` requires rc 3 —
/// nothing was read from the mesh, so the arm proved nothing about what is
/// passed on.
///
/// # Errors
///
/// As [`run`].
pub async fn out_of_range_control<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
) -> Result<ScenarioReport, RigError> {
    let started = tokio::time::Instant::now();
    let outcome = bridged(world, tick, false, Allowance::new()).await?;
    Ok(Scenario::MemberBridging.report(world, &ARMS[0], outcome, started))
}

/// The first arm as it runs once a wait of its setting-up has run out.
///
/// The control in `tests/oracles.rs` requires rc 3 and no delivery finding:
/// the arm then waits for nothing, and a wait it did not make grades nothing.
///
/// # Errors
///
/// As [`run`].
pub async fn late_setup_control<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
) -> Result<ScenarioReport, RigError> {
    let started = tokio::time::Instant::now();
    let outcome = bridged(world, tick, true, Allowance::run_out()).await?;
    Ok(Scenario::MemberBridging.report(world, &ARMS[0], outcome, started))
}

async fn bridged<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
    in_range: bool,
    waits: Allowance,
) -> Result<ArmOutcome, RigError> {
    let mut stage = Stage::set(world, in_range, waits).await?;
    let mut canaries = Canaries::new();

    // A drive whose relay receive had not completed passes nothing on.
    let Some(held_back) = stage.update(world).await? else {
        return stage.close(world, tick, canaries, Vec::new()).await;
    };
    let unreceived = stage.send(world, false).await?;
    // A drive whose receive completed passes the next update on.
    let Some(passed) = stage.update(world).await? else {
        return stage.close(world, tick, canaries, Vec::new()).await;
    };
    let mut far = listen(world, &[stage.far])?;
    let received = stage.send(world, true).await?;
    // Awaited only where the bridger read it and a relay took its send:
    // nothing else can bring it, and from there on passing it on is owed.
    // And only while the arm may still wait: a wait not made finds nothing.
    let passed_on = passed.read && received.taken;
    let author = world.device(stage.offline)?.pubkey_hex();
    let undelivered = match stage.waits.bound().filter(|_| passed_on) {
        Some(bound) => {
            let missed = undelivered_to(&mut far, &author, passed.probe, bound).await;
            !stage.waits.ended(missed.is_none())
        }
        None => false,
    };

    // 1. The setting-up waits ended, mesh is on, and frames crossed the
    //    link.
    canaries.check(stage.ready && stage.plane.carried() > 0);
    // 2. No relay took either of the offline member's own sends.
    canaries.check(held_back.refused && passed.refused);
    // 3. The bridger read the first update from the mesh and kept it to pass
    //    on, and a relay took the send that was to pass nothing on.
    canaries.check(held_back.read && held_back.waiting && unreceived.taken);
    // 4. The bridger read the second update from the mesh…
    canaries.check(passed.read);
    // 5. …and a relay took the send that was to pass it on.
    canaries.check(received.taken);

    let mut extra = Vec::new();
    // Byte for byte, and in one frame of the bridger's a relay.
    let altered =
        (received.sent.iter()).any(|event| event.id == passed.event.id && *event != passed.event);
    let again = (world.relays().iter()).any(|plane| {
        let frames = plane
            .ledger()
            .published_by(Some(stage.bridger), &passed.event.id);
        frames > 1
    });
    if stage.at_a_relay(world, &held_back.event.id).await?
        || unreceived.passed_on(&held_back.event.id)
        || received.passed_on(&held_back.event.id)
        || altered
        || again
    {
        extra.push(stage.past_its_gate());
    }
    if undelivered {
        extra.push((
            Invariant::LocationRoundTrip,
            Verdict::Failed(Finding::ProbeNotDelivered {
                from: stage.offline,
                to: stage.far,
                circle: stage.circle.tag,
            }),
        ));
    }
    stage.close(world, tick, canaries, extra).await
}

async fn removed<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    let mut stage = Stage::set(world, true, Allowance::new()).await?;
    let mut canaries = Canaries::new();

    let before = (
        stage.epoch(world, stage.bridger).await?,
        stage.epoch(world, stage.offline).await?,
    );
    let (_, removal) = remove_member(world, stage.bridger, &stage.circle, stage.far).await?;
    let after = (
        stage.epoch(world, stage.bridger).await?,
        stage.epoch(world, stage.offline).await?,
    );
    let Some(update) = stage.update(world).await? else {
        return stage.close(world, tick, canaries, Vec::new()).await;
    };
    let own = stage.send(world, true).await?;
    let view = stage.far_view(world).await?;

    // 1. The setting-up waits ended, mesh is on, and frames crossed the
    //    link.
    canaries.check(stage.ready && stage.plane.carried() > 0);
    // 2. The removal stands on the bridger, and the offline member never
    //    heard of it.
    canaries
        .check(removal == PublishVerdict::Confirmed && after.0 > before.0 && after.1 == before.1);
    // 3. No relay took the offline member's update, sealed after the
    //    removal; the bridger read it from the mesh and kept it to pass on.
    canaries.check(update.refused && update.read && update.waiting);
    // 4. A relay took the bridger's send, its receive completed.
    canaries.check(own.taken);
    // 5. The removed member's view of the relay shows that send.
    canaries.check(own.id.is_some_and(|id| view.contains(&id)));

    let mut extra = Vec::new();
    if stage.at_a_relay(world, &update.event.id).await?
        || own.passed_on(&update.event.id)
        || view.contains(&update.event.id)
    {
        extra.push(stage.past_its_gate());
    }
    stage.close(world, tick, canaries, extra).await
}

/// The circle, who is who in it, and the radio between the two on mesh.
struct Stage {
    circle: SimCircle,
    plane: MeshPlane,
    /// Online, in range of the offline member, and the circle's admin.
    bridger: DeviceTag,
    /// On mesh, with no relay.
    offline: DeviceTag,
    /// A relay and no mesh.
    far: DeviceTag,
    /// Whether every wait of the setting-up ended in time — each entry's
    /// pass, the bridger's relay receive of the circle — and mesh is on at
    /// both mesh members.
    ready: bool,
    minted: u32,
    waits: Allowance,
}

/// One update of the offline member's.
struct Update {
    event: Event,
    probe: ProbeToken,
    /// Whether no relay took its own send.
    refused: bool,
    /// Whether the bridger then read it from the mesh, for the first time.
    read: bool,
    /// Whether the bridger's session then kept it to pass on.
    waiting: bool,
}

/// One send of the bridger's own.
struct OwnSend {
    id: Option<EventId>,
    /// Whether a relay took it.
    taken: bool,
    /// Every event the send's transport was asked to send.
    sent: Vec<Event>,
}

impl OwnSend {
    fn passed_on(&self, id: &EventId) -> bool {
        self.sent.iter().any(|event| event.id == *id)
    }
}

impl Stage {
    async fn set<T: TimelineSink, L: LogDrain>(
        world: &mut ScenarioWorld<T, L>,
        in_range: bool,
        mut waits: Allowance,
    ) -> Result<Self, RigError> {
        let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
        let [bridger, offline, .., far] = *tags.as_slice() else {
            return Err(RigError::ShapeMismatch);
        };
        // A device brought to the foreground holds its seals until the
        // NIP-77 pass its entry is owed has ended.
        for &tag in &tags {
            if let Some(bound) = waits.bound() {
                let ended = world.device(tag)?.entry_pass_ended(bound).await?;
                waits.ended(ended);
            }
        }
        let circle = world.build_extra_circle().await?;
        for online in [bridger, far] {
            let spec = circle.spec_for(online, world.relays());
            world.device_mut(online)?.subscribe_circle(spec).await?;
        }
        if let Some(bound) = waits.bound() {
            let session = world.device(bridger)?.session()?;
            let caught_up = await_condition(bound, || async {
                Ok(session.caught_up_for_test(circle.mls_group_id()))
            })
            .await?;
            waits.ended(caught_up);
        }
        let cap = ByteCap::new(REFUSES_EVERY_EVENT);
        for plane in world.relays_mut() {
            plane
                .apply_for(offline, Fault::RefuseOversize { max_bytes: cap })
                .await?;
        }
        let lit_bridger = turn_on(world.device(bridger)?).await?;
        let lit_offline = turn_on(world.device(offline)?).await?;
        let mut plane = MeshPlane::over(world.seed(), world.devices())?;
        if in_range {
            plane.link(offline, bridger)?;
        }
        Ok(Self {
            circle,
            plane,
            bridger,
            offline,
            far,
            ready: waits.all_ended() && lit_bridger && lit_offline,
            minted: 0,
            waits,
        })
    }

    fn mint(&mut self) -> ProbeToken {
        self.minted += 1;
        ProbeToken::mint(BRIDGE_ROUND, self.minted)
    }

    /// The offline member seals an update and sends it as the app does; the
    /// mesh runs one emission slot; the bridger drives. `None` if its seals
    /// are held: a device inside its entry's pass, never waited for, seals
    /// nothing, and the arm has then no update to grade.
    async fn update<T: TimelineSink, L: LogDrain>(
        &mut self,
        world: &ScenarioWorld<T, L>,
    ) -> Result<Option<Update>, RigError> {
        let probe = self.mint();
        let group = self.circle.mls_group_id();
        let Ok(event) = seal_probe(world, self.offline, group, probe, &WallClock).await? else {
            return Ok(None);
        };
        let (publish, _) = world
            .publish_and_bridge(self.offline, &event, false, &WallClock)
            .await?;
        self.plane.run(MeshPlane::slot_ms(), WallNow::now());
        let driven = self
            .plane
            .drive(world, self.bridger, WallNow::now())
            .await?;
        let author = world.device(self.offline)?.pubkey_hex();
        let read = driven.from_circles > 0
            && driven.replayed.iter().any(|result| {
                matches!(
                    result,
                    LocationMessageResult::Location { sender_pubkey, content, .. }
                        if *sender_pubkey == author && probe.carried_by(content)
                )
            });
        let waiting = world
            .device(self.bridger)?
            .session()?
            .mesh_bridge_waiting_for_test(group)
            .contains(&event.id);
        Ok(Some(Update {
            event,
            probe,
            refused: !taken(&publish),
            read,
            waiting,
        }))
    }

    /// The bridger seals a location of its own and sends it as the app does,
    /// `received` its word that the drive's relay receive completed first.
    async fn send<T: TimelineSink, L: LogDrain>(
        &mut self,
        world: &ScenarioWorld<T, L>,
        received: bool,
    ) -> Result<OwnSend, RigError> {
        let probe = self.mint();
        let group = self.circle.mls_group_id();
        let Ok(event) = seal_probe(world, self.bridger, group, probe, &WallClock).await? else {
            return Ok(OwnSend {
                id: None,
                taken: false,
                sent: Vec::new(),
            });
        };
        let (publish, sent) = world
            .publish_and_bridge(self.bridger, &event, received, &WallClock)
            .await?;
        Ok(OwnSend {
            id: Some(event.id),
            taken: taken(&publish),
            sent: sent
                .into_iter()
                .filter(|sent| sent.id != event.id)
                .collect(),
        })
    }

    async fn epoch<T: TimelineSink, L: LogDrain>(
        &self,
        world: &ScenarioWorld<T, L>,
        device: DeviceTag,
    ) -> Result<u64, RigError> {
        world
            .device(device)?
            .manager()?
            .group_epoch(self.circle.mls_group_id())
            .await
            .map_err(|_| RigError::Core(Step::ReadEpoch))
    }

    /// Whether any of the circle's relays stores `id`.
    async fn at_a_relay<T: TimelineSink, L: LogDrain>(
        &self,
        world: &ScenarioWorld<T, L>,
        id: &EventId,
    ) -> Result<bool, RigError> {
        for plane in world.relays() {
            if plane.stored(id).await? {
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// The far member's own view of the circle's relays: every event they
    /// serve it for the circle's routing id, asked over its own endpoint.
    async fn far_view<T: TimelineSink, L: LogDrain>(
        &self,
        world: &ScenarioWorld<T, L>,
    ) -> Result<Vec<EventId>, RigError> {
        let urls: Vec<String> = world
            .relays()
            .iter()
            .map(|plane| plane.url_for(self.far).to_owned())
            .collect();
        let filter = Filter::new().kind(Kind::Custom(445)).custom_tag(
            SingleLetterTag::lowercase(Alphabet::H),
            self.circle.group_id_hex(),
        );
        // A view that was not asked for, or could not be read, shows nothing,
        // and the canary that requires the bridger's own send in it then
        // goes unmet.
        let Some(bound) = self.waits.bound() else {
            return Ok(Vec::new());
        };
        Ok(world
            .device(self.far)?
            .relays
            .fetch_events(filter, &urls, Some(bound))
            .await
            .map(|events| events.into_iter().map(|event| event.id).collect())
            .unwrap_or_default())
    }

    /// The finding for an update passed on past a gate of the bridge.
    const fn past_its_gate(&self) -> (Invariant, Verdict) {
        (
            Invariant::RemovalUnreadability,
            Verdict::Failed(Finding::BridgedPastItsGate {
                device: self.bridger,
                circle: self.circle.tag,
            }),
        )
    }

    /// Heals the offline member's endpoint and grades the world it leaves.
    async fn close<T: TimelineSink, L: LogDrain>(
        self,
        world: &mut ScenarioWorld<T, L>,
        tick: Duration,
        canaries: Canaries,
        extra: Vec<(Invariant, Verdict)>,
    ) -> Result<ArmOutcome, RigError> {
        for plane in world.relays_mut() {
            plane.apply_for(self.offline, Fault::Heal).await?;
        }
        let pairs = closing_pairs(world, self.bridger);
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
}

/// Whether a relay took a send.
const fn taken(publish: &LocationPublish) -> bool {
    matches!(publish, LocationPublish::Sent(Ok(sent)) if sent.is_success())
}

#[cfg(test)]
mod tests {
    use super::ARMS;
    use crate::oracle::Recovery;

    #[test]
    fn each_arm_takes_one_fault_and_closes_no_socket() {
        for arm in ARMS {
            assert!(
                arm.floor.faults_applied == 1 && arm.recovery == Recovery::Undisturbed,
                "{}: the offline member's endpoint refuses, and nothing reconnects",
                arm.label
            );
            assert!(
                arm.floor.canaries_caught == 5,
                "{}: every premise of what is or is not passed on is observed",
                arm.label
            );
        }
    }
}
