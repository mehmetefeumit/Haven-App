//! What a user's removal of a curated profile relay does — and does not — do.
//!
//! Settings ▸ Relays lists the Profile category straight from
//! `list_user_relays(RelayType::Profile)`, but every kind-0 fetch and publish
//! resolves through `usable_profile_relays()`, which unions
//! `profile_relay_pool_default()` back in on every call. Deleting a curated row
//! therefore shortens the LIST without shortening the SET Haven dials.
//!
//! That union is deliberate and is a recorded privacy invariant
//! (`docs/privacy/privacy_invariants.json`, "The eight profile relays and six
//! discovery relays never overlap, and the user cannot remove them"), which the
//! user-facing copy states in as many words: "You can add your own servers to
//! the profile group, but you cannot take these eight out of it"
//! (`privacyRelaysDetailIndexers`). So the divergence is resolved on the UI
//! side — the Profile section offers no remove control for a curated entry
//! (`haven/lib/src/pages/settings/relay_settings_page.dart`) — and this test is
//! the premise that decision rests on.
//!
//! If someone later makes removal genuinely take effect, THIS test is what goes
//! red first, which is the correct order: the copy, the invariant and the UI
//! affordance all have to move with it.
//!
//! Lives in `tests/` rather than beside `usable_profile_relays` because the
//! assertion needs both `haven_core::circle` storage and
//! `haven_core::profile`'s pool; `src/profile/**` may not import `crate::circle`
//! (`check_profile_privacy_boundaries.sh` Check 3).

use haven_core::circle::{CircleStorage, RelayType};
use haven_core::profile::production_profile_relays;

#[test]
fn removing_a_curated_profile_relay_shortens_the_list_but_not_the_dialled_set() {
    // `CircleStorage::in_memory()` is `#[cfg(test)]`, i.e. lib-unit-tests only;
    // an integration binary opens a real (unencrypted) file the way the sibling
    // relay-preferences integration test does.
    let dir = tempfile::tempdir().expect("temp dir");
    let storage = CircleStorage::new(&dir.path().join("circles.db"), None).expect("open storage");
    storage.seed_defaults_if_unseeded().expect("seed");

    let victim = production_profile_relays()
        .into_iter()
        .next()
        .expect("the curated pool is non-empty");

    assert!(
        storage
            .list_user_relays(RelayType::Profile)
            .expect("list")
            .contains(&victim),
        "precondition: seeding put the curated relay in the user's Profile list",
    );
    assert!(
        storage
            .usable_profile_relays()
            .expect("pool resolves")
            .contains(&victim),
        "precondition: the resolver dials it",
    );

    assert!(
        storage
            .remove_user_relay(&victim, RelayType::Profile)
            .expect("remove"),
        "a row really was deleted",
    );

    // What the settings page reads: the relay is gone.
    assert!(
        !storage
            .list_user_relays(RelayType::Profile)
            .expect("list")
            .contains(&victim),
        "the stored Profile list must lose the row — otherwise this test proves \
         nothing about the divergence",
    );

    // What every kind-0 fetch and publish reads: the relay is still there.
    assert!(
        storage
            .usable_profile_relays()
            .expect("pool still resolves")
            .contains(&victim),
        "removal took effect on the dialled set; the UI may now offer a remove \
         control for curated entries, and the 'you cannot take these eight out' \
         copy has become false",
    );
}
