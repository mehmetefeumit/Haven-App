//! End-to-end MLS security tests (Category G of the security audit).
//!
//! These tests verify critical security properties of the MLS encryption layer:
//! - G2: Encryption/decryption roundtrip with real MLS crypto
//! - G3: Cross-group isolation (messages from one group cannot be decrypted in another)
//! - G4: Ephemeral pubkey uniqueness per message (privacy property)
//!
//! All tests use real MLS operations via `MdkManager::new_unencrypted()`.
//! No mocking is involved.

mod helpers;

use std::collections::HashSet;

use haven_core::location::LocationMessage;
use haven_core::nostr::mls::types::LocationGroupConfig;
use haven_core::nostr::mls::MdkManager;
use mdk_core::prelude::MessageProcessingResult;
use nostr::{EventBuilder, Keys, Kind};

use helpers::{cleanup_dir, create_key_package_event, setup_two_party_group, unique_temp_dir};

// ============================================================================
// G1: Test Harness Validation
// ============================================================================

#[test]
fn g1_test_harness_creates_valid_group() {
    let group = setup_two_party_group("g1_harness");

    // Both managers should see the group
    let alice_groups = group.alice_mdk.get_groups().expect("alice should get groups");
    assert_eq!(alice_groups.len(), 1, "Alice should have exactly one group");

    let bob_groups = group.bob_mdk.get_groups().expect("bob should get groups");
    assert_eq!(bob_groups.len(), 1, "Bob should have exactly one group");

    // Both should see two members
    let alice_members = group
        .alice_mdk
        .get_members(&group.group_id)
        .expect("alice should get members");
    assert_eq!(alice_members.len(), 2, "Group should have 2 members");

    // Both should see each other
    assert!(
        alice_members.contains(&group.alice_keys.public_key()),
        "Alice should be in the group"
    );
    assert!(
        alice_members.contains(&group.bob_keys.public_key()),
        "Bob should be in the group"
    );

    // Nostr group IDs should match
    assert_eq!(
        alice_groups[0].nostr_group_id,
        bob_groups[0].nostr_group_id,
        "Nostr group IDs should match between Alice and Bob"
    );

    group.cleanup();
}

#[test]
fn g1_key_package_event_is_valid_kind_443() {
    let dir = unique_temp_dir("g1_kp_kind");
    let mdk = MdkManager::new_unencrypted(&dir).expect("should create manager");
    let keys = Keys::generate();
    let relays = vec!["wss://relay.test.com".to_string()];

    let event = create_key_package_event(&mdk, &keys, &relays);

    assert_eq!(
        event.kind,
        Kind::MlsKeyPackage,
        "Key package event should be kind 443"
    );
    assert_eq!(
        event.pubkey,
        keys.public_key(),
        "Key package should be signed by the user's key"
    );
    assert!(
        !event.content.is_empty(),
        "Key package event content should not be empty"
    );

    cleanup_dir(&dir);
}

// ============================================================================
// G2: End-to-end Encryption/Decryption Roundtrip
// ============================================================================

#[test]
fn g2_location_encryption_roundtrip() {
    let group = setup_two_party_group("g2_roundtrip");

    // Alice creates a location message
    let location = LocationMessage::new(37.7749, -122.4194);
    let location_json = location.to_string().expect("should serialize location");

    // Alice creates an unsigned rumor (kind 9 inner event)
    let rumor = EventBuilder::new(Kind::Custom(9), &location_json)
        .build(group.alice_keys.public_key());

    // Alice encrypts the rumor for the group
    let encrypted_event = group
        .alice_mdk
        .create_message(&group.group_id, rumor)
        .expect("alice should encrypt message");

    // Verify outer event is kind 445 (MLS group message)
    assert_eq!(
        encrypted_event.kind,
        Kind::Custom(445),
        "Encrypted event should be kind 445"
    );

    // Verify the outer event content is NOT plaintext location data
    assert!(
        !encrypted_event.content.contains("37.7749"),
        "Encrypted event must NOT contain plaintext latitude"
    );
    assert!(
        !encrypted_event.content.contains("-122.4194"),
        "Encrypted event must NOT contain plaintext longitude"
    );
    assert!(
        !encrypted_event.content.contains("geohash"),
        "Encrypted event must NOT contain plaintext geohash field"
    );

    // Bob decrypts the message
    let decrypted = group
        .bob_mdk
        .process_message(&encrypted_event)
        .expect("bob should decrypt message");

    // Verify the decrypted message matches the original
    if let MessageProcessingResult::ApplicationMessage(msg) = decrypted {
        assert_eq!(
            msg.pubkey,
            group.alice_keys.public_key(),
            "Decrypted sender should be Alice"
        );
        assert_eq!(
            msg.content, location_json,
            "Decrypted content should match original location JSON"
        );

        // Verify we can parse the decrypted content back to a LocationMessage
        let recovered = LocationMessage::from_string(&msg.content)
            .expect("should deserialize decrypted location");
        assert_eq!(
            recovered.latitude, location.latitude,
            "Recovered latitude should match"
        );
        assert_eq!(
            recovered.longitude, location.longitude,
            "Recovered longitude should match"
        );
    } else {
        panic!(
            "Expected ApplicationMessage variant, got: {:?}",
            decrypted
        );
    }

    group.cleanup();
}

#[test]
fn g2_message_roundtrip_plain_text() {
    let group = setup_two_party_group("g2_plaintext");

    // Alice sends a simple text message
    let content = "Hello from Alice!";
    let rumor = EventBuilder::new(Kind::Custom(9), content)
        .build(group.alice_keys.public_key());

    let encrypted = group
        .alice_mdk
        .create_message(&group.group_id, rumor)
        .expect("should encrypt");

    // Plaintext should NOT appear in encrypted event
    assert!(
        !encrypted.content.contains(content),
        "Plaintext must not appear in encrypted event"
    );

    // Bob decrypts
    let result = group
        .bob_mdk
        .process_message(&encrypted)
        .expect("should decrypt");

    if let MessageProcessingResult::ApplicationMessage(msg) = result {
        assert_eq!(msg.content, content);
        assert_eq!(msg.pubkey, group.alice_keys.public_key());
    } else {
        panic!("Expected ApplicationMessage");
    }

    group.cleanup();
}

// ============================================================================
// G3: Cross-group Decryption Failure
// ============================================================================

#[test]
fn g3_cross_group_decryption_fails() {
    let relays = vec!["wss://relay.test.com".to_string()];

    // Set up Group A: Alice + Bob
    let group_a = setup_two_party_group("g3_group_a");

    // Set up Group B: Alice (new instance) + Carol
    let alice_b_dir = unique_temp_dir("g3_alice_b");
    let alice_b_mdk =
        MdkManager::new_unencrypted(&alice_b_dir).expect("should create alice_b manager");
    let alice_b_keys = Keys::generate();

    let carol_dir = unique_temp_dir("g3_carol");
    let carol_mdk =
        MdkManager::new_unencrypted(&carol_dir).expect("should create carol manager");
    let carol_keys = Keys::generate();

    let carol_kp = create_key_package_event(&carol_mdk, &carol_keys, &relays);

    let config_b = LocationGroupConfig::new("Group B")
        .with_relay("wss://relay.test.com")
        .with_admin(&alice_b_keys.public_key().to_hex());

    let group_b_result = alice_b_mdk
        .create_group(
            &alice_b_keys.public_key().to_hex(),
            vec![carol_kp],
            config_b,
        )
        .expect("should create group B");

    let group_b_id = group_b_result.group.mls_group_id.clone();
    alice_b_mdk
        .merge_pending_commit(&group_b_id)
        .expect("should merge group B commit");

    // Carol joins group B
    let carol_welcome_rumor = group_b_result
        .welcome_rumors
        .first()
        .expect("carol should have welcome");
    carol_mdk
        .process_welcome(&nostr::EventId::all_zeros(), carol_welcome_rumor)
        .expect("carol should process welcome");
    let carol_pending = carol_mdk
        .get_pending_welcomes()
        .expect("carol should get pending");
    carol_mdk
        .accept_welcome(carol_pending.first().unwrap())
        .expect("carol should accept welcome");

    // Alice encrypts a message for Group A
    let rumor = EventBuilder::new(Kind::Custom(9), "Secret for Group A only")
        .build(group_a.alice_keys.public_key());
    let encrypted_for_a = group_a
        .alice_mdk
        .create_message(&group_a.group_id, rumor)
        .expect("should encrypt for group A");

    // Carol (member of Group B only) should NOT be able to decrypt Group A's message
    let carol_result = carol_mdk.process_message(&encrypted_for_a);
    assert!(
        carol_result.is_err(),
        "Carol should NOT be able to decrypt a message from Group A"
    );

    // Clean up
    group_a.cleanup();
    cleanup_dir(&alice_b_dir);
    cleanup_dir(&carol_dir);
}

// ============================================================================
// G4: Unique Ephemeral Pubkeys Per Message
// ============================================================================

#[test]
fn g4_unique_ephemeral_pubkeys_per_message() {
    let group = setup_two_party_group("g4_ephemeral");

    let message_count = 10;
    let mut pubkeys = HashSet::new();

    for i in 0..message_count {
        let rumor = EventBuilder::new(Kind::Custom(9), format!("Message {i}"))
            .build(group.alice_keys.public_key());

        let encrypted = group
            .alice_mdk
            .create_message(&group.group_id, rumor)
            .expect("should encrypt message");

        // Collect the outer event's pubkey (should be ephemeral)
        pubkeys.insert(encrypted.pubkey);
    }

    // All outer event pubkeys should be unique
    assert_eq!(
        pubkeys.len(),
        message_count,
        "Each encrypted message must use a unique ephemeral pubkey. \
         Got {} unique out of {} messages.",
        pubkeys.len(),
        message_count
    );

    // None of the ephemeral pubkeys should be Alice's real pubkey
    assert!(
        !pubkeys.contains(&group.alice_keys.public_key()),
        "Ephemeral pubkeys must NOT match Alice's real identity pubkey"
    );

    group.cleanup();
}

#[test]
fn g4_ephemeral_pubkey_differs_from_sender() {
    let group = setup_two_party_group("g4_not_sender");

    let rumor = EventBuilder::new(Kind::Custom(9), "test")
        .build(group.alice_keys.public_key());

    let encrypted = group
        .alice_mdk
        .create_message(&group.group_id, rumor)
        .expect("should encrypt");

    // The outer event pubkey MUST differ from Alice's real identity
    assert_ne!(
        encrypted.pubkey,
        group.alice_keys.public_key(),
        "Kind 445 outer event must use an ephemeral pubkey, not the sender's real key"
    );

    group.cleanup();
}

// ============================================================================
// Additional Security Properties
// ============================================================================

#[test]
fn encrypted_event_has_h_tag_with_nostr_group_id() {
    let group = setup_two_party_group("h_tag");

    let rumor = EventBuilder::new(Kind::Custom(9), "test content")
        .build(group.alice_keys.public_key());

    let encrypted = group
        .alice_mdk
        .create_message(&group.group_id, rumor)
        .expect("should encrypt");

    // The encrypted event should have an h-tag containing the nostr_group_id
    let h_tag = encrypted
        .tags
        .iter()
        .find(|tag| tag.kind() == nostr::TagKind::h())
        .expect("Encrypted event must have an h-tag for relay routing");

    let h_content = h_tag.content().expect("h-tag must have content");
    assert!(
        !h_content.is_empty(),
        "h-tag content must not be empty"
    );

    // The h-tag should match the nostr_group_id from the group
    let alice_group = group
        .alice_mdk
        .get_groups()
        .expect("should get groups")
        .into_iter()
        .next()
        .expect("should have one group");

    let expected_h = hex::encode(alice_group.nostr_group_id);
    assert_eq!(
        h_content, expected_h,
        "h-tag must contain the hex-encoded nostr_group_id"
    );

    group.cleanup();
}

#[test]
fn bidirectional_messaging_works() {
    let group = setup_two_party_group("bidirectional");

    // Alice sends to Bob
    let alice_rumor = EventBuilder::new(Kind::Custom(9), "Hello Bob")
        .build(group.alice_keys.public_key());
    let alice_encrypted = group
        .alice_mdk
        .create_message(&group.group_id, alice_rumor)
        .expect("alice should encrypt");

    // Bob's group_id: find it from his groups
    let bob_group = group
        .bob_mdk
        .get_groups()
        .expect("should get bob groups")
        .into_iter()
        .next()
        .expect("bob should have one group");

    let bob_result = group
        .bob_mdk
        .process_message(&alice_encrypted)
        .expect("bob should decrypt alice's message");
    if let MessageProcessingResult::ApplicationMessage(msg) = bob_result {
        assert_eq!(msg.content, "Hello Bob");
        assert_eq!(msg.pubkey, group.alice_keys.public_key());
    } else {
        panic!("Expected ApplicationMessage from Alice");
    }

    // Bob sends to Alice
    let bob_rumor = EventBuilder::new(Kind::Custom(9), "Hello Alice")
        .build(group.bob_keys.public_key());
    let bob_encrypted = group
        .bob_mdk
        .create_message(&bob_group.mls_group_id, bob_rumor)
        .expect("bob should encrypt");

    let alice_result = group
        .alice_mdk
        .process_message(&bob_encrypted)
        .expect("alice should decrypt bob's message");
    if let MessageProcessingResult::ApplicationMessage(msg) = alice_result {
        assert_eq!(msg.content, "Hello Alice");
        assert_eq!(msg.pubkey, group.bob_keys.public_key());
    } else {
        panic!("Expected ApplicationMessage from Bob");
    }

    group.cleanup();
}
