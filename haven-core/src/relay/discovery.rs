//! Discovery-plane relays for resolving *other* users' public metadata.
//!
//! Haven uses a **two-plane** relay model:
//!
//! - The **account plane** is the user's own configured relays. The user's
//!   own relay-list events (kind 10050 / 10051) and key packages are
//!   published there and nowhere else. See [`crate::circle::default_relays`]
//!   for the one-time account-creation seed.
//! - The **discovery plane** (this module) is a curated set of public
//!   indexer relays queried **read-only** to resolve *other* users' relay
//!   lists (kind 10050 / 10051 / 10002) and key packages when all we have is
//!   a bare pubkey.
//!
//! # Why a separate plane
//!
//! Querying a public indexer for *someone else's* pubkey never exposes the
//! local user's own relays — it is a read of foreign data. This is what lets
//! Haven discover contacts by bare pubkey *without* force-publishing the
//! user's own relay list (and any private relay in it) to public relays. The
//! discovery plane is therefore **never** a publish target and **never**
//! carries the local user's writes.
//!
//! # Privacy properties
//!
//! - Read-only: discovery queries attach no signer and never trigger NIP-42
//!   AUTH, so they cannot be tied to the local user's identity.
//! - Bounded: queries are one-shot `REQ`s with a `limit`, never long-lived
//!   subscriptions (consistent with Haven's relay-metadata-minimization
//!   stance).

use std::sync::OnceLock;

/// Production discovery relay URLs (public NIP-65 outbox-model indexers).
///
/// This set is a strict **superset** of [`crate::circle::PRODUCTION_DEFAULT_RELAYS`]
/// (the account-creation seed), enforced by a unit test, so that a user who
/// keeps the seeded public relays stays discoverable by bare pubkey while a
/// user who configures only private relays does not leak them.
///
/// Runtime callers must use [`discovery_relays`], which honors the debug-only
/// override installed via [`set_discovery_relays_for_test`].
pub const PRODUCTION_DISCOVERY_RELAYS: &[&str] = &[
    "wss://index.hzrd149.com",
    "wss://indexer.coracle.social",
    "wss://relay.primal.net",
    "wss://relay.damus.io",
    "wss://relay.ditto.pub",
    "wss://nos.lol",
];

/// Process-static override of the discovery relay list. Set once via
/// [`set_discovery_relays_for_test`] in debug builds, never observable in
/// release.
static DISCOVERY_RELAYS_OVERRIDE: OnceLock<Vec<String>> = OnceLock::new();

/// Returns the production discovery relay list as owned strings.
fn production_discovery_relays() -> Vec<String> {
    PRODUCTION_DISCOVERY_RELAYS
        .iter()
        .map(|s| (*s).to_string())
        .collect()
}

/// Returns the discovery relay list for the current process.
///
/// In release this is always [`PRODUCTION_DISCOVERY_RELAYS`]. In debug builds
/// the resolution order is:
///
/// 1. the override installed via [`set_discovery_relays_for_test`], else
/// 2. the default-relay test override (if a harness installed only that one,
///    so discovery reads stay hermetic — see
///    [`crate::circle::types::default_relays_test_override`]), else
/// 3. [`PRODUCTION_DISCOVERY_RELAYS`].
///
/// The function always returns at least one entry.
#[cfg(debug_assertions)]
#[must_use]
pub fn discovery_relays() -> Vec<String> {
    if let Some(over) = DISCOVERY_RELAYS_OVERRIDE.get() {
        return over.clone();
    }
    // Hermeticity safety net: a harness that installed only the default-relay
    // override (`set_default_relays_for_test`) but not the discovery override
    // would otherwise send discovery reads to the public indexers. Mirror the
    // default override so such harnesses stay fully offline.
    if let Some(default_override) = crate::circle::types::default_relays_test_override() {
        return default_override;
    }
    production_discovery_relays()
}

/// Returns the discovery relay list for the current process.
///
/// Always [`PRODUCTION_DISCOVERY_RELAYS`] in release builds; the override
/// mechanism is unreachable.
#[cfg(not(debug_assertions))]
#[must_use]
pub fn discovery_relays() -> Vec<String> {
    production_discovery_relays()
}

/// Overrides the discovery relay list for E2E tests.
///
/// Intended exclusively for hermetic test harnesses that need every Rust
/// read path resolving *other* users' metadata to redirect to a local strfry
/// instead of the public indexers. Mirrors
/// [`crate::circle::set_default_relays_for_test`] for the discovery plane.
///
/// # Errors
///
/// * Returns `Err` if called more than once in the same process — the
///   override is install-once via [`OnceLock`].
/// * Returns `Err` when `relays` is empty (a zero-length override would
///   break every discovery read).
#[cfg(debug_assertions)]
pub fn set_discovery_relays_for_test(relays: Vec<String>) -> Result<(), String> {
    if relays.is_empty() {
        return Err("set_discovery_relays_for_test requires a non-empty list".to_string());
    }
    DISCOVERY_RELAYS_OVERRIDE
        .set(relays)
        .map_err(|_existing| "set_discovery_relays_for_test already installed".to_string())
}

/// Release-build stub for [`set_discovery_relays_for_test`].
///
/// Always returns an error so release callers fail closed — the override path
/// is physically unreachable here.
///
/// # Errors
///
/// Always returns an error.
#[cfg(not(debug_assertions))]
pub fn set_discovery_relays_for_test(_relays: Vec<String>) -> Result<(), String> {
    Err("set_discovery_relays_for_test is disabled in release builds".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::circle::default_relays;

    #[test]
    fn production_discovery_relays_are_wss() {
        assert!(!PRODUCTION_DISCOVERY_RELAYS.is_empty());
        for relay in PRODUCTION_DISCOVERY_RELAYS {
            assert!(
                relay.starts_with("wss://"),
                "discovery relay {relay} must be wss://"
            );
        }
    }

    #[test]
    fn discovery_relays_returns_curated_list_by_default() {
        // No discovery or default override is installed in this unit-test
        // binary, so the production indexer set is returned verbatim.
        let relays = discovery_relays();
        assert_eq!(relays.len(), PRODUCTION_DISCOVERY_RELAYS.len());
        for expected in PRODUCTION_DISCOVERY_RELAYS {
            assert!(
                relays.iter().any(|r| r == expected),
                "discovery list must contain {expected}"
            );
        }
    }

    #[test]
    fn production_discovery_is_superset_of_production_default_consts() {
        // Lock the discoverability coupling at the constant level, independent
        // of any process override: every account-seed default MUST be a
        // discovery relay, so a seeded user is always discoverable by pubkey.
        for seed in crate::circle::PRODUCTION_DEFAULT_RELAYS {
            assert!(
                PRODUCTION_DISCOVERY_RELAYS.contains(seed),
                "production default {seed} must be a production discovery relay"
            );
        }
    }

    #[test]
    fn discovery_relays_is_superset_of_account_seed() {
        // Discoverability coupling: every seeded account-plane default must be
        // a discovery relay, so a user who keeps the seed stays discoverable.
        let discovery = discovery_relays();
        for seed in default_relays() {
            assert!(
                discovery.iter().any(|d| d == &seed),
                "account-seed relay {seed} must also be a discovery relay"
            );
        }
    }

    #[cfg(debug_assertions)]
    #[test]
    fn set_discovery_relays_for_test_rejects_empty_list() {
        let err = set_discovery_relays_for_test(vec![]).expect_err("empty input must error");
        assert!(err.contains("non-empty"));
    }
}
