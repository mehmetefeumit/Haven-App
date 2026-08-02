//! Plane-separation invariants for the profile (kind-0) relay pool.
//!
//! A relay must observe EITHER a user's encrypted location traffic (kind-445)
//! and gift wraps (kind-1059), OR their kind-0 profile traffic — never both. A
//! relay that sees both can join "who this IP shares location with" against
//! "who this IP looks up", reconstructing the social graph Haven deliberately
//! never publishes as a kind-3 contact list.
//!
//! # Why these live here and not beside the code
//!
//! Asserting the invariant requires naming BOTH the profile pool and the
//! circle-side relay constants. `haven-core/src/profile/**` may not import
//! `crate::circle` — that import boundary is CI-enforced by
//! `scripts/ci/check_profile_privacy_boundaries.sh` Check 3 and is load-bearing
//! for key separation. An integration test sits outside the boundary, so it can
//! see both sides without weakening the rule. Do NOT "simplify" these back into
//! `src/profile/relay_pool.rs`; the guard will reject it, correctly.
//!
//! The pool's self-contained properties (wss-only, unique, exclusion filtering,
//! underflow fail-closed) are unit-tested in `src/profile/relay_pool.rs`.
//!
//! # Constants versus sockets
//!
//! The four tests above the divider compare relay *constants*, which is a
//! statement about how the pool is configured. It is not a statement about what
//! the fetch path actually dials — a fetch that ignored the pool would leave
//! them all green. `profile_plane_never_touches_circle_relays_e2e` closes that
//! gap over two real in-process relays, by counting the requests each one is
//! asked to serve.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::types::PRODUCTION_DEFAULT_RELAYS;
use haven_core::profile::{
    assigned_relay, build_metadata_event, fetch_profiles_assigned, production_profile_relays,
    publish_metadata, resolve_profile_pool, ProfileMetadata, ProfileRelaySalt, PROFILE_POOL_MIN,
};
use haven_core::relay::{
    allow_ws_loopback_for_test, normalize_relay_url, RelayManager, PRODUCTION_DISCOVERY_RELAYS,
};
use nostr::util::BoxedFuture;
use nostr::{
    Alphabet, EventBuilder, Filter, JsonUtil, Keys, Kind, Metadata, SingleLetterTag, Tag, TagKind,
};
use nostr_relay_builder::builder::RelayBuilder;
use nostr_relay_builder::prelude::{PolicyResult, QueryPolicy};
use nostr_relay_builder::LocalRelay;

/// The account-seed relays receive kind-445 and kind-1059 for a
/// default-configured user. Any overlap with the profile pool means that user's
/// profile reads land on a relay already holding their encrypted location
/// traffic — the exact cross-plane join the pool exists to prevent.
#[test]
fn pool_is_disjoint_from_account_seed_defaults() {
    let pool = production_profile_relays();
    assert!(!pool.is_empty(), "pool must not be empty (non-vacuity)");
    for seed in PRODUCTION_DEFAULT_RELAYS {
        let normalized = normalize_relay_url(seed).expect("seed relays are valid URLs");
        assert!(
            !pool.contains(&normalized),
            "profile pool contains account-seed relay {seed} — plane separation broken",
        );
    }
}

/// The discovery plane is a strict superset of the account seed (pinned by
/// `relay/discovery.rs`), so every discovery relay is contaminated
/// transitively. The profile pool must avoid all of them, not just the three
/// seeds.
#[test]
fn pool_is_disjoint_from_discovery_plane() {
    let pool = production_profile_relays();
    assert!(!pool.is_empty(), "pool must not be empty (non-vacuity)");
    for relay in PRODUCTION_DISCOVERY_RELAYS {
        let normalized = normalize_relay_url(relay).expect("discovery relays are valid URLs");
        assert!(
            !pool.contains(&normalized),
            "profile pool contains discovery relay {relay} — plane separation broken",
        );
    }
}

/// Guards the anti-vacuity precondition of the two tests above: if the seed and
/// discovery sets were ever emptied, disjointness would hold trivially and stop
/// proving anything.
#[test]
fn contaminated_reference_sets_are_non_empty() {
    assert!(
        !PRODUCTION_DEFAULT_RELAYS.is_empty(),
        "account seed empty — the disjointness tests would pass vacuously",
    );
    assert!(
        !PRODUCTION_DISCOVERY_RELAYS.is_empty(),
        "discovery plane empty — the disjointness tests would pass vacuously",
    );
}

/// The pool must stay large enough that ordinary contamination (a user adding a
/// relay by hand, or joining a circle whose inviter routes through a pool
/// relay) does not drive it under `PROFILE_POOL_MIN` and hard-fail the plane.
#[test]
fn pool_retains_headroom_above_the_underflow_floor() {
    let pool = production_profile_relays();
    assert!(
        pool.len() >= PROFILE_POOL_MIN + 5,
        "pool has {} relays; needs at least {} to tolerate several contaminations",
        pool.len(),
        PROFILE_POOL_MIN + 5,
    );
}

// ===========================================================================
// The two-relay proof: what the fetch path actually DIALS.
// ===========================================================================

/// Injected fetch clock — deterministic `fetched_at` stamping.
const NOW: i64 = 1_700_000_000;

/// Counts every `REQ` the relay is asked to admit, then admits it.
///
/// The count is taken relay-side at admission — before the filter is evaluated
/// and before any event is matched — so a request counts whether or not the
/// relay holds anything for it. That is what lets a zero mean *never asked*. A
/// test that instead inspected returned events could not tell "never asked"
/// from "asked and had nothing", and only the former is the invariant.
#[derive(Debug)]
struct CountingQueryPolicy {
    /// Requests admitted so far.
    seen: Arc<AtomicUsize>,
}

impl QueryPolicy for CountingQueryPolicy {
    fn admit_query<'a>(
        &'a self,
        _query: &'a Filter,
        _addr: &'a SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        self.seen.fetch_add(1, Ordering::SeqCst);
        Box::pin(async { PolicyResult::Accept })
    }
}

/// Starts an in-process relay that counts the `REQ`s it is asked to serve.
///
/// Returns the running relay — which the caller MUST keep alive for the whole
/// test — its normalized URL, and the counter.
async fn counting_relay() -> (LocalRelay, String, Arc<AtomicUsize>) {
    let seen = Arc::new(AtomicUsize::new(0));
    let relay = LocalRelay::new(RelayBuilder::default().query_policy(CountingQueryPolicy {
        seen: Arc::clone(&seen),
    }));
    relay.run().await.expect("local relay runs");
    // Normalize here so the URL the pool holds is byte-identical to the one the
    // exclusion filter and the assignment hash see. `ws://` loopback is
    // accepted only because `allow_ws_loopback_for_test` is armed by the caller.
    let url = normalize_relay_url(&relay.url().await.to_string())
        .expect("a ws:// loopback URL normalizes once the debug-only opt-in is armed");
    (relay, url, seen)
}

/// A stand-in for circle-plane traffic: an opaque kind-445 carrying an `h` tag.
///
/// Only its ROUTING matters here — publishing it is what registers the circle
/// relay in the shared client's pool — so the "ciphertext" is a literal and the
/// group id is a throwaway constant.
fn stand_in_circle_event() -> nostr::Event {
    EventBuilder::new(Kind::Custom(445), "opaque-ciphertext")
        .tags([Tag::custom(
            TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
            [hex::encode([0x42u8; 32])],
        )])
        .sign_with_keys(&Keys::generate())
        .expect("sign the stand-in circle-plane event")
}

/// End-to-end plane separation over two real relays: a profile fetch resolves
/// from the relay its author is assigned to, and the contaminated circle relay
/// serves ZERO profile requests.
///
/// The constant-level tests above prove the pool is *configured* disjointly.
/// They say nothing about the sockets: a fetch that ignored the pool would
/// leave every one of them green. This test closes that gap by counting, on the
/// relay side, what each relay was actually asked.
///
/// # Why the two relays share one `RelayManager`
///
/// The circle relay is deliberately registered in the shared client's pool
/// FIRST, by publishing a stand-in kind-445 to it, before the profile fetch
/// runs. That is the adversarial arrangement: if the fetch ever broadcast to
/// whatever relays the client happens to hold — rather than targeting the one
/// relay the author is assigned to — the circle relay's counter would move.
/// Zero therefore proves a *targeted* fetch, not merely that the circle relay
/// was unknown to the client.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn profile_plane_never_touches_circle_relays_e2e() {
    let _ = allow_ws_loopback_for_test();

    // Relay P carries the profile plane; relay C stands in for a circle /
    // location relay and is treated as contaminated throughout.
    let (_relay_p, profile_url, profile_reqs) = counting_relay().await;
    let (_relay_c, circle_url, circle_reqs) = counting_relay().await;

    // (d) The exclusion filter drops the contaminated relay. Two spare entries
    // keep the survivor count at `PROFILE_POOL_MIN` so the pool RESOLVES rather
    // than failing closed: the property under test here is the subtraction, and
    // the underflow floor is covered by
    // `exclusion_underflow_errors_and_never_falls_back_to_discovery`. The
    // spares are unresolvable `.invalid` hosts and are never dialed, because no
    // author in this test is assigned to one.
    let configured = vec![
        profile_url.clone(),
        circle_url.clone(),
        "wss://spare-a.profile-plane.invalid".to_string(),
        "wss://spare-b.profile-plane.invalid".to_string(),
    ];
    let pool = resolve_profile_pool(&configured, std::slice::from_ref(&circle_url))
        .expect("three uncontaminated relays survive the exclusion");
    assert!(
        !pool.contains(&circle_url),
        "the contaminated circle relay must be excluded from the profile pool",
    );
    assert!(
        pool.contains(&profile_url),
        "the uncontaminated profile relay must survive the exclusion",
    );

    // A FIXED salt, never `generate()`: assignment is a salted rendezvous hash,
    // so a random salt would make the author→relay mapping a per-run draw and
    // any failure irreproducible.
    let salt = ProfileRelaySalt::from_bytes([0xAA; 32]);

    // Choose an author whom the PRODUCTION assignment pins to the profile
    // relay, rather than asserting a mapping this test made up — the test and
    // the code under test cannot disagree about where the kind-0 must live.
    let author_keys = (0..10_000)
        .map(|_| Keys::generate())
        .find(|keys| {
            assigned_relay(&salt, &keys.public_key(), &pool).as_ref() == Some(&profile_url)
        })
        .expect("~1 key in 3 ranks the profile relay first in a 3-relay pool");
    let author = author_keys.public_key();

    // One manager for both planes; the circle relay joins its pool first (see
    // the doc comment above).
    let manager = RelayManager::new();
    manager
        .publish_event(&stand_in_circle_event(), std::slice::from_ref(&circle_url))
        .await
        .expect("the circle relay accepts its own plane's traffic");

    let metadata = ProfileMetadata::from_metadata(
        Metadata::from_json(r#"{"display_name":"Plane Separated"}"#).expect("valid json"),
    );
    let event = build_metadata_event(&author_keys, &metadata, None).expect("build kind-0");
    publish_metadata(&manager, &event, std::slice::from_ref(&profile_url))
        .await
        .expect("publish kind-0 to the profile relay");
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Both counters must still be zero: publishing sends `EVENT`, never `REQ`,
    // so everything counted from here on belongs to the fetch under test.
    assert_eq!(
        (
            profile_reqs.load(Ordering::SeqCst),
            circle_reqs.load(Ordering::SeqCst)
        ),
        (0, 0),
        "setup must issue no REQ, or the counters below would be contaminated",
    );

    let fetched = fetch_profiles_assigned(&manager, &[(author, 0)], &salt, &pool, NOW)
        .await
        .expect("assigned fetch");

    // (a) The author's kind-0 resolves — through its assigned relay, since that
    // is the only relay it can be requested from.
    assert!(
        fetched.unattempted.is_empty(),
        "the author must have been queried",
    );
    assert!(
        fetched.missed.is_empty(),
        "the profile relay holds the kind-0"
    );
    assert_eq!(fetched.resolved.len(), 1, "exactly one profile resolves");
    assert_eq!(fetched.resolved[0].pubkey_hex, author.to_hex());
    assert_eq!(
        fetched.resolved[0].metadata.display_name(),
        Some("Plane Separated"),
        "the resolved row is the kind-0 published to the profile relay",
    );

    // (c) NON-VACUITY, and it must be established BEFORE (b) is read: a fetch
    // that never reached a socket would satisfy (b) trivially while proving
    // nothing at all. The profile relay's counter moving is the evidence that a
    // real REQ crossed a real connection in this run.
    let profile_seen = profile_reqs.load(Ordering::SeqCst);
    assert!(
        profile_seen >= 1,
        "the profile relay served no REQ — no fetch actually happened, so the \
         zero-REQ assertion below would be vacuous",
    );

    // (b) THE INVARIANT: the circle relay was asked nothing, by anyone, ever.
    let circle_seen = circle_reqs.load(Ordering::SeqCst);
    assert_eq!(
        circle_seen, 0,
        "the circle relay served {circle_seen} profile REQ(s) (the profile relay served \
         {profile_seen}) — a relay that sees both a user's encrypted location traffic and \
         their kind-0 lookups can join the two into the social graph Haven never publishes",
    );
}
