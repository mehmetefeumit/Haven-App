//! **S27** — with the Bluetooth mesh on, a device sends a relay what it sends
//! with it off (T-INDEP-1a, `docs/BLUETOOTH_MESH_PLAN.md` §9.3).
//!
//! One script, run twice in one world: with the mesh off, then with it on
//! and every device in radio range of every other. What is compared between
//! the two passes, and must not differ:
//!
//! * per device, the multiset of the `EVENT` frames it sent a relay — each as
//!   (plane, kind, tag names, `expiration − created_at`, the answer its own
//!   endpoint was given, how many times it was sent);
//! * per endpoint of every plane, the canonical one included, how many
//!   `REQ`, `CLOSE`, `NEG-OPEN` and other frames it carried — and, on the
//!   canonical one, how many `EVENT`s;
//! * the answer of every seal and every send, in order.
//!
//! And within the mesh-on pass: a mesh drive asks its transport to send
//! nothing and moves no cursor or backfill floor; a device reads from the
//! mesh only what a send-time check passed; and O7, as for every arm, admits
//! every frame of both passes.
//!
//! Two things differ by design, and are counted apart rather than compared:
//! the seal made for the mesh alone — nothing is sealed with the mesh off,
//! and no relay is handed it with it on — and the one update a device passes
//! on to the relay (member bridging), once a relay. Any other frame carrying
//! an event its sender did not seal is a finding.
//!
//! # What is not compared
//!
//! The order of a device's frames and when each was sent; a connection that
//! is opened and carries no frame; and anything about a frame but its shape —
//! another `created_at`, another routing id, another filter under the same
//! verb all compare equal. Nor a NIP-77 session's course after its opening:
//! how many `NEG-MSG`s it takes is the relay's answer, and the pool sends a
//! `NEG-CLOSE` only for a session it finished, never for one a relay was too
//! slow for or refused. That a session was opened is compared.
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
//! sessions rather than being two runs of a profile. The mark before each
//! pass waits for the wire to be still, as O6 reads its fingerprint: no
//! endpoint carrying a new frame across [`STABILITY_TICKS`] observations a
//! tick apart — a foreground entry's NIP-77 pass ends in the engine before
//! its last frame has left, and however a session ended it sends nothing
//! more. The passes share an instant: every frame after the first mark is in
//! exactly one of them, and the last mark is taken behind the closing
//! round's settle, so a frame a device still had to send is counted.
//!
//! # One wait may run out
//!
//! The arm's bounded waits share one [`Allowance`]: after the first that
//! runs out, none is made, so whatever is broken costs one round trip, and
//! the passes are then not compared. Which wait it was decides what the run
//! says. A send a relay took and a peer's live plane never delivered is the
//! finding, by name. A wait of the setting-up — a foreground entry's pass
//! that has not ended, a wire that never stood still — is no finding of this
//! arm's: nothing it grades was observed, so the run is unusable (rc 3), and
//! a device that is really stuck is still named by the closing round. A wait
//! that was not made grades nothing.
//!
//! # The controls
//!
//! [`out_of_range_control`] runs the arm with no device in range of another:
//! no frame crosses a link and nothing is read from the mesh — rc 3.
//! [`late_setup_control`] runs it as after a setting-up wait that ran out:
//! rc 3, and no delivery named that nobody waited for.

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
use crate::oracle::quiescence::STABILITY_TICKS;
use crate::oracle::vacuity::{Canaries, ExpectationFloor, Observed};
use crate::oracle::{Finding, Invariant, ProbeToken, Reach, Recovery, Verdict};
use crate::relay::{plane_instant, CLIENT_VERBS};
use crate::rig::mesh::turn_on;
use crate::rig::{
    poll_until, DeviceTag, LogDrain, MeshPlane, PacingClock, RelayPlane, RelayTag, RigError, Step,
    TimelineSink,
};
use crate::scenarios::{
    closing_pairs, grade_round, listen, round, seal_probe, undelivered_to, Absence, Allowance, Arm,
    ArmOutcome, Scenario, ScenarioReport, ScenarioWorld, WithheldAcks, CONDITION_POLL,
    NO_GATING_ROWS,
};

/// The arm this scenario offers.
pub const ARMS: [Arm; 1] = [Arm {
    label: "mesh-off-then-on",
    recovery: Recovery::Undisturbed,
    // The closing round, and the one wait of the script that may run out.
    probe_rounds: 2,
    resubscribes: false,
    absence: Absence::None,
    // A refused send is answered at once: nothing waits out a silence.
    withheld_acks: WithheldAcks::None,
    floor: ExpectationFloor {
        // The refusing endpoint, once a pass.
        faults_applied: 2,
        epochs_crossed: 0,
        deliveries_observed: 1,
        canaries_caught: 6,
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
    independence(world, tick, true, Allowance::new()).await
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
    let outcome = independence(world, tick, false, Allowance::new()).await?;
    Ok(Scenario::MeshIndependence.report(world, &ARMS[0], outcome, started))
}

/// The arm as it runs once a wait of its setting-up has run out.
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
    let outcome = independence(world, tick, true, Allowance::run_out()).await?;
    Ok(Scenario::MeshIndependence.report(world, &ARMS[0], outcome, started))
}

async fn independence<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
    in_range: bool,
    mut waits: Allowance,
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
        if let Some(bound) = waits.bound() {
            let ended = world.device(tag)?.entry_pass_ended(bound).await?;
            waits.ended(ended);
        }
    }
    let mut minted = 0_u32;

    let start = Mark::still(world, tick, &mut waits).await?;
    let off = Pass::run(world, &at, None, &mut minted, &mut waits).await?;
    let cut = Mark::still(world, tick, &mut waits).await?;

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
    let on = Pass::run(world, &at, Some(&mut plane), &mut minted, &mut waits).await?;

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
    // The settle first, and the last mark behind it: what a device still had
    // to send when the script ended is in the mesh-on pass, not after it.
    let mut graded = grade_round(world, &closing, &[Invariant::Quiescence]).await?;
    let end = Mark::of(world);
    let sent_off = Sent::between(world, &start, &cut, &off.sealed_by);
    let sent_on = Sent::between(world, &cut, &end, &on.sealed_by);
    graded.extend(
        grade_round(
            world,
            &closing,
            &[Invariant::LocationRoundTrip, Invariant::SendPathLiveness],
        )
        .await?,
    );

    let entitled = on.refused.map(|refused| (at.bridger, refused));
    let mut canaries = Canaries::new();
    // 1. The mesh was on at every device, and frames crossed its links.
    canaries.check(lit && plane.carried() > 0);
    // 2. A peer read the refused update from the mesh, which no relay had.
    canaries.check(on.read_refused);
    // 3. …and it was passed on to the relay, counted apart from the
    //    device's own.
    canaries.check((sent_on.passed_on.iter()).any(|sent| Some((sent.device, sent.id)) == entitled));
    // 4. With the mesh on a location was sealed for it alone.
    canaries.check(on.mesh_only == 1);
    // 5. The refusing endpoint refused, in both passes.
    canaries.check(sent_off.refusals > 0 && sent_on.refusals > 0);
    // 6. No wait ran out: the entries' passes had ended, each mark was taken
    //    on a still wire, and every send was read from the relay before the
    //    mesh carried it, which is what makes the passes comparable.
    canaries.check(waits.all_ended());

    if let Some(undelivered) = off.undelivered.or(on.undelivered) {
        graded.push(undelivered);
    } else if waits.all_ended() {
        let moved = moved(&at, (&off, &sent_off), (&on, &sent_on));
        graded.extend(moved.map(|finding| {
            let verdict = Verdict::Failed(finding);
            (Invariant::RelayPlaneContainment, verdict)
        }));
    }

    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// What the mesh moved of a relay path, if it moved anything: the finding
/// names the device whose path, or no device for a plane's canonical
/// endpoint.
fn moved(
    at: &At,
    (off, sent_off): (&Pass, &Sent),
    (on, sent_on): (&Pass, &Sent),
) -> Option<Finding> {
    let of = |device| Some(Finding::RelayPathMoved { device });
    // With the mesh off nothing is sealed for it and nothing is passed on.
    if off.mesh_only != 0 {
        return of(Some(at.other));
    }
    if let Some(sent) = sent_off.passed_on.first() {
        return of(Some(sent.device));
    }
    if let Some(device) = on.strayed {
        return of(Some(device));
    }
    // The one update the script's sends were entitled to pass on, in one
    // frame a relay.
    let entitled = on.refused.map(|refused| (at.bridger, refused));
    if let Some(sent) = (sent_on.passed_on.iter())
        .find(|sent| Some((sent.device, sent.id)) != entitled || sent.times != 1)
    {
        return of(Some(sent.device));
    }
    if let Some((&(device, _), _)) =
        (off.answers.iter().zip(&on.answers)).find(|(without, with)| without != with)
    {
        return of(Some(device));
    }
    if off.answers.len() != on.answers.len() {
        return of(Some(at.bridger));
    }
    if let Some(device) = (at.tags.iter().copied())
        .find(|device| sent_off.frames.get(device) != sent_on.frames.get(device))
    {
        return of(Some(device));
    }
    (sent_off.others.iter().zip(&sent_on.others))
        .find(|(without, with)| without != with)
        .and_then(|((_, endpoint, _), _)| of(*endpoint))
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

/// One `EVENT` a device sent a relay, as the two passes compare it: nothing
/// here names an event, a circle or an instant.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Frame {
    plane: RelayTag,
    kind: u64,
    tags: Vec<String>,
    /// `expiration − created_at`, for an event that carries one.
    life_secs: Option<i64>,
    heard: Heard,
    /// How many frames carried it on the device's own endpoint: the plane
    /// record keeps a frame repeated on one connection once.
    times: usize,
}

/// One pass of the script.
struct Pass {
    /// Every seal's and send's answer but the mesh-only seal's, in order.
    answers: Vec<(DeviceTag, Answer)>,
    /// Sends answered as sealed for the mesh alone.
    mesh_only: usize,
    /// Who sealed each event of the pass.
    sealed_by: Vec<(EventId, DeviceTag)>,
    /// The update step 2's endpoint refused, if the device could seal one:
    /// one inside its entry's pass, never waited for, holds its seals.
    refused: Option<EventId>,
    /// Whether a peer read that update from the mesh, for the first time.
    read_refused: bool,
    /// A device whose mesh drive sent something, moved a cursor, or read an
    /// update no send-time check had passed.
    strayed: Option<DeviceTag>,
    /// The send a relay took that a peer's live plane, waited for, never
    /// delivered.
    undelivered: Option<(Invariant, Verdict)>,
}

/// A pass while it runs.
struct Script<'a, T: TimelineSink, L: LogDrain> {
    world: &'a mut ScenarioWorld<T, L>,
    at: &'a At,
    mesh: Option<&'a mut MeshPlane>,
    minted: &'a mut u32,
    waits: &'a mut Allowance,
    answers: Vec<(DeviceTag, Answer)>,
    mesh_only: usize,
    sealed_by: Vec<(EventId, DeviceTag)>,
    /// Every probe a send-time check passed.
    handed: Vec<ProbeToken>,
    /// Step 2's update, once it is sealed.
    refused: Option<(EventId, ProbeToken)>,
    read_refused: bool,
    strayed: Option<DeviceTag>,
    undelivered: Option<(Invariant, Verdict)>,
}

impl Pass {
    async fn run<T: TimelineSink, L: LogDrain>(
        world: &mut ScenarioWorld<T, L>,
        at: &At,
        mesh: Option<&mut MeshPlane>,
        minted: &mut u32,
        waits: &mut Allowance,
    ) -> Result<Self, RigError> {
        let mut script = Script {
            world,
            at,
            mesh,
            minted,
            waits,
            answers: Vec::new(),
            mesh_only: 0,
            sealed_by: Vec::new(),
            handed: Vec::new(),
            refused: None,
            read_refused: false,
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
        script.refused = script.send(at.quiet, &WallClock).await?;
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

        Ok(Self {
            answers: script.answers,
            mesh_only: script.mesh_only,
            sealed_by: script.sealed_by,
            refused: script.refused.map(|(refused, _)| refused),
            read_refused: script.read_refused,
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
    /// live plane while the arm may still wait. The event and its probe, when
    /// one was sealed.
    async fn send(
        &mut self,
        device: DeviceTag,
        clock: &dyn FanoutClock,
    ) -> Result<Option<(EventId, ProbeToken)>, RigError> {
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
        if let Some(bound) = self.waits.bound().filter(|_| answer == Answer::Taken) {
            let sender = self.world.device(device)?.pubkey_hex();
            if let Some(to) = undelivered_to(&mut listeners, &sender, probe, bound).await {
                self.waits.ended(false);
                let circle = self.world.circles()[0].tag;
                self.undelivered = Some((
                    Invariant::LocationRoundTrip,
                    Verdict::Failed(Finding::ProbeNotDelivered {
                        from: device,
                        to,
                        circle,
                    }),
                ));
            }
        }
        Ok(Some((event.id, probe)))
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
            let carried = |probe: &ProbeToken| {
                driven.replayed.iter().any(|result| {
                    matches!(
                        result,
                        LocationMessageResult::Location { content, .. }
                            if probe.carried_by(content)
                    )
                })
            };
            let unsent = driven.replayed.iter().any(|result| match result {
                LocationMessageResult::Location { content, .. } => {
                    !self.handed.iter().any(|probe| probe.carried_by(content))
                }
                _ => false,
            });
            if driven.sent != 0 || unsent || cursors(self.world, device)? != before {
                self.strayed.get_or_insert(device);
            }
            if driven.from_circles > 0 && self.refused.is_some_and(|(_, probe)| carried(&probe)) {
                self.read_refused = true;
            }
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

/// How many frames an endpoint carried, by verb: the slots of
/// [`CLIENT_VERBS`], then every other frame.
type ByVerb = [usize; CLIENT_VERBS.len() + 1];

/// The verbs that carry a NIP-77 session's course after its opening: the
/// relay's pace, never the device's choice.
const SESSION_COURSE: [&str; 2] = ["NEG-MSG", "NEG-CLOSE"];

/// What `endpoint` carried between two counts, as the passes compare it by
/// count: nothing of a device's own `EVENT`s, which are compared one by one,
/// and nothing of a session's course.
fn compared(endpoint: Option<DeviceTag>, before: ByVerb, after: ByVerb) -> ByVerb {
    let mut carried = after;
    for (slot, count) in carried.iter_mut().enumerate() {
        let verb = CLIENT_VERBS.get(slot);
        let apart = (endpoint.is_some() && verb == Some(&"EVENT"))
            || verb.is_some_and(|verb| SESSION_COURSE.contains(verb));
        *count = if apart { 0 } else { *count - before[slot] };
    }
    carried
}

/// An instant between passes: where the plane record stood, and how many
/// frames every endpoint of every plane had carried.
struct Mark {
    at: u64,
    carried: Vec<(RelayTag, Option<DeviceTag>, ByVerb)>,
}

impl Mark {
    /// A mark behind a still wire, while the arm may still wait for one: no
    /// endpoint carrying a new frame across [`STABILITY_TICKS`] observations
    /// a tick apart. Every end of a NIP-77 session reaches it, which a count
    /// of `NEG-CLOSE`s does not: the pool closes only a session it finished.
    async fn still<T: TimelineSink, L: LogDrain>(
        world: &ScenarioWorld<T, L>,
        tick: Duration,
        waits: &mut Allowance,
    ) -> Result<Self, RigError> {
        if let Some(bound) = waits.bound() {
            let (mut last, mut streak) = (None, 0_u8);
            let still = poll_until(bound, tick.max(CONDITION_POLL), || {
                let carried = Self::of(world).carried;
                streak = if last.as_ref() == Some(&carried) {
                    streak.saturating_add(1)
                } else {
                    1
                };
                last = Some(carried);
                std::future::ready(Ok(streak >= STABILITY_TICKS))
            })
            .await?;
            waits.ended(still.is_some());
        }
        Ok(Self::of(world))
    }

    fn of<T: TimelineSink, L: LogDrain>(world: &ScenarioWorld<T, L>) -> Self {
        let devices = world.devices().iter().map(|device| Some(device.tag));
        let endpoints: Vec<Option<DeviceTag>> = std::iter::once(None).chain(devices).collect();
        let mut carried = Vec::new();
        for plane in world.all_planes() {
            for &endpoint in &endpoints {
                let frames = plane.ledger().client_frames(endpoint);
                carried.push((plane.tag(), endpoint, frames));
            }
        }
        Self {
            at: plane_instant(),
            carried,
        }
    }
}

/// An event its sender did not seal, on one plane.
struct PassedOn {
    device: DeviceTag,
    id: EventId,
    /// How many frames carried it on that device's endpoint.
    times: usize,
}

/// What the devices sent the relays between two marks.
struct Sent {
    /// Each device's own `EVENT`s, sorted.
    frames: BTreeMap<DeviceTag, Vec<Frame>>,
    /// Frames carrying an event another device sealed.
    passed_on: Vec<PassedOn>,
    /// How many `EVENT`s a relay refused.
    refusals: usize,
    /// Per endpoint of every plane, the frames that are compared by count
    /// alone ([`compared`]).
    others: Vec<(RelayTag, Option<DeviceTag>, ByVerb)>,
}

impl Sent {
    fn between<T: TimelineSink, L: LogDrain>(
        world: &ScenarioWorld<T, L>,
        from: &Mark,
        to: &Mark,
        sealed_by: &[(EventId, DeviceTag)],
    ) -> Self {
        let (frames, passed_on, refusals) = events_between(world, from.at..to.at, sealed_by);
        let others = (from.carried.iter().zip(&to.carried))
            .map(|(&(plane, endpoint, before), &(_, _, after))| {
                (plane, endpoint, compared(endpoint, before, after))
            })
            .collect();
        Self {
            frames,
            passed_on,
            refusals,
            others,
        }
    }
}

/// Every `EVENT` a device's own endpoints first carried inside `window`, on
/// every plane, once an event however many frames carried it: each device's
/// own, sorted; those another device sealed; and how many a relay refused.
fn events_between<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    window: std::ops::Range<u64>,
    sealed_by: &[(EventId, DeviceTag)],
) -> (BTreeMap<DeviceTag, Vec<Frame>>, Vec<PassedOn>, usize) {
    let mut frames: BTreeMap<DeviceTag, Vec<Frame>> = BTreeMap::new();
    let (mut passed_on, mut refusals) = (Vec::new(), 0);
    for plane in world.all_planes() {
        let ledger = plane.ledger();
        // The record keeps a frame once a connection: an event sent again
        // on another is a second entry, and `times` counts every frame.
        let mut seen = Vec::new();
        for sent in ledger.plane_record().frames {
            let Some(device) = sent.endpoint.device().filter(|_| window.contains(&sent.at)) else {
                continue;
            };
            let Some((id, frame)) = projected(&sent.text, plane.tag()) else {
                continue;
            };
            if seen.contains(&(device, id)) {
                continue;
            }
            seen.push((device, id));
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
            let times = ledger.published_by(Some(device), &id);
            let foreign = sealed_by
                .iter()
                .any(|(sealed, sealer)| *sealed == id && *sealer != device);
            if foreign {
                passed_on.push(PassedOn { device, id, times });
            } else {
                frames.entry(device).or_default().push(Frame {
                    heard,
                    times,
                    ..frame
                });
            }
        }
    }
    for sent in frames.values_mut() {
        sent.sort();
    }
    (frames, passed_on, refusals)
}

/// A digest of every `EVENT` every device of `world` has sent a relay.
///
/// Each by the shape the passes compare: what two runs are compared by.
/// Nothing a mesh engine draws reaches a relay, so the runs of any seeds
/// agree on it.
#[must_use]
pub fn sent_digest<T: TimelineSink, L: LogDrain>(world: &ScenarioWorld<T, L>) -> [u8; 32] {
    let mut digest = Sha256::new();
    for (device, sent) in events_between(world, 0..u64::MAX, &[]).0 {
        for frame in sent {
            digest.update(device.ordinal().to_be_bytes());
            digest.update(frame.plane.ordinal().to_be_bytes());
            digest.update(frame.kind.to_be_bytes());
            digest.update(frame.life_secs.unwrap_or(-1).to_be_bytes());
            digest.update([frame.heard as u8]);
            digest.update(frame.times.to_be_bytes());
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
            times: 0,
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

    fn id(byte: u8) -> EventId {
        EventId::from_slice(&[byte; 32]).expect("32 bytes is an event id")
    }

    /// A pass that answered nothing, with `refused` as its refused update.
    fn pass(refused: EventId) -> Pass {
        Pass {
            answers: Vec::new(),
            mesh_only: 0,
            sealed_by: Vec::new(),
            refused: Some(refused),
            read_refused: false,
            strayed: None,
            undelivered: None,
        }
    }

    /// What one device sent one plane: `times` frames of one location, and
    /// `reqs` `REQ`s on its own endpoint and on the canonical one.
    fn sent(device: DeviceTag, times: usize, reqs: (usize, usize)) -> Sent {
        let (_, location) = projected(
            &frame("EVENT", r#"[["h","aa"],["expiration","1228"]]"#),
            RelayTag::new(0),
        )
        .expect("an EVENT frame");
        let by_verb = |reqs| {
            let mut carried = ByVerb::default();
            carried[1] = reqs;
            carried
        };
        Sent {
            frames: BTreeMap::from([(device, vec![Frame { times, ..location }])]),
            passed_on: Vec::new(),
            refusals: 0,
            others: vec![
                (RelayTag::new(0), None, by_verb(reqs.1)),
                (RelayTag::new(0), Some(device), by_verb(reqs.0)),
            ],
        }
    }

    #[test]
    fn a_resent_frame_a_further_request_and_a_second_pass_on_each_move_the_path() {
        let (bridger, quiet, other) = (DeviceTag::new(0), DeviceTag::new(1), DeviceTag::new(2));
        let at = At {
            group: GroupId::new(vec![7; 32]),
            bridger,
            quiet,
            other,
            tags: vec![bridger, quiet, other],
        };
        let (off, on) = (pass(id(1)), pass(id(2)));
        let moved = |sent_off: &Sent, sent_on: &Sent| moved(&at, (&off, sent_off), (&on, sent_on));
        let same = sent(quiet, 1, (0, 0));
        assert!(
            moved(&same, &sent(quiet, 1, (0, 0))).is_none(),
            "premise: two passes that sent the same are not a finding"
        );
        assert!(
            moved(&same, &sent(quiet, 2, (0, 0)))
                == Some(Finding::RelayPathMoved {
                    device: Some(quiet)
                }),
            "the same event sent twice, on one connection or two"
        );
        assert!(
            moved(&same, &sent(quiet, 1, (1, 0)))
                == Some(Finding::RelayPathMoved {
                    device: Some(quiet)
                }),
            "one more REQ on the device's own endpoint"
        );
        assert!(
            moved(&same, &sent(quiet, 1, (0, 1))) == Some(Finding::RelayPathMoved { device: None }),
            "one more REQ on the canonical endpoint, which no device's engine dials"
        );
        let passed_on = |times| {
            let mut sent = sent(quiet, 1, (0, 0));
            sent.passed_on.push(PassedOn {
                device: bridger,
                id: id(2),
                times,
            });
            sent
        };
        assert!(
            moved(&same, &passed_on(1)).is_none(),
            "the one update the bridger was entitled to pass on, in one frame"
        );
        assert!(
            moved(&same, &passed_on(2))
                == Some(Finding::RelayPathMoved {
                    device: Some(bridger)
                }),
            "the same update passed on in a second frame"
        );
    }

    #[test]
    fn a_sessions_opening_is_compared_and_its_course_is_not() {
        let slot = |verb| {
            (CLIENT_VERBS.iter())
                .position(|known| *known == verb)
                .expect("a verb the ledger counts")
        };
        let one_more = |verb| {
            let mut after = ByVerb::default();
            after[slot(verb)] = 1;
            compared(Some(DeviceTag::new(0)), ByVerb::default(), after)
        };
        let nothing = ByVerb::default();
        // A session a relay answered in time takes a NEG-MSG and a NEG-CLOSE
        // more than one it was too slow for.
        assert!(one_more("NEG-MSG") == nothing && one_more("NEG-CLOSE") == nothing);
        assert!(
            one_more("NEG-OPEN") != nothing && one_more("REQ") != nothing,
            "what a device chose to ask is compared"
        );
        assert!(
            one_more("EVENT") == nothing
                && compared(None, nothing, {
                    let mut after = nothing;
                    after[slot("EVENT")] = 1;
                    after
                }) != nothing,
            "a device's own EVENTs are compared one by one; the canonical endpoint's by count"
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
            arm.floor.canaries_caught == 6,
            "frames crossed, the refused update read from the mesh, passed on, one sealed for \
             the mesh alone, the refusal in both passes, and no wait that ran out"
        );
        assert!(
            arm.probe_rounds == 2,
            "the closing round, and the one wait of the script that may run out"
        );
    }
}
