//! Structural rules S1–S12 and the allowlist that can forgive one.
//!
//! A needle rule catches the values this run declared. The structural rules
//! catch the ones it did not: a pubkey minted by a peer, an event id the relay
//! assigned, a coordinate the OS produced. They are the half of the instrument
//! that still works when the declaration channel misses something.
//!
//! # Scope
//!
//! They run on **Haven-owned lines only** (the tag/process scoping in
//! [`crate::scan`]) and never on a `relay` sink. A relay log holding pubkeys and
//! event ids is not a Haven leak, and a guard that cries wolf on vendor output
//! is a guard that gets deleted (`tooling/e2e/ci/scan-logs-for-secrets.sh:98-110`).
//!
//! # The seven bash patterns are NOT duplicated here
//!
//! `tooling/e2e/ci/scan-logs-for-secrets.sh` stays the toolchain-free
//! key-material floor and the wrapper runs both scanners. Re-implementing its
//! patterns would double every future edit and halve the chance both copies stay
//! right.

use std::collections::BTreeSet;

use regex::{Regex, RegexSet};
use serde::{Deserialize, Serialize};

/// One structural rule: an id, the shapes that trigger it, and why it exists.
struct Rule {
    id: &'static str,
    patterns: &'static [&'static str],
}

/// Every rule, in id order. One positive and one negative fixture per rule is
/// asserted individually by `fixtures_cover_every_rule`.
const RULES: &[Rule] = &[
    Rule {
        id: "S1",
        // A 64-hex run is a pubkey, an event id, a signature half, an MLS
        // group id or a SQLCipher passphrase. None of them may be in a log.
        patterns: &[r"(?:^|[^0-9A-Fa-f])[0-9A-Fa-f]{64,}(?:[^0-9A-Fa-f]|$)"],
    },
    Rule {
        id: "S2",
        // 32..63 hex is the truncated form: an 8/16-char prefix is still a join
        // key for anyone holding the full value, and 32 hex is a 16-byte id.
        patterns: &[r"(?:^|[^0-9A-Fa-f])[0-9A-Fa-f]{32,63}(?:[^0-9A-Fa-f]|$)"],
    },
    Rule {
        id: "S3",
        // Bech32 of ANY hrp: npub/nsec/note/nevent/naddr/nprofile today, and
        // whatever NIP-19 adds tomorrow.
        patterns: &[r"(?i)(?:^|[^0-9A-Za-z])[a-z]{2,12}1[ac-hj-np-z02-9]{20,}(?:[^0-9A-Za-z]|$)"],
    },
    Rule {
        id: "S4",
        // base64 of >= 24 bytes, above a Shannon floor so a long camel-case
        // identifier is not mistaken for ciphertext.
        patterns: &[r"[A-Za-z0-9+/]{32,}={0,2}"],
    },
    Rule {
        id: "S5",
        // A decimal coordinate pair. Three decimals is ~100 m; two would match
        // version numbers and percentages.
        patterns: &[r"-?\d{1,3}\.\d{3,}\s*,\s*-?\d{1,3}\.\d{3,}"],
    },
    Rule {
        id: "S6",
        // The keyword must be delimited and SEPARATED from the cell by at
        // least one non-alphanumeric character. The "at least one" half is what
        // keeps the rule out of any base32-ish token that happens to contain
        // `gh` — a positive-control plant's alphabet shares 30 of its 32
        // characters with geohash's, and a rule that reddens the control is a
        // rule that deletes the evidence. The upper bound is 8 rather than 3
        // only so the renderings that actually occur all fit:
        // `geohash=u4pruyd`, `gh: u4pruyd`, `"geohash" : "u4pruyd"`,
        // `geohash -> u4pruyd` and the escaped-JSON `\"geohash\": \"u4pruyd\"`.
        patterns: &[
            r"(?i)(?:^|[^0-9A-Za-z])(?:geohash|geo|gh)[^0-9A-Za-z]{1,8}([0-9bcdefghjkmnpqrstuvwxyz]{5,12})",
        ],
    },
    Rule {
        id: "S7",
        // Every `ws`/`wss` URL, the default pool included (owner-directed): a
        // pool membership is a fingerprint, and a custom relay is worse.
        patterns: &[r#"(?i)wss?://[^\s"'<>\\]+"#],
    },
    Rule {
        id: "S8",
        // The blob is captured so `is_real_hit` can ask whether it looks
        // ENCODED: `KeyPackageMaintenanceFailed` and
        // `KeyCipherImplementationRSA18` are a long alphanumeric run next to
        // the word `key` too, and a rule that reddens on a Rust enum variant is
        // a rule that gets deleted.
        patterns: &[r"(?i)(?:secret|nsec|seed|key)[^\n]{0,24}?([A-Za-z0-9+/]{24,}={0,2})"],
    },
    Rule {
        id: "S9",
        // A 32-element decimal array is key material or a 32-byte group id.
        patterns: &[r"\[\s*\d{1,3}(?:\s*,\s*\d{1,3}){31}\s*\]"],
    },
    Rule {
        id: "S10",
        patterns: &[
            r#"(?i)(?:^|[^a-z_])(?:display_name|petname|circle_name|name)\s*[=:]\s*"?([^\s",;}\]]{2,})"#,
        ],
    },
    Rule {
        id: "S11",
        // An absolute publish/receive instant correlates a log with a relay's
        // `created_at` history.
        patterns: &[
            r"(?i)(?:publish|sent|received|since)[^\n]{0,40}?[^0-9](1[0-9]{9})(?:[^0-9]|$)",
        ],
    },
    Rule {
        id: "S12",
        // The IPv6 literal must be delimited by NON-WORD characters on both
        // sides and (in `is_real_hit`) carry a digit. A Rust module path is the
        // shape this rule is otherwise indistinguishable from: every `::` in
        // `haven_core::relay::manager` has a letter on each side, and
        // `Option::Some` has one on both.
        patterns: &[
            r"(?:^|[^0-9.])((?:\d{1,3}\.){3}\d{1,3})(?:[^0-9.]|$)",
            r"(?i)(?:^|[^A-Za-z0-9_:])((?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,7}:(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6})?|::(?:[0-9a-f]{1,4}:){0,6}[0-9a-f]{1,4})(?:[^A-Za-z0-9_:]|$)",
        ],
    },
];

/// The ONE cargo status line that trips a structural rule: a crate being built,
/// with its version and, for a git or path dependency, its source.
///
/// Cargo prints the public pinned git REVISION of every git dependency and the
/// NAME of every crate it touches before a single test runs, so a cold run
/// carries a 40-hex run per MDK crate (S2) and `geo-types` (S6 — a `geo`
/// keyword next to five base32 letters). Neither is a Haven identifier: both
/// are public facts about this tree's dependency list, printed by the toolchain
/// rather than by the app. `rust-test` therefore skips [`CARGO_STATUS_RULES`] on
/// lines of this shape (`cargo_status = "exempt"` in `policy.toml`, which is
/// where the per-sink answer lives).
///
/// Cargo's OTHER status lines — `Finished`, `Running`, `Doc-tests`, `Updating`,
/// `Downloading` — are deliberately NOT here. They trip no rule as cargo prints
/// them (`the_cargo_lines_that_need_no_exemption_are_clean_on_their_own` is the
/// proof), so exempting them would buy nothing and cost everything: each of
/// those tails is unbounded, which is a slot an app print can land a value in.
/// `Doc-tests <32 hex>`, `Running x (target/<coordinate pair>)` and an
/// `Updating git repository` line naming a `wss://` URL all used to pass for
/// furniture.
///
/// Every field is bounded for the same reason. The crate name is a cargo crate
/// name (`[A-Za-z][A-Za-z0-9_-]*`, which no `<key>=<value>` print can occupy),
/// the version is a bare semver triple, and the source must open with a scheme
/// or a path separator, so `(2001:db8::1)` is not a source.
///
/// What is left inside is the residual, and the README states it in one
/// sentence rather than pretending it away: a 32–63-hex run or a
/// geohash-shaped token in the crate-name or source-URL slot of a
/// `Compiling|Checking|Downloaded <name> v<semver>` line, on the `rust-test`
/// sink only. A hex run that begins with a LETTER does fit the name slot; what
/// bounds the residual is that S2 and S6 are the only rules skipped, that the
/// needle search still reads the line, and that the whole shape has to be
/// produced deliberately.
///
/// Both verbs and shapes are verbatim from the `cargo test`, `cargo clippy` and
/// `cargo build` transcripts of CI run 35244067610 (the run this exemption was
/// paid for) and from `fixtures/furniture.rust-test.log`; none is guessed from
/// cargo's source.
const CARGO_STATUS: &str = concat!(
    r"^\s*(?:Compiling|Checking|Downloaded) ",
    r"[A-Za-z][A-Za-z0-9_-]* v\d+\.\d+\.\d+",
    r"(?: \((?:[a-z+]+)?(?:/|https://)[^)\s]*\))?$",
);

/// The rules a cargo status line is furniture FOR, and no others.
///
/// S2 is the pinned git revision and S6 the crate name — the two shapes cargo's
/// own output actually carries. Every other rule still runs on the line, so a
/// coordinate, a URL, an IP or a 64-hex run inside a cargo-shaped line is
/// reported exactly as it would be anywhere else.
const CARGO_STATUS_RULES: &[&str] = &["S2", "S6"];

/// Placeholders S10 must not fire on: the redactions and alias handles the tree
/// prints deliberately.
const PLACEHOLDERS: &[&str] = &[
    "<redacted>",
    "redacted",
    "<none>",
    "none",
    "null",
    "nil",
    "<empty>",
    "***",
    "-",
];

/// One allowlist entry. Structural hits only: a needle hit has no allowlist
/// path, because a needle IS a value this run minted and there is no benign
/// reason for it to be in a log.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AllowEntry {
    /// The rule id this entry forgives.
    pub rule: String,
    /// Where it applies.
    pub scope: AllowScope,
    /// A regex the LINE must match.
    pub pattern: String,
    /// Why this is not a leak.
    pub justification: String,
    /// `file:line` or a test name that proves the justification.
    pub proof: String,
    /// Who owns the exception.
    pub owner: String,
    /// `YYYY-MM-DD`. Past it, the entry is rc 2: stale allowances cannot
    /// accumulate.
    pub expires: String,
}

/// The scope of an allowlist entry.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AllowScope {
    /// A `*`-glob over the sink path.
    pub sink_glob: String,
    /// The log tag, when the exception is tag-specific.
    #[serde(default)]
    pub tag: Option<String>,
}

/// A compiled allowlist entry.
struct CompiledAllow {
    entry: AllowEntry,
    pattern: Regex,
}

/// A structural hit.
#[derive(Clone, Debug)]
pub struct RuleHit {
    /// The rule id.
    pub rule: &'static str,
    /// The matched text. Carried ONLY so `--disclose-values` can print it for
    /// local triage; every other output path must ignore it.
    pub matched: String,
}

/// A date as `(year, month, day)`, compared lexicographically.
pub type Today = (u32, u32, u32);

/// The compiled rule engine.
pub struct RuleSet {
    regexes: Vec<Regex>,
    /// Rule id per regex index; a rule may own several shapes (S12 does).
    ids: Vec<&'static str>,
    set: RegexSet,
    cargo_status: Regex,
    entropy_bits: f64,
    epoch_window: (u64, u64),
    exempt: BTreeSet<String>,
    allow: Vec<CompiledAllow>,
    /// Test-only mutation: the rule whose hits are suppressed, so a fixture set
    /// that stops depending on a rule can be shown to go red.
    #[cfg(test)]
    disabled: Option<&'static str>,
}

impl RuleSet {
    /// Builds the engine.
    ///
    /// `now_unix` anchors S11's epoch window; `exempt` holds the endpoint
    /// spellings S7 and S12 skip (the lane's own loopback relay and proxy).
    ///
    /// # Errors
    ///
    /// Returns a message when a rule or an allowlist pattern does not compile.
    pub fn new(
        entropy_bits: f64,
        now_unix: u64,
        exempt: &[String],
        allow: Vec<AllowEntry>,
    ) -> Result<Self, String> {
        let mut regexes = Vec::new();
        let mut ids = Vec::new();
        let mut sources = Vec::new();
        for rule in RULES {
            for pattern in rule.patterns {
                let compiled = Regex::new(pattern)
                    .map_err(|e| format!("rule {} does not compile: {e}", rule.id))?;
                regexes.push(compiled);
                ids.push(rule.id);
                sources.push(*pattern);
            }
        }
        let set = RegexSet::new(&sources).map_err(|e| format!("rule set does not compile: {e}"))?;
        let mut compiled_allow = Vec::with_capacity(allow.len());
        for entry in allow {
            let pattern = Regex::new(&entry.pattern).map_err(|e| {
                format!("allowlist pattern for {} does not compile: {e}", entry.rule)
            })?;
            compiled_allow.push(CompiledAllow { entry, pattern });
        }
        Ok(Self {
            regexes,
            ids,
            set,
            cargo_status: Regex::new(CARGO_STATUS)
                .map_err(|e| format!("the cargo status shape does not compile: {e}"))?,
            entropy_bits,
            // Floor: 2020-01-01. Ceiling: a year out, so a fixture's fixed
            // timestamp stays inside the window forever while a future stamp
            // cannot sneak past as "not yet plausible".
            epoch_window: (1_577_836_800, now_unix.saturating_add(31_536_000)),
            exempt: exempt.iter().cloned().collect(),
            allow: compiled_allow,
            #[cfg(test)]
            disabled: None,
        })
    }

    /// Every rule id, in order. Used by the fixture coverage assertion.
    #[must_use]
    pub fn ids() -> Vec<&'static str> {
        let mut ids: Vec<&'static str> = RULES.iter().map(|r| r.id).collect();
        ids.dedup();
        ids
    }

    /// Whether `line` is one of cargo's own status lines ([`CARGO_STATUS`]).
    #[must_use]
    pub fn is_cargo_status(&self, line: &str) -> bool {
        self.cargo_status.is_match(line)
    }

    /// Whether this HIT is cargo furniture: the right rule ([`CARGO_STATUS_RULES`])
    /// on a line of the right shape, in a sink class that says so.
    ///
    /// Both halves are required. A rule outside the pair still fires on a
    /// cargo-shaped line, and the pair still fires on every other line, so the
    /// exemption is one shape's two rules rather than a sink-wide licence.
    #[must_use]
    pub fn is_cargo_furniture(&self, rule: &str, line: &str) -> bool {
        CARGO_STATUS_RULES.contains(&rule) && self.is_cargo_status(line)
    }

    /// Evaluates one Haven-owned line.
    #[must_use]
    pub fn evaluate(&self, line: &str, sink_path: &str, tag: Option<&str>) -> Vec<RuleHit> {
        let mut hits = Vec::new();
        for index in self.set.matches(line) {
            let id = self.ids[index];
            #[cfg(test)]
            if self.disabled == Some(id) {
                continue;
            }
            let regex = &self.regexes[index];
            for capture in regex.captures_iter(line) {
                let whole = capture.get(0).map_or("", |m| m.as_str());
                if !self.is_real_hit(id, &capture, whole, line) {
                    continue;
                }
                if self.is_allowlisted(id, line, sink_path, tag) {
                    continue;
                }
                hits.push(RuleHit {
                    rule: id,
                    matched: whole.to_owned(),
                });
                break;
            }
        }
        hits
    }

    /// The post-filters: the part of a rule a regex cannot express.
    fn is_real_hit(
        &self,
        id: &str,
        capture: &regex::Captures<'_>,
        whole: &str,
        line: &str,
    ) -> bool {
        match id {
            "S4" => {
                let blob = longest_base64_run(whole);
                is_base64_payload(blob, whole.contains('='), self.entropy_bits)
            }
            // A geohash is base32: a bare run of digits next to the word "geo"
            // is a number (a count, a port, a duration), not a cell. And a cell
            // inside a code path is a module name.
            "S6" => {
                let (Some(all), Some(cell)) = (capture.get(0), capture.get(1)) else {
                    return false;
                };
                cell.as_str().chars().any(char::is_alphabetic) && !is_code_path(line, all, cell)
            }
            "S7" => !self.is_exempt_endpoint(whole),
            "S8" => capture.get(1).is_some_and(|blob| {
                !runs_into_a_word(line, blob.start())
                    && looks_encoded(blob.as_str(), self.entropy_bits)
            }),
            "S10" => capture.get(1).is_some_and(|m| !is_placeholder(m.as_str())),
            "S11" => capture.get(1).is_some_and(|m| {
                m.as_str()
                    .parse::<u64>()
                    .is_ok_and(|t| t >= self.epoch_window.0 && t <= self.epoch_window.1)
            }),
            "S12" => capture.get(1).is_some_and(|m| {
                let literal = m.as_str();
                if literal.contains('.')
                    && !literal.split('.').all(|octet| octet.parse::<u8>().is_ok())
                {
                    return false;
                }
                // No digit, no address: `[abc::def]` is a path, a type or a
                // label, and every IPv6 spelling a log carries (`::1`,
                // `fe80::…`, `2001:db8::…`, `fd00::…`) has one.
                if !literal.bytes().any(|b| b.is_ascii_digit()) {
                    return false;
                }
                !self.is_exempt_endpoint(literal)
            }),
            _ => true,
        }
    }

    /// Whether `matched` is one of the endpoints the run declared exempt.
    ///
    /// Exactly those spellings, never a prefix: the loopback relay is exempt,
    /// but `ws://127.0.0.1:7777/../something` is not an endpoint.
    fn is_exempt_endpoint(&self, matched: &str) -> bool {
        let trimmed = matched.trim_end_matches(['/', ',', ';', ')', '"', '\'']);
        self.exempt.iter().any(|e| e.eq_ignore_ascii_case(trimmed))
    }

    fn is_allowlisted(&self, id: &str, line: &str, sink_path: &str, tag: Option<&str>) -> bool {
        self.allow.iter().any(|candidate| {
            candidate.entry.rule == id
                && glob_matches(&candidate.entry.scope.sink_glob, sink_path)
                && candidate
                    .entry
                    .scope
                    .tag
                    .as_ref()
                    .is_none_or(|want| tag == Some(want.as_str()))
                && candidate.pattern.is_match(line)
        })
    }

    /// Builds an engine with one rule suppressed, so a test can show the fixture
    /// set depends on every rule it claims to.
    #[cfg(test)]
    pub(crate) const fn with_rule_disabled(mut self, id: &'static str) -> Self {
        self.disabled = Some(id);
        self
    }
}

/// Validates an allowlist: every entry must be live, explained, owned and
/// provable.
///
/// # Errors
///
/// Returns one message per defect. Any defect is rc 2 — the guard, not the
/// subject, is broken.
pub fn validate_allowlist(
    entries: &[AllowEntry],
    today: Today,
    proof_root: &std::path::Path,
) -> Result<(), Vec<String>> {
    let mut problems = Vec::new();
    for entry in entries {
        if !RuleSet::ids().contains(&entry.rule.as_str()) {
            problems.push(format!(
                "allowlist entry names rule `{}`, which does not exist",
                entry.rule
            ));
        }
        if entry.justification.trim().is_empty() {
            problems.push(format!(
                "allowlist entry for {} has no justification",
                entry.rule
            ));
        }
        if entry.owner.trim().is_empty() {
            problems.push(format!("allowlist entry for {} has no owner", entry.rule));
        }
        match parse_date(&entry.expires) {
            None => problems.push(format!(
                "allowlist entry for {} has an unparseable `expires`",
                entry.rule
            )),
            Some(date) if date < today => problems.push(format!(
                "allowlist entry for {} expired; a stale allowance cannot accumulate",
                entry.rule
            )),
            Some(_) => {}
        }
        if let Err(reason) = resolve_proof(proof_root, &entry.proof) {
            problems.push(format!("allowlist entry for {}: {reason}", entry.rule));
        }
    }
    if problems.is_empty() {
        Ok(())
    } else {
        Err(problems)
    }
}

/// Resolves a `file:line` (or bare `file`) citation under `root`.
///
/// # Errors
///
/// Returns the reason the citation does not resolve.
pub fn resolve_proof(root: &std::path::Path, proof: &str) -> Result<(), String> {
    // A citation that climbs out of the tree it claims to cite proves nothing
    // about this tree.
    if std::path::Path::new(proof)
        .components()
        .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(format!(
            "proof cites `{proof}`, which climbs out of the tree with `..`"
        ));
    }
    let (path, line) = match proof.rsplit_once(':') {
        Some((path, suffix))
            if suffix.chars().all(|c| c.is_ascii_digit()) && !suffix.is_empty() =>
        {
            (path, suffix.parse::<usize>().ok())
        }
        _ => (proof, None),
    };
    let full = root.join(path);
    let text = std::fs::read_to_string(&full)
        .map_err(|_| format!("proof cites `{path}`, which this tree does not contain"))?;
    match line {
        Some(line) if text.lines().count() < line => Err(format!(
            "proof cites `{proof}`, but that file has fewer lines than that"
        )),
        _ => Ok(()),
    }
}

/// Parses `YYYY-MM-DD`.
fn parse_date(text: &str) -> Option<Today> {
    let mut parts = text.split('-');
    let year = parts.next()?.parse().ok()?;
    let month = parts.next()?.parse().ok()?;
    let day = parts.next()?.parse().ok()?;
    if parts.next().is_some() || !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    Some((year, month, day))
}

fn is_placeholder(text: &str) -> bool {
    let trimmed = text.trim_matches(['"', '\'']);
    PLACEHOLDERS
        .iter()
        .any(|p| p.eq_ignore_ascii_case(trimmed))
        // An alias handle (`circle#a91f3c`) is the redaction, not a name.
        || trimmed
            .split_once('#')
            .is_some_and(|(_, suffix)| suffix.len() == 6 && suffix.chars().all(|c| c.is_ascii_hexdigit()))
}

/// Whether the character immediately before `at` is an ASCII letter, i.e. the
/// blob is the tail of a longer word (`Key` + `CipherImplementationRSA18`)
/// rather than a value the line presents on its own.
fn runs_into_a_word(line: &str, at: usize) -> bool {
    line[..at]
        .chars()
        .next_back()
        .is_some_and(|c| c.is_ascii_alphabetic())
}

/// Whether an S6 match is a code path rather than a geohash field.
///
/// `location::geohash::tests::nan_latitude_returns_empty` is the shape: the
/// keyword is a MODULE, `::` is the separator the rule allows, and `tests` is
/// five letters of the geohash alphabet. Every `cargo test` transcript of this
/// tree carries seven of them, so the rule has to tell a path from a field or
/// the unit-test lanes redden on their own module names.
///
/// Two tells, both syntactic. The first is that the cell is not a whole token:
/// a real cell ends the word it is in, while `geohash::tests::name`,
/// `empty_geohash_returns_zero` and `geohash::encode(…)` all continue into `::`,
/// `_`, `(` or another letter. The second is that the keyword itself is preceded
/// by `::`. A real rendering — `geohash=u4pruyd`, `gh: u4pruyd`, the quoted JSON
/// forms — has neither.
fn is_code_path(line: &str, whole: regex::Match<'_>, cell: regex::Match<'_>) -> bool {
    let after = &line[cell.end()..];
    // Deliberately NOT "any alphanumeric": the cell is capped at twelve
    // characters and stops at `a`/`i`/`l`/`o`, so a real cell can legitimately be
    // followed by one, and suppressing those would lose the longest geohashes
    // this app produces.
    let continues =
        after.starts_with("::") || after.chars().next().is_some_and(|c| c == '_' || c == '(');
    continues || (whole.as_str().starts_with(':') && line[..whole.start()].ends_with(':'))
}

/// Whether an S4 run is base64 PAYLOAD rather than an identifier or a path.
///
/// The entropy floor alone cannot separate them: `kBackgroundSessionReclaimAtMsKey`
/// scores 4.33 bits and a real 32-byte base64 blob scores 4.5–5.0, so the floor
/// that admits the second admits the first. Base64 punctuation alone cannot
/// either — `App/haven/test/providers/identity` is a path made of `/`.
///
/// What a base64 payload of random bytes has, and a camel-case identifier does
/// not, is SCATTERED digits: 10 of the 64 characters are digits, so a random
/// blob carries several of them in separate places, while an identifier carries
/// a vocabulary number as ONE run — `Base64`, `Sha256`, `Utf8`, `Nip44`,
/// `Kind445`. Counting digits rather than digit RUNS is why
/// `circleNameBase64dIntoAnUnalignedBlobIsCaught` reddened the Flutter coverage
/// lane of CI run 35244067610: the two digits of `64` are one run, and a
/// 44-letter camel-case name clears the entropy floor. Trailing `=` padding is
/// the other definitive tell. Both are checked alongside the entropy floor,
/// never instead of it.
///
/// Two runs rather than two digits costs almost nothing: a random 44-character
/// base64 blob (a 32-byte key) has fewer than two digit runs about once in 160,
/// against once in 190 for fewer than two digits, and a 32-character one about
/// once in 28 against once in 33.
///
/// The recall this costs — a base64 blob whose digits are absent or contiguous —
/// is carried by S1/S2 (hex), S8 (a blob next to a key word), the needle search
/// for every value the run declared, and `scan-logs-for-secrets.sh`'s
/// keyword-anchored patterns.
fn is_base64_payload(blob: &str, padded: bool, entropy_bits: f64) -> bool {
    (digit_runs(blob) >= 2 || padded) && shannon_bits(blob) > entropy_bits
}

/// Maximal runs of consecutive ASCII digits in `text`.
fn digit_runs(text: &str) -> usize {
    let mut runs = 0;
    let mut in_run = false;
    for byte in text.bytes() {
        if byte.is_ascii_digit() {
            runs += usize::from(!in_run);
            in_run = true;
        } else {
            in_run = false;
        }
    }
    runs
}

/// Whether a keyword-adjacent run looks ENCODED rather than like an identifier.
///
/// Three independent signs, because no single one covers the renderings that
/// matter: two digits (hex and base64 of random bytes almost always carry
/// several, a CamelCase name rarely carries two), base64 punctuation, or S4's
/// entropy floor. `KeyPackageMaintenanceFailed` satisfies none of them; 32 hex
/// characters satisfy the first while sitting just BELOW the entropy floor,
/// which is why the floor alone is not the test.
///
/// Deliberately still DIGITS here, where [`is_base64_payload`] counts digit
/// runs: this rule fires only within 24 characters of `secret|nsec|seed|key`
/// and only on a blob no word runs into, and its entropy clause already admits
/// a long camel-case identifier on its own, so the digit count is not what
/// separates the two — narrowing it would cost recall in the one net that has a
/// keyword anchor and buy nothing. No `flutter test` or `cargo test` transcript
/// of CI run 35244067610 carries an S8 hit on an identifier.
fn looks_encoded(blob: &str, entropy_bits: f64) -> bool {
    blob.bytes().filter(u8::is_ascii_digit).count() >= 2
        || blob.bytes().any(|b| matches!(b, b'+' | b'/' | b'='))
        || shannon_bits(blob) > entropy_bits
}

/// The longest run of base64 characters in `text`.
fn longest_base64_run(text: &str) -> &str {
    let bytes = text.as_bytes();
    let mut best = 0..0;
    let mut start = None;
    for (index, byte) in bytes.iter().enumerate() {
        let is_b64 = byte.is_ascii_alphanumeric() || *byte == b'+' || *byte == b'/';
        match (is_b64, start) {
            (true, None) => start = Some(index),
            (false, Some(from)) => {
                if index - from > best.len() {
                    best = from..index;
                }
                start = None;
            }
            _ => {}
        }
    }
    if let Some(from) = start {
        if bytes.len() - from > best.len() {
            best = from..bytes.len();
        }
    }
    &text[best]
}

/// Shannon entropy in bits per character.
fn shannon_bits(text: &str) -> f64 {
    if text.is_empty() {
        return 0.0;
    }
    let mut counts = [0u32; 256];
    for byte in text.bytes() {
        counts[usize::from(byte)] += 1;
    }
    let total = f64::from(u32::try_from(text.len()).unwrap_or(u32::MAX));
    -counts
        .iter()
        .filter(|&&c| c > 0)
        .map(|&c| {
            let p = f64::from(c) / total;
            p * p.log2()
        })
        .sum::<f64>()
}

/// Matches a `*`-glob. Deliberately minimal: the only wildcard any sink glob in
/// this tree needs is `*`, and a full glob crate would be a dependency whose
/// semantics nothing here pins.
fn glob_matches(glob: &str, text: &str) -> bool {
    // `str::split` always yields at least one item, so the first is infallible.
    let mut parts = glob.split('*');
    let first = parts.next().unwrap_or(glob);
    if !text.starts_with(first) {
        return false;
    }
    let mut cursor = first.len();
    let mut last_required = None;
    for part in parts {
        last_required = Some(part);
        if part.is_empty() {
            continue;
        }
        match text[cursor..].find(part) {
            Some(at) => cursor += at + part.len(),
            None => return false,
        }
    }
    match last_required {
        // A glob ending in a literal must match the end of the text.
        Some(tail) if !tail.is_empty() => text.ends_with(tail),
        Some(_) => true,
        None => text == glob,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        glob_matches, parse_date, resolve_proof, shannon_bits, validate_allowlist, AllowEntry,
        AllowScope, RuleSet,
    };

    fn engine() -> RuleSet {
        RuleSet::new(4.2, 1_800_000_000, &[], Vec::new()).expect("rules compile")
    }

    fn hits(line: &str) -> Vec<&'static str> {
        let mut ids: Vec<&'static str> = engine()
            .evaluate(line, "/tmp/fixture.log", Some("haven"))
            .into_iter()
            .map(|h| h.rule)
            .collect();
        ids.sort_unstable();
        ids.dedup();
        ids
    }

    /// One positive and one negative line per rule, asserted individually.
    ///
    /// Individually, not as a set: a table that asserted "at least one rule
    /// fired" would stay green after a rule was deleted.
    #[test]
    fn every_rule_has_a_positive_and_a_negative_fixture() {
        let cases: &[(&str, &str, &str)] = &[
            (
                "S1",
                "haven: id=0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9",
                "haven: circle#a91f3c epoch+2 relay#0b12cc",
            ),
            (
                "S2",
                "haven: gid=0a1b2c3d4e5f60718293a4b5c6d7e8f90",
                "haven: attempt=2 of 3, backoff bucket 2-4",
            ),
            (
                "S3",
                "haven: npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
                "haven: state=idle1 reason=timeout",
            ),
            (
                "S4",
                "haven: payload=7mK4pQz9XbR2vT8yLwN3cJ5hD6gF0aSeUiOpZxCvBnMq",
                "haven: ThisIsALongCamelCaseComponentNameForLogging",
            ),
            (
                "S5",
                "haven: fix=-33.865143,151.209901",
                "haven: build=1.2.345, api=36",
            ),
            ("S6", "haven: geohash=r3gx2f7k", "haven: geo cell bucket 2-4"),
            (
                "S7",
                "haven: dialing wss://relay.example.com",
                "haven: dialing relay#0b12cc",
            ),
            (
                "S8",
                "haven: exporter secret 7mK4pQz9XbR2vT8yLwN3cJ5hD6gF0aSe",
                "haven: key rotated, handle kp#44ac1d",
            ),
            (
                "S9",
                "haven: bytes=[10, 27, 44, 61, 78, 95, 112, 129, 146, 163, 180, 197, 214, 231, 248, 9, 26, 43, 60, 77, 94, 111, 128, 145, 162, 179, 196, 213, 230, 247, 8, 25]",
                "haven: bytes=[10, 27, 44]",
            ),
            (
                "S10",
                "haven: display_name=Kåre",
                "haven: display_name=<redacted>",
            ),
            (
                "S11",
                "haven: published since 1789000000",
                "haven: published t+12s ago",
            ),
            (
                "S12",
                "haven: endpoint 10.0.2.2 unreachable",
                "haven: endpoint relay#0b12cc unreachable",
            ),
        ];
        assert_eq!(
            cases.len(),
            RuleSet::ids().len(),
            "every rule needs its own pair of fixtures"
        );
        for (id, dirty, clean) in cases {
            assert!(
                hits(dirty).contains(id),
                "{id} must fire on its positive fixture (fired: {:?})",
                hits(dirty)
            );
            assert!(
                !hits(clean).contains(id),
                "{id} must not fire on its negative fixture (fired: {:?})",
                hits(clean)
            );
        }
    }

    /// The mutation test: with one rule suppressed, its own dirty fixture goes
    /// clean. A fixture set that survived a deleted rule would be measuring
    /// nothing.
    #[test]
    fn disabling_a_rule_makes_its_dirty_fixture_pass() {
        let line = "haven: fix=-33.865143,151.209901";
        assert!(hits(line).contains(&"S5"));
        let mutated = engine().with_rule_disabled("S5");
        let after = mutated.evaluate(line, "/tmp/fixture.log", Some("haven"));
        assert!(
            !after.iter().any(|hit| hit.rule == "S5"),
            "the mutation hook must actually suppress the rule"
        );
    }

    /// S6 across the renderings a log actually carries, both directions.
    ///
    /// The separator bound is a real trade-off: too tight and a quoted JSON
    /// field slips through, too loose and the rule starts reading across
    /// unrelated words. Both edges are fixtures rather than judgement.
    #[test]
    fn s6_catches_every_real_rendering_of_a_geohash_field() {
        for dirty in [
            "haven: geohash=u4pruyd",
            "haven: gh: u4pruyd",
            "haven: geo u4pruyd",
            "haven: {\"geohash\" : \"u4pruyd\"}",
            "haven: geohash -> u4pruyd",
            "haven: {\\\"geohash\\\": \\\"u4pruyd\\\"}",
        ] {
            assert!(hits(dirty).contains(&"S6"), "must fire on {dirty:?}");
        }
        for clean in [
            // `gh` inside a word is never a keyword: the rule needs a boundary.
            "haven: throughput settled, bucket 2-4",
            "haven: brightness cursed by the display",
            // A keyword with no separator is not a field, and a bare digit run
            // next to one is a count, a port or a duration.
            "haven: geohashu4pruyd",
            "haven: geo 123456",
            "haven: geo cell bucket 2-4",
            // Nine separator characters is past the bound: a cell that far from
            // its label is not a rendering, it is two facts on one line.
            "haven: geohash         u4pruyd",
            // Verbatim from `cargo test` over haven-core: the keyword is a
            // MODULE and the "cell" is the next path segment. Seven of these
            // land in every transcript of this tree.
            "test location::geohash::tests::nan_latitude_returns_empty ... ok",
            "test location::geohash::tests::empty_geohash_returns_zero ... ok",
            // A call whose NAME is geohash-alphabet-only, so the regex does match
            // and it is the `(` that rejects it — the earlier fixture used
            // `encode`, which the cell pattern never matched in the first place.
            "haven: location::geohash::sweeps(2) returned",
        ] {
            assert!(!hits(clean).contains(&"S6"), "must not fire on {clean:?}");
        }
    }

    /// S4 reads a base64 PAYLOAD, not an identifier and not a path.
    ///
    /// The negatives are verbatim from the `flutter test` transcripts of this
    /// tree, which is where the shape was found: a Dart test description is a
    /// long camel-case run over the Shannon floor, and a repository path is a
    /// long run of base64 characters joined by `/`.
    #[test]
    fn s4_reads_a_base64_payload_and_not_an_identifier_or_a_path() {
        for dirty in [
            "haven: payload=7mK4pQz9XbR2vT8yLwN3cJ5hD6gF0aSeUiOpZxCvBnMq",
            "haven: payload=q6DHwmDdd0LrxtQ9XmYUMdiNlUvKZPWaUXjZQFT8Vzo=",
        ] {
            assert!(hits(dirty).contains(&"S4"), "must fire on {dirty:?}");
        }
        for clean in [
            "00:01 +33: identity_provider_test.dart: background residue clears kBackgroundSessionReclaimAtMsKey",
            "00:04 +91: wire_frame_test.dart: anUnparseableFrameWithMultibytePreviewIsNotABlindSpot",
            "00:01 +32: /home/runner/work/Haven-App/Haven-App/haven/test/providers/identity_provider_test.dart: ok",
        ] {
            assert!(!hits(clean).contains(&"S4"), "must not fire on {clean:?}");
        }
    }

    /// A vocabulary number in a name is ONE digit run; a payload scatters them.
    ///
    /// The three clean lines are verbatim from the `flutter test` transcript of
    /// CI run 35244067610, where the Flutter coverage lane went rc 1 on nothing
    /// but test names: `64` inside `Base64` satisfied a "two digits" test while
    /// a 44-letter camel-case name cleared the entropy floor. The dirty side is
    /// what must survive the tightening — digits in two places, and padding with
    /// no digit at all.
    #[test]
    fn s4_counts_digit_runs_so_a_vocabulary_number_in_a_name_is_not_a_payload() {
        for clean in [
            "✅ /home/runner/work/Haven-App/Haven-App/haven/test/e2e/wire_canaries_test.dart: realistic leak shapes circleNameBase64dIntoAnUnalignedBlobIsCaught",
            "✅ /home/runner/work/Haven-App/Haven-App/haven/test/e2e/wire_canaries_test.dart: realistic leak shapes base64OfAPercentEncodedNameIsCaught",
            "✅ /home/runner/work/Haven-App/Haven-App/haven/test/e2e/wire_canaries_test.dart: realistic leak shapes base64OfAHexDumpedPetnameIsCaught",
            "haven: Sha256OfTheCircleNameAsDisplayedInTheSheet",
        ] {
            assert!(!hits(clean).contains(&"S4"), "must not fire on {clean:?}");
        }
        for dirty in [
            // Digits in two separate places: a payload, whatever its length.
            "haven: payload=7mK4pQzXbRvTyLwN3cJhDgFaSeUiOpZxCvBnMq",
            // No digit anywhere, but `=` padding: still a payload.
            "haven: payload=qDHwmDddLrxtQXmYUMdiNlUvKZPWaUXjZQFTVzo=",
        ] {
            assert!(hits(dirty).contains(&"S4"), "must fire on {dirty:?}");
        }
    }

    /// The exempted shape is the crate-build line, and nothing else.
    ///
    /// Every accepted line is verbatim from CI run 35244067610's transcripts or
    /// from `fixtures/furniture.rust-test.log`. The rejected ones are two
    /// traps: a test's own stdout that opens with a cargo verb, and cargo's
    /// OTHER status lines, whose tails are unbounded — every one of them passed
    /// for furniture while the shape reached past the crate version, and each
    /// was an evasion: `Doc-tests <32 hex>`, `Running x (target/<pair>)`, and
    /// an `Updating git repository` line naming a `wss://` URL.
    #[test]
    fn the_cargo_status_shape_admits_only_the_crate_build_line() {
        let engine = engine();
        for furniture in [
            "   Compiling cgka-traits v0.9.4 (https://github.com/marmot-protocol/mdk?rev=e391adc133a9b60e420da7a0446f014a180ac8d2#e391adc1)",
            "   Compiling geo-types v0.7.19",
            "    Checking cgka-engine v0.9.4 (https://github.com/marmot-protocol/mdk?rev=e391adc133a9b60e420da7a0446f014a180ac8d2#e391adc1)",
            "  Downloaded geo-types v0.7.19",
            "   Compiling haven-core v0.1.0 (/home/runner/work/Haven-App/Haven-App/haven-core)",
            "   Compiling evil v0.1.0 (git+https://example.invalid/evil?rev=deadbeef)",
        ] {
            assert!(
                engine.is_cargo_status(furniture),
                "cargo prints {furniture:?}"
            );
        }
        for stdout in [
            "Compiling nostr_group_id=5f3a9c2e1b7d408695a4c3e2f1d0b9a8",
            "test relay::manager::tests::compiling_a_filter_twice_is_idempotent ... ok",
            "   Compiling evil",
            "   Compiling evil v1.2",
            // The crate slot is a crate NAME, so a hex run cannot occupy it, and
            // the source must open with a scheme or a path separator, so an
            // address is not a source.
            "   Compiling 0a1b2c3d4e5f60718293a4b5c6d7e8f9 v1.2.3",
            "   Compiling evil v1.2.3 (2001:db8::1)",
            "   Compiling evil v1.2.3 (fix -33.865143,151.209901)",
        ] {
            assert!(
                !engine.is_cargo_status(stdout),
                "a test's own stdout must not pass for a cargo status line: {stdout:?}"
            );
        }
        // The exemption is structural-only and never reaches the rules' own
        // verdict: the line still trips S2 when nothing exempts it.
        assert!(hits("Compiling nostr_group_id=5f3a9c2e1b7d408695a4c3e2f1d0b9a8").contains(&"S2"));
    }

    /// Cargo's other status lines need no exemption, because they trip no rule.
    ///
    /// That is the argument for leaving them out of the shape — an exemption
    /// that buys nothing still costs an unbounded slot — so it is asserted
    /// rather than assumed. Each line is verbatim from CI run 35244067610.
    #[test]
    fn the_cargo_lines_that_need_no_exemption_are_clean_on_their_own() {
        for line in [
            "    Finished `dev` profile [unoptimized + debuginfo] target(s) in 22.61s",
            "    Finished `test` profile [unoptimized + debuginfo] target(s) in 1m 44s",
            "     Running unittests src/lib.rs (target/debug/deps/haven_core-521ec6d6aa32dd35)",
            "     Running tests/mls_integration_tests.rs (target/debug/deps/mls_integration_tests-db684c5c6718c987)",
            "   Doc-tests haven_core",
            "    Updating crates.io index",
            "    Updating git repository `https://github.com/marmot-protocol/mdk`",
            " Downloading crates ...",
        ] {
            assert!(
                hits(line).is_empty(),
                "{line:?} needs no exemption, but fired {:?}",
                hits(line)
            );
            assert!(
                !engine().is_cargo_status(line),
                "…and therefore must not be inside the exemption: {line:?}"
            );
        }
    }

    /// The exemption is two rules on one shape, never the shape itself.
    #[test]
    fn only_s2_and_s6_are_cargo_furniture() {
        let engine = engine();
        let line = "   Compiling geo-types v0.7.19 (https://example.invalid/x?rev=7d4e1c9b3a2f85607d4e1c9b3a2f85607d4e1c9b)";
        assert!(engine.is_cargo_furniture("S2", line));
        assert!(engine.is_cargo_furniture("S6", line));
        for other in [
            "S1", "S3", "S4", "S5", "S7", "S8", "S9", "S10", "S11", "S12",
        ] {
            assert!(
                !engine.is_cargo_furniture(other, line),
                "{other} must still fire on a cargo status line"
            );
        }
        // And neither half stands alone: the pair is not furniture off-shape.
        assert!(!engine.is_cargo_furniture("S2", "gid=0a1b2c3d4e5f60718293a4b5c6d7e8f90"));
        // The residual, asserted rather than implied: a hex run that begins with
        // a LETTER fits the crate-name slot, so a deliberate print of that exact
        // shape is inside the exemption. The same run one character earlier —
        // starting with a digit, as a hex id usually does — is not.
        assert!(
            engine.is_cargo_furniture("S2", "   Compiling a1b2c3d4e5f60718293a4b5c6d7e8f90 v1.2.3")
        );
        assert!(!engine
            .is_cargo_furniture("S2", "   Compiling 0a1b2c3d4e5f60718293a4b5c6d7e8f9 v1.2.3"));
    }

    /// S12 across the IPv6 spellings a log carries, and the Rust furniture it
    /// must not read as one.
    ///
    /// The negatives are verbatim from the captures of CI run 34766632019,
    /// where the pre-delimiter rule matched `re::r` inside
    /// `haven_core::relay::manager` on hundreds of lines per transcript.
    #[test]
    fn s12_reads_an_ipv6_literal_and_not_a_rust_path() {
        for dirty in [
            "haven: peer at fe80::1 left",
            "haven: peer at 2001:db8::1 left",
            "haven: peer at ::1 left",
            "haven: refused [2001:db8:85a3::8a2e:370:7334]:7788",
            "haven: peer at 2001:db8:85a3:0:0:8a2e:370:7334 left",
        ] {
            assert!(hits(dirty).contains(&"S12"), "must fire on {dirty:?}");
        }
        for clean in [
            "haven_core::relay::manager: dialing",
            "haven: state is Option::Some",
            "haven: std::io::Error while reading",
            "haven: at 15:47:32.240 the window closed",
            // A path whose every component is hex-shaped: delimited, but with
            // no digit anywhere, so it is a name and not an address.
            "haven: [abc::def] resolved",
        ] {
            assert!(!hits(clean).contains(&"S12"), "must not fire on {clean:?}");
        }
    }

    /// S8 needs a blob that looks ENCODED, not a CamelCase identifier the word
    /// `key` happens to run into.
    ///
    /// Both negatives are verbatim from CI run 34766632019; the positives keep
    /// the three renderings a leaked secret actually takes.
    #[test]
    fn s8_reads_an_encoded_blob_and_not_a_camel_case_identifier() {
        for dirty in [
            "haven: exporter secret 7mK4pQz9XbR2vT8yLwN3cJ5hD6gF0aSe",
            "haven: nsec bytes 3mK/9xQ+aZv2tRlPqW8nEuY1hCdG7bFs=",
            "haven: key=0a1b2c3d4e5f60718293a4b5c6d7e8f9",
        ] {
            assert!(hits(dirty).contains(&"S8"), "must fire on {dirty:?}");
        }
        for clean in [
            "[KeyPackage] maintain tick: KeyPackageMaintenanceFailed(noRelaysConfigured, awaitUserAction, relayErrors: 0, initKeyPurged: false)",
            "Detected non-biometric migration: FROM=com.it_nomads.fluttersecurestorage.ciphers.KeyCipherImplementationRSA18@727ec4, TO=AES_GCM_NoPadding",
        ] {
            assert!(!hits(clean).contains(&"S8"), "must not fire on {clean:?}");
        }
    }

    #[test]
    fn s1_and_s2_do_not_double_report_one_run() {
        let line = "haven: 0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9";
        assert_eq!(hits(line), vec!["S1"]);
    }

    #[test]
    fn an_exempt_endpoint_is_skipped_by_s7_and_s12_and_nothing_else_is() {
        let exempt = vec![
            "ws://10.0.2.2:7777".to_owned(),
            "10.0.2.2".to_owned(),
            "::1".to_owned(),
        ];
        let engine = RuleSet::new(4.2, 1_800_000_000, &exempt, Vec::new()).expect("rules");
        let hits = |line: &str| -> Vec<&'static str> {
            engine
                .evaluate(line, "/tmp/fixture.log", Some("haven"))
                .into_iter()
                .map(|h| h.rule)
                .collect()
        };
        assert!(hits("haven: relay ws://10.0.2.2:7777 connected").is_empty());
        assert!(hits("haven: host 10.0.2.2 reachable").is_empty());
        // A different endpoint is still a hit, and so is a path under the
        // exempt one: an endpoint is a host and a port, not a prefix.
        assert!(hits("haven: relay ws://10.0.2.3:7777 connected").contains(&"S7"));
        assert!(hits("haven: relay ws://10.0.2.2:7777/secret connected").contains(&"S7"));
        assert!(hits("haven: host 192.168.1.22 reachable").contains(&"S12"));
        // An IPv6 exemption is the exact spelling too: the loopback the lane
        // declared is forgiven and the address one hop away is not.
        assert!(hits("haven: proxy at ::1 accepted").is_empty());
        assert!(hits("haven: proxy at ::2 accepted").contains(&"S12"));
    }

    #[test]
    fn s12_rejects_a_dotted_quad_that_is_not_an_address() {
        // A version number has four groups and no octet above 255 guarantee.
        assert!(!hits("haven: schema 1.2.3.400 applied").contains(&"S12"));
        assert!(hits("haven: schema 1.2.3.40 applied").contains(&"S12"));
    }

    #[test]
    fn s12_does_not_fire_on_a_logcat_timestamp() {
        // `12:34:56.789` is three colon-separated hex-looking groups; an IPv6
        // rule that matched it would redden every single logcat line.
        assert!(!hits("haven: at 12:34:56.789 the window closed").contains(&"S12"));
        assert!(hits("haven: peer at 2001:db8:85a3:0:0:8a2e:370:7334 left").contains(&"S12"));
        assert!(hits("haven: peer at ::1 left").contains(&"S12"));
    }

    #[test]
    fn s11_ignores_a_timestamp_outside_the_epoch_window() {
        assert!(!hits("haven: published since 1000000000").contains(&"S11"));
        assert!(hits("haven: published since 1789000000").contains(&"S11"));
    }

    #[test]
    fn s10_accepts_every_redaction_the_tree_prints() {
        for placeholder in ["<redacted>", "null", "circle#a91f3c", "***", "<none>"] {
            let line = format!("haven: petname={placeholder}");
            assert!(!hits(&line).contains(&"S10"), "{placeholder}");
        }
    }

    #[test]
    fn s4_needs_entropy_not_just_length() {
        assert!(shannon_bits("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") < 1.0);
        assert!(shannon_bits("7mK4pQz9XbR2vT8yLwN3cJ5hD6gF0aSeUiOpZxCvBnMq") > 4.2);
    }

    #[test]
    fn an_allowlisted_hit_is_forgiven_only_in_its_scope() {
        let entry = AllowEntry {
            rule: "S7".to_owned(),
            scope: AllowScope {
                sink_glob: "*/fixture.log".to_owned(),
                tag: Some("haven".to_owned()),
            },
            pattern: "^haven: dialing ".to_owned(),
            justification: "the harness prints its own loopback endpoint".to_owned(),
            proof: "tooling/logscan/src/rules.rs:1".to_owned(),
            owner: "logscan".to_owned(),
            expires: "2099-01-01".to_owned(),
        };
        let engine = RuleSet::new(4.2, 1_800_000_000, &[], vec![entry]).expect("rules");
        let line = "haven: dialing wss://relay.example.com";
        assert!(engine
            .evaluate(line, "/tmp/fixture.log", Some("haven"))
            .is_empty());
        // Wrong sink, wrong tag, wrong line: each still a hit.
        assert!(!engine
            .evaluate(line, "/tmp/other.log", Some("haven"))
            .is_empty());
        assert!(!engine
            .evaluate(line, "/tmp/fixture.log", Some("flutter"))
            .is_empty());
        assert!(!engine
            .evaluate(
                "haven: redialing wss://relay.example.com",
                "/tmp/fixture.log",
                Some("haven")
            )
            .is_empty());
    }

    #[test]
    fn an_expired_entry_and_a_dangling_proof_are_both_rejected() {
        let base = AllowEntry {
            rule: "S7".to_owned(),
            scope: AllowScope {
                sink_glob: "*".to_owned(),
                tag: None,
            },
            pattern: ".".to_owned(),
            justification: "because".to_owned(),
            proof: "Cargo.toml".to_owned(),
            owner: "logscan".to_owned(),
            expires: "2099-01-01".to_owned(),
        };
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        validate_allowlist(std::slice::from_ref(&base), (2026, 9, 12), root)
            .expect("a live entry is fine");

        let mut expired = base.clone();
        expired.expires = "2020-01-01".to_owned();
        let problems =
            validate_allowlist(&[expired], (2026, 9, 12), root).expect_err("expired must fail");
        assert!(problems[0].contains("expired"), "{problems:?}");

        let mut dangling = base.clone();
        dangling.proof = "src/nowhere.rs:12".to_owned();
        let problems =
            validate_allowlist(&[dangling], (2026, 9, 12), root).expect_err("dangling must fail");
        assert!(problems[0].contains("does not contain"), "{problems:?}");

        let mut past_end = base;
        past_end.proof = "Cargo.toml:99999".to_owned();
        let problems =
            validate_allowlist(&[past_end], (2026, 9, 12), root).expect_err("bad line must fail");
        assert!(problems[0].contains("fewer lines"), "{problems:?}");
    }

    #[test]
    fn a_proof_resolves_against_the_given_root_only() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        resolve_proof(root, "Cargo.toml:1").expect("a real citation resolves");
        resolve_proof(std::path::Path::new("/nonexistent-root"), "Cargo.toml:1")
            .expect_err("the same citation must not resolve under another root");
        let err = resolve_proof(root, "../../Cargo.toml")
            .expect_err("a citation may not climb out of the tree");
        assert!(err.contains("climbs out of the tree"), "{err}");
    }

    #[test]
    fn dates_parse_or_are_rejected() {
        assert_eq!(parse_date("2026-09-12"), Some((2026, 9, 12)));
        assert_eq!(parse_date("2026-13-01"), None);
        assert_eq!(parse_date("soon"), None);
        assert_eq!(parse_date("2026-09-12-1"), None);
    }

    #[test]
    fn globs_match_what_they_claim() {
        assert!(glob_matches("*", "/tmp/x.log"));
        assert!(glob_matches("*.log", "/tmp/x.log"));
        assert!(glob_matches("/tmp/*.log", "/tmp/x.log"));
        assert!(!glob_matches("/tmp/*.log", "/var/x.log"));
        assert!(!glob_matches("*.log", "/tmp/x.logarchive"));
        assert!(glob_matches("/tmp/x.log", "/tmp/x.log"));
    }
}
