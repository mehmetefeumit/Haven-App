//! `haven-logscan --self-test`: a hermetic end-to-end proof of the built binary.
//!
//! Every bash guard in `tooling/e2e/ci/*.sh` carries a `--self-test` so it cannot
//! rot into a rubber stamp; this is the same discipline for a compiled
//! instrument, and it is what a runner runs to check the tool before a lane
//! depends on it.
//!
//! # Every count is pinned
//!
//! The fixture counts below are asserted with `==`, not `>=`. A self-test that
//! accepted "at least one hit" would stay green after a rule was deleted, an
//! encoding stopped being produced, or a fixture line was dropped — which is the
//! exact failure mode this repository keeps finding.
//!
//! # There is no timing assertion
//!
//! The throughput case MEASURES and PRINTS megabytes per second and asserts only
//! the single-pass property (bytes read == file size). A timing floor on a shared
//! CI runner is a flake source, and CLAUDE.md forbids one; the ≥ 300 MB/s/core
//! design goal is verified locally, by reading the number this prints.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::expand::expand;
use crate::ledger::reconcile;
use crate::manifest::{parse_decl, read_manifest, Declarations, Manifest, NEEDLE_DIR};
use crate::policy::Policy;
use crate::rules::{validate_allowlist, AllowEntry, RuleSet};
use crate::scan::{scan_sinks, FindingKind, Outcome, SinkArg};
use crate::{RC_CLEAN, RC_GUARD, RC_LEAK, RC_META, RC_UNUSABLE};

/// Number of cases [`run`] must execute. A case that stops running is a case that
/// stops proving anything, and silence is how that goes unnoticed.
const DECLARED_CASES: usize = 14;

const DECL: &str = include_str!("../fixtures/selftest.needles.decl");
const CLEAN_DRIVE: &str = include_str!("../fixtures/clean.drive.log");
const CLEAN_LOGCAT: &str = include_str!("../fixtures/clean.logcat.log");
const DIRTY_LOGCAT: &str = include_str!("../fixtures/dirty.logcat.log");
const FURNITURE_DRIVE: &str = include_str!("../fixtures/furniture.drive.log");
const FURNITURE_LOGCAT: &str = include_str!("../fixtures/furniture.logcat.log");
const REASSEMBLY: &str = include_str!("../fixtures/reassembly.logcat.log");
const ALLOW_EXPIRED: &str = include_str!("../fixtures/allowlist.expired.json");
const ALLOW_DANGLING: &str = include_str!("../fixtures/allowlist.dangling.json");
const ALLOW_LIVE: &str = include_str!("../fixtures/allowlist.live.json");
const PLANT_TRIPPING: &str = include_str!("../fixtures/plant.tripping.needles.decl");

/// Searchable terms the fixture declaration expands to.
const SEALED_TERMS: usize = 139;
/// Labels that produced no term: 61 aliases, 30 policy gaps, 3 renderings the
/// declared values cannot carry.
const SEALED_DROPPED: usize = 94;
/// Of those, the ones that lose recall (everything but an alias): the 28
/// withheld `nsec` renderings, the two hinted bech32 forms, and the three the
/// fixture values are too short for.
const SEALED_COVERAGE_GAPS: usize = 33;
/// Lines of `dirty.logcat.log` that must each be caught, individually.
const DIRTY_RULE_LINES: usize = 12;
/// Lines of `dirty.logcat.log` that must each stay clean: the vendor line (tag
/// scoping) and the alias-only Haven line.
const DIRTY_CLEAN_LINES: usize = 2;
/// Lines of the real-furniture negative controls, pinned so a fixture that lost
/// lines cannot report the same clean verdict over less evidence.
const FURNITURE_DRIVE_LINES: u64 = 98;
const FURNITURE_LOGCAT_LINES: u64 = 87;
/// Structural rules, all of which the dirty fixture must exercise.
const RULE_COUNT: usize = 12;
/// Bytes the CLI's throughput probe generates.
const FULL_PROBE_BYTES: u64 = 64 * 1024 * 1024;
/// Bytes `cargo test`'s run of the self-test generates. The single-pass property
/// is size-independent; the CLI gate is what reads a realistic number.
#[cfg(test)]
const SMALL_PROBE_BYTES: u64 = 1024 * 1024;

/// Everything the self-test can conclude about one case.
type Case = Result<(), String>;

/// Runs the whole self-test.
///
/// # Errors
///
/// Returns a message naming every failing case.
pub fn run(out: &mut dyn Write, err: &mut dyn Write) -> Result<(), String> {
    run_with(out, err, FULL_PROBE_BYTES, None)
}

/// Runs the self-test with a given throughput probe size and, in a test build
/// only, one structural rule suppressed.
pub(crate) fn run_with(
    out: &mut dyn Write,
    err: &mut dyn Write,
    probe_bytes: u64,
    mutation: Option<&'static str>,
) -> Result<(), String> {
    let rig = Rig::new()?;
    let mut executed = 0usize;
    let mut failures = Vec::new();

    for (name, result) in [
        ("A ledger reconciliation", case_ledger()),
        (
            "B every encoding label caught",
            case_encodings(&rig, mutation),
        ),
        (
            "C every rule caught, vendor lines skipped",
            case_rules(&rig, mutation),
        ),
        ("D cross-entry reassembly", case_reassembly(&rig, mutation)),
        ("E sealed manifest round trip", case_round_trip(&rig)),
        ("F every plant caught", case_plants_clean(&rig, mutation)),
        (
            "G a missed or undeclared plant",
            case_plants_missed(&rig, mutation),
        ),
        ("H a plant that trips a rule", case_plant_tripping(&rig)),
        ("I segment reconciliation", case_segments(&rig, mutation)),
        ("J rc aggregation", case_aggregation(&rig, mutation)),
        ("K allowlist expiry and proofs", case_allowlist(&rig)),
        ("L line floor", case_floor(&rig, mutation)),
        (
            "M single streaming pass",
            case_throughput(&rig, out, probe_bytes, mutation),
        ),
        ("N real furniture is clean", case_furniture(&rig, mutation)),
    ] {
        executed += 1;
        match result {
            Ok(()) => {
                let _ = writeln!(out, "  PASS {name}");
            }
            Err(reason) => {
                let _ = writeln!(err, "  FAIL {name}: {reason}");
                failures.push(name);
            }
        }
    }

    if executed != DECLARED_CASES {
        return Err(format!(
            "self-test executed {executed} case(s) but declares {DECLARED_CASES} — a case has been dropped and would have proved nothing silently"
        ));
    }
    if failures.is_empty() {
        let _ = writeln!(out, "haven-logscan: self-test passed ({executed} cases).");
        Ok(())
    } else {
        Err(format!("failing case(s): {}", failures.join(", ")))
    }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// A scratch directory holding the materialised fixtures, plus two sealed
/// manifests. Everything it creates is removed on drop, including the manifests
/// in the needle directory.
struct Rig {
    dir: PathBuf,
    /// Sealed with every line floor lowered to 1, which is what lets 10-line
    /// fixtures stand in for a 5 000-line logcat.
    manifest: PathBuf,
    /// Sealed with the policy's real floors, for the floor case.
    manifest_real_floors: PathBuf,
    stamp: String,
}

impl Rig {
    fn new() -> Result<Self, String> {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.subsec_nanos());
        let stamp = format!("{}-{nanos}", std::process::id());
        let dir = std::env::temp_dir().join(format!("haven-logscan-selftest-{stamp}"));
        std::fs::create_dir_all(&dir).map_err(|e| format!("scratch dir: {:?}", e.kind()))?;
        let rig = Self {
            manifest: Path::new(NEEDLE_DIR).join(format!("selftest-{stamp}.needles.json")),
            manifest_real_floors: Path::new(NEEDLE_DIR)
                .join(format!("selftest-floors-{stamp}.needles.json")),
            dir,
            stamp,
        };
        let decl = rig.write("selftest.needles.decl", DECL)?;
        let decl = decl.display().to_string();
        let manifest = rig.manifest.display().to_string();
        expect_rc(
            RC_CLEAN,
            &[
                "seal",
                "--run-id",
                &format!("selftest-{}", rig.stamp),
                "--decl",
                &decl,
                "--floor",
                "logcat=1",
                "--floor",
                "drive=1",
                "--exempt-endpoint",
                "ws://10.0.2.2:7777",
                "--out",
                &manifest,
            ],
        )?;
        expect_rc(
            RC_CLEAN,
            &[
                "seal",
                "--run-id",
                &format!("selftest-floors-{}", rig.stamp),
                "--decl",
                &decl,
                "--out",
                &rig.manifest_real_floors.display().to_string(),
            ],
        )?;
        Ok(rig)
    }

    fn write(&self, name: &str, body: &str) -> Result<PathBuf, String> {
        let path = self.dir.join(name);
        std::fs::write(&path, body)
            .map_err(|e| format!("cannot write the fixture {name}: {:?}", e.kind()))?;
        Ok(path)
    }

    fn manifest(&self) -> Result<Manifest, String> {
        read_manifest(&self.manifest)
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
        let _ = std::fs::remove_file(&self.manifest);
        let _ = std::fs::remove_file(&self.manifest_real_floors);
    }
}

/// Runs a full CLI invocation in-process and asserts its exit code.
///
/// Through the real entry point, because the hole this repository found in its
/// bash scanner lived in `main`'s argument loop rather than in the function a
/// narrower self-test would have called.
fn expect_rc(want: i32, args: &[&str]) -> Result<(), String> {
    let owned: Vec<String> = args.iter().map(|a| (*a).to_owned()).collect();
    let mut out = Vec::new();
    let mut err = Vec::new();
    let got = crate::cli::run(&owned, &mut out, &mut err);
    if got == want {
        return Ok(());
    }
    Err(format!(
        "expected rc {want}, got {got} from `{}`; stderr: {}",
        args.first().copied().unwrap_or("?"),
        String::from_utf8_lossy(&err).trim()
    ))
}

/// Builds the rule engine a case scans with.
///
/// The `mutation` argument can only do anything in a test build: that is what
/// makes the mutation test possible without giving the shipped binary a way to
/// turn a rule off.
fn rules_for(
    manifest: &Manifest,
    allow: Vec<AllowEntry>,
    mutation: Option<&'static str>,
) -> Result<RuleSet, String> {
    let rules = RuleSet::new(
        manifest.base64_entropy_bits,
        1_800_000_000,
        &manifest.exempt_endpoints,
        allow,
    )?;
    #[cfg(test)]
    if let Some(id) = mutation {
        return Ok(rules.with_rule_disabled(id));
    }
    let _ = mutation;
    Ok(rules)
}

fn sink(class: &str, paths: &[&PathBuf]) -> SinkArg {
    SinkArg {
        class: class.to_owned(),
        paths: paths.iter().map(|p| (*p).clone()).collect(),
    }
}

fn scan(manifest: &Manifest, sinks: &[SinkArg], rules: &RuleSet) -> Outcome {
    scan_sinks(
        manifest,
        sinks,
        &BTreeMap::new(),
        &BTreeMap::new(),
        rules,
        false,
    )
}

/// Drops every line containing `marker`, keeping the rest verbatim.
fn rejoin(text: &str, marker: &str) -> String {
    let mut out = String::new();
    for line in text.lines().filter(|line| !line.contains(marker)) {
        out.push_str(line);
        out.push('\n');
    }
    out
}

fn require(condition: bool, message: &str) -> Case {
    if condition {
        Ok(())
    } else {
        Err(message.to_owned())
    }
}

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

/// The expansion's own shape, and the ledger's agreement with it.
fn case_ledger() -> Case {
    let policy = Policy::load()?;
    let mut declarations = Declarations::default();
    let mut ids = 0;
    let mut order = 0;
    parse_decl(&policy, DECL, &mut ids, &mut order, &mut declarations)?;
    let declared: Vec<crate::expand::Declared> = declarations
        .values
        .iter()
        .map(|(declared, _)| declared.clone())
        .collect();
    let expansion = expand(&policy, &declared)?;
    let mismatches = reconcile(&policy, &expansion);
    require(
        mismatches.is_empty(),
        &format!(
            "the ledger and the expander disagree: {}",
            mismatches
                .iter()
                .map(crate::ledger::Mismatch::message)
                .collect::<Vec<_>>()
                .join(" | ")
        ),
    )?;
    let gaps = expansion.dropped.iter().filter(|d| d.coverage_gap).count();
    require(
        expansion.terms.len() == SEALED_TERMS,
        &format!(
            "the fixture declaration expands to {} term(s), not the pinned {SEALED_TERMS}",
            expansion.terms.len()
        ),
    )?;
    require(
        expansion.dropped.len() == SEALED_DROPPED,
        &format!(
            "the fixture declaration drops {} label(s), not the pinned {SEALED_DROPPED}",
            expansion.dropped.len()
        ),
    )?;
    require(
        gaps == SEALED_COVERAGE_GAPS,
        &format!("{gaps} coverage gap(s), not the pinned {SEALED_COVERAGE_GAPS}"),
    )
}

/// One line per term: every single encoding must be caught on its own line.
fn case_encodings(rig: &Rig, mutation: Option<&'static str>) -> Case {
    let manifest = rig.manifest()?;
    let floor = manifest
        .sinks
        .get("drive")
        .map_or(6, |spec| spec.term_floor);
    let searched: Vec<&crate::expand::Term> = manifest
        .terms
        .iter()
        .filter(|t| t.text.chars().count() >= floor)
        .collect();
    let mut body = String::new();
    for term in &searched {
        body.push_str("[fixture] ");
        body.push_str(&term.text);
        body.push('\n');
    }
    let path = rig.write("one-term-per-line.drive.log", &body)?;
    let rules = rules_for(&manifest, Vec::new(), mutation)?;
    let outcome = scan(&manifest, &[sink("drive", &[&path])], &rules);
    let found: std::collections::BTreeSet<(String, String)> = outcome
        .findings
        .iter()
        .filter(|f| f.kind == FindingKind::Needle)
        .filter_map(|f| f.class.clone().zip(f.encoding.clone()))
        .collect();
    for term in &searched {
        require(
            found.contains(&(term.class.clone(), term.encoding.clone())),
            &format!(
                "the `{}`/`{}` encoding was not caught on its own line",
                term.class, term.encoding
            ),
        )?;
    }
    require(
        found.len() == searched.len(),
        &format!(
            "{} distinct encoding(s) caught for {} searched term(s)",
            found.len(),
            searched.len()
        ),
    )
}

/// Every rule on its own line, every clean line clean, vendor lines untouched.
fn case_rules(rig: &Rig, mutation: Option<&'static str>) -> Case {
    let manifest = rig.manifest()?;
    let dirty = rig.write("dirty.logcat.log", DIRTY_LOGCAT)?;
    let rules = rules_for(&manifest, Vec::new(), mutation)?;
    let outcome = scan(&manifest, &[sink("logcat", &[&dirty])], &rules);
    let mut by_line: BTreeMap<u64, Vec<String>> = BTreeMap::new();
    for finding in &outcome.findings {
        if finding.kind == FindingKind::Rule {
            by_line
                .entry(finding.line)
                .or_default()
                .push(finding.rule.clone().unwrap_or_default());
        }
    }
    for line in 1..=DIRTY_RULE_LINES as u64 {
        require(
            by_line.contains_key(&line),
            &format!("line {line} of the dirty fixture was not caught"),
        )?;
    }
    for line in (DIRTY_RULE_LINES as u64 + 1)..=(DIRTY_RULE_LINES + DIRTY_CLEAN_LINES) as u64 {
        require(
            !by_line.contains_key(&line),
            &format!(
                "line {line} of the dirty fixture is a clean control and must not be caught (it is a vendor-tagged line or an alias-only Haven line)"
            ),
        )?;
    }
    let ids: std::collections::BTreeSet<&String> = by_line.values().flatten().collect();
    require(
        ids.len() == RULE_COUNT,
        &format!(
            "{} distinct rule(s) fired, not the pinned {RULE_COUNT}",
            ids.len()
        ),
    )?;

    let clean_logcat = rig.write("clean.logcat.log", CLEAN_LOGCAT)?;
    let clean_drive = rig.write("clean.drive.log", CLEAN_DRIVE)?;
    let outcome = scan(
        &manifest,
        &[
            sink("logcat", &[&clean_logcat]),
            sink("drive", &[&clean_drive]),
        ],
        &rules,
    );
    require(
        outcome.findings.is_empty(),
        &format!(
            "the clean fixtures produced {} finding(s); every line of them is a negative control",
            outcome.findings.len()
        ),
    )
}

/// A needle split across two logcat entries, both ways.
fn case_reassembly(rig: &Rig, mutation: Option<&'static str>) -> Case {
    let manifest = rig.manifest()?;
    let path = rig.write("reassembly.logcat.log", REASSEMBLY)?;
    let rules = rules_for(&manifest, Vec::new(), mutation)?;
    let outcome = scan(&manifest, &[sink("logcat", &[&path])], &rules);
    let joined: Vec<&crate::scan::Finding> = outcome
        .findings
        .iter()
        .filter(|f| f.reassembled && f.encoding.as_deref() == Some("hex-lower"))
        .collect();
    require(
        joined.len() == 1,
        &format!(
            "{} re-joined hex-lower hit(s); the same-tag split must be caught and the cross-tag split must not",
            joined.len()
        ),
    )?;
    require(
        joined[0].class.as_deref() == Some("pubkey"),
        "the re-joined hit must be the same-pid/tid/tag pubkey split, not the cross-tag event id",
    )?;

    // Rust's own multi-line `{:#x?}`, built from the DECLARED value at run time
    // and framed the way `android_logger` hands logcat one entry per line. This
    // runs in the shipped binary on the runner, so the claim is checked against
    // the compiler that built it rather than against a frozen fixture.
    let hex = manifest
        .terms
        .iter()
        .find(|t| t.class == "pubkey" && t.encoding == "hex-lower")
        .ok_or_else(|| "the fixture declares a pubkey".to_owned())?;
    let bytes: Vec<u8> = (0..hex.text.len() / 2)
        .map(|i| u8::from_str_radix(&hex.text[i * 2..i * 2 + 2], 16))
        .collect::<Result<_, _>>()
        .map_err(|_| "the hex-lower term must decode".to_owned())?;
    let mut dump = String::new();
    for line in format!("{bytes:#x?}").lines() {
        let _ = writeln!(dump, "09-12 12:30:00.001  1234  1301 D haven_core: {line}");
    }
    let path = rig.write("alt-x.logcat.log", &dump)?;
    let outcome = scan(&manifest, &[sink("logcat", &[&path])], &rules);
    let alt = outcome
        .findings
        .iter()
        .filter(|f| f.encoding.as_deref() == Some("rust-debug-alt-x") && f.reassembled)
        .count();
    require(
        alt == 1,
        &format!(
            "{alt} re-joined `rust-debug-alt-x` hit(s): the alternate hex dump is the one rendering that label exists for, and it is only visible after the join preserves the indent"
        ),
    )
}

/// Seal, read back, and ask for the plant token the harness prints.
fn case_round_trip(rig: &Rig) -> Case {
    let manifest = rig.manifest()?;
    require(
        manifest.plants.len() == 2,
        "a sealed manifest carries exactly the Dart open and close plants",
    )?;
    require(
        manifest.values.len() == 9,
        "the fixture declares nine non-plant values",
    )?;
    require(
        manifest.roles == vec!["alice".to_owned()],
        "the sealed manifest records the declaring role",
    )?;
    let withheld = manifest.values.iter().filter(|v| v.raw_withheld).count();
    require(
        withheld == 1,
        "exactly the one secret-class value is withheld",
    )?;
    let path = rig.manifest.display().to_string();
    expect_rc(
        RC_CLEAN,
        &[
            "plant",
            "--manifest",
            &path,
            "--sink",
            "dart",
            "--phase",
            "open",
        ],
    )?;
    expect_rc(
        RC_GUARD,
        &[
            "plant",
            "--manifest",
            &path,
            "--sink",
            "swift",
            "--phase",
            "open",
        ],
    )
}

/// The green path: plants caught in every sink class that must carry them.
fn case_plants_clean(rig: &Rig, mutation: Option<&'static str>) -> Case {
    let manifest = rig.manifest()?;
    let logcat = rig.write("plants.logcat.log", CLEAN_LOGCAT)?;
    let drive = rig.write("plants.drive.log", CLEAN_DRIVE)?;
    let rules = rules_for(&manifest, Vec::new(), mutation)?;
    let outcome = scan(
        &manifest,
        &[sink("logcat", &[&logcat]), sink("drive", &[&drive])],
        &rules,
    );
    require(
        outcome.rc() == RC_CLEAN,
        &format!(
            "the clean capture reads as rc {} — {}",
            outcome.rc(),
            outcome
                .problems
                .iter()
                .map(|p| p.message.clone())
                .collect::<Vec<_>>()
                .join(" | ")
        ),
    )?;
    require(
        outcome.plants_caught == outcome.plants_required && outcome.plants_required == 4,
        &format!(
            "plants {}/{}: two Dart phases across two sink classes",
            outcome.plants_caught, outcome.plants_required
        ),
    )
}

/// Three ways a positive control fails, each rc 3.
fn case_plants_missed(rig: &Rig, mutation: Option<&'static str>) -> Case {
    let manifest = rig.manifest()?;
    let rules = rules_for(&manifest, Vec::new(), mutation)?;
    let logcat = rig.write("missed.logcat.log", CLEAN_LOGCAT)?;

    // 1. The capture died before the closing plant.
    let truncated = rejoin(CLEAN_DRIVE, "logscan-plant-dart-close-");
    let path = rig.write("truncated.drive.log", &truncated)?;
    let outcome = scan(
        &manifest,
        &[sink("logcat", &[&logcat]), sink("drive", &[&path])],
        &rules,
    );
    require(
        outcome.rc() == RC_UNUSABLE,
        &format!("a missing closing plant reads as rc {}", outcome.rc()),
    )?;

    // 2. A plant-shaped token nothing declared: a declaration was lost.
    let stray = format!("{CLEAN_DRIVE}logscan-plant-dart-open-ZZZZZZZZZZ\n");
    let path = rig.write("stray.drive.log", &stray)?;
    let outcome = scan(
        &manifest,
        &[sink("logcat", &[&logcat]), sink("drive", &[&path])],
        &rules,
    );
    require(
        outcome.rc() == RC_UNUSABLE,
        &format!(
            "an undeclared Dart plant token reads as rc {}",
            outcome.rc()
        ),
    )?;

    // 3. An emitter whose backend never reached the capture.
    let without_kotlin = rejoin(CLEAN_LOGCAT, "logscan-plant-kotlin-open-");
    let path = rig.write("no-kotlin.logcat.log", &without_kotlin)?;
    let drive = rig.write("plants2.drive.log", CLEAN_DRIVE)?;
    let outcome = scan(
        &manifest,
        &[sink("logcat", &[&path]), sink("drive", &[&drive])],
        &rules,
    );
    require(
        outcome.rc() == RC_UNUSABLE,
        &format!("a missing Kotlin shape plant reads as rc {}", outcome.rc()),
    )?;

    // 4. `--plants-in` narrows reconciliation to one file of the class, while the
    // other file of the same class is still scanned for needles.
    let final_attempt = rig.write("final.drive.log", CLEAN_DRIVE)?;
    let all_attempts = rig.write("all.drive.log", &truncated)?;
    let mut plants_in = BTreeMap::new();
    plants_in.insert("drive".to_owned(), final_attempt.clone());
    let outcome = scan_sinks(
        &manifest,
        &[
            sink("logcat", &[&logcat]),
            sink("drive", &[&final_attempt, &all_attempts]),
        ],
        &BTreeMap::new(),
        &plants_in,
        &rules,
        false,
    );
    require(
        outcome.rc() == RC_CLEAN,
        &format!(
            "with --plants-in naming the final attempt, the earlier attempt's missing closing plant must not be a verdict: rc {} — {}",
            outcome.rc(),
            outcome
                .problems
                .iter()
                .map(|p| p.message.clone())
                .collect::<Vec<_>>()
                .join(" | ")
        ),
    )
}

/// A mis-designed control is rc 2, never rc 1: it must not delete evidence.
fn case_plant_tripping(rig: &Rig) -> Case {
    let decl = rig.write("tripping.needles.decl", PLANT_TRIPPING)?;
    let out = Path::new(NEEDLE_DIR).join(format!("selftest-tripping-{}.needles.json", rig.stamp));
    let result = expect_rc(
        RC_GUARD,
        &[
            "seal",
            "--run-id",
            "tripping",
            "--decl",
            &decl.display().to_string(),
            "--out",
            &out.display().to_string(),
        ],
    );
    let _ = std::fs::remove_file(&out);
    result?;
    require(
        !out.exists(),
        "a run whose positive control trips a structural rule must seal nothing",
    )
}

/// A rotated segment nobody named is a segment nobody read.
fn case_segments(rig: &Rig, mutation: Option<&'static str>) -> Case {
    let manifest = rig.manifest()?;
    let rules = rules_for(&manifest, Vec::new(), mutation)?;
    let logcat = rig.write("segments.logcat.log", CLEAN_LOGCAT)?;
    let drive = rig.write("segments.drive.log", CLEAN_DRIVE)?;
    let mut segments = BTreeMap::new();
    segments.insert("logcat".to_owned(), 2usize);
    let outcome = scan_sinks(
        &manifest,
        &[sink("logcat", &[&logcat]), sink("drive", &[&drive])],
        &segments,
        &BTreeMap::new(),
        &rules,
        false,
    );
    require(
        outcome.rc() == RC_UNUSABLE,
        &format!("a segment-count mismatch reads as rc {}", outcome.rc()),
    )?;
    segments.insert("logcat".to_owned(), 1usize);
    let outcome = scan_sinks(
        &manifest,
        &[sink("logcat", &[&logcat]), sink("drive", &[&drive])],
        &segments,
        &BTreeMap::new(),
        &rules,
        false,
    );
    require(
        outcome.rc() == RC_CLEAN,
        &format!("a reconciled segment count reads as rc {}", outcome.rc()),
    )
}

/// A leak outranks an unusable sink: the containment branch must still run.
fn case_aggregation(rig: &Rig, mutation: Option<&'static str>) -> Case {
    let manifest = rig.manifest()?;
    let rules = rules_for(&manifest, Vec::new(), mutation)?;
    let dirty = rig.write("aggregate.drive.log", DIRTY_LOGCAT)?;
    let absent = rig.dir.join("never-written.drive.log");
    let outcome = scan(&manifest, &[sink("drive", &[&dirty, &absent])], &rules);
    require(
        outcome.rc() == RC_LEAK,
        &format!(
            "a leak next to an unusable sink must aggregate to rc 1, got rc {}",
            outcome.rc()
        ),
    )?;
    require(
        outcome.problems.iter().any(|p| p.rc == RC_UNUSABLE),
        "the unusable sink must still be reported alongside the leak",
    )
}

/// Stale allowances cannot accumulate, and a live one forgives exactly its hit.
fn case_allowlist(rig: &Rig) -> Case {
    let manifest = rig.manifest()?;
    let today = (2026, 9, 12);
    let root = rig.dir.clone();
    std::fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml"),
        root.join("Cargo.toml"),
    )
    .map_err(|e| format!("cannot stage the proof target: {:?}", e.kind()))?;

    for (name, body) in [("expired", ALLOW_EXPIRED), ("dangling", ALLOW_DANGLING)] {
        let entries: Vec<AllowEntry> = serde_json::from_str(body)
            .map_err(|e| format!("the {name} allowlist fixture does not parse: {e}"))?;
        require(
            validate_allowlist(&entries, today, &root).is_err(),
            &format!("the {name} allowlist fixture must be rejected"),
        )?;
    }

    let entries: Vec<AllowEntry> = serde_json::from_str(ALLOW_LIVE)
        .map_err(|e| format!("the live allowlist fixture does not parse: {e}"))?;
    validate_allowlist(&entries, today, &root)
        .map_err(|problems| format!("the live fixture must validate: {}", problems.join(" | ")))?;

    let dirty = rig.write("dirty.logcat.log", DIRTY_LOGCAT)?;
    let before = scan(
        &manifest,
        &[sink("logcat", &[&dirty])],
        &rules_for(&manifest, Vec::new(), None)?,
    );
    let after = scan(
        &manifest,
        &[sink("logcat", &[&dirty])],
        &rules_for(&manifest, entries, None)?,
    );
    let s7 = |outcome: &Outcome| -> usize {
        outcome
            .findings
            .iter()
            .filter(|f| f.rule.as_deref() == Some("S7"))
            .count()
    };
    require(
        s7(&before) == 1 && s7(&after) == 0,
        &format!(
            "the live entry must forgive exactly the one S7 hit: {} before, {} after",
            s7(&before),
            s7(&after)
        ),
    )?;
    require(
        before.findings.len() - after.findings.len() == 1,
        "an allowlist entry must forgive one hit, not a category",
    )
}

/// A readable capture that proves too little is rc 4, not rc 0.
fn case_floor(rig: &Rig, mutation: Option<&'static str>) -> Case {
    let manifest = read_manifest(&rig.manifest_real_floors)?;
    let rules = rules_for(&manifest, Vec::new(), mutation)?;
    let drive = rig.write("floor.drive.log", CLEAN_DRIVE)?;
    let logcat = rig.write("floor.logcat.log", CLEAN_LOGCAT)?;
    let outcome = scan(
        &manifest,
        &[sink("logcat", &[&logcat]), sink("drive", &[&drive])],
        &rules,
    );
    require(
        outcome.rc() == RC_META,
        &format!(
            "an eleven-line drive transcript under a hundred-line floor must be rc 4, got rc {}",
            outcome.rc()
        ),
    )
}

/// One pass, every byte, and a printed throughput.
fn case_throughput(
    rig: &Rig,
    out: &mut dyn Write,
    probe_bytes: u64,
    mutation: Option<&'static str>,
) -> Case {
    let manifest = rig.manifest()?;
    let rules = rules_for(&manifest, Vec::new(), mutation)?;
    let mut block = String::new();
    for n in 0..512 {
        let _ = writeln!(
            block,
            "[Probe] cycle {n} settled for circle#a91f3c at epoch+1, bucket 2-4, t+{n}s"
        );
    }
    let path = rig.dir.join("throughput.drive.log");
    {
        let mut file = std::fs::File::create(&path)
            .map_err(|e| format!("cannot create the probe: {:?}", e.kind()))?;
        let block_bytes = u64::try_from(block.len()).unwrap_or(1);
        let repeats = probe_bytes / block_bytes + 1;
        for _ in 0..repeats {
            file.write_all(block.as_bytes())
                .map_err(|e| format!("cannot write the probe: {:?}", e.kind()))?;
        }
    }
    let size = std::fs::metadata(&path)
        .map_err(|e| format!("cannot stat the probe: {:?}", e.kind()))?
        .len();
    let started = std::time::Instant::now();
    let outcome = scan(&manifest, &[sink("drive", &[&path])], &rules);
    let elapsed = started.elapsed();
    let _ = std::fs::remove_file(&path);
    // Printed, never asserted: a timing floor on a shared runner is a flake, and
    // the design goal (>= 300 MB/s/core) is read off this line locally.
    // `f64::from(u32)` rather than a cast: exact for every probe this tool
    // generates, and no precision lint to silence.
    let mib = f64::from(u32::try_from(size).unwrap_or(u32::MAX)) / (1024.0 * 1024.0);
    let _ = writeln!(
        out,
        "  INFO throughput {:.1} MiB in {:.2} s = {:.0} MiB/s (measured, never asserted)",
        mib,
        elapsed.as_secs_f64(),
        mib / elapsed.as_secs_f64().max(f64::MIN_POSITIVE)
    );
    require(
        outcome.bytes_read == size,
        &format!(
            "the scanner read {} of {size} byte(s): the single streaming pass must see every byte exactly once",
            outcome.bytes_read
        ),
    )?;
    require(
        outcome.findings.is_empty(),
        "the throughput probe is also a clean-at-scale control and must produce no finding",
    )
}

/// Real furniture from a real run, every line of it a negative control.
///
/// The synthetic clean fixtures say what the author of a rule expected a log to
/// look like; these two say what a log ACTUALLY looks like. Run 34766632019
/// returned rc 1 on nothing but false positives — a Rust module path read as an
/// IPv6 literal, an enum variant read as a key blob — and each of those shapes
/// is in here now, so the next rule that would redden a real lane reddens this
/// case first, before a lane deletes its own evidence.
fn case_furniture(rig: &Rig, mutation: Option<&'static str>) -> Case {
    let manifest = rig.manifest()?;
    let rules = rules_for(&manifest, Vec::new(), mutation)?;
    let drive = rig.write("furniture.drive.log", FURNITURE_DRIVE)?;
    let logcat = rig.write("furniture.logcat.log", FURNITURE_LOGCAT)?;
    let outcome = scan(
        &manifest,
        &[sink("logcat", &[&logcat]), sink("drive", &[&drive])],
        &rules,
    );
    let where_ = |kind: FindingKind| -> Vec<String> {
        outcome
            .findings
            .iter()
            .filter(|f| f.kind == kind)
            .map(|f| {
                format!(
                    "{}:{}",
                    f.rule
                        .clone()
                        .or_else(|| f.encoding.clone())
                        .unwrap_or_default(),
                    f.line
                )
            })
            .collect()
    };
    require(
        outcome.findings.is_empty(),
        &format!(
            "real furniture produced {} finding(s): rules {:?}, needles {:?}",
            outcome.findings.len(),
            where_(FindingKind::Rule),
            where_(FindingKind::Needle)
        ),
    )?;
    require(
        outcome.lines.get("drive") == Some(&FURNITURE_DRIVE_LINES)
            && outcome.lines.get("logcat") == Some(&FURNITURE_LOGCAT_LINES),
        &format!(
            "the furniture corpus is {:?}/{:?} line(s), not the pinned {FURNITURE_DRIVE_LINES}/{FURNITURE_LOGCAT_LINES}",
            outcome.lines.get("drive"),
            outcome.lines.get("logcat")
        ),
    )
}

#[cfg(test)]
mod tests {
    use super::{run_with, SMALL_PROBE_BYTES};

    #[test]
    fn the_self_test_passes() {
        let mut out = Vec::new();
        let mut err = Vec::new();
        let result = run_with(&mut out, &mut err, SMALL_PROBE_BYTES, None);
        assert!(
            result.is_ok(),
            "{}\n{}",
            String::from_utf8_lossy(&out),
            String::from_utf8_lossy(&err)
        );
    }

    /// The mutation test: with one rule suppressed, the fixture set must go RED.
    ///
    /// A fixture set that survived a deleted rule would be reporting coverage it
    /// does not have — which is the failure mode the whole self-test exists to
    /// make impossible.
    #[test]
    fn disabling_one_rule_turns_the_self_test_red() {
        for rule in ["S1", "S5", "S10", "S12"] {
            let mut out = Vec::new();
            let mut err = Vec::new();
            let result = run_with(&mut out, &mut err, SMALL_PROBE_BYTES, Some(rule));
            assert!(
                result.is_err(),
                "suppressing {rule} left the self-test green: {}",
                String::from_utf8_lossy(&out)
            );
        }
    }
}
