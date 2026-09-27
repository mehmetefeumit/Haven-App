//! `verdict.log`'s field set, pinned by equality, and every value's class.
//!
//! This file is the ALLOWLIST's own test, and the allowlist is the control: the
//! verdict is the one artifact composed into a public issue body, and a scanner
//! over that body is a backstop — it catches a structural shape (a hex run, a
//! coordinate, an endpoint) and provably cannot catch an undeclared value like
//! a petname or a display name, because nothing declared it. So the guarantee
//! has to be that no field CAN carry one.
//!
//! Both halves, as `timeline_fields.rs` does for the timeline: a key the writer
//! emits and the table does not classify fails, and a row no sample reaches
//! fails too.

use std::collections::BTreeSet;

use haven_soak::banner::Provenance;
use haven_soak::oracle::quiescence::PendingReason;
use haven_soak::oracle::undecryptable;
use haven_soak::oracle::{Finding, FloorTerm, Invariant};
use haven_soak::profiles::ProfileName;
use haven_soak::rc::Rc;
use haven_soak::rig::{CircleTag, DeviceTag};
use haven_soak::scenarios::registry;
use haven_soak::verdict::{is_handle, is_invariant_id, RunVerdict, Violation, VERDICT_KEYS};

/// The field set, pinned. A verdict whose field set can drift is an issue body
/// whose field set can drift.
const VERDICT_FIELDS: usize = 15;

/// What a moved pin means, kept as a constant so the assertion stays on one
/// line.
const PIN_MOVED: &str = "the verdict's field set moved; classify the new field or stop writing it";

/// What a field is allowed to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Class {
    /// A string from one of this crate's closed vocabularies, or a repository
    /// fact (the commit, the toolchain, the seed).
    Literal,
    /// The schedule's own 8-hex tag.
    Tag,
    /// A count from the world's origin.
    Delta,
    /// A span in whole seconds.
    DurationSecs,
    /// A code from the rc taxonomy.
    Code,
    /// A namespaced invariant id.
    InvariantId,
    /// A list of the rig's own handles.
    Handles,
}

/// The table: one row per field `verdict.log` carries.
fn table() -> Vec<(&'static str, Class)> {
    use Class::{Code, Delta, DurationSecs, Handles, InvariantId, Literal, Tag};
    vec![
        ("profile", Literal),
        ("seed", Literal),
        ("schedule_tag", Tag),
        ("commit", Literal),
        ("rustc", Literal),
        ("rc", Code),
        ("rc_name", Literal),
        ("scenario", Literal),
        ("arm", Literal),
        ("invariant", InvariantId),
        ("tick", Delta),
        ("bound_secs", DurationSecs),
        ("observed_secs", DurationSecs),
        ("finding_class", Literal),
        ("handles", Handles),
    ]
}

/// Every word a `literal` field may carry.
///
/// Each one is a constant of this crate or a repository fact: a profile name,
/// an rc name, a scenario id, an arm label, a finding class, the seed, the
/// commit, the toolchain version. A value outside them is a string somebody
/// else composed — which is exactly what Rule 15 keeps out of a published file.
fn vocabulary() -> BTreeSet<String> {
    let mut words = BTreeSet::new();
    for profile in ProfileName::ALL {
        words.insert(profile.as_str().to_owned());
    }
    for rc in [
        Rc::Clean,
        Rc::ViolationOrLeak,
        Rc::RigBroken,
        Rc::Unusable,
        Rc::ProvesTooLittle,
    ] {
        words.insert(rc.name().to_owned());
    }
    for scenario in registry() {
        words.insert(scenario.id().to_owned());
        for arm in scenario.arms() {
            words.insert(arm.label.to_owned());
        }
    }
    // The background schedule's own phase, which runs no arm and names itself.
    words.insert("nemesis".to_owned());
    words.insert("schedule".to_owned());
    for finding in every_finding() {
        words.insert(finding.class().to_owned());
    }
    // The build facts, as the banner spells them.
    words.insert("unknown".to_owned());
    words.insert("bb310e2f4a9c".to_owned());
    words.insert("1.97.1".to_owned());
    words.insert("0x000000000000002a".to_owned());
    words
}

/// Every finding the crate can produce, populated.
///
/// Written out because the values are: a variant needs real handles before a
/// sample can say what it renders. What makes the LIST trustworthy is not this
/// function but [`variant_index`], whose wildcard-free match stops compiling the
/// day `Finding` grows an arm.
fn every_finding() -> Vec<Finding> {
    let device = DeviceTag::new(3);
    let other = DeviceTag::new(1);
    let circle = CircleTag::new(2);
    vec![
        Finding::ProbeNotPublished { device, circle },
        Finding::ProbeNotDelivered {
            from: device,
            to: other,
            circle,
        },
        Finding::DeliveryEvidenceLost { to: other },
        Finding::RowEnvelopeExceeded { device, circle },
        Finding::NothingProbed,
        Finding::RosterNotConverged { device, circle },
        Finding::RosterDiverged { circle },
        Finding::EpochDiverged { circle },
        Finding::BranchDiverged { circle },
        Finding::ConvergenceGated { device, circle },
        Finding::ProposalUncommitted { device, circle },
        Finding::RemovalOwed { device },
        Finding::RemovalOrphaned { device },
        Finding::SendRefused {
            device,
            circle,
            cause: undecryptable::Verdict::SendDeferred,
        },
        Finding::RetentionEdgeRefused { device, circle },
        Finding::RetentionWindowOverrun { device, circle },
        Finding::RetentionEdgesIncomplete,
        Finding::UnaccountedOutcome,
        Finding::UnnamedRow,
        Finding::NothingClassified,
        Finding::NotQuiescent(PendingReason::StagedCommit),
        Finding::BacklogUnsettled { device },
        Finding::FloorUnmet(FloorTerm::FaultsApplied),
    ]
}

/// The number of `Finding` variants, pinned.
const FINDING_VARIANTS: usize = 23;

/// A distinct ordinal per `Finding` variant.
///
/// The exhaustiveness proof: no wildcard arm, so a variant added to `Finding`
/// fails to COMPILE here rather than slipping past the class table with its
/// handles unchecked. Ordinals rather than a bool, because the other way
/// [`every_finding`] can lie is by listing one variant twice and none of
/// another — which only distinct ordinals catch.
const fn variant_index(finding: &Finding) -> usize {
    match finding {
        Finding::ProbeNotPublished { .. } => 0,
        Finding::ProbeNotDelivered { .. } => 1,
        Finding::DeliveryEvidenceLost { .. } => 2,
        Finding::RowEnvelopeExceeded { .. } => 3,
        Finding::NothingProbed => 4,
        Finding::RosterNotConverged { .. } => 5,
        Finding::RosterDiverged { .. } => 6,
        Finding::EpochDiverged { .. } => 7,
        Finding::BranchDiverged { .. } => 8,
        Finding::ConvergenceGated { .. } => 9,
        Finding::ProposalUncommitted { .. } => 10,
        Finding::RemovalOwed { .. } => 11,
        Finding::RemovalOrphaned { .. } => 12,
        Finding::SendRefused { .. } => 13,
        Finding::RetentionEdgeRefused { .. } => 14,
        Finding::RetentionWindowOverrun { .. } => 15,
        Finding::RetentionEdgesIncomplete => 16,
        Finding::UnaccountedOutcome => 17,
        Finding::UnnamedRow => 18,
        Finding::NothingClassified => 19,
        Finding::NotQuiescent(_) => 20,
        Finding::BacklogUnsettled { .. } => 21,
        Finding::FloorUnmet(_) => 22,
    }
}

#[test]
fn the_finding_list_is_the_whole_enum_and_not_one_variant_twice() {
    let findings = every_finding();
    let reached: BTreeSet<usize> = findings.iter().map(variant_index).collect();
    assert!(
        findings.len() == FINDING_VARIANTS,
        "the sampled finding list moved; a finding with no sample has an unchecked class and \
         unchecked handles"
    );
    assert!(
        reached.len() == FINDING_VARIANTS,
        "one variant is sampled twice and another not at all"
    );
}

/// A verdict carrying `finding`, rendered.
fn verdict_with(finding: Finding) -> serde_json::Value {
    let verdict = RunVerdict::new(
        ProfileName::Pr,
        42,
        "a1b2c3d4",
        &Provenance::new(Some("bb310e2f4a9c"), Some("1.97.1")),
        Rc::ViolationOrLeak,
    )
    .with_violation(Violation::new(
        "S01",
        "single-relay-outage",
        Some(Invariant::LocationRoundTrip),
        finding,
        7,
        145,
        190,
    ));
    assert!(
        verdict.validates(),
        "a verdict this crate minted must pass the validation its own writer applies"
    );
    serde_json::to_value(&verdict).expect("a verdict serialises")
}

/// Whether `value` conforms to `class`.
fn conforms(class: Class, value: &serde_json::Value) -> bool {
    match class {
        Class::Literal => value
            .as_str()
            .is_some_and(|text| vocabulary().contains(text)),
        Class::Tag => value
            .as_str()
            .is_some_and(|text| text.len() == 8 && text.chars().all(|c| c.is_ascii_hexdigit())),
        Class::Delta | Class::DurationSecs => value.as_u64().is_some(),
        Class::Code => value.as_i64().is_some_and(|code| (0..=4).contains(&code)),
        Class::InvariantId => value.as_str().is_some_and(is_invariant_id),
        Class::Handles => value.as_array().is_some_and(|handles| {
            handles
                .iter()
                .all(|handle| handle.as_str().is_some_and(is_handle))
        }),
    }
}

#[test]
fn the_field_set_is_pinned_and_the_writer_emits_exactly_it() {
    assert!(VERDICT_KEYS.len() == VERDICT_FIELDS, "{PIN_MOVED}");
    assert!(table().len() == VERDICT_FIELDS, "{PIN_MOVED}");

    let declared: BTreeSet<&str> = VERDICT_KEYS.iter().copied().collect();
    assert!(
        declared.len() == VERDICT_FIELDS,
        "one key is declared twice, so one of the two is never classified"
    );
    let classified: BTreeSet<&str> = table().iter().map(|(field, _)| *field).collect();
    assert!(
        declared == classified,
        "the declared key set and the classified one must be the same set"
    );

    // What the writer really emits, on the verdict that carries every field.
    let written = verdict_with(Finding::ProbeNotPublished {
        device: DeviceTag::new(0),
        circle: CircleTag::new(0),
    });
    let emitted: BTreeSet<&str> = written
        .as_object()
        .expect("an object")
        .keys()
        .map(String::as_str)
        .collect();
    assert!(
        emitted == declared,
        "a key the writer emits and the allowlist does not name would reach an issue body"
    );
}

#[test]
fn every_class_is_a_literal_and_every_handle_is_the_rigs_own() {
    let table = table();
    for finding in every_finding() {
        let written = verdict_with(finding);
        for (field, value) in written.as_object().expect("an object") {
            let class = table
                .iter()
                .find(|(name, _)| name == field)
                .map(|(_, class)| *class)
                .expect("a field the table does not classify");
            assert!(
                conforms(class, value),
                "a verdict field does not conform to the class it declares"
            );
        }
    }
}

#[test]
fn every_classified_field_is_reached_by_a_sample() {
    // The other direction: a row nothing renders is a class nobody checks.
    let written = verdict_with(Finding::ProbeNotDelivered {
        from: DeviceTag::new(0),
        to: DeviceTag::new(1),
        circle: CircleTag::new(2),
    });
    let fields = written.as_object().expect("an object");
    for (field, _) in table() {
        assert!(
            fields.contains_key(field),
            "a classified field no sample reaches is a class that is now a comment"
        );
    }
}

#[test]
fn no_verdict_field_carries_a_shape_a_structural_rule_matches() {
    // The backstop's own shapes, asserted over the file rather than over a
    // composed body: 32 hex and up is a pubkey, an event id and a group id at
    // once; `://` is an endpoint; four dotted numbers is an address.
    for finding in every_finding() {
        let rendered = verdict_with(finding).to_string();
        let mut run = 0_usize;
        for character in rendered.chars() {
            if character.is_ascii_hexdigit() {
                run += 1;
                assert!(
                    run < 32,
                    "a verdict carries a hex run a structural rule matches"
                );
            } else {
                run = 0;
            }
        }
        assert!(!rendered.contains("://"), "a verdict carries an endpoint");
        for candidate in rendered.split(|c: char| !(c.is_ascii_digit() || c == '.')) {
            let parts: Vec<&str> = candidate.split('.').collect();
            assert!(
                !(parts.len() == 4
                    && parts
                        .iter()
                        .all(|part| !part.is_empty() && part.chars().all(|c| c.is_ascii_digit()))),
                "a verdict carries a dotted quad"
            );
        }
    }
}

#[test]
fn a_planted_identifier_is_refused_on_write_and_leaves_no_file() {
    // The needles the lane's own scan plants, put where the only free-form
    // field is: a circle name, an endpoint and a pubkey-shaped hex run. None of
    // them is a handle this crate mints, so the writer refuses the whole
    // verdict — an absent file reads as "no verdict", which is a state the
    // filing job already has a branch for, while a written one would be
    // published as validated.
    let dir = tempfile::tempdir().expect("a temp dir");
    for needle in [
        "Saturday Ride",
        "ws://198.51.100.7:7777",
        "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        "npub1needleneedleneedle",
        "simdev#0 Saturday Ride",
    ] {
        let mut violation = Violation::new(
            "S01",
            "single-relay-outage",
            Some(Invariant::LocationRoundTrip),
            Finding::NothingProbed,
            1,
            2,
            3,
        );
        violation.handles = vec![needle.to_owned()];
        let verdict = RunVerdict::new(
            ProfileName::Pr,
            42,
            "a1b2c3d4",
            &Provenance::new(None, None),
            Rc::ViolationOrLeak,
        )
        .with_violation(violation);
        assert!(!verdict.validates(), "{needle}");
        assert!(verdict.write_to(dir.path()).is_err(), "{needle}");
        assert!(
            !dir.path().join("verdict.log").exists(),
            "a refused verdict must leave nothing behind"
        );
    }
}
