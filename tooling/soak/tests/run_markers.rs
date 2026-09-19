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
use haven_soak::driver::{self, RunPlan};
use haven_soak::nemesis::types::{Fault, Op, Schedule, ScheduledOp};
use haven_soak::profiles::{ProfileName, ProfileSpec, WorldShape};
use haven_soak::rc::{Rc, LEAK_MARKER, VIOLATION_MARKER};
use haven_soak::rig::RelayTag;
use haven_soak::timeline;

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
}
