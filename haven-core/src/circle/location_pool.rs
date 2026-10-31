//! The location-plane relay pool a new circle's relays are drawn from.
//!
//! A circle's relays see every kind-445 its members send, and the `#h` REQs
//! that fetch them. If one of them also carried a member's identity traffic —
//! the kind 10050 / 10002 / 30443 that member authored, a kind 1059 `#p`-tagged
//! to them, their standing inbox REQ, their kind 0 — that relay could join the
//! circle's routing id to the member's pubkey on one socket. So a create the
//! caller names no relays for draws [`RELAYS_PER_NEW_CIRCLE`] of them at random
//! from a curated pool that carries kind 445 only, less every relay the
//! creator's own identity traffic touches (refused when none is left), and
//! preferring relays no invitee lists.
//!
//! The draw is uniform and independent per circle: a per-account choice would
//! be a durable fingerprint and would put every circle on the same relays.

// `OnceLock` backs the debug-only pool override; it is unreferenced in a release
// build (where the override static is gated out), so gate the import too.
#[cfg(debug_assertions)]
use std::sync::OnceLock;

use std::collections::BTreeSet;

use rand::seq::SliceRandom;
use rand::{CryptoRng, RngCore};

use super::error::{CircleError, Result};

/// Curated location-plane relays: a new circle's relays are drawn from these.
///
/// Admission criteria, every one hard:
///
/// (a) `wss` on a public host;
/// (b) accepts an unauthenticated kind 445 from a never-seen key and serves it
///     back by `#h`, in both shapes (with `expiration`, a location; without, a
///     commit, which offline members catch up on);
/// (c) no NIP-42 AUTH on read or write; not paid, web-of-trust gated or
///     kind-restricted against 445;
/// (d) answers Haven's NIP-77 dry-run pass — without it a commit buried past
///     the relay's replay limit cannot be recovered;
/// (e) one entry per operator, and no operator shared with the account seed,
///     discovery or profile plane;
/// (f) no TLS terminator or CDN shared with the account or discovery plane — a
///     shared front end sees both planes' frames from one IP in one second;
/// (g) NIP-11 `limitation.max_subscriptions` of at least 16 (up to ten circles'
///     `#h` REQs plus the inbox REQ can land on one relay);
/// (h) 90-day reliability evidence, or a company or foundation operator;
/// (i) not another Marmot client's default inbox relay, which would put that
///     client's users' `#p` traffic on the circle's own relay.
///
/// Behavioural criteria cannot be read from code: an entry ships only with a
/// dated pass row, operator and terminator in `docs/LOCATION_RELAY_VETTING.md`
/// (CI-enforced by `check_profile_privacy_boundaries.sh` Check 14b; the probe is
/// `tests/location_relay_vetting.rs`). Host disjointness from the other planes
/// is pinned by `tests/profile_plane_separation.rs`.
///
/// Runtime callers use [`location_relays`], which honours the debug-only
/// override; this constant and [`production_location_relays`] never do.
pub const PRODUCTION_LOCATION_RELAYS: &[&str] = &[
    "wss://relay.nostr.com",
    "wss://relay.nostr.hu",
    "wss://relay.lanavault.space",
    "wss://nostrelay.circum.space",
    "wss://relay.mwaters.net",
    "wss://relay.satlantis.io",
    "wss://relay.nostr.wirednet.jp",
    "wss://relay.artx.market",
];

/// How many relays a new circle is given when the pool leaves that many.
pub const RELAYS_PER_NEW_CIRCLE: usize = 3;

/// Process-static override of the location pool, set once via
/// [`set_location_relays_for_test`] in debug builds only.
#[cfg(debug_assertions)]
static LOCATION_RELAYS_OVERRIDE: OnceLock<Vec<String>> = OnceLock::new();

/// The shipped pool as owned, normalised strings; never the override.
#[must_use]
pub fn production_location_relays() -> Vec<String> {
    normalize_all(PRODUCTION_LOCATION_RELAYS.iter().copied())
}

fn normalize_all<'a>(raw: impl Iterator<Item = &'a str>) -> Vec<String> {
    raw.filter_map(crate::relay::normalize_relay_url).collect()
}

/// The pool this process draws from: the debug override when one is
/// installed, else [`PRODUCTION_LOCATION_RELAYS`].
///
/// No fallback to the default-relay override, unlike the discovery plane:
/// those relays are the account's inbox, which the pick excludes anyway. A
/// harness that wants a hermetic create installs THIS override. Entries are
/// normalised on read, so a harness may install loopback URLs before arming
/// [`crate::relay::allow_ws_loopback_for_test`].
#[cfg(debug_assertions)]
#[must_use]
pub fn location_relays() -> Vec<String> {
    if let Some(over) = LOCATION_RELAYS_OVERRIDE.get() {
        return normalize_all(over.iter().map(String::as_str));
    }
    production_location_relays()
}

/// The pool this process draws from: always [`PRODUCTION_LOCATION_RELAYS`]
/// in a release build.
#[cfg(not(debug_assertions))]
#[must_use]
pub fn location_relays() -> Vec<String> {
    production_location_relays()
}

/// Overrides the location pool for E2E tests.
///
/// The installed list is NOT exempt from the pick's exclusions or its host
/// rule: an exempt override would keep a lane green with the exclusion broken.
///
/// # Errors
///
/// * Returns `Err` if called more than once in the same process — the
///   override is install-once via [`OnceLock`].
/// * Returns `Err` when `relays` is empty (every create would be refused).
#[cfg(debug_assertions)]
pub fn set_location_relays_for_test(relays: Vec<String>) -> std::result::Result<(), String> {
    if relays.is_empty() {
        return Err("set_location_relays_for_test requires a non-empty list".to_string());
    }
    LOCATION_RELAYS_OVERRIDE
        .set(relays)
        .map_err(|_existing| "set_location_relays_for_test already installed".to_string())
}

/// Release-build stub for [`set_location_relays_for_test`]: the override path
/// is physically unreachable here.
///
/// # Errors
///
/// Always returns an error.
#[cfg(not(debug_assertions))]
pub fn set_location_relays_for_test(_relays: Vec<String>) -> std::result::Result<(), String> {
    Err("set_location_relays_for_test is disabled in release builds".to_string())
}

/// The server a relay URL names: its lower-cased host and port.
///
/// Exclusion compares servers, not strings: a path or a spelled-out default
/// port on an identity relay is still that server, while two ports of one
/// loopback host stay two relays.
pub fn relay_authority(url: &str) -> Option<String> {
    let canonical = crate::relay::normalize_relay_url(url)?;
    let parsed = url::Url::parse(&canonical).ok()?;
    let host = parsed.host_str()?.to_ascii_lowercase();
    let port = parsed.port_or_known_default()?;
    Some(format!("{host}:{port}"))
}

/// Draws a new circle's relays from `pool`.
///
/// Entries another member could not dial, or the same server spelled twice,
/// are dropped first. `hard_excluded` (the creator's identity relays, as
/// [`relay_authority`]s) is never picked, and when it leaves nothing the create
/// is refused. `soft_excluded` (the invitees' relays) is avoided while enough
/// remain and only fills up to `min(RELAYS_PER_NEW_CIRCLE, eligible)`: a hard
/// exclusion of an invitee's lists would let a crafted relay list steer the
/// circle onto one relay or block the create. Sorted, as the routing component
/// stores it.
///
/// # Errors
///
/// [`CircleError::NoLocationRelay`] when the hard tier leaves no entry.
pub fn pick_circle_relays<R: RngCore + CryptoRng>(
    pool: &[String],
    hard_excluded: &BTreeSet<String>,
    soft_excluded: &BTreeSet<String>,
    rng: &mut R,
) -> Result<Vec<String>> {
    let mut seen = BTreeSet::new();
    let mut preferred = Vec::new();
    let mut fill = Vec::new();
    for raw in pool {
        let Some(url) = crate::relay::normalize_relay_url(raw) else {
            continue;
        };
        if !crate::relay::foreign_relay_dialable(&url) {
            continue;
        }
        let Some(authority) = relay_authority(&url) else {
            continue;
        };
        if hard_excluded.contains(&authority) || !seen.insert(authority.clone()) {
            continue;
        }
        if soft_excluded.contains(&authority) {
            fill.push(url);
        } else {
            preferred.push(url);
        }
    }
    let wanted = RELAYS_PER_NEW_CIRCLE.min(preferred.len() + fill.len());
    if wanted == 0 {
        return Err(CircleError::NoLocationRelay);
    }
    let mut picked: Vec<String> = preferred
        .choose_multiple(rng, wanted.min(preferred.len()))
        .cloned()
        .collect();
    let short = wanted - picked.len();
    picked.extend(fill.choose_multiple(rng, short).cloned());
    picked.sort();
    Ok(picked)
}

/// [`pick_circle_relays`] over [`location_relays`], drawn with `OsRng`.
///
/// # Errors
///
/// [`CircleError::NoLocationRelay`] when `hard` covers the whole pool.
pub fn pick_location_relays(
    hard: &BTreeSet<String>,
    soft: &BTreeSet<String>,
) -> Result<Vec<String>> {
    pick_circle_relays(&location_relays(), hard, soft, &mut rand::rngs::OsRng)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A deterministic word stream: `SplitMix64` over a counter that starts at
    /// the value it is built with. Varied words keep `gen_range` from ever
    /// looping on a rejected draw.
    struct ScriptedRng(u64);

    impl RngCore for ScriptedRng {
        fn next_u32(&mut self) -> u32 {
            u32::try_from(self.next_u64() >> 32).unwrap_or(u32::MAX)
        }

        fn next_u64(&mut self) -> u64 {
            self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = self.0;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        }

        fn fill_bytes(&mut self, dest: &mut [u8]) {
            for chunk in dest.chunks_mut(8) {
                let word = self.next_u64().to_le_bytes();
                chunk.copy_from_slice(&word[..chunk.len()]);
            }
        }

        fn try_fill_bytes(&mut self, dest: &mut [u8]) -> std::result::Result<(), rand::Error> {
            self.fill_bytes(dest);
            Ok(())
        }
    }

    // A test-only marker: the bound is what keeps production on a CSPRNG.
    impl CryptoRng for ScriptedRng {}

    /// How many streams each sweep runs; every assertion below holds for each.
    const SWEEP: u64 = 64;

    fn owned(entries: &[&str]) -> Vec<String> {
        entries.iter().map(|s| (*s).to_string()).collect()
    }

    fn authorities(urls: &[&str]) -> BTreeSet<String> {
        urls.iter()
            .map(|url| relay_authority(url).expect("an authority"))
            .collect()
    }

    fn pick(
        pool: &[String],
        hard: &BTreeSet<String>,
        soft: &BTreeSet<String>,
        stream: u64,
    ) -> Vec<String> {
        pick_circle_relays(pool, hard, soft, &mut ScriptedRng(stream)).expect("a pick")
    }

    fn eight() -> Vec<String> {
        (0..8).map(|i| format!("wss://r{i}.example")).collect()
    }

    #[test]
    fn location_pool_entries_are_wss_public_and_unique() {
        let pool = production_location_relays();
        assert_eq!(
            pool.len(),
            PRODUCTION_LOCATION_RELAYS.len(),
            "an entry failed URL normalization",
        );
        for relay in &pool {
            assert!(relay.starts_with("wss://"), "non-wss entry: {relay}");
            assert!(
                crate::relay::foreign_relay_dialable(relay),
                "entry on a non-public host: {relay}"
            );
        }
        let servers: BTreeSet<String> = pool
            .iter()
            .map(|relay| relay_authority(relay).expect("an authority"))
            .collect();
        assert_eq!(servers.len(), pool.len(), "two entries name one server");
    }

    #[test]
    fn production_location_relays_count_is_pinned() {
        // A resize changes how many operators can see a device's circles and
        // how many distinct sets a circle can get: a reviewed act.
        assert_eq!(PRODUCTION_LOCATION_RELAYS.len(), 8);
        assert_eq!(RELAYS_PER_NEW_CIRCLE, 3);
    }

    #[test]
    fn pick_is_a_subset_of_the_pool() {
        let pool = eight();
        for stream in 0..SWEEP {
            for relay in pick(&pool, &BTreeSet::new(), &BTreeSet::new(), stream) {
                assert!(pool.contains(&relay), "picked outside the pool: {relay}");
            }
        }
    }

    #[test]
    fn pick_takes_three_or_the_whole_pool_when_smaller() {
        for (size, expected) in [(1, 1), (2, 2), (3, 3), (8, 3)] {
            let pool: Vec<String> = eight().into_iter().take(size).collect();
            for stream in 0..SWEEP {
                let picked = pick(&pool, &BTreeSet::new(), &BTreeSet::new(), stream);
                assert_eq!(picked.len(), expected, "a pool of {size}");
                let distinct: BTreeSet<&String> = picked.iter().collect();
                assert_eq!(distinct.len(), picked.len(), "a relay picked twice");
                let mut sorted = picked.clone();
                sorted.sort();
                assert_eq!(picked, sorted, "the pick is not sorted");
            }
        }
    }

    #[test]
    fn pick_never_repeats_a_relay_even_when_the_pool_spells_one_twice() {
        let pool = owned(&[
            "wss://A.example/",
            "wss://a.example",
            "wss://a.example:443",
            "wss://b.example",
        ]);
        for stream in 0..SWEEP {
            let picked = pick(&pool, &BTreeSet::new(), &BTreeSet::new(), stream);
            assert_eq!(picked, owned(&["wss://a.example", "wss://b.example"]));
        }
    }

    #[test]
    fn pick_never_returns_a_hard_excluded_relay_however_it_is_spelled() {
        let pool = owned(&[
            "wss://keep-1.example",
            "wss://relay.example",
            "wss://keep-2.example",
            "wss://keep-3.example",
        ]);
        for spelling in [
            "wss://Relay.Example/",
            "wss://relay.example/inbox",
            "wss://RELAY.example:443",
        ] {
            let hard = authorities(&[spelling]);
            for stream in 0..SWEEP {
                let picked = pick(&pool, &hard, &BTreeSet::new(), stream);
                assert_eq!(
                    picked,
                    owned(&[
                        "wss://keep-1.example",
                        "wss://keep-2.example",
                        "wss://keep-3.example"
                    ]),
                    "{spelling} did not exclude its server",
                );
            }
        }
    }

    #[test]
    fn pick_prefers_relays_no_invitee_lists_and_fills_from_the_rest() {
        let pool = eight();
        // Four unlisted: three of them, never a listed one.
        let soft = authorities(&[
            "wss://r0.example",
            "wss://r1.example",
            "wss://r2.example",
            "wss://r3.example",
        ]);
        for stream in 0..SWEEP {
            for relay in pick(&pool, &BTreeSet::new(), &soft, stream) {
                assert!(
                    !soft.contains(&relay_authority(&relay).expect("an authority")),
                    "an invitee's relay was picked while unlisted ones remained: {relay}"
                );
            }
        }
        // One unlisted: it, and two listed ones to make three.
        let soft: BTreeSet<String> = pool[..7]
            .iter()
            .map(|relay| relay_authority(relay).expect("an authority"))
            .collect();
        for stream in 0..SWEEP {
            let picked = pick(&pool, &BTreeSet::new(), &soft, stream);
            assert_eq!(picked.len(), RELAYS_PER_NEW_CIRCLE);
            assert!(
                picked.contains(&pool[7]),
                "the unlisted relay was not picked"
            );
        }
        // Every entry listed: still three, so an invitee cannot block a create.
        let soft: BTreeSet<String> = pool
            .iter()
            .map(|relay| relay_authority(relay).expect("an authority"))
            .collect();
        for stream in 0..SWEEP {
            assert_eq!(
                pick(&pool, &BTreeSet::new(), &soft, stream).len(),
                RELAYS_PER_NEW_CIRCLE
            );
        }
    }

    #[test]
    fn fallback_never_drops_the_creators_own_exclusion() {
        // Invitees list every entry but the creator's one identity relay: the
        // fill takes from what invitees list and never from the hard tier.
        let pool = eight();
        let hard = authorities(&["wss://r4.example"]);
        let soft: BTreeSet<String> = pool
            .iter()
            .filter(|relay| relay.as_str() != "wss://r4.example")
            .map(|relay| relay_authority(relay).expect("an authority"))
            .collect();
        for stream in 0..SWEEP {
            let picked = pick(&pool, &hard, &soft, stream);
            assert_eq!(picked.len(), RELAYS_PER_NEW_CIRCLE);
            assert!(
                !picked.iter().any(|relay| relay == "wss://r4.example"),
                "the creator's identity relay was picked to fill: {picked:?}"
            );
        }
    }

    #[test]
    fn pick_leaves_out_a_pool_entry_on_a_non_public_host() {
        // `wss` to a non-public host is refused whatever the loopback opt-in
        // says, so no global state is touched.
        let pool = owned(&[
            "wss://ok.invalid",
            "wss://192.168.1.1",
            "wss://localhost",
            "wss://169.254.169.254",
            "wss://[::1]",
            "wss://10.0.0.1",
        ]);
        for stream in 0..SWEEP {
            assert_eq!(
                pick(&pool, &BTreeSet::new(), &BTreeSet::new(), stream),
                owned(&["wss://ok.invalid"])
            );
        }
    }

    #[test]
    fn pick_fails_closed_when_the_hard_tier_is_empty() {
        let pool = eight();
        let every: BTreeSet<String> = pool
            .iter()
            .map(|relay| relay_authority(relay).expect("an authority"))
            .collect();
        let refused = |pool: &[String], hard: &BTreeSet<String>, soft: &BTreeSet<String>| {
            matches!(
                pick_circle_relays(pool, hard, soft, &mut ScriptedRng(0)),
                Err(CircleError::NoLocationRelay)
            )
        };
        assert!(
            refused(&pool, &every, &BTreeSet::new()),
            "the whole pool excluded"
        );
        // The soft tier never re-admits what the hard tier removed.
        assert!(
            refused(&pool, &every, &every),
            "re-admitted through the soft tier"
        );
        assert!(
            refused(&[], &BTreeSet::new(), &BTreeSet::new()),
            "an empty pool"
        );
        assert!(
            refused(
                &owned(&["wss://localhost", "wss://10.0.0.1"]),
                &BTreeSet::new(),
                &BTreeSet::new()
            ),
            "a pool of non-public hosts alone"
        );
    }

    #[test]
    fn pick_is_drawn_from_the_rng_it_is_handed() {
        let pool = eight();
        let none = BTreeSet::new();
        let mut subsets = BTreeSet::new();
        let mut reached = BTreeSet::new();
        for stream in 0..SWEEP {
            let picked = pick(&pool, &none, &none, stream);
            // The same stream gives the same pick: nothing but the handed
            // generator decides it.
            assert_eq!(pick(&pool, &none, &none, stream), picked, "stream {stream}");
            reached.extend(picked.iter().cloned());
            subsets.insert(picked);
        }
        assert!(subsets.len() > 1, "every stream drew the same relays");
        assert_eq!(
            reached,
            pool.iter().cloned().collect::<BTreeSet<_>>(),
            "the sweep never reached some entry"
        );
    }

    #[cfg(debug_assertions)]
    #[test]
    fn set_location_relays_for_test_rejects_empty_list() {
        // The only call to the setter in the lib test binary, and one that
        // cannot install: the empty list is refused before the `OnceLock` is
        // touched, so no other test here sees an override (Check 12b). The
        // override itself is exercised in `tests/location_pool_override.rs`,
        // a process of its own.
        let err = set_location_relays_for_test(vec![]).expect_err("empty input must error");
        assert!(err.contains("non-empty"));
    }
}
