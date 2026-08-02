//! The profile-plane relay pool and its contamination exclusion filter.
//!
//! # The plane-separation invariant
//!
//! A relay must observe EITHER a user's encrypted location traffic (kind-445)
//! and gift wraps (kind-1059), OR their kind-0 profile traffic — never both.
//! A relay that sees both can join "who this IP shares location with" against
//! "who this IP looks up", which reconstructs the social graph that Haven
//! deliberately never publishes as a kind-3 contact list.
//!
//! Two mechanisms enforce it:
//!
//! 1. **Disjoint by construction.** [`PRODUCTION_PROFILE_RELAYS`] shares no
//!    entry with the account seed (`crate::circle::PRODUCTION_DEFAULT_RELAYS`)
//!    or the discovery plane (`crate::relay::PRODUCTION_DISCOVERY_RELAYS`), so
//!    a default-configured user contaminates ZERO pool relays. Unit-pinned by
//!    `pool_is_disjoint_from_account_seed_defaults` and
//!    `pool_is_disjoint_from_discovery_plane`.
//! 2. **Excluded at runtime.** A user may add relays by hand, and a circle
//!    joined from someone else carries the INVITER's routing relays — either
//!    can drag a pool relay onto the location plane. [`resolve_profile_pool`]
//!    subtracts the caller-supplied contaminated set on every call.
//!
//! # Why the contaminated set is injected, never computed here
//!
//! `profile/` may not import `crate::circle` (CI-enforced by
//! `check_profile_privacy_boundaries.sh` Check 3) — that boundary is what
//! structurally keeps circle and group identifiers out of the profile plane.
//! So this module cannot ask which relays carry circle traffic; the caller
//! resolves it and passes bare URLs.
//!
//! # Why exclusion must read an append-only ledger, not live circle rows
//!
//! Contamination is HISTORICAL. A relay that routed a circle's kind-445 last
//! month saw those events, and deleting the circle does not un-see them.
//! Recomputing the set from current rows would shrink it over time and
//! silently re-admit a relay that already holds the user's encrypted traffic.
//! The caller is therefore expected to supply a monotonically-growing set.
//!
//! # The constant, the effective set, and the hermetic override
//!
//! [`PRODUCTION_PROFILE_RELAYS`] / [`production_profile_relays`] are the
//! CONSTANT: what ships. [`profile_relay_pool_default`] is the EFFECTIVE set
//! this process should seed and resolve from, which in debug builds honours the
//! install-once override from [`set_profile_relays_for_test`] so a hermetic E2E
//! lane can point the kind-0 plane at a local relay. Release builds cannot
//! install one (the setter is a fail-closed stub), so the two agree there.
//!
//! The split is load-bearing in both directions. The disjointness proofs in
//! `tests/profile_plane_separation.rs` pin the CONSTANT, so a harness can never
//! quietly retarget the pool those proofs are about; and mechanism 2 above still
//! runs over the override, so an E2E lane exercises the real exclusion filter
//! rather than a bypass that would stay green even if exclusion were broken.

// `OnceLock` backs the debug-only pool override; it is unreferenced in a release
// build (where the override static is gated out), so gate the import too.
#[cfg(debug_assertions)]
use std::sync::OnceLock;

use crate::profile::error::{ProfileError, Result};

/// Curated profile-plane relays.
///
/// Selection criteria, in priority order:
///
/// 1. disjoint from the account seed AND the discovery plane (test-pinned);
/// 2. accepts UNAUTHENTICATED kind-0 writes from an arbitrary pubkey — a relay
///    that silently rejects our publish makes us invisible to every peer whose
///    assignment lands there;
/// 3. no NIP-42 AUTH requirement on read — the profile fetch path is built
///    without a signer and structurally cannot answer a challenge;
/// 4. `wss://` only;
/// 5. metadata-specialised indexers are preferred: they carry no group traffic
///    by policy, and being widely polled keeps Haven users resolvable by
///    outbox-model clients even though Haven publishes no kind-10002 for this
///    plane.
///
/// # Vetting status
///
/// Criteria 2 and 3 are behavioural and cannot be verified by reading code —
/// they require probing each host. Entries here are CANDIDATES pending that
/// probe; see the dependency-auditor task in the rollout plan. The disjointness
/// tests below are meaningful regardless and gate every change to this list.
///
/// Runtime callers must use [`profile_relay_pool_default`], which honors the
/// debug-only override installed via [`set_profile_relays_for_test`]. This
/// constant and [`production_profile_relays`] deliberately do NOT — the
/// plane-separation proofs are stated over them.
pub const PRODUCTION_PROFILE_RELAYS: &[&str] = &[
    "wss://purplepag.es",
    "wss://relay.nostr.band",
    "wss://nostr.mom",
    "wss://offchain.pub",
    "wss://relay.nostr.bg",
    "wss://nostr.oxtr.dev",
    "wss://relay.nostrplebs.com",
    "wss://eden.nostr.land",
];

/// Minimum usable relays required to operate the profile plane.
///
/// Below this, [`resolve_profile_pool`] fails closed with
/// [`ProfileError::PoolUnderflow`] rather than degrading. Three keeps the
/// retry ladder meaningful (a primary and a distinct secondary, plus one
/// spare) while leaving five of the eight curated entries as contamination
/// headroom.
pub const PROFILE_POOL_MIN: usize = 3;

/// Process-static override of the profile-plane relay pool. Set once via
/// [`set_profile_relays_for_test`] in debug builds, never observable in
/// release — hence gated to debug builds so a release build carries no
/// unreferenced static (`dead_code`).
#[cfg(debug_assertions)]
static PROFILE_RELAYS_OVERRIDE: OnceLock<Vec<String>> = OnceLock::new();

/// Returns the curated pool as owned, normalized strings.
///
/// This is the shipped CONSTANT and is never affected by
/// [`set_profile_relays_for_test`]; runtime callers want
/// [`profile_relay_pool_default`] instead.
#[must_use]
pub fn production_profile_relays() -> Vec<String> {
    normalize_all(PRODUCTION_PROFILE_RELAYS.iter().copied())
}

/// Normalizes and collects relay URLs, dropping any entry that fails to parse.
///
/// Dropping rather than erroring matches [`resolve_profile_pool`], which also
/// skips unparseable entries: a malformed URL shrinks the pool toward the
/// fail-closed [`PROFILE_POOL_MIN`] floor instead of substituting anything.
fn normalize_all<'a>(raw: impl Iterator<Item = &'a str>) -> Vec<String> {
    raw.filter_map(crate::relay::normalize_relay_url).collect()
}

/// Returns the profile-plane pool this process should seed and resolve from.
///
/// In release this is always [`PRODUCTION_PROFILE_RELAYS`]. In debug builds the
/// resolution order is:
///
/// 1. the override installed via [`set_profile_relays_for_test`], else
/// 2. [`PRODUCTION_PROFILE_RELAYS`].
///
/// There is deliberately NO safety-net fallback to the account-seed test
/// override — the sibling accessor in `relay/discovery.rs` has one, and copying
/// it here would be a plane-separation hole, not a convenience: those relays are
/// exactly the ones carrying this account's kind-445 and kind-1059 traffic, so
/// routing kind-0 to them is the cross-plane join this module exists to prevent.
/// A harness that wants a local kind-0 plane must install THIS override.
///
/// Entries are normalized on read, not at install time, so a hermetic harness
/// may install loopback URLs before arming
/// [`crate::relay::allow_ws_loopback_for_test`].
#[cfg(debug_assertions)]
#[must_use]
pub fn profile_relay_pool_default() -> Vec<String> {
    if let Some(over) = PROFILE_RELAYS_OVERRIDE.get() {
        return normalize_all(over.iter().map(String::as_str));
    }
    production_profile_relays()
}

/// Returns the profile-plane pool this process should seed and resolve from.
///
/// Always [`PRODUCTION_PROFILE_RELAYS`] in release builds; the override
/// mechanism is unreachable.
#[cfg(not(debug_assertions))]
#[must_use]
pub fn profile_relay_pool_default() -> Vec<String> {
    production_profile_relays()
}

/// Overrides the profile-plane relay pool for E2E tests.
///
/// Intended exclusively for hermetic test harnesses that need kind-0 traffic to
/// resolve to a local relay instead of the curated public pool. Mirrors
/// [`crate::circle::set_default_relays_for_test`] and
/// [`crate::profile::set_blossom_server_for_test`] for this plane.
///
/// Two properties the caller must not expect to be relaxed:
///
/// * The installed list is **not** exempt from contamination exclusion.
///   [`resolve_profile_pool`] subtracts the contaminated set from it exactly as
///   it does from the curated pool. An override that bypassed exclusion would
///   make the E2E lane pass even if exclusion were broken — a rehearsal, not a
///   proof.
/// * Underflow stays terminal, so install at least [`PROFILE_POOL_MIN`] entries
///   that survive normalization AND deduplication (the same local relay spelled
///   three ways collapses to one). A shorter list is accepted here and fails
///   later, at [`resolve_profile_pool`], with
///   [`ProfileError::PoolUnderflow`].
///
/// # Errors
///
/// * Returns `Err` if called more than once in the same process — the override
///   is install-once via [`OnceLock`].
/// * Returns `Err` when `relays` is empty (a zero-length override would break
///   every profile read).
#[cfg(debug_assertions)]
pub fn set_profile_relays_for_test(relays: Vec<String>) -> std::result::Result<(), String> {
    if relays.is_empty() {
        return Err("set_profile_relays_for_test requires a non-empty list".to_string());
    }
    PROFILE_RELAYS_OVERRIDE
        .set(relays)
        .map_err(|_existing| "set_profile_relays_for_test already installed".to_string())
}

/// Release-build stub for [`set_profile_relays_for_test`].
///
/// Always returns an error so release callers fail closed — the override path
/// is physically unreachable here.
///
/// # Errors
///
/// Always returns an error.
#[cfg(not(debug_assertions))]
pub fn set_profile_relays_for_test(_relays: Vec<String>) -> std::result::Result<(), String> {
    Err("set_profile_relays_for_test is disabled in release builds".to_string())
}

/// Subtracts `contaminated` from `configured`, preserving order.
///
/// Both sides are normalized before comparison, so a contaminated
/// `wss://Relay.Example/` correctly excludes a pool entry spelled
/// `wss://relay.example`. Without that, set subtraction would silently
/// no-op on a trailing slash or a capitalised host and the plane separation
/// would fail open — which is why
/// `exclusion_matches_across_url_normalization` exists.
///
/// # Errors
///
/// Returns [`ProfileError::PoolUnderflow`] when fewer than
/// [`PROFILE_POOL_MIN`] relays survive. This is TERMINAL by design: there is
/// deliberately no fallback path, because any fallback would route profile
/// traffic to a relay that already sees the user's location traffic.
pub fn resolve_profile_pool(configured: &[String], contaminated: &[String]) -> Result<Vec<String>> {
    let excluded: Vec<String> = contaminated
        .iter()
        .filter_map(|raw| crate::relay::normalize_relay_url(raw))
        .collect();

    let mut usable: Vec<String> = Vec::with_capacity(configured.len());
    for raw in configured {
        let Some(url) = crate::relay::normalize_relay_url(raw) else {
            continue;
        };
        if excluded.contains(&url) || usable.contains(&url) {
            continue;
        }
        usable.push(url);
    }

    if usable.len() < PROFILE_POOL_MIN {
        return Err(ProfileError::PoolUnderflow {
            usable: usable.len(),
            required: PROFILE_POOL_MIN,
        });
    }
    Ok(usable)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn owned(entries: &[&str]) -> Vec<String> {
        entries.iter().map(|s| (*s).to_string()).collect()
    }

    // NOTE: the two disjointness invariants — profile pool ∩ account seed == ∅
    // and profile pool ∩ discovery plane == ∅ — deliberately live in
    // `tests/profile_plane_separation.rs`, NOT here. Asserting them requires
    // naming `crate::circle`, which the profile module's import boundary
    // forbids (`check_profile_privacy_boundaries.sh` Check 3). That boundary is
    // load-bearing for key separation, so the test moves rather than the rule.

    #[test]
    fn pool_entries_are_wss_and_unique() {
        let pool = production_profile_relays();
        assert_eq!(
            pool.len(),
            PRODUCTION_PROFILE_RELAYS.len(),
            "an entry failed URL normalization",
        );
        let unique: std::collections::HashSet<&String> = pool.iter().collect();
        assert_eq!(unique.len(), pool.len(), "duplicate entry in the pool");
        for relay in &pool {
            assert!(relay.starts_with("wss://"), "non-wss entry: {relay}");
        }
    }

    #[test]
    fn pool_is_large_enough_for_contamination_headroom() {
        assert!(
            PRODUCTION_PROFILE_RELAYS.len() >= PROFILE_POOL_MIN + 5,
            "pool must tolerate several contaminations before underflowing",
        );
    }

    #[test]
    fn exclusion_removes_injected_contaminated_relay() {
        let configured = owned(&[
            "wss://a.example",
            "wss://b.example",
            "wss://c.example",
            "wss://d.example",
        ]);
        let usable =
            resolve_profile_pool(&configured, &owned(&["wss://b.example"])).expect("3 survive");
        assert_eq!(
            usable,
            owned(&["wss://a.example", "wss://c.example", "wss://d.example"]),
        );
    }

    #[test]
    fn exclusion_matches_across_url_normalization() {
        // The footgun: set subtraction that compares raw strings silently
        // no-ops on a trailing slash or a capitalised host, and the profile
        // plane fails OPEN onto a location relay.
        let configured = owned(&[
            "wss://Relay.Example",
            "wss://b.example",
            "wss://c.example",
            "wss://d.example",
        ]);
        let usable = resolve_profile_pool(&configured, &owned(&["wss://relay.example/"]))
            .expect("3 survive");
        assert!(
            !usable.iter().any(|u| u.contains("relay.example")),
            "normalization mismatch let a contaminated relay through: {usable:?}",
        );
        assert_eq!(usable.len(), 3);
    }

    #[test]
    fn exclusion_deduplicates_configured_entries() {
        let configured = owned(&[
            "wss://a.example",
            "wss://a.example/",
            "wss://b.example",
            "wss://c.example",
        ]);
        let usable = resolve_profile_pool(&configured, &[]).expect("3 survive");
        assert_eq!(
            usable,
            owned(&["wss://a.example", "wss://b.example", "wss://c.example"])
        );
    }

    #[test]
    fn exclusion_underflow_errors_and_never_falls_back_to_discovery() {
        // The single most damaging possible bug here would be a fallback to the
        // discovery plane on underflow. Assert the error AND that no discovery
        // URL is reachable through this function.
        let configured = owned(&["wss://a.example", "wss://b.example", "wss://c.example"]);
        let result = resolve_profile_pool(&configured, &owned(&["wss://b.example"]));
        match result {
            Err(ProfileError::PoolUnderflow { usable, required }) => {
                assert_eq!(usable, 2);
                assert_eq!(required, PROFILE_POOL_MIN);
            }
            Err(other) => panic!("expected PoolUnderflow, got {other}"),
            Ok(pool) => panic!("underflow must fail closed, got {pool:?}"),
        }
    }

    #[test]
    fn underflow_error_carries_no_urls() {
        // The error crosses the FFI; counts only, never relay URLs.
        let configured = owned(&["wss://secret-relay.example"]);
        let err = resolve_profile_pool(&configured, &[]).expect_err("underflow");
        let rendered = format!("{err}");
        let debugged = format!("{err:?}");
        assert!(!rendered.contains("secret-relay"), "Display leaked a URL");
        assert!(!debugged.contains("secret-relay"), "Debug leaked a URL");
    }

    #[test]
    fn empty_configured_pool_underflows() {
        let err = resolve_profile_pool(&[], &[]).expect_err("empty pool must fail closed");
        assert!(matches!(err, ProfileError::PoolUnderflow { usable: 0, .. }));
    }

    #[test]
    fn malformed_configured_entries_are_dropped_not_fatal() {
        let configured = owned(&[
            "not-a-url",
            "wss://a.example",
            "wss://b.example",
            "wss://c.example",
        ]);
        let usable = resolve_profile_pool(&configured, &[]).expect("3 valid survive");
        assert_eq!(
            usable,
            owned(&["wss://a.example", "wss://b.example", "wss://c.example"])
        );
    }

    #[cfg(debug_assertions)]
    #[test]
    fn set_profile_relays_for_test_rejects_empty_list() {
        // The ONLY call to the setter anywhere in the lib test binary, and it
        // is deliberately one that cannot install: the empty-list rejection is
        // checked BEFORE the `OnceLock` is touched, so this test leaves the
        // override uninstalled for every other test in the process. See the
        // NOTE below for why that matters.
        let err = set_profile_relays_for_test(vec![]).expect_err("empty input must error");
        assert!(err.contains("non-empty"));
    }

    // NOTE — NO LIB UNIT TEST MAY INSTALL THE OVERRIDE.
    //
    // The override is a process-global `OnceLock` and every `#[cfg(test)]`
    // module in this crate shares ONE binary whose tests run in parallel, in
    // an order that is not part of any contract. An install therefore mutates
    // global state that unrelated tests read: `default_relays_for(Profile)`,
    // `seed_defaults_if_unseeded` and `usable_profile_relays` all resolve
    // through `profile_relay_pool_default()`, and several `circle::` unit
    // tests assert those equal `production_profile_relays()`. With an install
    // anywhere in this binary, those tests are green only while libtest
    // happens to schedule them first — a module rename or a slow overlapping
    // test flips them red non-deterministically, and the obvious "fix"
    // (comparing against the effective accessor instead) would silently
    // retire `profile_category_seeds_from_the_profile_pool_not_the_account_seed`,
    // a CI-pinned plane-separation invariant.
    //
    // So the override is exercised only from integration binaries, which each
    // get their OWN process and therefore their own install:
    //
    // * `tests/profile_relay_override_wiring.rs` — that runtime readers reach
    //   the effective accessor (`installed_override_reaches_usable_profile_relays`);
    // * `tests/profile_relay_override_semantics.rs` — install-once, what the
    //   override does and does not shadow, and that it stays subject to
    //   contamination exclusion.
    //
    // One install per binary means one test per binary; that is why each of
    // those files holds a single multi-section test. Enforced by
    // `scripts/ci/check_profile_privacy_boundaries.sh` (Check 12).

    // NOTE: there is deliberately no `#[cfg(not(debug_assertions))]` test of the
    // fail-closed release stub, for the same reason `relay/discovery.rs` has
    // none: this crate CANNOT be tested with debug assertions off. Its dev
    // self-dependency turns on `test-utils` for every test build, and
    // `src/lib.rs` raises `compile_error!` for `all(feature = "test-utils",
    // not(debug_assertions))`. Such a test would therefore never compile, never
    // run, and rot unnoticed while looking like coverage. The release branch is
    // instead compile-checked by the release-mode build in CI (`rust-check`),
    // and it is total by construction — the stub's body is an unconditional
    // `Err` and the release accessor returns `production_profile_relays()`.
}
