//! The timeline: what a run did, in the only vocabulary it is allowed to use.
//!
//! One NDJSON line per record, written as the run goes, so a run that is killed
//! by its own deadline still has everything up to the moment it died. Nothing
//! here is a log in the `log` sense — the rig emits no `log` records of its own
//! — and that is deliberate: the log sink's evidence is the SUBJECT's output,
//! and this file is the HARNESS's, so a reader never has to work out which one
//! wrote a line.
//!
//! # Every field carries a privacy class
//!
//! `tag` (a rig handle), `delta` (a count from the world's origin), `duration`
//! (a measured span), `bucket` (a magnitude) and `literal` (a string constant
//! from this crate). There is no sixth class, and a field that is none of them
//! does not belong in a record — a field named `epoch` would pass a name
//! allowlist and still be an identifier. `tooling/soak/tests/timeline_fields.rs`
//! walks every
//! rendered line, classifies every leaf by its PATH, and fails on one it cannot
//! classify, which is why [`TimelineLine`] keeps its fields as a flat map rather
//! than as a typed struct per variant: a field added upstream lands in that map
//! and reds the test, where a typed reader would simply ignore it.
//!
//! # The extension is `.log`, and the content is NDJSON
//!
//! `check_wire_proxy_test_only.sh` bans `.ndjson` in an upload step. The file is
//! `soak-timeline-<seed>.log` locally and whatever `--timeline-out` names in a
//! lane, and its banner, markers and first-violation snapshot are written beside
//! it in the same directory.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use serde::Deserialize;

use crate::nemesis::types::{Schedule, ScheduledOp};
use crate::rc::{Verdicts, LEAK_MARKER, VIOLATION_MARKER};
use crate::rig::{TimelineRecord, TimelineSink};

/// How many records the first-violation snapshot carries.
///
/// Enough to hold the whole of a scenario arm's run at the tick rates every
/// profile declares, and bounded so a snapshot cannot become the timeline
/// again.
pub const SNAPSHOT_RECORDS: usize = 200;

/// The timeline's own file name for a local run.
#[must_use]
pub fn default_path(dir: &Path, seed: u64) -> PathBuf {
    dir.join(format!("soak-timeline-{seed:016x}.log"))
}

/// The directory a run writes its banner, its markers and its first-violation
/// snapshot into: the one holding `--timeline-out`.
///
/// One directory, because the lane uploads a tree rather than a list of files
/// and reads the markers' PRESENCE out of it. A banner somewhere else is a
/// banner nobody reads, and a marker somewhere else is a containment branch
/// that never fires.
#[must_use]
pub fn artifact_dir(timeline_out: &Path) -> PathBuf {
    timeline_out
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .map_or_else(|| PathBuf::from("."), Path::to_path_buf)
}

/// The first-violation snapshot's file name.
#[must_use]
pub fn snapshot_path(dir: &Path, seed: u64) -> PathBuf {
    dir.join(format!("soak-violation-{seed:016x}.log"))
}

/// Where a run's records go.
///
/// Cheap to clone: the world takes one and the run loop keeps another, and both
/// write to the same file.
#[derive(Clone)]
pub struct Timeline {
    records: Arc<Mutex<Vec<TimelineRecord>>>,
    file: Option<Arc<Mutex<BufWriter<File>>>>,
}

impl Default for Timeline {
    fn default() -> Self {
        Self::in_memory()
    }
}

impl Timeline {
    /// A timeline that keeps its records and writes no file.
    #[must_use]
    pub fn in_memory() -> Self {
        Self {
            records: Arc::new(Mutex::new(Vec::new())),
            file: None,
        }
    }

    /// A timeline that also appends NDJSON to `path`.
    ///
    /// Appends rather than truncates: a run that seals twice in one job must not
    /// silently lose the first half, and the run id in the banner beside it is
    /// what tells two halves apart.
    ///
    /// # Errors
    ///
    /// The `io::Error` from creating the directory or opening the file.
    pub fn to_path(path: &Path) -> std::io::Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let file = OpenOptions::new().create(true).append(true).open(path)?;
        Ok(Self {
            records: Arc::new(Mutex::new(Vec::new())),
            file: Some(Arc::new(Mutex::new(BufWriter::new(file)))),
        })
    }

    /// Every record so far, in order.
    #[must_use]
    pub fn records(&self) -> Vec<TimelineRecord> {
        lock(&self.records).clone()
    }

    /// How many records have been written.
    #[must_use]
    pub fn len(&self) -> usize {
        lock(&self.records).len()
    }

    /// Whether nothing has been recorded.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Flushes the file, if there is one.
    ///
    /// # Errors
    ///
    /// The `io::Error` from the flush.
    pub fn flush(&self) -> std::io::Result<()> {
        self.file.as_ref().map_or(Ok(()), |file| lock(file).flush())
    }

    /// Writes the materialised schedule beside the timeline.
    ///
    /// The schedule is a value the whole run is reproducible from, so it is
    /// written once, before the first tick, as its own file — a run that dies in
    /// its first tick still says what it was going to do. The digest is NOT in
    /// it: the schedule serialises its 8-hex TAG, because 64 hex characters is
    /// the shape of a pubkey, an event id and an MLS group id, and this file is
    /// scanned as one of the run's own sinks.
    ///
    /// `.log`, like the timeline, and for a harder reason than symmetry: every
    /// scan in the chain — the rig's own, `run-soak-core.sh`'s sink spec, the
    /// lane's gate, `check_logscan_wired_everywhere.sh` rule (b) — selects the
    /// files it reads by that extension. A `.json` here would be the one
    /// uploaded file nothing scanned, and widening the glob instead would pull
    /// every NDJSON scan report into the tree that may not carry one.
    ///
    /// # Errors
    ///
    /// The `io::Error` from writing, or a serialisation failure.
    pub fn write_schedule(&self, dir: &Path, schedule: &Schedule) -> std::io::Result<PathBuf> {
        std::fs::create_dir_all(dir)?;
        let path = dir.join("schedule.log");
        let json = serde_json::to_string_pretty(schedule)
            .map_err(|e| std::io::Error::other(e.to_string()))?;
        std::fs::write(&path, json)?;
        Ok(path)
    }

    /// Writes the first-violation snapshot and returns its path.
    ///
    /// # Errors
    ///
    /// The `io::Error` from writing.
    pub fn write_snapshot(
        &self,
        dir: &Path,
        seed: u64,
        snapshot: &Snapshot,
    ) -> std::io::Result<PathBuf> {
        std::fs::create_dir_all(dir)?;
        let path = snapshot_path(dir, seed);
        let mut out = String::new();
        out.push_str(&snapshot.render());
        // The lock is released before the write: a snapshot is written while a
        // run is failing, and holding the records' lock across a filesystem
        // call would stall every other record behind it.
        let tail = {
            let records = lock(&self.records);
            let from = records.len().saturating_sub(SNAPSHOT_RECORDS);
            records[from..].to_vec()
        };
        for record in &tail {
            match serde_json::to_string(record) {
                Ok(line) => {
                    out.push_str(&line);
                    out.push('\n');
                }
                // A record that will not serialise is noted as absent rather
                // than dropped: a snapshot with a silent hole in it is worse
                // than one that says where the hole is.
                Err(_) => out.push_str("{\"record\":\"unserialisable\"}\n"),
            }
        }
        std::fs::write(&path, out)?;
        Ok(path)
    }
}

impl TimelineSink for Timeline {
    fn record(&self, record: TimelineRecord) {
        if let Some(file) = &self.file {
            // A record that cannot be rendered is not written: every field in
            // every record is a handle, a bucket, a delta, a duration or a
            // literal, so a failure here is a bug in this crate rather than
            // something to report about the run.
            if let Ok(line) = serde_json::to_string(&record) {
                let mut handle = lock(file);
                let _ = writeln!(handle, "{line}");
                let _ = handle.flush();
            }
        }
        lock(&self.records).push(record);
    }
}

// Presence and a bucket. The records themselves are value-free, but a `Debug`
// that rendered all of them would put the whole run in one line of somebody's
// terminal.
impl std::fmt::Debug for Timeline {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Timeline")
            .field("records", &crate::rig::sim_magnitude(self.len()))
            .field("to_file", &self.file.is_some())
            .finish()
    }
}

/// What the first-violation snapshot says, above the records.
///
/// Every field is a classification, a handle, a bucket or a duration — the
/// snapshot is uploaded, and Rule 15 applies to it exactly as it applies to the
/// product's own diagnostics.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    /// Which scenario was running.
    pub scenario: &'static str,
    /// Which arm.
    pub arm: &'static str,
    /// The invariant that broke, by id and title.
    pub violated: String,
    /// The finding, as the oracle rendered it: a classification plus the rig's
    /// own handles.
    pub finding: String,
    /// The bound the arm was entitled to take.
    pub bound_secs: u64,
    /// What it actually took.
    pub observed_secs: u64,
    /// The scheduled ops that had fired and not yet healed.
    pub active: Vec<ScheduledOp>,
    /// Per-device state, pre-rendered by the caller from the rig's own bucketed
    /// `Debug`.
    pub devices: Vec<String>,
    /// Per-relay state, the same way.
    pub relays: Vec<String>,
    /// The scan report's own lines: class, encoding and `sink:line`, never a
    /// value.
    pub scan: Vec<String>,
}

impl Snapshot {
    /// The snapshot's header, above the records.
    #[must_use]
    pub fn render(&self) -> String {
        let mut out = format!(
            "haven-soak first violation\n  scenario={} arm={}\n  violated={}\n  finding={}\n  expected within {}s, observed {}s\n",
            self.scenario, self.arm, self.violated, self.finding, self.bound_secs, self.observed_secs
        );
        for op in &self.active {
            let _ = writeln!(
                out,
                "  active op={} tick={} heal_at={}",
                op.op.label(),
                op.tick,
                op.heal_at
                    .map_or_else(|| "-".to_owned(), |tick| tick.to_string())
            );
        }
        for device in &self.devices {
            let _ = writeln!(out, "  device {device}");
        }
        for relay in &self.relays {
            let _ = writeln!(out, "  relay {relay}");
        }
        for line in &self.scan {
            let _ = writeln!(out, "  scan {line}");
        }
        out
    }
}

/// Writes the markers a run's two verdicts owe into `dir`.
///
/// The lane branches on the FILES, not on the exit code: rc 1 means either a
/// leak or a violation, and those two want opposite things done with the
/// evidence — one deleted, the other preserved and read. Each marker's body is
/// one harness-authored sentence with nothing interpolated into it.
///
/// # Errors
///
/// The `io::Error` from writing.
pub fn write_markers(dir: &Path, verdicts: Verdicts) -> std::io::Result<Vec<PathBuf>> {
    std::fs::create_dir_all(dir)?;
    let mut written = Vec::new();
    for marker in verdicts.markers() {
        let body = if marker == LEAK_MARKER {
            "a capture carried a declared identifier; every capture is to be deleted on the runner before any upload\n"
        } else {
            "an invariant broke; the first-violation snapshot beside this marker is the evidence\n"
        };
        let path = dir.join(marker);
        std::fs::write(&path, body)?;
        written.push(path);
    }
    debug_assert!(
        written.len() <= 2,
        "the taxonomy has exactly two rc-1 evidence contracts"
    );
    let _ = VIOLATION_MARKER;
    Ok(written)
}

/// One timeline line, re-read.
///
/// The fields stay a flat map on purpose: a typed reader would ignore a field
/// nobody classified, and the whole point of the field-class test is that it
/// cannot.
#[derive(Debug, Clone, Deserialize)]
pub struct TimelineLine {
    /// Which kind of record this is — the internal tag.
    pub record: String,
    /// Every other field, by name.
    #[serde(flatten)]
    pub fields: BTreeMap<String, serde_json::Value>,
}

/// Parses NDJSON back into lines.
///
/// # Errors
///
/// The line NUMBER that would not parse, and nothing else: a serde message
/// quotes its input, and the input here is a run's own diagnostic.
pub fn read_lines(text: &str) -> Result<Vec<TimelineLine>, String> {
    let mut lines = Vec::new();
    for (index, raw) in text.lines().enumerate() {
        if raw.trim().is_empty() {
            continue;
        }
        let parsed: TimelineLine = serde_json::from_str(raw)
            .map_err(|_| format!("timeline line {} is not a record", index + 1))?;
        lines.push(parsed);
    }
    Ok(lines)
}

/// Poison-tolerant lock: a panicking scenario must not turn every later record
/// into a second panic that hides the first.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::{default_path, read_lines, snapshot_path, write_markers, Snapshot, Timeline};
    use crate::nemesis::types::{Fault, Op, Schedule, ScheduledOp};
    use crate::rc::{Rc, Verdicts, LEAK_MARKER, VIOLATION_MARKER};
    use crate::rig::{DeviceTag, KillKind, RelayTag, TimelineRecord, TimelineSink};

    fn records() -> Vec<TimelineRecord> {
        vec![
            TimelineRecord::Scheduled {
                tick: 4,
                op: Op::Fault {
                    relay: RelayTag::new(0),
                    fault: Fault::Down,
                },
                heal_at_tick: Some(9),
            },
            TimelineRecord::Restarted {
                tick: 12,
                device: DeviceTag::new(1),
                kind: KillKind::Hard,
                release_ms: 40,
                reopen_ms: 90,
            },
        ]
    }

    #[test]
    fn a_written_timeline_reads_back_as_the_records_it_was_given() {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = default_path(dir.path(), 0x5eed);
        let timeline = Timeline::to_path(&path).expect("timeline opens");
        for record in records() {
            timeline.record(record);
        }
        timeline.flush().expect("flush");

        let text = std::fs::read_to_string(&path).expect("read back");
        let lines = read_lines(&text).expect("parse");
        assert!(lines.len() == 2, "{text}");
        assert!(lines[0].record == "scheduled", "{text}");
        assert!(lines[1].record == "restarted", "{text}");
        assert!(
            lines[1].fields["device"] == serde_json::json!("simdev#1"),
            "{text}"
        );
        assert!(timeline.records().len() == 2);
    }

    #[test]
    fn the_artifact_directory_is_the_one_holding_the_timeline() {
        // The lane passes `--timeline-out <upload tree>/soak-timeline.log` and
        // reads the markers out of that tree, so every other artifact the run
        // writes has to land beside it.
        let dir = super::artifact_dir(std::path::Path::new("/tmp/up/soak-timeline.log"));
        assert!(dir == std::path::Path::new("/tmp/up"));
        let bare = super::artifact_dir(std::path::Path::new("soak-timeline.log"));
        assert!(bare == std::path::Path::new("."));
    }

    #[test]
    fn the_file_name_carries_the_seed_and_no_other_identifier() {
        let dir = std::path::Path::new("/tmp/soak-fixture");
        let timeline = default_path(dir, 42);
        let snapshot = snapshot_path(dir, 42);
        assert!(timeline.ends_with("soak-timeline-000000000000002a.log"));
        assert!(snapshot.ends_with("soak-violation-000000000000002a.log"));
        // The extension is what an upload step is allowed to carry: `.ndjson`
        // is banned outright.
        assert!(timeline.extension().and_then(std::ffi::OsStr::to_str) == Some("log"));
    }

    #[test]
    fn an_in_memory_timeline_keeps_records_and_writes_nothing() {
        let timeline = Timeline::in_memory();
        assert!(timeline.is_empty());
        timeline.record(records()[0].clone());
        assert!(timeline.len() == 1);
        assert!(format!("{timeline:?}").contains("records: \"1\""));
    }

    #[test]
    fn the_schedule_is_written_beside_the_timeline_with_its_tag_and_not_its_digest() {
        let dir = tempfile::tempdir().expect("temp dir");
        let schedule = Schedule::new(vec![ScheduledOp {
            tick: 1,
            op: Op::Probe,
            heal_at: None,
        }]);
        let timeline = Timeline::in_memory();
        let path = timeline
            .write_schedule(dir.path(), &schedule)
            .expect("schedule written");
        let text = std::fs::read_to_string(&path).expect("read back");
        assert!(text.contains(&schedule.tag()), "{text}");
        assert!(!text.contains(&hex::encode(schedule.digest())), "{text}");
        assert!(
            path.extension().and_then(std::ffi::OsStr::to_str) == Some("log"),
            "every scan in the chain selects by this extension; another one would upload a \
             file nothing scanned"
        );
    }

    #[test]
    fn a_snapshot_carries_the_bound_beside_the_measurement_and_the_last_records() {
        let dir = tempfile::tempdir().expect("temp dir");
        let timeline = Timeline::in_memory();
        for record in records() {
            timeline.record(record);
        }
        let snapshot = Snapshot {
            scenario: "S01",
            arm: "single-relay-outage",
            violated: "O1 LOCATION ROUND-TRIP".to_owned(),
            finding: "probe not delivered from simdev#0 to simdev#1 in simcircle#0".to_owned(),
            bound_secs: 145,
            observed_secs: 190,
            active: vec![ScheduledOp {
                tick: 4,
                op: Op::Fault {
                    relay: RelayTag::new(0),
                    fault: Fault::Down,
                },
                heal_at: Some(9),
            }],
            devices: vec!["simdev#0 offline=false deliveries=2-4".to_owned()],
            relays: vec!["simrelay#0 accepting=false".to_owned()],
            scan: vec!["soak:12 class=pubkey encoding=hex-lower rule=-".to_owned()],
        };
        let path = timeline
            .write_snapshot(dir.path(), 7, &snapshot)
            .expect("snapshot written");
        let text = std::fs::read_to_string(&path).expect("read back");
        assert!(
            text.contains("expected within 145s, observed 190s"),
            "{text}"
        );
        assert!(text.contains("simrelay#0"), "{text}");
        assert!(text.contains("\"record\":\"restarted\""), "{text}");
        assert!(text.contains("active op=down tick=4 heal_at=9"), "{text}");
    }

    #[test]
    fn a_snapshot_keeps_only_the_last_records_it_declares() {
        let timeline = Timeline::in_memory();
        for tick in 0..(super::SNAPSHOT_RECORDS as u64 + 50) {
            timeline.record(TimelineRecord::Applied {
                tick,
                op: Op::Probe,
            });
        }
        let dir = tempfile::tempdir().expect("temp dir");
        let snapshot = Snapshot {
            scenario: "S06",
            arm: "stuck-row-sweep",
            violated: "O6 QUIESCENCE".to_owned(),
            finding: "the world kept moving".to_owned(),
            bound_secs: 13,
            observed_secs: 30,
            active: Vec::new(),
            devices: Vec::new(),
            relays: Vec::new(),
            scan: Vec::new(),
        };
        let path = timeline
            .write_snapshot(dir.path(), 1, &snapshot)
            .expect("snapshot written");
        let text = std::fs::read_to_string(&path).expect("read back");
        let records = text.matches("\"record\":\"applied\"").count();
        assert!(
            records == super::SNAPSHOT_RECORDS,
            "a snapshot must not become the timeline again"
        );
        assert!(!text.contains("\"tick\":0,"), "{text}");
    }

    #[test]
    fn the_two_rc_one_verdicts_write_two_different_markers() {
        let dir = tempfile::tempdir().expect("temp dir");
        let mut verdicts = Verdicts::new();
        assert!(write_markers(dir.path(), verdicts)
            .expect("no markers")
            .is_empty());

        verdicts.fold_scan(Rc::ViolationOrLeak);
        let written = write_markers(dir.path(), verdicts).expect("leak marker");
        assert!(written.len() == 1);
        assert!(dir.path().join(LEAK_MARKER).exists());
        assert!(!dir.path().join(VIOLATION_MARKER).exists());

        verdicts.fold_invariant(Rc::ViolationOrLeak);
        write_markers(dir.path(), verdicts).expect("both markers");
        assert!(dir.path().join(VIOLATION_MARKER).exists());
        let body = std::fs::read_to_string(dir.path().join(VIOLATION_MARKER)).expect("read");
        assert!(body.contains("snapshot"), "{body}");
    }

    #[test]
    fn a_line_that_is_not_a_record_names_its_position_and_nothing_else() {
        let refused = read_lines("{\"nope\":1}\n").expect_err("refused");
        assert!(refused.contains("line 1"), "{refused}");
        assert!(!refused.contains("nope"), "{refused}");
        assert!(read_lines("\n\n").expect("blank lines").is_empty());
    }
}
