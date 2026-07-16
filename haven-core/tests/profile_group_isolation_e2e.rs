//! Integration tests pinning the profile fetch/publish path's group-isolation
//! and no-AUTH privacy invariants over real in-process relays.
//!
//! * `profile_fetch_never_dials_the_circle_relay`: given ONLY a "discovery"
//!   relay, `fetch_profiles` resolves an author whose kind-0 lives there but
//!   NEVER resolves an author whose kind-0 lives only on a separate "circle"
//!   relay — proving the fetch never rode the circle relay set.
//! * `published_kind0_carries_no_group_identifier`: a built+published kind-0
//!   carries no `h` tag / group id.
//! * `fetch_never_answers_nip42_auth`: against an AUTH-required (NIP-42 Read)
//!   relay, the signer-less fetch resolves nothing — it cannot (and must not)
//!   authenticate, so it can never be attributed to the local user.

use std::time::Duration;

use haven_core::profile::{build_metadata_event, fetch_profiles, ProfileMetadata};
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use nostr::{JsonUtil, Keys, Metadata};
use nostr_relay_builder::builder::{RelayBuilder, RelayBuilderNip42, RelayBuilderNip42Mode};
use nostr_relay_builder::{LocalRelay, MockRelay};
use nostr_sdk::Client;

const NOW: i64 = 1_700_000_000;

fn metadata(json: &str) -> ProfileMetadata {
    ProfileMetadata::from_metadata(Metadata::from_json(json).expect("valid json"))
}

/// Publishes a kind-0 for `keys` to exactly `url` via a raw client.
async fn publish_to(url: &str, keys: &Keys, meta: &ProfileMetadata) {
    let event = build_metadata_event(keys, meta, None).expect("build kind-0");
    let client = Client::builder().build();
    client.add_relay(url).await.unwrap();
    client.connect().await;
    client.send_event(&event).await.expect("publish");
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

    // Fetch BOTH authors but target ONLY the discovery relay.
    let manager = RelayManager::new();
    let profiles = fetch_profiles(
        &manager,
        &[on_discovery.public_key(), on_circle.public_key()],
        std::slice::from_ref(&url_discovery),
        NOW,
    )
    .await
    .expect("fetch");

    assert!(
        profiles
            .iter()
            .any(|p| p.pubkey_hex == on_discovery.public_key().to_hex()),
        "the discovery-relay author resolves"
    );
    assert!(
        !profiles
            .iter()
            .any(|p| p.pubkey_hex == on_circle.public_key().to_hex()),
        "the circle-only author must NOT resolve — the fetch never dialed the circle relay"
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
    let profiles = fetch_profiles(
        &manager,
        &[author.public_key()],
        std::slice::from_ref(&url),
        NOW,
    )
    .await
    .expect("fetch returns (empty), never authenticates");
    assert!(
        profiles.is_empty(),
        "an AUTH-required read must resolve nothing — the fetch path never answers NIP-42 AUTH"
    );
}
