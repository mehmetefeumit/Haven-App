//! `haven-wire-proxy` — the recording WebSocket proxy for Haven's E2E lanes.
//!
//! Sits between the app under test and the hermetic relay, forwarding every
//! byte and writing an NDJSON wire journal. See `docs/WIRE_JOURNAL.md` for the
//! schema and `tooling/e2e/ci/start-wire-proxy.sh` for how a lane starts it.
//!
//! # TEST HARNESS ONLY
//!
//! The journal is a complete transcript of relay traffic, including ciphertext
//! and the pubkeys carried in REQ filters. This binary must never be reachable
//! from `haven/lib` or a release build, and its RAW journal must never be
//! uploaded as a CI artifact — use `--summarize` for that.
//! `scripts/ci/check_wire_proxy_test_only.sh` enforces both.
//!
//! It also writes an MLS-GROUP-ID SIDECAR (`HAVEN_WIRE_MLS_GROUP_ID_FILE`):
//! the real MLS group ids a device declares over the control channel, so a
//! host-side oracle can assert Security Rule 4 (they never appear on the
//! wire). Asserting an absence needs the value, and the value cannot come from
//! the journal — its absence there IS the assertion. That file is the one
//! thing on this runner more sensitive than the journal, and the same guard
//! keeps it out of every artifact.
//!
//! # Usage
//!
//! ```text
//! haven-wire-proxy                      # serve, configured from the environment
//! haven-wire-proxy --self-test          # prove the instrument, then exit
//! haven-wire-proxy --summarize <in> [--out <path>]
//! ```
//!
//! # argv is otherwise ignored, deliberately
//!
//! `start-wire-proxy.sh` launches every instance with a
//! `--haven-wire-proxy-instance=<name>` marker so teardown can `pkill -f` ONE
//! instance out of several — the same convention `haven-local-relay` uses.
//! Unrecognised arguments are therefore inert rather than fatal.

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;

use haven_local_relay::journal::WireJournal;
use haven_local_relay::proxy::{MlsGroupIdSink, Proxy};
use haven_local_relay::{config, selftest, summarize, ENV_JOURNAL, ENV_MLS_GROUP_ID_FILE};

/// Exit code for a usage error (a mistyped routing table, a missing file).
const RC_USAGE: u8 = 2;
/// Exit code for a failed `--self-test`.
const RC_SELF_TEST_FAILED: u8 = 1;

#[tokio::main]
async fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();

    if args.iter().any(|a| a == "--self-test") {
        return match selftest::run().await {
            Ok(()) => ExitCode::SUCCESS,
            Err(err) => {
                eprintln!("haven-wire-proxy: SELF-TEST FAILED — {err}");
                ExitCode::from(RC_SELF_TEST_FAILED)
            }
        };
    }

    if let Some(index) = args.iter().position(|a| a == "--summarize") {
        return run_summarize(&args, index);
    }

    serve().await
}

/// Reads a journal and writes its redacted, upload-safe form.
fn run_summarize(args: &[String], index: usize) -> ExitCode {
    let Some(input) = args.get(index + 1) else {
        eprintln!("usage: haven-wire-proxy --summarize <journal> [--out <path>]");
        return ExitCode::from(RC_USAGE);
    };
    let output = args
        .iter()
        .position(|a| a == "--out")
        .and_then(|i| args.get(i + 1))
        .map(PathBuf::from);

    // A missing or empty journal is NOT a clean summary. Callers key their
    // fail-closed handling off this exit code, mirroring the convention in
    // tooling/e2e/ci/scan-logs-for-secrets.sh: an absent instrument proves
    // nothing, and reporting "0 lines, all fine" is the false green this whole
    // workstream exists to remove.
    let text = match std::fs::read_to_string(input) {
        Ok(text) => text,
        Err(err) => {
            eprintln!(
                "haven-wire-proxy: journal '{input}' is unreadable ({:?}); \
                 nothing was summarized.",
                err.kind()
            );
            return ExitCode::from(RC_USAGE);
        }
    };
    if text.trim().is_empty() {
        eprintln!(
            "haven-wire-proxy: journal '{input}' is EMPTY; the proxy recorded \
             nothing, so this run carries no wire evidence."
        );
        return ExitCode::from(RC_USAGE);
    }

    let (summary, stats) = summarize::summarize(&text);
    match output {
        Some(path) => {
            if let Err(err) = std::fs::write(&path, &summary) {
                eprintln!(
                    "haven-wire-proxy: could not write summary ({:?})",
                    err.kind()
                );
                return ExitCode::from(RC_USAGE);
            }
            eprintln!(
                "haven-wire-proxy: summarized {} line(s) ({} malformed, {} unparseable frames) \
                 -> {}",
                stats.lines,
                stats.malformed,
                stats.unparseable_frames,
                path.display()
            );
        }
        None => print!("{summary}"),
    }
    ExitCode::SUCCESS
}

/// Binds every route and serves until Ctrl-C / SIGTERM.
async fn serve() -> ExitCode {
    let config = match config::from_env() {
        Ok(config) => config,
        Err(err) => {
            // A mistyped routing table must fail LOUDLY at startup: silently
            // dropping a relay would leave its traffic unrecorded while every
            // oracle still reported green over the relays that were proxied.
            eprintln!("haven-wire-proxy: bad configuration — {err}");
            return ExitCode::from(RC_USAGE);
        }
    };

    let journal_path = std::env::var(ENV_JOURNAL).map_or_else(
        |_| PathBuf::from(haven_local_relay::DEFAULT_JOURNAL_PATH),
        PathBuf::from,
    );
    warn_if_journal_is_stale(&journal_path);

    let mls_group_id_path = std::env::var(ENV_MLS_GROUP_ID_FILE).map_or_else(
        |_| PathBuf::from(haven_local_relay::DEFAULT_MLS_GROUP_ID_PATH),
        PathBuf::from,
    );
    warn_if_sidecar_is_stale(&mls_group_id_path);

    let journal = Arc::new(WireJournal::open(&journal_path));
    let mls_group_ids = Arc::new(MlsGroupIdSink::new(mls_group_id_path.clone()));
    let proxy = match Proxy::start(&config, Arc::clone(&journal), Arc::clone(&mls_group_ids)).await
    {
        Ok(proxy) => proxy,
        Err(err) => {
            // NOT fail-open: a proxy that cannot listen leaves the app pointed
            // at a dead port, so the lane must know now.
            eprintln!(
                "haven-wire-proxy: could not bind ({:?}); the lane has no relay path.",
                err.kind()
            );
            return ExitCode::FAILURE;
        }
    };

    // stderr (not stdout) so it never pollutes a piped journal; the CI script
    // greps these lines to confirm readiness.
    for route in proxy.bound_routes() {
        eprintln!(
            "[haven-wire-proxy] ws://{} -> {}",
            route.listen, route.upstream
        );
    }
    // BEFORE the journal line, which is what start-wire-proxy.sh greps for as
    // its readiness signal: everything printed after that line races the
    // script's `cat` of the log.
    eprintln!(
        "[haven-wire-proxy] mls-group-id sidecar: {} \
         (NEVER an artifact — it holds the values Security Rule 4 forbids on the wire)",
        mls_group_id_path.display()
    );
    eprintln!(
        "[haven-wire-proxy] journal: {} ({})",
        journal_path.display(),
        if journal.is_degraded() {
            "DEGRADED — traffic will flow UNRECORDED"
        } else {
            "recording"
        }
    );

    wait_for_shutdown().await;
    proxy.shutdown();

    let stats = journal.stats();
    eprintln!(
        "[haven-wire-proxy] shutting down: {} connection(s), {} record(s) observed, \
         {} line(s) written{}",
        proxy.connection_count(),
        stats.observed,
        stats.written,
        stats
            .degraded
            .map_or(String::new(), |reason| format!(" — DEGRADED ({reason:?})")),
    );
    // COUNTS ONLY, never the ids themselves (Security Rule 6). A lane whose
    // declarations were refused or lost has no Rule-4 ground truth, and the
    // stop script tails these lines into the step log precisely so that is
    // visible to someone reading an otherwise green run.
    let mls_stats = mls_group_ids.stats();
    eprintln!(
        "[haven-wire-proxy] mls-group-id sidecar: {} distinct id(s) recorded, \
         {} refused, {} lost",
        mls_stats.distinct, mls_stats.refused, mls_stats.lost,
    );
    ExitCode::SUCCESS
}

/// Blocks until SIGINT **or SIGTERM**.
///
/// SIGTERM is the load-bearing one: `stop-wire-proxy.sh` sends it with plain
/// `kill`, and a process that only awaits `ctrl_c()` (SIGINT) is killed by the
/// default SIGTERM disposition before it can print anything. The shutdown
/// summary below is the ONLY place a run states whether its recorder stayed
/// healthy — the stop script tails it into the step log precisely so a
/// DEGRADED run is visible to someone reading a green lane — so losing it
/// would make the degraded case silent, which is the failure this whole
/// instrument exists to remove.
async fn wait_for_shutdown() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        match signal(SignalKind::terminate()) {
            Ok(mut term) => {
                tokio::select! {
                    _ = tokio::signal::ctrl_c() => {}
                    _ = term.recv() => {}
                }
            }
            Err(err) => {
                eprintln!(
                    "[haven-wire-proxy] SIGTERM handler unavailable ({:?}); \
                     falling back to SIGINT only",
                    err.kind()
                );
                let _ = tokio::signal::ctrl_c().await;
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

/// The journal is opened in APPEND mode so a torn write can never truncate
/// prior evidence — which means a leftover file from an earlier attempt would
/// silently merge two runs under one sequence space. Say so; the start script
/// is what actually rotates it.
fn warn_if_journal_is_stale(path: &Path) {
    if path.exists() {
        eprintln!(
            "[haven-wire-proxy] NOTE: {} already exists and will be APPENDED to. \
             wire_seq restarts at 0, so a consumer would see two interleaved \
             sequence spaces. start-wire-proxy.sh rotates it; a hand-run should too.",
            path.display()
        );
    }
}

/// The sidecar is appended to as well, and a leftover file is worse here than
/// a merged journal: the ids of a PREVIOUS run's circles would be handed to
/// this run's oracle as ground truth. It would then scan this journal for
/// values that were never on this wire — an assertion that cannot fail, which
/// is the one failure mode a privacy oracle must never have.
fn warn_if_sidecar_is_stale(path: &Path) {
    if path.exists() {
        eprintln!(
            "[haven-wire-proxy] NOTE: {} already exists and will be APPENDED to, so an \
             earlier run's MLS group ids would be handed to this run's oracle as ground \
             truth and could never be found. start-wire-proxy.sh rotates it; a hand-run \
             should too.",
            path.display()
        );
    }
}
