//! **S27** — the Bluetooth mesh never changes the relay path (T-INDEP-1a,
//! `docs/BLUETOOTH_MESH_PLAN.md` §9.3).
//!
//! One script, run twice in one world: with the mesh off, then with it on
//! and every device in radio range of every other. The promise is a
//! difference between the two passes that must be empty:
//!
//! * per device, the multiset of the `EVENT` frames it sent a relay — each as
//!   (plane, kind, tag names, `expiration − created_at`, the relay's answer);
//! * the answer of every seal and every send, in order;
//! * a mesh drive asks its transport to send nothing and moves no cursor;
//! * a device reads from the mesh only what a send-time check passed;
//! * and O7, as for every arm, admits every frame of both passes.
//!
//! Two things differ by design, and are counted apart rather than compared:
//! the seal made for the mesh alone — nothing is sealed with the mesh off,
//! and no relay is handed it with it on — and the one update a device passes
//! on to the relay (member bridging). Any other frame carrying an event its
//! sender did not seal is a finding.
//!
//! # The script
//!
//! 1. Every device seals and sends, each send read by every peer from the
//!    relay before the mesh carries anything: the mesh's copy is then a
//!    duplicate, and nothing is passed on.
//! 2. One device's own endpoint refuses its events (`refuse-oversize`: no
//!    socket is closed, so nothing reconnects). It seals and sends; with the
//!    mesh on its peers read the update from the mesh alone, and the next
//!    device to send passes it on behind its own.
//! 3. A device seals for the mesh alone.
//! 4. A device sends a location a whole life after sealing it: expired, not
//!    sent, and never handed to the mesh.
//! 5. One more send, which passes nothing on.
//!
//! # One world, two passes
//!
//! An arm has one world, so the passes share its circles, relays and
//! sessions rather than being two runs of a profile. What is compared names
//! no value of either pass.
//!
//! # The control
//!
//! [`out_of_range_control`] runs the arm with no device in range of another:
//! no frame crosses a link and nothing is read from the mesh — rc 3.

use std::collections::BTreeMap;
use std::time::Duration;

use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::nostr::mls::types::{GroupId, LocationMessageResult};
use haven_core::relay::fanout::{FanoutClock, LocationPublish, LocationSeal, SendHeld, WallClock};
use haven_core::relay::live_sync::processor::group_cursor_stream;
use nostr::EventId;
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::clock::WallNow;
use crate::nemesis::types::{ByteCap, Fault};
use crate::oracle::vacuity::{Canaries, ExpectationFloor, Observed};
use crate::oracle::{bounds, Finding, Invariant, ProbeToken, Reach, Recovery, Verdict};
use crate::relay::plane_instant;
use crate::rig::mesh::turn_on;
use crate::rig::{
    DeviceTag, LogDrain, MeshPlane, PacingClock, RelayPlane, RelayTag, RigError, Step, TimelineSink,
};
use crate::scenarios::{
    closing_pairs, grade_round, listen, round, seal_probe, undelivered_to, Absence, Arm,
    ArmOutcome, Scenario, ScenarioReport, ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// The arm this scenario offers.
pub const ARMS: [Arm; 1] = [Arm {
    label: "mesh-off-then-on",
    recovery: Recovery::Undisturbed,
    probe_rounds: 1,
    resubscribes: false,
    absence: Absence::None,
    // A refused send is answered at once: nothing waits out a silence.
    withheld_acks: WithheldAcks::None,
    floor: ExpectationFloor {
        // The refusing endpoint, once a pass.
        faults_applied: 2,
        epochs_crossed: 0,
        deliveries_observed: 1,
        canaries_caught: 5,
    },
}];

/// The probe round every location of the script is minted from.
const SCRIPT_ROUND: u32 = 127;

/// Smaller than any event: the endpoint it is armed on refuses them all.
const REFUSES_EVERY_EVENT: usize = 1;

/// Runs the arm.
///
/// # Errors
///
/// [`RigError::ShapeMismatch`] if the world has fewer than three devices,
/// otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    _arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    independence(world, tick, true).await
}

/// The arm with no device in radio range of another.
///
/// The mis-configuration control in `tests/oracles.rs` requires rc 3 — the
/// mesh carried nothing, so the arm proved nothing about it.
///
/// # Errors
///
/// As [`run`].
pub async fn out_of_range_control<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
) -> Result<ScenarioReport, RigError> {
    let started = tokio::time::Instant::now();
    let outcome = independence(world, tick, false).await?;
    Ok(Scenario::MeshIndependence.report(world, &ARMS[0], outcome, started))
}

async fn independence<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
    in_range: bool,
) -> Result<ArmOutcome, RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [bridger, quiet, .., other] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    let circle = world.circles().first().ok_or(RigError::ShapeMismatch)?;
    let at = At {
        group: circle.mls_group_id().clone(),
        bridger,
        quiet,
        other,
        tags,
    };
    // A device brought to the foreground holds its seals, and may still move
    // a cursor, until the NIP-77 pass its entry is owed has ended.
    for &tag in &at.tags {
        let _ = world
            .device(tag)?
            .entry_pass_ended(bounds::round_trip(Recovery::Undisturbed))
            .await?;
    }
    let mut minted = 0_u32;

    let off = Pass::run(world, &at, None, &mut minted).await?;

    let mut lit = true;
    for &tag in &at.tags {
        lit &= turn_on(world.device(tag)?).await?;
    }
    let mut plane = MeshPlane::over(world.seed(), world.devices())?;
    if in_range {
        for (index, &from) in at.tags.iter().enumerate() {
            for &to in &at.tags[index + 1..] {
                plane.link(from, to)?;
            }
        }
    }
    let on = Pass::run(world, &at, Some(&mut plane), &mut minted).await?;

    let mut canaries = Canaries::new();
    // 1. The mesh was on at every device, and frames crossed its links.
    canaries.check(lit && plane.carried() > 0);
    // 2. An update was read from the mesh before any relay had it.
    canaries.check(on.read_first > 0);
    // 3. …and passed on to the relay, counted apart from the device's own.
    let entitled = (at.bridger, on.refused);
    canaries.check((on.passed_on.iter()).any(|(_, device, id)| (*device, *id) == entitled));
    // 4. With the mesh on a location was sealed for it alone.
    canaries.check(on.mesh_only == 1);
    // 5. The refusing endpoint refused, in both passes.
    canaries.check(off.refusals > 0 && on.refusals > 0);

    let pairs = closing_pairs(world, at.bridger);
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
    graded.extend(off.undelivered.into_iter().chain(on.undelivered));
    if let Some(device) = moved(&at, &off, &on) {
        graded.push((
            Invariant::RelayPlaneContainment,
            Verdict::Failed(Finding::RelayPathMoved { device }),
        ));
    }

    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// The device whose relay path the mesh moved, if it moved any.
fn moved(at: &At, off: &Pass, on: &Pass) -> Option<DeviceTag> {
    // With the mesh off nothing is sealed for it and nothing is passed on.
    if off.mesh_only != 0 {
        return Some(at.other);
    }
    if let Some(&(_, device, _)) = off.passed_on.first() {
        return Some(device);
    }
    if let Some(device) = on.strayed {
        return Some(device);
    }
    // The one update the script's sends were entitled to pass on, once a
    // relay.
    let entitled = (at.bridger, on.refused);
    for (index, &(plane, device, id)) in on.passed_on.iter().enumerate() {
        let again = on.passed_on[..index].iter().any(|sent| sent.0 == plane);
        if (device, id) != entitled || again {
            return Some(device);
        }
    }
    if let Some((&(device, _), _)) =
        (off.answers.iter().zip(&on.answers)).find(|(without, with)| without != with)
    {
        return Some(device);
    }
    if off.answers.len() != on.answers.len() {
        return Some(at.bridger);
    }
    at.tags
        .iter()
        .copied()
        .find(|device| off.frames.get(device) != on.frames.get(device))
}

/// The circle the script runs in, and who does what in it.
struct At {
    group: GroupId,
    /// Sends after the refused update, its relay receive completed.
    bridger: DeviceTag,
    /// Whose endpoint refuses its events in step 2.
    quiet: DeviceTag,
    /// Seals for the mesh alone.
    other: DeviceTag,
    tags: Vec<DeviceTag>,
}

/// What a seal or a send answered, as the two passes compare it.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Answer {
    Sealed,
    Held(SendHeld),
    Taken,
    Untaken,
    Expired,
    Superseded,
    Ended,
    InFlight,
    MeshOnly,
}

impl Answer {
    const fn of(publish: &LocationPublish) -> Self {
        match publish {
            LocationPublish::Sent(Ok(sent)) if sent.is_success() => Self::Taken,
            LocationPublish::Sent(_) => Self::Untaken,
            LocationPublish::Expired => Self::Expired,
            LocationPublish::Superseded => Self::Superseded,
            LocationPublish::Ended => Self::Ended,
            LocationPublish::InFlight => Self::InFlight,
            LocationPublish::MeshOnly => Self::MeshOnly,
        }
    }
}

/// What a relay answered an `EVENT` frame.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Heard {
    Accepted,
    Refused,
    Nothing,
}

/// One `EVENT` frame a device sent a relay, as the two passes compare it:
/// nothing here names an event, a circle or an instant.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Frame {
    plane: RelayTag,
    kind: u64,
    tags: Vec<String>,
    /// `expiration − created_at`, for an event that carries one.
    life_secs: Option<i64>,
    heard: Heard,
}

/// One pass of the script.
struct Pass {
    /// Every seal's and send's answer but the mesh-only seal's, in order.
    answers: Vec<(DeviceTag, Answer)>,
    /// Sends answered as sealed for the mesh alone.
    mesh_only: usize,
    /// Each device's own `EVENT` frames, sorted.
    frames: BTreeMap<DeviceTag, Vec<Frame>>,
    /// Frames carrying an event their sender did not seal: who sent which,
    /// to which plane.
    passed_on: Vec<(RelayTag, DeviceTag, EventId)>,
    /// How many `EVENT` frames a relay refused.
    refusals: usize,
    /// The update step 2's endpoint refused.
    refused: EventId,
    /// Updates read from the mesh before any relay delivered them.
    read_first: u64,
    /// A device whose mesh drive sent something, moved a cursor, or read an
    /// update no send-time check had passed.
    strayed: Option<DeviceTag>,
    /// A send a relay took that a peer's live plane never delivered.
    undelivered: Option<(Invariant, Verdict)>,
}

/// A pass while it runs.
struct Script<'a, T: TimelineSink, L: LogDrain> {
    world: &'a mut ScenarioWorld<T, L>,
    at: &'a At,
    mesh: Option<&'a mut MeshPlane>,
    minted: &'a mut u32,
    answers: Vec<(DeviceTag, Answer)>,
    mesh_only: usize,
    /// Who sealed each event of the pass.
    sealed_by: Vec<(EventId, DeviceTag)>,
    /// Every probe a send-time check passed.
    handed: Vec<ProbeToken>,
    read_first: u64,
    strayed: Option<DeviceTag>,
    undelivered: Option<(Invariant, Verdict)>,
}

impl Pass {
    async fn run<T: TimelineSink, L: LogDrain>(
        world: &mut ScenarioWorld<T, L>,
        at: &At,
        mesh: Option<&mut MeshPlane>,
        minted: &mut u32,
    ) -> Result<Self, RigError> {
        let since = plane_instant();
        let mut script = Script {
            world,
            at,
            mesh,
            minted,
            answers: Vec::new(),
            mesh_only: 0,
            sealed_by: Vec::new(),
            handed: Vec::new(),
            read_first: 0,
            strayed: None,
            undelivered: None,
        };

        // 1. Every device, the relay first.
        for &device in &at.tags {
            script.send(device, &WallClock).await?;
        }
        script.carry().await?;

        // 2. A refused update, then the send that passes it on.
        let cap = ByteCap::new(REFUSES_EVERY_EVENT);
        script
            .fault(Fault::RefuseOversize { max_bytes: cap })
            .await?;
        let refused = script.send(at.quiet, &WallClock).await?;
        script.carry().await?;
        script.send(at.bridger, &WallClock).await?;
        script.fault(Fault::Heal).await?;

        // 3. A seal for the mesh alone.
        script.seal_for_mesh(at.other).await?;
        script.carry().await?;

        // 4. A send a whole life after its seal.
        let late = PacingClock::default();
        late.step(LOCATION_MESSAGE_RETENTION_SECS * 1_000);
        script.send(at.quiet, &late).await?;
        script.carry().await?;

        // 5. One more send.
        script.send(at.bridger, &WallClock).await?;

        let sent = sent_since(script.world, since, &script.sealed_by);
        Ok(Self {
            answers: script.answers,
            mesh_only: script.mesh_only,
            frames: sent.frames,
            passed_on: sent.passed_on,
            refusals: sent.refusals,
            refused: refused.ok_or(RigError::Core(Step::Publish))?,
            read_first: script.read_first,
            strayed: script.strayed,
            undelivered: script.undelivered,
        })
    }
}

impl<T: TimelineSink, L: LogDrain> Script<'_, T, L> {
    fn mint(&mut self) -> ProbeToken {
        *self.minted += 1;
        ProbeToken::mint(SCRIPT_ROUND, *self.minted)
    }

    /// `device` seals a location and sends it as the app does, its relay
    /// receive completed; a send a relay took is awaited at every peer's
    /// live plane. The event's id, when one was sealed.
    async fn send(
        &mut self,
        device: DeviceTag,
        clock: &dyn FanoutClock,
    ) -> Result<Option<EventId>, RigError> {
        let (probe, at) = (self.mint(), self.at);
        let event = match seal_probe(self.world, device, &at.group, probe, &WallClock).await? {
            Ok(event) => event,
            Err(held) => {
                self.answers.push((device, Answer::Held(held)));
                return Ok(None);
            }
        };
        self.answers.push((device, Answer::Sealed));
        self.sealed_by.push((event.id, device));
        let peers: Vec<DeviceTag> = (at.tags.iter().copied())
            .filter(|peer| *peer != device)
            .collect();
        let mut listeners = listen(self.world, &peers)?;
        let (publish, _) = self
            .world
            .publish_and_bridge(device, &event, true, clock)
            .await?;
        let answer = Answer::of(&publish);
        self.answers.push((device, answer));
        if matches!(publish, LocationPublish::Sent(_)) {
            self.handed.push(probe);
        }
        if answer == Answer::Taken {
            let sender = self.world.device(device)?.pubkey_hex();
            let bound = bounds::round_trip(Recovery::Undisturbed);
            if let Some(to) = undelivered_to(&mut listeners, &sender, probe, bound).await {
                let circle = self.world.circles()[0].tag;
                self.undelivered.get_or_insert((
                    Invariant::LocationRoundTrip,
                    Verdict::Failed(Finding::ProbeNotDelivered {
                        from: device,
                        to,
                        circle,
                    }),
                ));
            }
        }
        Ok(Some(event.id))
    }

    /// `device` seals for the mesh alone, and sends what it sealed. Counted,
    /// never compared: with the mesh off nothing is sealed.
    async fn seal_for_mesh(&mut self, device: DeviceTag) -> Result<(), RigError> {
        let probe = self.mint();
        let sealed = self
            .world
            .seal_for_mesh(device, &self.at.group, &probe.as_location(), &WallClock)
            .await?;
        let LocationSeal::Sealed { event, .. } = sealed.seal else {
            return Ok(());
        };
        self.sealed_by.push((event.id, device));
        let (publish, _) = self
            .world
            .publish_and_bridge(device, &event, true, &WallClock)
            .await?;
        if matches!(publish, LocationPublish::MeshOnly) {
            self.mesh_only += 1;
            self.handed.push(probe);
        } else {
            self.answers.push((device, Answer::of(&publish)));
        }
        Ok(())
    }

    /// Arms `fault` on the quiet device's own endpoint of every plane its
    /// circles name.
    async fn fault(&mut self, fault: Fault) -> Result<(), RigError> {
        let quiet = self.at.quiet;
        for plane in self.world.relays_mut() {
            plane.apply_for(quiet, fault).await?;
        }
        Ok(())
    }

    /// With the mesh on: one emission slot, then every device's drive.
    async fn carry(&mut self) -> Result<(), RigError> {
        let Some(plane) = self.mesh.as_deref_mut() else {
            return Ok(());
        };
        plane.run(MeshPlane::slot_ms(), WallNow::now());
        for &device in &self.at.tags {
            let before = cursors(self.world, device)?;
            let driven = plane.drive(self.world, device, WallNow::now()).await?;
            let unsent = driven.replayed.iter().any(|result| match result {
                LocationMessageResult::Location { content, .. } => {
                    !self.handed.iter().any(|probe| probe.carried_by(content))
                }
                _ => false,
            });
            if driven.sent != 0 || unsent || cursors(self.world, device)? != before {
                self.strayed.get_or_insert(device);
            }
            self.read_first += driven.from_circles;
        }
        Ok(())
    }
}

/// One circle's persisted cursor and backfill floor.
type Asked = (Option<i64>, Option<i64>);

/// `device`'s persisted cursor and backfill floor for every circle of the
/// world: what a relay is next asked from.
fn cursors<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    device: DeviceTag,
) -> Result<Vec<Asked>, RigError> {
    let manager = world.device(device)?.manager()?;
    let read = |_| RigError::Core(Step::ReadCursor);
    world
        .circles()
        .iter()
        .map(|circle| {
            let stream = group_cursor_stream(circle.group_id_hex());
            Ok((
                manager.read_sync_cursor(&stream).map_err(read)?,
                manager.read_backfill_floor(&stream).map_err(read)?,
            ))
        })
        .collect()
}

/// What the devices sent the relays.
struct Sent {
    /// Each device's own `EVENT` frames, sorted.
    frames: BTreeMap<DeviceTag, Vec<Frame>>,
    /// Frames carrying an event another device sealed.
    passed_on: Vec<(RelayTag, DeviceTag, EventId)>,
    /// How many frames a relay refused.
    refusals: usize,
}

/// Every `EVENT` frame a device's own endpoints carried since `since`, on
/// every plane.
///
/// The canonical endpoint is not read: only a sweep and the rig's own reads
/// dial it, and the script runs neither.
fn sent_since<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    since: u64,
    sealed_by: &[(EventId, DeviceTag)],
) -> Sent {
    let mut frames: BTreeMap<DeviceTag, Vec<Frame>> = BTreeMap::new();
    let (mut passed_on, mut refusals) = (Vec::new(), 0);
    for plane in world.all_planes() {
        let ledger = plane.ledger();
        for sent in ledger.plane_record().frames {
            let Some(device) = sent.endpoint.device().filter(|_| sent.at >= since) else {
                continue;
            };
            let Some((id, frame)) = projected(&sent.text, plane.tag()) else {
                continue;
            };
            // What THIS device's endpoint was answered: an event refused
            // here can be taken on the socket of the device that passes it on.
            let heard = match ledger.answered(Some(device), &id) {
                Some(true) => Heard::Accepted,
                Some(false) => {
                    refusals += 1;
                    Heard::Refused
                }
                None => Heard::Nothing,
            };
            let foreign = sealed_by
                .iter()
                .any(|(sealed, sealer)| *sealed == id && *sealer != device);
            if foreign {
                passed_on.push((plane.tag(), device, id));
            } else {
                frames
                    .entry(device)
                    .or_default()
                    .push(Frame { heard, ..frame });
            }
        }
    }
    for sent in frames.values_mut() {
        sent.sort();
    }
    Sent {
        frames,
        passed_on,
        refusals,
    }
}

/// A digest of every `EVENT` frame every device of `world` has sent a relay.
///
/// Each frame by the shape the passes compare: what two runs are compared
/// by. One seed's runs agree on it, and so do two seeds', since nothing a
/// mesh engine draws reaches a relay.
#[must_use]
pub fn sent_digest<T: TimelineSink, L: LogDrain>(world: &ScenarioWorld<T, L>) -> [u8; 32] {
    let mut digest = Sha256::new();
    for (device, sent) in sent_since(world, 0, &[]).frames {
        for frame in sent {
            digest.update(device.ordinal().to_be_bytes());
            digest.update(frame.plane.ordinal().to_be_bytes());
            digest.update(frame.kind.to_be_bytes());
            digest.update(frame.life_secs.unwrap_or(-1).to_be_bytes());
            digest.update([frame.heard as u8]);
            for tag in frame.tags {
                digest.update(tag);
                digest.update([0]);
            }
        }
    }
    digest.finalize().into()
}

/// The event a recorded `EVENT` frame carries and what the passes compare of
/// it, its answer still to be read; `None` for any other frame.
fn projected(text: &str, plane: RelayTag) -> Option<(EventId, Frame)> {
    let frame: Value = serde_json::from_str(text).ok()?;
    if frame.get(0)?.as_str()? != "EVENT" {
        return None;
    }
    let event = frame.get(1)?;
    let id = EventId::from_hex(event.get("id")?.as_str()?).ok()?;
    let tag = |tag: &Value| Some((tag.get(0)?.as_str()?.to_owned(), tag.get(1).cloned()));
    let tagged: Vec<(String, Option<Value>)> = event
        .get("tags")?
        .as_array()?
        .iter()
        .filter_map(tag)
        .collect();
    let expiration = tagged.iter().find_map(|(name, value)| {
        (name == "expiration")
            .then(|| value.as_ref()?.as_str()?.parse::<i64>().ok())
            .flatten()
    });
    let created_at = event.get("created_at")?.as_i64()?;
    let mut tags: Vec<String> = tagged.into_iter().map(|(name, _)| name).collect();
    tags.sort();
    Some((
        id,
        Frame {
            plane,
            kind: event.get("kind")?.as_u64()?,
            tags,
            life_secs: expiration.map(|expires| expires - created_at),
            heard: Heard::Nothing,
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "00000000000000000000000000000000000000000000000000000000000000aa";

    fn frame(verb: &str, tags: &str) -> String {
        format!(
            r#"["{verb}",{{"id":"{ID}","pubkey":"{ID}","created_at":1000,"kind":445,"tags":{tags}}}]"#
        )
    }

    #[test]
    fn a_frame_is_compared_by_shape_and_never_by_value() {
        let plane = RelayTag::new(0);
        let (id, location) = projected(
            &frame("EVENT", r#"[["h","aa"],["expiration","1228"]]"#),
            plane,
        )
        .expect("an EVENT frame");
        assert_eq!(id.to_hex(), ID);
        assert!(location.kind == 445 && location.life_secs == Some(228));
        assert_eq!(location.tags, ["expiration", "h"]);

        let (_, other) = projected(
            &frame("EVENT", r#"[["expiration","5228"],["h","bb"]]"#),
            plane,
        )
        .expect("an EVENT frame");
        assert!(
            location.tags == other.tags && location.life_secs != other.life_secs,
            "another routing id is the same shape; another lifetime is not"
        );

        let (_, commit) =
            projected(&frame("EVENT", r#"[["h","aa"]]"#), plane).expect("an EVENT frame");
        assert!(commit.life_secs.is_none() && commit != location);
        assert!(
            projected(&frame("REQ", "[]"), plane).is_none(),
            "only an EVENT frame is a send"
        );
    }

    #[test]
    fn the_arm_refuses_once_a_pass_and_closes_no_socket() {
        let arm = ARMS[0];
        assert!(
            arm.floor.faults_applied == 2 && arm.recovery == Recovery::Undisturbed,
            "the refusing endpoint is armed once a pass, and nothing reconnects"
        );
        assert!(
            arm.floor.canaries_caught == 5,
            "frames crossed, an update read from the mesh, one passed on, one sealed for the \
             mesh alone, and the refusal in both passes"
        );
    }
}
