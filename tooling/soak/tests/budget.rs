//! What a profile promises to fit into, checked against what its arms actually
//! cost.
//!
//! Every arm's deadline is DERIVED — a composition of `oracle::bounds` terms —
//! so this test does not check a number somebody typed. It checks that the sum
//! of the bounds the product's own constants imply, plus the headroom the
//! profile keeps, still fits inside the run budget that profile declares. When a
//! constant in haven-core moves, this is what says whether the PR lane still
//! fits, rather than a lane timing out at 3 a.m.
//!
//! # The run budget, not the deadline above it
//!
//! `run_budget_secs` is the work; `deadline_secs` is the timeout the lane arms
//! ABOVE it, so a hung run is killed with time left to write its banner, its
//! timeline and its verdict. Summing against the deadline would spend the
//! finalisation window on scenarios. The tie between the profile's declared
//! deadline and the workflow's own literal belongs to
//! `check_soak_lane_reachable.sh`: a crate test that parsed a workflow would
//! duplicate a guard and split its ownership.

use std::time::Duration;

use haven_soak::nemesis::generator::Generator;
use haven_soak::nemesis::types::Op;
use haven_soak::oracle::{bounds, Recovery};
use haven_soak::profiles::{ProfileName, ProfileSpec};
use haven_soak::scenarios::{registry, Scenario};

/// A seed for pricing the schedule. Any seed prices the same, because the
/// generator places exactly one probe per slot and the slot count is a property
/// of the WORLD's shape, not of the draw — which is what makes a budget
/// derivable from a profile at all.
const PRICING_SEED: u64 = 0x5eed;

/// The profile's tick period, which the quiescence bound pays for its stability
/// window.
const fn tick(spec: &ProfileSpec) -> Duration {
    Duration::from_millis(spec.tick_ms)
}

/// Every (scenario, arm) a profile declares.
fn declared(spec: &ProfileSpec) -> Vec<(Scenario, &'static haven_soak::scenarios::Arm)> {
    let mut out = Vec::new();
    for selection in &spec.scenarios {
        let scenario = Scenario::with_id(&selection.id).expect("a profile names a known scenario");
        for label in &selection.arms {
            out.push((
                scenario,
                scenario.arm(label).expect("a profile names a known arm"),
            ));
        }
    }
    out
}

/// The summed deadlines of everything a profile runs.
fn summed(spec: &ProfileSpec) -> Duration {
    declared(spec)
        .iter()
        .map(|(_, arm)| arm.deadline(tick(spec), &spec.world))
        .sum()
}

/// How many probe rounds the background schedule asks for in this world.
///
/// Read off the materialised schedule rather than recomputed here: the driver
/// grades one round per `Op::Probe`, so the op list IS the price list.
fn scheduled_probes(spec: &ProfileSpec) -> u32 {
    let schedule = Generator::new(spec.clone(), PRICING_SEED).schedule(&spec.world);
    u32::try_from(
        schedule
            .ops()
            .iter()
            .filter(|scheduled| scheduled.op == Op::Probe)
            .count(),
    )
    .unwrap_or(u32::MAX)
}

/// What the NEMESIS phase costs, priced the way an arm is priced.
///
/// The driver walks the schedule before it runs a single arm, and that walk is
/// graded: one `LocationRoundTrip` round per scheduled probe, and a final
/// O1/O2/O6 round over the settled world. Every one of those rounds is graded
/// at `Recovery::Reconnect`, because a slot may have healed a dropped endpoint
/// and the pool's own ladder is then in the path.
///
/// One round-trip budget per ROUND, which is exactly the model
/// `Arm::deadline` uses — the two halves of a run have to be priced in the same
/// units or the sum means nothing.
fn nemesis_cost(spec: &ProfileSpec) -> Duration {
    bounds::round_trip(Recovery::Reconnect) * scheduled_probes(spec)
        + bounds::quiescence(Recovery::Reconnect, tick(spec))
        + bounds::round_trip(Recovery::Reconnect)
}

#[test]
fn every_profile_fits_inside_its_own_run_budget() {
    for name in ProfileName::ALL {
        let spec = ProfileSpec::embedded(name).expect("an embedded profile");
        let margin = Duration::from_secs(spec.margin_secs);
        let budget = Duration::from_secs(spec.run_budget_secs);
        assert!(
            summed(&spec) + nemesis_cost(&spec) + margin <= budget,
            "the summed deadlines of the WHOLE run — the arms and the background \
             schedule the driver walks before them — plus the margin no longer \
             fit the run budget; run fewer arms or raise the budget, never \
             loosen a bound"
        );
    }
}

#[test]
fn the_nemesis_phase_is_priced_from_the_schedule_the_run_walks() {
    // A phase nobody priced is a phase whose cost cannot move when a product
    // constant does. Re-derived here from the same two things the driver uses:
    // the op list, and the bound each round is graded against.
    for name in ProfileName::ALL {
        let spec = ProfileSpec::embedded(name).expect("an embedded profile");
        let probes = scheduled_probes(&spec);
        assert!(
            probes > 0,
            "a schedule with no probe round grades nothing at all, and the \
             background phase would then be a walk nobody looked at"
        );
        assert!(
            nemesis_cost(&spec)
                == bounds::round_trip(Recovery::Reconnect) * probes
                    + bounds::quiescence(Recovery::Reconnect, tick(&spec))
                    + bounds::round_trip(Recovery::Reconnect),
            "the phase's price is its probe rounds plus its teardown round, and \
             nothing else"
        );
    }
    // Seed-independent: the slot count is a property of the world's shape, so a
    // budget derived from one seed prices every run of that profile.
    let spec = ProfileSpec::embedded(ProfileName::Pr).expect("the pr profile");
    let one = Generator::new(spec.clone(), 1).schedule(&spec.world);
    let other = Generator::new(spec.clone(), 2).schedule(&spec.world);
    let probes_of = |schedule: &haven_soak::nemesis::types::Schedule| {
        schedule
            .ops()
            .iter()
            .filter(|scheduled| scheduled.op == Op::Probe)
            .count()
    };
    assert!(
        probes_of(&one) == probes_of(&other),
        "two seeds must price the same, or a budget is a property of a draw"
    );
}

#[test]
fn every_registered_scenario_runs_in_at_least_one_profile() {
    for scenario in registry() {
        let declared = ProfileName::ALL.into_iter().any(|name| {
            ProfileSpec::embedded(name)
                .expect("an embedded profile")
                .arms(scenario.id())
                .is_some()
        });
        assert!(
            declared,
            "a registered scenario no profile runs is a scenario nothing executes"
        );
    }
}

#[test]
fn every_arm_of_every_registered_scenario_runs_in_at_least_one_profile() {
    for scenario in registry() {
        for arm in scenario.arms() {
            let declared = ProfileName::ALL.into_iter().any(|name| {
                ProfileSpec::embedded(name)
                    .expect("an embedded profile")
                    .arms(scenario.id())
                    .is_some_and(|labels| labels.iter().any(|label| label == arm.label))
            });
            assert!(
                declared,
                "an arm no profile declares is an arm nothing ever runs"
            );
        }
    }
}

#[test]
fn the_profiles_escalate_rather_than_diverge() {
    // pr ⊆ nightly ⊆ weekly: a nightly red must never be something the PR lane
    // silently stopped covering.
    let pr = ProfileSpec::embedded(ProfileName::Pr).expect("pr");
    let nightly = ProfileSpec::embedded(ProfileName::Nightly).expect("nightly");
    let weekly = ProfileSpec::embedded(ProfileName::Weekly).expect("weekly");
    for (smaller, larger) in [(&pr, &nightly), (&nightly, &weekly)] {
        for selection in &smaller.scenarios {
            let wider = larger
                .arms(&selection.id)
                .expect("a wider profile runs every scenario a narrower one does");
            for label in &selection.arms {
                assert!(
                    wider.contains(label),
                    "a wider profile drops an arm a narrower one runs"
                );
            }
        }
    }
}

#[test]
fn every_profile_names_an_arm_that_exists_and_no_scenario_twice() {
    for name in ProfileName::ALL {
        let spec = ProfileSpec::embedded(name).expect("an embedded profile");
        let mut seen: Vec<&str> = Vec::new();
        for selection in &spec.scenarios {
            assert!(
                !seen.contains(&selection.id.as_str()),
                "a profile declares one scenario twice, so one declaration is ignored"
            );
            seen.push(&selection.id);
            let scenario =
                Scenario::with_id(&selection.id).expect("a profile names a known scenario");
            for label in &selection.arms {
                assert!(
                    scenario.arm(label).is_some(),
                    "a profile names an arm its scenario does not offer"
                );
            }
        }
    }
}

#[test]
fn a_bigger_profile_costs_more_than_a_smaller_one() {
    // The sums are only meaningful if they move with the set: three profiles
    // with the same total would mean the deadlines are not being derived from
    // the arms at all.
    let pr = ProfileSpec::embedded(ProfileName::Pr).expect("pr");
    let nightly = ProfileSpec::embedded(ProfileName::Nightly).expect("nightly");
    let weekly = ProfileSpec::embedded(ProfileName::Weekly).expect("weekly");
    assert!(summed(&nightly) > summed(&pr), "nightly runs strictly more");
    assert!(
        summed(&weekly) > summed(&nightly),
        "weekly runs strictly more"
    );
}

#[test]
fn the_pr_budget_has_room_for_the_run_it_makes_and_not_much_more() {
    // The honest lever if this ever fails is fewer arms or a longer budget —
    // never a loosened bound and never a retry. Asserted in both directions, so
    // a budget that grew past what it buys, or an arm that quietly halved its
    // own deadline, shows up here rather than as slack nobody re-reads.
    let spec = ProfileSpec::embedded(ProfileName::Pr).expect("pr");
    let priced = summed(&spec) + nemesis_cost(&spec);
    let budget = Duration::from_secs(spec.run_budget_secs);
    assert!(priced + Duration::from_secs(spec.margin_secs) <= budget);
    assert!(
        priced * 2 > budget,
        "the PR run no longer uses half the budget it reserves; either a bound \
         stopped being waited for, or the budget is stale"
    );
}
