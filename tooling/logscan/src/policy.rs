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
    /// A `log show` text export, in either rendering: `--style syslog`
    /// (`<date> <time+tz> <host> <process>[<pid>] <<Type>>: <message>`, which is
    /// what the lanes capture) or the default columnar one.
    Ios,
    /// Every line is Haven-owned in full (drive transcripts, `cargo test` logs).
    Plain,
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
    /// Default line floor; `seal --floor <sink>=<n>` overrides it.
    pub min_lines: u64,
    /// How lines are framed.
    pub entry_format: EntryFormat,
    /// Log tags this repo owns. Structural rules run only on these lines.
    #[serde(default)]
    pub owned_tags: Vec<String>,
    /// Process names this repo owns, for `log show` exports.
    #[serde(default)]
    pub owned_processes: Vec<String>,
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
                EntryFormat::Ios if sink.owned_processes.is_empty() => {
                    return Err(format!(
                        "sink `{name}` is ios-framed but names no owned processes"
                    ));
                }
                _ => {}
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
    use super::{ClassKind, Policy};

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
