//! Integration tests for the public-profile fetch/publish network layer over a
//! real in-process Nostr relay (`nostr-relay-builder`).
//!
//! Proves the full kind-0 round trip: `build_metadata_event` →
//! `publish_metadata` over a real socket → `fetch_profiles` reads it back →
//! `parse_newest_metadata` resolves the winner. Also pins newest-wins
//! convergence, the fetch→merge→publish edit preserving another client's
//! field, and that an event failing signature/id verification never surfaces
//! as a cached profile.

use std::time::Duration;

use haven_core::profile::{
    build_metadata_event, fetch_profiles, merge_edits, publish_metadata, ProfileEdits,
    ProfileMetadata, ProfileState,
};
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use nostr::{Event, EventBuilder, JsonUtil, Keys, Kind, Metadata, Timestamp};
use nostr_relay_builder::MockRelay;
use nostr_sdk::Client;

const NOW: i64 = 1_700_000_000;

fn metadata(json: &str) -> ProfileMetadata {
    ProfileMetadata::from_metadata(Metadata::from_json(json).expect("valid json"))
}

/// Builds + publishes a kind-0 for `keys` to `url` via the production
/// `publish_metadata` path.
async fn publish_profile(relay: &RelayManager, keys: &Keys, meta: &ProfileMetadata, url: &str) {
    let event = build_metadata_event(keys, meta, None).expect("build kind-0");
    publish_metadata(relay, &event, &[url.to_string()])
        .await
        .expect("publish kind-0");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn publish_fetch_parse_round_trip() {
    let _ = allow_ws_loopback_for_test();
    let relay_srv = MockRelay::run().await.expect("mock relay");
    let url = relay_srv.url().await.to_string();
    let manager = RelayManager::new();
    let keys = Keys::generate();

    publish_profile(
        &manager,
        &keys,
        &metadata(r#"{"display_name":"Alice","about":"hi"}"#),
        &url,
    )
    .await;
    tokio::time::sleep(Duration::from_millis(300)).await;

    let profiles = fetch_profiles(
        &manager,
        &[keys.public_key()],
        std::slice::from_ref(&url),
        NOW,
    )
    .await
    .expect("fetch");
    assert_eq!(profiles.len(), 1, "the published profile is resolved");
    let profile = &profiles[0];
    assert_eq!(profile.pubkey_hex, keys.public_key().to_hex());
    assert_eq!(profile.state, ProfileState::Known);
    assert_eq!(profile.fetched_at, NOW);
    assert_eq!(profile.metadata.display_name(), Some("Alice"));
    assert_eq!(profile.metadata.about(), Some("hi"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_publishes_newest_wins() {
    let _ = allow_ws_loopback_for_test();
    let relay_srv = MockRelay::run().await.expect("mock relay");
    let url = relay_srv.url().await.to_string();
    let manager = RelayManager::new();
    let keys = Keys::generate();

    publish_profile(
        &manager,
        &keys,
        &metadata(r#"{"display_name":"Old"}"#),
        &url,
    )
    .await;
    // Ensure a strictly later created_at (replaceable supersession).
    tokio::time::sleep(Duration::from_millis(1_100)).await;
    publish_profile(
        &manager,
        &keys,
        &metadata(r#"{"display_name":"New"}"#),
        &url,
    )
    .await;
    tokio::time::sleep(Duration::from_millis(300)).await;

    let profiles = fetch_profiles(
        &manager,
        &[keys.public_key()],
        std::slice::from_ref(&url),
        NOW,
    )
    .await
    .expect("fetch");
    assert_eq!(profiles.len(), 1);
    assert_eq!(
        profiles[0].metadata.display_name(),
        Some("New"),
        "the newest kind-0 wins"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn edit_preserves_field_written_by_another_client() {
    let _ = allow_ws_loopback_for_test();
    let relay_srv = MockRelay::run().await.expect("mock relay");
    let url = relay_srv.url().await.to_string();
    let manager = RelayManager::new();

    // Two distinct `Keys` instances backed by the SAME secret — two clients of
    // one identity. "Client B" (another Nostr app) publishes a profile that
    // includes a lightning address Haven does not model in its editor.
    let client_a = Keys::generate();
    let client_b = Keys::new(client_a.secret_key().clone());
    publish_profile(
        &manager,
        &client_b,
        &metadata(r#"{"display_name":"Alice","lud16":"alice@wallet","bot":true}"#),
        &url,
    )
    .await;
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Haven (client A) fetches the freshest, merges a display-name edit, and
    // republishes the WHOLE object.
    let fetched = fetch_profiles(
        &manager,
        &[client_a.public_key()],
        std::slice::from_ref(&url),
        NOW,
    )
    .await
    .expect("fetch");
    assert_eq!(fetched.len(), 1);
    let merged = merge_edits(
        &fetched[0].metadata,
        &ProfileEdits {
            display_name: Some("Alice B".to_string()),
            ..ProfileEdits::default()
        },
    );
    // Later created_at so the edit supersedes.
    tokio::time::sleep(Duration::from_millis(1_100)).await;
    publish_profile(&manager, &client_a, &merged, &url).await;
    tokio::time::sleep(Duration::from_millis(300)).await;

    let after = fetch_profiles(
        &manager,
        &[client_a.public_key()],
        std::slice::from_ref(&url),
        NOW,
    )
    .await
    .expect("fetch");
    assert_eq!(after.len(), 1);
    let md = after[0].metadata.as_metadata();
    assert_eq!(md.display_name.as_deref(), Some("Alice B"), "edit applied");
    assert_eq!(
        md.lud16.as_deref(),
        Some("alice@wallet"),
        "another client's lud16 survives the edit"
    );
    assert_eq!(
        md.custom.get("bot").and_then(serde_json::Value::as_bool),
        Some(true),
        "unknown custom field survives the edit"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn forged_signature_kind0_rejected() {
    let _ = allow_ws_loopback_for_test();
    let relay_srv = MockRelay::run().await.expect("mock relay");
    let url = relay_srv.url().await.to_string();
    let manager = RelayManager::new();

    let alice = Keys::generate();
    let mallory = Keys::generate();

    // Alice publishes a normal, valid profile.
    publish_profile(
        &manager,
        &alice,
        &metadata(r#"{"display_name":"Alice"}"#),
        &url,
    )
    .await;

    // Mallory builds a valid kind-0, then tampers the content so the event id
    // no longer commits to it — signature/id verification must fail.
    let valid: Event = EventBuilder::new(Kind::Metadata, r#"{"display_name":"Real"}"#)
        .custom_created_at(Timestamp::from(u64::try_from(NOW).unwrap()))
        .sign_with_keys(&mallory)
        .expect("sign");
    let mut forged = valid.clone();
    forged.content = r#"{"display_name":"Tampered"}"#.to_string();
    assert!(
        forged.verify().is_err(),
        "a tampered kind-0 must fail verification"
    );

    // Attempt to inject the forged event via a raw client. Either the client
    // refuses to transmit it or the relay rejects it; either way it must never
    // become a resolvable profile.
    let publisher = Client::builder().build();
    publisher.add_relay(&url).await.unwrap();
    publisher.connect().await;
    let _ = publisher.send_event(&forged).await;
    tokio::time::sleep(Duration::from_millis(400)).await;

    let profiles = fetch_profiles(
        &manager,
        &[alice.public_key(), mallory.public_key()],
        std::slice::from_ref(&url),
        NOW,
    )
    .await
    .expect("fetch");

    assert!(
        profiles
            .iter()
            .any(|p| p.pubkey_hex == alice.public_key().to_hex()),
        "the valid profile resolves"
    );
    assert!(
        !profiles
            .iter()
            .any(|p| p.pubkey_hex == mallory.public_key().to_hex()),
        "the forged-signature profile must never resolve"
    );
}
