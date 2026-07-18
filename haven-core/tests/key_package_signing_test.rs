//! Integration tests for the key package signing flow.
//!
//! These tests verify that the `create_key_package_event` helper (which mirrors
//! the DM-2b `KeyPackage` publish path) produces valid, well-formed kind-30443
//! Nostr events with correct signatures, decodable content, and expected tags.
//!
//! # Dark Matter port (DM-5a)
//!
//! The KeyPackage kind is now **30443** (addressable, W1), not the legacy 443,
//! and `create_key_package_event` is async over `SessionManager`. The kind-10051
//! relay-list builder is retained (its retirement + retraction is the DM-4 FFI
//! flip), so those tests are unchanged.

mod helpers;

use base64::Engine;
use haven_core::circle::{RelayType, KEY_PACKAGE_KIND};
use haven_core::nostr::mls::SessionManager;
use haven_core::relay::build_relay_list_event;
use nostr::{Keys, Kind};

use helpers::{cleanup_dir, create_key_package_event, unique_temp_dir};

// ============================================================================
// Key Package Signing Tests (kind 30443)
// ============================================================================

#[tokio::test]
async fn sign_key_package_produces_valid_kind_30443() {
    let dir = unique_temp_dir("kp_valid_30443");
    let keys = Keys::generate();
    let session = SessionManager::new_unencrypted(&dir, &keys).expect("should create session");
    let relays = vec!["wss://relay.example.com".to_string()];

    let event = create_key_package_event(&session, &keys, &relays).await;

    // Event kind must be 30443 (addressable MLS Key Package, W1).
    assert_eq!(
        event.kind.as_u16(),
        KEY_PACKAGE_KIND,
        "Key package event must be kind 30443"
    );

    // Event author must match the signing key
    assert_eq!(
        event.pubkey,
        keys.public_key(),
        "Event author must match the signing key's public key"
    );

    // Cryptographic signature must be valid
    event
        .verify()
        .expect("Event signature must be valid and verifiable");

    cleanup_dir(&dir);
}

#[tokio::test]
async fn sign_key_package_content_is_valid_encoding() {
    let dir = unique_temp_dir("kp_content_encoding");
    let keys = Keys::generate();
    let session = SessionManager::new_unencrypted(&dir, &keys).expect("should create session");
    let relays = vec!["wss://relay.example.com".to_string()];

    let event = create_key_package_event(&session, &keys, &relays).await;

    // Content must not be empty
    assert!(
        !event.content.is_empty(),
        "Key package event content must not be empty"
    );

    // Content is base64-encoded serialized MLS key package bytes.
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(&event.content)
        .or_else(|_| hex::decode(&event.content))
        .expect("Key package content must be valid base64 or hex");

    // Decoded bytes must be non-empty (an MLS key package has real structure)
    assert!(
        !bytes.is_empty(),
        "Decoded key package bytes must not be empty"
    );

    cleanup_dir(&dir);
}

#[tokio::test]
async fn sign_key_package_has_expected_tags() {
    let dir = unique_temp_dir("kp_tags");
    let keys = Keys::generate();
    let session = SessionManager::new_unencrypted(&dir, &keys).expect("should create session");
    let relays = vec!["wss://relay.example.com".to_string()];

    let event = create_key_package_event(&session, &keys, &relays).await;

    // Event must have at least one tag
    assert!(
        !event.tags.is_empty(),
        "Key package event must have at least one tag"
    );

    // Must contain an mls_protocol_version tag (required by the Marmot protocol)
    let has_protocol_version = event.tags.iter().any(|tag| {
        let parts = tag.as_slice();
        parts.first().is_some_and(|k| k == "mls_protocol_version")
    });

    assert!(
        has_protocol_version,
        "Key package event must contain an mls_protocol_version tag"
    );

    // The mls_protocol_version tag must have a non-empty value
    let version_value = event
        .tags
        .iter()
        .find_map(|tag| {
            let parts = tag.as_slice();
            if parts.first().is_some_and(|k| k == "mls_protocol_version") {
                parts.get(1).cloned()
            } else {
                None
            }
        })
        .expect("mls_protocol_version tag must have a value");

    assert!(
        !version_value.is_empty(),
        "mls_protocol_version value must not be empty"
    );

    cleanup_dir(&dir);
}

/// Verify that a signed kind-30443 event does not carry the NIP-70 protected
/// tag (`["-"]`).
///
/// The DM-2b builder never emits a `Tag::protected()`, so the invariant that a
/// published KeyPackage carries no NIP-70 protected tag (which most production
/// relays reject) holds by construction. This test proves it end-to-end.
#[tokio::test]
async fn sign_key_package_event_has_no_nip70_protected_tag() {
    let dir = unique_temp_dir("kp_no_protected_tag");
    let keys = Keys::generate();
    let session = SessionManager::new_unencrypted(&dir, &keys).expect("should create session");
    let relays = vec!["wss://relay.example.com".to_string()];

    let event = create_key_package_event(&session, &keys, &relays).await;

    // The NIP-70 protected tag is ["-"]. No tag in a kind 30443 event should
    // have "-" as its sole identifier, because most production relays reject
    // protected events outright.
    let has_protected_tag = event.tags.iter().any(|tag| {
        let parts = tag.as_slice();
        // Protected tag serialises as exactly one element: "-"
        parts.first().is_some_and(|k| k == "-")
    });

    assert!(
        !has_protected_tag,
        "Kind 30443 key package event must not contain the NIP-70 protected tag [\"-\"]; \
         most production relays (e.g. relay.damus.io, nos.lol) reject events with this tag"
    );

    cleanup_dir(&dir);
}

// ============================================================================
// Relay List Event (Kind 10051) Tests
// ============================================================================

#[test]
fn build_relay_list_event_produces_valid_kind_10051() {
    let keys = Keys::generate();
    let relays = vec![
        "wss://relay.damus.io".to_string(),
        "wss://nos.lol".to_string(),
    ];

    let event = build_relay_list_event(&keys, RelayType::KeyPackage, &relays, None)
        .expect("build relay list event");

    // Event kind must be 10051 (MLS Key Package Relays)
    assert_eq!(
        event.kind,
        Kind::MlsKeyPackageRelays,
        "Relay list event must be kind 10051"
    );

    // Event author must match the signing key
    assert_eq!(
        event.pubkey,
        keys.public_key(),
        "Event author must match the signing key's public key"
    );

    // Content must be empty per MIP-00
    assert!(
        event.content.is_empty(),
        "Relay list event content must be empty"
    );

    // Cryptographic signature must be valid
    event
        .verify()
        .expect("Event signature must be valid and verifiable");
}

#[test]
fn build_relay_list_event_has_relay_tags() {
    let keys = Keys::generate();
    let relays = vec![
        "wss://relay.damus.io".to_string(),
        "wss://nos.lol".to_string(),
        "wss://relay.nostr.band".to_string(),
    ];

    let event = build_relay_list_event(&keys, RelayType::KeyPackage, &relays, None)
        .expect("build relay list event");

    // Must have exactly 3 tags (one per relay)
    assert_eq!(
        event.tags.len(),
        3,
        "Relay list event must have one tag per relay"
    );

    // Each tag must be ["relay", url]
    for (i, tag) in event.tags.iter().enumerate() {
        let parts = tag.as_slice();
        assert_eq!(
            parts.first().map(String::as_str),
            Some("relay"),
            "Tag {i} must have 'relay' as first element"
        );
        assert_eq!(
            parts.get(1).map(String::as_str),
            Some(relays[i].as_str()),
            "Tag {i} must contain the relay URL"
        );
    }
}

#[test]
fn build_relay_list_event_empty_relays() {
    let keys = Keys::generate();
    let relays: Vec<String> = vec![];

    let event = build_relay_list_event(&keys, RelayType::KeyPackage, &relays, None)
        .expect("build relay list event");

    // Kind must still be 10051
    assert_eq!(event.kind, Kind::MlsKeyPackageRelays);

    // No tags when no relays provided
    assert!(
        event.tags.is_empty(),
        "Relay list event with no relays must have no tags"
    );

    // Signature must still be valid
    event.verify().expect("Event signature must be valid");
}
