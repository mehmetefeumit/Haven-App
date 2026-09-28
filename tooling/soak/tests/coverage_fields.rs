//! `coverage.log`'s field set, pinned by equality, and every value's class.
//!
//! The same shape as `verdict_fields.rs`, for the second machine-readable file
//! a night uploads: the monitor downloads it, so a field that drifts into it is
//! a field that drifts into a public report. Both halves — a key the writer
//! emits and the table does not classify fails, and a classified key no sample
//! reaches fails too — plus the vocabulary each literal is drawn from, proved
//! whole by a wildcard-free match.

use std::collections::BTreeSet;

use haven_soak::coverage::{Coverage, COVERAGE_KEYS, PROBE_ROUND, SETTLED_ROUND, TRIPLE_KEYS};
use haven_soak::nemesis::types::{ByteCap, ClosedPrefix, DeviceOp, DropClass, Fault, RigCount};
use haven_soak::oracle::Invariant;
use haven_soak::profiles::ProfileName;
use haven_soak::relay::Forgery;
use haven_soak::rig::KillKind;
use haven_soak::scenarios::registry;
use haven_soak::verdict::is_invariant_id;

/// The top-level field set, pinned.
const COVERAGE_FIELDS: usize = 3;

/// One triple's field set, pinned.
const TRIPLE_FIELDS: usize = 4;

/// What a moved pin means.
const PIN_MOVED: &str = "coverage.log's field set moved; classify the new field or stop writing it";

/// Every fault the rig can apply, populated.
///
/// What makes the LIST trustworthy is [`fault_index`], whose wildcard-free
/// match stops compiling the day `Fault` grows a variant.
fn every_fault() -> Vec<Fault> {
    vec![
        Fault::Down,
        Fault::Up,
        Fault::WipeStore,
        Fault::Closed(ClosedPrefix::Blocked),
        Fault::Notice("held for the harness"),
        Fault::SwallowOk,
        Fault::DoubleEveryEvent,
        Fault::ReversePages,
        Fault::EoseForAnotherSubscription,
        Fault::Inject(Forgery::Expired { group_id: [0; 32] }),
        Fault::RefuseOversize {
            max_bytes: ByteCap::new(1024),
        },
        Fault::DropClass(DropClass::Application),
        Fault::ClampLimit(RigCount::new(2)),
        Fault::RefusePage {
            nth: RigCount::new(1),
        },
        Fault::ColdFirstConnect,
        Fault::Heal,
    ]
}

/// The number of `Fault` variants, pinned.
const FAULT_VARIANTS: usize = 16;

/// A distinct ordinal per `Fault` variant: the exhaustiveness proof.
const fn fault_index(fault: &Fault) -> usize {
    match fault {
        Fault::Down => 0,
        Fault::Up => 1,
        Fault::WipeStore => 2,
        Fault::Closed(_) => 3,
        Fault::Notice(_) => 4,
        Fault::SwallowOk => 5,
        Fault::DoubleEveryEvent => 6,
        Fault::ReversePages => 7,
        Fault::EoseForAnotherSubscription => 8,
        Fault::Inject(_) => 9,
        Fault::RefuseOversize { .. } => 10,
        Fault::DropClass(_) => 11,
        Fault::ClampLimit(_) => 12,
        Fault::RefusePage { .. } => 13,
        Fault::ColdFirstConnect => 14,
        Fault::Heal => 15,
    }
}

/// Every operation a device can record taking, populated.
///
/// Every variant, not only the generator's palette: an arm takes
/// `ComeOnline` and `StepPolicyOffset` itself, and a device records what it
/// took whoever asked. [`device_op_index`]'s wildcard-free match is what makes
/// the list whole.
fn every_device_op() -> Vec<DeviceOp> {
    vec![
        DeviceOp::Restart(KillKind::Soft),
        DeviceOp::Restart(KillKind::Hard),
        DeviceOp::GoOffline,
        DeviceOp::ComeOnline,
        DeviceOp::StepPolicyOffset { secs: 288 },
    ]
}

/// The number of distinct `DeviceOp` labels, pinned: one per variant, and one
/// per kill kind.
const DEVICE_OP_LABELS: usize = 5;

/// A distinct ordinal per `DeviceOp` label: the exhaustiveness proof.
const fn device_op_index(op: &DeviceOp) -> usize {
    match op {
        DeviceOp::Restart(KillKind::Soft) => 0,
        DeviceOp::Restart(KillKind::Hard) => 1,
        DeviceOp::GoOffline => 2,
        DeviceOp::ComeOnline => 3,
        DeviceOp::StepPolicyOffset { .. } => 4,
    }
}

/// Every word the `nemesis` field may carry: a fault's label or a device
/// operation's.
fn fault_labels() -> BTreeSet<&'static str> {
    every_fault()
        .iter()
        .map(|fault| fault.label())
        .chain(every_device_op().iter().map(|op| op.label()))
        .collect()
}

/// Every word the `scenario` field may carry: the registry's ids and the
/// background phase's two literals.
fn scenario_ids() -> BTreeSet<&'static str> {
    let mut ids: BTreeSet<&'static str> = registry().iter().map(|s| s.id()).collect();
    ids.insert(PROBE_ROUND);
    ids.insert(SETTLED_ROUND);
    ids
}

/// A record that reaches every scenario, every fault and every invariant.
fn everything() -> serde_json::Value {
    let labels: Vec<&'static str> = fault_labels().into_iter().collect();
    let mut coverage = Coverage::new(ProfileName::Nightly, 0x2a);
    for (tick, scenario) in (0_u64..).zip(scenario_ids()) {
        for invariant in Invariant::REGISTRY {
            coverage.note(scenario, &labels, invariant, tick);
        }
    }
    serde_json::to_value(&coverage).expect("coverage serialises")
}

#[test]
fn the_fault_list_is_the_whole_enum_and_not_one_variant_twice() {
    let faults = every_fault();
    let reached: BTreeSet<usize> = faults.iter().map(fault_index).collect();
    assert!(
        faults.len() == FAULT_VARIANTS,
        "the sampled fault list moved"
    );
    assert!(
        reached.len() == FAULT_VARIANTS,
        "one variant is sampled twice and another not at all"
    );
    let ops = every_device_op();
    let reached: BTreeSet<usize> = ops.iter().map(device_op_index).collect();
    assert!(
        ops.len() == DEVICE_OP_LABELS && reached.len() == DEVICE_OP_LABELS,
        "one device operation is sampled twice and another not at all"
    );
    assert!(
        fault_labels().len() == FAULT_VARIANTS + DEVICE_OP_LABELS,
        "two faults or device operations share a label, so the nemesis field could not tell \
         them apart"
    );
}

#[test]
fn the_background_phase_literals_are_pinned_and_distinct_from_every_registry_id() {
    // The monitor's knee reads PROBE_ROUND triples only; a teardown round
    // folded into it would make the knee the schedule's length every night.
    assert!(PROBE_ROUND == "nemesis", "the monitor reads this literal");
    assert!(SETTLED_ROUND == "settled", "the monitor skips this literal");
    assert!(
        scenario_ids().len() == registry().len() + 2,
        "a background-phase literal collides with a registry id"
    );
}

#[test]
fn the_field_sets_are_pinned_and_the_writer_emits_exactly_them() {
    assert!(COVERAGE_KEYS.len() == COVERAGE_FIELDS, "{PIN_MOVED}");
    assert!(TRIPLE_KEYS.len() == TRIPLE_FIELDS, "{PIN_MOVED}");

    let written = everything();
    let top: BTreeSet<&str> = written
        .as_object()
        .expect("an object")
        .keys()
        .map(String::as_str)
        .collect();
    assert!(
        top == COVERAGE_KEYS.iter().copied().collect::<BTreeSet<_>>(),
        "a top-level key the writer emits and the allowlist does not name would reach a report"
    );
    let triples = written["triples"].as_array().expect("a triple list");
    assert!(
        !triples.is_empty(),
        "a sample that reaches no triple checks no triple"
    );
    for triple in triples {
        let keys: BTreeSet<&str> = triple
            .as_object()
            .expect("a triple is an object")
            .keys()
            .map(String::as_str)
            .collect();
        assert!(
            keys == TRIPLE_KEYS.iter().copied().collect::<BTreeSet<_>>(),
            "a triple's keys must be exactly the four declared"
        );
    }
}

#[test]
fn every_value_is_a_literal_of_its_own_vocabulary() {
    let written = everything();
    let profiles: BTreeSet<&str> = ProfileName::ALL.iter().map(|p| p.as_str()).collect();
    assert!(
        written["profile"]
            .as_str()
            .is_some_and(|profile| profiles.contains(profile)),
        "the profile is a TOML's own name"
    );
    assert!(
        written["seed"] == serde_json::json!("0x000000000000002a"),
        "the seed is the banner's spelling, sixteen hex and no more"
    );
    let scenarios = scenario_ids();
    let faults = fault_labels();
    for triple in written["triples"].as_array().expect("a triple list") {
        assert!(
            triple["scenario"]
                .as_str()
                .is_some_and(|id| scenarios.contains(id)),
            "a scenario outside the registry is a string somebody else composed"
        );
        assert!(
            triple["nemesis"]
                .as_str()
                .is_some_and(|label| faults.contains(label)),
            "a nemesis outside Fault::label's vocabulary is a string somebody else composed"
        );
        assert!(
            triple["invariant"].as_str().is_some_and(is_invariant_id),
            "the invariant is namespaced and in the registry, as verdict.log spells it"
        );
        assert!(
            triple["first_tick"].as_u64().is_some(),
            "a tick is a count from the world's origin"
        );
    }
}

#[test]
fn every_classified_field_is_reached_by_a_sample() {
    let written = everything();
    let first = &written["triples"][0];
    for key in TRIPLE_KEYS {
        assert!(
            first.get(key).is_some(),
            "a classified field no sample reaches is a class that is now a comment"
        );
    }
    let reached: BTreeSet<&str> = written["triples"]
        .as_array()
        .expect("a triple list")
        .iter()
        .filter_map(|triple| triple["nemesis"].as_str())
        .collect();
    assert!(
        reached == fault_labels(),
        "every fault label the rig can record reaches the file through note()"
    );
}

#[test]
fn a_tick_is_carried_as_given_and_never_becomes_an_instant() {
    // The record takes a tick and writes that tick: there is no clock in the
    // module to read, so the only way an instant could appear is a caller
    // passing one, and the driver passes `current_tick()`.
    let mut coverage = Coverage::new(ProfileName::Pr, 0);
    coverage.note("S01", &["down"], Invariant::Quiescence, 7);
    let written = serde_json::to_value(&coverage).expect("coverage serialises");
    assert!(
        written["triples"][0]["first_tick"] == serde_json::json!(7),
        "the tick written is the tick given"
    );
    let source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/coverage.rs"),
    )
    .expect("the module's source is readable");
    for clock in ["SystemTime", "Instant", "Utc", "chrono", "now()"] {
        assert!(
            !source.contains(clock),
            "coverage.rs reads no clock, so no field of it can be an instant"
        );
    }
}

#[test]
fn no_coverage_field_carries_a_shape_a_structural_rule_matches() {
    let rendered = everything().to_string();
    let mut run = 0_usize;
    for character in rendered.chars() {
        if character.is_ascii_hexdigit() {
            run += 1;
            assert!(
                run < 32,
                "coverage.log carries a hex run a structural rule matches"
            );
        } else {
            run = 0;
        }
    }
    assert!(
        !rendered.contains("://"),
        "coverage.log carries an endpoint"
    );
    for candidate in rendered.split(|c: char| !(c.is_ascii_digit() || c == '.')) {
        let parts: Vec<&str> = candidate.split('.').collect();
        assert!(
            !(parts.len() == 4
                && parts
                    .iter()
                    .all(|part| !part.is_empty() && part.chars().all(|c| c.is_ascii_digit()))),
            "coverage.log carries a dotted quad"
        );
    }
    for needle in ["Saturday Ride", "npub1", "simdev#", "127.0.0.1", "wss://"] {
        assert!(
            !rendered.contains(needle),
            "coverage.log names no circle, key, device or endpoint"
        );
    }
}
