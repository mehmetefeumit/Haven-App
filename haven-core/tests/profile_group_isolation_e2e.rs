//! Integration tests pinning the profile fetch/publish path's group-isolation
//! and no-AUTH privacy invariants over real in-process relays.
//!
//! * `profile_fetch_never_dials_the_circle_relay`: given a pool holding ONLY a
//!   "discovery" relay, `fetch_profiles_assigned` resolves an author whose
//!   kind-0 lives there but NEVER resolves an author whose kind-0 lives only on
//!   a separate "circle" relay — proving the fetch never rode the circle relay
//!   set. (A two-relay proof that COUNTS the circle relay's `REQ`s, rather than
//!   inferring from what failed to resolve, lives in
//!   `profile_plane_separation.rs::profile_plane_never_touches_circle_relays_e2e`.)
//! * `published_kind0_carries_no_group_identifier`: a built+published kind-0
//!   carries no `h` tag / group id.
//! * `fetch_never_answers_nip42_auth`: against an AUTH-required (NIP-42 Read)
//!   relay, the signer-less fetch resolves nothing — it cannot (and must not)
//!   authenticate, so it can never be attributed to the local user.

use std::time::Duration;

use haven_core::profile::{
    build_metadata_event, fetch_profiles_assigned, AssignedFetch, ProfileMetadata, ProfileRelaySalt,
};
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use nostr::{JsonUtil, Keys, Metadata, PublicKey};
use nostr_relay_builder::builder::{RelayBuilder, RelayBuilderNip42, RelayBuilderNip42Mode};
use nostr_relay_builder::{LocalRelay, MockRelay};
use nostr_sdk::Client;

const NOW: i64 = 1_700_000_000;

fn metadata(json: &str) -> ProfileMetadata {
    ProfileMetadata::from_metadata(Metadata::from_json(json).expect("valid json"))
}

/// A FIXED assignment salt — never [`ProfileRelaySalt::generate`], so which
/// relay an author is asked of is reproducible across runs.
const fn salt() -> ProfileRelaySalt {
    ProfileRelaySalt::from_bytes([0xAA; 32])
}

/// Publishes a kind-0 for `keys` to exactly `url` via a raw client.
async fn publish_to(url: &str, keys: &Keys, meta: &ProfileMetadata) {
    let event = build_metadata_event(keys, meta, None).expect("build kind-0");
    let client = Client::builder().build();
    client.add_relay(url).await.unwrap();
    client.connect().await;
    client.send_event(&event).await.expect("publish");
}

/// Requests every author in `authors` at attempt 0 from a one-relay pool.
///
/// A one-relay pool pins the rendezvous ranking: every author is assigned to
/// `url` and to nothing else, which is exactly the condition these tests need.
async fn fetch_from(relay: &RelayManager, authors: &[PublicKey], url: &str) -> AssignedFetch {
    let requests: Vec<(PublicKey, u8)> = authors.iter().map(|author| (*author, 0)).collect();
    fetch_profiles_assigned(relay, &requests, &salt(), &[url.to_string()], NOW)
        .await
        .expect("fetch")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn profile_fetch_never_dials_the_circle_relay() {
    let _ = allow_ws_loopback_for_test();
    let discovery = MockRelay::run().await.expect("discovery relay");
    let circle = MockRelay::run().await.expect("circle relay");
    let url_discovery = discovery.url().await.to_string();
    let url_circle = circle.url().await.to_string();

    let on_discovery = Keys::generate();
    let on_circle = Keys::generate();

    // One author's kind-0 lives on the discovery relay; a different author's
    // lives ONLY on the circle relay.
    publish_to(
        &url_discovery,
        &on_discovery,
        &metadata(r#"{"display_name":"Discoverable"}"#),
    )
    .await;
    publish_to(
        &url_circle,
        &on_circle,
        &metadata(r#"{"display_name":"CircleOnly"}"#),
    )
    .await;
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Fetch BOTH authors from a pool containing ONLY the discovery relay, so
    // both are assigned to it and the circle relay is never a target.
    let manager = RelayManager::new();
    let fetched = fetch_from(
        &manager,
        &[on_discovery.public_key(), on_circle.public_key()],
        &url_discovery,
    )
    .await;

    assert!(
        fetched
            .resolved
            .iter()
            .any(|p| p.pubkey_hex == on_discovery.public_key().to_hex()),
        "the discovery-relay author resolves"
    );
    assert!(
        !fetched
            .resolved
            .iter()
            .any(|p| p.pubkey_hex == on_circle.public_key().to_hex()),
        "the circle-only author must NOT resolve — the fetch never dialed the circle relay"
    );
    // The circle-only author is a MISS, not an unattempted author: it WAS
    // requested, from the discovery relay, which does not hold its kind-0.
    // Asserting the bucket (rather than mere absence from `resolved`) is what
    // rules out the vacuous pass where no request was issued at all.
    assert_eq!(
        fetched.missed,
        vec![on_circle.public_key()],
        "the circle-only author was asked for — from the discovery relay — and missed",
    );
    assert!(
        fetched.unattempted.is_empty(),
        "both authors were queried; an unattempted author would void the assertions above",
    );
}

#[test]
fn published_kind0_carries_no_group_identifier() {
    let keys = Keys::generate();
    let event = build_metadata_event(&keys, &metadata(r#"{"display_name":"Alice"}"#), None)
        .expect("build kind-0");
    assert!(
        event.tags.is_empty(),
        "a Haven kind-0 carries no tags (no `h`/group id): {:?}",
        event.tags
    );
    let json = event.as_json().to_lowercase();
    assert!(!json.contains("\"h\""), "no #h tag: {json}");
    assert!(!json.contains("group"), "no group identifier: {json}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn fetch_never_answers_nip42_auth() {
    let _ = allow_ws_loopback_for_test();

    // A relay that requires NIP-42 AUTH to READ (writes stay open).
    let relay = LocalRelay::new(RelayBuilder::default().nip42(RelayBuilderNip42 {
        mode: RelayBuilderNip42Mode::Read,
    }));
    relay.run().await.expect("auth relay runs");
    let url = relay.url().await.to_string();

    let author = Keys::generate();
    // Publish is a write — permitted without AUTH under Read mode.
    publish_to(&url, &author, &metadata(r#"{"display_name":"Secret"}"#)).await;
    tokio::time::sleep(Duration::from_millis(300)).await;

    // The RelayManager is built with NO signer, so it cannot satisfy the AUTH
    // challenge. The read therefore yields nothing (the relay refuses to serve
    // an unauthenticated REQ) — the fetch is never attributable to a signer.
    let manager = RelayManager::new();
    let fetched = fetch_from(&manager, &[author.public_key()], &url).await;
    assert!(
        fetched.resolved.is_empty(),
        "an AUTH-required read must resolve nothing — the fetch path never answers NIP-42 AUTH"
    );
    // The `REQ` was issued and the relay answered it (with an auth-required
    // refusal the SDK absorbs into an empty result), so the author is a MISS.
    // Without this the test would pass just as happily on a dead socket and
    // would prove nothing about AUTH.
    assert_eq!(
        fetched.missed,
        vec![author.public_key()],
        "the refusal must land as a miss — proof the REQ reached the relay",
    );
    assert!(fetched.unattempted.is_empty());
}
