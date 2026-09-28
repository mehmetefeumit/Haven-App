//! The schedule: every fault a run will apply, materialised before the first
//! tick.
//!
//! A schedule is a value, not a stream. It is minted once from the seed, hashed
//! into a digest, written as the timeline's first records, and then only read —
//! which is what makes a run reproducible from `profile + seed` alone and what
//! lets every liveness bound be derived from the faults that will actually fire
//! rather than from the ones that happened to fire.
//!
//! # Every non-permanent fault carries its own heal
//!
//! [`ScheduledOp::heal_at`] is part of the schedule rather than a decision a
//! tick makes, because a bound is only derivable if the moment the world starts
//! recovering is known in advance. A schedule with no heal proves nothing about
//! recovery.

use std::fmt;

use haven_core::nostr::KIND_GROUP_MESSAGE;
use nostr::{Event, Kind, TagKind};
use serde::{Serialize, Serializer};
use sha2::{Digest, Sha256};

use crate::relay::Forgery;
use crate::rig::{sim_magnitude, DeviceTag, KillKind, RelayTag};

/// A NIP-01 machine-readable `CLOSED` / `OK` prefix.
///
/// Mirrors `nostr::MachineReadablePrefix`'s literals rather than depending on
/// the type: these are the bytes a relay puts on the wire, and the rig asserts
/// byte fidelity against them. The in-crate test parses every
/// [`Self::as_str`] back through the nostr parser, so a drift in the upstream
/// vocabulary reds this crate instead of silently changing what a fault means.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ClosedPrefix {
    /// `duplicate:`
    Duplicate,
    /// `pow:`
    Pow,
    /// `blocked:`
    Blocked,
    /// `rate-limited:` — one of the two prefixes the engine treats as a
    /// throttle rather than a drop.
    RateLimited,
    /// `invalid:`
    Invalid,
    /// `error:`
    Error,
    /// `unsupported:`
    Unsupported,
    /// `auth-required:` — the other throttle prefix.
    AuthRequired,
    /// `restricted:`
    Restricted,
}

impl ClosedPrefix {
    /// Every prefix, in NIP-01 order.
    pub const ALL: [Self; 9] = [
        Self::Duplicate,
        Self::Pow,
        Self::Blocked,
        Self::RateLimited,
        Self::Invalid,
        Self::Error,
        Self::Unsupported,
        Self::AuthRequired,
        Self::Restricted,
    ];

    /// The prefix as it appears on the wire, colon included.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Duplicate => "duplicate:",
            Self::Pow => "pow:",
            Self::Blocked => "blocked:",
            Self::RateLimited => "rate-limited:",
            Self::Invalid => "invalid:",
            Self::Error => "error:",
            Self::Unsupported => "unsupported:",
            Self::AuthRequired => "auth-required:",
            Self::Restricted => "restricted:",
        }
    }

    /// The digest discriminant.
    const fn code(self) -> u8 {
        match self {
            Self::Duplicate => 0,
            Self::Pow => 1,
            Self::Blocked => 2,
            Self::RateLimited => 3,
            Self::Invalid => 4,
            Self::Error => 5,
            Self::Unsupported => 6,
            Self::AuthRequired => 7,
            Self::Restricted => 8,
        }
    }
}

/// A frame-size cap, in bytes.
///
/// Its own type for one reason: every rendering of it is BUCKETED. The cap an
/// arm chooses is MEASURED off an event the world minted — the oversize arm
/// takes one byte less than a staged commit's own frame — so an exactly
/// rendered cap is a fingerprint of that world's roster, which Rule 15 keeps
/// out of a record exactly as it keeps out a count.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct ByteCap(usize);

impl ByteCap {
    /// A cap of `bytes`.
    #[must_use]
    pub const fn new(bytes: usize) -> Self {
        Self(bytes)
    }

    /// The cap itself, for the proxy that enforces it.
    #[must_use]
    pub const fn bytes(self) -> usize {
        self.0
    }
}

// Presence only, like `ProbeToken`'s: the magnitude is the world's and the
// bucket vocabulary has no resolution at this scale anyway, so rendering
// anything but "a cap was set" would render the measurement itself.
impl fmt::Debug for ByteCap {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("ByteCap").field(&"..").finish()
    }
}

// The crate's one magnitude vocabulary, for the same reason: a record says a
// cap was in force, never which.
impl Serialize for ByteCap {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(sim_magnitude(self.0))
    }
}

/// A count the rig chose for a page fault: how many events a clamped page
/// keeps, or which `REQ` on a connection is refused.
///
/// Its own type for the reason [`ByteCap`] is: every rendering of it is
/// BUCKETED. An arm sizes it off the backlog its world seeded, so an exactly
/// rendered count is a magnitude of that world.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct RigCount(usize);

impl RigCount {
    /// A count of `n`.
    #[must_use]
    pub const fn new(n: usize) -> Self {
        Self(n)
    }

    /// The count itself, for the proxy that enforces it.
    #[must_use]
    pub const fn get(self) -> usize {
        self.0
    }
}

// Presence only, as `ByteCap`'s is.
impl fmt::Debug for RigCount {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("RigCount").field(&"..").finish()
    }
}

impl Serialize for RigCount {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(sim_magnitude(self.0))
    }
}

/// The class of a server→client `EVENT` frame a plane can withhold.
///
/// The one discriminator the rig owns, used by the proxy that drops a class and
/// by the publish ladder that picks a class's ladder, so the two cannot
/// diverge. It is the wire's own and the product's: the engine stamps a NIP-40
/// `expiration` on kind-445 APPLICATION messages and never on a commit or a
/// proposal (`haven-core/src/nostr/mls/manager.rs`, the `message-retention.v1`
/// component), so the complement of an application 445 is a commit OR a
/// proposal — which is why the class is `Handshake`, not `Commit` — and a
/// welcome is a kind-1059 gift wrap with no expiration at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum DropClass {
    /// A kind-445 application message: a location.
    Application,
    /// A kind-445 commit or proposal.
    Handshake,
    /// A kind-1059 gift wrap: a welcome.
    GiftWrap,
}

impl DropClass {
    /// The class `event` falls in, or `None` for a frame no class names.
    #[must_use]
    pub fn of(event: &Event) -> Option<Self> {
        if event.kind == Kind::GiftWrap {
            return Some(Self::GiftWrap);
        }
        if event.kind.as_u16() != KIND_GROUP_MESSAGE {
            return None;
        }
        Some(if event.tags.find(TagKind::Expiration).is_some() {
            Self::Application
        } else {
            Self::Handshake
        })
    }

    /// The digest discriminant.
    const fn code(self) -> u8 {
        match self {
            Self::Application => 0,
            Self::Handshake => 1,
            Self::GiftWrap => 2,
        }
    }
}

/// One thing that can be wrong with a relay.
///
/// Exactly what the scenarios need and nothing speculative: a fault nobody
/// schedules and no arm applies is a mechanism nobody tests.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Fault {
    /// The relay stops accepting connections, keeping its store and its port.
    Down,
    /// The relay comes back on the same port with the same store.
    Up,
    /// The relay comes back with an empty store — the "the relay forgot"
    /// shape, which is not the same as an outage.
    WipeStore,
    /// Every `REQ` is closed with this prefix.
    Closed(ClosedPrefix),
    /// A `NOTICE` frame carrying harness-authored text. The text is a literal
    /// from this crate, never anything a peer produced.
    Notice(&'static str),
    /// The relay stores the event and the `OK` never reaches the client — the
    /// shape Rule 13 exists for.
    SwallowOk,
    /// Every event is delivered twice.
    DoubleEveryEvent,
    /// Stored-event pages are delivered in the reverse of the order the
    /// relay serves them: the store serves newest first, so oldest first.
    /// Live events published while it is armed are held until the
    /// subscription's next `EOSE` — do not publish while it is armed.
    ReversePages,
    /// `EOSE` is sent naming a different subscription.
    EoseForAnotherSubscription,
    /// A forged event is written onto the subscriptions it matches, live.
    ///
    /// Live and never stored, which is the honest model of "in flight but not
    /// retained": an injected event is one an adversary put on the wire, so a
    /// later catch-up sweep must not find it sitting in the relay's own pages.
    Inject(Forgery),
    /// An `EVENT` frame above this size is refused with `OK false invalid:`
    /// and never reaches the relay.
    RefuseOversize {
        /// The largest frame payload the plane will forward.
        max_bytes: ByteCap,
    },
    /// Every server→client `EVENT` frame of this class is dropped instead of
    /// written. The relay stores and acknowledges as it always did: the
    /// partition is between the relay and ONE endpoint, which is what makes it
    /// a per-device fault and not an outage.
    DropClass(DropClass),
    /// Every stored-event page is cut to its newest `n` events, the way a
    /// relay whose `max_limit` is `n` clamps a larger `limit`. Live events
    /// after the page's `EOSE` pass untouched. Arm and heal it BETWEEN pages:
    /// a page in flight across the arming or the heal is part forwarded, part
    /// held, and comes out reordered or mis-truncated.
    ClampLimit(RigCount),
    /// The `nth` `REQ` each connection makes after this is armed (counting
    /// from 1) is answered `CLOSED "error: …"` and never reaches the relay.
    RefusePage {
        /// Which `REQ` is refused.
        nth: RigCount,
    },
    /// The next connection each endpoint accepts is dropped before its
    /// handshake; every later one is served.
    ColdFirstConnect,
    /// Everything above is undone.
    Heal,
}

impl Fault {
    /// The label the timeline records. A literal from this file — never a
    /// value, and never anything a relay said.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Down => "down",
            Self::Up => "up",
            Self::WipeStore => "wipe-store",
            Self::Closed(_) => "closed",
            Self::Notice(_) => "notice",
            Self::SwallowOk => "swallow-ok",
            Self::DoubleEveryEvent => "double-every-event",
            Self::ReversePages => "reverse-pages",
            Self::EoseForAnotherSubscription => "eose-for-another-subscription",
            Self::Inject(_) => "inject",
            Self::RefuseOversize { .. } => "refuse-oversize",
            Self::DropClass(_) => "drop-class",
            Self::ClampLimit(_) => "clamp-limit",
            Self::RefusePage { .. } => "refuse-page",
            Self::ColdFirstConnect => "cold-first-connect",
            Self::Heal => "heal",
        }
    }

    fn encode_into(self, buf: &mut Vec<u8>) {
        let code = match self {
            Self::Down => 0,
            Self::Up => 1,
            Self::WipeStore => 2,
            Self::Closed(_) => 3,
            Self::Notice(_) => 4,
            Self::SwallowOk => 5,
            Self::DoubleEveryEvent => 6,
            Self::ReversePages => 7,
            Self::EoseForAnotherSubscription => 8,
            Self::Inject(_) => 9,
            Self::RefuseOversize { .. } => 10,
            Self::Heal => 11,
            Self::DropClass(_) => 12,
            Self::ClampLimit(_) => 13,
            Self::RefusePage { .. } => 14,
            Self::ColdFirstConnect => 15,
        };
        buf.push(code);
        match self {
            Self::Closed(prefix) => buf.push(prefix.code()),
            Self::Notice(text) => {
                buf.extend_from_slice(&(text.len() as u64).to_be_bytes());
                buf.extend_from_slice(text.as_bytes());
            }
            // The RECIPE, never what it is aimed at: a digest is an input this
            // crate holds twice, and a routing id or an event id has no second
            // reason to exist in one. Neither fault is ever scheduled — both
            // are arm-applied — so nothing derives a bound from telling two of
            // them apart.
            Self::Inject(forgery) => buf.push(forgery.code()),
            Self::RefuseOversize { max_bytes } => {
                buf.extend_from_slice(&(max_bytes.bytes() as u64).to_be_bytes());
            }
            Self::DropClass(class) => buf.push(class.code()),
            Self::ClampLimit(n) | Self::RefusePage { nth: n } => {
                buf.extend_from_slice(&(n.get() as u64).to_be_bytes());
            }
            _ => {}
        }
    }
}

/// One thing that can happen to a device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum DeviceOp {
    /// The process dies and comes back on the same store.
    Restart(KillKind),
    /// The engine pauses: it keeps its session but stops receiving.
    GoOffline,
    /// The engine resumes and re-anchors.
    ComeOnline,
    /// The device's policy clock steps forward, so an age-out horizon is
    /// reachable inside a run that lasts minutes. Only ever stepped between
    /// quiescent phases.
    StepPolicyOffset {
        /// Seconds to add to this device's policy offset.
        secs: i64,
    },
}

impl DeviceOp {
    /// The label the timeline records.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Restart(KillKind::Soft) => "restart-soft",
            Self::Restart(KillKind::Hard) => "restart-hard",
            Self::GoOffline => "go-offline",
            Self::ComeOnline => "come-online",
            Self::StepPolicyOffset { .. } => "step-policy-offset",
        }
    }

    fn encode_into(self, buf: &mut Vec<u8>) {
        match self {
            Self::Restart(kind) => {
                buf.push(0);
                buf.push(kind.code());
            }
            Self::GoOffline => buf.push(1),
            Self::ComeOnline => buf.push(2),
            Self::StepPolicyOffset { secs } => {
                buf.push(3);
                buf.extend_from_slice(&secs.to_be_bytes());
            }
        }
    }
}

/// One scheduled action.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Op {
    /// Apply a fault to one relay plane.
    Fault {
        /// Which relay.
        relay: RelayTag,
        /// What happens to it.
        fault: Fault,
    },
    /// Apply a fault to ONE device's endpoint on one relay plane, leaving the
    /// plane's canonical endpoint and every other device's alone.
    DeviceFault {
        /// Which relay.
        relay: RelayTag,
        /// Whose endpoint.
        device: DeviceTag,
        /// What happens to it.
        fault: Fault,
    },
    /// Do something to one device.
    Device {
        /// Which device.
        device: DeviceTag,
        /// What happens to it.
        op: DeviceOp,
    },
    /// Run a liveness probe round. The world surfaces the request; the
    /// scenario performs it, because only the scenario knows which oracle is
    /// being satisfied and with which freshly minted probe token.
    Probe,
}

impl Op {
    /// The label the timeline records.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Fault { fault, .. } | Self::DeviceFault { fault, .. } => fault.label(),
            Self::Device { op, .. } => op.label(),
            Self::Probe => "probe",
        }
    }

    fn encode_into(self, buf: &mut Vec<u8>) {
        match self {
            Self::Fault { relay, fault } => {
                buf.push(0);
                buf.extend_from_slice(&relay.ordinal().to_be_bytes());
                fault.encode_into(buf);
            }
            Self::Device { device, op } => {
                buf.push(1);
                buf.extend_from_slice(&device.ordinal().to_be_bytes());
                op.encode_into(buf);
            }
            Self::Probe => buf.push(2),
            Self::DeviceFault {
                relay,
                device,
                fault,
            } => {
                buf.push(3);
                buf.extend_from_slice(&relay.ordinal().to_be_bytes());
                buf.extend_from_slice(&device.ordinal().to_be_bytes());
                fault.encode_into(buf);
            }
        }
    }
}

/// An [`Op`] with the tick it fires on and the tick it is undone on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct ScheduledOp {
    /// The tick the op fires on — a count from the world's origin, never an
    /// instant.
    pub tick: u64,
    /// What fires.
    pub op: Op,
    /// The tick the fault is healed on, if it is not permanent.
    pub heal_at: Option<u64>,
}

/// Every op a run will apply, plus the digest that identifies the set.
///
/// The digest is computed on construction and the fields are private: a
/// schedule whose digest does not match its ops is a reproduction recipe that
/// lies, which is worse than none.
#[derive(Clone, PartialEq, Eq)]
pub struct Schedule {
    ops: Vec<ScheduledOp>,
    digest: [u8; 32],
}

// The tag, never the digest: a derived `Debug` renders 32 raw bytes, and 64 hex
// characters is the shape a structural rule matches and a reader cannot tell
// from a pubkey. Ops are bucketed for the same reason the `Display` buckets
// them.
impl fmt::Debug for Schedule {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Schedule")
            .field("schedule_tag", &self.tag())
            .field("ops", &crate::rig::sim_magnitude(self.ops.len()))
            // The digest is deliberately absent, not merely unrendered: the tag
            // above IS its safe form.
            .finish_non_exhaustive()
    }
}

impl Schedule {
    /// Digests `ops` and takes ownership of them.
    #[must_use]
    pub fn new(ops: Vec<ScheduledOp>) -> Self {
        let mut buf = Vec::new();
        for scheduled in &ops {
            buf.extend_from_slice(&scheduled.tick.to_be_bytes());
            buf.push(u8::from(scheduled.heal_at.is_some()));
            buf.extend_from_slice(&scheduled.heal_at.unwrap_or(0).to_be_bytes());
            scheduled.op.encode_into(&mut buf);
        }
        let digest: [u8; 32] = Sha256::digest(&buf).into();
        Self { ops, digest }
    }

    /// Every scheduled op, in schedule order.
    #[must_use]
    pub fn ops(&self) -> &[ScheduledOp] {
        &self.ops
    }

    /// The full digest. Never rendered: 64 hex characters is the shape of a
    /// pubkey, an event id and an MLS group id, and a scanner cannot tell them
    /// apart. [`Self::tag`] is what a human ever sees.
    #[must_use]
    pub const fn digest(&self) -> &[u8; 32] {
        &self.digest
    }

    /// The 8-hex tag the banner prints.
    ///
    /// Eight characters, deliberately: the structural rules match 32 hex and
    /// up, and this file is scanned as one of the run's own sinks — a longer
    /// tag would red the run's own scan.
    #[must_use]
    pub fn tag(&self) -> String {
        hex::encode(&self.digest[..4])
    }

    /// The ops firing on `tick`.
    pub fn firing_at(&self, tick: u64) -> impl Iterator<Item = &ScheduledOp> {
        self.ops.iter().filter(move |op| op.tick == tick)
    }

    /// The ops whose heal falls on `tick`.
    pub fn healing_at(&self, tick: u64) -> impl Iterator<Item = &ScheduledOp> {
        self.ops.iter().filter(move |op| op.heal_at == Some(tick))
    }

    /// The last tick anything is scheduled for, healing included.
    #[must_use]
    pub fn last_tick(&self) -> u64 {
        self.ops
            .iter()
            .map(|op| op.heal_at.unwrap_or(op.tick).max(op.tick))
            .max()
            .unwrap_or(0)
    }
}

// Serialises as the timeline and `schedule.log` carry it: the TAG, never the
// digest, plus the ops themselves.
impl Serialize for Schedule {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let mut out = serializer.serialize_struct("Schedule", 2)?;
        out.serialize_field("schedule_tag", &self.tag())?;
        out.serialize_field("ops", &self.ops)?;
        out.end()
    }
}

impl fmt::Display for Schedule {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "schedule {} ops={}",
            self.tag(),
            crate::rig::sim_magnitude(self.ops.len())
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ops() -> Vec<ScheduledOp> {
        vec![
            ScheduledOp {
                tick: 4,
                op: Op::Fault {
                    relay: RelayTag::new(0),
                    fault: Fault::Down,
                },
                heal_at: Some(40),
            },
            ScheduledOp {
                tick: 12,
                op: Op::Device {
                    device: DeviceTag::new(1),
                    op: DeviceOp::Restart(KillKind::Hard),
                },
                heal_at: None,
            },
            ScheduledOp {
                tick: 20,
                op: Op::Probe,
                heal_at: None,
            },
        ]
    }

    #[test]
    fn the_same_ops_digest_the_same_and_a_changed_op_does_not() {
        let a = Schedule::new(ops());
        let b = Schedule::new(ops());
        assert_eq!(a.digest(), b.digest());
        assert_eq!(a.tag(), b.tag());

        let mut moved = ops();
        moved[0].tick += 1;
        assert_ne!(Schedule::new(moved).digest(), a.digest());

        let mut rehealed = ops();
        rehealed[0].heal_at = Some(41);
        assert_ne!(Schedule::new(rehealed).digest(), a.digest());

        let mut retargeted = ops();
        retargeted[1].op = Op::Device {
            device: DeviceTag::new(2),
            op: DeviceOp::Restart(KillKind::Hard),
        };
        assert_ne!(Schedule::new(retargeted).digest(), a.digest());
    }

    #[test]
    fn a_reordered_schedule_is_a_different_schedule() {
        let mut swapped = ops();
        swapped.swap(0, 2);
        assert_ne!(
            Schedule::new(swapped).digest(),
            Schedule::new(ops()).digest()
        );
    }

    #[test]
    fn two_faults_that_differ_only_in_their_closed_prefix_digest_differently() {
        let one = Schedule::new(vec![ScheduledOp {
            tick: 1,
            op: Op::Fault {
                relay: RelayTag::new(0),
                fault: Fault::Closed(ClosedPrefix::RateLimited),
            },
            heal_at: None,
        }]);
        let other = Schedule::new(vec![ScheduledOp {
            tick: 1,
            op: Op::Fault {
                relay: RelayTag::new(0),
                fault: Fault::Closed(ClosedPrefix::AuthRequired),
            },
            heal_at: None,
        }]);
        assert_ne!(one.digest(), other.digest());
    }

    #[test]
    fn two_faults_that_differ_only_in_their_dropped_class_digest_differently() {
        let dropping = |class| {
            Schedule::new(vec![ScheduledOp {
                tick: 1,
                op: Op::Fault {
                    relay: RelayTag::new(0),
                    fault: Fault::DropClass(class),
                },
                heal_at: None,
            }])
        };
        assert_ne!(
            dropping(DropClass::Application).digest(),
            dropping(DropClass::Handshake).digest()
        );
        assert_ne!(
            dropping(DropClass::Handshake).digest(),
            dropping(DropClass::GiftWrap).digest()
        );
        // The same class aimed at a device's endpoint is a different op from
        // the same class aimed at the plane, and two devices are two ops.
        let aimed = |device| {
            Schedule::new(vec![ScheduledOp {
                tick: 1,
                op: Op::DeviceFault {
                    relay: RelayTag::new(0),
                    device: DeviceTag::new(device),
                    fault: Fault::DropClass(DropClass::Application),
                },
                heal_at: None,
            }])
        };
        assert_ne!(aimed(0).digest(), dropping(DropClass::Application).digest());
        assert_ne!(aimed(0).digest(), aimed(1).digest());
        assert_eq!(
            Op::DeviceFault {
                relay: RelayTag::new(0),
                device: DeviceTag::new(1),
                fault: Fault::DropClass(DropClass::GiftWrap),
            }
            .label(),
            "drop-class"
        );
    }

    #[test]
    fn a_frames_class_is_read_off_the_wire_and_names_the_products_own_discriminator() {
        use nostr::{EventBuilder, Keys, Tag, Timestamp};

        let keys = Keys::generate();
        let application = EventBuilder::new(Kind::Custom(KIND_GROUP_MESSAGE), "x")
            .tag(Tag::expiration(Timestamp::from(
                Timestamp::now().as_secs() + 228,
            )))
            .sign_with_keys(&keys)
            .expect("signs");
        let handshake = EventBuilder::new(Kind::Custom(KIND_GROUP_MESSAGE), "x")
            .sign_with_keys(&keys)
            .expect("signs");
        let welcome = EventBuilder::new(Kind::GiftWrap, "x")
            .sign_with_keys(&keys)
            .expect("signs");
        let note = EventBuilder::text_note("x")
            .tag(Tag::expiration(Timestamp::from(
                Timestamp::now().as_secs() + 228,
            )))
            .sign_with_keys(&keys)
            .expect("signs");
        assert_eq!(DropClass::of(&application), Some(DropClass::Application));
        assert_eq!(
            DropClass::of(&handshake),
            Some(DropClass::Handshake),
            "a 445 with no expiration is a commit or a proposal: group history outlives any TTL"
        );
        assert_eq!(DropClass::of(&welcome), Some(DropClass::GiftWrap));
        assert_eq!(
            DropClass::of(&note),
            None,
            "an expiration on a kind no class names does not make it an application message"
        );
    }

    #[test]
    fn the_tag_is_short_enough_that_the_structural_rules_cannot_match_it() {
        let tag = Schedule::new(ops()).tag();
        assert_eq!(tag.len(), 8);
        assert!(tag.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn firing_and_healing_select_the_right_ops() {
        let schedule = Schedule::new(ops());
        assert_eq!(schedule.firing_at(4).count(), 1);
        assert_eq!(schedule.firing_at(5).count(), 0);
        assert_eq!(schedule.healing_at(40).count(), 1);
        assert_eq!(schedule.healing_at(4).count(), 0);
        assert_eq!(schedule.last_tick(), 40);
        assert_eq!(Schedule::new(Vec::new()).last_tick(), 0);
    }

    #[test]
    fn every_closed_prefix_is_the_one_the_nostr_parser_reads_back() {
        use nostr::message::MachineReadablePrefix;

        for prefix in ClosedPrefix::ALL {
            let message = format!("{} something happened", prefix.as_str());
            let parsed: Option<MachineReadablePrefix> = MachineReadablePrefix::parse(&message);
            assert!(
                parsed.is_some(),
                "the upstream parser no longer knows {}",
                prefix.as_str()
            );
            assert_eq!(
                parsed.map(|p| p.as_str().to_string()),
                Some(prefix.as_str().trim_end_matches(':').to_string())
            );
        }
    }

    #[test]
    fn the_forged_ok_false_is_a_prefix_the_nostr_parser_reads_back_too() {
        use nostr::message::MachineReadablePrefix;

        // The `CLOSED` side is pinned above; this is the OK side, which the rig
        // forges for the first time with `RefuseOversize`. A client branches on
        // the prefix, so a refusal the upstream parser no longer recognises is
        // a fault that no longer means what the arm applying it thinks.
        let message = crate::relay::oversize_message();
        let parsed: Option<MachineReadablePrefix> = MachineReadablePrefix::parse(&message);
        assert_eq!(
            parsed.map(|prefix| prefix.as_str().to_string()),
            Some(
                crate::relay::OVERSIZE_PREFIX
                    .as_str()
                    .trim_end_matches(':')
                    .to_string()
            )
        );
    }

    #[test]
    fn the_serialised_schedule_carries_the_tag_and_not_the_digest() {
        let schedule = Schedule::new(ops());
        let json = serde_json::to_string(&schedule).expect("schedule serialises");
        assert!(json.contains(&schedule.tag()), "{json}");
        assert!(!json.contains(&hex::encode(schedule.digest())), "{json}");
        assert!(json.contains("schedule_tag"), "{json}");
    }

    #[test]
    fn rendering_a_schedule_buckets_its_size_and_names_no_instant() {
        let rendered = Schedule::new(ops()).to_string();
        assert!(rendered.contains("2-4"), "{rendered}");
        assert!(!rendered.contains(" 3"), "{rendered}");
    }

    #[test]
    fn a_forgery_and_a_cap_reach_the_digest_and_neither_reaches_a_rendering() {
        use crate::relay::Forgery;

        let expired = Forgery::Expired {
            group_id: [0x5a; 32],
        };
        let unprocessable = Forgery::Unprocessable {
            group_id: [0x5a; 32],
        };
        let injected = |forgery| {
            Schedule::new(vec![ScheduledOp {
                tick: 1,
                op: Op::Fault {
                    relay: RelayTag::new(0),
                    fault: Fault::Inject(forgery),
                },
                heal_at: None,
            }])
        };
        assert_ne!(
            injected(expired).digest(),
            injected(unprocessable).digest(),
            "two recipes must not digest as one op"
        );

        let capped = |bytes| {
            Schedule::new(vec![ScheduledOp {
                tick: 1,
                op: Op::Fault {
                    relay: RelayTag::new(0),
                    fault: Fault::RefuseOversize {
                        max_bytes: ByteCap::new(bytes),
                    },
                },
                heal_at: None,
            }])
        };
        assert_ne!(
            capped(1024).digest(),
            capped(1025).digest(),
            "two caps must not digest as one op"
        );

        // The rendering side: the recipe's target and the cap's magnitude are
        // both measurements of a world, and neither may reach a record.
        let rendered = format!("{:?}", Fault::Inject(expired));
        assert!(rendered.contains("expired"), "{rendered}");
        assert!(!rendered.contains("5a5a"), "{rendered}");
        let rendered = format!(
            "{:?}",
            Fault::RefuseOversize {
                max_bytes: ByteCap::new(7919),
            }
        );
        assert!(!rendered.contains("7919"), "{rendered}");
        let json = serde_json::to_string(&Fault::RefuseOversize {
            max_bytes: ByteCap::new(7919),
        })
        .expect("a fault serialises");
        assert!(!json.contains("7919"), "{json}");
        assert!(json.contains("5+"), "{json}");
    }

    #[test]
    fn two_page_faults_that_differ_only_in_their_count_digest_differently() {
        let applied = |fault| {
            Schedule::new(vec![ScheduledOp {
                tick: 1,
                op: Op::Fault {
                    relay: RelayTag::new(0),
                    fault,
                },
                heal_at: None,
            }])
        };
        assert_ne!(
            applied(Fault::ClampLimit(RigCount::new(1))).digest(),
            applied(Fault::ClampLimit(RigCount::new(2))).digest(),
            "two clamps must not digest as one op"
        );
        assert_ne!(
            applied(Fault::RefusePage {
                nth: RigCount::new(1)
            })
            .digest(),
            applied(Fault::RefusePage {
                nth: RigCount::new(2)
            })
            .digest(),
            "two refused pages must not digest as one op"
        );
        // The same count under two faults is two recipes.
        assert_ne!(
            applied(Fault::ClampLimit(RigCount::new(1))).digest(),
            applied(Fault::RefusePage {
                nth: RigCount::new(1)
            })
            .digest()
        );
        assert_ne!(
            applied(Fault::ColdFirstConnect).digest(),
            applied(Fault::Heal).digest()
        );

        for fault in [
            Fault::ClampLimit(RigCount::new(7919)),
            Fault::RefusePage {
                nth: RigCount::new(7919),
            },
        ] {
            let rendered = format!("{fault:?}");
            assert!(!rendered.contains("7919"), "{rendered}");
            let json = serde_json::to_string(&fault).expect("a fault serialises");
            assert!(!json.contains("7919"), "{json}");
            assert!(json.contains("5+"), "{json}");
        }
    }

    #[test]
    fn labels_are_literals_from_this_file() {
        assert_eq!(Fault::Closed(ClosedPrefix::Blocked).label(), "closed");
        assert_eq!(Fault::Notice("held for the harness").label(), "notice");
        assert_eq!(Fault::ClampLimit(RigCount::new(2)).label(), "clamp-limit");
        assert_eq!(
            Fault::RefusePage {
                nth: RigCount::new(2)
            }
            .label(),
            "refuse-page"
        );
        assert_eq!(Fault::ColdFirstConnect.label(), "cold-first-connect");
        assert_eq!(
            Op::Device {
                device: DeviceTag::new(0),
                op: DeviceOp::Restart(KillKind::Soft),
            }
            .label(),
            "restart-soft"
        );
        assert_eq!(Op::Probe.label(), "probe");
    }

    #[test]
    fn a_notice_texts_bytes_are_part_of_the_digest() {
        let one = Schedule::new(vec![ScheduledOp {
            tick: 1,
            op: Op::Fault {
                relay: RelayTag::new(0),
                fault: Fault::Notice("one"),
            },
            heal_at: None,
        }]);
        let other = Schedule::new(vec![ScheduledOp {
            tick: 1,
            op: Op::Fault {
                relay: RelayTag::new(0),
                fault: Fault::Notice("two"),
            },
            heal_at: None,
        }]);
        assert_ne!(one.digest(), other.digest());
    }
}
