//! Integration tests for the public-profile fetch/publish network layer over a
//! real in-process Nostr relay (`nostr-relay-builder`).
//!
//! Proves the full kind-0 round trip: `build_metadata_event` →
//! `publish_metadata` over a real socket → `fetch_profiles_assigned` reads it
//! back → `parse_newest_metadata` resolves the winner. Also pins newest-wins
//! convergence, the fetch→merge→publish edit preserving another client's
//! field, and that an event failing signature/id verification never surfaces
//! as a cached profile.
//!
//! # Reading the outcome buckets
//!
//! `fetch_profiles_assigned` partitions every requested author into exactly one
//! of `resolved` / `missed` / `unattempted`. The tests below assert on the
//! partition, not just on `resolved`, because that is what makes them
//! non-vacuous: a run whose `REQ` never left the process would leave the author
//! `unattempted`, so `resolved.is_empty()` alone would "pass" a dead socket.
//! `unattempted.is_empty()` is the standing proof that the request really was
//! issued and answered.

use std::time::Duration;

use haven_core::profile::{
    build_metadata_event, fetch_profiles_assigned, merge_edits, publish_metadata, AssignedFetch,
    ProfileEdits, ProfileMetadata, ProfileRelaySalt, ProfileState,
};
use haven_core::relay::{allow_ws_loopback_for_test, RelayManager};
use nostr::{Event, EventBuilder, JsonUtil, Keys, Kind, Metadata, PublicKey, Timestamp};
use nostr_relay_builder::MockRelay;
use nostr_sdk::Client;

const NOW: i64 = 1_700_000_000;

fn metadata(json: &str) -> ProfileMetadata {
    ProfileMetadata::from_metadata(Metadata::from_json(json).expect("valid json"))
}

/// A FIXED assignment salt — never [`ProfileRelaySalt::generate`].
///
/// Assignment is a salted rendezvous hash, so a random salt would make which
/// relay an author is asked of a per-run draw and a failure irreproducible.
fn salt() -> ProfileRelaySalt {
    ProfileRelaySalt::from_bytes([0xAA; 32])
}

/// Builds + publishes a kind-0 for `keys` to `url` via the production
/// `publish_metadata` path.
async fn publish_profile(relay: &RelayManager, keys: &Keys, meta: &ProfileMetadata, url: &str) {
    let event = build_metadata_event(keys, meta, None).expect("build kind-0");
    publish_metadata(relay, &event, &[url.to_string()])
        .await
        .expect("publish kind-0");
}

/// Requests every author in `authors` at attempt 0 from a one-relay pool.
///
/// A single-relay pool pins the rendezvous ranking: every author's assigned
/// relay is `url`, so these round-trip tests read exactly as they did under the
/// old broadcast fetch while still driving the production assignment code.
async fn fetch_from(relay: &RelayManager, authors: &[PublicKey], url: &str) -> AssignedFetch {
    let requests: Vec<(PublicKey, u8)> = authors.iter().map(|author| (*author, 0)).collect();
    fetch_profiles_assigned(relay, &requests, &salt(), &[url.to_string()], NOW)
        .await
        .expect("fetch")
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

    let fetched = fetch_from(&manager, &[keys.public_key()], &url).await;
    assert!(
        fetched.unattempted.is_empty(),
        "the author must have been queried — an unattempted author would make the \
         assertions below vacuous",
    );
    assert!(fetched.missed.is_empty(), "the relay holds the kind-0");
    assert_eq!(
        fetched.resolved.len(),
        1,
        "the published profile is resolved"
    );
    let profile = &fetched.resolved[0];
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

    let fetched = fetch_from(&manager, &[keys.public_key()], &url).await;
    assert!(fetched.unattempted.is_empty(), "the author was queried");
    assert_eq!(fetched.resolved.len(), 1);
    assert_eq!(
        fetched.resolved[0].metadata.display_name(),
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
    let fetched = fetch_from(&manager, &[client_a.public_key()], &url).await;
    assert!(fetched.unattempted.is_empty(), "the author was queried");
    assert_eq!(fetched.resolved.len(), 1);
    let merged = merge_edits(
        &fetched.resolved[0].metadata,
        &ProfileEdits {
            display_name: Some("Alice B".to_string()),
            ..ProfileEdits::default()
        },
    );
    // Later created_at so the edit supersedes.
    tokio::time::sleep(Duration::from_millis(1_100)).await;
    publish_profile(&manager, &client_a, &merged, &url).await;
    tokio::time::sleep(Duration::from_millis(300)).await;

    let after = fetch_from(&manager, &[client_a.public_key()], &url).await;
    assert!(after.unattempted.is_empty(), "the author was queried");
    assert_eq!(after.resolved.len(), 1);
    let md = after.resolved[0].metadata.as_metadata();
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

    let fetched = fetch_from(&manager, &[alice.public_key(), mallory.public_key()], &url).await;

    assert!(
        fetched.unattempted.is_empty(),
        "both authors must have been queried, or the rejection below proves nothing",
    );
    assert!(
        fetched
            .resolved
            .iter()
            .any(|p| p.pubkey_hex == alice.public_key().to_hex()),
        "the valid profile resolves"
    );
    assert!(
        !fetched
            .resolved
            .iter()
            .any(|p| p.pubkey_hex == mallory.public_key().to_hex()),
        "the forged-signature profile must never resolve"
    );
    // Mallory was asked for and answered with nothing usable — a MISS, not a
    // skipped author. That distinction is the whole non-vacuity argument: the
    // forged event was rejected on its merits, not by an unsent request.
    assert_eq!(
        fetched.missed,
        vec![mallory.public_key()],
        "the forged author is a miss (asked, nothing valid came back)",
    );
}
