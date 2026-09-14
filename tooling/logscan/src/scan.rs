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
//! * **needles** — every line of every file, because a declared value in a
//!   vendor line is still a disclosure in an uploaded artifact. Class scoping
//!   (`relay` holds pubkeys legitimately) and the sink's term floor do the
//!   narrowing.
//! * **rules** — Haven-owned lines only, and never on a `relay` sink. For
//!   `logcat` they see the MESSAGE BODY rather than the whole line (the host's
//!   own timestamp is a documented residual, not a Haven leak); for `ios` and
//!   `plain` sinks the body IS the line, framing included.
//! * **cross-entry reassembly** — `logcat` only. `android_logger` chunks a
//!   record at ~4000 B and Kotlin's `Log.*` has its own per-entry cap, so
//!   consecutive entries sharing pid/tid/tag are re-joined with each entry's
//!   whitespace runs collapsed to one space — including the leading run, which
//!   is what keeps `hex-spaced`, `debug-array` and Rust's multi-line `{:#x?}`
//!   dump matchable across a split — and a hit is reported only when it SPANS a
//!   join, since anything else was already found on its own line.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use aho_corasick::{AhoCorasick, AhoCorasickBuilder, MatchKind};
use regex::Regex;

use crate::expand::Term;
use crate::manifest::Manifest;
use crate::plants::{self, PlantSlot};
use crate::policy::{EntryFormat, SinkSpec};
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

/// One `--sink <class>=<path>[,<path>…]`.
#[derive(Clone, Debug)]
pub struct SinkArg {
    /// The sink class.
    pub class: String,
    /// The files, in the order given.
    pub paths: Vec<PathBuf>,
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
    /// The log tag, for logcat and `log show` sinks. `None` elsewhere: a line
    /// PREFIX can carry remote-authored text, which Rule 15 forbids printing.
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
    /// Declared plants caught, out of those required.
    pub plants_caught: usize,
    /// Declared plant requirements.
    pub plants_required: usize,
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
#[must_use]
pub fn scan_sinks(
    manifest: &Manifest,
    sinks: &[SinkArg],
    segments: &BTreeMap<String, usize>,
    plants_in: &BTreeMap<String, PathBuf>,
    rules: &RuleSet,
    disclose: bool,
) -> Outcome {
    let mut outcome = Outcome::default();
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
                    reconcile_plants: plants_in.get(&sink.class).is_none_or(|only| only == path),
                },
                &mut tally,
                &mut outcome,
            );
        }
    }

    check_floors(manifest, sinks, &mut outcome);
    check_plants(manifest, sinks, &plant_counts, &shape_seen, &mut outcome);
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
    // whichever device log the platform writes. Requiring it in exactly the
    // classes this scan names derives the platform instead of hard-coding it.
    let declared_classes: Vec<&str> = ["logcat", "ios", "drive"]
        .into_iter()
        .filter(|c| classes.contains(c))
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
    // the plants exist to detect.
    let known: std::collections::BTreeSet<&str> = manifest
        .plants
        .iter()
        .flat_map(|slot| {
            std::iter::once(slot.token.as_str()).chain(slot.superseded.iter().map(String::as_str))
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

/// One streaming pass over one file.
fn scan_file(
    path: &Path,
    spec: &SinkSpec,
    needles: &Needles<'_>,
    rules: &RuleSet,
    plant_shape: &Regex,
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
    let mut line_no: u64 = 1;
    let mut needle_lines: std::collections::BTreeSet<u64> = std::collections::BTreeSet::new();
    let mut reassembly = Reassembly::default();
    let sink_path = path.display().to_string();
    let ctx = LineCtx {
        spec,
        needles,
        rules,
        plant_shape,
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
        report.bytes += u64::try_from(read).unwrap_or(u64::MAX);
        let fresh = &chunk[..read];

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
    // Only for a line the window pass already matched on. The window pass for a
    // chunk completes before the line pass of the same chunk, and a match
    // straddling a chunk boundary lands on the line still open at that boundary
    // — which this pass emits in the new chunk — so the set is always populated
    // before the line that needs it arrives.
    if needle_lines.contains(&line_no) {
        if let Some(tag) = framed.tag.clone() {
            report.tags.insert(line_no, tag);
        }
    }
    for found in ctx.plant_shape.find_iter(framed.body) {
        *report.plants.entry(found.as_str().to_owned()).or_default() += 1;
    }
    if ctx.spec.structural_rules && framed.owned {
        for hit in ctx
            .rules
            .evaluate(framed.body, ctx.sink_path, framed.tag.as_deref())
        {
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
    sink_path: &'a str,
    disclose: bool,
}

/// A line split into the part Haven owns and the framing around it.
struct Framed<'a> {
    body: &'a str,
    /// The tag the REPORT may print: present only when Haven owns it, because a
    /// vendor tag is not ours to publish.
    tag: Option<String>,
    /// The tag as parsed, owned or not. The reassembly key needs the real tag:
    /// keying on the reportable one would join two DIFFERENT vendor entries
    /// that merely share a pid and a tid, and a spurious needle hit is rc 1,
    /// which deletes the sink.
    raw_tag: Option<String>,
    pid: Option<String>,
    tid: Option<String>,
    owned: bool,
}

/// Splits a line according to its sink's framing.
fn frame<'a>(spec: &SinkSpec, text: &'a str) -> Framed<'a> {
    match spec.entry_format {
        EntryFormat::Plain => Framed {
            body: text,
            tag: None,
            raw_tag: None,
            pid: None,
            tid: None,
            owned: true,
        },
        EntryFormat::Logcat => parse_logcat(spec, text),
        EntryFormat::Ios => {
            let process = spec
                .owned_processes
                .iter()
                .find(|p| text.contains(p.as_str()))
                .cloned();
            Framed {
                body: text,
                owned: process.is_some(),
                raw_tag: process.clone(),
                tag: process,
                pid: None,
                tid: None,
            }
        }
    }
}

/// `MM-DD HH:MM:SS.mmm  pid  tid P tag: message` — `adb logcat -v threadtime`.
///
/// A line that does not parse is treated as NOT Haven-owned, so the structural
/// rules skip it. That is the right default for a device-wide capture full of
/// vendor framing; needles are still searched in every byte of it.
fn parse_logcat<'a>(spec: &SinkSpec, text: &'a str) -> Framed<'a> {
    let unparseable = Framed {
        body: text,
        tag: None,
        raw_tag: None,
        pid: None,
        tid: None,
        owned: false,
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
    let Some((tag, body)) = text[cursor..].split_once(':') else {
        return unparseable;
    };
    let tag = tag.trim();
    let owned = spec
        .owned_tags
        .iter()
        .any(|candidate| candidate.eq_ignore_ascii_case(tag));
    Framed {
        body: body.strip_prefix(' ').unwrap_or(body),
        tag: owned.then(|| tag.to_owned()),
        raw_tag: Some(tag.to_owned()),
        pid: Some(pid.to_owned()),
        tid: Some(tid.to_owned()),
        owned,
    }
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
    use crate::{RC_GUARD, RC_UNUSABLE};

    const PUBKEY: &str = "0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9";
    const MLS_GROUP_ID: &str = "3f4a5b6c7d8e9f0a1b2c3d4e5f6071823f4a5b6c7d8e9f0a1b2c3d4e5f607182";

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

    /// `log show` exports are scoped by process name.
    #[test]
    fn an_ios_sink_is_scoped_by_process_name() {
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
