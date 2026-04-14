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
use nostr::{EventBuilder, Keys, Kind, TagStandard, Timestamp};

use helpers::{cleanup_dir, create_key_package_event, setup_two_party_group, unique_temp_dir};

// ============================================================================
// G1: Test Harness Validation
// ============================================================================

#[test]
fn g1_test_harness_creates_valid_group() {
    let group = setup_two_party_group("g1_harness");

    // Both managers should see the group
    let alice_groups = group
        .alice_mdk
        .get_groups()
        .expect("alice should get groups");
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
        alice_groups[0].nostr_group_id, bob_groups[0].nostr_group_id,
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
    let rumor =
        EventBuilder::new(Kind::Custom(9), &location_json).build(group.alice_keys.public_key());

    // Alice encrypts the rumor for the group
    let encrypted_event = group
        .alice_mdk
        .create_message(&group.group_id, rumor, None)
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
        panic!("Expected ApplicationMessage variant, got a different result type");
    }

    group.cleanup();
}

#[test]
fn g2_message_roundtrip_plain_text() {
    let group = setup_two_party_group("g2_plaintext");

    // Alice sends a simple text message
    let content = "Hello from Alice!";
    let rumor = EventBuilder::new(Kind::Custom(9), content).build(group.alice_keys.public_key());

    let encrypted = group
        .alice_mdk
        .create_message(&group.group_id, rumor, None)
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

#[test]
fn outer_kind_445_carries_expiration_tag_when_requested() {
    let group = setup_two_party_group("g2_expiration");

    let rumor = EventBuilder::new(Kind::Custom(9), "ping").build(group.alice_keys.public_key());

    // Explicit expiration: +450 seconds from now.
    let exp = Timestamp::from(Timestamp::now().as_secs() + 450);

    let encrypted = group
        .alice_mdk
        .create_message(&group.group_id, rumor, Some(exp))
        .expect("should encrypt with expiration");

    let tagged: Vec<u64> = encrypted
        .tags
        .iter()
        .filter_map(|t| match t.as_standardized() {
            Some(TagStandard::Expiration(ts)) => Some(ts.as_secs()),
            _ => None,
        })
        .collect();

    assert_eq!(
        tagged.len(),
        1,
        "outer kind:445 must carry exactly one expiration tag when caller requests it"
    );
    assert_eq!(
        tagged[0],
        exp.as_secs(),
        "expiration tag value must match the caller-supplied timestamp"
    );

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
    let carol_mdk = MdkManager::new_unencrypted(&carol_dir).expect("should create carol manager");
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
        .create_message(&group_a.group_id, rumor, None)
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
            .create_message(&group.group_id, rumor, None)
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

    let rumor = EventBuilder::new(Kind::Custom(9), "test").build(group.alice_keys.public_key());

    let encrypted = group
        .alice_mdk
        .create_message(&group.group_id, rumor, None)
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

    let rumor =
        EventBuilder::new(Kind::Custom(9), "test content").build(group.alice_keys.public_key());

    let encrypted = group
        .alice_mdk
        .create_message(&group.group_id, rumor, None)
        .expect("should encrypt");

    // The encrypted event should have an h-tag containing the nostr_group_id
    let h_tag = encrypted
        .tags
        .iter()
        .find(|tag| tag.kind() == nostr::TagKind::h())
        .expect("Encrypted event must have an h-tag for relay routing");

    let h_content = h_tag.content().expect("h-tag must have content");
    assert!(!h_content.is_empty(), "h-tag content must not be empty");

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

    // P3-C (MIP-00 Rule 4): h-tag MUST carry the nostr_group_id (a 32-byte
    // privacy-preserving identifier), not the real MLS group ID. Leaking the
    // latter would let relays correlate kind:445 traffic with internal MLS
    // state and undermine the unlinkability property of the protocol.
    let mls_group_id_hex = hex::encode(group.group_id.as_slice());
    assert_ne!(
        h_content, mls_group_id_hex,
        "h-tag must contain nostr_group_id, NOT the real MLS group ID"
    );

    // Multi-message consistency: the h-tag MUST be the same nostr_group_id
    // for every kind:445 event Alice publishes. If this ever diverges, the
    // nostr_group_id is being re-derived per message (a regression).
    for i in 0..3 {
        let rumor_i = EventBuilder::new(Kind::Custom(9), format!("h-tag check {i}"))
            .build(group.alice_keys.public_key());
        let enc_i = group
            .alice_mdk
            .create_message(&group.group_id, rumor_i, None)
            .expect("should encrypt");
        let h_i = enc_i
            .tags
            .iter()
            .find(|tag| tag.kind() == nostr::TagKind::h())
            .and_then(|tag| tag.content())
            .expect("every kind:445 event must have an h-tag");
        assert_eq!(
            h_i, expected_h,
            "h-tag must be stable across messages (message {i})"
        );
    }

    // Bob (joiner) must see the same nostr_group_id as Alice (creator).
    // Catches divergence in creator vs joiner derivation.
    let bob_groups = group.bob_mdk.get_groups().expect("bob should get groups");
    let bob_group = bob_groups.first().expect("bob should have one group");
    assert_eq!(
        hex::encode(bob_group.nostr_group_id),
        h_content,
        "Bob's view of nostr_group_id must match the h-tag Alice publishes"
    );

    group.cleanup();
}

#[test]
fn bidirectional_messaging_works() {
    let group = setup_two_party_group("bidirectional");

    // Alice sends to Bob
    let alice_rumor =
        EventBuilder::new(Kind::Custom(9), "Hello Bob").build(group.alice_keys.public_key());
    let alice_encrypted = group
        .alice_mdk
        .create_message(&group.group_id, alice_rumor, None)
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
    let bob_rumor =
        EventBuilder::new(Kind::Custom(9), "Hello Alice").build(group.bob_keys.public_key());
    let bob_encrypted = group
        .bob_mdk
        .create_message(&bob_group.mls_group_id, bob_rumor, None)
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

// ============================================================================
// P3-A: Key Separation (MIP-00 Rule 1)
// ============================================================================
//
// MIP-00 Rule 1: MLS signing keys MUST differ from Nostr identity keys.
// The MLS credential *carries* the Nostr identity (in `credential_identity`),
// but the signature key used to authenticate MLS handshake messages MUST be
// an independent keypair. If these collide, a Nostr key compromise would
// let an attacker impersonate MLS handshake messages (and vice-versa), which
// MIP-00 explicitly forbids.

#[test]
fn p3a_mls_signing_keys_differ_from_nostr_identity_keys() {
    let group = setup_two_party_group("p3a_keysep");

    // Structural check: pull the ratchet tree and inspect every leaf's
    // signature key. None may equal either member's Nostr pubkey.
    // (The behavioural "outer kind:445 pubkey is ephemeral" invariant is
    // covered by g4_unique_ephemeral_pubkeys_per_message — no need to
    // duplicate it here.)
    let tree_info = group
        .alice_mdk
        .get_ratchet_tree_info(&group.group_id)
        .expect("alice should fetch ratchet tree info");

    assert_eq!(
        tree_info.leaf_nodes.len(),
        2,
        "ratchet tree should contain exactly two leaves"
    );

    let alice_nostr_hex = group.alice_keys.public_key().to_hex();
    let bob_nostr_hex = group.bob_keys.public_key().to_hex();

    let mut signature_keys: HashSet<String> = HashSet::new();
    let mut credential_identities: HashSet<String> = HashSet::new();

    for leaf in &tree_info.leaf_nodes {
        // credential_identity should be the Nostr pubkey; signature_key must not be.
        assert!(
            leaf.credential_identity == alice_nostr_hex
                || leaf.credential_identity == bob_nostr_hex,
            "leaf credential_identity should match a known Nostr pubkey"
        );

        assert_ne!(
            leaf.signature_key, alice_nostr_hex,
            "MLS signature_key for leaf {} must NOT equal Alice's Nostr identity key",
            leaf.index
        );
        assert_ne!(
            leaf.signature_key, bob_nostr_hex,
            "MLS signature_key for leaf {} must NOT equal Bob's Nostr identity key",
            leaf.index
        );

        // Defensive: compare case-insensitively in case MDK ever returns uppercase hex.
        assert_ne!(
            leaf.signature_key.to_lowercase(),
            alice_nostr_hex.to_lowercase(),
            "MLS signature_key (case-normalized) for leaf {} must NOT equal Alice's Nostr key",
            leaf.index
        );
        assert_ne!(
            leaf.signature_key.to_lowercase(),
            bob_nostr_hex.to_lowercase(),
            "MLS signature_key (case-normalized) for leaf {} must NOT equal Bob's Nostr key",
            leaf.index
        );

        // Sanity: the signature key is a well-formed 32-byte lowercase hex string.
        assert_eq!(
            leaf.signature_key.len(),
            64,
            "leaf.signature_key must be 64 hex chars (32 bytes), got {}",
            leaf.signature_key.len()
        );
        assert!(
            leaf.signature_key
                .chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
            "leaf.signature_key must be lowercase hex, got {:?}",
            leaf.signature_key
        );

        signature_keys.insert(leaf.signature_key.clone());
        credential_identities.insert(leaf.credential_identity.clone());
    }

    // Cross-member: every leaf must have a distinct MLS signing key.
    assert_eq!(
        signature_keys.len(),
        tree_info.leaf_nodes.len(),
        "every leaf must have a unique MLS signature_key"
    );

    // Credential identities must be exactly {Alice's Nostr key, Bob's Nostr key}.
    let expected_identities: HashSet<String> = HashSet::from([alice_nostr_hex, bob_nostr_hex]);
    assert_eq!(
        credential_identities, expected_identities,
        "leaf credential_identities must exactly match the set of member Nostr pubkeys"
    );

    group.cleanup();
}

// ============================================================================
// P3-B: Exporter Secret Lifecycle (MIP-03 Rule 5)
// ============================================================================
//
// MIP-03 Rule 5: old-epoch exporter secrets must be pruned once they fall
// outside the retention window. Haven inherits MDK's default
// `max_past_epochs = 5`, which is more lenient than MIP-03's literal
// "~2 epochs" wording — this is an intentional deviation that follows
// MDK's design (retaining up to 5 prior epochs allows decrypting slightly
// stale kind:445 traffic after a commit is merged). A long-lived cache of
// exporter secrets would defeat forward secrecy for kind:445 messages: an
// attacker who later compromises the device could decrypt historical
// traffic up to the oldest retained epoch.
//
// Strategy:
//   1. After `setup_two_party_group`, Alice is at epoch 1 (create + add-Bob
//      commit). Her epoch 1 exporter secret is saved by merge_pending_commit.
//   2. Advance one epoch to prove MDK actually stores historical secrets and
//      that the accessor is sensitive to epoch number.
//   3. Advance epochs via self_update + merge_pending_commit until the
//      current epoch exceeds `max_past_epochs + start_epoch`. With
//      max_past_epochs=5 and start epoch=1, reaching epoch 7 makes
//      `min_epoch_to_keep = 7 - 5 = 2`, which prunes epoch 1.
//   4. Assert epoch 1's secret returns None while the current epoch still
//      has one (sanity check for the accessor itself).

#[test]
fn p3b_old_exporter_secrets_are_pruned() {
    let group = setup_two_party_group("p3b_exporter");

    // After setup, Alice is at epoch 1 (add-Bob commit merged). Sanity-check
    // the starting state and capture the starting epoch's secret.
    let alice_group_v0 = group
        .alice_mdk
        .get_groups()
        .expect("should get alice's groups")
        .into_iter()
        .next()
        .expect("alice should have one group");
    let start_epoch = alice_group_v0.epoch;

    let start_secret_present = group
        .alice_mdk
        .get_stored_exporter_secret(&group.group_id, start_epoch)
        .expect("query for start-epoch secret should not error");
    assert!(
        start_secret_present,
        "starting-epoch exporter secret must be present after group setup \
         (epoch {start_epoch})"
    );

    // Intermediate probe: advance one epoch and verify the starting epoch's
    // secret is STILL retained (proves MDK stores historical secrets and
    // that the accessor is sensitive to epoch number — without this, the
    // later "pruned == false" assertion could pass falsely if MDK simply
    // never stored the secret in the first place).
    group
        .alice_mdk
        .self_update(&group.group_id)
        .expect("self_update should succeed");
    group
        .alice_mdk
        .merge_pending_commit(&group.group_id)
        .expect("merge_pending_commit should succeed");

    let start_secret_still_present = group
        .alice_mdk
        .get_stored_exporter_secret(&group.group_id, start_epoch)
        .expect("query for start-epoch secret should not error");
    assert!(
        start_secret_still_present,
        "start-epoch ({start_epoch}) secret must still be present at epoch \
         {start_epoch}+1 (inside the max_past_epochs=5 window)"
    );

    // Advance enough epochs that the starting epoch falls outside the
    // retention window. Default max_past_epochs = 5, so we advance to
    // start_epoch + 6 to guarantee pruning. Iteration cap ensures we fail
    // loudly if self_update ever stops advancing epochs.
    let target_epoch = start_epoch + 6;
    let mut current_epoch = start_epoch;
    for _ in 0..20 {
        current_epoch = group
            .alice_mdk
            .get_groups()
            .expect("should get alice's groups")
            .into_iter()
            .next()
            .expect("alice should have one group")
            .epoch;
        if current_epoch >= target_epoch {
            break;
        }
        group
            .alice_mdk
            .self_update(&group.group_id)
            .expect("self_update should succeed");
        group
            .alice_mdk
            .merge_pending_commit(&group.group_id)
            .expect("merge_pending_commit should succeed");
    }
    assert!(
        current_epoch >= target_epoch,
        "epoch did not advance within safety cap (current={current_epoch}, \
         target={target_epoch})"
    );

    let alice_group_final = group
        .alice_mdk
        .get_groups()
        .expect("should get alice's groups")
        .into_iter()
        .next()
        .expect("alice should have one group");
    assert!(
        alice_group_final.epoch >= target_epoch,
        "alice should have advanced to at least epoch {target_epoch}, got {}",
        alice_group_final.epoch
    );

    // The starting epoch's exporter secret must be pruned.
    let pruned = group
        .alice_mdk
        .get_stored_exporter_secret(&group.group_id, start_epoch)
        .expect("query for pruned secret should not error");
    assert!(
        !pruned,
        "starting-epoch ({start_epoch}) exporter secret MUST be pruned once \
         current epoch ({}) exceeds the retention window (max_past_epochs=5)",
        alice_group_final.epoch
    );

    // Sanity: the current epoch's secret must still be retrievable.
    let current_secret_present = group
        .alice_mdk
        .get_stored_exporter_secret(&group.group_id, alice_group_final.epoch)
        .expect("query for current-epoch secret should not error");
    assert!(
        current_secret_present,
        "current-epoch ({}) exporter secret must still be stored",
        alice_group_final.epoch
    );

    group.cleanup();
}
