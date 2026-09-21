//! Ties the shared fake scanner to the real one.
//!
//! The shell half of this tree cannot build a Rust binary: `repo-guards.yml` is
//! toolchain-free by design, and the iOS lanes' self-tests run on a macOS runner
//! with no cargo. So every self-test that exercises the log-privacy gate injects
//! a FAKE `haven-logscan` through `HAVEN_LOGSCAN_BIN`. That fake decides what
//! those self-tests can prove.
//!
//! Until now there were five of them, written inline: two that answered `seal`
//! and `scan` and exited 9 for anything else, three that answered **any** argv
//! at all with a staged exit code. None of them read a flag. A renamed flag, a
//! new required argument or a changed exit code would therefore have kept all
//! five green while every lane went rc 2 — or, worse, while a gate quietly
//! stopped scanning. It is the shape that cost CI run 35536892150 a whole
//! Android matrix, where a fake emulator was `exit 0` for any argv and the
//! probe's real 255 was never measured.
//!
//! There is now ONE fake (`tooling/e2e/ci/fixtures/fake-haven-logscan.sh`), it
//! models the real binary's ARGUMENT CONTRACT, and this test drives the same
//! table through both. It lives here because `rust-check.yml`'s `logscan-tooling`
//! job is the one place that already has the binary and the checkout: its
//! `cargo test` step builds `haven-logscan` for `CARGO_BIN_EXE_haven-logscan`
//! and runs this file.
//!
//! It fails if EITHER side moves alone, and it fails CLOSED: a missing `bash`, a
//! missing fake, a fake without its executable bit and a signalled process are
//! each a distinct panic, never a skip.

use std::path::{Path, PathBuf};
use std::process::Command;

/// The one exit code that means "I could not read this command line".
const RC_GUARD: i32 = 2;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("the repository root two levels above tooling/logscan")
}

/// The checked-in fake, refusing to run at all if it is not what a lane would
/// get: `logscan-gate.sh` and `scan-logs.sh` both require `-f` and `-x`, so a
/// fake that lost its executable bit would put every self-test on the gate's
/// absent-binary arm, where the fixtures still pass.
fn fake_path() -> PathBuf {
    let path = repo_root().join("tooling/e2e/ci/fixtures/fake-haven-logscan.sh");
    assert!(
        path.is_file(),
        "the shared fake scanner is missing; every shell self-test that injects \
         it would exercise the gate's absent-binary arm instead of its scanner arm"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path)
            .expect("fake metadata")
            .permissions()
            .mode();
        assert!(
            mode & 0o111 != 0,
            "the shared fake scanner has no executable bit; logscan-gate.sh and \
             scan-logs.sh both test `-x` before running it, so every gate under \
             test would take the absent-binary arm and still pass"
        );
    }
    path
}

/// A scratch directory that cleans itself up. Only the `--report` path needs
/// one: every other row below is decided before the binary opens a file.
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        // A counter, not `line!()`: that expands to a constant here, so every
        // Scratch in one test binary took the SAME directory and the first test
        // to finish deleted the second's `--report` path out from under it.
        static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let stamp = format!(
            "{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        );
        let dir = std::env::temp_dir().join(format!("haven-logscan-contract-{stamp}"));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        Self(dir)
    }

    fn join(&self, name: &str) -> String {
        self.0.join(name).to_string_lossy().into_owned()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// What both sides must answer.
///
/// Every refusal here is [`RC_GUARD`] and nothing else, because that is the one
/// code the binary has for "I could not read this command line" — the rc is the
/// claim, not a parameter.
enum Verdict {
    /// Both refuse, and both say why: the string is a phrase of the real
    /// binary's reason, so a fake that refuses the right argv for the wrong
    /// reason is still a failure.
    Refused(&'static str),
    /// Both ACCEPT the argv. The real binary must not answer rc 2 — whatever it
    /// then makes of the capture is not this table's business — and the fake
    /// must answer its default 0. This is the row a renamed flag or a new
    /// required argument reds.
    Accepted,
}

struct Row {
    name: &'static str,
    argv: Vec<String>,
    verdict: Verdict,
}

/// A row, whose argv is written as the command line it is.
///
/// Every word in these tables is space-free by construction — the fixtures name
/// flags, classes and paths under `/nonexistent/` — so splitting on whitespace
/// is exact and reads as the lane would spell it.
fn refused(name: &'static str, argv: &str, marker: &'static str) -> Row {
    Row {
        name,
        argv: argv.split_whitespace().map(str::to_owned).collect(),
        verdict: Verdict::Refused(marker),
    }
}

fn accepted(name: &'static str, argv: &str) -> Row {
    Row {
        name,
        argv: argv.split_whitespace().map(str::to_owned).collect(),
        verdict: Verdict::Accepted,
    }
}

/// Runs a command to completion and returns its exit code and combined output.
///
/// A process that died on a signal has no exit code, and reading that as any of
/// the five verdicts would be a guess: it panics instead.
fn invoke(program: &Path, lead: &[&Path], argv: &[String]) -> (i32, String) {
    let mut command = Command::new(program);
    for arg in lead {
        command.arg(arg);
    }
    let out = command.args(argv).output().unwrap_or_else(|e| {
        panic!(
            "cannot run {}: {e}. The contract between the shared fake and the \
             real scanner is unmeasurable without it; this is a failure, not a \
             reason to skip.",
            program.display()
        )
    });
    let code = out.status.code().unwrap_or_else(|| {
        panic!(
            "{} was killed by a signal and named no exit code",
            program.display()
        )
    });
    let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&out.stderr));
    (code, text)
}

/// The first line of an output, for a failure message. Rule 15 holds over this
/// binary's own stdout and stderr (`logscan_never_prints_a_needle`), so a line
/// of it is safe to render; the fixtures below carry no real value either way.
fn first_line(text: &str) -> &str {
    text.lines().next().unwrap_or("<no output>")
}

/// Every argv shape both sides must answer the same way.
///
/// The refusals are the real binary's, in ITS order — `scan` checks that a sink
/// was named before it checks the mode, so a row that is both sink-less and
/// mis-moded must be refused for the sink on both sides. The acceptances walk
/// the whole flag vocabulary the lane scripts build, which is what turns a
/// renamed flag into a red here rather than into a red lane.
fn table(scratch: &Scratch) -> Vec<Row> {
    // Path-legal but absent, and nothing here ever creates it: `scan` answers
    // rc 4 for a manifest that is not there and `seal` answers rc 3 for an
    // unreadable `--decl` before it writes anything, so both acceptance rows are
    // measured without a sealed manifest and without touching the needle
    // directory. The directory is the crate's own constant rather than a second
    // spelling of it, because `seal` refuses any other parent outright.
    let manifest = Path::new(haven_logscan::manifest::NEEDLE_DIR)
        .join(format!("contract-{}.needles.json", std::process::id()))
        .to_string_lossy()
        .into_owned();
    let report = scratch.join("report.ndjson");
    let mut rows = verb_rows();
    rows.extend(seal_rows(&manifest));
    rows.extend(scan_rows(&manifest, &report));
    rows
}

/// The first word: anything the binary does not recognise is its usage block.
fn verb_rows() -> Vec<Row> {
    vec![
        refused("no argument at all", "", "runtime log-privacy scanner"),
        refused(
            "an unknown verb",
            "frobnicate",
            "runtime log-privacy scanner",
        ),
    ]
}

/// `seal`, the verb logscan-gate.sh invokes.
fn seal_rows(manifest: &str) -> Vec<Row> {
    // Synthetic throughout, per the fixtures' conventions: a repeating-byte seed
    // (`tooling/logscan/fixtures/`), the harness's own `Qzvx` stem
    // (host-needles.sh), and paths that exist nowhere.
    let seed = "0707070707070707070707070707070707070707070707070707070707070707";
    vec![
        refused(
            "seal: an unknown flag",
            &format!("seal --run-id contract --nope x --out {manifest}"),
            "unknown flag",
        ),
        refused(
            "seal: a flag with no value",
            "seal --run-id",
            "needs a value",
        ),
        refused(
            "seal: --exempt-endpoint with no value",
            "seal --run-id contract --exempt-endpoint",
            "needs a value",
        ),
        refused(
            "seal: no --run-id",
            &format!("seal --out {manifest}"),
            "seal needs --run-id",
        ),
        refused(
            "seal: no --out",
            "seal --run-id contract",
            "seal needs --out",
        ),
        refused(
            "seal: --host-decl that is not <key>=<value>",
            &format!("seal --run-id contract --host-decl pubkey --out {manifest}"),
            "needs <key>=<value>",
        ),
        refused(
            "seal: --expect with a count that is not a number",
            &format!("seal --run-id contract --expect pubkey=many --out {manifest}"),
            "needs <class>=<min-count>",
        ),
        refused(
            "seal: --floor with a count that is not a number",
            &format!("seal --run-id contract --floor drive=abc --out {manifest}"),
            "needs <sink>=<min-lines>",
        ),
        refused(
            "seal: --declared-plants outside its two words",
            &format!("seal --run-id contract --declared-plants maybe --out {manifest}"),
            "--declared-plants takes",
        ),
        accepted(
            "seal: the whole vocabulary logscan-gate.sh builds",
            &format!(
                "seal --run-id contract --decl /nonexistent/contract.needles.decl \
                 --host-decl circle_name=QzvxCIRCLEcontract --host-seed {seed} \
                 --declared-plants none --expect pubkey=1 --floor drive=20 \
                 --exempt-endpoint ws://127.0.0.1:7788 --out {manifest}"
            ),
        ),
    ]
}

/// `scan`, the verb scan-logs.sh invokes, in both of its modes.
fn scan_rows(manifest: &str, report: &str) -> Vec<Row> {
    let sink = "--sink drive=/nonexistent/a.log";
    vec![
        refused(
            "scan: an unknown flag",
            &format!("scan --manifest {manifest} {sink} --nope"),
            "unknown flag",
        ),
        refused(
            "scan: --report with no value",
            &format!("scan --manifest {manifest} {sink} --report"),
            "needs a value",
        ),
        refused(
            "scan: no --sink at all",
            &format!("scan --manifest {manifest}"),
            "scan needs at least one --sink",
        ),
        refused(
            "scan: --rules-only with no --sink is still the sink refusal",
            "scan --rules-only",
            "scan needs at least one --sink",
        ),
        refused(
            "scan: --sink that is not <class>=<path>",
            &format!("scan --manifest {manifest} --sink drive"),
            "needs <key>=<value>",
        ),
        refused(
            "scan: --plants-in that is not <class>=<path>",
            &format!("scan --manifest {manifest} {sink} --plants-in drive"),
            "needs <key>=<value>",
        ),
        refused(
            "scan: --segments with a count that is not a number",
            &format!("scan --manifest {manifest} {sink} --segments drive=q"),
            "needs <class>=<count>",
        ),
        refused(
            "scan: --rules-only beside --manifest",
            &format!("scan --rules-only --manifest {manifest} {sink}"),
            "mutually exclusive",
        ),
        // The row logscan-gate.sh's `rules` profile used to pass while its fake
        // answered 0: the wrapper forwards the caller's `--plants-in`, and a
        // rules-only scan reconciles no positive control.
        refused(
            "scan: --rules-only beside --plants-in",
            &format!("scan --rules-only {sink} --plants-in drive=/nonexistent/a.log"),
            "--plants-in reconciles positive controls",
        ),
        refused(
            "scan: --exempt-endpoint beside a manifest",
            &format!("scan --manifest {manifest} --exempt-endpoint 127.0.0.1 {sink}"),
            "--exempt-endpoint belongs to",
        ),
        // Both acceptance rows are read off `scan-logs.sh`'s own argv builder —
        // `source_args` + `scanner_args` + `report_args` — rather than off a
        // lane, because the wrapper validates and forwards more than any lane
        // currently passes, and a flag it CAN forward that no row covers is a
        // renamed flag nobody would hear about until a lane went rc 2.
        // `--manifest-dir` resolves to `--manifest <path>` inside the wrapper,
        // so it is this same row.
        accepted(
            "scan: the whole vocabulary scan-logs.sh builds with a manifest",
            &format!(
                "scan --manifest {manifest} --sink logcat=/nonexistent/a.log \
                 --sink drive=/nonexistent/b.log,/nonexistent/c.log --segments drive=2 \
                 --plants-in drive=/nonexistent/b.log --report {report}"
            ),
        ),
        // `--exempt-endpoint` is repeatable through the wrapper and `--segments`
        // rides a rules-only scan (only `--plants-in` does not, one row above).
        accepted(
            "scan: the whole vocabulary scan-logs.sh builds with --rules-only",
            &format!(
                "scan --rules-only --exempt-endpoint 127.0.0.1 \
                 --exempt-endpoint http://127.0.0.1:4545 \
                 --sink rust-test=/nonexistent/a.log --segments rust-test=1 \
                 --report {report}"
            ),
        ),
    ]
}

/// THE CONTRACT. Every row, through both binaries, same answer.
#[test]
fn the_shared_fake_answers_every_argv_shape_as_the_real_scanner_does() {
    let scratch = Scratch::new();
    let fake = fake_path();
    let real = PathBuf::from(env!("CARGO_BIN_EXE_haven-logscan"));
    let bash = PathBuf::from("bash");

    for case in table(&scratch) {
        let (real_rc, real_out) = invoke(&real, &[], &case.argv);
        let (fake_rc, fake_out) = invoke(&bash, &[fake.as_path()], &case.argv);
        match case.verdict {
            Verdict::Refused(marker) => {
                assert!(
                    real_rc == RC_GUARD,
                    "{}: the real scanner answered rc {real_rc} where this table \
                     records a usage refusal — the binary moved and the shared fake \
                     did not: {}",
                    case.name,
                    first_line(&real_out)
                );
                assert!(
                    fake_rc == RC_GUARD,
                    "{}: the shared fake answered rc {fake_rc}, not the real scanner's \
                     usage refusal; a self-test injecting it proves less than it \
                     reports: {}",
                    case.name,
                    first_line(&fake_out)
                );
                assert!(
                    real_out.contains(marker),
                    "{}: the real scanner no longer gives `{marker}` as its reason, so \
                     the shared fake is now refusing this argv for a reason the binary \
                     does not hold: {}",
                    case.name,
                    first_line(&real_out)
                );
                assert!(
                    fake_out.contains(marker),
                    "{}: the shared fake refused with the right code and the wrong \
                     reason; `{marker}` is what the real scanner says: {}",
                    case.name,
                    first_line(&fake_out)
                );
            }
            Verdict::Accepted => {
                assert!(
                    real_rc != RC_GUARD,
                    "{}: the real scanner REFUSED an argv the lane scripts build — a \
                     renamed flag, a new required argument or a dropped one. Every \
                     shell self-test injecting the fake still passes, and the lane is \
                     rc 2: {}",
                    case.name,
                    first_line(&real_out)
                );
                assert!(
                    fake_rc == 0,
                    "{}: the shared fake refused (rc {fake_rc}) an argv the real \
                     scanner accepts, so a self-test would read a usage error where a \
                     lane reads a verdict: {}",
                    case.name,
                    first_line(&fake_out)
                );
            }
        }
    }
}

/// The fake answers exactly the verbs the shell half invokes, and refuses the
/// rest outright.
///
/// The real binary also has `plant` and `--self-test`; no lane script runs
/// either, so the fake does not model them, and that is a decision rather than
/// an oversight only while this test holds. A script that starts invoking a
/// third verb reds here until the fake models it, instead of silently getting
/// the fake's usage refusal in a lane.
#[test]
fn the_fake_models_exactly_the_verbs_the_lane_scripts_invoke() {
    let fake = fake_path();
    let bash = PathBuf::from("bash");
    let mut invoked: Vec<String> = Vec::new();
    for path in harness_scripts() {
        let text = std::fs::read_to_string(&path).expect("harness script");
        for line in text.lines() {
            // The two call sites are `"${bin}" seal …` and `"${bin}" scan …`;
            // a comment mentioning one is not a call.
            if line.trim_start().starts_with('#') {
                continue;
            }
            // A verb is a bare lowercase word. `[[ ! -f "${bin}" || … ]]` and
            // `HAVEN_LOGSCAN_BIN="${bin}" FAKE_… = …` both put something else
            // there, and neither is a command position.
            if let Some(tail) = line.split("\"${bin}\" ").nth(1) {
                let verb = tail.split_whitespace().next().unwrap_or_default();
                if !verb.is_empty()
                    && verb.chars().all(|c| c.is_ascii_lowercase() || c == '-')
                    && !invoked.iter().any(|v| v == verb)
                {
                    invoked.push(verb.to_owned());
                }
            }
        }
    }
    invoked.sort();
    assert!(
        invoked == ["scan", "seal"],
        "the harness invokes {invoked:?} on the scanner binary; the shared fake \
         models `seal` and `scan` alone"
    );

    for verb in &invoked {
        // A modelled verb PARSES its flags: an unknown one is refused by name,
        // never by the usage banner a rejected verb gets.
        let (rc, out) = invoke(
            &bash,
            &[fake.as_path()],
            &[verb.clone(), "--nope".to_owned()],
        );
        assert!(
            rc == RC_GUARD && out.contains("unknown flag"),
            "the shared fake does not parse `{verb}`, which the harness invokes: rc {rc}"
        );
    }
    for verb in ["plant", "--self-test"] {
        let (rc, out) = invoke(&bash, &[fake.as_path()], &[verb.to_owned()]);
        assert!(
            rc == RC_GUARD && out.contains("runtime log-privacy scanner"),
            "the shared fake answers `{verb}`, which no lane script invokes; a fake \
             that models more than the harness uses is a second contract to keep: rc {rc}"
        );
    }
}

/// No self-test writes a fake of its own again.
///
/// Five did, and all five accepted every argv. The pin is behavioural in shape:
/// each of the five names the shared fake, and none of them makes one
/// executable, which is the one line an inline fake cannot do without.
///
/// The first four source `logscan-gate.sh` and take its resolved constant;
/// `scan-logs.sh` does not source it, so it resolves the same fixture beside
/// itself. Either spelling names ONE file, which is the point.
#[test]
fn every_gate_self_test_injects_the_one_shared_fake() {
    let root = repo_root();
    for (name, marker) in [
        ("logscan-gate.sh", "fake_bin=\"${LOGSCAN_FAKE_BIN}\""),
        (
            "run-single-avd-scenario.sh",
            "fake_bin=\"${LOGSCAN_FAKE_BIN}\"",
        ),
        (
            "run-b5-permission-revocation.sh",
            "fake_bin=\"${LOGSCAN_FAKE_BIN}\"",
        ),
        (
            "run-b9-network-reconnect.sh",
            "fake_bin=\"${LOGSCAN_FAKE_BIN}\"",
        ),
        (
            "scan-logs.sh",
            "fake=\"${script_dir}/fixtures/fake-haven-logscan.sh\"",
        ),
    ] {
        let path = root.join("tooling/e2e/ci").join(name);
        let text = std::fs::read_to_string(&path).expect("harness script");
        assert!(
            text.contains(marker),
            "{name} no longer injects the shared fake; a fake it writes itself \
             records argv without reading it, which is how five self-tests came to \
             accept command lines the binary refuses"
        );
        // An inline fake has to be made executable before it can be injected, so
        // that line is the one all five had and none may have again.
        for line in text.lines() {
            assert!(
                !(line.contains("chmod +x") && line.contains("fake")),
                "{name} makes a fake scanner of its own executable again"
            );
        }
    }
}

/// The one side effect a shell self-test reads back: `--report` creates its file.
///
/// `scan-logs.sh` asserts that a LEAK verdict deletes every sink and KEEPS the
/// findings report — which says only sink, line and class, never a value. That
/// assertion is worth something only if the report exists at all, so the shared
/// fake has to create it exactly where the binary does and nowhere else.
///
/// MEASURED against the release binary with `--rules-only` scans, which need no
/// sealed manifest: an ACCEPTED scan writes the path (empty when nothing was
/// found, one NDJSON object per finding when something was), and a REFUSED one
/// never touches it. Existence is compared, not content: what lands in the file
/// is a fact about the capture, which the fake deliberately does not model.
#[test]
fn the_shared_fake_creates_the_report_exactly_where_the_real_scanner_does() {
    let scratch = Scratch::new();
    let fake = fake_path();
    let real = PathBuf::from(env!("CARGO_BIN_EXE_haven-logscan"));
    let bash = PathBuf::from("bash");

    // (present?, name, argv) — the report path is filled in per side, so the two
    // binaries never race for one file.
    let cases: [(bool, &str, &str); 3] = [
        (
            true,
            "an accepted scan writes the report",
            "scan --rules-only --sink rust-test=/nonexistent/a.log --report",
        ),
        (
            false,
            "a refused scan leaves no report",
            "scan --rules-only --sink rust-test=/nonexistent/a.log --nope x --report",
        ),
        (
            false,
            "a mode refusal leaves no report either",
            "scan --rules-only --sink rust-test=/nonexistent/a.log \
             --plants-in rust-test=/nonexistent/a.log --report",
        ),
    ];
    let sides: [(&str, &Path, &[&Path]); 2] = [
        ("the real scanner", real.as_path(), &[]),
        ("the shared fake", bash.as_path(), &[fake.as_path()]),
    ];
    for (index, (want_file, name, head)) in cases.into_iter().enumerate() {
        for (side, program, lead) in sides {
            let report = scratch.join(&format!("report-{index}-{}.ndjson", lead.len()));
            let mut argv: Vec<String> = head.split_whitespace().map(str::to_owned).collect();
            argv.push(report.clone());
            let (rc, out) = invoke(program, lead, &argv);
            let exists = Path::new(&report).is_file();
            assert!(
                exists == want_file,
                "{name}: {side} {} the report and the other side does the \
                 opposite — scan-logs.sh reads that file back to prove a leak \
                 verdict kept it (rc {rc}): {}",
                if exists { "wrote" } else { "left no" },
                first_line(&out)
            );
        }
    }

    // ...and a path it cannot write is the binary's own rc 2 rather than a
    // report that silently never appears. MEASURED: `cannot write the report`.
    let missing = scratch.join("no-such-directory/report.ndjson");
    for (side, program, lead) in sides {
        let argv: Vec<String> = [
            "scan",
            "--rules-only",
            "--sink",
            "rust-test=/nonexistent/a.log",
            "--report",
            &missing,
        ]
        .into_iter()
        .map(str::to_owned)
        .collect();
        let (rc, out) = invoke(program, lead, &argv);
        assert!(
            rc == RC_GUARD && out.contains("cannot write the report"),
            "{side} answered rc {rc} for a --report path it cannot create; a \
             report that silently never appears is the same lie as a scan that \
             silently never ran: {}",
            first_line(&out)
        );
    }
}

/// Every `--sink <class>=` the harness and the workflows build names a class the
/// compiled-in policy declares.
///
/// An unknown class is rc 2 from the scanner (`is not a sink class the manifest
/// knows`), and the shared fake deliberately does not model it: the class list
/// is a POLICY fact, and a second reader of `policy.toml` is the duplication
/// this file exists to remove. So the tie is made here instead, against the
/// policy itself, which is the same protection with one source of truth.
#[test]
fn every_sink_class_the_harness_names_is_a_class_the_policy_declares() {
    let root = repo_root();
    let policy = std::fs::read_to_string(root.join("tooling/logscan/policy.toml")).expect("policy");
    let mut declared: Vec<String> = Vec::new();
    let mut in_sinks = false;
    for line in policy.lines() {
        if line.starts_with('[') {
            in_sinks = line.trim() == "[sinks]";
            continue;
        }
        if !in_sinks {
            continue;
        }
        if let Some((key, rest)) = line.split_once(" = ") {
            if rest.starts_with('{') && !key.starts_with(' ') && !key.starts_with('#') {
                declared.push(key.to_owned());
            }
        }
    }
    assert!(
        declared.len() >= 5,
        "read {} sink class(es) out of policy.toml's [sinks] table; the parser has \
         lost the table's shape and this tie would pass vacuously",
        declared.len()
    );

    let mut checked = 0usize;
    let mut files = harness_scripts();
    files.extend(workflow_files());
    for path in files {
        let text = std::fs::read_to_string(&path).expect("source");
        for piece in text.split("--sink ").skip(1) {
            let spec = piece.trim_start_matches('"');
            let Some((class, _)) = spec.split_once('=') else {
                continue;
            };
            // `<class>` in a usage line is documentation, not a sink.
            if class.is_empty()
                || !class
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
            {
                continue;
            }
            checked += 1;
            assert!(
                declared.iter().any(|d| d == class),
                "{} names the sink class `{class}`, which tooling/logscan/policy.toml \
                 does not declare; the scanner answers rc 2 for it and no shell \
                 self-test can tell, because the shared fake models the flag SHAPE \
                 and not the policy",
                path.display()
            );
        }
    }
    assert!(
        checked >= 20,
        "found only {checked} `--sink <class>=` site(s) across the harness and the \
         workflows; the extractor has stopped seeing them"
    );
}

/// Every `tooling/e2e/ci/*.sh`, sorted. Non-recursive on purpose: the fixtures
/// directory beside them holds the fake itself, not a caller.
fn harness_scripts() -> Vec<PathBuf> {
    sorted_files(&repo_root().join("tooling/e2e/ci"), "sh")
}

fn workflow_files() -> Vec<PathBuf> {
    sorted_files(&repo_root().join(".github/workflows"), "yml")
}

fn sorted_files(dir: &Path, extension: &str) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("{}: {e}", dir.display()))
        .map(|e| e.expect("entry").path())
        .filter(|p| p.is_file() && p.extension().is_some_and(|x| x == extension))
        .collect();
    out.sort();
    assert!(
        !out.is_empty(),
        "no *.{extension} under {}; this tie would pass vacuously",
        dir.display()
    );
    out
}
