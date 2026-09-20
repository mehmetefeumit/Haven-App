//! `policy.toml` — the one declaration of what is a needle and where it is
//! searched, plus the hand-written coverage ledger.
//!
//! The policy is **compiled in** (`include_str!`). A `--policy <path>` flag
//! would make the instrument's own rules caller-controlled, which is the defeat
//! `scripts/ci/check_wire_proxy_test_only.sh:180-191` records twice: a guard
//! whose subject can be relocated by an argument is not a guard. Changing the
//! policy means changing the file and rebuilding, which means a reviewed diff.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// The policy this binary was built with.
const POLICY_TOML: &str = include_str!("../policy.toml");

/// The only schema this build understands.
const SCHEMA: u32 = 1;

/// How a sink's lines are framed, which is what decides where the Haven-owned
/// part of a line starts and whether structural rules may look at it at all.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum EntryFormat {
    /// `adb logcat -v threadtime`: `MM-DD HH:MM:SS.mmm  pid  tid P tag: message`.
    Logcat,
    /// A `log show` text export, in any of its renderings: what the lanes
    /// capture (`<date> <time+tz>  <host> <process>[<pid>]: (<library>)
    /// [<subsystem>:<category>] <message>`), the `<<Type>>:` variant, or the
    /// default columnar one.
    Ios,
    /// Every line is Haven-owned in full (drive transcripts, `cargo test` logs).
    Plain,
}

/// Whether the STRUCTURAL rules read cargo's own status lines in a sink class.
///
/// Never about needles: a declared value on a cargo status line is a hit in
/// every sink, because the needle pass reads every byte of every line.
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum CargoStatus {
    /// The rules read them like any other line — every sink but the one that
    /// holds a cargo transcript.
    #[default]
    Scanned,
    /// The rules skip the lines matching cargo's status shape
    /// (`crate::rules::RuleSet::is_cargo_status`): cargo prints the public
    /// pinned git revision of every git dependency and the name of every crate
    /// before a single test runs, and neither is a Haven identifier.
    Exempt,
}

/// The shape of a declared value, which decides which encodings exist for it.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ClassKind {
    /// A byte string declared as hex (or as a bech32 string for the key
    /// classes).
    Bytes,
    /// A human- or protocol-authored string.
    Text,
    /// `lat,lon` in decimal degrees.
    Coordinate,
    /// A base32 geohash.
    Geohash,
    /// A `ws`/`wss`/`http`/`https` URL.
    Url,
    /// A positive control. Plants are not expanded: they are matched literally
    /// and tallied, never reported as leaks.
    Plant,
}

/// One needle class.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ClassSpec {
    /// Which expander runs for this class.
    pub kind: ClassKind,
    /// Secret-class: the raw value is NEVER serialised. The manifest carries
    /// `sha256(raw)` and only the digest's encodings are searchable.
    #[serde(default)]
    pub secret: bool,
    /// Bech32 HRPs whose hint-free form is expanded.
    #[serde(default)]
    pub bech32: Vec<String>,
    /// Bech32 HRPs whose only real-world form carries relay hints, so the
    /// expander records them as coverage gaps instead of guessing the hints.
    #[serde(default)]
    pub bech32_tlv_gap: Vec<String>,
    /// Sink classes that legitimately hold this class (a relay holds pubkeys),
    /// where a needle of this class is therefore not searched.
    #[serde(default)]
    pub scoped_out: Vec<String>,
}

/// One PROGRAM whose own records are the source of a needle class.
///
/// The sink's `owned_emitters` say whose lines the structural rules read; this
/// says whose lines a needle CLASS is not searched on, for a program that
/// necessarily holds the value. An owned emitter can never be one: there the
/// value would be the leak itself.
///
/// It names BOTH columns, because neither identifies a program on its own. The
/// subsystem does not: an Apple framework linked into Haven's app logs under
/// its own subsystem from INSIDE the app's process (`fixtures/format.ios.log`
/// carries a `Runner[…]` record under `com.apple.locationd.Core`), so scoping
/// on the subsystem alone would forgive the class exactly where a leak would
/// be. The process does not either: one daemon carries many subsystems.
///
/// `process` is required rather than optional: every framed record names one,
/// so an absent one could only mean "any process" — a wider mode reachable by
/// omission, which is the shape a guard must not have.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct EmitterScope {
    /// The record's process, matched EXACTLY.
    pub process: String,
    /// The record's emitter, matched EXACTLY as ownership is — its `os_log`
    /// subsystem, else its library, else its process.
    pub emitter: String,
    /// The needle classes not searched on that program's own records. Every
    /// other class still is, and the structural rules are untouched.
    pub classes: Vec<String>,
}

/// One sink class.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SinkSpec {
    /// Shortest term that may be searched in this sink. A short term in a
    /// device-wide logcat matches furniture, and a guard that cries wolf is a
    /// guard that gets deleted.
    pub term_floor: usize,
    /// Whether the structural rules run here. OFF for `relay`: a relay log
    /// holding pubkeys and event ids is not a Haven leak.
    pub structural_rules: bool,
    /// Whether consecutive entries sharing pid/tid/tag are re-joined before
    /// needle matching (`android_logger` chunks a record at ~4000 B).
    pub reassemble: bool,
    /// Whether the structural rules read cargo's own status lines here.
    /// `exempt` for `rust-test` alone, which is the only class that holds a
    /// cargo transcript; every other sink defaults to reading them.
    #[serde(default)]
    pub cargo_status: CargoStatus,
    /// Default line floor; `seal --floor <sink>=<n>` overrides it.
    pub min_lines: u64,
    /// A line every capture of this class carries once its SUBJECT has started,
    /// as a regex: the proof that the capture is of a run that happened.
    ///
    /// A line floor cannot tell a short complete capture from an empty one. How
    /// many lines a `flutter drive` transcript holds depends on how much logcat
    /// furniture the tool forwards and on whether the reporter's closing line
    /// beats the driver's disconnect, so the floor that clears the shortest
    /// COMPLETE transcript also clears a transcript in which nothing ran. The
    /// test reporter's own progress line can tell them apart: it is written
    /// before the first test body runs. Declared per class, because only a
    /// class whose captures all come from one producer has such a line.
    #[serde(default)]
    pub proof_of_run: Option<String>,
    /// How lines are framed.
    pub entry_format: EntryFormat,
    /// Log tags this repo owns. Structural rules run only on these lines.
    #[serde(default)]
    pub owned_tags: Vec<String>,
    /// Record EMITTERS this repo owns, for `log show` exports.
    ///
    /// A `log show` line names three things, and only the innermost one says
    /// who wrote it: the record's `os_log` SUBSYSTEM (`frb_user`), else the
    /// emitting library/image (`rust_lib_haven`), else the process. On iOS the
    /// process is `Runner` for Haven's own records AND for every Apple
    /// framework linked into the app, so a process-only test hands the
    /// structural rules `libxpc`, `UIKitCore` and `CoreLocation` output —
    /// 31 vendor hits per lane in CI run 35280144455's captures, i.e. rc 1 and
    /// a deleted capture on a green run. Matched exactly, never as a substring.
    #[serde(default)]
    pub owned_emitters: Vec<String>,
    /// Emitters whose own records legitimately CARRY a needle class, where a
    /// needle of it is therefore not searched.
    ///
    /// The `ios` twin of a class's `scoped_out`, one rung finer: a device-wide
    /// `log show` holds the OS's own daemons, and the daemon that delivers a
    /// simulated fix has to know the position to deliver it. Applied to needle
    /// matching alone, on records whose emitter matches exactly; the structural
    /// rules are unaffected (such an emitter is un-owned anyway) and every other
    /// class is still searched on those records.
    #[serde(default)]
    pub emitter_scoped_out: Vec<EmitterScope>,
    /// Whether the DECLARED (Dart) plant tokens must appear in this sink class.
    ///
    /// There is no default: a sink class added without an answer would inherit
    /// one silently, and the two answers differ by whether a whole positive
    /// control is enforced. `false` says "Dart's `debugPrint` is not known to
    /// reach this capture", which is the honest state of `ios` until a run
    /// proves otherwise; the shape plants are unaffected either way.
    pub declared_plants_expected: bool,
    /// Emitters whose UNDECLARED, shape-matched plant must appear at least once
    /// in this sink class (`rust`, `kotlin`, `swift`). Proof that the emitter's
    /// log backend actually reached the file: a mis-installed Rust backend, a
    /// wrong `log show --predicate` and a dead capture all read as clean
    /// otherwise.
    #[serde(default)]
    pub required_shape_plants: Vec<String>,
}

impl SinkSpec {
    /// The needle classes not searched on the records of the program named by
    /// `(process, emitter)`.
    ///
    /// BOTH halves must match: see [`EmitterScope`] for why neither identifies
    /// a program on its own. Empty for every sink but the one that declares a
    /// scope, and for every program but the ones it names.
    #[must_use]
    pub fn emitter_scope(&self, process: &str, emitter: &str) -> &[String] {
        self.emitter_scoped_out
            .iter()
            .find(|scope| scope.process == process && scope.emitter == emitter)
            .map_or(&[][..], |scope| &scope.classes)
    }
}

/// The hand-declared coverage claim for one class.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LedgerClass {
    /// Encodings the expander is expected to produce (or to drop as an alias of
    /// another produced term, or as unavailable for the declared value).
    #[serde(default)]
    pub covered: Vec<String>,
    /// Encodings the expander deliberately does not search, each with the
    /// reason. An empty reason is one of the four ledger mismatch kinds.
    #[serde(default)]
    pub gaps: BTreeMap<String, String>,
    /// Renderings deliberately out of scope ENTIRELY, each with the sentence
    /// why: base58, DMS coordinates, deeper compositions. They are not gaps —
    /// nothing in this tree produces them — and if the expander ever starts
    /// producing one, reconciliation reports it as an undeclared label.
    #[serde(default)]
    pub not_gaps: BTreeMap<String, String>,
}

/// The whole policy.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    /// Schema version; must equal [`SCHEMA`].
    pub schema: u32,
    /// Bits-per-character floor above which a base64-shaped run is a blob (S4).
    pub base64_entropy_bits: f64,
    /// Shortest term any sink may search, i.e. the floor of the floors.
    pub min_term_len: usize,
    /// Terms identical to one of these are log furniture, not needles.
    pub furniture: Vec<String>,
    /// Needle classes.
    pub classes: BTreeMap<String, ClassSpec>,
    /// Sink classes.
    pub sinks: BTreeMap<String, SinkSpec>,
    /// The coverage ledger, one table per class.
    pub ledger: BTreeMap<String, LedgerClass>,
}

impl Policy {
    /// Loads the compiled-in policy.
    ///
    /// # Errors
    ///
    /// Returns a message naming the defect when the policy does not parse or
    /// does not satisfy its own invariants.
    pub fn load() -> Result<Self, String> {
        Self::parse(POLICY_TOML)
    }

    /// Parses and validates a policy document.
    ///
    /// # Errors
    ///
    /// Returns a message naming the defect.
    pub fn parse(text: &str) -> Result<Self, String> {
        let policy: Self =
            toml::from_str(text).map_err(|e| format!("policy.toml does not parse: {e}"))?;
        policy.validate()?;
        Ok(policy)
    }

    /// The spec for `class`.
    ///
    /// # Errors
    ///
    /// Returns a message when the class is not declared — which is a
    /// producer/policy drift, not a user error.
    pub fn class(&self, class: &str) -> Result<&ClassSpec, String> {
        self.classes
            .get(class)
            .ok_or_else(|| format!("undeclared needle class `{class}`"))
    }

    /// The spec for `sink`.
    ///
    /// # Errors
    ///
    /// Returns a message when the sink class is not declared.
    pub fn sink(&self, sink: &str) -> Result<&SinkSpec, String> {
        self.sinks
            .get(sink)
            .ok_or_else(|| format!("undeclared sink class `{sink}`"))
    }

    /// The needle exemptions of one sink: the only allowance in this policy that
    /// stops a DECLARED value being searched for, so each bound is checked.
    fn validate_emitter_scopes(&self, name: &str, sink: &SinkSpec) -> Result<(), String> {
        for scope in &sink.emitter_scoped_out {
            // Ownership is only computed for a `log show` export; under every
            // other framing "the emitter" is not something a record names, so
            // the scope would silently apply to nothing.
            if sink.entry_format != EntryFormat::Ios {
                return Err(format!(
                    "sink `{name}` scopes a class out of an emitter, but only an ios-framed sink names one per record"
                ));
            }
            if scope.process.is_empty() || scope.emitter.is_empty() {
                return Err(format!(
                    "sink `{name}` declares an emitter scope with an empty process or emitter, which would match whatever a record happens to carry"
                ));
            }
            if sink.owned_emitters.contains(&scope.emitter) {
                return Err(format!(
                    "sink `{name}` scopes a class out of an emitter it also OWNS; on Haven's own emitter the value would be the leak itself"
                ));
            }
            if scope.classes.is_empty() {
                return Err(format!(
                    "sink `{name}` scopes an emitter out of no class at all, which searches exactly what it did before and reads as an exemption"
                ));
            }
            for class in &scope.classes {
                if !self.classes.contains_key(class) {
                    return Err(format!(
                        "sink `{name}` scopes an emitter out of `{class}`, which is not a needle class"
                    ));
                }
            }
        }
        Ok(())
    }

    fn validate(&self) -> Result<(), String> {
        if self.schema != SCHEMA {
            return Err(format!(
                "policy schema {} is not the {SCHEMA} this build understands",
                self.schema
            ));
        }
        if self.min_term_len == 0 {
            return Err("min_term_len 0 would make every single character a needle".to_owned());
        }
        for (name, class) in &self.classes {
            for sink in &class.scoped_out {
                if !self.sinks.contains_key(sink) {
                    return Err(format!(
                        "class `{name}` is scoped out of `{sink}`, which is not a sink class"
                    ));
                }
            }
            if class.secret && !matches!(class.kind, ClassKind::Bytes) {
                return Err(format!(
                    "class `{name}` is secret-class but not bytes; only a byte string has a digest commitment"
                ));
            }
        }
        for (name, sink) in &self.sinks {
            if sink.term_floor < self.min_term_len {
                return Err(format!(
                    "sink `{name}` has a term floor below min_term_len, so it would search terms the seal dropped"
                ));
            }
            match sink.entry_format {
                EntryFormat::Logcat if sink.owned_tags.is_empty() => {
                    return Err(format!(
                        "sink `{name}` is logcat-framed but names no owned tags, so every vendor line would be scanned"
                    ));
                }
                EntryFormat::Ios if sink.owned_emitters.is_empty() => {
                    return Err(format!(
                        "sink `{name}` is ios-framed but names no owned emitters, so every vendor line would be scanned"
                    ));
                }
                _ => {}
            }
            self.validate_emitter_scopes(name, sink)?;
            if let Some(pattern) = &sink.proof_of_run {
                if pattern.is_empty() {
                    return Err(format!(
                        "sink `{name}` declares an empty proof_of_run, which every line matches and so proves nothing"
                    ));
                }
                regex::Regex::new(pattern).map_err(|_| {
                    format!("sink `{name}`'s proof_of_run is not a valid regular expression")
                })?;
            }
            // A sink cannot require a control the declaration channel has no way
            // to mint: without the `plant` class the harness cannot declare a
            // token, and the requirement would be permanently unsatisfiable. The
            // shipped policy cannot reach this; `a_sink_cannot_expect_a_plant_the_policy_cannot_declare`
            // is what keeps a future edit from reaching it silently.
            if sink.declared_plants_expected && !self.classes.contains_key("plant") {
                return Err(format!(
                    "sink `{name}` expects declared plants but the policy declares no `plant` class, so the control could never be satisfied"
                ));
            }
        }
        for (name, entry) in &self.ledger {
            if !self.classes.contains_key(name) {
                return Err(format!(
                    "the ledger declares `{name}`, which is not a class"
                ));
            }
            // A gap with a blank reason is deliberately NOT rejected here: it is
            // one of the four ledger mismatch kinds, which the brief prices at
            // rc 3 (the coverage claim is unverified), not at rc 2.
            for label in entry.gaps.keys() {
                if entry.covered.contains(label) {
                    return Err(format!(
                        "ledger label `{name}`/`{label}` is declared both covered and a gap"
                    ));
                }
            }
            for (label, reason) in &entry.not_gaps {
                if reason.trim().is_empty() {
                    return Err(format!(
                        "ledger `{name}`/`{label}` is declared out of scope with no reason"
                    ));
                }
            }
            let mut seen = std::collections::BTreeSet::new();
            for label in &entry.covered {
                if !seen.insert(label) {
                    return Err(format!(
                        "ledger label `{name}`/`{label}` is declared covered twice"
                    ));
                }
            }
        }
        for (name, class) in &self.classes {
            if matches!(class.kind, ClassKind::Plant) {
                continue;
            }
            if !self.ledger.contains_key(name) {
                return Err(format!(
                    "class `{name}` has no ledger table, so its coverage claim would be whatever the expander happens to do"
                ));
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{CargoStatus, ClassKind, Policy};

    #[test]
    fn the_shipped_policy_loads_and_validates() {
        let policy = Policy::load().expect("shipped policy.toml must be valid");
        // The classes the brief's table names, all present: a class deleted by
        // accident would silently stop being searched for.
        for class in [
            "nsec",
            "secret",
            "mls_group_id",
            "nostr_group_id",
            "pubkey",
            "event_id",
            "kp_slot",
            "subscription_id",
            "relay_url",
            "circle_name",
            "display_name",
            "petname",
            "about",
            "device_id",
            "coordinate",
            "geohash",
            "blossom_url",
            "plant",
        ] {
            assert!(policy.classes.contains_key(class), "class `{class}`");
        }
        for sink in [
            "logcat",
            "drive",
            "ios",
            "rust-test",
            "relay",
            "proxy",
            "diag",
        ] {
            assert!(policy.sinks.contains_key(sink), "sink `{sink}`");
        }
    }

    #[test]
    fn the_relay_sink_has_structural_rules_off_and_scopes_out_the_public_classes() {
        let policy = Policy::load().expect("policy");
        assert!(!policy.sinks["relay"].structural_rules);
        for class in [
            "pubkey",
            "event_id",
            "nostr_group_id",
            "kp_slot",
            "subscription_id",
        ] {
            assert!(
                policy.classes[class]
                    .scoped_out
                    .contains(&"relay".to_owned()),
                "`{class}` must be scoped out of a relay log"
            );
        }
        // …and the secret classes are scoped out of NOTHING: a relay that holds
        // an nsec is a catastrophe wherever it is written down.
        for class in ["nsec", "secret"] {
            assert!(policy.classes[class].scoped_out.is_empty(), "`{class}`");
        }
    }

    #[test]
    fn both_key_classes_are_secret_class() {
        let policy = Policy::load().expect("policy");
        assert!(policy.classes["nsec"].secret);
        assert!(policy.classes["secret"].secret);
        assert!(matches!(policy.classes["nsec"].kind, ClassKind::Bytes));
        // And nothing else is, because every other class is a value a relay or
        // a peer already holds: committing it would only cost recall.
        let secrets: Vec<&String> = policy
            .classes
            .iter()
            .filter(|(_, c)| c.secret)
            .map(|(n, _)| n)
            .collect();
        assert_eq!(secrets, vec!["nsec", "secret"]);
    }

    #[test]
    fn the_secret_classes_declare_every_raw_rendering_a_gap_and_only_the_commitment_covered() {
        let policy = Policy::load().expect("policy");
        for class in ["nsec", "secret"] {
            let entry = &policy.ledger[class];
            assert_eq!(
                entry.covered,
                vec![
                    "sha256-hex".to_owned(),
                    "sha256-hex-prefix8".to_owned(),
                    "sha256-hex-prefix16".to_owned()
                ],
                "`{class}` may only search the commitment"
            );
            assert!(entry
                .gaps
                .values()
                .all(|r| r == "secret-class raw never serialised"));
        }
    }

    #[test]
    fn base58_and_dms_are_declared_out_of_scope_with_a_reason() {
        // The brief asks for these two to be declared non-gaps with one sentence
        // why, so the boundary of the claimed space is written down rather than
        // discovered by an adversarial reader later.
        let policy = Policy::load().expect("policy");
        assert!(policy.ledger["coordinate"]
            .not_gaps
            .get("coord/dms")
            .is_some_and(|reason| reason.contains("degrees/minutes/seconds")));
        assert!(policy.ledger["circle_name"]
            .not_gaps
            .get("utf8/base58")
            .is_some_and(|reason| reason.contains("base58")));
    }

    /// Which sinks the DECLARED Dart plants are demanded in, pinned.
    ///
    /// Both values are asserted, because the knob is only worth having if the
    /// `false` side is reachable — and only safe if the `true` side cannot be
    /// flipped off quietly to make a red lane green.
    #[test]
    fn the_declared_plant_expectation_is_pinned_per_sink() {
        let policy = Policy::load().expect("policy");
        for (sink, expected) in [
            ("logcat", true),
            ("drive", true),
            ("ios", false),
            ("rust-test", false),
            ("proxy", false),
            ("diag", false),
            ("relay", false),
        ] {
            assert_eq!(
                policy.sinks[sink].declared_plants_expected, expected,
                "`{sink}`"
            );
        }
        // The `false` on `ios` is a claim about a capture, not a licence: the
        // shape plants that prove the emitters' backends reached it still stand.
        assert_eq!(
            policy.sinks["ios"].required_shape_plants,
            vec!["rust".to_owned(), "swift".to_owned()]
        );
    }

    /// Which emitter's own records are searched for one class less, pinned in
    /// both directions.
    ///
    /// This is the only NEEDLE exemption in the policy — every other one belongs
    /// to a structural rule — so what it covers is written down here rather than
    /// read off whatever the file currently says, and a second emitter, a second
    /// class or a second sink acquiring one fails this test first.
    #[test]
    fn the_emitter_needle_scope_is_pinned() {
        let policy = Policy::load().expect("policy");
        let scoped: Vec<(&str, &str, &str, &[String])> = policy
            .sinks
            .iter()
            .flat_map(|(sink, spec)| {
                spec.emitter_scoped_out.iter().map(move |scope| {
                    (
                        sink.as_str(),
                        scope.process.as_str(),
                        scope.emitter.as_str(),
                        &scope.classes[..],
                    )
                })
            })
            .collect();
        assert_eq!(
            scoped,
            vec![(
                "ios",
                "locationd",
                "com.apple.locationd.Position",
                &["coordinate".to_owned()][..]
            )],
            "the location daemon, its Position subsystem, the coordinate class, the ios sink — and nothing else"
        );
        // …and the lookup answers per PROGRAM, so no near miss is forgiven:
        // the same subsystem inside Haven's own process (which is where a leak
        // would be), the daemon's other subsystems, the daemon's process under
        // another subsystem, and Haven's own emitters are all searched for
        // every class exactly as before.
        let ios = &policy.sinks["ios"];
        assert_eq!(
            ios.emitter_scope("locationd", "com.apple.locationd.Position"),
            ["coordinate"]
        );
        for (process, emitter) in [
            ("Runner", "com.apple.locationd.Position"),
            ("locationd", "com.apple.locationd.Core"),
            ("locationd", "locationd"),
            ("Runner", "frb_user"),
            ("Runner", "haven_ios"),
            ("apsd", "com.apple.network"),
        ] {
            assert!(
                ios.emitter_scope(process, emitter).is_empty(),
                "`{process}/{emitter}`"
            );
        }
    }

    #[test]
    fn an_emitter_scope_on_a_sink_that_names_no_emitter_is_rejected() {
        let text = r#"
schema = 1
base64_entropy_bits = 4.2
min_term_len = 6
furniture = []
[classes]
coordinate = { kind = "coordinate" }
[sinks]
drive = { term_floor = 6, declared_plants_expected = false, structural_rules = true, reassemble = false, min_lines = 1, entry_format = "plain", emitter_scoped_out = [{ process = "locationd", emitter = "locationd", classes = ["coordinate"] }] }
[ledger.coordinate]
"#;
        let err = Policy::parse(text).expect_err("a plain sink names no emitter per record");
        assert!(err.contains("only an ios-framed sink"), "{err}");
    }

    /// Scoping a class out of an emitter Haven OWNS would forgive the leak
    /// itself, which is the one thing this knob must never be able to do.
    #[test]
    fn an_emitter_scope_on_an_owned_emitter_is_rejected() {
        let text = r#"
schema = 1
base64_entropy_bits = 4.2
min_term_len = 6
furniture = []
[classes]
coordinate = { kind = "coordinate" }
[sinks]
ios = { term_floor = 8, declared_plants_expected = false, structural_rules = true, reassemble = false, min_lines = 1, entry_format = "ios", owned_emitters = ["frb_user"], emitter_scoped_out = [{ process = "Runner", emitter = "frb_user", classes = ["coordinate"] }] }
[ledger.coordinate]
"#;
        let err = Policy::parse(text).expect_err("Haven's own emitter must never be scoped out");
        assert!(err.contains("it also OWNS"), "{err}");
    }

    #[test]
    fn an_emitter_scoped_out_of_an_undeclared_class_is_rejected() {
        let text = r#"
schema = 1
base64_entropy_bits = 4.2
min_term_len = 6
furniture = []
[classes]
coordinate = { kind = "coordinate" }
[sinks]
ios = { term_floor = 8, declared_plants_expected = false, structural_rules = true, reassemble = false, min_lines = 1, entry_format = "ios", owned_emitters = ["frb_user"], emitter_scoped_out = [{ process = "locationd", emitter = "locationd", classes = ["coordinates"] }] }
[ledger.coordinate]
"#;
        let err = Policy::parse(text).expect_err("a misspelt class scopes out nothing");
        assert!(err.contains("not a needle class"), "{err}");
    }

    /// Every sink's LINE FLOOR, pinned with the capture each was sized to.
    ///
    /// A floor is the anti-vacuity check behind rc 4: it is what turns "the
    /// scan read an empty or truncated file and found nothing" into a failure
    /// rather than a clean verdict. That makes it the one number in this file
    /// a red lane argues for lowering, so it is pinned here with its basis —
    /// the SMALLEST COMPLETE capture of the class, never what would make a
    /// lane pass. A lane whose captures are legitimately smaller (a per-target
    /// logcat slice, a one-target drive) passes `seal --floor <class>=<n>`
    /// instead; lowering a default to fit the smallest lane would take the
    /// floor off every other one.
    #[test]
    fn every_sink_floor_is_pinned_with_its_basis() {
        let policy = Policy::load().expect("policy");
        for (sink, expected) in [
            // A device-wide `adb logcat -v threadtime` capture of a whole
            // scenario: 10 626 lines in the smallest of CI run 35280144455.
            ("logcat", 2000),
            // A `log show` export of a whole simulator boot: 283 455 lines
            // across the two files every iOS lane hands the scanner.
            ("ios", 2000),
            // The Android core flow's `flutter drive` transcript, 394 lines.
            ("drive", 100),
            // A `cargo test` transcript: the shortest of rust-check.yml's four
            // still prints a status block and a result line per target.
            ("rust-test", 20),
            // The wire proxy's log: a listen line, a per-role connect and its
            // sidecar summary, so never fewer than a handful.
            ("proxy", 5),
            // A diag file is whatever a lane chose to dump — b9's is 28 lines,
            // e2e-profile's blossom log is 1 — so existence is all it can
            // prove.
            ("diag", 1),
            // The hermetic host relay prints its listen line and nothing else
            // for a whole run. A lane whose relay is strfry (14-23 lines per
            // `docker logs` dump) passes `--floor relay=7`, which is what
            // catches a container torn down before the dump: ONE error line.
            ("relay", 1),
        ] {
            assert_eq!(policy.sinks[sink].min_lines, expected, "`{sink}`");
        }
        // And every sink HAS one: a class added without a floor would be the
        // one capture the anti-vacuity check never reads.
        assert!(policy.sinks.values().all(|s| s.min_lines >= 1));
    }

    /// Which sinks skip cargo's status lines, pinned in both directions.
    ///
    /// A cargo transcript is the only capture in the fleet that carries them, so
    /// the exemption must not spread: on a `drive` or `logcat` sink a line
    /// shaped like `Compiling x v1.2.3 (…<hex>…)` is app output, and the rules
    /// are right to read it.
    #[test]
    fn only_the_cargo_transcript_sink_skips_cargo_status_lines() {
        let policy = Policy::load().expect("policy");
        for (sink, expected) in [
            ("rust-test", CargoStatus::Exempt),
            ("soak", CargoStatus::Exempt),
            ("logcat", CargoStatus::Scanned),
            ("drive", CargoStatus::Scanned),
            ("ios", CargoStatus::Scanned),
            ("proxy", CargoStatus::Scanned),
            ("diag", CargoStatus::Scanned),
            ("relay", CargoStatus::Scanned),
        ] {
            assert_eq!(policy.sinks[sink].cargo_status, expected, "`{sink}`");
        }
        // And the exemption never stands in for the rules being off: the sink
        // that skips cargo's lines still runs S1–S12 over every other one.
        assert!(policy.sinks["rust-test"].structural_rules);
        assert!(policy.sinks["soak"].structural_rules);
    }

    /// Which sinks carry a PROOF-OF-RUN line, and what it must match.
    ///
    /// The proof is the half of the anti-vacuity check a line count cannot be,
    /// so it is pinned here with the renderings it has to catch: Android
    /// forwards the reporter through logcat, `flutter test` prints it bare, and
    /// a failing run renders `+N -M:`. It is pinned in the other direction too:
    /// a class whose captures do NOT come from a test reporter would be
    /// demanding a line its producer never writes, i.e. rc 4 on every green run.
    #[test]
    fn only_the_test_reporter_sink_declares_a_proof_of_run() {
        let policy = Policy::load().expect("policy");
        let pattern = policy.sinks["drive"]
            .proof_of_run
            .as_deref()
            .expect("the drive class carries the proof");
        let proof = regex::Regex::new(pattern).expect("a valid pattern");
        for line in [
            "I/flutter ( 4457): 00:00 +0: M7 disable: register a task then disable consent",
            "I/flutter ( 4106): 00:08 +2: All tests passed!",
            "00:01 +31: /home/runner/work/Haven-App/haven/test/providers/x_test.dart: ok",
            "00:02 +12 -1: haven/test/y_test.dart: a failing test [E]",
        ] {
            assert!(proof.is_match(line), "must prove a test ran: {line:?}");
        }
        for line in [
            "Installing ../../../../../../tmp/integration-apks/m7_worker_disable_test.apk...      1,362ms",
            "VMServiceFlutterDriver: Connected to Flutter application.",
            "I/Choreographer( 4457): Skipped 59 frames!  The application may be doing too much work",
            "All tests passed.",
            "D/WM-SystemJobScheduler( 4457): Scheduling work ID 7580a323 Job ID 5",
        ] {
            assert!(
                !proof.is_match(line),
                "the tool's own furniture is printed whether or not a test ran: {line:?}"
            );
        }
        for (sink, spec) in &policy.sinks {
            assert_eq!(
                spec.proof_of_run.is_some(),
                sink == "drive",
                "`{sink}`: only a class whose every capture comes from a test reporter has such a line"
            );
        }
    }

    #[test]
    fn an_empty_proof_of_run_is_rejected() {
        let text = r#"
schema = 1
base64_entropy_bits = 4.2
min_term_len = 6
furniture = []
[classes]
[sinks]
drive = { term_floor = 6, declared_plants_expected = false, structural_rules = true, reassemble = false, min_lines = 1, entry_format = "plain", proof_of_run = "" }
[ledger]
"#;
        let err = Policy::parse(text).expect_err("a proof every line satisfies is no proof");
        assert!(err.contains("proves nothing"), "{err}");
    }

    #[test]
    fn a_proof_of_run_that_is_not_a_regex_is_rejected() {
        let text = r#"
schema = 1
base64_entropy_bits = 4.2
min_term_len = 6
furniture = []
[classes]
[sinks]
drive = { term_floor = 6, declared_plants_expected = false, structural_rules = true, reassemble = false, min_lines = 1, entry_format = "plain", proof_of_run = "+[" }
[ledger]
"#;
        let err = Policy::parse(text).expect_err("a proof nothing can match is rc 4 on every run");
        assert!(err.contains("not a valid regular expression"), "{err}");
    }

    #[test]
    fn a_sink_that_omits_the_declared_plant_expectation_is_rejected() {
        let text = r#"
schema = 1
base64_entropy_bits = 4.2
min_term_len = 6
furniture = []
[classes]
[sinks]
drive = { term_floor = 6, structural_rules = true, reassemble = false, min_lines = 1, entry_format = "plain" }
[ledger]
"#;
        let err = Policy::parse(text).expect_err("the expectation has no default");
        assert!(err.contains("declared_plants_expected"), "{err}");
    }

    #[test]
    fn a_sink_cannot_expect_a_plant_the_policy_cannot_declare() {
        let text = r#"
schema = 1
base64_entropy_bits = 4.2
min_term_len = 6
furniture = []
[classes]
[sinks]
drive = { term_floor = 6, declared_plants_expected = true, structural_rules = true, reassemble = false, min_lines = 1, entry_format = "plain" }
[ledger]
"#;
        let err = Policy::parse(text).expect_err("an unsatisfiable control must be rejected");
        assert!(err.contains("could never be satisfied"), "{err}");
    }

    #[test]
    fn a_label_declared_both_covered_and_a_gap_is_rejected() {
        let text = r#"
schema = 1
base64_entropy_bits = 4.2
min_term_len = 6
furniture = []
[classes]
pubkey = { kind = "bytes" }
[sinks]
drive = { term_floor = 6, declared_plants_expected = false, structural_rules = true, reassemble = false, min_lines = 1, entry_format = "plain" }
[ledger.pubkey]
covered = ["hex-lower"]
[ledger.pubkey.gaps]
"hex-lower" = "both at once"
"#;
        let err = Policy::parse(text).expect_err("a contradictory claim must be rejected");
        assert!(err.contains("both covered and a gap"), "{err}");
    }

    #[test]
    fn a_class_with_no_ledger_table_is_rejected() {
        let text = r#"
schema = 1
base64_entropy_bits = 4.2
min_term_len = 6
furniture = []
[classes]
pubkey = { kind = "bytes" }
[sinks]
drive = { term_floor = 6, declared_plants_expected = false, structural_rules = true, reassemble = false, min_lines = 1, entry_format = "plain" }
[ledger]
"#;
        let err = Policy::parse(text).expect_err("an unledgered class must be rejected");
        assert!(err.contains("no ledger table"), "{err}");
    }

    #[test]
    fn a_logcat_sink_with_no_owned_tags_is_rejected() {
        let text = r#"
schema = 1
base64_entropy_bits = 4.2
min_term_len = 6
furniture = []
[classes]
[sinks]
logcat = { term_floor = 8, declared_plants_expected = false, structural_rules = true, reassemble = true, min_lines = 1, entry_format = "logcat" }
[ledger]
"#;
        let err = Policy::parse(text).expect_err("an unscoped logcat sink must be rejected");
        assert!(err.contains("owned tags"), "{err}");
    }

    /// The `ios` twin of the rule above: an unscoped `log show` sink would put
    /// every Apple framework linked into the app under Haven's structural rules.
    #[test]
    fn an_ios_sink_with_no_owned_emitters_is_rejected() {
        let text = r#"
schema = 1
base64_entropy_bits = 4.2
min_term_len = 6
furniture = []
[classes]
[sinks]
ios = { term_floor = 8, declared_plants_expected = false, structural_rules = true, reassemble = false, min_lines = 1, entry_format = "ios" }
[ledger]
"#;
        let err = Policy::parse(text).expect_err("an unscoped ios sink must be rejected");
        assert!(err.contains("owned emitters"), "{err}");
    }

    #[test]
    fn a_term_floor_below_the_global_minimum_is_rejected() {
        let text = r#"
schema = 1
base64_entropy_bits = 4.2
min_term_len = 6
furniture = []
[classes]
[sinks]
drive = { term_floor = 4, declared_plants_expected = false, structural_rules = true, reassemble = false, min_lines = 1, entry_format = "plain" }
[ledger]
"#;
        let err = Policy::parse(text).expect_err("a sub-minimum floor must be rejected");
        assert!(err.contains("below min_term_len"), "{err}");
    }
}
