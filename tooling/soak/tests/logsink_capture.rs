//! The capture, end to end: what reaches it, what may not, and what it proves.
//!
//! # Why this is a test binary of its own
//!
//! The sink is process-wide and stamps every record with whatever world last
//! held the lease. The lease serialises LEASEHOLDERS — it cannot serialise
//! emitters, because a record arrives on whatever task the engine spawned it on
//! and carries nothing but its target. So a world built by a test that never
//! took the lease still logs, and its lines would land in the leaseholder's
//! window under the leaseholder's world id: the first-line/last-line plant
//! discipline below would then depend on which other test happened to be
//! running. `cargo test` gives each integration target its own process, and in
//! this one every world takes the lease before it exists.
//!
//! # ...and why each test also takes [`ORDER`]
//!
//! Two things in this file happen OUTSIDE a lease and would otherwise land in
//! whichever capture was open at the time: a record emitted deliberately with
//! the lease released (that is the point of one test), and the scan's read of
//! the process-wide dropped-record counter (a capture is scanned by the run
//! that holds the lease, but a test that has already released it would read
//! another test's losses). One mutex over each whole test body makes this
//! binary sequential, which is what §3.8 asks of every sink-bearing test.

use std::future::Future as _;
use std::pin::pin;
use std::task::{Context, Waker};
use std::time::Duration;

use haven_soak::logsink::{
    self, Needles, ScanReport, SinkError, SoakLogs, CAPTURE_CAP, SINK_CLASS,
};
use haven_soak::oracle::bounds;
use haven_soak::rc::Rc;
use haven_soak::rig::{LogDrain, WorldId};

/// What a test waits for the lease: the product's own settle window, derived
/// rather than invented. Every body below holds [`ORDER`] first, so the lease
/// is free when it is asked for and this bound is never actually spent.
const fn lease_bound() -> Duration {
    bounds::settle()
}

/// Serialises whole test bodies. Never the lease's substitute — the lease is
/// what the RIG relies on, and `two_worlds_cannot_interleave_in_one_capture`
/// still proves it holds.
static ORDER: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// A needle-shaped value nothing in the tree should ever log.
const NEEDLE_HEX: &str = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";

/// Seals a manifest that searches for [`NEEDLE_HEX`].
fn manifest(run_id: &str) -> haven_logscan::manifest::Manifest {
    let mut needles = Needles::new().expect("the compiled-in policy loads");
    needles
        .declare_pubkey(NEEDLE_HEX)
        .expect("a pubkey declares");
    needles.seal(run_id).expect("the declarations seal")
}

/// Scans `lines` as `capture`.
fn scan(capture: &str, lines: &[haven_soak::rig::CapturedLine]) -> ScanReport {
    logsink::scan_capture(capture, lines, &manifest(capture)).expect("the scan runs")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn only_havens_own_records_are_captured() {
    let _order = ORDER.lock().await;
    let logs = SoakLogs::acquire(lease_bound())
        .await
        .expect("the capture lease");
    let world = WorldId::new(4_242);
    logs.attribute_to(world);
    let from = logs.mark();

    // The exact shape A3 found: the MLS group context, contiguous hex, at
    // debug level, from a dependency.
    log::debug!(target: "openmls::ciphersuite", "kdf_label {NEEDLE_HEX}"); // log-scan-ok: the planted control this test exists to prove is DROPPED — the allowlist refuses the record before the capture, so it reaches neither the buffer nor a file
    log::debug!(target: "nostr_relay_pool::relay", "connecting to ws://127.0.0.1:7777");
    log::warn!(target: "haven_core::relay", "circle#a91f3c settled");

    let captured = logs.drain_since(from);
    assert!(
        captured.iter().all(|line| line.target.starts_with("haven")),
        "a dependency's record reached the capture"
    );
    assert!(
        captured.iter().all(|line| !line.text.contains(NEEDLE_HEX)),
        "the group context OpenMLS renders reached the capture"
    );
    assert!(
        captured
            .iter()
            .any(|line| line.target == "haven_core::relay"),
        "Haven's own record was dropped"
    );
    assert!(
        captured.iter().all(|line| line.world == world),
        "a line was attributed to another world"
    );
    drop(logs);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_record_with_no_world_holding_the_lease_is_not_captured() {
    let _order = ORDER.lock().await;
    let (from, inside) = {
        let logs = SoakLogs::acquire(lease_bound())
            .await
            .expect("the capture lease");
        logs.attribute_to(WorldId::new(1));
        let from = logs.mark();
        log::warn!(target: "haven_core::relay", "inside the lease");
        let inside = logs.drain_since(from);
        drop(logs);
        (from, inside)
    };
    log::warn!(target: "haven_core::relay", "after the lease");

    assert!(
        inside.iter().any(|line| line.text == "inside the lease"),
        "a record inside the lease was lost"
    );
    let logs = SoakLogs::acquire(lease_bound())
        .await
        .expect("the capture lease");
    logs.attribute_to(WorldId::new(2));
    assert!(
        logs.drain_since(from)
            .iter()
            .all(|line| line.text != "after the lease"),
        "a record nobody could attribute became somebody's evidence"
    );
    drop(logs);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_worlds_cannot_interleave_in_one_capture() {
    let _order = ORDER.lock().await;
    let first = SoakLogs::acquire(lease_bound())
        .await
        .expect("the capture lease");
    first.attribute_to(WorldId::new(11));
    let from_first = first.mark();
    log::warn!(target: "haven_core::relay", "the first world's line");

    // A second world may not open a capture while the first holds the lease.
    // Polled rather than timed: the acquire future is driven once by hand with
    // a no-op waker, so the assertion is about the lease's state and not about
    // how long anything took. A broken lease answers Ready here, immediately.
    {
        let mut contending = pin!(SoakLogs::acquire(lease_bound()));
        let mut context = Context::from_waker(Waker::noop());
        assert!(
            contending.as_mut().poll(&mut context).is_pending(),
            "a second capture opened while the first held the lease; the sink stamps every \
             record with whatever world attributed LAST, so the two worlds' lines would fold \
             into one window"
        );
    }

    let first_lines = first.drain_since(from_first);
    assert!(
        first_lines
            .iter()
            .all(|line| line.world == WorldId::new(11)),
        "the first world's capture carries another world's line"
    );
    assert!(
        first_lines
            .iter()
            .any(|line| line.text == "the first world's line"),
        "the first world's own line is missing from its capture"
    );
    let last_of_first = first_lines.last().map(|line| line.seq).expect("a line");
    drop(first);

    let second = SoakLogs::acquire(lease_bound())
        .await
        .expect("the capture lease");
    second.attribute_to(WorldId::new(12));
    let from_second = second.mark();
    log::warn!(target: "haven_core::relay", "the second world's line");
    let second_lines = second.drain_since(from_second);

    assert!(
        from_second > last_of_first,
        "the second world's window opened before the first world's last line, so the two \
         overlap"
    );
    assert!(
        second_lines
            .iter()
            .all(|line| line.world == WorldId::new(12)),
        "the second world's capture carries the first world's lines"
    );
    assert!(
        second_lines
            .iter()
            .all(|line| line.text != "the first world's line"),
        "the first world's line reached the second world's evidence"
    );
    drop(second);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_lease_that_never_comes_is_a_verdict_and_never_a_hang() {
    let _order = ORDER.lock().await;
    {
        let _held = SoakLogs::acquire(lease_bound())
            .await
            .expect("the capture lease");

        // Zero, because the lease is definitively held: the question is what
        // the caller is TOLD, not how long it is prepared to wait, and a bound
        // spent waiting here would be a sleep. A run that leaked a handle or
        // opened a second capture takes this branch with its own derived
        // deadline instead, and reports rc 2 rather than waiting for a reaper
        // to kill it with an anonymous timeout.
        // `.err()` on the spot: an `Ok` here would be a second live lease, and
        // holding one while asserting is the very thing under test.
        let refused = SoakLogs::acquire(Duration::ZERO).await.err();
        assert!(
            refused == Some(SinkError::LeaseUnavailable),
            "a second capture must be refused with a verdict, not awaited for ever"
        );
        assert!(
            SinkError::LeaseUnavailable.rc() == Rc::RigBroken,
            "the rig holding its own lease is the rig being broken, never a finding about the \
             subject"
        );
    }

    // …and the lease really was only held, not poisoned: the next caller gets
    // it, which is what makes the refusal above a bound rather than a break.
    let next = SoakLogs::acquire(lease_bound())
        .await
        .expect("the capture lease");
    drop(next);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_clean_capture_carries_its_plants_scans_clean_and_leaves_nothing_on_disk() {
    let _order = ORDER.lock().await;
    let logs = SoakLogs::acquire(lease_bound())
        .await
        .expect("the capture lease");
    logs.attribute_to(WorldId::new(77));
    let from = logs.mark();

    let opened = logsink::plant("open").expect("mint an opening plant");
    log::info!(target: "haven_core::relay", "circle#a91f3c reached epoch +1");
    let closed = logsink::plant("close").expect("mint a closing plant");

    // The lease is held across the scan, as a run holds it: the report carries
    // what the sink lost during THIS capture, and a released lease would let it
    // carry somebody else's losses.
    let lines = logs.drain_since(from);
    assert!(
        lines.first().is_some_and(|line| line.text == opened),
        "the opening plant is not the capture's first line"
    );
    assert!(
        lines.last().is_some_and(|line| line.text == closed),
        "the closing plant is not the capture's last line"
    );

    let report = scan("logsink-clean", &lines);
    drop(logs);
    let verdict = report.rc.name();
    assert!(
        report.rc == Rc::Clean,
        "a capture of Haven's own alias-only lines must scan clean, and this one read {verdict}"
    );
    assert!(
        !report.contained,
        "nothing was contained on a clean capture"
    );
    assert!(
        !logsink::evidence_exists("logsink-clean"),
        "a clean run left the subject's own lines on disk with nothing that needs them"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_planted_identifier_is_a_leak_and_the_evidence_is_deleted() {
    let _order = ORDER.lock().await;
    let logs = SoakLogs::acquire(lease_bound())
        .await
        .expect("the capture lease");
    logs.attribute_to(WorldId::new(78));
    let from = logs.mark();
    let _ = logsink::plant("open").expect("mint an opening plant");
    // The positive control: a declared value, logged by a target the rig
    // keeps. If the scan misses this, every green scan above proves nothing.
    log::warn!(target: "haven_core::relay", "peer {NEEDLE_HEX} joined"); // log-scan-ok: the planted control the scan must FIND; a capture the scanner cannot redden proves nothing
    let _ = logsink::plant("close").expect("mint a closing plant");

    let lines = logs.drain_since(from);
    let report = scan("logsink-leak", &lines);

    assert!(
        report.rc == Rc::ViolationOrLeak,
        "a declared value in a captured line must be rc 1"
    );
    assert!(report.contained, "the evidence was not deleted");
    assert!(
        !logsink::evidence_exists("logsink-leak"),
        "the evidence file survived containment"
    );
    assert!(
        report
            .findings
            .iter()
            .all(|line| !line.contains(NEEDLE_HEX)),
        "the report repeated the value it found"
    );
    assert!(
        report.findings.iter().any(|line| line.contains("class=")),
        "a finding named no class"
    );
    drop(logs);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_finding_names_the_capture_and_never_a_path_or_a_count() {
    let _order = ORDER.lock().await;
    let logs = SoakLogs::acquire(lease_bound())
        .await
        .expect("the capture lease");
    // This test is about how a finding RENDERS, not about the sink path, so
    // the line is constructed rather than emitted; the sink's own controls are
    // the tests above.
    let lines = [haven_soak::rig::CapturedLine {
        seq: 1,
        world: WorldId::new(80),
        level: log::Level::Warn,
        target: "haven_core::relay".to_owned(),
        text: format!("peer {NEEDLE_HEX} joined"),
    }];
    let report = scan("logsink-rendering", &lines);
    drop(logs);

    assert!(
        !report.findings.is_empty(),
        "the planted value produced no finding, so this proves nothing about how one renders"
    );
    for finding in &report.findings {
        assert!(
            finding.starts_with("logsink-rendering:"),
            "a finding must name the CAPTURE, which is the only name a reader can act on"
        );
        assert!(
            !finding.contains('/'),
            "a finding carried a path; the evidence directory is minted per process and its \
             name is nobody's business"
        );
        assert!(
            !finding.contains("haven-soak"),
            "a finding carried the evidence tree's own name"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_capture_below_the_line_floor_proves_too_little() {
    let _order = ORDER.lock().await;
    let logs = SoakLogs::acquire(lease_bound())
        .await
        .expect("the capture lease");
    logs.attribute_to(WorldId::new(79));
    let sealed = manifest("logsink-empty");
    let report = logsink::scan_capture("logsink-empty", &[], &sealed).expect("the scan runs");
    assert!(
        report.rc != Rc::Clean,
        "an empty capture must never read as clean"
    );
    assert!(
        sealed.floor(SINK_CLASS) >= 2,
        "the floor is the two plants a complete capture holds"
    );
    drop(logs);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_drained_window_stops_costing_memory() {
    let _order = ORDER.lock().await;
    let logs = SoakLogs::acquire(lease_bound())
        .await
        .expect("the capture lease");
    logs.attribute_to(WorldId::new(81));
    log::warn!(target: "haven_core::relay", "the first window");
    let second = logs.mark();
    log::warn!(target: "haven_core::relay", "the second window");

    assert!(
        logs.drain_since(second).len() == 1,
        "a window answers with its own lines"
    );
    let everything = logs.drain_since(0);
    assert!(
        everything
            .iter()
            .all(|line| line.text != "the first window"),
        "a window that was already drained is still held; a run holds one window, not a whole \
         transcript"
    );
    assert!(
        everything
            .iter()
            .any(|line| line.text == "the second window"),
        "the live window was dropped along with the consumed one"
    );
    drop(logs);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_window_past_its_cap_is_truncated_loudly_and_never_reads_as_clean() {
    let _order = ORDER.lock().await;
    let logs = SoakLogs::acquire(lease_bound())
        .await
        .expect("the capture lease");
    logs.attribute_to(WorldId::new(82));
    let from = logs.mark();
    assert!(logs.dropped() == 0, "a fresh lease starts with no losses");

    // Eight past the cap: enough that the sink must refuse some, few enough
    // that the count is the mechanism rather than the machine.
    for _ in 0..(CAPTURE_CAP + 8) {
        log::warn!(target: "haven_core::relay", "a line the window may not hold");
    }

    // Kept plus refused is everything emitted, and kept is under the cap. Said
    // that way rather than as one equality, because the buffer may hold an
    // earlier test's live window when this lease opens: the cap is a bound on
    // the BUFFER, and what this test owns is the accounting.
    let kept = logs.drain_since(from).len();
    let refused = usize::try_from(logs.dropped()).expect("a count this machine can hold");
    assert!(
        kept <= CAPTURE_CAP,
        "the buffer grew past the cap it declares"
    );
    assert!(
        kept + refused == CAPTURE_CAP + 8,
        "records went missing between the emitter and the two counters, so a drop could be \
         silent after all"
    );
    assert!(
        refused >= 8,
        "the sink refused records and counted none of them"
    );

    // The promise: a truncated capture never reads as clean, whatever its own
    // lines scanned as. Draining at the boundary first releases the window
    // above, which is what lets the sink take these three at all.
    let boundary = logs.mark();
    assert!(
        logs.drain_since(boundary).is_empty(),
        "the truncated window was not released"
    );
    let _ = logsink::plant("open").expect("mint an opening plant");
    log::info!(target: "haven_core::relay", "circle#a91f3c settled");
    let _ = logsink::plant("close").expect("mint a closing plant");
    let report = scan("logsink-truncated", &logs.drain_since(boundary));
    assert!(
        report.rc == Rc::ProvesTooLittle,
        "a capture whose sink dropped records proves less than it claims"
    );
    assert!(
        report
            .findings
            .iter()
            .any(|finding| finding.contains("truncated") && finding.contains("dropped=5+")),
        "the truncation is reported, as a bucket"
    );
    drop(logs);

    // And the next lease starts clean, so one capture's losses are never
    // reported against the next one's.
    let next = SoakLogs::acquire(lease_bound())
        .await
        .expect("the capture lease");
    assert!(
        next.dropped() == 0,
        "a loss outlived the capture that had it"
    );
    drop(next);
}
