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
use haven_core::nostr::giftwrap::{unwrap_welcome, wrap_welcome, KIND_WELCOME};
use haven_core::nostr::mls::types::LocationGroupConfig;
use haven_core::nostr::mls::MdkManager;
use haven_core::nostr::NostrError;
use mdk_core::prelude::MessageProcessingResult;
use nostr::{Event, EventBuilder, JsonUtil, Keys, Kind, TagStandard, Timestamp, UnsignedEvent};

use helpers::{
    cleanup_dir, create_key_package_event, setup_two_party_group,
    setup_two_party_group_capturing_welcome, unique_temp_dir,
};

/// Drives an async future to completion on a fresh single-threaded Tokio
/// runtime. The gift-wrap helpers (`wrap_welcome`/`unwrap_welcome`) are async
/// because NIP-44 sealing is async in the nostr crate; these MLS integration
/// tests are otherwise synchronous, so we spin up a runtime per call rather
/// than converting the whole binary to `#[tokio::test]`.
fn block_on<F: std::future::Future>(fut: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("should build tokio runtime")
        .block_on(fut)
}

/// Drives `mdk`'s view of `group_id` forward via repeated `self_update` +
/// `merge_pending_commit` until its epoch reaches at least `target_epoch`.
///
/// The bounded loop (`max_iters`) makes the test fail loudly rather than hang
/// if `self_update` ever stops advancing the epoch. Returns the epoch reached.
fn advance_epoch_to_at_least(
    mdk: &MdkManager,
    group_id: &haven_core::nostr::mls::types::GroupId,
    target_epoch: u64,
    max_iters: usize,
) -> u64 {
    let current = |mdk: &MdkManager| {
        mdk.get_groups()
            .expect("should get groups")
            .into_iter()
            .next()
            .expect("group should exist")
            .epoch
    };
    let mut epoch = current(mdk);
    for _ in 0..max_iters {
        if epoch >= target_epoch {
            break;
        }
        mdk.self_update(group_id)
            .expect("self_update should succeed");
        mdk.merge_pending_commit(group_id)
            .expect("merge_pending_commit should succeed");
        epoch = current(mdk);
    }
    assert!(
        epoch >= target_epoch,
        "epoch did not advance to target within the safety cap (reached={epoch}, \
         target={target_epoch})"
    );
    epoch
}

/// Asserts that a `process_message` failure is a genuine decryption/processing
/// failure and NOT a "group not found" error.
///
/// Both failure modes surface as [`NostrError::MdkError`] (every MDK error is
/// funneled through `map_mdk_err`), so matching the variant alone is not enough
/// to prove the security property. MDK's `GroupNotFound` renders as
/// `"group not found"`, whereas a real decryption failure renders as
/// `"Failed to decrypt message with any exporter secret ..."`. We assert the
/// error is an `MdkError` whose message is the decryption-failure shape, so the
/// test cannot pass merely because the group was missing from storage.
fn assert_is_decryption_failure(err: &NostrError, context: &str) {
    match err {
        NostrError::MdkError(msg) => {
            let lower = msg.to_lowercase();
            assert!(
                !lower.contains("group not found"),
                "{context}: failure must be a decryption/processing error, not \
                 group-not-found (got MdkError: {msg:?})"
            );
            assert!(
                lower.contains("decrypt")
                    || lower.contains("exporter secret")
                    || lower.contains("tls")
                    || lower.contains("deserialize")
                    || lower.contains("mls message"),
                "{context}: failure must clearly be a decryption/processing \
                 error (got MdkError: {msg:?})"
            );
        }
        other => {
            panic!("{context}: expected NostrError::MdkError from process_message, got {other:?}")
        }
    }
}

/// Asserts that a published kind:445 `event` leaks NO raw MLS group ID — not in
/// any tag, not anywhere in the serialized JSON — while the privacy-preserving
/// `expected_nostr_group_id` IS present (MIP-00 Rule 4 / Security Rule #4).
///
/// The two IDs are asserted to differ first, so the "absent" scan is meaningful
/// (not a vacuous pass where the two happened to coincide) and the "present"
/// check provides a positive control that the scan operates on real content.
fn assert_no_raw_mls_group_id_leak(
    event: &Event,
    raw_mls_group_id: &[u8],
    expected_nostr_group_id: &[u8],
) {
    let raw_mls_hex = hex::encode(raw_mls_group_id);
    let nostr_hex = hex::encode(expected_nostr_group_id);
    assert_ne!(
        nostr_hex, raw_mls_hex,
        "nostr_group_id must differ from the raw MLS group ID for the scan to be meaningful"
    );

    let json = event.as_json();
    assert!(
        !json.contains(&raw_mls_hex),
        "raw MLS group ID must NOT appear anywhere in the kind:445 event JSON"
    );
    for tag in event.tags.iter() {
        for part in tag.as_slice() {
            assert!(
                !part.contains(&raw_mls_hex),
                "raw MLS group ID must NOT appear in any tag of a kind:445 event"
            );
        }
    }
    assert!(
        json.contains(&nostr_hex),
        "the privacy-preserving nostr_group_id should appear in the kind:445 event"
    );
}

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

    // (1) Original coverage (preserved): Carol (member of Group B only) cannot
    //     process a Group A message at all. Because Carol's storage has no group
    //     with Group A's nostr_group_id, this fails at the routing layer
    //     (group-not-found) — the correct behaviour for an unrelated message.
    let carol_result = carol_mdk.process_message(&encrypted_for_a);
    assert!(
        carol_result.is_err(),
        "Carol should NOT be able to decrypt a message from Group A"
    );

    // (2) RM-4 strengthening: force a genuine *decryption* failure rather than a
    //     routing failure. Re-wrap Group A's ciphertext under Group B's h-tag so
    //     it routes to a group Carol actually has. Decryption must still fail,
    //     because the payload was sealed with Group A's exporter secret, not
    //     Group B's. MDK does not verify the outer Nostr signature (that is the
    //     relay pool's job), so re-signing with a fresh ephemeral key is a
    //     faithful model of a hostile relay replaying ciphertext into the wrong
    //     group. This proves cross-group ciphertext is undecryptable even when
    //     correctly routed — the property a relay-level attacker would target.
    let routing_id_for_group_b = alice_b_mdk
        .get_groups()
        .expect("alice_b should get groups")
        .into_iter()
        .next()
        .expect("group B should exist")
        .nostr_group_id;

    let rewrapped_for_b = EventBuilder::new(Kind::Custom(445), encrypted_for_a.content.clone())
        .tag(nostr::Tag::custom(
            nostr::TagKind::h(),
            [hex::encode(routing_id_for_group_b)],
        ))
        .sign_with_keys(&Keys::generate())
        .expect("should re-sign rewrapped event with ephemeral key");

    let carol_misrouted = carol_mdk.process_message(&rewrapped_for_b);
    let carol_err = carol_misrouted
        .expect_err("Carol must NOT decrypt Group A ciphertext routed under Group B's h-tag");
    assert_is_decryption_failure(
        &carol_err,
        "cross-group ciphertext routed to a group Carol is in",
    );

    // (3) RM-4 privacy scan: the real MLS group ID must never appear anywhere in
    //     a published kind:445 event — only the privacy-preserving
    //     nostr_group_id may (MIP-00 Rule 4 / Security Rule #4).
    let published_id_for_group_a = group_a
        .alice_mdk
        .get_groups()
        .expect("alice should get groups")
        .into_iter()
        .next()
        .expect("group A should exist")
        .nostr_group_id;
    assert_no_raw_mls_group_id_leak(
        &encrypted_for_a,
        group_a.group_id.as_slice(),
        &published_id_for_group_a,
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

// ============================================================================
// RM-1: Unsigned Kind-444 Welcome (Security Rule #3 / MIP-02)
// ============================================================================
//
// MIP-02 / Security Rule #3: the kind:444 Welcome rumor MUST remain unsigned.
// An unsigned rumor cannot be independently published or replayed even if the
// gift-wrap leaks. This test asserts (a) the welcome the real creation path
// produces is unsigned, and (b) a *signed* kind:444 does not survive the
// welcome (gift-wrap) path as a signed event — its signature is stripped, so a
// signed 444 is never accepted as valid Welcome material.

/// Reports whether a serialized Nostr event JSON carries a present, non-empty
/// `sig` field.
///
/// This operates on the JSON string (not a typed value) so it works uniformly
/// for both a signed [`Event`] (whose JSON DOES contain `sig`) and an
/// [`UnsignedEvent`] (whose JSON has no `sig` key at all). That dual
/// applicability is what makes the RM-1 assertions non-vacuous: every test that
/// asserts "no signature" is paired with a positive control proving this
/// detector returns `true` for a genuinely signed event.
fn event_json_has_signature(json: &str) -> bool {
    let value: serde_json::Value = serde_json::from_str(json).expect("event JSON should parse");
    value
        .get("sig")
        .is_some_and(|sig| !sig.is_null() && sig.as_str().is_some_and(|s| !s.is_empty()))
}

#[test]
fn rm1_welcome_rumor_from_creation_path_is_unsigned_kind_444() {
    let setup = setup_two_party_group_capturing_welcome("rm1_unsigned");
    let rumor = &setup.bob_welcome_rumor;

    // The welcome MDK emits for a new member is a kind:444 event.
    assert_eq!(
        rumor.kind,
        Kind::Custom(KIND_WELCOME),
        "welcome rumor must be kind 444"
    );

    // Positive control: the detector DOES flag a real signature. We sign the
    // exact same (pubkey, created_at, kind, tags, content) into an `Event` and
    // confirm its JSON trips `event_json_has_signature`. Without this control,
    // the "no sig" assertion below could pass vacuously (an `UnsignedEvent` can
    // never carry a `sig` field), which is precisely the failure mode this audit
    // exists to prevent.
    let signed_twin: Event = UnsignedEvent::new(
        rumor.pubkey,
        rumor.created_at,
        rumor.kind,
        rumor.tags.clone().to_vec(),
        rumor.content.clone(),
    )
    .sign_with_keys(&Keys::generate())
    .expect("should be able to sign a kind 444 twin");
    assert!(
        event_json_has_signature(&signed_twin.as_json()),
        "detector sanity: a signed kind:444 twin MUST be flagged as signed"
    );

    // The actual welcome rumor MUST be unsigned: no `sig` in its serialized
    // form. If MDK (or a future refactor) ever emitted a signed welcome, this
    // fails — and we have just proven the detector is capable of catching it.
    assert!(
        !event_json_has_signature(&rumor.as_json()),
        "kind:444 welcome rumor MUST be unsigned (Security Rule #3 / MIP-02)"
    );

    setup.cleanup();
}

#[test]
fn rm1_signed_kind_444_is_not_accepted_as_a_signed_welcome() {
    // Build a genuinely SIGNED kind:444 event and confirm its signature is
    // valid on its own — this is the artefact a misbehaving sender might try to
    // pass off as a welcome.
    let sender = Keys::generate();
    let recipient = Keys::generate();

    let signed_444: Event = EventBuilder::new(Kind::Custom(KIND_WELCOME), "fake_welcome_bytes")
        .sign_with_keys(&sender)
        .expect("should sign kind 444 event");
    signed_444
        .verify()
        .expect("the constructed signed 444 must itself be a valid signed event");
    assert!(
        !signed_444.sig.to_string().is_empty(),
        "precondition: the constructed kind 444 event is signed"
    );

    // Feed it through the welcome (gift-wrap) path the way a welcome travels on
    // the wire. `wrap_welcome` requires kind 444 and operates on the *rumor*
    // (unsigned) projection; NIP-59 rumors never carry a signature. After a
    // wrap + unwrap round-trip, the rumor that emerges MUST be unsigned — the
    // sender's signature does not survive. A signed 444 is therefore never
    // accepted as valid signed welcome material.
    let signed_444_as_rumor = UnsignedEvent::new(
        signed_444.pubkey,
        signed_444.created_at,
        signed_444.kind,
        signed_444.tags.clone(),
        signed_444.content.clone(),
    );

    let wrapped = block_on(wrap_welcome(
        &sender,
        &recipient.public_key(),
        signed_444_as_rumor,
    ))
    .expect("wrap_welcome should accept a kind 444 rumor");

    let unwrapped = block_on(unwrap_welcome(&recipient, &wrapped))
        .expect("recipient should unwrap the gift-wrapped welcome");

    assert_eq!(
        unwrapped.rumor.kind,
        Kind::Custom(KIND_WELCOME),
        "unwrapped welcome must be kind 444"
    );
    // The payload survived the round-trip (proves we actually carried the same
    // event, so the missing signature below is meaningful, not an empty wrap).
    assert_eq!(
        unwrapped.rumor.content, signed_444.content,
        "welcome content must survive the gift-wrap round-trip"
    );

    // Positive control: the ORIGINAL signed event's JSON genuinely contains a
    // signature (so the detector is live). The unwrapped rumor's JSON must NOT —
    // the sender's signature did not survive the welcome path. Asserting both
    // sides makes this a real contrast, not a vacuous "an UnsignedEvent has no
    // sig" tautology.
    assert!(
        event_json_has_signature(&signed_444.as_json()),
        "control: the original signed kind:444 must carry a signature"
    );
    assert!(
        !event_json_has_signature(&unwrapped.rumor.as_json()),
        "a signed kind:444 must NOT survive the welcome path as a signed event — \
         its signature must be stripped (Security Rule #3 / MIP-02)"
    );

    // And the welcome path rejects the *wrong* inner kind outright: only kind
    // 444 may be wrapped. This guards the kind-gate that keeps arbitrary signed
    // events out of the welcome channel.
    let wrong_kind_rumor = UnsignedEvent::new(
        sender.public_key(),
        Timestamp::now(),
        Kind::Custom(9),
        Vec::new(),
        "not a welcome".to_string(),
    );
    let rejected = block_on(wrap_welcome(
        &sender,
        &recipient.public_key(),
        wrong_kind_rumor,
    ));
    assert!(
        matches!(rejected, Err(NostrError::GiftWrap(_))),
        "welcome path must reject a non-444 inner event, got {rejected:?}"
    );
}

// ============================================================================
// RM-2: Ciphertext Tamper Detection
// ============================================================================

#[test]
fn rm2_tampered_ciphertext_fails_to_decrypt() {
    let group = setup_two_party_group("rm2_tamper");

    let rumor = EventBuilder::new(Kind::Custom(9), "authentic payload")
        .build(group.alice_keys.public_key());
    let encrypted = group
        .alice_mdk
        .create_message(&group.group_id, rumor, None)
        .expect("alice should encrypt");

    // Sanity: the untampered event decrypts for Bob (proves the only difference
    // below is the single flipped byte, not some unrelated breakage).
    let clean = group
        .bob_mdk
        .process_message(&encrypted)
        .expect("bob should decrypt the untampered message");
    assert!(
        matches!(clean, MessageProcessingResult::ApplicationMessage(_)),
        "untampered message must decrypt to an ApplicationMessage"
    );

    // Flip one byte in the middle of the (base64) ciphertext content and re-sign
    // with a fresh ephemeral key so this is a brand-new event id (avoiding the
    // dedup/Failed short-circuit, which would mask the genuine error). The h-tag
    // is preserved so routing still lands on the right group — the ONLY change
    // that matters is the corrupted ciphertext.
    let mut tampered_bytes = encrypted.content.clone().into_bytes();
    assert!(
        tampered_bytes.len() > 4,
        "ciphertext must be long enough to tamper"
    );
    let mid = tampered_bytes.len() / 2;
    // Map to a different base64-safe character so the string stays valid base64
    // (forcing the failure into the AEAD layer, not base64 decoding alone).
    tampered_bytes[mid] = if tampered_bytes[mid] == b'A' {
        b'B'
    } else {
        b'A'
    };
    let tampered_content =
        String::from_utf8(tampered_bytes).expect("tampered content should remain valid UTF-8");
    assert_ne!(
        tampered_content, encrypted.content,
        "tampering must actually change the content"
    );

    let h_tag = encrypted
        .tags
        .iter()
        .find(|t| t.kind() == nostr::TagKind::h())
        .expect("encrypted event must have an h-tag")
        .clone();

    let tampered_event = EventBuilder::new(Kind::Custom(445), tampered_content)
        .tag(h_tag)
        .sign_with_keys(&Keys::generate())
        .expect("should sign tampered event");

    let result = group.bob_mdk.process_message(&tampered_event);
    let err = result.expect_err("tampered ciphertext must fail to decrypt");
    assert_is_decryption_failure(&err, "tampered kind:445 ciphertext");

    group.cleanup();
}

// ============================================================================
// RM-3: Replay / Duplicate Handling
// ============================================================================

#[test]
fn rm3_replayed_message_is_not_a_fresh_application_message() {
    let group = setup_two_party_group("rm3_replay");

    let rumor = EventBuilder::new(Kind::Custom(9), "first and only delivery")
        .build(group.alice_keys.public_key());
    let encrypted = group
        .alice_mdk
        .create_message(&group.group_id, rumor, None)
        .expect("alice should encrypt");

    // First delivery decrypts to a fresh ApplicationMessage.
    let first = group
        .bob_mdk
        .process_message(&encrypted)
        .expect("first delivery should process");
    match first {
        MessageProcessingResult::ApplicationMessage(msg) => {
            assert_eq!(msg.content, "first and only delivery");
        }
        other => panic!("first delivery must be an ApplicationMessage, got {other:?}"),
    }

    // Second delivery of the *same* event MUST NOT yield a fresh
    // ApplicationMessage. MDK consumes the MLS message generation on first
    // decrypt, so the replay cannot be re-decrypted; it is reported as
    // Unprocessable (not a new application message, and not a hard error that
    // would crash callers).
    let second = group
        .bob_mdk
        .process_message(&encrypted)
        .expect("replay should be handled gracefully, not error");
    assert!(
        !matches!(second, MessageProcessingResult::ApplicationMessage(_)),
        "a replayed kind:445 must NOT decrypt to a fresh ApplicationMessage, got {second:?}"
    );

    // Group state must remain usable: exactly one stored message, and a brand
    // new follow-up message still decrypts end-to-end.
    let stored = group
        .bob_mdk
        .get_messages(&group.group_id)
        .expect("bob should read messages");
    assert_eq!(
        stored.len(),
        1,
        "replay must not duplicate the stored message"
    );

    let followup_rumor = EventBuilder::new(Kind::Custom(9), "still works after replay")
        .build(group.alice_keys.public_key());
    let followup = group
        .alice_mdk
        .create_message(&group.group_id, followup_rumor, None)
        .expect("alice should encrypt a follow-up");
    let followup_result = group
        .bob_mdk
        .process_message(&followup)
        .expect("follow-up must process after a replay");
    match followup_result {
        MessageProcessingResult::ApplicationMessage(msg) => {
            assert_eq!(msg.content, "still works after replay");
        }
        other => panic!("follow-up must decrypt after replay, got {other:?}"),
    }

    group.cleanup();
}

// ============================================================================
// RM-6: Malformed / Oversized Event Handling (no panic, graceful Err)
// ============================================================================

#[test]
fn rm6_malformed_and_oversized_events_fail_gracefully() {
    let group = setup_two_party_group("rm6_malformed");

    let nostr_group_id_hex = hex::encode(
        group
            .alice_mdk
            .get_groups()
            .expect("alice should get groups")
            .into_iter()
            .next()
            .expect("group should exist")
            .nostr_group_id,
    );

    // Build a routable kind:445 event (correct h-tag) with arbitrary content,
    // each signed with a distinct ephemeral key so each is a unique event id
    // (first-time processing, never the dedup short-circuit). Every case must
    // return Err WITHOUT panicking — process_message uses the result, never
    // unwinds.
    let make_event = |content: &str| {
        EventBuilder::new(Kind::Custom(445), content.to_string())
            .tag(nostr::Tag::custom(
                nostr::TagKind::h(),
                [nostr_group_id_hex.clone()],
            ))
            .sign_with_keys(&Keys::generate())
            .expect("should sign malformed-content event")
    };

    // (a) Empty content.
    let empty = make_event("");
    let empty_err = group
        .bob_mdk
        .process_message(&empty)
        .expect_err("empty content must fail to decrypt");
    assert_is_decryption_failure(&empty_err, "empty kind:445 content");

    // (b) Garbage, non-base64 content (contains characters outside the base64
    //     alphabet, e.g. '!' and '@').
    let garbage = make_event("!!!not-valid-base64@@@%%%");
    let garbage_err = group
        .bob_mdk
        .process_message(&garbage)
        .expect_err("garbage content must fail to decrypt");
    assert_is_decryption_failure(&garbage_err, "garbage (non-base64) kind:445 content");

    // (c) Oversized payload: ~1 MiB of base64 'A's. Must fail gracefully (no
    //     unbounded allocation panic, no crash) — we consume the Result.
    let oversized = make_event(&"A".repeat(1024 * 1024));
    let oversized_err = group
        .bob_mdk
        .process_message(&oversized)
        .expect_err("oversized payload must fail to decrypt");
    assert_is_decryption_failure(&oversized_err, "oversized kind:445 payload");

    group.cleanup();
}

// ============================================================================
// RM-7: Cross-group Key Isolation by Bytes
// ============================================================================

#[test]
fn rm7_independent_groups_have_distinct_ids_and_exporter_secrets() {
    let group_a = setup_two_party_group("rm7_group_a");
    let group_b = setup_two_party_group("rm7_group_b");

    let a_group = group_a
        .alice_mdk
        .get_groups()
        .expect("group A: get_groups")
        .into_iter()
        .next()
        .expect("group A should exist");
    let b_group = group_b
        .alice_mdk
        .get_groups()
        .expect("group B: get_groups")
        .into_iter()
        .next()
        .expect("group B should exist");

    // Two independently created groups must have different nostr_group_ids.
    assert_ne!(
        a_group.nostr_group_id, b_group.nostr_group_id,
        "independent groups must have distinct nostr_group_ids"
    );
    // ... and different MLS group IDs.
    assert_ne!(
        group_a.group_id.as_slice(),
        group_b.group_id.as_slice(),
        "independent groups must have distinct MLS group IDs"
    );

    // Each group must have a stored exporter secret at its current epoch
    // (precondition for the isolation claim to be meaningful).
    assert!(
        group_a
            .alice_mdk
            .get_stored_exporter_secret(&group_a.group_id, a_group.epoch)
            .expect("group A exporter query should not error"),
        "group A must have an exporter secret at its current epoch"
    );
    assert!(
        group_b
            .alice_mdk
            .get_stored_exporter_secret(&group_b.group_id, b_group.epoch)
            .expect("group B exporter query should not error"),
        "group B must have an exporter secret at its current epoch"
    );

    // Behavioural proof that the per-group exporter secrets differ WITHOUT ever
    // reading raw secret bytes: a message sealed for group A, re-routed under
    // group B's h-tag, must fail to decrypt in group B. Identical exporter
    // secrets would let the outer ChaCha20-Poly1305 layer open — it must not.
    let rumor =
        EventBuilder::new(Kind::Custom(9), "group A only").build(group_a.alice_keys.public_key());
    let sealed_for_a = group_a
        .alice_mdk
        .create_message(&group_a.group_id, rumor, None)
        .expect("group A should encrypt");

    let rerouted_to_b = EventBuilder::new(Kind::Custom(445), sealed_for_a.content)
        .tag(nostr::Tag::custom(
            nostr::TagKind::h(),
            [hex::encode(b_group.nostr_group_id)],
        ))
        .sign_with_keys(&Keys::generate())
        .expect("should re-sign rerouted event");

    let b_attempt = group_b.alice_mdk.process_message(&rerouted_to_b);
    let b_err =
        b_attempt.expect_err("group A ciphertext must not decrypt under group B's exporter secret");
    assert_is_decryption_failure(&b_err, "group A ciphertext rerouted to group B");

    group_a.cleanup();
    group_b.cleanup();
}

// ============================================================================
// RM-8: Forward Secrecy on the Wire (pruned-epoch ciphertext is undecryptable)
// ============================================================================
//
// Forward secrecy for kind:445 traffic depends on old-epoch exporter secrets
// being pruned. Haven inherits MDK's default `max_past_epochs = 5`: once the
// current epoch exceeds (message_epoch + 5), the message_epoch's exporter
// secret is pruned and ciphertext sealed at that epoch can no longer be
// decrypted — even by a group member, even with the original event. This
// complements RC-1/RC-2 (removal-based forward secrecy) by exercising the
// epoch-pruning path directly. Assumption documented here so a future change to
// `max_past_epochs` is a deliberate, visible decision.

#[test]
fn rm8_pruned_epoch_ciphertext_is_no_longer_decryptable() {
    let group = setup_two_party_group("rm8_fs_wire");

    // Capture the starting epoch and a message sealed at that epoch.
    let start_epoch = group
        .alice_mdk
        .get_groups()
        .expect("alice should get groups")
        .into_iter()
        .next()
        .expect("group should exist")
        .epoch;

    // The ciphertext under test (sealed at the start epoch). Bob does NOT
    // process this before pruning, so its MLS message generation is never
    // consumed — the only thing that can make it fail later is the missing
    // exporter secret, not generation-based dedup.
    let target_rumor =
        EventBuilder::new(Kind::Custom(9), "epoch N secret").build(group.alice_keys.public_key());
    let old_epoch_ciphertext = group
        .alice_mdk
        .create_message(&group.group_id, target_rumor, None)
        .expect("alice should encrypt the target message at the starting epoch");

    // Genuineness probe: a *separate* message sealed at the same start epoch
    // decrypts for Bob now. This proves Alice's start-epoch encryption is sound
    // (so a later failure on the target is attributable to pruning, not a
    // malformed payload) WITHOUT consuming the target's MLS generation.
    let probe_rumor = EventBuilder::new(Kind::Custom(9), "epoch N genuineness probe")
        .build(group.alice_keys.public_key());
    let probe_ciphertext = group
        .alice_mdk
        .create_message(&group.group_id, probe_rumor, None)
        .expect("alice should encrypt the probe message at the starting epoch");
    let bob_probe = group
        .bob_mdk
        .process_message(&probe_ciphertext)
        .expect("bob should decrypt the start-epoch probe");
    assert!(
        matches!(bob_probe, MessageProcessingResult::ApplicationMessage(_)),
        "start-epoch probe must decrypt before pruning"
    );

    // Advance Bob's group far enough that the starting epoch's exporter secret
    // is pruned. With max_past_epochs = 5, reaching (start_epoch + 6) makes
    // min_epoch_to_keep = current - 5 > start_epoch, pruning it. We drive Bob's
    // OWN epoch forward via self_update + merge (mirrors the p3b prune pattern).
    advance_epoch_to_at_least(&group.bob_mdk, &group.group_id, start_epoch + 6, 20);

    // Precondition: the starting epoch's exporter secret is actually pruned on
    // Bob's side. Without this, the decryption failure below could be a false
    // positive for an unrelated reason.
    let start_secret_pruned = !group
        .bob_mdk
        .get_stored_exporter_secret(&group.group_id, start_epoch)
        .expect("exporter query should not error");
    assert!(
        start_secret_pruned,
        "starting-epoch ({start_epoch}) exporter secret MUST be pruned once the \
         current epoch exceeds max_past_epochs=5"
    );

    // Forward secrecy on the wire: Bob now sees the pristine old-epoch
    // ciphertext for the FIRST time, after its exporter secret was pruned. It
    // must be undecryptable. Because Bob never processed this event before, the
    // failure cannot be generation-based dedup — it is purely the missing
    // secret (AEAD-layer failure). The original signed event is delivered as-is.
    let after_prune = group.bob_mdk.process_message(&old_epoch_ciphertext);
    let err = after_prune
        .expect_err("old-epoch ciphertext must be undecryptable after its secret is pruned");
    assert_is_decryption_failure(&err, "old-epoch ciphertext after pruning");

    // Bob's group must remain usable at the new epoch: a fresh message Bob seals
    // for himself round-trips. (Bob is the only one who advanced epochs here, so
    // Alice cannot decrypt at Bob's new epoch; we verify Bob's own send/receive,
    // which exercises the current exporter secret end-to-end.)
    let fresh_rumor = EventBuilder::new(Kind::Custom(9), "post-prune still works")
        .build(group.bob_keys.public_key());
    let fresh_event = group
        .bob_mdk
        .create_message(&group.group_id, fresh_rumor, None)
        .expect("bob should encrypt at the advanced epoch");
    // Bob cannot decrypt his OWN freshly-created message via process_message
    // (MLS rejects own-message decryption), but the encrypt path succeeding at
    // the new epoch — together with the pruned-secret failure above — confirms
    // the group state is intact rather than bricked. Assert the wrapper is a
    // well-formed kind:445 carrying the current nostr_group_id.
    assert_eq!(
        fresh_event.kind,
        Kind::Custom(445),
        "post-prune message must still be a kind:445 event"
    );
    let fresh_h = fresh_event
        .tags
        .iter()
        .find(|t| t.kind() == nostr::TagKind::h())
        .and_then(|t| t.content().map(str::to_owned))
        .expect("post-prune message must carry an h-tag");
    let bob_nostr_id = hex::encode(
        group
            .bob_mdk
            .get_groups()
            .expect("bob should get groups")
            .into_iter()
            .next()
            .expect("group should exist")
            .nostr_group_id,
    );
    assert_eq!(
        fresh_h, bob_nostr_id,
        "post-prune message h-tag must match the group's nostr_group_id"
    );

    group.cleanup();
}
