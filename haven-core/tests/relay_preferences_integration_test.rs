//! Integration tests for user-configurable relay preferences.
//!
//! Verifies the full storage surface end-to-end against a real (encrypted
//! and unencrypted) `circles.db`, including schema bootstrap, idempotent
//! seeding, normalization, and the publish-target unioning. Unit-test
//! coverage of pure helpers lives in `src/circle/storage_relay_prefs.rs`
//! and `src/relay/publishers.rs`; these tests catch regressions that a
//! pure-helper suite cannot (schema, encryption interaction, sentinel
//! persistence across reopen).

use std::env;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use haven_core::circle::{CircleStorage, RelayType, DEFAULT_RELAYS};
use haven_core::relay::compute_publish_targets;

// Counter for unique test paths so parallel test runs don't collide.
static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

fn unique_db_path(prefix: &str) -> PathBuf {
    let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
    let dir = env::temp_dir().join(format!(
        "haven_relay_prefs_integ_{}_{}_{}",
        prefix,
        std::process::id(),
        id
    ));
    std::fs::create_dir_all(&dir).expect("temp dir");
    dir.join("circles.db")
}

fn cleanup(path: &PathBuf) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::remove_dir_all(parent);
    }
}

/// 64-char hex key for SQLCipher tests.
fn test_hex_key() -> String {
    "deadbeefcafebabe1234567890abcdef".repeat(2)
}

#[test]
fn schema_bootstrap_creates_tables() {
    let path = unique_db_path("schema");
    let storage = CircleStorage::new(&path, None).expect("open");
    // Listing both categories must succeed even though no data exists yet.
    let inbox = storage.list_user_relays(RelayType::Inbox).unwrap();
    let kp = storage.list_user_relays(RelayType::KeyPackage).unwrap();
    assert!(inbox.is_empty());
    assert!(kp.is_empty());
    // Toggles default to true even without seeding.
    assert!(storage.get_publish_inbox_relay_list().unwrap());
    assert!(storage.get_publish_kp_relay_list().unwrap());
    cleanup(&path);
}

#[test]
fn seed_then_reopen_remembers_sentinel() {
    let path = unique_db_path("sentinel");
    {
        let storage = CircleStorage::new(&path, None).expect("open");
        let did_seed = storage.seed_defaults_if_unseeded().unwrap();
        assert!(did_seed);
        // User removes a default — leaves two others, allowed.
        storage
            .remove_user_relay(DEFAULT_RELAYS[0], RelayType::Inbox)
            .unwrap();
    }
    // Drop and reopen to simulate an app restart.
    {
        let storage = CircleStorage::new(&path, None).expect("reopen");
        // Sentinel persisted — re-seeding is a no-op even though the user
        // legitimately removed a default. This is the regression test for
        // the row-presence-vs-sentinel bug class.
        let did_seed = storage.seed_defaults_if_unseeded().unwrap();
        assert!(!did_seed);
        let inbox = storage.list_user_relays(RelayType::Inbox).unwrap();
        assert_eq!(
            inbox.len(),
            DEFAULT_RELAYS.len() - 1,
            "removed default must NOT be re-added by defensive seed"
        );
    }
    cleanup(&path);
}

#[test]
fn full_crud_against_encrypted_db() {
    let path = unique_db_path("encrypted");
    let key = test_hex_key();
    let storage = CircleStorage::new(&path, Some(&key)).expect("encrypted open");
    storage.seed_defaults_if_unseeded().unwrap();

    // Add custom URL — round-trips through SQLCipher.
    storage
        .add_user_relay("wss://my-relay.example.com", RelayType::KeyPackage)
        .unwrap();
    let kp = storage.list_user_relays(RelayType::KeyPackage).unwrap();
    assert!(kp.iter().any(|u| u.contains("my-relay.example.com")));

    // Remove a default (still leaves at least one).
    storage
        .remove_user_relay(DEFAULT_RELAYS[0], RelayType::KeyPackage)
        .unwrap();

    // Restore is non-destructive — defaults come back, custom stays.
    storage.restore_defaults_for(RelayType::KeyPackage).unwrap();
    let after_restore = storage.list_user_relays(RelayType::KeyPackage).unwrap();
    assert!(after_restore
        .iter()
        .any(|u| u.contains("my-relay.example.com")));
    for d in DEFAULT_RELAYS {
        assert!(after_restore.iter().any(|u| u.starts_with(d)));
    }

    cleanup(&path);
}

#[test]
fn publish_targets_dedupe_with_defaults() {
    let path = unique_db_path("targets");
    let storage = CircleStorage::new(&path, None).expect("open");
    storage.seed_defaults_if_unseeded().unwrap();
    // Add a non-default custom relay.
    storage
        .add_user_relay("wss://nostr.wine", RelayType::Inbox)
        .unwrap();
    let user = storage.list_user_relays(RelayType::Inbox).unwrap();
    let targets = compute_publish_targets(&user);
    // All defaults present and the custom one present, exactly once each.
    for d in DEFAULT_RELAYS {
        let count = targets.iter().filter(|u| u.starts_with(d)).count();
        assert_eq!(count, 1, "default {d} must appear exactly once in targets");
    }
    let custom_count = targets.iter().filter(|u| u.contains("nostr.wine")).count();
    assert_eq!(custom_count, 1);
    cleanup(&path);
}

#[test]
fn add_then_remove_to_empty_blocks() {
    let path = unique_db_path("empty_block");
    let storage = CircleStorage::new(&path, None).expect("open");
    storage
        .add_user_relay("wss://only.example.com", RelayType::Inbox)
        .unwrap();
    // Removing the only entry must error.
    let res = storage.remove_user_relay("wss://only.example.com", RelayType::Inbox);
    assert!(res.is_err(), "must refuse to delete the last relay");
    let after = storage.list_user_relays(RelayType::Inbox).unwrap();
    assert_eq!(after.len(), 1, "row must remain after refused delete");
    cleanup(&path);
}

#[test]
fn ws_scheme_rejected_at_storage_boundary() {
    let path = unique_db_path("ws_reject");
    let storage = CircleStorage::new(&path, None).expect("open");
    // Plaintext ws:// must never reach storage.
    let res = storage.add_user_relay("ws://insecure.example.com", RelayType::Inbox);
    assert!(res.is_err());
    cleanup(&path);
}

#[test]
fn credentials_in_url_rejected() {
    let path = unique_db_path("creds_reject");
    let storage = CircleStorage::new(&path, None).expect("open");
    let res = storage.add_user_relay("wss://user:pass@relay.example.com", RelayType::KeyPackage);
    assert!(
        res.is_err(),
        "URLs with embedded credentials must be rejected"
    );
    cleanup(&path);
}

#[test]
fn url_normalization_collides_on_unique() {
    let path = unique_db_path("normalize");
    let storage = CircleStorage::new(&path, None).expect("open");
    // Add with mixed case + trailing slash.
    storage
        .add_user_relay("WSS://Relay.Example.com/", RelayType::Inbox)
        .unwrap();
    // Same URL in canonical form — must collide on UNIQUE (no second row).
    storage
        .add_user_relay("wss://relay.example.com", RelayType::Inbox)
        .unwrap();
    let inbox = storage.list_user_relays(RelayType::Inbox).unwrap();
    let count = inbox
        .iter()
        .filter(|u| u.contains("relay.example.com"))
        .count();
    assert_eq!(count, 1);
    cleanup(&path);
}

#[test]
fn toggles_persist_across_reopen() {
    let path = unique_db_path("toggles");
    {
        let storage = CircleStorage::new(&path, None).expect("open");
        storage.set_publish_kp_relay_list(false).unwrap();
        storage.set_publish_inbox_relay_list(false).unwrap();
    }
    {
        let storage = CircleStorage::new(&path, None).expect("reopen");
        assert!(!storage.get_publish_kp_relay_list().unwrap());
        assert!(!storage.get_publish_inbox_relay_list().unwrap());
    }
    cleanup(&path);
}
