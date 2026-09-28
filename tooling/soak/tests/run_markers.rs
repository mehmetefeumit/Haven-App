//! The rc-1 evidence contract, end to end.
//!
//! rc 1 means either a leak or a violation, and the two want opposite things
//! done with the evidence: one deleted on the runner, the other preserved and
//! read. The lane therefore branches on the MARKER FILES rather than on the
//! exit code — so what has to be true is not "the fold is right" (the rc module
//! tests that) but "a real run with a real defect in it leaves the right files
//! behind", which only a real run can say.
//!
//! The defect is planted in the SCHEDULE, which is why [`RunPlan`] carries one
//! rather than a seed: no test-only branch exists anywhere in the driver, and
//! this run reaches the product exactly as a lane's does.

use std::path::Path;

use haven_soak::banner::Provenance;
use haven_soak::coverage::COVERAGE_FILE;
use haven_soak::driver::{self, RunPlan};
use haven_soak::nemesis::types::{Fault, Op, Schedule, ScheduledOp};
use haven_soak::profiles::{ProfileName, ProfileSpec, WorldShape};
use haven_soak::rc::{Rc, LEAK_MARKER, VIOLATION_MARKER};
use haven_soak::rig::RelayTag;
use haven_soak::timeline;
use haven_soak::verdict::{is_handle, VERDICT_FILE, VERDICT_KEYS};

/// The seed these runs record. Nothing is minted from it — the schedule is
/// given — but the banner and the snapshot file are named after it.
const SEED: u64 = 0;

/// Two devices, one circle, one relay: the smallest world in which a probe can
/// cross from one peer to another, which is all either run needs.
const fn shape() -> WorldShape {
    WorldShape {
        members: 2,
        circles: 1,
        relays: 1,
    }
}

/// A plan over `dir`, running `schedule` and no scenario arm.
///
/// No arm on purpose: the arms are graded by their own tests, and what this
/// file is about is what a run LEAVES BEHIND when an oracle goes red.
fn plan(dir: &Path, schedule: Schedule) -> RunPlan {
    let mut spec = ProfileSpec::embedded(ProfileName::Pr).expect("the pr profile parses");
    spec.world = shape();
    RunPlan {
        spec,
        seed: SEED,
        schedule,
        timeline_out: dir.join("soak-timeline.log"),
        needle_manifest: None,
        stop_at_step: None,
        // A glob no scenario id matches: this run is the schedule alone.
        scenario_filter: Some("S00".to_owned()),
        provenance: Provenance::new(None, None),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_violated_invariant_leaves_its_marker_and_its_snapshot() {
    let tree = tempfile::TempDir::new().expect("a temp tree");
    let dir = tree.path();

    // The plant: the relay stores the probe and its acknowledgement never
    // reaches the publisher. Rule 13's own shape — and O1 refuses to wait for a
    // delivery of something no relay said it had.
    let schedule = Schedule::new(vec![
        ScheduledOp {
            tick: 1,
            op: Op::Fault {
                relay: RelayTag::new(0),
                fault: Fault::SwallowOk,
            },
            heal_at: Some(3),
        },
        ScheduledOp {
            tick: 2,
            op: Op::Probe,
            heal_at: None,
        },
    ]);

    let rc = driver::run(&plan(dir, schedule)).await;

    assert!(
        rc == Rc::ViolationOrLeak,
        "a probe no relay acknowledged is a finding about the subject"
    );
    assert!(
        dir.join(VIOLATION_MARKER).is_file(),
        "the lane preserves and uploads the snapshot when it sees this file"
    );
    assert!(
        !dir.join(LEAK_MARKER).exists(),
        "nothing leaked, and a containment branch that fired here would delete the evidence \
         of a real defect"
    );
    assert!(
        timeline::snapshot_path(dir, SEED).is_file(),
        "the first violation is snapshotted wherever it happens, including before any arm ran"
    );
    assert!(
        dir.join("banner.log").is_file(),
        "and the banner is on record whatever the verdict"
    );

    // The machine-readable half of the same evidence, which is what the filing
    // job reads: a run that reddened and left no verdict is indistinguishable
    // from a job that never started.
    let verdict = read_verdict(dir);
    let fields = verdict.as_object().expect("a verdict is one object");
    for key in fields.keys() {
        assert!(
            VERDICT_KEYS.contains(&key.as_str()),
            "a key outside the allowlist would reach a public issue body"
        );
    }
    assert!(
        verdict["rc"] == serde_json::json!(Rc::ViolationOrLeak.code()),
        "the verdict's rc is the run's own"
    );
    assert!(
        verdict["scenario"] == serde_json::json!("nemesis")
            && verdict["arm"] == serde_json::json!("schedule"),
        "a violation the background schedule produced names the phase, not an arm"
    );
    assert!(
        verdict["invariant"]
            .as_str()
            .is_some_and(|id| id.starts_with("INV-")),
        "the invariant is namespaced, as the filing job validates it"
    );
    assert!(
        verdict["finding_class"]
            .as_str()
            .is_some_and(|class| !class.is_empty()),
        "and the classification is the field a watcher groups by"
    );
    assert!(
        verdict["handles"]
            .as_array()
            .expect("a handle list")
            .iter()
            .all(|handle| handle.as_str().is_some_and(is_handle)),
        "every handle is one the rig minted"
    );

    // Coverage is read from what the PLANE took: the swallowed ack fired at
    // tick 1 and O1 graded it at the tick-2 probe. The teardown round grades
    // O1, O2 and O6 at the schedule's last tick (the heal, tick 3) under its
    // OWN literal: filed under the probe literal, it would make every night's
    // knee the schedule's length. The heal is not a fault, so no triple names
    // it. The whole array, so a stray or a missing triple fails as surely as a
    // wrong first one.
    let swallowed = Fault::SwallowOk.label();
    assert!(
        read_coverage(dir)["triples"]
            == serde_json::json!([
                {"scenario": "nemesis", "nemesis": swallowed, "invariant": "INV-O1", "first_tick": 2},
                {"scenario": "settled", "nemesis": swallowed, "invariant": "INV-O1", "first_tick": 3},
                {"scenario": "settled", "nemesis": swallowed, "invariant": "INV-O2", "first_tick": 3},
                {"scenario": "settled", "nemesis": swallowed, "invariant": "INV-O6", "first_tick": 3},
            ]),
        "one probe triple at the probe that followed the fault, and the teardown round's three \
         under their own literal"
    );
}

/// The coverage record the run left, parsed.
fn read_coverage(dir: &Path) -> serde_json::Value {
    let text = std::fs::read_to_string(dir.join(COVERAGE_FILE)).expect("a run leaves coverage");
    serde_json::from_str(&text).expect("the coverage record is JSON")
}

/// The verdict the run left, parsed.
fn read_verdict(dir: &Path) -> serde_json::Value {
    let text = std::fs::read_to_string(dir.join(VERDICT_FILE)).expect("a run leaves a verdict");
    serde_json::from_str(&text).expect("the verdict is JSON")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_clean_run_leaves_neither_marker() {
    let tree = tempfile::TempDir::new().expect("a temp tree");
    let dir = tree.path();

    let rc = driver::run(&plan(dir, Schedule::new(Vec::new()))).await;

    assert!(
        rc == Rc::Clean,
        "a world with nothing wrong with it folds to clean, or every red run above is noise"
    );
    assert!(
        !dir.join(VIOLATION_MARKER).exists(),
        "a marker on a clean run would send the lane looking for a defect that is not there"
    );
    assert!(!dir.join(LEAK_MARKER).exists(), "and nothing leaked");
    assert!(
        !timeline::snapshot_path(dir, SEED).exists(),
        "a snapshot with no violation behind it is evidence of nothing"
    );
    assert!(
        dir.join("soak-timeline.log").is_file(),
        "the timeline is written either way"
    );

    let verdict = read_verdict(dir);
    let fields = verdict.as_object().expect("a verdict is one object");
    assert!(
        verdict["rc"] == serde_json::json!(Rc::Clean.code())
            && verdict["rc_name"] == serde_json::json!(Rc::Clean.name()),
        "a clean run says so in the file a job reads, not only in its exit code"
    );
    for absent in ["scenario", "arm", "invariant", "finding_class", "handles"] {
        assert!(
            !fields.contains_key(absent),
            "a clean run has no violation to describe, and a half-filled one would be filed"
        );
    }
    assert!(
        read_coverage(dir)["triples"] == serde_json::json!([]),
        "a world that took no fault reached no triple, and a clean run still says so"
    );
}
