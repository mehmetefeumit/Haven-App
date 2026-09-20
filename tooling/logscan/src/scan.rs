//! The streaming scanner.
//!
//! One pass per file: 1 MiB chunks carrying `max_term_len − 1` bytes of overlap
//! so a term straddling a chunk boundary is still found, one case-insensitive
//! Aho-Corasick automaton over the hex/bech32/name/coordinate/URL terms, one
//! case-sensitive automaton over the base64 terms (base64 is the one encoding
//! where case is information), and one `RegexSet` for the structural rules.
//!
//! # What is scanned where
//!
//! * **terminal escapes** — removed from every byte of every sink before any
//!   matching, needles and rules alike ([`strip_escapes`]).
//! * **needles** — every line of every file, because a declared value in a
//!   vendor line is still a disclosure in an uploaded artifact. Class scoping
//!   (`relay` holds pubkeys legitimately) and the sink's term floor do the
//!   narrowing.
//! * **rules** — Haven-owned lines only, and never on a `relay` sink. For
//!   `logcat` and `ios` they see the MESSAGE BODY rather than the whole line
//!   (the host's own timestamp is a documented residual, not a Haven leak); for
//!   `plain` sinks the body IS the line, framing included.
//! * **cross-entry reassembly** — `logcat` only. `android_logger` chunks a
//!   record at ~4000 B and Kotlin's `Log.*` has its own per-entry cap, so
//!   consecutive entries sharing pid/tid/tag are re-joined with each entry's
//!   whitespace runs collapsed to one space — including the leading run, which
//!   is what keeps `hex-spaced`, `debug-array` and Rust's multi-line `{:#x?}`
//!   dump matchable across a split — and a hit is reported only when it SPANS a
//!   join, since anything else was already found on its own line.

use std::borrow::Cow;
use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use aho_corasick::{AhoCorasick, AhoCorasickBuilder, MatchKind};
use regex::Regex;

use crate::expand::Term;
use crate::manifest::Manifest;
use crate::plants::{self, DeclaredPlants, PlantSlot};
use crate::policy::{CargoStatus, EntryFormat, SinkSpec};
use crate::rules::RuleSet;
use crate::{worse, RC_CLEAN, RC_GUARD, RC_LEAK, RC_META, RC_UNUSABLE};

/// Bytes read per `read` call.
const CHUNK: usize = 1 << 20;

/// How much of one logical line is kept for rule evaluation. A multi-megabyte
/// line is still scanned for needles in full by the window pass; only the rule
/// view is capped, so one pathological line cannot cost unbounded memory.
const LINE_CAP: usize = 1 << 20;

/// How much reassembled text is held before it is matched and cleared.
const REASSEMBLY_CAP: usize = 256 * 1024;

/// `ESC`, which opens every sequence [`strip_escapes`] removes.
const ESC: u8 = 0x1b;

/// One `--sink <class>=<path>[,<path>…]`.
#[derive(Clone, Debug)]
pub struct SinkArg {
    /// The sink class.
    pub class: String,
    /// The files, in the order given.
    pub paths: Vec<PathBuf>,
}

/// What a scan is entitled to conclude.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ScanMode {
    /// A sealed manifest: needle terms, positive controls, structural rules and
    /// line floors.
    #[default]
    Full,
    /// No manifest: the structural rules and the line floors, and nothing else.
    /// It certifies that the rules RAN over the capture — never that the values
    /// a run minted are absent from it, because none were declared.
    RulesOnly,
}

/// Whether a finding came from a needle term or a structural rule.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FindingKind {
    /// A declared value, in some encoding.
    Needle,
    /// A structural shape.
    Rule,
}

/// One reportable hit.
#[derive(Clone, Debug)]
pub struct Finding {
    /// The file.
    pub sink: PathBuf,
    /// 1-based line number. For a reassembled hit, the first line of the run.
    pub line: u64,
    /// Needle or rule.
    pub kind: FindingKind,
    /// The needle class.
    pub class: Option<String>,
    /// The encoding label.
    pub encoding: Option<String>,
    /// The rule id.
    pub rule: Option<String>,
    /// Who emitted the line: the logcat tag for a `logcat` sink (Haven's own
    /// only — an Android tag is free text the emitter composes per call), and
    /// `<process>/<subsystem-or-library>` for an `ios` one, owned or not, so a
    /// hit in a device-wide `log show` names the program to go and look at.
    /// `None` elsewhere: a `plain` line's PREFIX can carry remote-authored
    /// text, which Rule 15 forbids printing.
    pub tag: Option<String>,
    /// How many times on that line.
    pub count: u64,
    /// The matched text, kept only when `--disclose-values` was passed.
    pub matched: Option<String>,
    /// Whether the hit was only visible after cross-entry reassembly.
    pub reassembled: bool,
}

/// Something that makes the run's verdict something other than clean or leaking.
#[derive(Clone, Debug)]
pub struct Problem {
    /// The exit code this problem demands.
    pub rc: i32,
    /// The operator-facing sentence. Counts, classes and paths only.
    pub message: String,
}

/// Everything one scan concluded.
#[derive(Debug, Default)]
pub struct Outcome {
    /// The hits.
    pub findings: Vec<Finding>,
    /// The non-leak problems.
    pub problems: Vec<Problem>,
    /// Total bytes read, which the self-test asserts equals the files' size.
    pub bytes_read: u64,
    /// Lines per sink class.
    pub lines: BTreeMap<String, u64>,
    /// Sink classes whose capture carried the class's proof-of-run line.
    pub proven: std::collections::BTreeSet<String>,
    /// Declared plants caught, out of those required.
    pub plants_caught: usize,
    /// Declared plant requirements.
    pub plants_required: usize,
    /// What this scan was entitled to conclude, which the report says out loud.
    pub mode: ScanMode,
    /// Whether the sealed run had a channel to hand the app a Dart token. A
    /// `plants 0/0` under `none` is a run with no channel, not a run whose
    /// controls all passed, and the summary has to be able to tell them apart.
    pub declared_plants: crate::plants::DeclaredPlants,
}

impl Outcome {
    /// The aggregated exit code.
    #[must_use]
    pub fn rc(&self) -> i32 {
        let mut rc = if self.findings.is_empty() {
            RC_CLEAN
        } else {
            RC_LEAK
        };
        for problem in &self.problems {
            rc = worse(rc, problem.rc);
        }
        rc
    }
}

/// The automatons for one sink class.
struct Needles<'a> {
    /// Terms in index order: the case-insensitive ones first, then the
    /// case-sensitive ones.
    terms: Vec<&'a Term>,
    ci: Option<AhoCorasick>,
    ci_count: usize,
    cs: Option<AhoCorasick>,
    max_len: usize,
}

impl<'a> Needles<'a> {
    /// Builds the automatons for `class`, honouring class scoping and the sink's
    /// term floor.
    fn build(manifest: &'a Manifest, class: &str, spec: &SinkSpec) -> Result<Self, String> {
        let mut insensitive = Vec::new();
        let mut sensitive = Vec::new();
        for term in &manifest.terms {
            let scoped_out = manifest
                .scoped_out
                .get(&term.class)
                .is_some_and(|sinks| sinks.iter().any(|s| s == class));
            if scoped_out || term.text.chars().count() < spec.term_floor {
                continue;
            }
            if term.case_sensitive {
                sensitive.push(term);
            } else {
                insensitive.push(term);
            }
        }
        let max_len = insensitive
            .iter()
            .chain(sensitive.iter())
            .map(|t| t.text.len())
            .max()
            .unwrap_or(0);
        // `MatchKind::Standard` is required for overlapping iteration, and
        // overlapping iteration is required because one occurrence legitimately
        // satisfies several labels (a hex prefix sits inside the full hex).
        let build = |terms: &[&Term], insensitive: bool| -> Result<Option<AhoCorasick>, String> {
            if terms.is_empty() {
                return Ok(None);
            }
            AhoCorasickBuilder::new()
                .match_kind(MatchKind::Standard)
                .ascii_case_insensitive(insensitive)
                .build(terms.iter().map(|t| t.text.as_bytes()))
                .map(Some)
                .map_err(|e| format!("cannot build the needle automaton: {e}"))
        };
        let ci = build(&insensitive, true)?;
        let cs = build(&sensitive, false)?;
        let ci_count = insensitive.len();
        let mut terms = insensitive;
        terms.extend(sensitive);
        Ok(Self {
            terms,
            ci,
            ci_count,
            cs,
            max_len,
        })
    }

    const fn is_empty(&self) -> bool {
        self.terms.is_empty()
    }

    /// Every match in `haystack`, as `(term index, start, end)`.
    fn matches(&self, haystack: &[u8]) -> Vec<(usize, usize, usize)> {
        let mut out = Vec::new();
        if let Some(ci) = &self.ci {
            for found in ci.find_overlapping_iter(haystack) {
                out.push((found.pattern().as_usize(), found.start(), found.end()));
            }
        }
        if let Some(cs) = &self.cs {
            for found in cs.find_overlapping_iter(haystack) {
                out.push((
                    self.ci_count + found.pattern().as_usize(),
                    found.start(),
                    found.end(),
                ));
            }
        }
        out
    }
}

/// What one file yielded.
#[derive(Default)]
struct FileReport {
    bytes: u64,
    lines: u64,
    /// Lines a framed sink (`logcat`, `ios`) could actually parse. Zero of them
    /// in a non-empty file means the capture is not in the format the sink
    /// class frames, so no structural rule ran over any of it.
    framed: u64,
    /// Whether a line matched the sink class's `proof_of_run`.
    proof_of_run: bool,
    /// `(term index, line, reassembled)` → `(count, sample)`.
    needles: BTreeMap<(usize, u64, bool), (u64, String)>,
    /// `(rule, line, tag)` → `(count, sample)`.
    rules: BTreeMap<(&'static str, u64, Option<String>), (u64, String)>,
    /// Plant token → occurrences.
    plants: BTreeMap<String, u64>,
    /// The tag of a line that produced a needle finding, so the report can name
    /// it. Bounded by the FINDINGS rather than by the owned lines: a soak-tier
    /// logcat has millions of the latter and a handful of the former.
    tags: BTreeMap<u64, String>,
    /// Needle classes the line's own EMITTER is the source of, for the lines
    /// that produced a needle finding. Bounded the same way.
    emitter_scoped: BTreeMap<u64, Vec<String>>,
}

/// The accumulator that re-joins a chunked logcat record.
#[derive(Default)]
struct Reassembly {
    key: Option<(String, String, String)>,
    buf: Vec<u8>,
    boundaries: Vec<usize>,
    first_line: u64,
    tag: Option<String>,
}

/// Scans every named sink.
///
/// `plants_in` restricts plant reconciliation to one file per class (the lane
/// passes its final-attempt drive slice, while both drive files are still scanned
/// for needles).
///
/// Under [`ScanMode::RulesOnly`] the manifest declares nothing, so there are no
/// needles to search and no positive controls to reconcile; the structural rules
/// and the line floors are the whole verdict.
#[must_use]
pub fn scan_sinks(
    manifest: &Manifest,
    sinks: &[SinkArg],
    segments: &BTreeMap<String, usize>,
    plants_in: &BTreeMap<String, PathBuf>,
    rules: &RuleSet,
    disclose: bool,
    mode: ScanMode,
) -> Outcome {
    let mut outcome = Outcome {
        mode,
        declared_plants: manifest.declared_plants,
        ..Outcome::default()
    };
    let plant_shape = plants::shape_regex();
    // `(sink class, token)` → occurrences, so "present in logcat AND in drive"
    // is answerable rather than merely "present somewhere".
    let mut plant_counts: BTreeMap<(String, String), u64> = BTreeMap::new();
    let mut shape_seen: BTreeMap<String, Vec<String>> = BTreeMap::new();

    for (class, want) in segments {
        let have = sinks
            .iter()
            .filter(|s| &s.class == class)
            .map(|s| s.paths.len())
            .sum::<usize>();
        if have != *want {
            outcome.problems.push(Problem {
                rc: RC_UNUSABLE,
                message: format!(
                    "sink class `{class}` was declared to have {want} segment(s) but {have} were named; a rotated segment nobody scanned is a segment nobody read"
                ),
            });
        }
    }

    for (class, path) in plants_in {
        let known = sinks
            .iter()
            .filter(|s| &s.class == class)
            .any(|s| s.paths.contains(path));
        if !known {
            outcome.problems.push(Problem {
                rc: RC_GUARD,
                message: format!(
                    "--plants-in names a file for class `{class}` that is not among that class's --sink paths"
                ),
            });
        }
    }

    for sink in sinks {
        let Some(spec) = manifest.sinks.get(&sink.class).cloned() else {
            outcome.problems.push(Problem {
                rc: RC_GUARD,
                message: format!("`{}` is not a sink class the manifest knows", sink.class),
            });
            continue;
        };
        let needles = match Needles::build(manifest, &sink.class, &spec) {
            Ok(needles) => needles,
            Err(message) => {
                outcome.problems.push(Problem {
                    rc: RC_GUARD,
                    message,
                });
                continue;
            }
        };
        let Ok(proof) = spec.proof_of_run.as_deref().map(Regex::new).transpose() else {
            outcome.problems.push(Problem {
                rc: RC_GUARD,
                message: format!(
                    "sink class `{}` declares a proof-of-run pattern that is not a valid regular expression",
                    sink.class
                ),
            });
            continue;
        };
        let mut tally = PlantTally {
            counts: &mut plant_counts,
            shapes: &mut shape_seen,
            shape: &plant_shape,
        };
        for path in &sink.paths {
            scan_one(
                &SinkFile {
                    class: &sink.class,
                    path,
                    spec: &spec,
                    needles: &needles,
                    rules,
                    disclose,
                    proof: proof.as_ref(),
                    reconcile_plants: plants_in.get(&sink.class).is_none_or(|only| only == path),
                },
                &mut tally,
                &mut outcome,
            );
        }
    }

    check_floors(manifest, sinks, &mut outcome);
    check_proofs_of_run(manifest, sinks, &mut outcome);
    if mode == ScanMode::Full {
        check_plants(manifest, sinks, &plant_counts, &shape_seen, &mut outcome);
    }
    outcome
}

/// One file of one sink class, and everything needed to scan it.
struct SinkFile<'a> {
    class: &'a str,
    path: &'a Path,
    spec: &'a SinkSpec,
    needles: &'a Needles<'a>,
    rules: &'a RuleSet,
    disclose: bool,
    /// The sink class's compiled `proof_of_run`, where it declares one.
    proof: Option<&'a Regex>,
    /// Whether plants found here count. `--plants-in` narrows reconciliation to
    /// one file of the class while every file is still searched for needles.
    reconcile_plants: bool,
}

/// The plant tallies a scan accumulates across files.
struct PlantTally<'a> {
    counts: &'a mut BTreeMap<(String, String), u64>,
    shapes: &'a mut BTreeMap<String, Vec<String>>,
    shape: &'a Regex,
}

/// Scans one file into `outcome`.
fn scan_one(file: &SinkFile<'_>, tally: &mut PlantTally<'_>, outcome: &mut Outcome) {
    if let Err(message) = usable(file.path) {
        outcome.problems.push(Problem {
            rc: RC_UNUSABLE,
            message,
        });
        return;
    }
    let report = match scan_file(
        file.path,
        file.spec,
        file.needles,
        file.rules,
        tally.shape,
        file.proof,
        file.disclose,
    ) {
        Ok(report) => report,
        Err(message) => {
            outcome.problems.push(Problem {
                rc: RC_UNUSABLE,
                message,
            });
            return;
        }
    };
    outcome.bytes_read += report.bytes;
    *outcome.lines.entry(file.class.to_owned()).or_default() += report.lines;
    if report.proof_of_run {
        outcome.proven.insert(file.class.to_owned());
    }

    // A framed sink whose every line failed to parse is a capture in a rendering
    // this sink class does not know — a different `log show --style`, a logcat
    // without `-v threadtime`. Nothing else would say so: the rules simply skip
    // every line and the file reads as clean. That is the one failure mode a
    // scanner must never render as a pass, so it is the capture's rc, not the
    // app's.
    if file.spec.entry_format != EntryFormat::Plain && report.lines > 0 && report.framed == 0 {
        outcome.problems.push(Problem {
            rc: RC_UNUSABLE,
            message: format!(
                "no line of {} parsed as `{}` framing; the capture is in a rendering this sink class does not know, so no structural rule ran over any of it",
                file.path.display(),
                file.class
            ),
        });
    }

    if file.reconcile_plants {
        for (token, count) in &report.plants {
            *tally
                .counts
                .entry((file.class.to_owned(), token.clone()))
                .or_default() += *count;
            // Keyed on emitter AND phase: the undeclared plants are `open`
            // plants, and a `close` token would not prove the backend was
            // installed at launch.
            if let Some((emitter, phase)) = tally.shape.captures(token).and_then(|c| {
                c.get(1)
                    .map(|m| m.as_str().to_owned())
                    .zip(c.get(2).map(|m| m.as_str().to_owned()))
            }) {
                tally
                    .shapes
                    .entry(file.class.to_owned())
                    .or_default()
                    .push(format!("{emitter}-{phase}"));
            }
        }
    }

    for ((index, line, reassembled), (count, sample)) in report.needles {
        let term = file.needles.terms[index];
        // The record's own emitter is the SOURCE of this class, not a place the
        // value leaked to: the location daemon has to know the position the
        // lane injected in order to deliver it. Only the classes that emitter
        // declares, only on its own records, and only here — the same value
        // under a Haven emitter is still a finding.
        if report
            .emitter_scoped
            .get(&line)
            .is_some_and(|classes| classes.contains(&term.class))
        {
            continue;
        }
        outcome.findings.push(Finding {
            sink: file.path.to_path_buf(),
            line,
            kind: FindingKind::Needle,
            class: Some(term.class.clone()),
            encoding: Some(term.encoding.clone()),
            rule: None,
            tag: report.tags.get(&line).cloned(),
            count,
            matched: file.disclose.then_some(sample),
            reassembled,
        });
    }
    for ((rule, line, tag), (count, sample)) in report.rules {
        outcome.findings.push(Finding {
            sink: file.path.to_path_buf(),
            line,
            kind: FindingKind::Rule,
            class: None,
            encoding: None,
            rule: Some(rule.to_owned()),
            tag,
            count,
            matched: file.disclose.then_some(sample),
            reassembled: false,
        });
    }
}

/// The four usability failures, each named: "the log is missing" and "the log is
/// clean" demand opposite responses.
fn usable(path: &Path) -> Result<(), String> {
    // `metadata`, not `symlink_metadata`: a lane may legitimately point the
    // scanner at a symlinked capture, and the semantics have to match the bash
    // scanner's `[[ -f ]]` so one file cannot be usable to one scanner and not
    // to the other.
    let meta = std::fs::metadata(path).map_err(|_| {
        format!(
            "UNUSABLE: {} [absent] — nothing was scanned",
            path.display()
        )
    })?;
    if !meta.is_file() {
        return Err(format!(
            "UNUSABLE: {} [not a regular file] — refusing to treat it as a scanned log",
            path.display()
        ));
    }
    if meta.len() == 0 {
        // Deliberately as fatal as absent: `cmd > file &` creates the file at
        // redirection time, so the same crash leaves 0 bytes or no file at all
        // depending on scheduling, and a verdict decided by scheduling is not a
        // verdict.
        return Err(format!(
            "UNUSABLE: {} [empty] — 0 bytes; the capture never wrote anything",
            path.display()
        ));
    }
    std::fs::File::open(path).map(|_| ()).map_err(|_| {
        format!(
            "UNUSABLE: {} [unreadable] — nothing was scanned",
            path.display()
        )
    })
}

fn check_floors(manifest: &Manifest, sinks: &[SinkArg], outcome: &mut Outcome) {
    let classes: std::collections::BTreeSet<&String> = sinks.iter().map(|s| &s.class).collect();
    for class in classes {
        let floor = manifest.floor(class);
        let lines = outcome.lines.get(class).copied().unwrap_or(0);
        if lines < floor {
            outcome.problems.push(Problem {
                rc: RC_META,
                message: format!(
                    "sink class `{class}` holds {lines} line(s), below its declared floor of {floor}; the capture is readable but proves too little"
                ),
            });
        }
    }
}

/// The other half of the anti-vacuity check, for the classes that can carry it.
///
/// A line floor answers "was the capture truncated"; it cannot answer "did the
/// subject ever run", because the two look identical at the short end. A class
/// that declares a `proof_of_run` answers the second question from a line its
/// producer writes before the first test body does.
fn check_proofs_of_run(manifest: &Manifest, sinks: &[SinkArg], outcome: &mut Outcome) {
    let classes: std::collections::BTreeSet<&String> = sinks.iter().map(|s| &s.class).collect();
    for class in classes {
        if manifest.proof_of_run(class).is_none() || outcome.proven.contains(class) {
            continue;
        }
        outcome.problems.push(Problem {
            rc: RC_META,
            message: format!(
                "sink class `{class}` carries no line any test reporter writes per test (`HH:MM +N:` from the compact reporter, `✅` or `::group::✅` from the github one); the capture is readable but proves too little: no test ever started"
            ),
        });
    }
}

fn check_plants(
    manifest: &Manifest,
    sinks: &[SinkArg],
    counts: &BTreeMap<(String, String), u64>,
    shape_seen: &BTreeMap<String, Vec<String>>,
    outcome: &mut Outcome,
) {
    let classes: std::collections::BTreeSet<&str> =
        sinks.iter().map(|s| s.class.as_str()).collect();
    // The Dart plant is `debugPrint`ed, so it reaches the drive transcript and
    // whichever device log the platform writes. WHICH classes must carry it is
    // the policy's `declared_plants_expected`, read here rather than listed
    // here: the one place that answer is written down is the policy, where a
    // reviewer sees it next to the reason.
    let declared_classes: Vec<&str> = classes
        .iter()
        .copied()
        .filter(|class| {
            manifest
                .sinks
                .get(*class)
                .is_some_and(|spec| spec.declared_plants_expected)
        })
        .collect();

    let declared: Vec<&PlantSlot> = manifest.plants.iter().collect();
    outcome.plants_required = declared.len() * declared_classes.len();
    for slot in &declared {
        for class in &declared_classes {
            let seen = counts
                .get(&((*class).to_owned(), slot.token.clone()))
                .copied()
                .unwrap_or(0);
            if seen == 0 {
                outcome.problems.push(Problem {
                    rc: RC_UNUSABLE,
                    message: format!(
                        "positive control missed: the declared `{}` `{}` plant appears in no `{class}` sink — either that file is not the file the run wrote, or the capture died before the `{}` plant",
                        slot.sink, slot.phase, slot.phase
                    ),
                });
            } else {
                outcome.plants_caught += 1;
            }
        }
    }

    // A plant-shaped Dart token that matches no declaration means a declaration
    // was lost on the way to the sidecar, which is exactly the channel failure
    // the plants exist to detect — and only a run that HAD a sidecar can suffer
    // it. `LogNeedles.plant` prints its token unconditionally and declares it
    // only where a recorder channel exists, so under a channel-less manifest an
    // undeclared token is the harness working as designed and this rule's
    // premise is false; asserting it anyway made every green host lane rc 3.
    // What keeps that from being a quiet waiver is `refuse_mislabelled_channel`:
    // a manifest claiming `none` beside a sidecar never reaches a scan.
    if manifest.declared_plants != DeclaredPlants::None {
        let known: std::collections::BTreeSet<&str> = manifest
            .plants
            .iter()
            .flat_map(|slot| {
                std::iter::once(slot.token.as_str())
                    .chain(slot.superseded.iter().map(String::as_str))
            })
            .collect();
        for (_, token) in counts.keys() {
            if token.starts_with("logscan-plant-dart-") && !known.contains(token.as_str()) {
                outcome.problems.push(Problem {
                    rc: RC_UNUSABLE,
                    message: "a Dart plant token in a scanned sink matches no declaration; a declaration was lost between the app and the sidecar".to_owned(),
                });
            }
        }
    }

    for class in classes {
        let Some(spec) = manifest.sinks.get(class) else {
            continue;
        };
        for emitter in &spec.required_shape_plants {
            let wanted = format!("{emitter}-open");
            let seen = shape_seen
                .get(class)
                .is_some_and(|seen| seen.iter().any(|candidate| candidate == &wanted));
            if !seen {
                outcome.problems.push(Problem {
                    rc: RC_UNUSABLE,
                    message: format!(
                        "positive control missed: sink class `{class}` carries no `{emitter}` opening plant — that emitter's log backend did not reach this capture"
                    ),
                });
            }
        }
    }
}

/// The needle pass's state between chunks: the tail of the previous window and
/// how many newlines the file holds before it.
struct WindowState {
    carry: Vec<u8>,
    newlines_before_carry: u64,
    /// `max_term_len − 1` — the largest straddle a term can have, by
    /// construction, so no term can cross two boundaries.
    overlap: usize,
}

/// Runs both automatons over the previous overlap plus this chunk.
///
/// Records every match whose END reaches into the fresh bytes (a match entirely
/// inside the carry was already reported by the window that first held it),
/// attributes it to its 1-based line, and notes that line in `needle_lines` so
/// the line pass knows which tags are worth remembering.
fn match_window(
    state: &mut WindowState,
    fresh: &[u8],
    needles: &Needles<'_>,
    disclose: bool,
    needle_lines: &mut std::collections::BTreeSet<u64>,
    report: &mut FileReport,
) {
    if needles.is_empty() {
        return;
    }
    let window: Vec<u8> = if state.carry.is_empty() {
        fresh.to_vec()
    } else {
        let mut joined = Vec::with_capacity(state.carry.len() + fresh.len());
        joined.extend_from_slice(&state.carry);
        joined.extend_from_slice(fresh);
        joined
    };
    let newlines: Vec<usize> = window
        .iter()
        .enumerate()
        .filter(|(_, b)| **b == b'\n')
        .map(|(i, _)| i)
        .collect();
    for (index, start, end) in needles.matches(&window) {
        if end <= state.carry.len() {
            continue;
        }
        let before = u64::try_from(newlines.partition_point(|nl| *nl < start)).unwrap_or(0);
        let line = state.newlines_before_carry + before + 1;
        needle_lines.insert(line);
        let entry = report
            .needles
            .entry((index, line, false))
            .or_insert_with(|| {
                (
                    0,
                    if disclose {
                        String::from_utf8_lossy(&window[start..end]).into_owned()
                    } else {
                        String::new()
                    },
                )
            });
        entry.0 += 1;
    }
    let keep = state.overlap.min(window.len());
    let split = window.len() - keep;
    state.newlines_before_carry +=
        u64::try_from(newlines.partition_point(|nl| *nl < split)).unwrap_or(0);
    state.carry = window[split..].to_vec();
}

/// Where the escape stripper is between chunks, so a sequence split across a
/// 1 MiB read is still removed whole.
#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum Escape {
    #[default]
    Idle,
    /// `ESC` seen; the next byte says which kind of sequence this is.
    Opened,
    /// Inside `ESC [ … <final>`, whose final byte is `0x40..=0x7E` (SGR colour
    /// is `ESC [ … m`).
    Csi,
    /// Inside an OSC's INTRODUCER: the numeric selector and its `;` parameters
    /// (`8;;` for a hyperlink), which are dropped.
    OscParams,
    /// Inside an OSC's PAYLOAD, which is kept — a hyperlink's target is a URL,
    /// and a URL is something the rules and the needle search must see.
    Osc,
    /// Inside an OSC, having just seen the `ESC` of a possible terminator.
    OscEsc,
}

/// Removes terminal escape sequences from a chunk before ANY matching.
///
/// CI sets `CARGO_TERM_COLOR=always`, so every `cargo` transcript carries SGR
/// colour and OSC-8 hyperlinks, and a `flutter` one can too. Stripping them is a
/// RECALL improvement rather than cosmetics: a colour code lands exactly where a
/// tool highlights a value, so an escape INSIDE a hex run splits the run into
/// two shorter ones — which hides the needle from the automaton and the shape
/// from the rules, silently and in the encoding a terminal chose. One pass here
/// means needles, plants and rules all read the same plain text.
///
/// What is removed is the FRAMING, never the content: a CSI sequence carries no
/// text, but an OSC does — an OSC-8 hyperlink's payload is a URL, which S7 and
/// the needle search must see — so only the introducer (`ESC ]`, the numeric
/// selector and its `;` parameters) and the terminator come off. The residual,
/// stated in the README: a payload whose first bytes are digits or `;` loses
/// them to the parameter run, which no OSC this tree emits produces (a URI
/// scheme starts with a letter).
///
/// The state is carried across chunks so a sequence split by a 1 MiB read is
/// still removed whole; a newline always ends a sequence, terminated or not,
/// because a stripper that swallowed one would merge two records and shift every
/// line number after it.
fn strip_escapes<'a>(state: &mut Escape, fresh: &'a [u8]) -> Cow<'a, [u8]> {
    if *state == Escape::Idle && !fresh.contains(&ESC) {
        return Cow::Borrowed(fresh);
    }
    let mut out = Vec::with_capacity(fresh.len());
    for &byte in fresh {
        if byte == b'\n' {
            *state = Escape::Idle;
            out.push(byte);
            continue;
        }
        match *state {
            Escape::Idle if byte == ESC => *state = Escape::Opened,
            Escape::Idle => out.push(byte),
            Escape::Opened => {
                *state = match byte {
                    b'[' => Escape::Csi,
                    b']' => Escape::OscParams,
                    // A two-byte escape (`ESC c`, the `ESC \` string
                    // terminator): the dispatcher byte is the whole of it.
                    _ => Escape::Idle,
                };
            }
            Escape::Csi => {
                if (0x40..=0x7e).contains(&byte) {
                    *state = Escape::Idle;
                }
            }
            Escape::OscParams => match byte {
                0x07 => *state = Escape::Idle,
                ESC => *state = Escape::OscEsc,
                b'0'..=b'9' | b';' => {}
                _ => {
                    *state = Escape::Osc;
                    out.push(byte);
                }
            },
            Escape::Osc => match byte {
                0x07 => *state = Escape::Idle,
                ESC => *state = Escape::OscEsc,
                _ => out.push(byte),
            },
            Escape::OscEsc => {
                if byte == b'\\' {
                    *state = Escape::Idle;
                } else {
                    *state = Escape::Osc;
                    out.push(byte);
                }
            }
        }
    }
    Cow::Owned(out)
}

/// One streaming pass over one file.
fn scan_file(
    path: &Path,
    spec: &SinkSpec,
    needles: &Needles<'_>,
    rules: &RuleSet,
    plant_shape: &Regex,
    proof: Option<&Regex>,
    disclose: bool,
) -> Result<FileReport, String> {
    let mut file = std::fs::File::open(path)
        .map_err(|e| format!("UNUSABLE: {} [{:?}]", path.display(), e.kind()))?;
    let mut report = FileReport::default();
    let mut chunk = vec![0u8; CHUNK];
    let mut window = WindowState {
        carry: Vec::new(),
        newlines_before_carry: 0,
        overlap: needles.max_len.saturating_sub(1),
    };
    let mut partial: Vec<u8> = Vec::new();
    let mut escapes = Escape::default();
    let mut line_no: u64 = 1;
    let mut needle_lines: std::collections::BTreeSet<u64> = std::collections::BTreeSet::new();
    let mut reassembly = Reassembly::default();
    let sink_path = path.display().to_string();
    let ctx = LineCtx {
        spec,
        needles,
        rules,
        plant_shape,
        proof,
        sink_path: &sink_path,
        disclose,
    };

    loop {
        let read = file
            .read(&mut chunk)
            .map_err(|e| format!("UNUSABLE: {} [{:?}] mid-read", path.display(), e.kind()))?;
        if read == 0 {
            break;
        }
        // Counted before stripping: `bytes_read == file size` is the
        // single-pass property, and a colour code is a byte the pass read.
        report.bytes += u64::try_from(read).unwrap_or(u64::MAX);
        let plain = strip_escapes(&mut escapes, &chunk[..read]);
        let fresh = plain.as_ref();

        needle_lines.clear();
        match_window(
            &mut window,
            fresh,
            needles,
            disclose,
            &mut needle_lines,
            &mut report,
        );

        for segment in fresh.split_inclusive(|b| *b == b'\n') {
            let complete = segment.ends_with(b"\n");
            let body = if complete {
                &segment[..segment.len() - 1]
            } else {
                segment
            };
            if partial.len() < LINE_CAP {
                partial.extend_from_slice(&body[..body.len().min(LINE_CAP - partial.len())]);
            }
            if !complete {
                break;
            }
            let text = String::from_utf8_lossy(&partial).into_owned();
            handle_line(
                &ctx,
                &text,
                line_no,
                &needle_lines,
                &mut reassembly,
                &mut report,
            );
            partial.clear();
            report.lines += 1;
            line_no += 1;
        }
    }

    if !partial.is_empty() {
        let text = String::from_utf8_lossy(&partial).into_owned();
        handle_line(
            &ctx,
            &text,
            line_no,
            &needle_lines,
            &mut reassembly,
            &mut report,
        );
        report.lines += 1;
    }
    flush_reassembly(&mut reassembly, needles, disclose, &mut report);
    Ok(report)
}

fn handle_line(
    ctx: &LineCtx<'_>,
    text: &str,
    line_no: u64,
    needle_lines: &std::collections::BTreeSet<u64>,
    reassembly: &mut Reassembly,
    report: &mut FileReport,
) {
    let framed = frame(ctx.spec, text);
    if framed.raw_tag.is_some() {
        report.framed += 1;
    }
    // The WHOLE line, framing included: the proof is about the capture's
    // producer, not about which part of the line Haven owns — on Android the
    // reporter's own output reaches the transcript through logcat's prefix.
    if !report.proof_of_run && ctx.proof.is_some_and(|proof| proof.is_match(text)) {
        report.proof_of_run = true;
    }
    // Only for a line the window pass already matched on. The window pass for a
    // chunk completes before the line pass of the same chunk, and a match
    // straddling a chunk boundary lands on the line still open at that boundary
    // — which this pass emits in the new chunk — so the set is always populated
    // before the line that needs it arrives.
    if needle_lines.contains(&line_no) {
        if let Some(tag) = framed.tag.clone() {
            report.tags.insert(line_no, tag);
        }
        if !framed.scoped_classes.is_empty() {
            report
                .emitter_scoped
                .insert(line_no, framed.scoped_classes.to_vec());
        }
    }
    for found in ctx.plant_shape.find_iter(framed.body) {
        *report.plants.entry(found.as_str().to_owned()).or_default() += 1;
    }
    if ctx.spec.structural_rules && framed.owned {
        for segment in rule_segments(ctx.spec, framed.body) {
            for hit in ctx
                .rules
                .evaluate(segment, ctx.sink_path, framed.tag.as_deref())
            {
                // A `Compiling <crate> v<semver>` line carries the public pinned
                // git revision of a dependency (S2) and a crate name (S6), and
                // nothing else of ours. Those two rules only, on that shape
                // only, in a class that says so: every other rule still fires
                // here, and the needle pass above read every byte of the line.
                if ctx.spec.cargo_status == CargoStatus::Exempt
                    && ctx.rules.is_cargo_furniture(hit.rule, segment)
                {
                    continue;
                }
                let entry = report
                    .rules
                    .entry((hit.rule, line_no, framed.tag.clone()))
                    .or_insert_with(|| {
                        (
                            0,
                            if ctx.disclose {
                                hit.matched.clone()
                            } else {
                                String::new()
                            },
                        )
                    });
                entry.0 += 1;
            }
        }
    }
    if ctx.spec.reassemble {
        let key = (
            framed.pid.unwrap_or_default(),
            framed.tid.unwrap_or_default(),
            framed.raw_tag.clone().unwrap_or_default(),
        );
        if reassembly.key.as_ref() != Some(&key) {
            flush_reassembly(reassembly, ctx.needles, ctx.disclose, report);
            reassembly.key = Some(key);
            reassembly.first_line = line_no;
            reassembly.tag.clone_from(&framed.tag);
        } else if reassembly.buf.len() >= REASSEMBLY_CAP {
            // Keep one term's worth of tail across the flush, so a needle that
            // straddles the cap is still joined.
            let keep = ctx
                .needles
                .max_len
                .saturating_sub(1)
                .min(reassembly.buf.len());
            let tail = reassembly.buf.split_off(reassembly.buf.len() - keep);
            flush_reassembly(reassembly, ctx.needles, ctx.disclose, report);
            reassembly.buf = tail;
            reassembly.first_line = line_no;
        }
        reassembly.boundaries.push(reassembly.buf.len());
        // `leading` keeps one space when the entry's body starts with
        // whitespace and the buffer is not empty. Rust's `{:#x?}` indents every
        // element, and `android_logger` splits a long record between elements,
        // so dropping that run would join `0xa,` to `0x1b,` as `0xa,0x1b,` —
        // a string no renderer produces and no term matches.
        let leading = !reassembly.buf.is_empty();
        reassembly
            .buf
            .extend_from_slice(collapse_whitespace(framed.body, leading).as_bytes());
    }
}

/// The pieces of one physical line the structural rules are evaluated on.
///
/// A progress reporter writing to a pipe rewrites its status line with a
/// CARRIAGE RETURN and no newline, so one physical line of `flutter test`'s
/// compact output carries hundreds of independent updates — up to 231 in the
/// transcripts this was measured on. Evaluated as one string, the tail of one
/// update sits within S8's 24-character window of the next update's timestamp
/// digits, and a test description ending in `key` reads as a key next to an
/// encoded blob. They are separate records, so they are evaluated separately.
///
/// Only for `plain` sinks: a logcat or a `log show` entry is one record per
/// line by construction, and a stray `\r` inside one is data, not a record
/// boundary. The reported line number stays the PHYSICAL one — a segment index
/// would name a position no editor can find.
fn rule_segments<'a>(spec: &SinkSpec, body: &'a str) -> impl Iterator<Item = &'a str> {
    let split = spec.entry_format == EntryFormat::Plain;
    let mut once = (!split).then_some(body);
    let mut parts = split.then(|| body.split('\r')).into_iter().flatten();
    std::iter::from_fn(move || once.take().or_else(|| parts.next()))
}

/// Matches the re-joined run and reports only hits that SPAN a join.
fn flush_reassembly(
    reassembly: &mut Reassembly,
    needles: &Needles<'_>,
    disclose: bool,
    report: &mut FileReport,
) {
    if reassembly.buf.is_empty() || needles.is_empty() {
        reassembly.buf.clear();
        reassembly.boundaries.clear();
        return;
    }
    let mut joined = false;
    for (index, start, end) in needles.matches(&reassembly.buf) {
        let spans_join = reassembly
            .boundaries
            .iter()
            .any(|boundary| *boundary > start && *boundary < end);
        if !spans_join {
            continue;
        }
        joined = true;
        let entry = report
            .needles
            .entry((index, reassembly.first_line, true))
            .or_insert_with(|| {
                (
                    0,
                    if disclose {
                        String::from_utf8_lossy(&reassembly.buf[start..end]).into_owned()
                    } else {
                        String::new()
                    },
                )
            });
        entry.0 += 1;
    }
    if joined {
        if let Some(tag) = reassembly.tag.clone() {
            report.tags.insert(reassembly.first_line, tag);
        }
    }
    reassembly.buf.clear();
    reassembly.boundaries.clear();
}

/// Everything `handle_line` needs that does not change line to line.
struct LineCtx<'a> {
    spec: &'a SinkSpec,
    needles: &'a Needles<'a>,
    rules: &'a RuleSet,
    plant_shape: &'a Regex,
    /// The sink class's compiled `proof_of_run`, where it declares one.
    proof: Option<&'a Regex>,
    sink_path: &'a str,
    disclose: bool,
}

/// A line split into the part Haven owns and the framing around it.
struct Framed<'a> {
    body: &'a str,
    /// The handle the REPORT may print. On `logcat` it is present only when
    /// Haven owns the tag, because a vendor tag is free text that is not ours
    /// to publish; on `ios` it is the record's own process/subsystem columns,
    /// which name a program rather than carry a message.
    tag: Option<String>,
    /// The tag as parsed, owned or not. The reassembly key needs the real tag:
    /// keying on the reportable one would join two DIFFERENT vendor entries
    /// that merely share a pid and a tid, and a spurious needle hit is rc 1,
    /// which deletes the sink.
    raw_tag: Option<String>,
    pid: Option<String>,
    tid: Option<String>,
    owned: bool,
    /// Needle classes this record's own emitter is the SOURCE of, so they are
    /// not searched on it (`SinkSpec::emitter_scoped_out`). Empty everywhere
    /// else, a line that does not parse included: an unattributable line is
    /// scoped out of nothing.
    scoped_classes: &'a [String],
}

/// Splits a line according to its sink's framing.
fn frame<'a>(spec: &'a SinkSpec, text: &'a str) -> Framed<'a> {
    match spec.entry_format {
        EntryFormat::Plain => Framed {
            body: text,
            tag: None,
            raw_tag: None,
            pid: None,
            tid: None,
            owned: true,
            scoped_classes: &[],
        },
        EntryFormat::Logcat => parse_logcat(spec, text),
        EntryFormat::Ios => parse_ios(spec, text),
    }
}

/// A `log show` line, in either rendering the lanes can produce.
///
/// * **`--style syslog`**, which is what every iOS lane captures. What the
///   simulator actually emits (CI run 35280144455, all five lanes) is
///   `<date> <time+tz>  <host> <process>[<pid>[:<tid>]]: [(<library>) ][[<subsystem>:<category>] ]<message>`
///   — two spaces before the host, a parenthesised emitting library, an
///   optional `[subsystem:category]`, and no `<<Type>>` column at all. The
///   `<<Type>>` column IS produced by other `log` front-ends, so it stays
///   accepted as an optional alternative to the colon after the process token;
///   `fixtures/format.ios.log` carries captured lines of the real shape and
///   written lines of the other.
/// * the **default columnar** style:
///   `<date> <time+tz> <thread> <type> <activity> <pid> <ttl> <process>: <message>`,
///   where the library rides in the process column as `Runner(Flutter)`.
///
/// Both, because the capture is one `--style` flag away from the other and a
/// rendering this function cannot frame is a rendering the structural rules
/// silently skip. The rc-3 net in [`scan_one`] is what catches a THIRD one.
///
/// Ownership is an EXACT match of the record's EMITTER — its subsystem, else
/// its library, else its process — against the sink's `owned_emitters`, never a
/// substring. See [`crate::policy::SinkSpec::owned_emitters`] for why the
/// process alone is not the answer on iOS, and note that a substring test would
/// additionally own `RunnerHelper` and any vendor line whose MESSAGE contains
/// the word `Runner`. A line that does not parse is treated as NOT owned, so
/// the rules skip it; needles are still searched in every byte of it.
fn parse_ios<'a>(spec: &'a SinkSpec, text: &'a str) -> Framed<'a> {
    parse_ios_syslog(spec, text)
        .or_else(|| parse_ios_columnar(spec, text))
        .unwrap_or(Framed {
            body: text,
            tag: None,
            raw_tag: None,
            pid: None,
            tid: None,
            owned: false,
            scoped_classes: &[],
        })
}

/// `<date> <time+tz>  <host> <process>[<pid>[:<tid>]]: (<library>) [<sub>:<cat>] <message>`,
/// the library, the subsystem/category pair and the `<<Type>>` column all
/// optional.
fn parse_ios_syslog<'a>(spec: &'a SinkSpec, text: &'a str) -> Option<Framed<'a>> {
    let ([date, time, _host, token], cursor) = split_fields::<4>(text)?;
    if !is_iso_date(date) || !is_clock(time) {
        return None;
    }
    // The colon terminates the process token in the shape the lanes capture; a
    // `<<Type>>:` column takes its place in the other. Requiring one of the two
    // is what keeps a THIRD rendering (`Sep 12 10:00:00 iPhone Runner[431]: …`)
    // from parsing here on the strength of its process token alone.
    let (token, typed) = token
        .strip_suffix(':')
        .map_or((token, true), |t| (t, false));
    let (process, bracketed) = token.split_once('[')?;
    // `[431]` and `[431:12345]` both occur; the thread half is framing.
    let pid = bracketed.strip_suffix(']')?.split(':').next()?;
    if pid.is_empty() || !pid.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut rest = &text[cursor..];
    if typed {
        let (kind, tail) = rest.trim_start().strip_prefix('<')?.split_once(">:")?;
        if kind.is_empty() || !kind.bytes().all(|b| b.is_ascii_alphanumeric()) {
            return None;
        }
        rest = tail;
    }
    let (library, rest) = split_ios_library(rest.strip_prefix(' ').unwrap_or(rest));
    framed_ios(spec, process, library, pid, rest)
}

/// `<date> <time+tz> <thread> <type> <activity> <pid> <ttl> <process>: <message>`.
fn parse_ios_columnar<'a>(spec: &'a SinkSpec, text: &'a str) -> Option<Framed<'a>> {
    let ([_date, _time, thread, _type, activity, pid, ttl], cursor) = split_fields::<7>(text)?;
    if !thread.starts_with("0x")
        || !activity.starts_with("0x")
        || !pid.bytes().all(|b| b.is_ascii_digit())
        || !ttl.bytes().all(|b| b.is_ascii_digit())
    {
        return None;
    }
    let (process, body) = text[cursor..].split_once(':')?;
    framed_ios(spec, process, None, pid, body)
}

/// `YYYY-MM-DD`.
fn is_iso_date(field: &str) -> bool {
    let bytes = field.as_bytes();
    bytes.len() == 10
        && bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes
            .iter()
            .enumerate()
            .all(|(i, b)| i == 4 || i == 7 || b.is_ascii_digit())
}

/// `HH:MM:SS` and whatever fraction/offset follows it.
fn is_clock(field: &str) -> bool {
    let bytes = field.as_bytes();
    bytes.len() >= 8
        && bytes[2] == b':'
        && bytes[5] == b':'
        && bytes[..8]
            .iter()
            .enumerate()
            .all(|(i, b)| i == 2 || i == 5 || b.is_ascii_digit())
}

/// Splits a leading `(<library>) ` column off the message, if there is one.
///
/// `find(')')` rather than a nesting scan: the one line that carries a nested
/// pair is `(null)[0]: ((null)) …`, whose process column fails to name an
/// emitter anyway, and a scan that recursed there would only reach further into
/// a vendor message.
fn split_ios_library(rest: &str) -> (Option<&str>, &str) {
    let Some(tail) = rest.strip_prefix('(') else {
        return (None, rest);
    };
    let Some(close) = tail.find(')') else {
        return (None, rest);
    };
    let library = &tail[..close];
    if library.is_empty() || library.contains(' ') {
        return (None, rest);
    }
    (Some(library), &tail[close + 1..])
}

/// Splits a leading `[<subsystem>:<category>] ` column off the message.
///
/// Only a bracket holding exactly one un-spaced `<subsystem>:<category>` pair is
/// the column: `[0x105faf4d0] activating connection` and `[RelayManager] …` are
/// message text and stay in the body. The category may itself hold `::` (a Rust
/// module path is the `oslog` category), so the split is at the FIRST colon.
fn split_ios_subsystem(rest: &str) -> (Option<&str>, &str) {
    let Some(tail) = rest.strip_prefix('[') else {
        return (None, rest);
    };
    let Some(close) = tail.find(']') else {
        return (None, rest);
    };
    let inside = &tail[..close];
    let Some((subsystem, category)) = inside.split_once(':') else {
        return (None, rest);
    };
    if subsystem.is_empty() || category.is_empty() || inside.contains([' ', '[']) {
        return (None, rest);
    }
    (Some(subsystem), &tail[close + 1..])
}

/// The half both `ios` renderings share: split the remaining framing columns
/// off the message, decide ownership by the record's emitter, and hand the
/// rules the message alone.
fn framed_ios<'a>(
    spec: &'a SinkSpec,
    process: &str,
    library: Option<&str>,
    pid: &str,
    rest: &'a str,
) -> Option<Framed<'a>> {
    // In the columnar rendering the library rides in the process column.
    let (name, library) = match process.split_once('(') {
        Some((name, inner)) if !name.is_empty() => {
            (name, library.or_else(|| inner.strip_suffix(')')))
        }
        _ => (process, library),
    };
    let name = name.trim();
    if name.is_empty() {
        return None;
    }
    let rest = rest.strip_prefix(' ').unwrap_or(rest);
    let (subsystem, body) = split_ios_subsystem(rest);
    let emitter = subsystem.or(library).unwrap_or(name);
    let owned = spec
        .owned_emitters
        .iter()
        .any(|candidate| candidate == emitter);
    Some(Framed {
        body: body.strip_prefix(' ').unwrap_or(body),
        // Reported whether or not Haven owns it: a `log show` process and
        // subsystem are build-time names of a program, one per record and never
        // free text the emitter composes, so naming them is what lets the NEXT
        // run attribute a hit the deleted capture could not. [`ios_handle`]
        // keeps that promise narrow.
        tag: Some(ios_handle(name, subsystem.or(library))),
        raw_tag: Some(name.to_owned()),
        pid: Some(pid.to_owned()),
        tid: None,
        owned,
        // The same exact match as ownership, one question further on: whose
        // records legitimately CARRY a class. Keyed on the PAIR, because an
        // Apple framework logs under its own subsystem from inside Haven's own
        // process — `name` is what tells that record from the daemon's.
        scoped_classes: spec.emitter_scope(name, emitter),
    })
}

/// `<process>/<subsystem-or-library>` for the report, with both halves reduced
/// to the character set a program name is drawn from.
///
/// The columns are metadata, not values — but they are still bytes off a
/// device, so anything outside `[A-Za-z0-9._-]` or past 48 characters is
/// dropped rather than printed (Security Rule 15 applies to this tool's own
/// output first).
fn ios_handle(process: &str, inner: Option<&str>) -> String {
    fn clean(text: &str) -> &str {
        if !text.is_empty()
            && text.len() <= 48
            && text
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        {
            text
        } else {
            "?"
        }
    }
    inner.map_or_else(
        || clean(process).to_owned(),
        |inner| format!("{}/{}", clean(process), clean(inner)),
    )
}

/// The first `N` space-separated fields of `text`, and the offset just past
/// them. `None` when the line holds fewer than `N`.
fn split_fields<const N: usize>(text: &str) -> Option<([&str; N], usize)> {
    let bytes = text.as_bytes();
    let mut cursor = 0usize;
    let mut fields = [""; N];
    for field in &mut fields {
        while cursor < bytes.len() && bytes[cursor] == b' ' {
            cursor += 1;
        }
        let start = cursor;
        while cursor < bytes.len() && bytes[cursor] != b' ' {
            cursor += 1;
        }
        if start == cursor {
            return None;
        }
        *field = &text[start..cursor];
    }
    Some((fields, cursor))
}

/// `MM-DD HH:MM:SS.mmm  pid  tid P tag: message` — `adb logcat -v threadtime`.
///
/// A line that does not parse is treated as NOT Haven-owned, so the structural
/// rules skip it. That is the right default for a device-wide capture full of
/// vendor framing; needles are still searched in every byte of it.
fn parse_logcat<'a>(spec: &'a SinkSpec, text: &'a str) -> Framed<'a> {
    let unparseable = Framed {
        body: text,
        tag: None,
        raw_tag: None,
        pid: None,
        tid: None,
        owned: false,
        scoped_classes: &[],
    };
    let bytes = text.as_bytes();
    let mut cursor = 0usize;
    let mut fields = ["", "", "", "", ""];
    for field in &mut fields {
        while cursor < bytes.len() && bytes[cursor] == b' ' {
            cursor += 1;
        }
        let start = cursor;
        while cursor < bytes.len() && bytes[cursor] != b' ' {
            cursor += 1;
        }
        if start == cursor {
            return unparseable;
        }
        *field = &text[start..cursor];
    }
    let [_date, _time, pid, tid, priority] = fields;
    if priority.len() != 1
        || !pid.bytes().all(|b| b.is_ascii_digit())
        || !tid.bytes().all(|b| b.is_ascii_digit())
    {
        return unparseable;
    }
    // The boundary is the first COLON-SPACE, not the first colon: a tag carries
    // `android_logger`'s module path (`haven_core::relay::live_sync::session`),
    // whose `::` has no space in it. Splitting at the first colon took
    // `rust_lib_haven` off `rust_lib_haven::api` and left `:api:` at the head of
    // the body — which happened to keep Haven's Rust lines owned, since the
    // crate name is also an `owned_tags` entry, and would have stopped the day
    // anyone fixed the body. Verified against all 50 501 framed lines of CI run
    // 35280144455's three logcats: every one has a colon-space, and in every one
    // it is the real boundary — including the vendor tags that contain spaces
    // (`Google Maps Android API`) and the kernel's empty tag.
    let Some((tag, body)) = text[cursor..].split_once(": ") else {
        return unparseable;
    };
    let tag = tag.trim();
    let owned = owns_logcat_tag(spec, tag);
    Framed {
        // No further space stripped: the delimiter took the ONE space logcat
        // puts after the tag, so a body that still starts with one started with
        // two — which is `android_logger` having split a record BETWEEN bytes,
        // and that space is the separator `collapse_whitespace` needs to
        // re-join `hex-spaced` across the split
        // (`a_spaced_hex_dump_split_between_bytes_is_rejoined`).
        body,
        tag: owned.then(|| tag.to_owned()),
        raw_tag: Some(tag.to_owned()),
        pid: Some(pid.to_owned()),
        tid: Some(tid.to_owned()),
        owned,
        // A logcat tag is free text an emitter composes per call, so there is
        // no build-time name here to scope a class out of.
        scoped_classes: &[],
    }
}

/// Whether a logcat tag is one this repo owns.
///
/// The tag EQUALS an `owned_tags` entry, or is that entry followed by `::` —
/// the module path `android_logger` appends, whole
/// (`haven_core::relay::live_sync::session`) or truncated to logcat's 23-char
/// tag limit (`haven_core::relay::man`). Both forms still carry the `::` after
/// the crate name, because every Haven crate name is shorter than the limit.
///
/// NOT a bare prefix. `flutter` would then own the five `Flutter*` plugin tags
/// the real captures carry (`FlutterJNI`, `FlutterGeolocator`,
/// `FlutterSecureStorage`, `FlutterRenderer`,
/// `FlutterActivityAndFragmentDelegate`) and `RustStdoutStderr` would own
/// `RustStdoutStderrFoo`, putting vendor text under Haven's rules — the same
/// trap the `ios` sink's exact-emitter test avoids.
///
/// And not case-insensitively either. Every entry is a spelling Haven itself
/// fixes — a crate name, a Kotlin `TAG` constant, the engine's own `flutter` —
/// while the tag is whatever the emitter chose, so a case-folded match hands
/// Haven's rules any vendor tag differing from one of ours only in case
/// (`Flutter` for `flutter`, `mainactivity` for `MainActivity`).
///
/// Byte-wise rather than by slicing `&str`: a tag is whatever bytes the device
/// wrote, and `tag[..n]` on a non-ASCII one would panic.
fn owns_logcat_tag(spec: &SinkSpec, tag: &str) -> bool {
    let bytes = tag.as_bytes();
    spec.owned_tags.iter().any(|candidate| {
        let want = candidate.as_bytes();
        bytes.len() >= want.len()
            && &bytes[..want.len()] == want
            && (bytes.len() == want.len() || bytes[want.len()..].starts_with(b"::"))
    })
}

/// Collapses every whitespace run to one space.
///
/// With `leading`, a run at the START of the text also becomes one space, which
/// is what makes Rust's multi-line `{:#x?}` dump matchable: the expander's
/// `rust-debug-alt-x` term is that dump's single-line normalisation, and
/// `android_logger` hands logcat one indented entry per line of it.
fn collapse_whitespace(text: &str, leading: bool) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_space = false;
    for ch in text.chars() {
        if ch.is_whitespace() {
            if !in_space && (leading || !out.is_empty()) {
                out.push(' ');
            }
            in_space = true;
        } else {
            out.push(ch);
            in_space = false;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    use super::{scan_sinks, FindingKind, SinkArg};
    use crate::expand::{expand, Declared};
    use crate::manifest::{Manifest, SCHEMA};
    use crate::policy::Policy;
    use crate::rules::RuleSet;
    use crate::{RC_CLEAN, RC_GUARD, RC_META, RC_UNUSABLE};

    const PUBKEY: &str = "0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9";
    /// One line per documented `log show --style syslog` column variant.
    const IOS_FORMAT: &str = include_str!("../fixtures/format.ios.log");
    const MLS_GROUP_ID: &str = "3f4a5b6c7d8e9f0a1b2c3d4e5f6071823f4a5b6c7d8e9f0a1b2c3d4e5f607182";
    /// A drive transcript with a reporter line and both Dart plant phases,
    /// none of them declared by any manifest below.
    const HOST_DRIVE: &str = "00:00 +0: the core flow\n\
                              flutter: logscan-plant-dart-open-ZZZZZZZZZZ\n\
                              flutter: logscan-plant-dart-close-YYYYYYYYYY\n\
                              00:42 +1: All tests passed!\n";

    /// A scratch directory, removed on drop.
    struct Dir(PathBuf);

    impl Dir {
        fn new(tag: &str) -> Self {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.subsec_nanos());
            let path = std::env::temp_dir().join(format!(
                "haven-logscan-scan-{}-{tag}-{nanos}",
                std::process::id()
            ));
            std::fs::create_dir_all(&path).expect("scratch dir");
            Self(path)
        }

        fn write(&self, name: &str, body: &str) -> PathBuf {
            let path = self.0.join(name);
            std::fs::write(&path, body).expect("fixture");
            path
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// A manifest built in-process: the scanner needs the terms and the sink
    /// specs, not a sealed file, and these tests are about the scanner.
    fn manifest(declared: &[(&str, &str)]) -> Manifest {
        let policy = Policy::load().expect("policy");
        let values: Vec<Declared> = declared
            .iter()
            .enumerate()
            .map(|(index, (class, raw))| Declared {
                id: format!("v{index}"),
                class: (*class).to_owned(),
                raw: (*raw).to_owned(),
            })
            .collect();
        let expansion = expand(&policy, &values).expect("expand");
        Manifest {
            schema: SCHEMA,
            run_id: "scan-test".to_owned(),
            roles: Vec::new(),
            values: Vec::new(),
            terms: expansion.terms,
            dropped: expansion.dropped,
            ledger: Vec::new(),
            plants: Vec::new(),
            declared_plants: crate::plants::DeclaredPlants::Dart,
            floors: policy.sinks.keys().map(|name| (name.clone(), 0)).collect(),
            expect: BTreeMap::new(),
            scoped_out: policy
                .classes
                .iter()
                .map(|(name, spec)| (name.clone(), spec.scoped_out.clone()))
                .collect(),
            sinks: policy.sinks.clone(),
            base64_entropy_bits: policy.base64_entropy_bits,
            exempt_endpoints: Vec::new(),
        }
    }

    fn rules() -> RuleSet {
        RuleSet::new(4.2, 1_800_000_000, &[], Vec::new()).expect("rules")
    }

    fn hex_bytes(hex: &str) -> Vec<u8> {
        (0..hex.len() / 2)
            .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).expect("hex"))
            .collect()
    }

    fn run(manifest: &Manifest, class: &str, paths: &[PathBuf]) -> super::Outcome {
        scan_sinks(
            manifest,
            &[SinkArg {
                class: class.to_owned(),
                paths: paths.to_vec(),
            }],
            &BTreeMap::new(),
            &BTreeMap::new(),
            &rules(),
            false,
            super::ScanMode::Full,
        )
    }

    /// A needle straddling the 1 MiB chunk boundary must still be found, and at
    /// the right line. This is what the `max_term_len − 1` overlap buys, and the
    /// only way to see it is to cross a real boundary.
    #[test]
    fn a_needle_across_the_chunk_boundary_is_found_once() {
        let dir = Dir::new("chunk");
        // A fixed-width filler line, so the needle can be placed to straddle
        // byte 1 048 576 exactly.
        let filler = "[fixture] settled at epoch+1, relay#0b12cc, bucket 2-4......\n";
        assert_eq!(filler.len(), 61);
        let lines = (1 << 20) / filler.len();
        let mut body = filler.repeat(lines);
        let before = (1 << 20) - body.len();
        body.push_str(&"x".repeat(before - 30));
        body.push_str(PUBKEY);
        body.push('\n');
        let path = dir.write("boundary.drive.log", &body);
        let manifest = manifest(&[("pubkey", PUBKEY)]);
        let outcome = run(&manifest, "drive", &[path]);
        let hex: Vec<&super::Finding> = outcome
            .findings
            .iter()
            .filter(|f| f.encoding.as_deref() == Some("hex-lower"))
            .collect();
        assert_eq!(hex.len(), 1, "exactly one hit, not zero and not two");
        assert_eq!(
            hex[0].line,
            u64::try_from(lines + 1).expect("line"),
            "the line number must survive the chunk boundary"
        );
        assert_eq!(outcome.bytes_read, u64::try_from(body.len()).expect("size"));
    }

    /// Rust's own `{:#x?}` rendering, split across logcat entries the way
    /// `android_logger` splits a long record, must be caught.
    ///
    /// The haystack is built from `format!("{bytes:#x?}")` rather than from a
    /// hand-written fixture, so it tracks what the compiler actually prints: the
    /// label exists for exactly this rendering, and a join that dropped the
    /// indent would make it unmatchable while the ledger still called it
    /// covered.
    #[test]
    fn a_multiline_rust_hex_dump_split_across_entries_is_rejoined() {
        let dir = Dir::new("altx");
        let bytes = hex_bytes(PUBKEY);
        let dump = format!("{bytes:#x?}");
        assert!(
            dump.lines().count() > 2,
            "Rust's alternate hex debug rendering is multi-line"
        );
        let mut body = String::new();
        for line in dump.lines() {
            // One entry per line, prefix repeated, same pid/tid/tag — which is
            // what `logcat -v threadtime` shows for one chunked record.
            body.push_str("09-12 12:00:00.001  1234  1301 D haven_core: ");
            body.push_str(line);
            body.push('\n');
        }
        let path = dir.write("altx.logcat.log", &body);
        let manifest = manifest(&[("pubkey", PUBKEY)]);
        let outcome = run(&manifest, "logcat", &[path]);
        let alt: Vec<&super::Finding> = outcome
            .findings
            .iter()
            .filter(|f| f.encoding.as_deref() == Some("rust-debug-alt-x"))
            .collect();
        assert_eq!(
            alt.len(),
            1,
            "the re-joined dump must be caught once: {:?}",
            outcome
                .findings
                .iter()
                .map(|f| f.encoding.clone())
                .collect::<Vec<_>>()
        );
        assert!(alt[0].reassembled, "only the re-joined view can see it");
        assert_eq!(alt[0].line, 1, "attributed to the run's first line");
    }

    /// The same split preserves the space every other byte rendering needs.
    #[test]
    fn a_spaced_hex_dump_split_between_bytes_is_rejoined() {
        let dir = Dir::new("spaced");
        let bytes = hex_bytes(PUBKEY);
        let spaced: Vec<String> = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let (head, tail) = spaced.split_at(20);
        let body = format!(
            "09-12 12:00:00.001  1234  1301 D haven_core: bytes {}\n\
             09-12 12:00:00.002  1234  1301 D haven_core:  {}\n",
            head.join(" "),
            tail.join(" ")
        );
        let path = dir.write("spaced.logcat.log", &body);
        let manifest = manifest(&[("pubkey", PUBKEY)]);
        let outcome = run(&manifest, "logcat", &[path]);
        assert!(
            outcome
                .findings
                .iter()
                .any(|f| f.encoding.as_deref() == Some("hex-spaced") && f.reassembled),
            "a byte boundary at a 4000-byte split must not lose the separating space"
        );
    }

    /// Reassembly is keyed on the entry's REAL tag, owned or not.
    ///
    /// Two vendor entries that share a pid and a tid but not a tag are two
    /// records, and joining them can fabricate a needle that was never in the
    /// log — which is rc 1, and rc 1 deletes the sink. The shared-tag arm is the
    /// positive control: it proves the mechanism still joins, so the
    /// differing-tag arm is a statement about the KEY and not about a
    /// reassembly that quietly stopped working.
    #[test]
    fn reassembly_keys_on_the_real_tag_so_two_vendor_tags_do_not_join() {
        let dir = Dir::new("unowned");
        let manifest = manifest(&[("pubkey", PUBKEY)]);
        let (head, tail) = PUBKEY.split_at(40);
        let joined = |second_tag: &str, name: &str| -> bool {
            let body = format!(
                "09-12 12:00:00.001   999   999 I WifiService: scan {head}\n\
                 09-12 12:00:00.002   999   999 I {second_tag}: {tail} done\n"
            );
            let path = dir.write(&format!("{name}.logcat.log"), &body);
            run(&manifest, "logcat", &[path])
                .findings
                .iter()
                .any(|f| f.encoding.as_deref() == Some("hex-lower") && f.reassembled)
        };
        assert!(
            joined("WifiService", "shared"),
            "one chunked record must still be re-joined, vendor or not"
        );
        assert!(
            !joined("TelephonyOne", "differing"),
            "two different tags are two records: joining them fabricates a needle"
        );
    }

    /// A sink is scanned as BYTES: a NUL, invalid UTF-8 and CRLF line endings
    /// must neither panic nor hide a needle.
    #[test]
    fn a_binary_tainted_sink_is_scanned_losslessly() {
        let dir = Dir::new("binary");
        let manifest = manifest(&[("pubkey", PUBKEY)]);
        let mut body: Vec<u8> = Vec::new();
        body.extend_from_slice(b"[fixture] start\r\n");
        body.push(0x00);
        body.extend_from_slice(b" nul and a lone continuation byte ");
        body.push(0x80);
        body.extend_from_slice(b"\r\n");
        body.extend_from_slice(format!("[fixture] pubkey {PUBKEY}\r\n").as_bytes());
        body.push(0xff);
        body.extend_from_slice(b" trailing, no newline");
        let path = dir.0.join("binary.drive.log");
        std::fs::write(&path, &body).expect("fixture");
        let outcome = run(&manifest, "drive", std::slice::from_ref(&path));
        let hex = outcome
            .findings
            .iter()
            .find(|f| f.encoding.as_deref() == Some("hex-lower"))
            .expect("a needle next to a NUL is still a needle");
        assert_eq!(hex.line, 3, "CRLF lines are counted like any other");
        assert_eq!(outcome.lines.get("drive"), Some(&4));
        assert_eq!(outcome.bytes_read, u64::try_from(body.len()).expect("size"));
    }

    /// A relay log legitimately holds pubkeys and event ids; it does NOT
    /// legitimately hold the real MLS group id, and no structural rule runs
    /// there at all.
    #[test]
    fn a_relay_sink_scopes_out_the_public_classes_and_runs_no_rules() {
        let dir = Dir::new("relay");
        let path = dir.write(
            "strfry.log",
            &format!("accepted event from {PUBKEY} at 10.0.0.2\ninternal {MLS_GROUP_ID}\n"),
        );
        let manifest = manifest(&[("pubkey", PUBKEY), ("mls_group_id", MLS_GROUP_ID)]);
        let outcome = run(&manifest, "relay", std::slice::from_ref(&path));
        assert!(
            outcome
                .findings
                .iter()
                .all(|f| f.kind == FindingKind::Needle),
            "structural rules must not run on a relay log"
        );
        let classes: Vec<&str> = outcome
            .findings
            .iter()
            .filter_map(|f| f.class.as_deref())
            .collect();
        assert!(classes.contains(&"mls_group_id"), "{classes:?}");
        assert!(!classes.contains(&"pubkey"), "{classes:?}");

        // The same two lines in a drive transcript are BOTH leaks, and the rules
        // run: the scoping is a property of the sink, not of the value.
        let drive = dir.write(
            "drive.log",
            &format!("accepted event from {PUBKEY} at 10.0.0.2\ninternal {MLS_GROUP_ID}\n"),
        );
        let outcome = run(&manifest, "drive", &[drive]);
        let classes: Vec<&str> = outcome
            .findings
            .iter()
            .filter_map(|f| f.class.as_deref())
            .collect();
        assert!(classes.contains(&"pubkey"), "{classes:?}");
        assert!(
            outcome.findings.iter().any(|f| f.kind == FindingKind::Rule),
            "S1 and S12 must fire on a Haven-owned line"
        );
    }

    /// The term floor is per sink: a six-character term is a needle in a drive
    /// transcript and furniture in a device-wide logcat.
    #[test]
    fn a_short_term_is_searched_below_its_floor_and_not_above_it() {
        let dir = Dir::new("floor");
        let manifest = manifest(&[("circle_name", "Hearth")]);
        let drive = dir.write("drive.log", "[Circle] opened Hearth\n");
        assert_eq!(
            run(&manifest, "drive", &[drive]).findings.len(),
            1,
            "six characters clears the drive floor"
        );
        let logcat = dir.write(
            "logcat.log",
            "09-12 10:00:00.001  1234  1290 I flutter: [Circle] opened Hearth\n",
        );
        assert!(
            run(&manifest, "logcat", &[logcat]).findings.is_empty(),
            "six characters is below the logcat floor, where it would match furniture"
        );
    }

    /// Structural rules see the MESSAGE, and only on a Haven-owned tag.
    #[test]
    fn rules_run_on_owned_tags_only_and_on_the_message_body() {
        let dir = Dir::new("tags");
        let manifest = manifest(&[]);
        let path = dir.write(
            "logcat.log",
            "09-12 10:00:00.001   999   999 I WifiService: fix -12.345678,98.765432\n\
             09-12 10:00:00.002  1234  1290 I flutter: fix -12.345678,98.765432\n",
        );
        let outcome = run(&manifest, "logcat", &[path]);
        assert_eq!(outcome.findings.len(), 1, "{:?}", outcome.findings);
        assert_eq!(outcome.findings[0].line, 2);
        assert_eq!(outcome.findings[0].rule.as_deref(), Some("S5"));
        assert_eq!(
            outcome.findings[0].tag.as_deref(),
            Some("flutter"),
            "the report's tag comes from the entry's own tag column"
        );
    }

    /// The tags Haven's Android lines actually carry, and the vendor tags that
    /// sit one character away from them.
    ///
    /// Every line is copied from CI run 35280144455's three logcats. The five
    /// `Flutter*` plugin tags are the reason ownership is not a bare prefix:
    /// `flutter` is an entry, and a prefix test would hand every one of them —
    /// remote-authored plugin text included — to Haven's structural rules.
    /// `vioustech.haven` is the ART runtime's tag for the app process (logcat
    /// truncates `com.oblivioustech.haven` to its last 15 characters), and its
    /// lines are the runtime's own (`Late-enabling -Xcheck:jni`, `SELinux` audit
    /// records), not Haven's log calls — so it stays un-owned, and the policy
    /// no longer carries a package-name entry that could only ever have matched
    /// an untruncated tag no capture produces.
    #[test]
    fn the_real_logcat_tags_frame_exactly_havens_lines() {
        let spec = Policy::load().expect("policy").sinks["logcat"].clone();
        let framed = |tag: &str| -> (bool, Option<String>, String) {
            let line = format!("09-17 22:41:04.751  4553  4790 D {tag}: fix -12.345678,98.765432");
            let f = super::frame(&spec, &line);
            (f.owned, f.raw_tag.clone(), f.body.to_owned())
        };
        for tag in [
            "rust_lib_haven::api",
            "haven_core::relay::manager",
            "haven_core::circle::storage",
            "haven_core::relay::live_sync::session",
            // The 23-character truncation `android_logger` applies when
            // logcat's tag limit bites.
            "haven_core::relay::man",
            "flutter ",
            "HavenApplication",
        ] {
            let (owned, raw, body) = framed(tag);
            assert!(owned, "{tag} is Haven's");
            assert_eq!(raw.as_deref(), Some(tag.trim()), "the WHOLE module path");
            assert_eq!(body, "fix -12.345678,98.765432", "{tag}");
        }
        for tag in [
            "FlutterJNI",
            "FlutterGeolocator",
            "FlutterSecureStorage",
            "FlutterRenderer",
            "FlutterActivityAndFragmentDelegate",
            "flutterx",
            "RustStdoutStderrFoo",
            "vioustech.haven",
            // The untruncated package name, pinned un-owned so the policy entry
            // that used to list it cannot come back: no capture carries this
            // tag, and the truncated form above is the platform's, not Haven's.
            "com.oblivioustech.haven",
            "Google Maps Android API",
            "AiAiEcho",
            // Case-only near misses of three entries. An emitter picks its own
            // tag and every entry is a spelling Haven fixes, so differing in
            // case is differing.
            "Flutter",
            "mainactivity",
            "HAVEN_CORE::relay::manager",
        ] {
            let (owned, raw, _) = framed(tag);
            assert!(!owned, "{tag} is not Haven's");
            assert_eq!(raw.as_deref(), Some(tag), "but it is still framed");
        }
    }

    /// A record that names no subsystem and no library is attributed to its
    /// PROCESS — the last rung of the emitter ladder, and the only one a
    /// columnar `<process>: <message>` line can reach.
    #[test]
    fn an_ios_record_with_no_subsystem_or_library_falls_back_to_its_process() {
        let dir = Dir::new("ios");
        let manifest = manifest(&[]);
        let path = dir.write(
            "ios.log",
            "2026-09-12 10:00:00.000000+0000 0x1 Default 0x0 11 0 locationd: fix -12.345678,98.765432\n\
             2026-09-12 10:00:00.000001+0000 0x1 Default 0x0 12 0 Runner: fix -12.345678,98.765432\n",
        );
        let outcome = run(&manifest, "ios", &[path]);
        assert_eq!(outcome.findings.len(), 1, "{:?}", outcome.findings);
        assert_eq!(outcome.findings[0].line, 2);
    }

    /// The `ios` twin of [`rules_run_on_owned_tags_only_and_on_the_message_body`].
    ///
    /// The lines are the rendering the lanes actually capture, and the vendor
    /// one is Haven's OWN process: on iOS every Apple framework linked into the
    /// app logs as `Runner`, so the process cannot be the ownership test and the
    /// record's subsystem is.
    #[test]
    fn rules_run_on_owned_emitters_only_and_on_the_message_body() {
        let dir = Dir::new("iosemitters");
        let manifest = manifest(&[]);
        let path = dir.write(
            "ios.log",
            "2026-09-17 22:45:43.010431+0000  localhost Runner[17463]: (CoreLocation) [com.apple.locationd.Core:Client] fix -12.345678,98.765432\n\
             2026-09-17 22:45:47.709581+0000  localhost Runner[17463]: (rust_lib_haven) [frb_user:rust_lib_haven::api] fix -12.345678,98.765432\n",
        );
        let outcome = run(&manifest, "ios", &[path]);
        assert_eq!(outcome.findings.len(), 1, "{:?}", outcome.findings);
        assert_eq!(outcome.findings[0].line, 2);
        assert_eq!(outcome.findings[0].rule.as_deref(), Some("S5"));
        assert_eq!(
            outcome.findings[0].tag.as_deref(),
            Some("Runner/frb_user"),
            "the report's handle names the process and the record's own subsystem"
        );
    }

    /// The simulator's location daemon is the SOURCE of the fix a lane injects,
    /// not a place it leaked to.
    ///
    /// `simctl location set` hands `locationd` the coordinate the lane then
    /// declares, so its `Position` subsystem logging that number is the OS
    /// delivering what the harness asked for: CI run 35311161479's
    /// `e2e-ios-real-gps` was rc 1 on the b4 seed in several encodings, every
    /// hit under that one program. The scope is that PROGRAM alone — the same
    /// text under Haven's own subsystem, under Apple's push daemon, under the
    /// simulator bridge, or under the very same `Position` subsystem emitted
    /// from inside Haven's own process is still a finding, which is what makes
    /// this a statement about the daemon rather than about the value.
    #[test]
    fn the_location_daemons_own_fix_is_scoped_out_and_nobody_elses_is() {
        let dir = Dir::new("iosposition");
        let manifest = manifest(&[("coordinate", "-33.865143,151.209901")]);
        let path = dir.write(
            "ios.log",
            "2026-09-17 22:45:47.709585+0000  localhost locationd[9676]: (CoreLocation) [com.apple.locationd.Position:Client] fix -33.865143,151.209901\n\
             2026-09-17 22:45:47.709586+0000  localhost Runner[17463]: (Runner) [haven_ios:slc] fix -33.865143,151.209901\n\
             2026-09-17 22:45:47.709587+0000  localhost apsd[9648]: (libnetwork.dylib) [com.apple.network:connection] fix -33.865143,151.209901\n\
             2026-09-17 22:45:47.709588+0000  localhost CoreSimulatorBridge[9640]: fix -33.865143,151.209901\n\
             2026-09-17 22:45:47.709589+0000  localhost Runner[17463]: (CoreLocation) [com.apple.locationd.Position:Client] fix -33.865143,151.209901\n",
        );
        let outcome = run(&manifest, "ios", &[path]);
        let mut needle_lines: Vec<u64> = outcome
            .findings
            .iter()
            .filter(|f| f.kind == FindingKind::Needle)
            .map(|f| f.line)
            .collect();
        needle_lines.sort_unstable();
        needle_lines.dedup();
        assert_eq!(
            needle_lines,
            vec![2, 3, 4, 5],
            "only the daemon's own record is forgiven — line 5 is the SAME subsystem inside Haven's own process, which is where a leak would be: {:?}",
            outcome.findings
        );
        assert!(
            outcome.findings.iter().all(|f| f.line != 1),
            "and it is forgiven whole, rules included: {:?}",
            outcome.findings
        );
    }

    /// The scope is per CLASS, not per record: the daemon has to know the
    /// position, and nothing else.
    #[test]
    fn only_the_coordinate_is_scoped_out_of_the_location_daemon() {
        let dir = Dir::new("iospositionclass");
        let manifest = manifest(&[("coordinate", "-33.865143,151.209901"), ("pubkey", PUBKEY)]);
        let path = dir.write(
            "ios.log",
            &format!(
                "2026-09-17 22:45:47.709585+0000  localhost locationd[9676]: (CoreLocation) [com.apple.locationd.Position:Client] client {PUBKEY} at -33.865143,151.209901\n"
            ),
        );
        let outcome = run(&manifest, "ios", &[path]);
        let classes: Vec<&str> = outcome
            .findings
            .iter()
            .filter(|f| f.kind == FindingKind::Needle)
            .filter_map(|f| f.class.as_deref())
            .collect();
        assert!(
            !classes.is_empty() && classes.iter().all(|class| *class == "pubkey"),
            "a pubkey on the daemon's record is still a leak: {:?}",
            outcome.findings
        );
    }

    /// The regression CI run 35280144455 would have produced next: with the
    /// process as the ownership test, Apple's own lines INSIDE the app's process
    /// reach the rules — 31 structural hits per lane in that run's captures,
    /// which is rc 1 and a deleted capture on a green lane. Three captured
    /// lines, one per rule that fired.
    #[test]
    fn apple_frameworks_inside_the_app_process_are_not_havens_lines() {
        let dir = Dir::new("iosvendor");
        let manifest = manifest(&[]);
        let path = dir.write(
            "ios.log",
            "2026-09-17 22:45:43.010431+0000  localhost Runner[17463]: (libxpc.dylib) [com.apple.xpc:connection] [0x105faf4d0] activating connection: mach=true listener=false peer=false name=com.apple.cfprefsd.daemon\n\
             2026-09-17 22:45:43.013393+0000  localhost Runner[17463]: (CoreServicesInternal) [com.apple.FileURL:default] kExcludedFromBackupXattrName set on path: /Users/x/Library/Developer/CoreSimulator/Devices\n",
        );
        let outcome = run(&manifest, "ios", &[path]);
        assert!(
            outcome.findings.is_empty(),
            "an Apple framework's line is not Haven's to answer for: {:?}",
            outcome.findings
        );
    }

    /// Owning the Flutter engine's image is what keeps S1-S12 over Dart's own
    /// output, and it costs nothing on the lines the lanes really produce.
    ///
    /// `debugPrint` CAN reach the unified log as `Runner: (Flutter) flutter:
    /// <msg>`, so leaving `Flutter` un-owned would be fail-SILENT: the day the
    /// engine routes Haven's Dart text there, every rule stops and nothing
    /// says so. The three `(Flutter)` shapes CI run 35280144455's captures hold
    /// are clean under ownership — two of them outright, and the Dart VM
    /// service's loopback URL through the endpoint exemption every lane's seal
    /// already carries for its own relay, which is an exemption the lane
    /// CLAIMS rather than an allowlist entry hiding a rule.
    #[test]
    fn owning_the_flutter_image_catches_dart_and_forgives_its_furniture() {
        let dir = Dir::new("iosflutter");
        let mut manifest = manifest(&[]);
        manifest.exempt_endpoints = crate::manifest::endpoint_spellings("ws://127.0.0.1:7777");
        let exempt = RuleSet::new(4.2, 1_800_000_000, &manifest.exempt_endpoints, Vec::new())
            .expect("rules");
        let path = dir.write(
            "ios.log",
            "2026-09-17 22:45:44.025579+0000  localhost Runner[17463]: (Flutter) flutter: The Dart VM service is listening on http://127.0.0.1:52512/_mVsUNwyDBE=/\n\
             2026-09-17 22:45:44.025580+0000  localhost Runner[17463]: (Flutter) [IMPORTANT:flutter/shell/platform/darwin/graphics/FlutterDarwinContextMetalImpeller.mm(89)] Using the Impeller rendering backend (Metal).\n\
             2026-09-17 22:45:44.930958+0000  localhost Runner[17463]: (Flutter) Plugin WorkmanagerPlugin uses deprecated application lifecycle events. See https://docs.flutter.dev/release/breaking-changes/uiscenedelegate#migration-guide-for-flutter-plugins\n\
             2026-09-17 22:45:47.709584+0000  localhost Runner[17463]: (Flutter) flutter: fix -12.345678,98.765432\n",
        );
        let outcome = scan_sinks(
            &manifest,
            &[SinkArg {
                class: "ios".to_owned(),
                paths: vec![path],
            }],
            &BTreeMap::new(),
            &BTreeMap::new(),
            &exempt,
            false,
            super::ScanMode::Full,
        );
        let hits: Vec<(u64, Option<&str>)> = outcome
            .findings
            .iter()
            .filter(|f| f.kind == FindingKind::Rule)
            .map(|f| (f.line, f.rule.as_deref()))
            .collect();
        assert_eq!(
            hits,
            vec![(4, Some("S5"))],
            "Dart's coordinate is caught and the engine's own furniture is not"
        );
        assert_eq!(
            outcome.findings[0].tag.as_deref(),
            Some("Runner/Flutter"),
            "and the finding says which image wrote it"
        );
    }

    /// The attribution handle is metadata, and stays metadata.
    ///
    /// It is printed for lines Haven does NOT own, which is the whole point of
    /// it — so what it may contain is bounded by the shape of a program name
    /// rather than by trust in the emitter (Rule 15 applies to this tool's own
    /// output first). A column carrying anything else is reported as `?`.
    #[test]
    fn an_ios_handle_carries_a_program_name_or_nothing() {
        let spec = Policy::load().expect("policy").sinks["ios"].clone();
        let long = "a".repeat(49);
        for (line, want) in [
            (
                "2026-09-17 22:45:43.010431+0000  localhost locationd[77]: (CoreLocation) [com.apple.locationd.Core:Client] settled".to_owned(),
                "locationd/com.apple.locationd.Core",
            ),
            (
                "2026-09-17 22:45:43.010431+0000  localhost locationd[77]: settled".to_owned(),
                "locationd",
            ),
            (
                format!("2026-09-17 22:45:43.010431+0000  localhost {long}[77]: settled"),
                "?",
            ),
            (
                format!("2026-09-17 22:45:43.010431+0000  localhost locationd[77]: [{long}:c] settled"),
                "locationd/?",
            ),
            (
                "2026-09-17 22:45:43.010431+0000  localhost ünïcode[77]: settled".to_owned(),
                "?",
            ),
        ] {
            assert_eq!(super::frame(&spec, &line).tag.as_deref(), Some(want), "{line}");
        }
    }

    /// Every column variant of `log show`, in all three renderings.
    ///
    /// The lines that must fire are the owned ones of each rendering — Haven's
    /// two subsystems, its two images, and the Flutter engine's — and the lines
    /// that must NOT are a vendor library and a vendor subsystem INSIDE Haven's
    /// own process, a vendor process, a process whose name merely CONTAINS an
    /// owned one, a vendor line whose message contains one, and a line that is
    /// in none of the formats. The last two are the substring trap the first
    /// implementation walked into: it owned any line with the word `Runner`
    /// anywhere in it, which puts remote-authored text under Haven's rules.
    ///
    /// Section A of the fixture is captured, and it is what proves owning
    /// `Flutter` costs nothing: the three real `(Flutter)` shapes — the
    /// Impeller notice, a plugin-deprecation notice with an `https` URL, and an
    /// empty message — are all owned here and all clean.
    #[test]
    fn the_ios_column_variants_frame_exactly_the_owned_lines() {
        let dir = Dir::new("iosformat");
        let manifest = manifest(&[("pubkey", PUBKEY)]);
        let path = dir.write("format.ios.log", IOS_FORMAT);
        let outcome = run(&manifest, "ios", &[path]);

        let rule_lines: Vec<u64> = outcome
            .findings
            .iter()
            .filter(|f| f.kind == FindingKind::Rule)
            .map(|f| f.line)
            .collect();
        assert_eq!(
            rule_lines,
            vec![45, 46, 47, 48, 49, 56, 57, 58, 61, 62, 63, 78],
            "only the owned variants of the three renderings may reach the rules"
        );
        // The handle names the process AND the record's own inner column, so a
        // hit in a device-wide export says which program to go and look at.
        let tags: Vec<Option<&str>> = outcome
            .findings
            .iter()
            .filter(|f| f.kind == FindingKind::Rule)
            .map(|f| f.tag.as_deref())
            .collect();
        assert_eq!(
            tags,
            vec![
                Some("Runner/frb_user"),
                Some("Runner/rust_lib_haven"),
                Some("Runner/haven_ios"),
                Some("Runner"),
                Some("Runner/Flutter"),
                Some("Runner"),
                Some("Runner/Flutter"),
                Some("Runner/frb_user"),
                Some("Runner"),
                Some("Runner/rust_lib_haven"),
                Some("Runner/frb_user"),
                // The owned member of the emitter-scope trio: the scope is a
                // NEEDLE scope, so the daemon's own record (77) is not reported
                // while the rules read this line as they always did.
                // `selftest.rs`'s IOS_NEEDLE_LINES is what pins that absence,
                // and the presence of the other two.
                Some("Runner/haven_ios"),
            ],
        );
        // A needle in a VENDOR line is still a disclosure in an uploaded
        // artifact, so the term search covers the lines the rules skip.
        let needle_lines: Vec<u64> = outcome
            .findings
            .iter()
            .filter(|f| f.kind == FindingKind::Needle)
            .map(|f| f.line)
            .collect();
        assert!(
            !needle_lines.is_empty() && needle_lines.iter().all(|line| *line == 68),
            "the declared pubkey sits on the un-owned last line: {needle_lines:?}"
        );
        // …and the finding names the vendor process that carried it, which is
        // the whole point of item 3: the run that found a coordinate in a
        // device-wide export could not say who wrote it.
        assert!(
            outcome
                .findings
                .iter()
                .filter(|f| f.kind == FindingKind::Needle)
                .all(|f| f.tag.as_deref() == Some("locationd")),
            "{:?}",
            outcome.findings
        );
    }

    /// The rules run on the MESSAGE, not on the framing — in all renderings.
    #[test]
    fn an_ios_body_excludes_the_framing_of_either_rendering() {
        let spec = Policy::load().expect("policy").sinks["ios"].clone();
        let captured = super::frame(
            &spec,
            "2026-09-17 22:45:51.209385+0000  localhost Runner[17463]: (rust_lib_haven) [frb_user:rust_lib_haven::api] settled",
        );
        assert_eq!(captured.body, "settled");
        assert!(captured.owned);
        assert_eq!(captured.tag.as_deref(), Some("Runner/frb_user"));
        assert_eq!(captured.pid.as_deref(), Some("17463"));

        // A bracket that is not a `<subsystem>:<category>` pair is MESSAGE: an
        // xpc connection handle and Haven's own `[RelayManager]` prefix both
        // have to stay where the rules can read them.
        let handle = super::frame(
            &spec,
            "2026-09-17 22:45:43.010431+0000  localhost Runner[17463]: (rust_lib_haven) [0x105faf4d0] settled",
        );
        assert_eq!(handle.body, "[0x105faf4d0] settled");
        assert_eq!(handle.tag.as_deref(), Some("Runner/rust_lib_haven"));

        let columnar = super::frame(
            &spec,
            "2026-09-12 10:00:00.000000+0000 0x1e0f     Default     0x0                  431    0    Runner(libsystem_network.dylib): [frb_user:default] settled",
        );
        assert_eq!(columnar.body, "settled");
        assert!(
            columnar.owned,
            "the record's subsystem outranks the library it was emitted from"
        );
        assert_eq!(columnar.raw_tag.as_deref(), Some("Runner"));
        assert_eq!(columnar.pid.as_deref(), Some("431"));

        let syslog = super::frame(
            &spec,
            "2026-09-12 10:00:00.000000+0000 localhost Runner(Flutter)[431:12345] <Notice>: flutter: settled",
        );
        assert_eq!(syslog.body, "flutter: settled");
        assert!(
            syslog.owned,
            "the engine's image carries Dart's own `flutter: <msg>` output, so it is Haven's"
        );
        assert_eq!(syslog.raw_tag.as_deref(), Some("Runner"));
        assert_eq!(
            syslog.pid.as_deref(),
            Some("431"),
            "the thread half of `[pid:tid]` is framing, not identity"
        );

        // A Haven record's CONTINUATION lines carry no process column at all, so
        // they are un-owned in every rendering: the rules never see the body of
        // a multi-line panic on iOS. Needles still are searched in every byte.
        let continuation = super::frame(&spec, "    at haven_core::relay::manager (line 1)");
        assert!(!continuation.owned);
        assert!(continuation.raw_tag.is_none());
        assert!(continuation.tag.is_none());
    }

    /// What a line count cannot see: a SHORT complete transcript and a LONG
    /// empty one.
    ///
    /// Both scans here are above every floor (the test manifest seals 0), so
    /// the only thing under test is the reporter's progress line. The short
    /// capture is the shape of CI run 35464818348's phase C2 — 19 lines,
    /// complete, and rc 4 under the line floor that lane then carried.
    #[test]
    fn the_reporter_line_and_not_the_line_count_proves_a_test_ran() {
        let dir = Dir::new("proofofrun");
        let manifest = manifest(&[]);

        let mut short = String::from("Installing /tmp/x.apk...      1,362ms\n");
        for _ in 0..8 {
            short.push_str("D/FlutterGeolocator( 4457): Binding to location service.\n");
        }
        short.push_str("I/flutter ( 4457): 00:00 +0: M7 disable: register a task\n");
        for _ in 0..7 {
            short.push_str("VMServiceFlutterDriver: Isolate is paused at start.\n");
        }
        short.push_str("I/flutter ( 4457): 00:00 +1: (tearDownAll)\nAll tests passed.\n");
        let path = dir.write("short.drive.log", &short);
        let outcome = run(&manifest, "drive", &[path]);
        assert_eq!(outcome.lines.get("drive"), Some(&19));
        assert!(
            outcome.problems.is_empty(),
            "a nineteen-line transcript in which a test RAN proves enough: {:?}",
            outcome.problems
        );

        // The failing reporter's rendering (`+3 -1:`) is proof just the same:
        // a test that ran and failed is still a test that ran.
        let failed = short.replace("+0: M7 disable", "+3 -1: M7 disable");
        let path = dir.write("failed.drive.log", &failed);
        assert!(
            run(&manifest, "drive", &[path]).problems.is_empty(),
            "a failing run's reporter line proves a test started too"
        );

        let long = "D/FlutterGeolocator( 4457): Binding to location service.\n".repeat(500);
        let path = dir.write("long.drive.log", &long);
        let outcome = run(&manifest, "drive", std::slice::from_ref(&path));
        assert_eq!(outcome.lines.get("drive"), Some(&500));
        assert_eq!(outcome.rc(), RC_META);
        let message = &outcome.problems[0].message;
        assert!(message.contains("`drive`"), "{message}");
        assert!(
            !message.contains(&path.display().to_string()),
            "Rule 15: the problem names the class, never the capture's path: {message}"
        );

        // A class that declares no proof is untouched by any of it.
        let same = dir.write("long.rust-test.log", &long);
        assert!(
            run(&manifest, "rust-test", &[same]).problems.is_empty(),
            "only a class whose captures come from a test reporter carries the proof"
        );
    }

    /// Both reporters a `drive` capture can come from, on the real transcripts.
    ///
    /// `flutter` picks its reporter from the environment — `test_core`'s
    /// `defaultReporter` selects `github` whenever `GITHUB_ACTIONS == 'true'` —
    /// so the hosted coverage lane's transcript carries NO `HH:MM +N:` line at
    /// all, which is how CI run 35478132251 went rc 4 over 4 673 passing tests.
    /// Each fixture is scanned as-is and again with every line the pattern
    /// matches deleted, because a pattern that matched something else in the
    /// same file would pass the first half for the wrong reason.
    #[test]
    fn both_test_reporters_prove_a_run_and_neither_proves_one_without_its_line() {
        const COMPACT: &str = include_str!("../fixtures/furniture.flutter-test.log");
        const GITHUB: &str = include_str!("../fixtures/furniture.flutter-test-github.log");

        let dir = Dir::new("reporters");
        let manifest = manifest(&[]);
        let proof = regex::Regex::new(
            manifest
                .proof_of_run("drive")
                .expect("the drive class carries the proof"),
        )
        .expect("a valid pattern");

        for (name, body) in [("compact.drive.log", COMPACT), ("github.drive.log", GITHUB)] {
            let path = dir.write(name, body);
            assert!(
                run(&manifest, "drive", &[path]).problems.is_empty(),
                "{name}: a real transcript of a run that happened must prove it"
            );

            let mut silent = String::new();
            for line in body.lines().filter(|l| !proof.is_match(l)) {
                silent.push_str(line);
                silent.push('\n');
            }
            assert!(
                silent.lines().count() < body.lines().count(),
                "{name}: the mutation removed nothing, so the scan below proves nothing"
            );
            let path = dir.write(&format!("silent.{name}"), &silent);
            let outcome = run(&manifest, "drive", &[path]);
            assert_eq!(
                outcome.rc(),
                RC_META,
                "{name}: every other line of the same capture is not proof that a test ran: {:?}",
                outcome.problems
            );
        }

        // The regression itself: the pattern before run 35478132251 was the
        // compact branch alone, and the hosted lane's transcript satisfies it
        // nowhere. Written out rather than derived, so narrowing the shipped
        // pattern back to it cannot make this test agree with the change.
        let before = regex::Regex::new(r"[0-9]{2}:[0-9]{2} \+[0-9]+( -[0-9]+)?: ").expect("valid");
        assert!(
            !GITHUB.lines().any(|l| before.is_match(l)),
            "a github-reporter transcript carries no progress line; if one appears here the fixture is no longer that lane's capture"
        );
        assert!(
            COMPACT.lines().any(|l| before.is_match(l)),
            "the compact fixture must still carry the rendering a device run and every local run print"
        );
    }

    /// A progress reporter's carriage returns are RECORD boundaries, not text.
    ///
    /// `flutter test`'s compact reporter rewrites its status line with `\r` and
    /// no newline when it writes to a pipe, so one physical line carries many
    /// updates. Joined, the tail of one update (`… clears the key`) sits inside
    /// S8's 24-character window of the next update's path and timestamp, and
    /// every green Flutter lane would delete its own transcript. The control is
    /// the same text with the `\r` replaced by a space: it MUST fire, or this
    /// test would pass for the wrong reason.
    #[test]
    fn a_progress_reporters_carriage_returns_separate_records() {
        let dir = Dir::new("cr");
        let manifest = manifest(&[]);
        let segments = "00:02 +58: haven/test/secrets_store_test.dart: SecretsStore reads the key";
        let next = "00:02 +59: haven/test/providers/identity_provider_test.dart: ok";

        let joined = dir.write("joined.drive.log", &format!("{segments} {next}\n"));
        let control = run(&manifest, "drive", &[joined]);
        assert_eq!(
            control
                .findings
                .iter()
                .filter(|f| f.rule.as_deref() == Some("S8"))
                .count(),
            1,
            "the control must fire, or the split below proves nothing: {:?}",
            control.findings
        );

        let split = dir.write("split.drive.log", &format!("{segments}\r{next}\n"));
        let outcome = run(&manifest, "drive", &[split]);
        assert!(
            outcome.findings.is_empty(),
            "two updates on one physical line are two records: {:?}",
            outcome.findings
        );
        assert_eq!(
            outcome.lines.get("drive"),
            Some(&1),
            "the reported line number stays the PHYSICAL one"
        );
    }

    /// A capture in a rendering the sink class cannot frame is rc 3, never rc 0.
    ///
    /// It is the one failure that otherwise looks exactly like a clean run: the
    /// rules skip every line and nothing says why.
    #[test]
    fn an_ios_capture_in_an_unknown_rendering_is_unusable() {
        let dir = Dir::new("iosshape");
        let manifest = manifest(&[]);
        // A THIRD rendering: the BSD-style stamp older tooling writes, which is
        // neither `log show` shape this sink class frames.
        let path = dir.write(
            "other.ios.log",
            "Sep 12 10:00:00 iPhone Runner(Flutter)[431] <Notice>: fix -12.345678,98.765432\n\
             Sep 12 10:00:01 iPhone Runner(Flutter)[431] <Notice>: settled\n",
        );
        let outcome = run(&manifest, "ios", &[path]);
        assert_eq!(outcome.rc(), RC_UNUSABLE);
        assert!(
            outcome
                .problems
                .iter()
                .any(|p| p.message.contains("does not know")),
            "{:?}",
            outcome.problems
        );
    }

    /// Repeats on one line are counted, not duplicated, and the last line counts
    /// even without a trailing newline.
    #[test]
    fn occurrences_are_counted_per_line_and_the_last_line_counts() {
        let dir = Dir::new("count");
        let manifest = manifest(&[("pubkey", PUBKEY)]);
        let path = dir.write(
            "drive.log",
            &format!("[a] {PUBKEY} {PUBKEY}\n[b] no needle"),
        );
        let outcome = run(&manifest, "drive", &[path]);
        let hex = outcome
            .findings
            .iter()
            .find(|f| f.encoding.as_deref() == Some("hex-lower"))
            .expect("the needle is found");
        assert_eq!(
            hex.count, 2,
            "two occurrences on one line are one finding ×2"
        );
        assert_eq!(hex.line, 1);
        assert_eq!(
            outcome.lines.get("drive"),
            Some(&2),
            "a final unterminated line still counts"
        );
    }

    /// A shape plant proves the backend was installed AT LAUNCH, so only the
    /// opening token counts.
    #[test]
    fn a_shape_plant_must_be_the_opening_one() {
        let dir = Dir::new("shapephase");
        let manifest = manifest(&[]);
        let closing = dir.write(
            "closing.logcat.log",
            "09-12 10:00:00.001  1234  1301 D haven_core: logscan-plant-rust-close-MNPQRSTUVW\n\
             09-12 10:00:00.002  1234  1234 D HavenApplication: logscan-plant-kotlin-open-QRSTUVWXYZ\n",
        );
        let outcome = run(&manifest, "logcat", &[closing]);
        assert_eq!(outcome.rc(), RC_UNUSABLE);
        assert_eq!(outcome.problems.len(), 1, "{:?}", outcome.problems);
        assert!(
            outcome.problems[0].message.contains("`rust` opening plant"),
            "{:?}",
            outcome.problems
        );

        let opening = dir.write(
            "opening.logcat.log",
            "09-12 10:00:00.001  1234  1301 D haven_core: logscan-plant-rust-open-MNPQRSTUVW\n\
             09-12 10:00:00.002  1234  1234 D HavenApplication: logscan-plant-kotlin-open-QRSTUVWXYZ\n",
        );
        let outcome = run(&manifest, "logcat", &[opening]);
        assert!(outcome.problems.is_empty(), "{:?}", outcome.problems);
    }

    /// The transcript a host lane really writes: `LogNeedles.plant` prints its
    /// token whether or not a recorder is there to declare it, so on a lane
    /// sealed `--declared-plants none` both phases reach the sink undeclared.
    /// That is the harness's documented behaviour, not a lost declaration.
    #[test]
    fn a_channel_less_manifest_forgives_an_undeclared_dart_plant() {
        let dir = Dir::new("hostplant");
        let mut manifest = manifest(&[("pubkey", PUBKEY)]);
        manifest.declared_plants = crate::plants::DeclaredPlants::None;
        let path = dir.write("host.drive.log", HOST_DRIVE);
        let outcome = run(&manifest, "drive", &[path]);
        assert_eq!(outcome.rc(), RC_CLEAN, "{:?}", outcome.problems);
        assert_eq!(outcome.plants_required, 0);
    }

    /// The same bytes under a manifest that DID have a channel: each phase is a
    /// declaration that never arrived, and the verdict is unchanged.
    #[test]
    fn a_manifest_with_a_channel_still_reports_an_undeclared_dart_plant() {
        let dir = Dir::new("channelplant");
        let manifest = manifest(&[("pubkey", PUBKEY)]);
        assert_eq!(
            manifest.declared_plants,
            crate::plants::DeclaredPlants::Dart
        );
        let path = dir.write("channel.drive.log", HOST_DRIVE);
        let outcome = run(&manifest, "drive", &[path]);
        assert_eq!(outcome.rc(), RC_UNUSABLE);
        let lost: Vec<&super::Problem> = outcome
            .problems
            .iter()
            .filter(|p| p.message.contains("matches no declaration"))
            .collect();
        assert_eq!(lost.len(), 2, "one per phase: {:?}", outcome.problems);
        assert_eq!(
            lost[0].message,
            "a Dart plant token in a scanned sink matches no declaration; a declaration was lost between the app and the sidecar"
        );
    }

    /// Real furniture from CI run 34766632019, rule-scanned in both framings.
    ///
    /// The self-test's case N scans the same two files with a sealed manifest;
    /// this is the `cargo test`-visible half, and it names the rule and the line
    /// so a tightening that would redden a real lane is diagnosed at the shape
    /// rather than at the file.
    #[test]
    fn real_furniture_trips_no_structural_rule() {
        let dir = Dir::new("furniture");
        let manifest = manifest(&[]);
        for (class, name, body) in [
            (
                "drive",
                "furniture.drive.log",
                include_str!("../fixtures/furniture.drive.log"),
            ),
            (
                "logcat",
                "furniture.logcat.log",
                include_str!("../fixtures/furniture.logcat.log"),
            ),
            (
                "rust-test",
                "furniture.rust-test.log",
                include_str!("../fixtures/furniture.rust-test.log"),
            ),
            (
                "drive",
                "furniture.flutter-test.log",
                include_str!("../fixtures/furniture.flutter-test.log"),
            ),
            // The same lane, the other reporter: `flutter test` prints the
            // github rendering whenever `GITHUB_ACTIONS == 'true'`, so this is
            // what `coverage.yml` actually scans and the one above is what a
            // local capture looks like.
            (
                "drive",
                "furniture.flutter-test-github.log",
                include_str!("../fixtures/furniture.flutter-test-github.log"),
            ),
        ] {
            let path = dir.write(name, body);
            let outcome = run(&manifest, class, &[path]);
            let hits: Vec<String> = outcome
                .findings
                .iter()
                .map(|f| format!("{}:{}", f.rule.clone().unwrap_or_default(), f.line))
                .collect();
            assert!(hits.is_empty(), "{class} furniture is not clean: {hits:?}");
            assert_eq!(
                outcome.lines.get(class),
                Some(&u64::try_from(body.lines().count()).expect("line count")),
                "{class} furniture lost lines"
            );
        }
    }

    /// A colour code inside a hex run must not hide the needle it splits.
    ///
    /// This is the recall half of the escape stripper: `ESC[0m` in the middle of
    /// a 64-hex value leaves two runs the automaton has no term for, and both
    /// are below S1's floor, so the value would be invisible to needles AND
    /// rules. The control is the same value with no escape in it.
    #[test]
    fn an_escape_inside_a_hex_run_does_not_hide_the_needle() {
        let dir = Dir::new("ansi");
        let manifest = manifest(&[("pubkey", PUBKEY)]);
        let (head, tail) = PUBKEY.split_at(31);
        let path = dir.write(
            "coloured.drive.log",
            &format!("[fixture] plain {PUBKEY}\n[fixture] coloured {head}\u{1b}[0m{tail}\n"),
        );
        let lines: Vec<u64> = run(&manifest, "drive", &[path])
            .findings
            .iter()
            .filter(|f| f.encoding.as_deref() == Some("hex-lower"))
            .map(|f| f.line)
            .collect();
        assert_eq!(
            lines,
            vec![1, 2],
            "the split value must be found on its own line, like the plain one"
        );
    }

    /// The stripper removes the framing cargo actually emits, and nothing else.
    ///
    /// Both inputs are verbatim from a `CARGO_TERM_COLOR=always` run: an SGR
    /// pair around the verb, and the OSC-8 hyperlink cargo wraps the profile
    /// name in. The assertion is equality with the uncoloured line, because
    /// "some escapes removed" is what silently leaves one inside a value.
    #[test]
    fn a_coloured_cargo_line_strips_to_the_plain_one() {
        let strip = |text: &str| -> String {
            let mut state = super::Escape::default();
            String::from_utf8(super::strip_escapes(&mut state, text.as_bytes()).into_owned())
                .expect("stripping keeps valid utf-8")
        };
        assert_eq!(
            strip("\u{1b}[1m\u{1b}[92m   Compiling\u{1b}[0m geo-types v0.7.19\n"),
            "   Compiling geo-types v0.7.19\n"
        );
        // The hyperlink's TARGET survives: an OSC payload is content, and a URL
        // is exactly what S7 and the needle search exist to see. Only the
        // introducer (`ESC ] 8 ; ;`) and the terminator come off.
        assert_eq!(
            strip(
                "\u{1b}[1m\u{1b}[92m    Finished\u{1b}[0m \u{1b}]8;;https://doc.rust-lang.org/cargo/reference/profiles.html#default-profiles\u{1b}\\`dev` profile [unoptimized + debuginfo]\u{1b}]8;;\u{1b}\\ target(s) in 22.61s\n"
            ),
            "    Finished https://doc.rust-lang.org/cargo/reference/profiles.html#default-profiles`dev` profile [unoptimized + debuginfo] target(s) in 22.61s\n"
        );
        // …and a hyperlink whose target IS an identifier is caught, which is the
        // whole reason the payload is kept.
        let mut engine_state = super::Escape::default();
        let linked = super::strip_escapes(
            &mut engine_state,
            "dialing \u{1b}]8;;wss://relay.example.com\u{1b}\\the relay\u{1b}]8;;\u{1b}\\\n"
                .as_bytes(),
        )
        .into_owned();
        let linked = String::from_utf8(linked).expect("utf-8");
        assert!(
            rules()
                .evaluate(linked.trim_end(), "/tmp/fixture.log", None)
                .iter()
                .any(|hit| hit.rule == "S7"),
            "a URL inside a terminal hyperlink is still a URL: {linked:?}"
        );
        // A sequence split by a chunk boundary is still removed whole, and an
        // unterminated one ends at the newline rather than eating the record
        // after it.
        let mut state = super::Escape::default();
        let first = super::strip_escapes(&mut state, b"id \x1b[").into_owned();
        let second = super::strip_escapes(&mut state, b"0mcafe\n").into_owned();
        assert_eq!([first, second].concat(), b"id cafe\n");
        assert_eq!(
            strip("truncated \u{1b}[1\nnext line\n"),
            "truncated \nnext line\n"
        );
    }

    /// Cargo's status lines are furniture on a `rust-test` sink, and only there.
    ///
    /// The same line in a drive transcript is app output, so the rules keep
    /// reading it; the same line carrying a DECLARED value is a needle hit in
    /// both. That pair is what makes the exemption an exemption rather than a
    /// blind spot.
    #[test]
    fn a_cargo_status_line_is_structural_furniture_only_on_a_cargo_transcript() {
        let dir = Dir::new("cargofurniture");
        let manifest = manifest(&[("pubkey", PUBKEY)]);
        // A synthetic revision, deliberately NOT a prefix of the declared
        // pubkey: this arm is about the structural rules, and a needle hit
        // would make either verdict unreadable.
        let body = "   Compiling cgka-traits v0.9.4 (https://github.com/marmot-protocol/mdk?rev=7d4e1c9b3a2f85607d4e1c9b3a2f85607d4e1c9b#7d4e1c9b)\n".to_owned();

        let cargo = dir.write("cargo.rust-test.log", &body);
        assert!(
            run(&manifest, "rust-test", &[cargo]).findings.is_empty(),
            "a pinned dependency revision is not a Haven identifier"
        );

        let drive = dir.write("cargo.drive.log", &body);
        let rules: Vec<String> = run(&manifest, "drive", &[drive])
            .findings
            .iter()
            .filter_map(|f| f.rule.clone())
            .collect();
        assert_eq!(
            rules,
            vec!["S2".to_owned()],
            "the exemption belongs to the cargo transcript sink, not to the shape"
        );

        let declared = dir.write(
            "declared.rust-test.log",
            &format!("   Compiling evil v0.1.0 (git+https://example.invalid/e?rev={PUBKEY})\n"),
        );
        let outcome = run(&manifest, "rust-test", &[declared]);
        assert!(
            outcome
                .findings
                .iter()
                .any(|f| f.kind == FindingKind::Needle),
            "a declared value cannot hide behind a cargo verb: {:?}",
            outcome.findings
        );
        assert!(
            outcome
                .findings
                .iter()
                .any(|f| f.rule.as_deref() == Some("S1")),
            "only S2 and S6 are furniture here: a 64-hex run on a cargo line is still S1: {:?}",
            outcome.findings
        );
    }

    /// The evasions a wider exemption allowed, each now a rule hit again.
    ///
    /// `--rules-only` is the whole net on a unit-test transcript: there is no
    /// manifest, so a shape the rules skip is a shape nothing sees. Every line
    /// here passed for cargo furniture while the exemption reached past the
    /// crate-version shape — an unbounded tail is a slot, and a slot is where a
    /// value goes. The `Running unittests` control is the fixture header's own
    /// claim ("sixteen hex is a build hash, and no rule may read it as an id"),
    /// which only means something while that line is NOT exempt.
    #[test]
    fn a_cargo_verb_does_not_exempt_the_rest_of_the_line() {
        let dir = Dir::new("cargoevasion");
        let manifest = manifest(&[]);
        for (name, line, want) in [
            (
                "doctests",
                "   Doc-tests 0a1b2c3d4e5f60718293a4b5c6d7e8f9",
                Some("S2"),
            ),
            (
                "cratename",
                "   Compiling 0a1b2c3d4e5f60718293a4b5c6d7e8f9 v1.2.3",
                Some("S2"),
            ),
            (
                "runningtarget",
                "     Running x (target/40.7128,-74.0060)",
                Some("S5"),
            ),
            (
                "updatingurl",
                "    Updating git repository `wss://relay.example.com`",
                Some("S7"),
            ),
            (
                "ipv6source",
                "   Compiling evil v1.2.3 (2001:db8::1)",
                Some("S12"),
            ),
            (
                "buildhash",
                "     Running unittests src/lib.rs (target/debug/deps/haven_core-78272f4b45ab4866)",
                None,
            ),
        ] {
            let path = dir.write(&format!("{name}.rust-test.log"), &format!("{line}\n"));
            let rules: Vec<String> = run(&manifest, "rust-test", &[path])
                .findings
                .iter()
                .filter_map(|f| f.rule.clone())
                .collect();
            match want {
                Some(rule) => assert!(
                    rules.iter().any(|fired| fired == rule),
                    "{rule} must still fire on {line:?}; fired {rules:?}"
                ),
                None => assert!(
                    rules.is_empty(),
                    "a cargo build hash is sixteen hex and no rule may read it as an id: {rules:?}"
                ),
            }
        }
    }

    /// `--plants-in` must name a file the scan is actually reading.
    #[test]
    fn plants_in_must_name_a_scanned_file() {
        let dir = Dir::new("plantsin");
        let manifest = manifest(&[]);
        let path = dir.write("drive.log", "[fixture] nothing here\n");
        let mut plants_in = BTreeMap::new();
        plants_in.insert("drive".to_owned(), dir.0.join("somewhere-else.log"));
        let outcome = scan_sinks(
            &manifest,
            &[SinkArg {
                class: "drive".to_owned(),
                paths: vec![path],
            }],
            &BTreeMap::new(),
            &plants_in,
            &rules(),
            false,
            super::ScanMode::Full,
        );
        assert_eq!(outcome.rc(), RC_GUARD);
    }

    /// A sink class the manifest does not know is a broken invocation, and a
    /// directory handed in as a sink is an unusable one.
    #[test]
    fn an_unknown_sink_class_and_a_directory_are_named_differently() {
        let dir = Dir::new("shapes");
        let manifest = manifest(&[]);
        let outcome = scan_sinks(
            &manifest,
            &[SinkArg {
                class: "not-a-class".to_owned(),
                paths: vec![dir.0.clone()],
            }],
            &BTreeMap::new(),
            &BTreeMap::new(),
            &rules(),
            false,
            super::ScanMode::Full,
        );
        assert_eq!(outcome.rc(), RC_GUARD);

        let outcome = run(&manifest, "drive", std::slice::from_ref(&dir.0));
        assert_eq!(outcome.rc(), RC_UNUSABLE);
        assert!(
            outcome.problems[0].message.contains("not a regular file"),
            "{:?}",
            outcome.problems
        );
    }
}
