//! `coverage.log`: which (scenario, nemesis, invariant) triples a run reached,
//! and the tick each was first reached at.
//!
//! The input to the 30-night duration review (`PLAN_PHASE2` OQ-L): a nightly
//! whose LAST new triple keeps appearing early is a nightly that runs longer
//! than it learns. Written beside `verdict.log`, with the same `.log` extension
//! every scan in the chain selects by, and pinned the same way — by equality,
//! in `tests/coverage_fields.rs`.
//!
//! # What a triple is
//!
//! A graded invariant, under a fault the world had really taken by then:
//! `scenario` is a registry id, or one of the background phase's two literals
//! — [`PROBE_ROUND`] for a probe the schedule asked for, [`SETTLED_ROUND`] for
//! the teardown round after its last tick; `nemesis` a [`Fault::label`] from a
//! plane's ledger or a [`DeviceOp::label`] a device recorded — what was
//! RECORDED taken, never what a schedule or an arm said it would apply — and
//! `invariant` the namespaced id `verdict.log` spells. `first_tick` is a count
//! from the grading world's origin. An arm's world is not ticked by a
//! schedule, so an arm's triples carry that world's tick as it stood (0 unless
//! the arm ticked it).
//!
//! # The knee, and why the teardown round has its own literal
//!
//! The duration knee is the largest `first_tick` among [`PROBE_ROUND`]
//! triples: the first probe after the last new fault label, i.e. when the
//! schedule stopped teaching the run anything. The teardown round is graded
//! at the schedule's last tick every night, so under the probe literal the
//! knee would read the schedule's length back as a constant.
//!
//! # Rule 15
//!
//! Every value is a `&'static str` of this crate, a delta or a repository fact
//! (the profile and the seed). Nothing counts a circle, a member, a relay or
//! an event — the list's length counts triples of the rig's own vocabulary —
//! and nothing is an instant.
//!
//! [`Fault::label`]: crate::nemesis::types::Fault::label
//! [`DeviceOp::label`]: crate::nemesis::types::DeviceOp::label

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::oracle::Invariant;
use crate::profiles::ProfileName;
use crate::verdict::namespaced;

/// The file the run writes beside its verdict.
pub const COVERAGE_FILE: &str = "coverage.log";

/// Every top-level key `coverage.log` carries, pinned by equality.
pub const COVERAGE_KEYS: [&str; 3] = ["triples", "profile", "seed"];

/// Every key one triple carries, pinned by equality.
pub const TRIPLE_KEYS: [&str; 4] = ["scenario", "nemesis", "invariant", "first_tick"];

/// The `scenario` of a triple graded at a probe round the schedule asked for.
pub const PROBE_ROUND: &str = "nemesis";

/// The `scenario` of a triple graded at the background phase's teardown round.
pub const SETTLED_ROUND: &str = "settled";

/// One (scenario, nemesis, invariant) triple, first reached at `first_tick`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Triple {
    /// A registry scenario id, [`PROBE_ROUND`] or [`SETTLED_ROUND`].
    scenario: &'static str,
    /// The fault's or device operation's label, as its ledger recorded it.
    nemesis: &'static str,
    /// The invariant's namespaced id.
    invariant: String,
    /// The grading world's tick: a count from its origin, never an instant.
    first_tick: u64,
}

/// Every triple a run reached, in the order it first reached them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Coverage {
    /// The triples, first-reached first.
    triples: Vec<Triple>,
    /// The profile, as the TOMLs spell it.
    profile: &'static str,
    /// The seed, `0x` and sixteen hex — the banner's own spelling.
    seed: String,
}

impl Coverage {
    /// An empty record for a run of `profile` at `seed`.
    #[must_use]
    pub fn new(profile: ProfileName, seed: u64) -> Self {
        Self {
            triples: Vec::new(),
            profile: profile.as_str(),
            seed: format!("0x{seed:016x}"),
        }
    }

    /// Records `invariant` graded in `scenario` at `tick`, once per fault the
    /// world had taken. A triple already recorded keeps its first tick.
    pub fn note(
        &mut self,
        scenario: &'static str,
        faults: &[&'static str],
        invariant: Invariant,
        tick: u64,
    ) {
        let id = namespaced(invariant);
        for &nemesis in faults {
            let seen = self.triples.iter().any(|triple| {
                triple.scenario == scenario && triple.nemesis == nemesis && triple.invariant == id
            });
            if !seen {
                self.triples.push(Triple {
                    scenario,
                    nemesis,
                    invariant: id.clone(),
                    first_tick: tick,
                });
            }
        }
    }

    /// The triples so far, first-reached first.
    #[must_use]
    pub fn triples(&self) -> &[Triple] {
        &self.triples
    }

    /// Writes the record into `dir` and answers with its path.
    ///
    /// # Errors
    ///
    /// The `io::Error` from serialising, creating the directory or writing.
    /// Its message carries the path, so the caller drops it unrendered.
    pub fn write_to(&self, dir: &Path) -> std::io::Result<PathBuf> {
        let body = serde_json::to_string(self)?;
        std::fs::create_dir_all(dir)?;
        let path = dir.join(COVERAGE_FILE);
        std::fs::write(&path, format!("{body}\n"))?;
        Ok(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_triple_keeps_its_first_tick_and_is_recorded_once_per_fault() {
        let mut coverage = Coverage::new(ProfileName::Nightly, 0x5eed);
        coverage.note("nemesis", &["down", "up"], Invariant::LocationRoundTrip, 3);
        coverage.note("nemesis", &["down"], Invariant::LocationRoundTrip, 9);
        coverage.note("S01", &["down"], Invariant::LocationRoundTrip, 0);
        let json = serde_json::to_value(&coverage).expect("coverage serialises");
        assert_eq!(
            json["triples"],
            serde_json::json!([
                {"scenario": "nemesis", "nemesis": "down", "invariant": "INV-O1", "first_tick": 3},
                {"scenario": "nemesis", "nemesis": "up", "invariant": "INV-O1", "first_tick": 3},
                {"scenario": "S01", "nemesis": "down", "invariant": "INV-O1", "first_tick": 0},
            ])
        );
        assert_eq!(json["seed"], serde_json::json!("0x0000000000005eed"));
    }

    #[test]
    fn a_world_that_took_no_fault_reaches_no_triple() {
        let mut coverage = Coverage::new(ProfileName::Pr, 0);
        coverage.note("S13", &[], Invariant::Quiescence, 0);
        let json = serde_json::to_value(&coverage).expect("coverage serialises");
        assert_eq!(json["triples"], serde_json::json!([]));
    }

    #[test]
    fn the_written_file_is_a_log_holding_one_object() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let path = Coverage::new(ProfileName::Pr, 0)
            .write_to(dir.path())
            .expect("it writes");
        assert!(
            path.extension().and_then(std::ffi::OsStr::to_str) == Some("log"),
            "every scan in the chain selects by this extension; another one would upload a \
             file nothing scanned"
        );
        let text = std::fs::read_to_string(&path).expect("it reads back");
        assert_eq!(text.lines().count(), 1, "one object, one line");
    }
}
