//! `verdict.log`: the run's answer, in the one shape a machine may read.
//!
//! The banner is for a human and the timeline is for whoever is debugging; this
//! file is for the job that has to decide, without a human, whether a night went
//! red and what to say about it. It is written beside them, with the same `.log`
//! extension every scan in the chain selects by.
//!
//! # An allowlist, and nothing else
//!
//! [`VERDICT_KEYS`] is the whole field set, pinned by EQUALITY in
//! `tests/verdict_fields.rs`. A field added to [`RunVerdict`] and not to that
//! list fails the test rather than reaching a public issue, which is the only
//! ordering that helps: a scanner finds what it was told to look for, so a value
//! nobody declared — a petname, a display name, a relay host — is exactly what a
//! re-scan of a composed body CANNOT catch. The allowlist is the control and the
//! scan is the backstop.
//!
//! # Two free-form fields, validated ON WRITE
//!
//! `invariant` and `handles[]` are the only fields whose contents are not a
//! literal of this crate's own, so both are validated here as well as by the
//! script that reads them: a handle must be one of the rig's own
//! (`simdev#3`) and an invariant id must be namespaced (`INV-O1`). A verdict
//! that fails either check is NOT written — a file the filing job would refuse
//! is better absent, where it reads as "no verdict", than published with a
//! field nobody validated.
//!
//! # Rule 15
//!
//! Every field is a repository fact (the profile, the seed, the commit, the
//! toolchain), a literal from a closed vocabulary (the rc name, the scenario
//! and arm ids, the finding class), a delta (the tick), a duration, or a rig
//! handle. There is no log tail, no rendered finding sentence, no path, no
//! endpoint and no error message — from the rig, from haven-core, or from a
//! relay.

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::banner::Provenance;
use crate::oracle::{Finding, Invariant};
use crate::profiles::ProfileName;
use crate::rc::Rc;

/// The file the run writes beside its banner.
pub const VERDICT_FILE: &str = "verdict.log";

/// Every key `verdict.log` may carry, pinned by equality.
///
/// Fifteen. `finding_class` and `handles` are SEPARATE fields rather than one
/// rendered sentence, because a reader needs a classification it can group by
/// and a handle list it can bound — and the sentence's shape is not pinned.
pub const VERDICT_KEYS: [&str; 15] = [
    "profile",
    "seed",
    "schedule_tag",
    "commit",
    "rustc",
    "rc",
    "rc_name",
    "scenario",
    "arm",
    "invariant",
    "tick",
    "bound_secs",
    "observed_secs",
    "finding_class",
    "handles",
];

/// The prefix a machine-readable invariant id carries.
///
/// Namespaced so the field cannot be satisfied by an arbitrary string: the
/// repository already spells its privacy invariants this way
/// (`INV-D-DIRECTORY-…`), and the filing script validates against it. The
/// prefix is the spelling, not the rule — [`is_invariant_id`] closes the set to
/// the ids this crate mints, so a manifest id in that other namespace is
/// refused here too.
const INVARIANT_PREFIX: &str = "INV-";

/// The handle prefixes this crate mints.
const HANDLE_PREFIXES: [&str; 4] = ["simdev", "simcircle", "simrelay", "simevt"];

/// The most characters a handle's ordinal may have.
const HANDLE_ORDINAL_MAX: usize = 8;

/// Why a verdict could not be written.
///
/// A classification: the `io::Error` underneath one of these renders a path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VerdictError {
    /// A free-form field did not validate, so nothing was written.
    Unvalidated,
    /// The file could not be written.
    Unwritable,
}

impl std::fmt::Display for VerdictError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unvalidated => f.write_str(
                "a verdict field did not validate, so no verdict was written; the run's own \
                 exit code is still its verdict",
            ),
            Self::Unwritable => f.write_str("the verdict could not be written"),
        }
    }
}

/// What a run answers, for a reader that is not a person.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RunVerdict {
    /// The profile, as the TOMLs spell it.
    profile: &'static str,
    /// The seed, `0x` and sixteen hex — the banner's own spelling.
    seed: String,
    /// The schedule's 8-hex tag. Short deliberately: a structural rule matches
    /// 32 hex and up, and this file is scanned like every other sink.
    schedule_tag: String,
    /// The commit, at most twelve hex, or `unknown`.
    commit: String,
    /// The toolchain version, or `unknown`.
    rustc: String,
    /// The exit code the run ends on.
    rc: i32,
    /// That code's name, from the rc taxonomy's own vocabulary.
    rc_name: &'static str,
    /// The violation half: absent in its entirety on a clean run, which is what
    /// makes "is there a finding here?" answerable without a rule.
    #[serde(flatten)]
    violation: Option<Violation>,
}

/// The first thing that broke, as a machine reads it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Violation {
    /// The scenario's id, a `&'static str` from the registry.
    pub scenario: &'static str,
    /// The arm's label, likewise.
    pub arm: &'static str,
    /// The invariant's id, namespaced — or absent when what broke was the arm's
    /// own expectation floor rather than an oracle.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub invariant: Option<String>,
    /// The tick it was seen at: a count from the world's origin, never an
    /// instant.
    pub tick: u64,
    /// The bound the arm was entitled to take.
    pub bound_secs: u64,
    /// What it took.
    pub observed_secs: u64,
    /// The finding's classification code.
    pub finding_class: &'static str,
    /// The rig handles the finding named.
    pub handles: Vec<String>,
}

impl Violation {
    /// The violation `invariant` and `finding` describe at `tick`.
    ///
    /// `invariant` is `None` for a floor: an expectation floor is the arm's own
    /// declaration, not one of the registry's promises, and giving it a
    /// borrowed id would make a reader group it with an oracle.
    #[must_use]
    pub fn new(
        scenario: &'static str,
        arm: &'static str,
        invariant: Option<Invariant>,
        finding: Finding,
        tick: u64,
        bound_secs: u64,
        observed_secs: u64,
    ) -> Self {
        Self {
            scenario,
            arm,
            invariant: invariant.map(|invariant| format!("{INVARIANT_PREFIX}{}", invariant.id())),
            tick,
            bound_secs,
            observed_secs,
            finding_class: finding.class(),
            handles: finding.handles(),
        }
    }
}

impl RunVerdict {
    /// The verdict for a run of `profile` at `seed`.
    #[must_use]
    pub fn new(
        profile: ProfileName,
        seed: u64,
        schedule_tag: &str,
        provenance: &Provenance,
        rc: Rc,
    ) -> Self {
        Self {
            profile: profile.as_str(),
            seed: format!("0x{seed:016x}"),
            schedule_tag: schedule_tag.to_owned(),
            commit: provenance.commit_short().to_owned(),
            rustc: provenance.rustc().to_owned(),
            rc: rc.code(),
            rc_name: rc.name(),
            violation: None,
        }
    }

    /// The same verdict carrying the first thing that broke.
    #[must_use]
    pub fn with_violation(mut self, violation: Violation) -> Self {
        self.violation = Some(violation);
        self
    }

    /// Whether every free-form field is one this crate could have minted.
    ///
    /// Checked here as well as in the script that reads the file, because the
    /// two answer different questions: this one says the rig did not produce a
    /// field it cannot vouch for, and the script's says the FILE it was handed
    /// does not carry one.
    #[must_use]
    pub fn validates(&self) -> bool {
        self.violation.as_ref().is_none_or(|violation| {
            violation
                .invariant
                .as_ref()
                .is_none_or(|id| is_invariant_id(id))
                && violation.handles.iter().all(|handle| is_handle(handle))
        })
    }

    /// Writes the verdict into `dir` and answers with its path.
    ///
    /// # Errors
    ///
    /// [`VerdictError::Unvalidated`] if a free-form field is not one this crate
    /// mints — nothing is written, and an absent verdict reads as "no verdict"
    /// rather than as a validated one. [`VerdictError::Unwritable`] if the file
    /// could not be written.
    pub fn write_to(&self, dir: &Path) -> Result<PathBuf, VerdictError> {
        if !self.validates() {
            return Err(VerdictError::Unvalidated);
        }
        let body = serde_json::to_string(self).map_err(|_| VerdictError::Unwritable)?;
        std::fs::create_dir_all(dir).map_err(|_| VerdictError::Unwritable)?;
        let path = dir.join(VERDICT_FILE);
        std::fs::write(&path, format!("{body}\n")).map_err(|_| VerdictError::Unwritable)?;
        Ok(path)
    }
}

/// Whether `text` is one of the rig's own handles.
///
/// Written out rather than matched with a pattern crate: the rule is four
/// prefixes and a short lower-case hex ordinal, and a dependency for that would
/// be a second place the vocabulary lives.
#[must_use]
pub fn is_handle(text: &str) -> bool {
    let Some((prefix, ordinal)) = text.split_once('#') else {
        return false;
    };
    HANDLE_PREFIXES.contains(&prefix)
        && (1..=HANDLE_ORDINAL_MAX).contains(&ordinal.len())
        && ordinal
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
}

/// Whether `text` is an invariant id this crate could have minted.
///
/// A CLOSED set, deliberately, and not a shape: `INV-` followed by an
/// upper-case-and-digits run also describes a 64-hex event id, which is exactly
/// the class of value the one free-form field exists to keep out. The set is
/// [`Invariant::REGISTRY`]'s own ids — the only ones [`Violation::new`] can
/// compose — so an oracle that grew an id without a registry entry cannot reach
/// the file either.
#[must_use]
pub fn is_invariant_id(text: &str) -> bool {
    text.strip_prefix(INVARIANT_PREFIX)
        .is_some_and(|rest| Invariant::REGISTRY.iter().any(|known| known.id() == rest))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rig::{CircleTag, DeviceTag};

    fn a_provenance() -> Provenance {
        Provenance::new(Some("bb310e2f4a9c"), Some("1.97.1"))
    }

    fn a_verdict() -> RunVerdict {
        RunVerdict::new(
            ProfileName::Pr,
            0x5eed,
            "a1b2c3d4",
            &a_provenance(),
            Rc::Clean,
        )
    }

    #[test]
    fn a_clean_run_carries_its_provenance_and_no_violation_fields_at_all() {
        let json = serde_json::to_string(&a_verdict()).expect("a verdict serialises");
        let parsed: serde_json::Value = serde_json::from_str(&json).expect("it is JSON");
        let fields = parsed.as_object().expect("an object");
        assert!(fields.contains_key("rc_name"), "{json}");
        for absent in ["scenario", "arm", "invariant", "finding_class", "handles"] {
            assert!(
                !fields.contains_key(absent),
                "a clean run has no violation to describe"
            );
        }
        assert_eq!(fields["seed"], serde_json::json!("0x0000000000005eed"));
    }

    #[test]
    fn a_violation_names_its_oracle_and_its_handles_and_nothing_else() {
        let verdict = a_verdict().with_violation(Violation::new(
            "S01",
            "single-relay-outage",
            Some(Invariant::LocationRoundTrip),
            Finding::ProbeNotDelivered {
                from: DeviceTag::new(0),
                to: DeviceTag::new(1),
                circle: CircleTag::new(2),
            },
            41,
            145,
            190,
        ));
        let json = serde_json::to_string(&verdict).expect("a verdict serialises");
        let parsed: serde_json::Value = serde_json::from_str(&json).expect("it is JSON");
        assert_eq!(parsed["invariant"], serde_json::json!("INV-O1"));
        assert_eq!(
            parsed["finding_class"],
            serde_json::json!("probe-not-delivered")
        );
        assert_eq!(
            parsed["handles"],
            serde_json::json!(["simdev#0", "simdev#1", "simcircle#2"])
        );
        assert!(verdict.validates());
    }

    #[test]
    fn a_floor_is_a_violation_with_no_invariant_rather_than_a_borrowed_one() {
        let verdict = a_verdict().with_violation(Violation::new(
            "S06",
            "stuck-row-sweep",
            None,
            Finding::FloorUnmet(crate::oracle::FloorTerm::FaultsApplied),
            9,
            26,
            30,
        ));
        let json = serde_json::to_string(&verdict).expect("a verdict serialises");
        let parsed: serde_json::Value = serde_json::from_str(&json).expect("it is JSON");
        assert!(
            parsed
                .as_object()
                .expect("an object")
                .get("invariant")
                .is_none(),
            "an expectation floor is the arm's own declaration, not one of the registry's"
        );
        assert_eq!(parsed["finding_class"], serde_json::json!("floor-unmet"));
        assert_eq!(parsed["handles"], serde_json::json!([]));
    }

    #[test]
    fn the_two_free_form_fields_are_refused_rather_than_written_unvalidated() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let mut verdict = a_verdict().with_violation(Violation::new(
            "S01",
            "single-relay-outage",
            Some(Invariant::Quiescence),
            Finding::NothingProbed,
            1,
            2,
            3,
        ));
        assert!(verdict.write_to(dir.path()).is_ok());

        // A handle nobody minted: the shape this validation exists for is a
        // value that reached the field from somewhere that is not this crate.
        let mut planted = verdict.violation.clone().expect("a violation");
        planted.handles = vec!["Saturday Ride".to_owned()];
        verdict.violation = Some(planted);
        assert!(!verdict.validates());
        assert_eq!(
            verdict.write_to(dir.path()),
            Err(VerdictError::Unvalidated),
            "a verdict the filing job would refuse is better absent than published"
        );

        let mut planted = verdict.violation.clone().expect("a violation");
        planted.handles = vec!["simdev#3".to_owned()];
        planted.invariant = Some("O1".to_owned());
        verdict.violation = Some(planted);
        assert!(
            !verdict.validates(),
            "an un-namespaced invariant id is a string the reader cannot bound"
        );
    }

    #[test]
    fn the_handle_and_invariant_rules_refuse_what_they_are_for() {
        for good in ["simdev#0", "simcircle#2", "simrelay#1", "simevt#a91f3c"] {
            assert!(is_handle(good), "{good}");
        }
        for bad in [
            // production's own vocabulary, which is a DIFFERENT namespace
            "circle#a91f3c",
            // a pubkey-shaped run
            "simdev#9f86d081884c7d659a2feaa0c55ad015",
            // upper-case hex is not the shape the reader validates
            "simdev#AB",
            "simdev#",
            "simdev",
            "Saturday Ride",
            "",
        ] {
            assert!(!is_handle(bad), "{bad}");
        }
        for invariant in Invariant::REGISTRY {
            let id = format!("{INVARIANT_PREFIX}{}", invariant.id());
            assert!(
                is_invariant_id(&id),
                "every id the crate can mint must validate, or a real violation would be dropped"
            );
        }
        // Sixty-four upper-case hex, composed rather than spelled: an event id
        // in that casing satisfies "namespaced, upper-case and digits", which is
        // why the rule is a closed set and not a shape.
        let event_id_shaped = format!("{INVARIANT_PREFIX}{}", "0123456789ABCDEF".repeat(4));
        assert!(
            !is_invariant_id(&event_id_shaped),
            "the one free-form field must not be a place an event id can be spelled"
        );
        for bad in [
            "O1",
            "INV-",
            "inv-o1",
            "INV-O1 and a sentence",
            // A real id, in the privacy manifest's namespace: this crate does
            // not mint it, so its own verdict may not carry it.
            "INV-D-DIRECTORY-RETENTION-BOUNDED",
        ] {
            assert!(!is_invariant_id(bad), "{bad}");
        }
    }

    #[test]
    fn a_refused_verdict_leaves_nothing_behind_and_a_failed_write_is_a_different_answer() {
        let tree = tempfile::tempdir().expect("a temp dir");

        let refused = tree.path().join("refused");
        let mut verdict = a_verdict().with_violation(Violation::new(
            "S01",
            "single-relay-outage",
            Some(Invariant::Quiescence),
            Finding::NothingProbed,
            1,
            2,
            3,
        ));
        let mut planted = verdict.violation.clone().expect("a violation");
        planted.handles = vec!["Saturday Ride".to_owned()];
        verdict.violation = Some(planted);
        assert_eq!(verdict.write_to(&refused), Err(VerdictError::Unvalidated));
        assert!(
            !refused.exists(),
            "validation runs before the directory is made, so a refused verdict leaves neither a \
             half-written file nor an empty tree a reader would take for one"
        );

        // A name a file already holds: `create_dir_all` cannot make a directory
        // there, so the write FAILED — which is not the same answer as "the rig
        // would not vouch for a field", and the two are classified apart
        // because the driver spends them differently.
        let occupied = tree.path().join("occupied");
        std::fs::write(&occupied, "not a directory").expect("the occupying file writes");
        assert_eq!(
            a_verdict().write_to(&occupied),
            Err(VerdictError::Unwritable)
        );
    }

    #[test]
    fn the_written_file_is_a_log_and_holds_one_object() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let path = a_verdict().write_to(dir.path()).expect("it writes");
        assert!(
            path.extension().and_then(std::ffi::OsStr::to_str) == Some("log"),
            "every scan in the chain selects by this extension; another one would upload a \
             file nothing scanned"
        );
        let text = std::fs::read_to_string(&path).expect("it reads back");
        assert_eq!(text.lines().count(), 1, "one object, one line");
        let parsed: serde_json::Value = serde_json::from_str(&text).expect("it is JSON");
        assert!(parsed.is_object());
    }
}
