//! What the hermetic profile-relay override does — and, just as importantly,
//! what it must NOT shadow.
//!
//! # Why its own integration binary
//!
//! `set_profile_relays_for_test` installs a process-global `OnceLock`, so the
//! install is once PER PROCESS and every assertion that depends on it must run
//! in the process that performed it. Two independent things need an install:
//! the end-to-end wiring proof (`profile_relay_override_wiring.rs`) and the
//! semantics proven here. They therefore live in two integration binaries — one
//! process each — rather than in the lib test binary, which must stay free of
//! any install at all.
//!
//! That last part is load-bearing. `haven-core`'s lib tests share ONE binary
//! whose tests run in parallel in an unspecified order, and several `circle::`
//! unit tests assert that the profile category seeds from
//! `production_profile_relays()`. An install anywhere in that binary makes
//! those tests order-dependent: green only while libtest happens to schedule
//! them before the installing test, red non-deterministically after a rename or
//! under load. The tempting repair — comparing against the effective accessor
//! instead — would silently retire
//! `profile_category_seeds_from_the_profile_pool_not_the_account_seed`, the
//! CI-pinned invariant that the profile plane never seeds from the relays
//! carrying this account's kind-445 traffic. Moving the install out of the lib
//! binary removes the ordering dependency at the source. The lib binary is kept
//! install-free by `scripts/ci/check_profile_privacy_boundaries.sh` (Check 12).
//!
//! # Why one test with four sections
//!
//! One install per process means one test per process: four separate `#[test]`
//! fns in this file would race for the single `OnceLock` exactly as the lib
//! tests did. The sections are numbered instead.

// The override only exists in debug builds (the release setter is a
// fail-closed stub), so gate the whole file rather than each item. In practice
// this is always true — `src/lib.rs` raises `compile_error!` for a test build
// with debug assertions off — but stating it keeps the file honest about which
// build it describes.
#![cfg(debug_assertions)]

use haven_core::profile::{
    production_profile_relays, profile_relay_pool_default, resolve_profile_pool,
    set_profile_relays_for_test, PRODUCTION_PROFILE_RELAYS,
};

fn owned(entries: &[&str]) -> Vec<String> {
    entries.iter().map(|s| (*s).to_string()).collect()
}

#[test]
fn installed_override_shadows_only_the_effective_pool_and_stays_subject_to_exclusion() {
    let installed = owned(&[
        "wss://override-a.profile-plane.invalid",
        "wss://override-b.profile-plane.invalid",
        "wss://override-c.profile-plane.invalid",
        "wss://override-d.profile-plane.invalid",
    ]);
    set_profile_relays_for_test(installed.clone()).expect("first install wins");

    // (1) Install-once: nothing can swap the pool out from under a running
    // process, so the plane a harness armed at startup is the plane it keeps.
    let err = set_profile_relays_for_test(owned(&["wss://second.profile-plane.invalid"]))
        .expect_err("a second install must be rejected");
    assert!(err.contains("already installed"), "unexpected error: {err}");

    // (2) The EFFECTIVE set reflects the override.
    assert_eq!(
        profile_relay_pool_default(),
        installed,
        "the effective pool must be the installed override",
    );

    // (3) The production CONSTANT does not. `tests/profile_plane_separation.rs`
    // states its disjointness proofs over `production_profile_relays()`; if the
    // override reached that accessor, a harness could retarget the very set
    // those proofs are about and they would silently stop describing what ships.
    let production = production_profile_relays();
    assert_eq!(
        production.len(),
        PRODUCTION_PROFILE_RELAYS.len(),
        "the override must not add to or shrink the shipped constant",
    );
    for entry in &installed {
        assert!(
            !production.contains(entry),
            "override entry {entry} leaked into the production constant",
        );
    }

    // (4) The override is NOT exempt from contamination exclusion. If it were,
    // an E2E lane built on it would stay green with the exclusion filter
    // completely broken — it would rehearse plane separation instead of proving
    // it. The contaminated URL is spelled with a trailing slash so
    // normalization is exercised on the override path too.
    let usable = resolve_profile_pool(
        &profile_relay_pool_default(),
        &owned(&["wss://override-b.profile-plane.invalid/"]),
    )
    .expect("three overridden relays survive the exclusion");
    assert!(
        !usable.iter().any(|u| u.contains("override-b")),
        "a contaminated relay survived exclusion on the override path: {usable:?}",
    );
    assert_eq!(
        usable.len(),
        3,
        "only the contaminated entry may be removed"
    );
}
