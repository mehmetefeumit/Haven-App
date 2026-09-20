//! The LANE's capture — the rig's own stdout — and the control that makes its
//! scan mean anything.
//!
//! The rig proves each SCENARIO capture reached the sink by planting a token
//! through the installed `log` backend. The lane reads a different tree: the
//! banner, the materialised schedule, the timeline and the rig's redirected
//! stdout, scanned together as one `soak` sink before anything is uploaded. For
//! as long as nothing in that tree carried a plant, the class's
//! `required_shape_plants` could not be satisfied by a healthy run at all — the
//! scan's verdict was "positive control missed" whatever the rig had done, which
//! is rc 3 on every green lane and the shape in which a control gets deleted
//! instead of fixed. The control stays; the stream it certifies is opened and
//! closed with a plant of its own.
//!
//! # Why this drives the BINARY
//!
//! The promise is about what the binary writes on its stdout and in what order.
//! A library call that returned a token would prove the token can be minted; it
//! could not tell a first line from a last one, and "first" is what makes the
//! control survive the reaper.
//!
//! # Why the manifest is sealed here rather than taken from the run
//!
//! `--needle-manifest` is the one path the rig writes its declarations to, and
//! `haven-logscan` refuses any path outside the upload-banned needle directory.
//! CI passes it because the lane has a reader and a discard for it; a local run
//! — this test included — seals in memory and leaves nothing behind (owner
//! decision Q5). What that costs is the search for the values THIS run minted,
//! and it costs the promise under test nothing: the sink spec, the line floors
//! and `required_shape_plants` come from the policy, which is the half of the
//! manifest this file is about.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use haven_logscan::manifest::Manifest;
use haven_logscan::plants::shape_regex;
use haven_logscan::rules::RuleSet;
use haven_logscan::scan::{scan_sinks, Outcome, ScanMode, SinkArg};
use haven_logscan::{RC_CLEAN, RC_META, RC_UNUSABLE};
use haven_soak::logsink::{Needles, SINK_CLASS};

/// The smallest world in which a probe can cross from one peer to another, and
/// a glob no scenario id matches: the arms are graded by their own tests, and
/// what this file is about is the STREAM the run writes while it works.
const SMALLEST_RUN: [&str; 8] = [
    "--members",
    "2",
    "--circles",
    "1",
    "--relays",
    "1",
    "--scenario-filter",
    "S00",
];

/// A name no world mints, declared so the seal has something to search for: a
/// manifest with no term refuses to seal, and a scan that looked for nothing
/// could not certify a capture as clean.
const ABSENT_NAME: &str = "Thistledown Quorum";

/// How the scanner opens every missed-control sentence, whichever plant it was.
const MISSED_CONTROL: &str = "positive control missed";

/// Unix seconds, for the rule set's epoch window.
///
/// The real clock, as `logsink` passes: the window is "2020-01-01 to a year
/// out", so nothing about this scan turns on which second it is, and a
/// constant would move the ceiling into the past and silently retire S11.
fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

/// A manifest sealed from one absent value, carrying the policy's own sink
/// specs — the floors and the shape plants the lane's scan applies.
fn sealed() -> Manifest {
    let mut needles = Needles::new().expect("the compiled-in policy loads");
    needles
        .declare_circle_name(ABSENT_NAME)
        .expect("a circle name is a declarable class");
    needles.seal("soak-lane-capture").expect("the seal holds")
}

/// The lane's scan, replayed: one `soak` sink over the files named, with no
/// allowlist at all — strictly more than `run-soak-core.sh` asks for.
fn scan(manifest: &Manifest, paths: Vec<PathBuf>) -> Outcome {
    let rules = RuleSet::new(
        manifest.base64_entropy_bits,
        now_unix(),
        &manifest.exempt_endpoints,
        Vec::new(),
    )
    .expect("the structural rules compile");
    scan_sinks(
        manifest,
        &[SinkArg {
            class: SINK_CLASS.to_owned(),
            paths,
        }],
        &BTreeMap::new(),
        &BTreeMap::new(),
        &rules,
        false,
        ScanMode::Full,
    )
}

/// Every problem the scan reported, as its own value-free sentences.
fn problems(outcome: &Outcome) -> String {
    outcome
        .problems
        .iter()
        .map(|problem| problem.message.clone())
        .collect::<Vec<String>>()
        .join(" | ")
}

/// Every `*.log` in `dir`, which is the sink spec the runner builds from the
/// tree it is about to upload.
fn logs_in(dir: &Path) -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = std::fs::read_dir(dir)
        .expect("the evidence tree is readable")
        .map(|entry| entry.expect("a directory entry").path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "log"))
        .collect();
    paths.sort();
    paths
}

/// Writes `text` as `name` under `dir` and answers with its path.
fn write(dir: &Path, name: &str, text: &str) -> PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, text).expect("a fixture file is writable");
    path
}

/// The emitter and phase of the plant on `line`, if it carries one.
fn plant_on(line: &str) -> Option<(String, String)> {
    let captures = shape_regex().captures(line)?;
    Some((
        captures.get(1)?.as_str().to_owned(),
        captures.get(2)?.as_str().to_owned(),
    ))
}

/// One real run, three questions about the one capture it wrote.
///
/// Three scans rather than three runs: they ask about the same stream, and
/// driving a world three times to ask them would cost three worlds and prove
/// the same thing once.
#[test]
fn the_runs_stdout_opens_and_closes_the_lanes_soak_capture() {
    let tree = tempfile::TempDir::new().expect("a temp tree");
    let dir = tree.path();
    let transcript = dir.join("soak-pr-run.log");

    // Both streams into one file, as `run-soak-core.sh` redirects them: an
    // unredirected rig writes into the job log, which nothing can retract.
    let capture = std::fs::File::create(&transcript).expect("the transcript is writable");
    let status = Command::new(env!("CARGO_BIN_EXE_haven-soak"))
        .args(["--profile", "pr"])
        .args(SMALLEST_RUN)
        .arg("--timeline-out")
        .arg(dir.join("soak-timeline.log"))
        .stdout(capture.try_clone().expect("the capture is shareable"))
        .stderr(capture)
        .status()
        .expect("the rig runs");
    assert!(
        status.success(),
        "the capture this file is about is a healthy run's"
    );

    let text = std::fs::read_to_string(&transcript).expect("the transcript is readable");
    let lines: Vec<&str> = text.lines().collect();
    // Extracted before the assertions, never inside them: the identifier guard
    // reads an invocation's own arguments, and the capture's text is the one
    // thing that may not be an argument to a panic.
    let opening = lines.first().copied().and_then(plant_on);
    let closing = lines.last().copied().and_then(plant_on);
    assert_eq!(
        opening,
        Some(("rust".to_owned(), "open".to_owned())),
        "the opening plant is not the first line the binary wrote, so a run reaped \
         before its first world would leave a capture nothing can certify"
    );
    assert_eq!(
        closing,
        Some(("rust".to_owned(), "close".to_owned())),
        "the closing plant is not the last line, so a truncated stream reads as a whole one"
    );

    let manifest = sealed();

    // 1. The lane's own verdict over the tree it would upload.
    let outcome = scan(&manifest, logs_in(dir));
    assert_eq!(
        outcome.rc(),
        RC_CLEAN,
        "a healthy run's evidence tree must scan clean: {}",
        problems(&outcome)
    );

    // 2. The same tree with the opening plant gone — the state every soak lane
    //    was in before the rig printed one.
    let without: String = lines
        .iter()
        .filter(|line| plant_on(line).is_none_or(|(_, phase)| phase != "open"))
        .fold(String::new(), |mut text, line| {
            text.push_str(line);
            text.push('\n');
            text
        });
    let mutated = tempfile::TempDir::new().expect("a temp tree");
    let mut paths: Vec<PathBuf> = logs_in(dir)
        .into_iter()
        .filter(|path| path != &transcript)
        .collect();
    paths.push(write(mutated.path(), "soak-pr-run.log", &without));
    let outcome = scan(&manifest, paths);
    assert_eq!(
        outcome.rc(),
        RC_UNUSABLE,
        "a `soak` tree with no opening plant proves nothing about which file was read"
    );
    assert!(
        problems(&outcome).contains("`rust` opening plant"),
        "the verdict must name the missed control: {}",
        problems(&outcome)
    );

    // 3. The reaper's case: killed after the plant and before anything else. The
    //    capture proves too little (one line, under the class floor) and says
    //    so — but the control HOLDS, because the plant is written and flushed
    //    before any world is built.
    let reaped = tempfile::TempDir::new().expect("a temp tree");
    let first = format!("{}\n", lines.first().expect("the transcript has a line"));
    let outcome = scan(
        &manifest,
        vec![write(reaped.path(), "soak-pr-run.log", &first)],
    );
    assert_eq!(
        outcome.lines.get(SINK_CLASS),
        Some(&1),
        "the one line has to have been READ, or what follows is a verdict over nothing"
    );
    assert_eq!(
        outcome.rc(),
        RC_META,
        "a capture under its class floor proves too little and says so"
    );
    assert!(
        !problems(&outcome).contains(MISSED_CONTROL),
        "a run reaped before its first world still opened the stream it wrote: {}",
        problems(&outcome)
    );
}

/// A `--stop-at-step` run leaves its capture through the scan, not around it.
///
/// The stop is a debugging exit taken mid-schedule, after the subject has
/// already logged; returning before the scan made it the one way out of a
/// capture that nothing read.
#[test]
fn a_run_stopped_mid_schedule_still_scans_what_it_captured() {
    let tree = tempfile::TempDir::new().expect("a temp tree");
    let dir = tree.path();
    let transcript = dir.join("soak-pr-run.log");
    let capture = std::fs::File::create(&transcript).expect("the transcript is writable");
    let status = Command::new(env!("CARGO_BIN_EXE_haven-soak"))
        .args(["--profile", "pr"])
        .args(SMALLEST_RUN)
        .args(["--stop-at-step", "1"])
        .arg("--timeline-out")
        .arg(dir.join("soak-timeline.log"))
        .stdout(capture.try_clone().expect("the capture is shareable"))
        .stderr(capture)
        .status()
        .expect("the rig runs");
    assert!(status.success(), "a requested stop is a clean exit");

    let text = std::fs::read_to_string(&transcript).expect("the transcript is readable");
    let scanned = text
        .lines()
        .position(|row| row.starts_with("scan nemesis:"));
    let stopped = text
        .lines()
        .position(|row| row.starts_with("stopped at the requested step"));
    assert!(
        stopped.is_some(),
        "the run did not stop where it was asked to"
    );
    assert!(
        scanned.is_some_and(|at| Some(at) < stopped),
        "the stop left the capture before its scan"
    );
}
