//! The three environment planes, as traits.
//!
//! A world is generic over them for one reason: the rig must compile, and be
//! testable, without the relay, timeline and sink implementations. That is not
//! a speculative abstraction — it is the seam between the parts of this crate,
//! and the in-crate doubles behind it are what let the rig's own behaviour be
//! asserted without an oracle, a scenario or a scanner in the picture.
//!
//! Everything crossing these traits is value-free: a handle, a bucket, a delta,
//! a duration or a literal from this crate.

use std::fmt;
use std::future::Future;

use nostr::EventId;
use std::time::Duration;

use serde::Serialize;

use crate::nemesis::types::{Fault, Op};
use crate::rig::{DeviceTag, KillKind, RelayTag, RigError, WorldId};

/// A relay the world can break.
///
/// The implementation owns a real relay; the rig only ever asks it for its
/// address, tells it what is wrong with it, and reads its ledger.
pub trait RelayPlane: Send + Sync {
    /// This plane's handle.
    fn tag(&self) -> RelayTag;

    /// The `ws://` loopback address devices dial. Never rendered.
    fn url(&self) -> &str;

    /// Applies `fault`, or heals with [`Fault::Heal`].
    ///
    /// # Errors
    ///
    /// [`RigError::Core`] with [`crate::rig::Step::ApplyFault`] if the plane
    /// could not reach the state the fault names — a fault that silently did
    /// not fire would make every bound derived from it a fiction.
    fn apply(&mut self, fault: Fault) -> impl Future<Output = Result<(), RigError>> + Send;

    /// How many bind attempts the last `Up`/`Heal` needed and how long it
    /// waited, once a plane has come back up. `None` for a plane that never
    /// rebinds (a test double), so the world records nothing for it.
    fn last_rebind(&self) -> Option<(u32, Duration)> {
        None
    }

    /// How many faults this plane really took, heals aside.
    ///
    /// Required, with no default: this is the OBSERVATION half of an arm's
    /// expectation floor, and the arm's own declaration is the other half. A
    /// plane that answered a borrowed default would be answering with the
    /// arm's own number, which is what having two sources is for.
    fn faults_applied(&self) -> usize;

    /// Whether this plane's **client-facing** frame stream carried
    /// `["OK", <id>, true, …]`.
    ///
    /// This is the Rule-13 evidence, and the client-facing qualifier is the
    /// whole of it: under a swallowed-`OK` fault the relay stores the event and
    /// the acknowledgement never reaches the client, so "the relay has it" is
    /// emphatically NOT an ack. A rig that confirmed on storage rather than on
    /// acknowledgement would merge an unpublished commit.
    fn witnessed_ok(&self, event_id: &EventId) -> bool;
}

/// Where the rig's own diagnostic records go.
pub trait TimelineSink: Send + Sync {
    /// Records one entry. Infallible by contract: a timeline that can refuse a
    /// record would lose the one record explaining why a run failed.
    fn record(&self, record: TimelineRecord);
}

/// Where the process's captured log lines come from.
pub trait LogDrain: Send + Sync {
    /// Every line captured since sequence `from`, in capture order.
    fn drain_since(&self, from: u64) -> Vec<CapturedLine>;
}

/// One diagnostic record.
///
/// Every field carries a privacy class, and the classes are the whole
/// vocabulary: `tag` (a rig handle), `delta` (a count from the world's
/// origin), `duration` (a measured span), `bucket` (a magnitude) and `literal`
/// (a string constant from this crate). A field that is none of those does not
/// belong in a record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "record", rename_all = "kebab-case")]
pub enum TimelineRecord {
    /// One materialised schedule entry, written before the first tick so a run
    /// that dies early still says what it was going to do.
    Scheduled {
        /// delta — the tick the op fires on.
        tick: u64,
        /// literal + tag — the op itself.
        op: Op,
        /// delta — the tick it heals on, if it is not permanent.
        heal_at_tick: Option<u64>,
    },
    /// A scheduled op the world applied.
    Applied {
        /// delta.
        tick: u64,
        /// literal + tag.
        op: Op,
    },
    /// A fault the world healed.
    Healed {
        /// delta.
        tick: u64,
        /// literal + tag.
        op: Op,
    },
    /// A device restart, with the latencies that ARE the Rule-14 measurement.
    Restarted {
        /// delta.
        tick: u64,
        /// tag.
        device: DeviceTag,
        /// literal.
        kind: KillKind,
        /// duration — how long the session took to be released.
        release_ms: u64,
        /// duration — how long it took to come back.
        reopen_ms: u64,
    },
    /// A Rule-13 publish and how it resolved.
    Published {
        /// delta.
        tick: u64,
        /// tag.
        device: DeviceTag,
        /// literal — whether the staged state was confirmed or rolled back.
        outcome: &'static str,
        /// duration — how long the ack took to be witnessed, and ABSENT when
        /// none ever was. A rolled-back publish has no witness latency to
        /// report, and recording the bound it waited as though it were a
        /// measurement would put a constant where the reader reads a
        /// measurement.
        #[serde(skip_serializing_if = "Option::is_none")]
        witness_ms: Option<u64>,
        /// bucket — how many events were published.
        events: &'static str,
    },
    /// A relay endpoint that came back after `Up`/`Heal`, with the rebind
    /// cost — the measurement that shows a same-port rebind is a bounded retry
    /// and never an `EADDRINUSE` race.
    Rebound {
        /// delta.
        tick: u64,
        /// tag.
        relay: RelayTag,
        /// bucket — bind attempts before the listener was back.
        attempts: &'static str,
        /// duration — how long the rebind waited.
        wait_ms: u64,
    },
}

/// One captured log line.
///
/// The text is whatever the subject logged, so this type never renders it: the
/// scanner reads the field, a human reads the scan report.
#[derive(Clone, PartialEq, Eq)]
pub struct CapturedLine {
    /// Capture order, from one monotonic counter per process.
    pub seq: u64,
    /// Which world produced it. `cargo test` runs worlds concurrently, so
    /// without this a scenario's evidence would hold another scenario's lines.
    pub world: WorldId,
    /// The line's level. The release surface is `Warn` and above.
    pub level: log::Level,
    /// The emitting target (a module path).
    pub target: String,
    /// The rendered message. Never printed by this crate.
    pub text: String,
}

// Presence-only: the text is the subject's, and the whole point of capturing it
// is that nobody knows yet whether it holds something it should not.
impl fmt::Debug for CapturedLine {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CapturedLine")
            .field("seq", &self.seq)
            .field("world", &self.world)
            .field("level", &self.level)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nemesis::types::{DeviceOp, Fault as F};

    #[test]
    fn a_captured_lines_debug_never_renders_what_was_captured() {
        let line = CapturedLine {
            seq: 4,
            world: WorldId::new(1),
            level: log::Level::Warn,
            target: "haven_core::relay".to_string(),
            text: "npub1needleneedleneedle wss://needle.example".to_string(),
        };
        let rendered = format!("{line:?}");
        assert!(rendered.contains("CapturedLine"), "{rendered}");
        assert!(rendered.contains("simworld#1"), "{rendered}");
        assert!(!rendered.contains("npub1"), "{rendered}");
        assert!(!rendered.contains("needle"), "{rendered}");
        assert!(!rendered.contains("wss://"), "{rendered}");
    }

    #[test]
    fn a_record_serialises_as_handles_deltas_and_literals() {
        let record = TimelineRecord::Restarted {
            tick: 12,
            device: DeviceTag::new(2),
            kind: KillKind::Hard,
            release_ms: 40,
            reopen_ms: 90,
        };
        let json = serde_json::to_string(&record).expect("record serialises");
        assert!(json.contains("\"simdev#2\""), "{json}");
        assert!(json.contains("restarted"), "{json}");
        assert!(json.contains("\"hard\""), "{json}");
    }

    #[test]
    fn an_applied_record_carries_the_ops_own_vocabulary() {
        let record = TimelineRecord::Applied {
            tick: 3,
            op: Op::Device {
                device: DeviceTag::new(0),
                op: DeviceOp::GoOffline,
            },
        };
        let json = serde_json::to_string(&record).expect("record serialises");
        assert!(json.contains("go-offline"), "{json}");

        let rendered = format!(
            "{:?}",
            TimelineRecord::Healed {
                tick: 9,
                op: Op::Fault {
                    relay: RelayTag::new(0),
                    fault: F::Heal,
                },
            }
        );
        assert!(rendered.contains("simrelay#0"), "{rendered}");
        assert!(!rendered.contains("127.0.0.1"), "{rendered}");
    }
}
