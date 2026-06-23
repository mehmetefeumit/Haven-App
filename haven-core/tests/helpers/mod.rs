//! Reusable test helpers for MDK/MLS integration tests.
//!
//! These helpers use REAL MLS crypto with `new_unencrypted()` storage.
//! Each `MdkManager` instance simulates a separate user with their own
//! MLS state. No mocking is needed.
//!
//! Each integration test binary compiles this module independently and only
//! uses a subset of the helpers, so `dead_code` is silenced at the module
//! level rather than per item.

#![allow(dead_code)]

use std::env;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use haven_core::nostr::mls::types::{GroupId, LocationGroupConfig};
use haven_core::nostr::mls::MdkManager;
use nostr::{Event, EventBuilder, Keys, Kind, UnsignedEvent};

/// Atomic counter for unique test directory names.
static HELPER_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Creates a unique temporary directory for test isolation.
///
/// Each call produces a distinct path by combining the prefix, process ID,
/// and an atomic counter.
pub fn unique_temp_dir(prefix: &str) -> PathBuf {
    let id = HELPER_COUNTER.fetch_add(1, Ordering::SeqCst);
    env::temp_dir().join(format!(
        "haven_g_test_{}_{}_{}",
        prefix,
        std::process::id(),
        id
    ))
}

/// Removes a temporary test directory. Ignores errors silently.
pub fn cleanup_dir(dir: &PathBuf) {
    let _ = std::fs::remove_dir_all(dir);
}

/// Creates a signed key package Event (kind 443) for a user.
///
/// This generates real MLS key material through the MDK manager and wraps
/// it in a properly signed Nostr event, exactly as would happen in production.
///
/// # Arguments
///
/// * `manager` - The user's MdkManager (each user needs their own)
/// * `keys` - The user's Nostr identity keys
/// * `relays` - Relay URLs for the key package
pub fn create_key_package_event(manager: &MdkManager, keys: &Keys, relays: &[String]) -> Event {
    let pubkey_hex = keys.public_key().to_hex();

    // Generate real MLS key package via MDK
    let bundle = manager
        .create_key_package(&pubkey_hex, relays)
        .expect("should create key package");

    // Parse the tags from Vec<Vec<String>> into nostr::Tag (kind 443 for test compatibility)
    let tags: Vec<nostr::Tag> = bundle
        .tags_443
        .into_iter()
        .map(|tag_vec| nostr::Tag::parse(&tag_vec).expect("should parse tag"))
        .collect();

    // Build and sign a kind 443 event
    EventBuilder::new(Kind::MlsKeyPackage, bundle.content)
        .tags(tags)
        .sign_with_keys(keys)
        .expect("should sign key package event")
}

/// Result of setting up a two-party MLS group.
pub struct TwoPartyGroup {
    pub alice_mdk: MdkManager,
    pub alice_keys: Keys,
    pub alice_dir: PathBuf,
    pub bob_mdk: MdkManager,
    pub bob_keys: Keys,
    pub bob_dir: PathBuf,
    pub group_id: GroupId,
}

impl TwoPartyGroup {
    /// Cleans up all temporary directories.
    pub fn cleanup(&self) {
        cleanup_dir(&self.alice_dir);
        cleanup_dir(&self.bob_dir);
    }
}

/// Sets up a complete two-party MLS group (Alice creates, Bob joins).
///
/// This performs real MLS operations:
/// 1. Creates separate MdkManagers for Alice and Bob
/// 2. Bob generates a key package and signs it
/// 3. Alice creates a group with Bob's key package
/// 4. Bob processes and accepts the welcome
///
/// Both parties can then encrypt/decrypt messages for the group.
pub fn setup_two_party_group(prefix: &str) -> TwoPartyGroup {
    let relays = vec!["wss://relay.test.com".to_string()];

    // Create separate managers (each user needs their own MLS state)
    let alice_dir = unique_temp_dir(&format!("{prefix}_alice"));
    let alice_mdk = MdkManager::new_unencrypted(&alice_dir).expect("should create alice manager");
    let alice_keys = Keys::generate();

    let bob_dir = unique_temp_dir(&format!("{prefix}_bob"));
    let bob_mdk = MdkManager::new_unencrypted(&bob_dir).expect("should create bob manager");
    let bob_keys = Keys::generate();

    // Bob creates a key package (signed event)
    let bob_kp_event = create_key_package_event(&bob_mdk, &bob_keys, &relays);

    // Alice creates the group with Bob
    let config = LocationGroupConfig::new("Test Group")
        .with_description("Integration test group")
        .with_relay("wss://relay.test.com")
        .with_admin(&alice_keys.public_key().to_hex());

    let group_result = alice_mdk
        .create_group(
            &alice_keys.public_key().to_hex(),
            vec![bob_kp_event],
            config,
        )
        .expect("should create group");

    let group_id = group_result.group.mls_group_id.clone();

    // Alice merges the pending commit (finalizes group creation)
    alice_mdk
        .merge_pending_commit(&group_id)
        .expect("should merge alice's pending commit");

    // Bob processes the welcome rumor
    let welcome_rumor = group_result
        .welcome_rumors
        .first()
        .expect("should have welcome rumor for bob");

    bob_mdk
        .process_welcome(&nostr::EventId::all_zeros(), welcome_rumor)
        .expect("should process welcome");

    // Bob accepts the welcome
    let pending = bob_mdk
        .get_pending_welcomes()
        .expect("should get pending welcomes");
    let welcome = pending.first().expect("should have one pending welcome");

    bob_mdk
        .accept_welcome(welcome)
        .expect("should accept welcome");

    TwoPartyGroup {
        alice_mdk,
        alice_keys,
        alice_dir,
        bob_mdk,
        bob_keys,
        bob_dir,
        group_id,
    }
}

/// A two-party group plus the welcome rumor Bob processed to join.
///
/// Used by tests that need to inspect the welcome rumor itself (e.g. the
/// MIP-02 unsigned-kind-444 invariant) — `setup_two_party_group` consumes the
/// rumor internally and does not expose it.
pub struct TwoPartyGroupWithWelcome {
    pub group: TwoPartyGroup,
    /// The unsigned kind-444 welcome rumor MDK produced for Bob during group
    /// creation. This is the exact rumor the gift-wrap/welcome path operates on.
    pub bob_welcome_rumor: UnsignedEvent,
}

impl TwoPartyGroupWithWelcome {
    /// Cleans up all temporary directories.
    pub fn cleanup(&self) {
        self.group.cleanup();
    }
}

/// Sets up a two-party MLS group and additionally returns the welcome rumor
/// that Bob processed to join.
///
/// Behaviourally identical to [`setup_two_party_group`] (Alice creates, Bob
/// joins and accepts), but the welcome rumor MDK emitted is captured and
/// returned so tests can assert protocol properties of the welcome itself
/// (it MUST be an unsigned kind-444 event per MIP-02 / Security Rule #3).
pub fn setup_two_party_group_capturing_welcome(prefix: &str) -> TwoPartyGroupWithWelcome {
    let relays = vec!["wss://relay.test.com".to_string()];

    let alice_dir = unique_temp_dir(&format!("{prefix}_alice"));
    let alice_mdk = MdkManager::new_unencrypted(&alice_dir).expect("should create alice manager");
    let alice_keys = Keys::generate();

    let bob_dir = unique_temp_dir(&format!("{prefix}_bob"));
    let bob_mdk = MdkManager::new_unencrypted(&bob_dir).expect("should create bob manager");
    let bob_keys = Keys::generate();

    let bob_kp_event = create_key_package_event(&bob_mdk, &bob_keys, &relays);

    let config = LocationGroupConfig::new("Test Group")
        .with_description("Integration test group")
        .with_relay("wss://relay.test.com")
        .with_admin(alice_keys.public_key().to_hex());

    let group_result = alice_mdk
        .create_group(
            &alice_keys.public_key().to_hex(),
            vec![bob_kp_event],
            config,
        )
        .expect("should create group");

    let group_id = group_result.group.mls_group_id.clone();

    alice_mdk
        .merge_pending_commit(&group_id)
        .expect("should merge alice's pending commit");

    let bob_welcome_rumor = group_result
        .welcome_rumors
        .first()
        .expect("should have welcome rumor for bob")
        .clone();

    bob_mdk
        .process_welcome(&nostr::EventId::all_zeros(), &bob_welcome_rumor)
        .expect("should process welcome");

    let pending = bob_mdk
        .get_pending_welcomes()
        .expect("should get pending welcomes");
    let welcome = pending.first().expect("should have one pending welcome");

    bob_mdk
        .accept_welcome(welcome)
        .expect("should accept welcome");

    TwoPartyGroupWithWelcome {
        group: TwoPartyGroup {
            alice_mdk,
            alice_keys,
            alice_dir,
            bob_mdk,
            bob_keys,
            bob_dir,
            group_id,
        },
        bob_welcome_rumor,
    }
}

// ============================================================================
// Shared security/wire assertion helpers (moved here from
// `mls_e2e_security_tests.rs` per profile-pictures plan §9 so the avatar
// integration tests can reuse them).
// ============================================================================

use haven_core::nostr::NostrError;
use nostr::JsonUtil as _;

/// Drives `mdk`'s view of `group_id` forward via repeated `self_update` +
/// `merge_pending_commit` until its epoch reaches at least `target_epoch`.
///
/// The bounded loop (`max_iters`) makes the test fail loudly rather than hang
/// if `self_update` ever stops advancing the epoch. Returns the epoch reached.
pub fn advance_epoch_to_at_least(
    mdk: &MdkManager,
    group_id: &GroupId,
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
pub fn assert_is_decryption_failure(err: &NostrError, context: &str) {
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
pub fn assert_no_raw_mls_group_id_leak(
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
