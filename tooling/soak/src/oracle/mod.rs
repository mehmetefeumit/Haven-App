//! The oracles: the promises a soak run actually grades.
//!
//! An oracle is not a check that something did not crash. Each one here names a
//! promise Haven makes, states it in terms the product itself can answer, and
//! FAILS when the promise breaks — which is why every one of them has a positive
//! control in `tests/oracles.rs` that plants a defect and watches it go red.
//!
//! # The registry is exhaustive, and deliberately short
//!
//! [`Invariant::REGISTRY`] is every oracle Phase 1 grades: O1, O2, O5 and O6.
//! **O3 (forward secrecy) and O4 (retention window) are NOT here, and there is
//! no placeholder for them.** O3 needs a per-member commit drop and O4 needs a
//! five-epoch advance, and the scenarios that produce those states are not in
//! this phase — an entry that could never run would report coverage this crate
//! does not have, which is worse than the absence. The same goes for PLAN §2.1's
//! safety invariants S4 (wire privacy) and S9 (kind-445 nonce uniqueness): both
//! want relay-ledger evidence the Phase-1 ledger does not keep.
//!
//! # Every verdict is value-free
//!
//! A verdict says WHICH promise broke and, through the rig's own handles, WHICH
//! device or circle it broke for. It never carries an epoch, a group id, a
//! pubkey, a coordinate or a count — the report is a log, and Security Rule 15
//! applies to it exactly as it applies to the product's.
//!
//! # Two oracles MUTATE, and the order they do it in is a contract
//!
//! [`Invariant::LocationRoundTrip`] publishes a real location and
//! [`Invariant::SendPathLiveness`] attempts a real send. A send that the engine
//! QUEUES rather than encrypts runs `repair_deferred_send` inside
//! `encrypt_location` — a sweep that retires stored rows. So neither of these
//! two may be run against a circle a scenario has deliberately gated: it would
//! repair the very row the scenario planted and then report the world healthy.
//! S06 grades O5 and the gating count for exactly that reason.

pub mod bounds;
pub mod quiescence;
pub mod undecryptable;
pub mod vacuity;

use std::fmt;
use std::time::Duration;

use haven_core::location::{LocationMessage, LOCATION_MESSAGE_RETENTION_SECS};
use haven_core::nostr::mls::types::ConvergedRoster;
use haven_core::relay::live_sync::LiveSyncEvent;
use tokio::sync::broadcast::error::TryRecvError;
use tokio::sync::broadcast::Receiver;
use tokio::time::{Instant, MissedTickBehavior};

use crate::rc::Rc;
use crate::rig::{
    CircleTag, DeviceTag, LogDrain, RelayPlane, RigError, SimCircle, SimDevice, SimWorld, Step,
    TimelineSink,
};

pub use bounds::Recovery;
pub use quiescence::PendingReason;
pub use vacuity::FloorTerm;

/// How often a bounded wait for a delivery re-reads its receiver.
///
/// A harness poll interval, not a product bound: no expectation is derived from
/// it, and shortening it only makes a passing round finish sooner.
const DELIVERY_POLL: Duration = Duration::from_millis(10);

/// One promise the run grades.
///
/// An enum rather than a table of trait objects: the set is closed, the compiler
/// checks that every arm is dispatched, and an oracle that is not in this enum
/// cannot be silently registered without an implementation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Invariant {
    /// **O1** — a location minted in this round, sent at the sender's current
    /// epoch, is decrypted BY THE PEER as exactly those bytes.
    ///
    /// §3.5 calls this one ONE BRANCH. The name here says what it measures:
    /// "a decrypt succeeded", "the epochs are equal" and "a probe from an
    /// earlier round arrived" are all things that can be true while the two
    /// devices are on different branches, so none of them is a substitute.
    LocationRoundTrip,
    /// **O2** — every online device agrees on the roster and the epoch, nothing
    /// gates the outbound path, and a send REALLY WORKS.
    ///
    /// §3.5 calls this one CONVERGED ROSTER. The read half is the roster; the
    /// send attempt is the half that makes the read trustworthy, because after
    /// an unrecovered removal-bearing staged commit every read accessor answers
    /// cheerfully about a group that can no longer send.
    SendPathLiveness,
    /// **O5** — every event that did not decrypt has an account.
    ///
    /// Graded over the classifications the scenario collected through
    /// [`undecryptable::classify`], because the subject of this oracle is an
    /// event's disposition rather than a state of the world.
    Undecryptable,
    /// **O6** — the world stops moving, and does so within the derived bound.
    Quiescence,
}

impl Invariant {
    /// Every oracle this phase grades. See the module docs for why O3 and O4 are
    /// not among them.
    pub const REGISTRY: [Self; 4] = [
        Self::LocationRoundTrip,
        Self::SendPathLiveness,
        Self::Undecryptable,
        Self::Quiescence,
    ];

    /// The oracle's id, as the plan and the timeline spell it.
    #[must_use]
    pub const fn id(self) -> &'static str {
        match self {
            Self::LocationRoundTrip => "O1",
            Self::SendPathLiveness => "O2",
            Self::Undecryptable => "O5",
            Self::Quiescence => "O6",
        }
    }

    /// The promise, in words.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::LocationRoundTrip => "LOCATION ROUND-TRIP",
            Self::SendPathLiveness => "SEND-PATH LIVENESS",
            Self::Undecryptable => "UNDECRYPTABLE ACCOUNTED",
            Self::Quiescence => "QUIESCENCE",
        }
    }

    /// Grades this promise against `world`.
    ///
    /// `&mut` because [`Self::Quiescence`] runs the world until it settles, and
    /// a settle that could not drain the devices' buses would be grading a world
    /// it was starving.
    ///
    /// # Errors
    ///
    /// [`RigError`] if a read failed — which is the rig being broken, never the
    /// subject failing. A subject failure is a [`Verdict`].
    pub async fn check<R: RelayPlane, T: TimelineSink, L: LogDrain>(
        self,
        world: &mut SimWorld<R, T, L>,
        round: &Round<'_>,
    ) -> Result<Verdict, RigError> {
        match self {
            Self::LocationRoundTrip => location_round_trip(world, round).await,
            Self::SendPathLiveness => send_path_liveness(world, round).await,
            Self::Undecryptable => Ok(undecryptable_accounted(round)),
            Self::Quiescence => quiescence_holds(world, round).await,
        }
    }
}

impl fmt::Display for Invariant {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} {}", self.id(), self.title())
    }
}

/// What one oracle answered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// The promise held.
    Holds,
    /// It did not, and this is why.
    Failed(Finding),
}

impl Verdict {
    /// The exit verdict this answer folds into.
    #[must_use]
    pub const fn rc(self) -> Rc {
        match self {
            Self::Holds => Rc::Clean,
            Self::Failed(finding) => finding.rc(),
        }
    }
}

impl fmt::Display for Verdict {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Holds => f.write_str("holds"),
            Self::Failed(finding) => fmt::Display::fmt(finding, f),
        }
    }
}

/// Why an oracle failed.
///
/// Every variant is a classification plus, at most, the rig's own handles. There
/// is no payload here that names a thing outside this crate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Finding {
    /// No relay's client-facing stream acknowledged the probe, so the send did
    /// not happen — whatever the peer may already hold.
    ProbeNotPublished {
        /// Who was sending.
        device: DeviceTag,
        /// In which circle.
        circle: CircleTag,
    },
    /// The peer never decrypted the bytes this round minted.
    ProbeNotDelivered {
        /// Who sent.
        from: DeviceTag,
        /// Who should have received.
        to: DeviceTag,
        /// In which circle.
        circle: CircleTag,
    },
    /// The oracle's own receiver fell behind, so a delivery may have happened
    /// unseen. The rig is broken, not the subject.
    DeliveryEvidenceLost {
        /// Whose bus was being read.
        to: DeviceTag,
    },
    /// A device is carrying more gating rows than the round declared it may.
    RowEnvelopeExceeded {
        /// Whose store.
        device: DeviceTag,
        /// Which circle's rows.
        circle: CircleTag,
    },
    /// The round asked for nothing, so nothing was graded.
    NothingProbed,
    /// A device holds no converged roster for a circle at all.
    RosterNotConverged {
        /// Whose view.
        device: DeviceTag,
        /// Which circle.
        circle: CircleTag,
    },
    /// Two online devices hold different rosters for one circle.
    RosterDiverged {
        /// Which circle.
        circle: CircleTag,
    },
    /// Two online devices hold different epochs for one circle.
    EpochDiverged {
        /// Which circle.
        circle: CircleTag,
    },
    /// Stored inputs still gate a circle's outbound path.
    ConvergenceGated {
        /// Whose store.
        device: DeviceTag,
        /// Which circle.
        circle: CircleTag,
    },
    /// A stored proposal is still waiting for a commit.
    ProposalUncommitted {
        /// Whose store.
        device: DeviceTag,
        /// Which circle.
        circle: CircleTag,
    },
    /// A durable eviction obligation is unredeemed.
    RemovalOwed {
        /// Whose store.
        device: DeviceTag,
    },
    /// A durable eviction obligation outlived the session that staged it, so
    /// nothing can publish or clear it.
    RemovalOrphaned {
        /// Whose store.
        device: DeviceTag,
    },
    /// The engine refused a send, classified.
    SendRefused {
        /// Who was sending.
        device: DeviceTag,
        /// In which circle.
        circle: CircleTag,
        /// What the send-side classifier made of it.
        cause: undecryptable::Verdict,
    },
    /// An event's disposition is one the classifier cannot account for.
    UnaccountedOutcome,
    /// A past-epoch disposition could not be resolved because the harness did
    /// not name the stored row — never folded into "no branch was lost".
    UnnamedRow,
    /// The round collected no classification, so O5 would grade an empty set.
    NothingClassified,
    /// The world was still moving when its derived deadline elapsed.
    NotQuiescent(PendingReason),
    /// A device's burst never finished the stored replay it opened.
    BacklogUnsettled {
        /// Whose burst.
        device: DeviceTag,
    },
    /// An arm did less than it declared, so its verdicts prove nothing.
    FloorUnmet(FloorTerm),
}

impl Finding {
    /// The exit verdict this finding folds into.
    ///
    /// Three distinct meanings, and the distinction is the whole point of the
    /// taxonomy: the subject broke a promise (rc 1), the RIG could not answer
    /// (rc 2), or the world never reached a state worth grading (rc 3).
    #[must_use]
    pub const fn rc(self) -> Rc {
        match self {
            Self::ProbeNotPublished { .. }
            | Self::ProbeNotDelivered { .. }
            | Self::RosterNotConverged { .. }
            | Self::RosterDiverged { .. }
            | Self::EpochDiverged { .. }
            | Self::ConvergenceGated { .. }
            | Self::ProposalUncommitted { .. }
            | Self::RemovalOwed { .. }
            | Self::RemovalOrphaned { .. }
            | Self::SendRefused { .. }
            | Self::UnaccountedOutcome
            | Self::NotQuiescent(_)
            | Self::BacklogUnsettled { .. } => Rc::ViolationOrLeak,
            Self::DeliveryEvidenceLost { .. } | Self::UnnamedRow => Rc::RigBroken,
            Self::RowEnvelopeExceeded { .. }
            | Self::NothingProbed
            | Self::NothingClassified
            | Self::FloorUnmet(_) => Rc::Unusable,
        }
    }
}

impl fmt::Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ProbeNotPublished { device, circle } => {
                write!(f, "no relay acknowledged the probe ({device}, {circle})")
            }
            Self::ProbeNotDelivered { from, to, circle } => {
                write!(
                    f,
                    "this round's probe never arrived ({from} -> {to}, {circle})"
                )
            }
            Self::DeliveryEvidenceLost { to } => {
                write!(f, "the delivery record is incomplete ({to})")
            }
            Self::RowEnvelopeExceeded { device, circle } => {
                write!(
                    f,
                    "gating rows above the declared envelope ({device}, {circle})"
                )
            }
            Self::NothingProbed => f.write_str("the round probed nothing"),
            Self::RosterNotConverged { device, circle } => {
                write!(f, "no converged roster ({device}, {circle})")
            }
            Self::RosterDiverged { circle } => write!(f, "rosters disagree ({circle})"),
            Self::EpochDiverged { circle } => write!(f, "epochs disagree ({circle})"),
            Self::ConvergenceGated { device, circle } => {
                write!(f, "stored inputs gate the send path ({device}, {circle})")
            }
            Self::ProposalUncommitted { device, circle } => {
                write!(f, "a proposal is still uncommitted ({device}, {circle})")
            }
            Self::RemovalOwed { device } => write!(f, "an eviction commit is owed ({device})"),
            Self::RemovalOrphaned { device } => {
                write!(f, "an eviction commit is orphaned ({device})")
            }
            Self::SendRefused {
                device,
                circle,
                cause,
            } => write!(f, "the send was refused ({device}, {circle}, {cause:?})"),
            Self::UnaccountedOutcome => f.write_str("an ingest outcome has no account"),
            Self::UnnamedRow => {
                f.write_str("a past-epoch row was not named, so a branch loss is undetermined")
            }
            Self::NothingClassified => f.write_str("the round classified nothing"),
            Self::NotQuiescent(reason) => write!(f, "still moving at the deadline ({reason:?})"),
            Self::BacklogUnsettled { device } => {
                write!(f, "a burst's stored replay never settled ({device})")
            }
            Self::FloorUnmet(term) => write!(f, "an expectation floor was unmet ({term:?})"),
        }
    }
}

/// Which ordered pairs [`Invariant::LocationRoundTrip`] probes this round.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reach<'a> {
    /// Every ordered pair of devices — the teardown sweep.
    EveryOrderedPair,
    /// Exactly these ordered pairs.
    ///
    /// The intermediate rounds' spanning tree comes in here rather than being
    /// rolled inside the oracle, because the rig's RNG lives only in the nemesis
    /// generator: a tick that sampled would make the run unreproducible from its
    /// seed, which is the one thing the whole harness is built around.
    These(&'a [(DeviceTag, DeviceTag)]),
}

/// Everything a check needs that the world does not already carry.
///
/// Built with a struct literal and no defaults on purpose: every term is a
/// declaration the scenario owes, and a default would let an arm inherit a
/// deadline or an envelope nobody chose.
#[derive(Debug, Clone, Copy)]
pub struct Round<'a> {
    /// Which round this is. Probes are minted from it, so two rounds never mint
    /// the same probe and an arrival from an earlier round cannot satisfy this
    /// one.
    pub ordinal: u32,
    /// Which pairs O1 probes.
    pub reach: Reach<'a>,
    /// The most disruptive thing the world is recovering from — every bound is
    /// derived from it.
    pub recovery: Recovery,
    /// The world's tick, which the settle loop re-reads at.
    pub tick: Duration,
    /// The most gating rows O1 tolerates per device per circle.
    pub row_envelope: usize,
    /// Devices whose burst window the harness itself opened this phase, and
    /// only those (see [`quiescence::confirm_backlog_settled`]).
    pub burst_opened: &'a [DeviceTag],
    /// What the scenario's own ingests classified — O5's whole subject.
    pub classified: &'a [undecryptable::Verdict],
}

/// The 16-bit span each half of a probe is minted from.
const PROBE_SPAN: u32 = 1 << 16;

/// Degrees per round step. `65535 / 1024` stays inside the latitude range, and
/// a power of two keeps every probe exactly representable in binary floating
/// point — which is what lets the round trip be compared bit for bit.
const PROBE_LAT_SCALE: f64 = 1024.0;

/// Degrees per pair step, chosen the same way against the longitude range.
const PROBE_LON_SCALE: f64 = 512.0;

/// The bytes one round asks one peer to decrypt.
///
/// Named a probe token rather than a nonce: Security Rule 11's nonce is the
/// kind-445 AEAD nonce, a different thing with a different contract, and one
/// word for both would eventually be read as one requirement.
#[derive(Clone, Copy, PartialEq)]
pub struct ProbeToken {
    latitude: f64,
    longitude: f64,
}

impl ProbeToken {
    /// Mints the probe for `(round, index)`.
    ///
    /// Injective while both halves stay under 2^16, which is more rounds and
    /// more pairs per round than any run this rig executes. Distinctness is the
    /// whole requirement: a probe that repeated across rounds would let a stale
    /// arrival satisfy a fresh round, which is exactly the substitution O1
    /// exists to forbid.
    #[must_use]
    pub fn mint(round: u32, index: u32) -> Self {
        Self {
            latitude: f64::from(round % PROBE_SPAN) / PROBE_LAT_SCALE,
            longitude: f64::from(index % PROBE_SPAN) / PROBE_LON_SCALE,
        }
    }

    /// The probe as the location message that carries it.
    #[must_use]
    pub fn as_location(self) -> LocationMessage {
        LocationMessage::new(self.latitude, self.longitude)
    }

    /// Whether `content` is a location carrying exactly these bytes.
    ///
    /// Bit-for-bit rather than approximate: the promise is that the peer
    /// decrypted THESE bytes, and a tolerance would let a neighbouring probe
    /// satisfy it.
    #[must_use]
    pub fn carried_by(self, content: &str) -> bool {
        LocationMessage::from_string(content).is_ok_and(|message| {
            message.latitude.to_bits() == self.latitude.to_bits()
                && message.longitude.to_bits() == self.longitude.to_bits()
        })
    }
}

// Presence-only: a coordinate is an identifier, and this one is registered as a
// needle precisely so that a line carrying it reds the scan.
impl fmt::Debug for ProbeToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ProbeToken(..)")
    }
}

/// O1's ordered pairs for this round.
fn pairs_of<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &SimWorld<R, T, L>,
    reach: Reach<'_>,
) -> Vec<(DeviceTag, DeviceTag)> {
    match reach {
        Reach::These(pairs) => pairs.to_vec(),
        Reach::EveryOrderedPair => {
            let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
            tags.iter()
                .flat_map(|from| {
                    tags.iter()
                        .filter(move |to| *to != from)
                        .map(move |to| (*from, *to))
                })
                .collect()
        }
    }
}

/// O1: this round's bytes, sent at the sender's epoch, decrypted by the peer.
async fn location_round_trip<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &SimWorld<R, T, L>,
    round: &Round<'_>,
) -> Result<Verdict, RigError> {
    let pairs = pairs_of(world, round.reach);
    if pairs.is_empty() {
        return Ok(Verdict::Failed(Finding::NothingProbed));
    }

    let mut index = 0_u32;
    for circle in world.circles() {
        for &(from, to) in &pairs {
            if from == to {
                continue;
            }
            index = index.wrapping_add(1);
            let verdict = probe_once(world, round, circle, from, to, index).await?;
            if verdict != Verdict::Holds {
                return Ok(verdict);
            }
        }
    }
    row_envelope(world, round.row_envelope).await
}

/// One ordered pair, one circle, one freshly minted probe.
async fn probe_once<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &SimWorld<R, T, L>,
    round: &Round<'_>,
    circle: &SimCircle,
    from: DeviceTag,
    to: DeviceTag,
    index: u32,
) -> Result<Verdict, RigError> {
    let probe = ProbeToken::mint(round.ordinal, index);
    // Subscribed BEFORE the send: a broadcast receiver sees only what is sent
    // after it subscribes, and a probe that crossed faster than this line would
    // otherwise read as never delivered.
    let mut deliveries = world.device(to)?.engine()?.bus().subscribe();

    let sender = world.device(from)?;
    let sent = sender
        .manager()?
        .encrypt_location(
            circle.mls_group_id(),
            &sender.keys.public_key(),
            &probe.as_location(),
            LOCATION_MESSAGE_RETENTION_SECS,
        )
        .await;
    let event = match sent {
        Ok((event, _, _)) => event,
        Err(error) => {
            return Ok(Verdict::Failed(Finding::SendRefused {
                device: from,
                circle: circle.tag,
                cause: undecryptable::classify_send(&error),
            }))
        }
    };

    if world
        .publish_witnessed(from, std::slice::from_ref(&event))
        .await?
        .is_none()
    {
        return Ok(Verdict::Failed(Finding::ProbeNotPublished {
            device: from,
            circle: circle.tag,
        }));
    }

    let arrival = await_probe(
        &mut deliveries,
        circle,
        &sender.pubkey_hex(),
        probe,
        bounds::round_trip(round.recovery),
    )
    .await;
    Ok(match arrival {
        Arrival::Decrypted => Verdict::Holds,
        Arrival::Absent => Verdict::Failed(Finding::ProbeNotDelivered {
            from,
            to,
            circle: circle.tag,
        }),
        Arrival::EvidenceLost => Verdict::Failed(Finding::DeliveryEvidenceLost { to }),
    })
}

/// What a bounded wait on one peer's bus saw.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Arrival {
    /// The peer decrypted exactly this round's bytes.
    Decrypted,
    /// The bound elapsed without them.
    Absent,
    /// The receiver fell behind, so the record cannot answer either way.
    EvidenceLost,
}

/// Waits, bounded, for `probe` to arrive on `deliveries` from `sender` in
/// `circle`.
async fn await_probe(
    deliveries: &mut Receiver<LiveSyncEvent>,
    circle: &SimCircle,
    sender_pubkey_hex: &str,
    probe: ProbeToken,
    bound: Duration,
) -> Arrival {
    let started = Instant::now();
    let mut ticker = tokio::time::interval(DELIVERY_POLL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        loop {
            match deliveries.try_recv() {
                Ok(LiveSyncEvent::Location {
                    ref nostr_group_id,
                    ref sender_pubkey,
                    ref content,
                    ..
                }) => {
                    if nostr_group_id.as_slice() == circle.nostr_group_id().as_slice()
                        && sender_pubkey == sender_pubkey_hex
                        && probe.carried_by(content)
                    {
                        return Arrival::Decrypted;
                    }
                }
                Ok(_) => {}
                // The events are GONE. Answering `Absent` here would report a
                // violation the rig's own reader caused.
                Err(TryRecvError::Lagged(_)) => return Arrival::EvidenceLost,
                Err(TryRecvError::Empty | TryRecvError::Closed) => break,
            }
        }
        if started.elapsed() >= bound {
            return Arrival::Absent;
        }
        ticker.tick().await;
    }
}

/// O1's row-cost half: probing must not leave rows piling up.
///
/// # What this measures at the pinned engine, and what it does not
///
/// PLAN §3.5 names `list_messages` row counts. No such accessor exists on the
/// product surface at this pin — the only non-mutating stored-row read is
/// `gating_input_count`, which counts the rows that still GATE a circle's
/// outbound path rather than every row in the store. It is the right ceiling for
/// what the envelope is for (a probing round that leaves the send path more
/// blocked than it found it), and it is emphatically not a measure of total
/// storage.
async fn row_envelope<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &SimWorld<R, T, L>,
    envelope: usize,
) -> Result<Verdict, RigError> {
    for device in world.devices() {
        let session = device.session()?;
        for circle in world.circles() {
            let rows = session
                .gating_input_count(circle.mls_group_id())
                .await
                .map_err(|_| RigError::Core(Step::ReadGatingRows))?;
            if rows > envelope {
                return Ok(Verdict::Failed(Finding::RowEnvelopeExceeded {
                    device: device.tag,
                    circle: circle.tag,
                }));
            }
        }
    }
    Ok(Verdict::Holds)
}

/// O2: agreement first, then a send that really works.
async fn send_path_liveness<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &SimWorld<R, T, L>,
    _round: &Round<'_>,
) -> Result<Verdict, RigError> {
    let online: Vec<&SimDevice> = world
        .devices()
        .iter()
        .filter(|device| !device.offline)
        .collect();
    if online.len() < 2 {
        // A roster comparison over one device is a comparison with itself.
        return Ok(Verdict::Failed(Finding::NothingProbed));
    }

    for circle in world.circles() {
        let verdict = circle_agreement(&online, circle).await?;
        if verdict != Verdict::Holds {
            return Ok(verdict);
        }
    }

    // BEFORE the send attempts, deliberately: an accepted send discharges a
    // removal deferral (`discharge_removal_deferral_after_send`), so grading
    // these afterwards would read a row the oracle itself had just cleared.
    for device in &online {
        let manager = device.manager()?;
        if !manager.owed_removal_commits().is_empty() {
            return Ok(Verdict::Failed(Finding::RemovalOwed { device: device.tag }));
        }
        if !manager.orphaned_removal_deferrals().is_empty() {
            return Ok(Verdict::Failed(Finding::RemovalOrphaned {
                device: device.tag,
            }));
        }
    }

    for device in &online {
        for circle in world.circles() {
            let verdict = send_attempt(device, circle).await?;
            if verdict != Verdict::Holds {
                return Ok(verdict);
            }
        }
    }
    Ok(Verdict::Holds)
}

/// Whether every online device holds the same converged roster and epoch for one
/// circle, with nothing gating or pending.
async fn circle_agreement(online: &[&SimDevice], circle: &SimCircle) -> Result<Verdict, RigError> {
    let group = circle.mls_group_id();
    let mut agreed: Option<(Vec<String>, bool, u64)> = None;
    for device in online {
        let session = device.session()?;
        let roster = session
            .converged_member_pubkeys(group)
            .await
            .map_err(|_| RigError::Core(Step::ReadRoster))?;
        let ConvergedRoster::Converged {
            mut member_pubkeys_hex,
            removed,
        } = roster
        else {
            return Ok(Verdict::Failed(Finding::RosterNotConverged {
                device: device.tag,
                circle: circle.tag,
            }));
        };
        member_pubkeys_hex.sort();
        let epoch = device
            .manager()?
            .group_epoch(group)
            .await
            .map_err(|_| RigError::Core(Step::ReadEpoch))?;

        match &agreed {
            None => agreed = Some((member_pubkeys_hex, removed, epoch)),
            Some((members, was_removed, first_epoch)) => {
                if members != &member_pubkeys_hex || *was_removed != removed {
                    return Ok(Verdict::Failed(Finding::RosterDiverged {
                        circle: circle.tag,
                    }));
                }
                if *first_epoch != epoch {
                    return Ok(Verdict::Failed(Finding::EpochDiverged {
                        circle: circle.tag,
                    }));
                }
            }
        }

        if session
            .gating_input_count(group)
            .await
            .map_err(|_| RigError::Core(Step::ReadGatingRows))?
            != 0
        {
            return Ok(Verdict::Failed(Finding::ConvergenceGated {
                device: device.tag,
                circle: circle.tag,
            }));
        }
        if session
            .has_pending_proposal(group)
            .await
            .map_err(|_| RigError::Core(Step::ReadGatingRows))?
        {
            return Ok(Verdict::Failed(Finding::ProposalUncommitted {
                device: device.tag,
                circle: circle.tag,
            }));
        }
    }
    Ok(Verdict::Holds)
}

/// One send that must really encrypt.
///
/// The event is minted and dropped: an application message advances no epoch and
/// stages no commit, so the only thing this costs is the encryption itself —
/// and the only thing it proves, which no read accessor can, is that the engine
/// would accept one.
async fn send_attempt(device: &SimDevice, circle: &SimCircle) -> Result<Verdict, RigError> {
    // Distinct from every O1 probe: a scenario reading its peers' buses must
    // never mistake a liveness attempt for a round's own probe.
    let attempt = ProbeToken::mint(PROBE_SPAN - 1, PROBE_SPAN - 1);
    match device
        .manager()?
        .encrypt_location(
            circle.mls_group_id(),
            &device.keys.public_key(),
            &attempt.as_location(),
            LOCATION_MESSAGE_RETENTION_SECS,
        )
        .await
    {
        Ok(_) => Ok(Verdict::Holds),
        Err(error) => Ok(Verdict::Failed(Finding::SendRefused {
            device: device.tag,
            circle: circle.tag,
            cause: undecryptable::classify_send(&error),
        })),
    }
}

/// O5: every disposition the round collected has an account.
fn undecryptable_accounted(round: &Round<'_>) -> Verdict {
    let Some(defect) = round.classified.iter().find_map(|verdict| match verdict {
        undecryptable::Verdict::Defect(cause) => Some(*cause),
        _ => None,
    }) else {
        // An empty set is not a clean one: O5 would be reporting that nothing
        // went unaccounted for because nothing was looked at.
        return if round.classified.is_empty() {
            Verdict::Failed(Finding::NothingClassified)
        } else {
            Verdict::Holds
        };
    };
    Verdict::Failed(match defect {
        // The harness did not name the row, so the engine's answer is intact and
        // the READER is the one that came up short.
        undecryptable::Cause::BranchLossUndetermined | undecryptable::Cause::ProbeUnreadable => {
            Finding::UnnamedRow
        }
        undecryptable::Cause::EngineFailure | undecryptable::Cause::OpaqueSendError => {
            Finding::UnaccountedOutcome
        }
    })
}

/// O6: settle to the derived deadline, then confirm the bursts the harness
/// opened.
async fn quiescence_holds<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &mut SimWorld<R, T, L>,
    round: &Round<'_>,
) -> Result<Verdict, RigError> {
    if let quiescence::Settled::TimedOut(reason) =
        quiescence::settle(world, round.recovery, round.tick).await?
    {
        return Ok(Verdict::Failed(Finding::NotQuiescent(reason)));
    }
    // Only here, at the settle-then-check boundary, and only for the devices
    // whose window this phase opened.
    let unsettled = quiescence::confirm_backlog_settled(world, round.burst_opened).await?;
    Ok(unsettled.first().map_or(Verdict::Holds, |&device| {
        Verdict::Failed(Finding::BacklogUnsettled { device })
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_round() -> Round<'static> {
        Round {
            ordinal: 0,
            reach: Reach::EveryOrderedPair,
            recovery: Recovery::Undisturbed,
            tick: Duration::from_millis(10),
            row_envelope: 0,
            burst_opened: &[],
            classified: &[],
        }
    }

    #[test]
    fn the_registry_is_the_four_oracles_this_phase_grades_and_no_placeholders() {
        let ids: Vec<&str> = Invariant::REGISTRY.iter().map(|i| i.id()).collect();
        assert_eq!(ids, ["O1", "O2", "O5", "O6"]);
        // O3 and O4 are absent BY CONSTRUCTION, not merely unimplemented: the
        // enum has no arm for them, so nothing can register one without an
        // implementation the compiler checks.
        assert!(!ids.contains(&"O3"));
        assert!(!ids.contains(&"O4"));
    }

    #[test]
    fn an_invariant_renders_its_id_and_its_promise() {
        assert_eq!(
            Invariant::LocationRoundTrip.to_string(),
            "O1 LOCATION ROUND-TRIP"
        );
        for invariant in Invariant::REGISTRY {
            let rendered = invariant.to_string();
            assert!(rendered.starts_with(invariant.id()), "{rendered}");
            assert!(rendered.ends_with(invariant.title()), "{rendered}");
        }
    }

    #[test]
    fn a_probe_is_distinct_per_round_and_per_pair_and_round_trips_bit_for_bit() {
        let first = ProbeToken::mint(1, 1);
        assert!(first.carried_by(
            &first
                .as_location()
                .to_string()
                .expect("a location serialises")
        ));
        for other in [ProbeToken::mint(2, 1), ProbeToken::mint(1, 2)] {
            assert!(
                !first.carried_by(
                    &other
                        .as_location()
                        .to_string()
                        .expect("a location serialises")
                ),
                "a probe from another round or another pair must not satisfy this one"
            );
        }
    }

    #[test]
    fn a_probe_renders_neither_of_its_coordinates() {
        let rendered = format!("{:?}", ProbeToken::mint(7, 9));
        assert_eq!(rendered, "ProbeToken(..)");
    }

    #[test]
    fn a_malformed_or_foreign_payload_never_satisfies_a_probe() {
        let probe = ProbeToken::mint(3, 4);
        assert!(!probe.carried_by("not json at all"));
        assert!(!probe.carried_by("{}"));
    }

    #[test]
    fn o5_reads_an_empty_set_as_unusable_rather_than_clean() {
        assert_eq!(
            undecryptable_accounted(&empty_round()),
            Verdict::Failed(Finding::NothingClassified)
        );
        assert_eq!(
            Verdict::Failed(Finding::NothingClassified).rc(),
            Rc::Unusable
        );
    }

    #[test]
    fn o5_separates_an_engine_it_cannot_account_for_from_a_row_the_rig_failed_to_name() {
        let accounted = [
            undecryptable::Verdict::Applied,
            undecryptable::Verdict::PastEpochOrBranchLoss { branch_loss: true },
        ];
        let mut round = empty_round();
        round.classified = &accounted;
        assert_eq!(undecryptable_accounted(&round), Verdict::Holds);

        let unnamed = [undecryptable::Verdict::Defect(
            undecryptable::Cause::BranchLossUndetermined,
        )];
        round.classified = &unnamed;
        assert_eq!(
            undecryptable_accounted(&round),
            Verdict::Failed(Finding::UnnamedRow)
        );
        assert_eq!(
            undecryptable_accounted(&round).rc(),
            Rc::RigBroken,
            "a row the harness did not name says nothing about the subject"
        );

        let unaccounted = [undecryptable::Verdict::Defect(
            undecryptable::Cause::EngineFailure,
        )];
        round.classified = &unaccounted;
        assert_eq!(
            undecryptable_accounted(&round),
            Verdict::Failed(Finding::UnaccountedOutcome)
        );
        assert_eq!(
            undecryptable_accounted(&round).rc(),
            Rc::ViolationOrLeak,
            "an ingest outcome nothing can account for is a finding about the subject"
        );
    }

    #[test]
    fn every_finding_renders_handles_and_classifications_and_no_values() {
        let findings = [
            Finding::ProbeNotPublished {
                device: DeviceTag::new(0),
                circle: CircleTag::new(1),
            },
            Finding::ProbeNotDelivered {
                from: DeviceTag::new(0),
                to: DeviceTag::new(1),
                circle: CircleTag::new(2),
            },
            Finding::DeliveryEvidenceLost {
                to: DeviceTag::new(3),
            },
            Finding::RowEnvelopeExceeded {
                device: DeviceTag::new(0),
                circle: CircleTag::new(0),
            },
            Finding::NothingProbed,
            Finding::RosterNotConverged {
                device: DeviceTag::new(1),
                circle: CircleTag::new(0),
            },
            Finding::RosterDiverged {
                circle: CircleTag::new(0),
            },
            Finding::EpochDiverged {
                circle: CircleTag::new(0),
            },
            Finding::ConvergenceGated {
                device: DeviceTag::new(0),
                circle: CircleTag::new(0),
            },
            Finding::ProposalUncommitted {
                device: DeviceTag::new(0),
                circle: CircleTag::new(0),
            },
            Finding::RemovalOwed {
                device: DeviceTag::new(0),
            },
            Finding::RemovalOrphaned {
                device: DeviceTag::new(0),
            },
            Finding::SendRefused {
                device: DeviceTag::new(0),
                circle: CircleTag::new(0),
                cause: undecryptable::Verdict::SendDeferred,
            },
            Finding::UnaccountedOutcome,
            Finding::UnnamedRow,
            Finding::NothingClassified,
            Finding::NotQuiescent(PendingReason::StagedCommit),
            Finding::BacklogUnsettled {
                device: DeviceTag::new(0),
            },
            Finding::FloorUnmet(FloorTerm::FaultsApplied),
        ];
        for finding in findings {
            let rendered = Verdict::Failed(finding).to_string();
            assert!(!rendered.is_empty());
            assert!(!rendered.contains("ws://"), "{rendered}");
            assert!(!rendered.contains("npub"), "{rendered}");
            // A handle is the only identifier shape allowed through, and it is
            // always the rig's own vocabulary.
            for production in ["circle#", "peer#", "event#", "relay#"] {
                assert!(
                    !rendered.contains(&format!(" {production}")),
                    "{rendered} borrows production's handle vocabulary"
                );
            }
        }
        assert_eq!(Verdict::Holds.to_string(), "holds");
        assert_eq!(Verdict::Holds.rc(), Rc::Clean);
    }
}
