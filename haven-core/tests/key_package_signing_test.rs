//! Integration tests for the key package signing flow.
//!
//! These tests verify that the `create_key_package_event` helper (which mirrors
//! the `sign_key_package_event` FFI method) produces valid, well-formed kind 443
//! Nostr events with correct signatures, decodable content, and expected tags.

mod helpers;

use base64::Engine;
use haven_core::nostr::mls::MdkManager;
use nostr::{Keys, Kind};

use helpers::{cleanup_dir, create_key_package_event, unique_temp_dir};

// ============================================================================
// Key Package Signing Tests
// ============================================================================

#[test]
fn sign_key_package_produces_valid_kind_443() {
    let dir = unique_temp_dir("kp_valid_443");
    let manager = MdkManager::new_unencrypted(&dir).expect("should create manager");
    let keys = Keys::generate();
    let relays = vec!["wss://relay.example.com".to_string()];

    let event = create_key_package_event(&manager, &keys, &relays);

    // Event kind must be 443 (MLS Key Package)
    assert_eq!(
        event.kind,
        Kind::MlsKeyPackage,
        "Key package event must be kind 443"
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

#[test]
fn sign_key_package_content_is_valid_encoding() {
    let dir = unique_temp_dir("kp_content_encoding");
    let manager = MdkManager::new_unencrypted(&dir).expect("should create manager");
    let keys = Keys::generate();
    let relays = vec!["wss://relay.example.com".to_string()];

    let event = create_key_package_event(&manager, &keys, &relays);

    // Content must not be empty
    assert!(
        !event.content.is_empty(),
        "Key package event content must not be empty"
    );

    // Content from MDK is base64-encoded serialized MLS key package bytes.
    // Try base64 first (standard encoding), fall back to hex.
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

#[test]
fn sign_key_package_has_expected_tags() {
    let dir = unique_temp_dir("kp_tags");
    let manager = MdkManager::new_unencrypted(&dir).expect("should create manager");
    let keys = Keys::generate();
    let relays = vec!["wss://relay.example.com".to_string()];

    let event = create_key_package_event(&manager, &keys, &relays);

    // Event must have at least one tag
    assert!(
        !event.tags.is_empty(),
        "Key package event must have at least one tag"
    );

    // Must contain an mls_protocol_version tag (required by the Marmot protocol)
    let has_protocol_version = event.tags.iter().any(|tag| {
        let parts = tag.as_slice();
        parts
            .first()
            .is_some_and(|k| k == "mls_protocol_version")
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
            if parts
                .first()
                .is_some_and(|k| k == "mls_protocol_version")
            {
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
