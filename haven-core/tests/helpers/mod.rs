//! Reusable test helpers for MDK/MLS integration tests.
//!
//! These helpers use REAL MLS crypto with `new_unencrypted()` storage.
//! Each `MdkManager` instance simulates a separate user with their own
//! MLS state. No mocking is needed.

use std::env;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use haven_core::nostr::mls::types::{GroupId, LocationGroupConfig};
use haven_core::nostr::mls::MdkManager;
use nostr::{Event, EventBuilder, Keys, Kind};

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

    // Parse the tags from Vec<Vec<String>> into nostr::Tag
    let tags: Vec<nostr::Tag> = bundle
        .tags
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
