//! Proves the hermetic profile-relay override actually reaches the code that
//! resolves the pool.
//!
//! # Why this test exists
//!
//! `set_profile_relays_for_test` installs a process-global override of the
//! curated profile pool, so the E2E lanes can point kind-0 traffic at local
//! relays. But an override is only worth anything if every RUNTIME reader goes
//! through the effective accessor ([`profile_relay_pool_default`]) rather than
//! the raw constant (`production_profile_relays`). Two call sites originally
//! read the constant:
//!
//! * the first-launch seed for `RelayType::Profile`, and
//! * the union inside `usable_profile_relays`, which re-admits the curated pool
//!   after the user's own stored rows.
//!
//! The second is the load-bearing one. Because it UNIONS the pool back in,
//! reading the constant there would pull the eight real public relays into the
//! pool even with an override installed — so a hermetic E2E would dial hosts it
//! never intended to contact, and would keep passing while proving nothing
//! about plane separation. That is a silent failure: nothing errors, no test
//! goes red, and the lane looks green.
//!
//! This test pins the wiring end to end, from the override through
//! `CircleManager::usable_profile_relays`.
//!
//! # Why its own integration binary
//!
//! The override is a `OnceLock` and is therefore install-once PER PROCESS. No
//! lib unit test may install it at all — `haven-core`'s lib tests share one
//! binary whose parallel, unordered execution would make every `circle::`
//! assertion about the curated pool order-dependent (see the NOTE in
//! `src/profile/relay_pool.rs`'s test module, and Check 12 in
//! `scripts/ci/check_profile_privacy_boundaries.sh`). An integration test gets
//! its own process, so this file owns ITS install — which is also why it is one
//! test rather than several. The override's own semantics (install-once, what
//! it shadows, exclusion still applying) need a second install and therefore
//! live in a second binary, `profile_relay_override_semantics.rs`.

use haven_core::circle::CircleManager;
use haven_core::profile::{
    production_profile_relays, profile_relay_pool_default, set_profile_relays_for_test,
    PROFILE_POOL_MIN,
};
use nostr::Keys;
use tempfile::TempDir;

/// Three distinct hosts: `resolve_profile_pool` dedupes after normalization and
/// fails closed below [`PROFILE_POOL_MIN`], so one relay spelled three ways
/// would collapse to one entry and underflow.
const OVERRIDE_RELAYS: [&str; 3] = [
    "wss://hermetic-a.test",
    "wss://hermetic-b.test",
    "wss://hermetic-c.test",
];

#[test]
fn installed_override_reaches_usable_profile_relays() {
    assert!(
        OVERRIDE_RELAYS.len() >= PROFILE_POOL_MIN,
        "the override must satisfy the pool minimum or the plane fails closed",
    );

    set_profile_relays_for_test(OVERRIDE_RELAYS.iter().map(|s| (*s).to_string()).collect())
        .expect("first install in this process");

    // Precondition: the override took effect at the accessor. Without this, a
    // silently-ignored install would make every assertion below vacuous.
    let effective = profile_relay_pool_default();
    for relay in OVERRIDE_RELAYS {
        assert!(
            effective
                .iter()
                .any(|r| r.contains(relay.trim_start_matches("wss://"))),
            "override missing from the effective pool: {effective:?}",
        );
    }

    let dir = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let manager = CircleManager::new_unencrypted(dir.path(), &keys).expect("manager opens");

    let usable = manager
        .usable_profile_relays()
        .expect("three uncontaminated relays satisfy the pool minimum");

    // THE assertion: no production relay may appear. `usable_profile_relays`
    // unions the curated pool back in after the user's stored rows, so if that
    // union reads the raw constant instead of the effective accessor, the eight
    // real public hosts land here and a hermetic lane would dial them.
    for production in production_profile_relays() {
        assert!(
            !usable.contains(&production),
            "production relay {production} leaked into the pool despite an \
             installed hermetic override — a runtime reader is using \
             production_profile_relays() where it must use \
             profile_relay_pool_default(). A hermetic E2E would silently dial \
             real public relays and prove nothing. usable={usable:?}",
        );
    }

    // And the override itself is present, so the pool is usable rather than
    // merely free of production hosts.
    assert_eq!(
        usable.len(),
        OVERRIDE_RELAYS.len(),
        "expected exactly the overridden relays, got {usable:?}",
    );
}
