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

use serde::{Serialize, Serializer};
use sha2::{Digest, Sha256};

use crate::rig::{DeviceTag, KillKind, RelayTag};

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

/// One thing that can be wrong with a relay.
///
/// Exactly what the Phase-1 scenarios need and nothing speculative: a fault
/// nobody schedules is a mechanism nobody tests.
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
    /// Stored-event pages are delivered newest-first.
    ReversePages,
    /// `EOSE` is sent naming a different subscription.
    EoseForAnotherSubscription,
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
            Self::Heal => 9,
        };
        buf.push(code);
        match self {
            Self::Closed(prefix) => buf.push(prefix.code()),
            Self::Notice(text) => {
                buf.extend_from_slice(&(text.len() as u64).to_be_bytes());
                buf.extend_from_slice(text.as_bytes());
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
            Self::Fault { fault, .. } => fault.label(),
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
    fn labels_are_literals_from_this_file() {
        assert_eq!(Fault::Closed(ClosedPrefix::Blocked).label(), "closed");
        assert_eq!(Fault::Notice("held for the harness").label(), "notice");
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
