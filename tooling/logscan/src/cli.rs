//! The command line: `seal`, `scan`, `plant`, `--self-test`.
//!
//! Every verb writes through the `out`/`err` handles it is given rather than
//! through `println!`, for one reason: `logscan_never_prints_a_needle` can then
//! drive every user-facing output path in-process and assert, byte for byte,
//! that no declared value reached any of them.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::expand::expand;
use crate::ledger::{reconcile, sealed_claims};
use crate::manifest::{
    add_host_decl, endpoint_spellings, parse_decl, read_manifest, validate_out_path,
    write_manifest, Declarations, Manifest, SCHEMA,
};
use crate::plants::{assert_inert, resolve_slots, DECLARED_EMITTER, PHASES};
use crate::policy::Policy;
use crate::report::{write_ndjson, write_report};
use crate::rules::{validate_allowlist, AllowEntry, RuleSet, Today};
use crate::scan::{scan_sinks, SinkArg};
use crate::selftest;
use crate::{worse, RC_CLEAN, RC_GUARD, RC_LEAK, RC_META, RC_UNUSABLE};

/// The allowlist this binary was built with.
///
/// Compiled in for the same reason the policy is: an allowlist a caller can
/// substitute at runtime is not an allowlist, it is a flag.
const ALLOWLIST_JSON: &str = include_str!("../allowlist.json");

const USAGE: &str = "\
haven-logscan — runtime log-privacy scanner

  haven-logscan seal  --run-id <id> [--decl <file.needles.decl>]...
                      [--host-decl <class>=<value>]... [--expect <class>=<min>]...
                      [--floor <sink>=<min-lines>]... [--exempt-endpoint <url|host|ip>]...
                      --out /tmp/haven-soak/needles/<run-id>.needles.json
  haven-logscan scan  --manifest <path> [--sink <class>=<path>[,<path>...]]...
                      [--segments <class>=<n>]... [--plants-in <class>=<path>]...
                      [--report <path.ndjson>] [--disclose-values]
  haven-logscan plant --manifest <path> --sink dart --phase open|close
  haven-logscan --self-test

exit: 0 clean · 1 leak · 2 guard broken · 3 unusable capture · 4 meta floor";

/// Runs one invocation. Returns the process exit code.
pub fn run(args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    match args.first().map(String::as_str) {
        Some("seal") => dispatch(seal(&args[1..], out), err),
        Some("scan") => dispatch(scan(&args[1..], out, err), err),
        Some("plant") => dispatch(plant(&args[1..], out), err),
        Some("--self-test") => match selftest::run(out, err) {
            Ok(()) => RC_CLEAN,
            Err(message) => {
                let _ = writeln!(err, "haven-logscan: self-test FAILED: {message}");
                RC_GUARD
            }
        },
        _ => {
            let _ = writeln!(err, "{USAGE}");
            RC_GUARD
        }
    }
}

/// Turns a verb's result into an exit code, printing the reason for a rc-2.
fn dispatch(result: Result<i32, String>, err: &mut dyn Write) -> i32 {
    match result {
        Ok(rc) => rc,
        Err(message) => {
            let _ = writeln!(err, "haven-logscan: {message}");
            RC_GUARD
        }
    }
}

/// A problem and the exit code it demands, collected rather than returned so one
/// run reports every defect it found.
struct Verdict {
    rc: i32,
    lines: Vec<String>,
}

impl Verdict {
    const fn new() -> Self {
        Self {
            rc: RC_CLEAN,
            lines: Vec::new(),
        }
    }

    fn note(&mut self, rc: i32, message: String) {
        self.rc = worse(self.rc, rc);
        self.lines.push(message);
    }
}

// ---------------------------------------------------------------------------
// seal
// ---------------------------------------------------------------------------

/// `seal`'s arguments, parsed.
struct SealArgs {
    run_id: String,
    decls: Vec<PathBuf>,
    host: Vec<(String, String)>,
    expect: BTreeMap<String, usize>,
    floors: BTreeMap<String, u64>,
    exempt: Vec<String>,
    output: PathBuf,
}

fn parse_seal_args(args: &[String]) -> Result<SealArgs, String> {
    let mut run_id = None;
    let mut decls: Vec<PathBuf> = Vec::new();
    let mut host: Vec<(String, String)> = Vec::new();
    let mut expect: BTreeMap<String, usize> = BTreeMap::new();
    let mut floors: BTreeMap<String, u64> = BTreeMap::new();
    let mut exempt: Vec<String> = Vec::new();
    let mut output = None;

    let mut index = 0;
    while index < args.len() {
        let flag = args[index].as_str();
        match flag {
            "--run-id" => run_id = Some(value(args, &mut index, flag)?),
            "--decl" => decls.push(PathBuf::from(value(args, &mut index, flag)?)),
            "--host-decl" => {
                let (class, raw) = pair(&value(args, &mut index, flag)?, flag)?;
                host.push((class, raw));
            }
            "--expect" => {
                let (class, raw) = pair(&value(args, &mut index, flag)?, flag)?;
                let min = raw
                    .parse()
                    .map_err(|_| format!("{flag} needs <class>=<min-count>"))?;
                expect.insert(class, min);
            }
            "--floor" => {
                let (sink, raw) = pair(&value(args, &mut index, flag)?, flag)?;
                let min = raw
                    .parse()
                    .map_err(|_| format!("{flag} needs <sink>=<min-lines>"))?;
                floors.insert(sink, min);
            }
            "--exempt-endpoint" => {
                exempt.extend(endpoint_spellings(&value(args, &mut index, flag)?));
            }
            "--out" => output = Some(PathBuf::from(value(args, &mut index, flag)?)),
            other => return Err(format!("unknown flag `{other}`\n{USAGE}")),
        }
        index += 1;
    }
    Ok(SealArgs {
        run_id: run_id.ok_or_else(|| format!("seal needs --run-id\n{USAGE}"))?,
        decls,
        host,
        expect,
        floors,
        exempt,
        output: output.ok_or_else(|| format!("seal needs --out\n{USAGE}"))?,
    })
}

fn seal(argv: &[String], out: &mut dyn Write) -> Result<i32, String> {
    let sealing = parse_seal_args(argv)?;
    validate_out_path(&sealing.output)?;

    let policy = Policy::load()?;
    for sink in sealing.floors.keys() {
        policy.sink(sink)?;
    }
    for class in sealing.expect.keys() {
        policy.class(class)?;
    }

    let mut verdict = Verdict::new();
    let mut declarations = Declarations::default();
    let mut ids = 0usize;
    let mut order = 0usize;
    for path in &sealing.decls {
        match std::fs::read_to_string(path) {
            Ok(text) => parse_decl(&policy, &text, &mut ids, &mut order, &mut declarations)?,
            Err(e) => verdict.note(
                RC_UNUSABLE,
                format!(
                    "declaration sidecar {} cannot be read [{:?}]; the channel produced no record of what the run minted",
                    path.display(),
                    e.kind()
                ),
            ),
        }
    }
    for (class, raw) in &sealing.host {
        add_host_decl(&policy, class, raw, &mut ids, &mut declarations)?;
    }

    let plants = resolve_slots(&declarations.plants)?;
    let inertness = RuleSet::new(
        policy.base64_entropy_bits,
        now_unix(),
        &sealing.exempt,
        Vec::new(),
    )?;
    for slot in &plants {
        assert_inert(&slot.token, &inertness)?;
    }

    let declared: Vec<crate::expand::Declared> = declarations
        .values
        .iter()
        .map(|(declared, _)| declared.clone())
        .collect();
    let expansion = expand(&policy, &declared)?;

    for mismatch in reconcile(&policy, &expansion) {
        verdict.note(RC_UNUSABLE, mismatch.message());
    }
    check_meta_floors(&declarations, &expansion, &sealing.expect, &mut verdict);

    if verdict.rc != RC_CLEAN {
        for line in &verdict.lines {
            let _ = writeln!(out, "{line}");
        }
        let _ = writeln!(
            out,
            "haven-logscan: NOT sealed — a manifest that proves too little must not become the basis of a clean verdict"
        );
        return Ok(verdict.rc);
    }

    let manifest = build_manifest(&policy, &sealing, &declarations, &expansion, plants);
    write_manifest(&sealing.output, &manifest)?;

    let gaps = manifest.dropped.iter().filter(|d| d.coverage_gap).count();
    // Counts and classes only. This line lands in a public CI artifact.
    let _ = writeln!(
        out,
        "haven-logscan: sealed {} value(s), {} term(s), {} dropped ({gaps} coverage gap(s)), {} plant(s), {} ledger claim(s) reconciled",
        manifest.values.len(),
        manifest.terms.len(),
        manifest.dropped.len(),
        manifest.plants.len(),
        manifest.ledger.len()
    );
    Ok(RC_CLEAN)
}

/// The rc-4 conditions: a manifest with nothing to search for, a class declared
/// fewer times than the scenario's shape requires, and a value nobody could
/// confirm was ever applied.
fn check_meta_floors(
    declarations: &Declarations,
    expansion: &crate::expand::Expansion,
    expect: &BTreeMap<String, usize>,
    verdict: &mut Verdict,
) {
    // The crate's own vacuity rule, applied to its own artifact: a manifest with
    // no searchable term would let `scan` report rc 0 having looked for nothing,
    // and the only thing standing between that and a green lane would be the
    // runner remembering to pass `--expect`.
    if expansion.terms.is_empty() {
        verdict.note(
            RC_META,
            "no searchable term was declared; a manifest that searches for nothing cannot certify a capture as clean".to_owned(),
        );
    }
    for (class, min) in expect {
        let have = declarations
            .values
            .iter()
            .filter(|(_, entry)| &entry.class == class)
            .count();
        if have < *min {
            verdict.note(
                RC_META,
                format!(
                    "declaration floor unmet: class `{class}` was declared {have} time(s), below the {min} this scenario's shape requires; a manifest that names fewer values than the run minted cannot read as complete"
                ),
            );
        }
    }
    let unconfirmed = declarations
        .values
        .iter()
        .filter(|(_, entry)| !entry.planted_confirmed)
        .count();
    if unconfirmed > 0 {
        verdict.note(
            RC_META,
            format!(
                "{unconfirmed} declared value(s) were never confirmed planted; a value the run minted but never applied proves nothing about what a log may hold"
            ),
        );
    }
}

/// Assembles the manifest from everything the seal resolved.
///
/// The sink specs, the class scoping and S4's entropy floor are COPIED from the
/// policy rather than re-read by `scan`: a policy edit between the two halves of
/// one run would otherwise change the meaning of the verdict with nothing saying
/// so.
fn build_manifest(
    policy: &Policy,
    args: &SealArgs,
    declarations: &Declarations,
    expansion: &crate::expand::Expansion,
    plants: Vec<crate::plants::PlantSlot>,
) -> Manifest {
    Manifest {
        schema: SCHEMA,
        run_id: args.run_id.clone(),
        roles: declarations.roles.clone(),
        values: declarations
            .values
            .iter()
            .map(|(_, entry)| entry.clone())
            .collect(),
        terms: expansion.terms.clone(),
        dropped: expansion.dropped.clone(),
        ledger: sealed_claims(policy, expansion),
        plants,
        floors: policy
            .sinks
            .iter()
            .map(|(name, spec)| {
                (
                    name.clone(),
                    args.floors.get(name).copied().unwrap_or(spec.min_lines),
                )
            })
            .collect(),
        expect: args.expect.clone(),
        scoped_out: policy
            .classes
            .iter()
            .map(|(name, spec)| (name.clone(), spec.scoped_out.clone()))
            .collect(),
        sinks: policy.sinks.clone(),
        base64_entropy_bits: policy.base64_entropy_bits,
        exempt_endpoints: args.exempt.clone(),
    }
}

// ---------------------------------------------------------------------------
// scan
// ---------------------------------------------------------------------------

fn scan(args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> Result<i32, String> {
    let mut manifest_path = None;
    let mut sinks: Vec<SinkArg> = Vec::new();
    let mut segments: BTreeMap<String, usize> = BTreeMap::new();
    let mut plants_in: BTreeMap<String, PathBuf> = BTreeMap::new();
    let mut report = None;
    let mut disclose = false;

    let mut index = 0;
    while index < args.len() {
        let flag = args[index].as_str();
        match flag {
            "--manifest" => manifest_path = Some(PathBuf::from(value(args, &mut index, flag)?)),
            "--sink" => {
                let (class, paths) = pair(&value(args, &mut index, flag)?, flag)?;
                sinks.push(SinkArg {
                    class,
                    paths: paths.split(',').map(PathBuf::from).collect(),
                });
            }
            "--segments" => {
                let (class, raw) = pair(&value(args, &mut index, flag)?, flag)?;
                let count = raw
                    .parse()
                    .map_err(|_| format!("{flag} needs <class>=<count>"))?;
                segments.insert(class, count);
            }
            "--plants-in" => {
                let (class, path) = pair(&value(args, &mut index, flag)?, flag)?;
                plants_in.insert(class, PathBuf::from(path));
            }
            "--report" => report = Some(PathBuf::from(value(args, &mut index, flag)?)),
            "--disclose-values" => disclose = true,
            other => return Err(format!("unknown flag `{other}`\n{USAGE}")),
        }
        index += 1;
    }

    let manifest_path = manifest_path.ok_or_else(|| format!("scan needs --manifest\n{USAGE}"))?;
    if sinks.is_empty() {
        return Err(format!("scan needs at least one --sink\n{USAGE}"));
    }
    if !manifest_path.exists() {
        let _ = writeln!(
            err,
            "haven-logscan: no manifest at {} — a scan with no manifest proves only that the structural rules ran",
            manifest_path.display()
        );
        return Ok(RC_META);
    }
    let manifest = read_manifest(&manifest_path)?;

    let allowlist: Vec<AllowEntry> = serde_json::from_str(ALLOWLIST_JSON)
        .map_err(|e| format!("the compiled-in allowlist does not parse: {e}"))?;
    if let Err(problems) = validate_allowlist(&allowlist, today(), &proof_root()) {
        for problem in &problems {
            let _ = writeln!(err, "haven-logscan: {problem}");
        }
        return Ok(RC_GUARD);
    }

    if disclose {
        let target = report
            .as_ref()
            .map_or_else(|| "this terminal".to_owned(), |p| p.display().to_string());
        let _ = writeln!(
            err,
            "haven-logscan: WARNING --disclose-values writes matched values into {target}; it is for local triage only and must never be uploaded, pasted or run in a workflow"
        );
    }

    let rules = RuleSet::new(
        manifest.base64_entropy_bits,
        now_unix(),
        &manifest.exempt_endpoints,
        allowlist,
    )?;
    let outcome = scan_sinks(&manifest, &sinks, &segments, &plants_in, &rules, disclose);
    if let Some(path) = &report {
        write_ndjson(&outcome, path)?;
    }
    write_report(&outcome, out, err)
        .map_err(|e| format!("cannot write the report: {:?}", e.kind()))?;
    let rc = outcome.rc();
    if rc == RC_LEAK {
        let _ = writeln!(
            err,
            "haven-logscan: evidence withheld by design; reproduce locally with --disclose-values and DELETE the sink rather than uploading it"
        );
    }
    Ok(rc)
}

// ---------------------------------------------------------------------------
// plant
// ---------------------------------------------------------------------------

fn plant(args: &[String], out: &mut dyn Write) -> Result<i32, String> {
    let mut manifest_path = None;
    let mut sink = None;
    let mut phase = None;
    let mut index = 0;
    while index < args.len() {
        let flag = args[index].as_str();
        match flag {
            "--manifest" => manifest_path = Some(PathBuf::from(value(args, &mut index, flag)?)),
            "--sink" => sink = Some(value(args, &mut index, flag)?),
            "--phase" => phase = Some(value(args, &mut index, flag)?),
            other => return Err(format!("unknown flag `{other}`\n{USAGE}")),
        }
        index += 1;
    }
    let manifest_path = manifest_path.ok_or_else(|| format!("plant needs --manifest\n{USAGE}"))?;
    let sink = sink.ok_or_else(|| format!("plant needs --sink\n{USAGE}"))?;
    let phase = phase.ok_or_else(|| format!("plant needs --phase\n{USAGE}"))?;
    if sink != DECLARED_EMITTER {
        return Err(format!(
            "only `{DECLARED_EMITTER}` plants are declared; the rust, kotlin and swift plants are undeclared and matched by shape, so there is no token to print for `{sink}`"
        ));
    }
    if !PHASES.contains(&phase.as_str()) {
        return Err(format!("--phase must be one of {PHASES:?}"));
    }
    let manifest = read_manifest(&manifest_path)?;
    // The token and nothing else: the harness reads this with `$(…)`.
    Ok(manifest
        .plants
        .iter()
        .find(|slot| slot.sink == sink && slot.phase == phase)
        .map_or(RC_UNUSABLE, |slot| {
            let _ = writeln!(out, "{}", slot.token);
            RC_CLEAN
        }))
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn value(args: &[String], index: &mut usize, flag: &str) -> Result<String, String> {
    *index += 1;
    args.get(*index)
        .cloned()
        .ok_or_else(|| format!("{flag} needs a value"))
}

/// Splits `key=value` at the FIRST `=`, so a base64 value keeps its padding.
fn pair(text: &str, flag: &str) -> Result<(String, String), String> {
    text.split_once('=')
        .map(|(key, raw)| (key.to_owned(), raw.to_owned()))
        .ok_or_else(|| format!("{flag} needs <key>=<value>"))
}

/// The tree an allowlist `proof` citation is resolved against.
///
/// Derived from `CARGO_MANIFEST_DIR` at BUILD time (`<repo>/tooling/logscan`, so
/// two levels up is the checkout) rather than from the process working
/// directory: a citation has to mean the same thing under `cargo test` (cwd =
/// the crate) and under `tooling/e2e/ci/scan-logs.sh` (cwd = the repo root or a
/// lane workspace), or the first real allowlist entry becomes a mid-lane rc 2.
/// If the binary is run outside its checkout the citation simply does not
/// resolve, which is rc 2 — fail-closed, as an unprovable exception should be.
fn proof_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// Today, derived from the wall clock without a date library.
///
/// Only `expires` comparisons use it, and only at day granularity: the civil
/// calendar arithmetic below is the whole reason this crate needs no `chrono`.
fn today() -> Today {
    let days = i64::try_from(now_unix() / 86_400).unwrap_or(0);
    civil_from_days(days)
}

/// Howard Hinnant's `civil_from_days`, which is exact for every day this tool
/// will ever see and is three lines of arithmetic instead of a dependency.
fn civil_from_days(days: i64) -> Today {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };
    (
        u32::try_from(year).unwrap_or(0),
        u32::try_from(m).unwrap_or(1),
        u32::try_from(d).unwrap_or(1),
    )
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};

    use super::{civil_from_days, pair, run};
    use crate::{RC_CLEAN, RC_GUARD, RC_LEAK, RC_META, RC_UNUSABLE};

    /// A scratch directory that cleans itself up, plus the sealed manifest path.
    struct Rig {
        dir: PathBuf,
        manifest: PathBuf,
    }

    impl Rig {
        fn new(tag: &str) -> Self {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.subsec_nanos());
            let stamp = format!("{}-{tag}-{nanos}", std::process::id());
            let dir = std::env::temp_dir().join(format!("haven-logscan-cli-{stamp}"));
            std::fs::create_dir_all(&dir).expect("scratch dir");
            Self {
                manifest: Path::new(crate::manifest::NEEDLE_DIR)
                    .join(format!("cli-{stamp}.needles.json")),
                dir,
            }
        }

        fn write(&self, name: &str, body: &str) -> PathBuf {
            let path = self.dir.join(name);
            std::fs::write(&path, body).expect("fixture");
            path
        }
    }

    impl Drop for Rig {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
            let _ = std::fs::remove_file(&self.manifest);
        }
    }

    fn invoke(args: &[&str]) -> (i32, String, String) {
        let owned: Vec<String> = args.iter().map(|a| (*a).to_owned()).collect();
        let mut out = Vec::new();
        let mut err = Vec::new();
        let rc = run(&owned, &mut out, &mut err);
        (
            rc,
            String::from_utf8_lossy(&out).into_owned(),
            String::from_utf8_lossy(&err).into_owned(),
        )
    }

    /// The needle every output path is checked against.
    const NEEDLE: &str = "0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9";

    fn seal_with_needle(rig: &Rig) -> String {
        let decl = rig.write(
            "alice.needles.decl",
            &format!(
                "{{\"class\":\"pubkey\",\"value\":\"{NEEDLE}\",\"role\":\"alice\",\"seq\":1}}\n"
            ),
        );
        let (rc, out, err) = invoke(&[
            "seal",
            "--run-id",
            "cli-test",
            "--decl",
            decl.to_str().expect("utf8"),
            "--floor",
            "drive=1",
            "--out",
            rig.manifest.to_str().expect("utf8"),
        ]);
        assert_eq!(rc, RC_CLEAN, "seal failed: {out}{err}");
        format!("{out}{err}")
    }

    /// Security Rule 15 applies to this tool's own stdout and stderr.
    #[test]
    fn logscan_never_prints_a_needle() {
        let rig = Rig::new("rule15");
        let mut transcript = seal_with_needle(&rig);

        // A sink that actually holds the needle, in two encodings, so the scan
        // takes the reporting path rather than the clean one.
        let dirty = rig.write(
            "drive.log",
            &format!(
                "flutter: pubkey {NEEDLE}\nflutter: prefix {}\nflutter: {}\n",
                &NEEDLE[..16],
                plant_token(&rig)
            ),
        );
        let report = rig.dir.join("report.ndjson");
        let (rc, out, err) = invoke(&[
            "scan",
            "--manifest",
            rig.manifest.to_str().expect("utf8"),
            "--sink",
            &format!("drive={}", dirty.display()),
            "--report",
            report.to_str().expect("utf8"),
        ]);
        assert_eq!(rc, RC_LEAK, "the dirty sink must read as a leak");
        transcript.push_str(&out);
        transcript.push_str(&err);
        transcript.push_str(&std::fs::read_to_string(&report).expect("report"));

        // The one path the earlier version did not walk: an app-authored
        // `class` field. The DECL payload is app-controlled text, so a harness
        // bug that put a pubkey there must not print it.
        let poisoned = rig.write(
            "poisoned.needles.decl",
            &format!("{{\"class\":\"{NEEDLE}\",\"value\":\"{NEEDLE}\"}}\n"),
        );
        let (rc, out, err) = invoke(&[
            "seal",
            "--run-id",
            "poisoned",
            "--decl",
            poisoned.to_str().expect("utf8"),
            // A path-legal target: the class error must be what stops this seal,
            // not the path rule, or the test would prove the wrong refusal.
            "--out",
            rig.manifest.to_str().expect("utf8"),
        ]);
        assert_eq!(rc, RC_GUARD, "an undeclared class is a broken producer");
        assert!(
            err.contains("does not declare"),
            "the class path must be what refused it: {err}"
        );
        transcript.push_str(&out);
        transcript.push_str(&err);

        // Every `plant` output path too.
        for phase in ["open", "close"] {
            let (_, out, err) = invoke(&[
                "plant",
                "--manifest",
                rig.manifest.to_str().expect("utf8"),
                "--sink",
                "dart",
                "--phase",
                phase,
            ]);
            transcript.push_str(&out);
            transcript.push_str(&err);
        }

        assert!(
            !transcript.contains(NEEDLE),
            "an output path printed the whole needle"
        );
        assert!(
            !transcript.contains(&NEEDLE[..8]),
            "an output path printed an 8-character prefix of the needle, which is still a join key"
        );
    }

    #[test]
    fn disclose_values_is_the_only_path_that_prints_the_value_and_it_warns() {
        let rig = Rig::new("disclose");
        seal_with_needle(&rig);
        let dirty = rig.write("drive.log", &format!("flutter: pubkey {NEEDLE}\n"));
        let report = rig.dir.join("report.ndjson");
        let (rc, _, err) = invoke(&[
            "scan",
            "--manifest",
            rig.manifest.to_str().expect("utf8"),
            "--sink",
            &format!("drive={}", dirty.display()),
            "--report",
            report.to_str().expect("utf8"),
            "--disclose-values",
        ]);
        assert_eq!(rc, RC_LEAK);
        assert!(err.contains("WARNING --disclose-values"), "{err}");
        assert!(
            err.contains(report.to_str().expect("utf8")),
            "the warning must name the file it writes: {err}"
        );
        let body = std::fs::read_to_string(&report).expect("report");
        assert!(body.contains(NEEDLE), "disclosure must actually disclose");
    }

    fn plant_token(rig: &Rig) -> String {
        let (rc, out, err) = invoke(&[
            "plant",
            "--manifest",
            rig.manifest.to_str().expect("utf8"),
            "--sink",
            "dart",
            "--phase",
            "open",
        ]);
        assert_eq!(rc, RC_CLEAN, "{err}");
        out.trim().to_owned()
    }

    #[test]
    fn the_plant_verb_prints_the_token_and_nothing_else() {
        let rig = Rig::new("plantverb");
        seal_with_needle(&rig);
        let (rc, out, _) = invoke(&[
            "plant",
            "--manifest",
            rig.manifest.to_str().expect("utf8"),
            "--sink",
            "dart",
            "--phase",
            "open",
        ]);
        assert_eq!(rc, RC_CLEAN);
        assert_eq!(out.lines().count(), 1, "exactly one line: {out}");
        assert!(crate::plants::shape_regex().is_match(out.trim()), "{out}");
    }

    #[test]
    fn a_plant_for_a_shape_matched_emitter_is_refused() {
        let rig = Rig::new("plantshape");
        seal_with_needle(&rig);
        let (rc, _, err) = invoke(&[
            "plant",
            "--manifest",
            rig.manifest.to_str().expect("utf8"),
            "--sink",
            "kotlin",
            "--phase",
            "open",
        ]);
        assert_eq!(rc, RC_GUARD);
        assert!(err.contains("matched by shape"), "{err}");
    }

    #[test]
    fn a_manifest_path_outside_the_needle_directory_is_refused() {
        let rig = Rig::new("path");
        let bad = rig.dir.join("run.needles.json");
        let (rc, _, err) = invoke(&[
            "seal",
            "--run-id",
            "x",
            "--out",
            bad.to_str().expect("utf8"),
        ]);
        assert_eq!(rc, RC_GUARD);
        assert!(err.contains("/tmp/haven-soak/needles"), "{err}");
    }

    #[test]
    fn a_declaration_floor_unmet_seals_nothing() {
        let rig = Rig::new("floor");
        let decl = rig.write(
            "alice.needles.decl",
            &format!("{{\"class\":\"pubkey\",\"value\":\"{NEEDLE}\"}}\n"),
        );
        let (rc, out, _) = invoke(&[
            "seal",
            "--run-id",
            "x",
            "--decl",
            decl.to_str().expect("utf8"),
            "--expect",
            "pubkey=2",
            "--out",
            rig.manifest.to_str().expect("utf8"),
        ]);
        assert_eq!(rc, RC_META);
        assert!(out.contains("declaration floor unmet"), "{out}");
        assert!(
            !rig.manifest.exists(),
            "a manifest that proves too little must not be written"
        );
    }

    #[test]
    fn a_value_that_was_never_confirmed_planted_seals_nothing() {
        // A value the run minted but never applied proves nothing about what a
        // log may hold, so it is rc 4 and no manifest — the same verdict as an
        // unmet declaration floor, and a listed promise of the exit taxonomy.
        let rig = Rig::new("unconfirmed");
        let decl = rig.write(
            "alice.needles.decl",
            &format!(
                "{{\"class\":\"pubkey\",\"value\":\"{NEEDLE}\",\"planted_confirmed\":false}}\n"
            ),
        );
        let (rc, out, _) = invoke(&[
            "seal",
            "--run-id",
            "x",
            "--decl",
            decl.to_str().expect("utf8"),
            "--out",
            rig.manifest.to_str().expect("utf8"),
        ]);
        assert_eq!(rc, RC_META);
        assert!(out.contains("never confirmed planted"), "{out}");
        assert!(!rig.manifest.exists());
    }

    #[test]
    fn a_manifest_with_no_searchable_term_seals_nothing() {
        // Plants only: the declaration channel produced no needle, so a scan
        // would report rc 0 having searched for nothing.
        let rig = Rig::new("noterms");
        let decl = rig.write(
            "alice.needles.decl",
            "{\"class\":\"plant\",\"value\":\"logscan-plant-dart-open-ABCDEFGHJK\",\"sink\":\"dart\",\"phase\":\"open\",\"seq\":1}\n",
        );
        let (rc, out, _) = invoke(&[
            "seal",
            "--run-id",
            "x",
            "--decl",
            decl.to_str().expect("utf8"),
            "--out",
            rig.manifest.to_str().expect("utf8"),
        ]);
        assert_eq!(rc, RC_META);
        assert!(out.contains("searches for nothing"), "{out}");
        assert!(!rig.manifest.exists());
    }

    #[test]
    fn the_allowlist_proof_root_is_the_checkout_not_the_working_directory() {
        // The root is derived at build time, so a citation means the same thing
        // whatever directory the lane runs from.
        let root = super::proof_root();
        assert!(
            root.join("tooling/logscan/Cargo.toml").is_file(),
            "the proof root must be the checkout containing this crate: {}",
            root.display()
        );
    }

    #[test]
    fn an_absent_sink_is_unusable_and_an_absent_manifest_is_a_meta_floor() {
        let rig = Rig::new("absent");
        seal_with_needle(&rig);
        let (rc, _, err) = invoke(&[
            "scan",
            "--manifest",
            rig.manifest.to_str().expect("utf8"),
            "--sink",
            &format!("drive={}", rig.dir.join("never-written.log").display()),
        ]);
        assert_eq!(rc, RC_UNUSABLE);
        assert!(err.contains("[absent]"), "{err}");

        let (rc, _, err) = invoke(&[
            "scan",
            "--manifest",
            rig.dir.join("nope.needles.json").to_str().expect("utf8"),
            "--sink",
            "drive=/dev/null",
        ]);
        assert_eq!(rc, RC_META);
        assert!(err.contains("no manifest"), "{err}");
    }

    #[test]
    fn an_empty_sink_is_as_fatal_as_an_absent_one() {
        let rig = Rig::new("empty");
        seal_with_needle(&rig);
        let empty = rig.write("drive.log", "");
        let (rc, _, err) = invoke(&[
            "scan",
            "--manifest",
            rig.manifest.to_str().expect("utf8"),
            "--sink",
            &format!("drive={}", empty.display()),
        ]);
        assert_eq!(rc, RC_UNUSABLE);
        assert!(err.contains("[empty]"), "{err}");
    }

    #[test]
    fn unknown_flags_and_missing_values_are_guard_failures() {
        assert_eq!(invoke(&["seal", "--nope"]).0, RC_GUARD);
        assert_eq!(invoke(&["seal", "--run-id"]).0, RC_GUARD);
        assert_eq!(invoke(&["scan"]).0, RC_GUARD);
        assert_eq!(invoke(&[]).0, RC_GUARD);
        assert_eq!(invoke(&["frobnicate"]).0, RC_GUARD);
    }

    #[test]
    fn a_key_value_flag_splits_at_the_first_equals_so_base64_keeps_its_padding() {
        let (class, raw) = pair("secret=AAAA==", "--host-decl").expect("split");
        assert_eq!(class, "secret");
        assert_eq!(raw, "AAAA==");
    }

    #[test]
    fn the_date_arithmetic_matches_known_days() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(19_723), (2024, 1, 1));
        assert_eq!(civil_from_days(20_000), (2024, 10, 4));
    }
}
