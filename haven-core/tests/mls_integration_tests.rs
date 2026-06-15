//! Integration tests for MLS module functionality.
//!
//! These tests verify the behavior of the MLS integration components including:
//! - `MdkManager` lifecycle and operations
//! - `MlsGroupContext` with MDK
//! - `StorageConfig` edge cases
//! - `LocationMessageResult` variants

mod helpers;

use std::env;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use haven_core::nostr::mls::storage::StorageConfig;
use haven_core::nostr::mls::types::{GroupId, LocationGroupConfig, LocationMessageResult};
use haven_core::nostr::mls::{MdkManager, MlsGroupContext};
use haven_core::nostr::NostrError;

// Atomic counter for unique test directories
static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

fn unique_temp_dir(prefix: &str) -> PathBuf {
    let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
    env::temp_dir().join(format!(
        "haven_mls_integ_{}_{}_{}",
        prefix,
        std::process::id(),
        id
    ))
}

fn cleanup_dir(dir: &PathBuf) {
    let _ = std::fs::remove_dir_all(dir);
}

// ============================================================================
// MdkManager Tests
// ============================================================================

mod mdk_manager_tests {
    use super::*;

    #[test]
    fn manager_get_group_returns_none_for_nonexistent() {
        let dir = unique_temp_dir("get_group_none");
        let manager = MdkManager::new_unencrypted(&dir).expect("should create manager");

        // Create a fake group ID
        let fake_group_id = GroupId::from_slice(&[1, 2, 3, 4, 5]);
        let result = manager.get_group(&fake_group_id);

        assert!(result.is_ok());
        assert!(result.unwrap().is_none());

        cleanup_dir(&dir);
    }

    #[test]
    fn manager_get_members_fails_for_nonexistent_group() {
        let dir = unique_temp_dir("get_members_fail");
        let manager = MdkManager::new_unencrypted(&dir).expect("should create manager");

        let fake_group_id = GroupId::from_slice(&[1, 2, 3, 4, 5]);
        let result = manager.get_members(&fake_group_id);

        // Should fail because group doesn't exist
        assert!(result.is_err());

        cleanup_dir(&dir);
    }

    #[test]
    fn manager_get_messages_fails_for_nonexistent_group() {
        let dir = unique_temp_dir("get_messages_fail");
        let manager = MdkManager::new_unencrypted(&dir).expect("should create manager");

        let fake_group_id = GroupId::from_slice(&[1, 2, 3, 4, 5]);
        let result = manager.get_messages(&fake_group_id);

        // Should fail because group doesn't exist
        assert!(result.is_err());

        cleanup_dir(&dir);
    }

    #[test]
    fn manager_leave_group_fails_for_nonexistent_group() {
        let dir = unique_temp_dir("leave_group_fail");
        let manager = MdkManager::new_unencrypted(&dir).expect("should create manager");

        let fake_group_id = GroupId::from_slice(&[1, 2, 3, 4, 5]);
        let result = manager.leave_group(&fake_group_id);

        // Should fail because group doesn't exist
        assert!(result.is_err());

        cleanup_dir(&dir);
    }

    #[test]
    fn manager_create_group_with_invalid_pubkey_fails() {
        let dir = unique_temp_dir("create_invalid_pubkey");
        let manager = MdkManager::new_unencrypted(&dir).expect("should create manager");

        let config = LocationGroupConfig::new("Test Group")
            .with_description("Test description")
            .with_relay("wss://relay.example.com");

        // Invalid pubkey (not valid hex)
        let result = manager.create_group("invalid-pubkey-not-hex", vec![], config);

        assert!(result.is_err());
        if let Err(NostrError::InvalidEvent(msg)) = result {
            assert!(msg.contains("Invalid creator pubkey"));
        } else {
            panic!("Expected InvalidEvent error");
        }

        cleanup_dir(&dir);
    }

    #[test]
    fn manager_create_group_with_short_pubkey_fails() {
        let dir = unique_temp_dir("create_short_pubkey");
        let manager = MdkManager::new_unencrypted(&dir).expect("should create manager");

        let config = LocationGroupConfig::new("Test Group");

        // Too short (valid hex but wrong length)
        let result = manager.create_group("abcd1234", vec![], config);

        assert!(result.is_err());

        cleanup_dir(&dir);
    }

    #[test]
    fn manager_to_location_result_group_update_from_commit() {
        use mdk_core::prelude::MessageProcessingResult;

        let group_id = GroupId::from_slice(&[1, 2, 3, 4]);

        let commit_result = MessageProcessingResult::Commit {
            mls_group_id: group_id,
        };

        let location_result = MdkManager::to_location_result(commit_result);

        if let LocationMessageResult::GroupUpdate {
            group_id: gid,
            evolution_event,
        } = location_result
        {
            assert_eq!(gid.as_slice(), &[1, 2, 3, 4]);
            assert!(evolution_event.is_none());
        } else {
            panic!("Expected GroupUpdate variant");
        }
    }

    #[test]
    fn manager_to_location_result_group_update_from_external_join() {
        use mdk_core::prelude::MessageProcessingResult;

        let group_id = GroupId::from_slice(&[5, 6, 7, 8]);

        let external_join = MessageProcessingResult::ExternalJoinProposal {
            mls_group_id: group_id,
        };

        let location_result = MdkManager::to_location_result(external_join);

        if let LocationMessageResult::GroupUpdate {
            group_id: gid,
            evolution_event,
        } = location_result
        {
            assert_eq!(gid.as_slice(), &[5, 6, 7, 8]);
            assert!(evolution_event.is_none());
        } else {
            panic!("Expected GroupUpdate variant");
        }
    }

    #[test]
    fn manager_to_location_result_unprocessable() {
        use mdk_core::prelude::MessageProcessingResult;

        let group_id = GroupId::from_slice(&[9, 10, 11, 12]);

        let unprocessable = MessageProcessingResult::Unprocessable {
            mls_group_id: group_id,
        };

        let location_result = MdkManager::to_location_result(unprocessable);

        if let LocationMessageResult::Unprocessable {
            group_id: gid,
            reason,
        } = location_result
        {
            assert_eq!(gid.as_slice(), &[9, 10, 11, 12]);
            assert!(reason.contains("could not be processed"));
        } else {
            panic!("Expected Unprocessable variant");
        }
    }

    #[test]
    fn manager_multiple_instances_same_directory() {
        let dir = unique_temp_dir("multi_instance");

        // Create first manager
        let manager1 = MdkManager::new_unencrypted(&dir).expect("should create first manager");
        let groups1 = manager1.get_groups().expect("should get groups");
        assert!(groups1.is_empty());

        // Create second manager pointing to same directory
        // This should work (SQLite handles concurrent access)
        let manager2 = MdkManager::new_unencrypted(&dir).expect("should create second manager");
        let groups2 = manager2.get_groups().expect("should get groups");
        assert!(groups2.is_empty());

        cleanup_dir(&dir);
    }
}

// ============================================================================
// MlsGroupContext Tests
// ============================================================================

mod mls_group_context_tests {
    use super::*;

    #[test]
    fn context_creation() {
        let dir = unique_temp_dir("ctx_creation");
        let manager = Arc::new(MdkManager::new_unencrypted(&dir).expect("should create manager"));
        let group_id = GroupId::from_slice(&[1, 2, 3, 4]);

        let ctx = MlsGroupContext::new(manager, group_id, "nostr-group-hex");

        assert_eq!(ctx.nostr_group_id(), "nostr-group-hex");
        // mls_group_id() is pub(crate) — not accessible from integration tests
        // This is intentional: real MLS group IDs should not be exposed externally

        cleanup_dir(&dir);
    }

    #[test]
    fn context_has_manager_reference() {
        let dir = unique_temp_dir("ctx_has_manager");
        let manager = Arc::new(MdkManager::new_unencrypted(&dir).expect("should create manager"));
        let group_id = GroupId::from_slice(&[1, 2, 3]);

        let ctx = MlsGroupContext::new(manager.clone(), group_id, "test");

        // Verify manager reference
        assert!(Arc::ptr_eq(ctx.manager(), &manager));

        cleanup_dir(&dir);
    }

    #[test]
    fn context_epoch_fails_for_nonexistent_group() {
        let dir = unique_temp_dir("ctx_epoch_fail");
        let manager = Arc::new(MdkManager::new_unencrypted(&dir).expect("should create manager"));
        let fake_group_id = GroupId::from_slice(&[99, 99, 99]);
        // Capture the hex of the REAL MLS group id before it is moved into the
        // context, so we can assert it is NOT what the error surfaces.
        let mls_hex = hex::encode(fake_group_id.as_slice());

        let ctx = MlsGroupContext::new(manager, fake_group_id, "test");

        let result = ctx.epoch();
        assert!(result.is_err());
        if let Err(NostrError::GroupNotFound(id)) = result {
            // Group-ID privacy (MIP-00 Rule 4): the error MUST surface the
            // nostr_group_id ("test"), never the real MLS group id. A bare
            // `!id.is_empty()` would pass even if the raw MLS id leaked.
            assert_eq!(id, "test", "GroupNotFound must surface the nostr_group_id");
            assert_ne!(id, mls_hex, "error must NOT surface the hex MLS group id");
            assert!(
                !id.contains(&mls_hex),
                "MLS group id must not be embedded in the surfaced error id"
            );
        } else {
            panic!("Expected GroupNotFound error");
        }

        cleanup_dir(&dir);
    }

    #[test]
    fn context_validate_epoch_fails_for_nonexistent_group() {
        let dir = unique_temp_dir("ctx_validate_epoch_fail");
        let manager = Arc::new(MdkManager::new_unencrypted(&dir).expect("should create manager"));
        let fake_group_id = GroupId::from_slice(&[99, 99]);

        let ctx = MlsGroupContext::new(manager, fake_group_id, "test");

        let result = ctx.validate_epoch(1);
        assert!(result.is_err());

        cleanup_dir(&dir);
    }

    #[test]
    fn context_debug_output() {
        let dir = unique_temp_dir("ctx_debug");
        let manager = Arc::new(MdkManager::new_unencrypted(&dir).expect("should create manager"));
        let group_id = GroupId::from_slice(&[1, 2, 3]);

        let ctx = MlsGroupContext::new(manager, group_id, "my-group");

        let debug_output = format!("{ctx:?}");
        assert!(debug_output.contains("MlsGroupContext"));
        assert!(debug_output.contains("my-group"));
        assert!(debug_output.contains("<redacted>"));
        assert!(!debug_output.contains("010203")); // real MLS group ID must NOT appear

        cleanup_dir(&dir);
    }

    #[test]
    fn context_with_empty_nostr_group_id() {
        let dir = unique_temp_dir("ctx_empty_id");
        let manager = Arc::new(MdkManager::new_unencrypted(&dir).expect("should create manager"));
        let group_id = GroupId::from_slice(&[1, 2, 3]);

        let ctx = MlsGroupContext::new(manager, group_id, "");

        assert_eq!(ctx.nostr_group_id(), "");

        cleanup_dir(&dir);
    }

    #[test]
    fn context_with_unicode_nostr_group_id() {
        let dir = unique_temp_dir("ctx_unicode");
        let manager = Arc::new(MdkManager::new_unencrypted(&dir).expect("should create manager"));
        let group_id = GroupId::from_slice(&[1, 2, 3]);

        let ctx = MlsGroupContext::new(manager, group_id, "groupe-familial-français");

        assert_eq!(ctx.nostr_group_id(), "groupe-familial-français");

        cleanup_dir(&dir);
    }
}

// ============================================================================
// StorageConfig Tests
// ============================================================================

mod storage_config_tests {
    use super::*;

    #[test]
    fn storage_config_creates_directory() {
        let dir = unique_temp_dir("storage_creates_dir");

        // Directory should not exist yet
        assert!(!dir.exists());

        let config = StorageConfig::new(&dir);
        let _storage = config
            .create_storage_unencrypted()
            .expect("should create storage");

        // Directory should now exist
        assert!(dir.exists());
        assert!(dir.is_dir());

        cleanup_dir(&dir);
    }

    #[test]
    fn storage_config_creates_nested_directories() {
        let base_dir = unique_temp_dir("storage_nested");
        let nested_dir = base_dir.join("level1").join("level2").join("level3");

        assert!(!nested_dir.exists());

        let config = StorageConfig::new(&nested_dir);
        let _storage = config
            .create_storage_unencrypted()
            .expect("should create storage");

        assert!(nested_dir.exists());

        cleanup_dir(&base_dir);
    }

    #[test]
    fn storage_config_database_path_correct() {
        let dir = PathBuf::from("/some/path");
        let config = StorageConfig::new(&dir);

        assert_eq!(
            config.database_path(),
            PathBuf::from("/some/path/haven_mdk.db")
        );
    }

    #[test]
    fn storage_config_relative_path() {
        let config = StorageConfig::new("relative/path");

        assert_eq!(config.data_dir, PathBuf::from("relative/path"));
        assert_eq!(
            config.database_path(),
            PathBuf::from("relative/path/haven_mdk.db")
        );
    }

    #[test]
    fn storage_config_empty_path() {
        let config = StorageConfig::new("");

        assert_eq!(config.data_dir, PathBuf::from(""));
        assert_eq!(config.database_path(), PathBuf::from("haven_mdk.db"));
    }

    #[test]
    fn storage_config_debug_impl() {
        let config = StorageConfig::new("/test/path");
        let debug_str = format!("{config:?}");

        assert!(debug_str.contains("StorageConfig"));
        assert!(debug_str.contains("/test/path"));
    }

    #[test]
    fn storage_config_clone() {
        let config1 = StorageConfig::new("/test/path");
        let config2 = config1.clone();

        assert_eq!(config1.data_dir, config2.data_dir);
    }
}

// ============================================================================
// LocationGroupConfig Tests
// ============================================================================

mod location_group_config_tests {
    use super::*;

    #[test]
    fn config_empty_name() {
        let config = LocationGroupConfig::new("");

        assert_eq!(config.name, "");
        assert!(config.description.is_empty());
        assert!(config.relays.is_empty());
        assert!(config.admins.is_empty());
    }

    #[test]
    fn config_unicode_name() {
        let config =
            LocationGroupConfig::new("Familie Schmidt").with_description("Deutsche Familie");

        assert_eq!(config.name, "Familie Schmidt");
        assert_eq!(config.description, "Deutsche Familie");
    }

    #[test]
    fn config_multiple_admins() {
        let config = LocationGroupConfig::new("Test")
            .with_admin("pubkey1")
            .with_admin("pubkey2")
            .with_admin("pubkey3");

        assert_eq!(config.admins.len(), 3);
        assert_eq!(config.admins[0], "pubkey1");
        assert_eq!(config.admins[2], "pubkey3");
    }

    #[test]
    fn config_empty_relays_vec() {
        let empty_relays: Vec<String> = vec![];
        let config = LocationGroupConfig::new("Test").with_relays(empty_relays);

        assert!(config.relays.is_empty());
    }

    #[test]
    fn config_with_relays_from_iter() {
        let relays = ["wss://r1.com", "wss://r2.com", "wss://r3.com"];
        let config = LocationGroupConfig::new("Test").with_relays(relays);

        assert_eq!(config.relays.len(), 3);
    }

    #[test]
    fn config_debug_output() {
        let config = LocationGroupConfig::new("Test Group")
            .with_description("A test")
            .with_relay("wss://relay.example.com")
            .with_admin("admin123");

        let debug_str = format!("{config:?}");

        assert!(debug_str.contains("Test Group"));
        assert!(debug_str.contains("A test"));
        assert!(debug_str.contains("relay.example.com"));
        assert!(debug_str.contains("admin123"));
    }

    #[test]
    fn config_clone() {
        let config1 = LocationGroupConfig::new("Original")
            .with_description("Desc")
            .with_relay("wss://r.com")
            .with_admin("admin");

        let config2 = config1.clone();

        assert_eq!(config1.name, config2.name);
        assert_eq!(config1.description, config2.description);
        assert_eq!(config1.relays, config2.relays);
        assert_eq!(config1.admins, config2.admins);
    }
}

// ============================================================================
// LocationMessageResult Tests
// ============================================================================

mod location_message_result_tests {
    use super::*;

    #[test]
    fn location_result_debug_location_variant() {
        let group_id = GroupId::from_slice(&[1, 2, 3]);

        let result = LocationMessageResult::Location {
            sender_pubkey: "abc123".to_string(),
            content: r#"{"latitude":37.7}"#.to_string(),
            group_id,
        };

        let debug_str = format!("{result:?}");

        assert!(debug_str.contains("Location"));
        // sender_pubkey and content must be redacted
        assert!(
            !debug_str.contains("abc123"),
            "sender_pubkey must be redacted in Debug output"
        );
        assert!(
            !debug_str.contains("latitude"),
            "content must be redacted in Debug output"
        );
        assert!(debug_str.contains("<redacted>"));
    }

    #[test]
    fn location_result_debug_group_update_variant() {
        let group_id = GroupId::from_slice(&[4, 5, 6]);

        let result = LocationMessageResult::GroupUpdate {
            group_id,
            evolution_event: None,
        };

        let debug_str = format!("{result:?}");

        assert!(debug_str.contains("GroupUpdate"));
    }

    #[test]
    fn location_result_debug_unprocessable_variant() {
        let group_id = GroupId::from_slice(&[7, 8, 9]);

        let result = LocationMessageResult::Unprocessable {
            group_id,
            reason: "Test failure reason".to_string(),
        };

        let debug_str = format!("{result:?}");

        assert!(debug_str.contains("Unprocessable"));
        assert!(debug_str.contains("Test failure reason"));
    }
}

// ============================================================================
// Production Storage Tests (require system keyring)
// ============================================================================

mod production_storage_tests {
    use super::*;
    use haven_core::circle::CircleManager;

    /// Tests that encrypted storage works when a system keyring is available.
    ///
    /// This test is ignored by default because it requires a system keyring
    /// (GNOME Keyring, macOS Keychain, Windows Credential Manager).
    ///
    /// Run manually with: `cargo test production_storage -- --ignored`
    #[test]
    #[ignore = "requires system keyring - run with --ignored flag"]
    fn storage_encrypted_creates_successfully() {
        let dir = unique_temp_dir("prod_storage_encrypted");

        let config = StorageConfig::new(&dir);
        let result = config.create_storage();

        // If we get here, keyring is available and storage was created
        assert!(result.is_ok(), "Encrypted storage should work with keyring");

        cleanup_dir(&dir);
    }

    /// Tests that `MdkManager` works with encrypted storage.
    ///
    /// This test is ignored by default because it requires a system keyring.
    #[test]
    #[ignore = "requires system keyring - run with --ignored flag"]
    fn mdk_manager_encrypted_creates_successfully() {
        let dir = unique_temp_dir("prod_manager_encrypted");

        let result = MdkManager::new(&dir);

        assert!(result.is_ok(), "MdkManager should work with keyring");

        // Verify basic operations work
        let manager = result.unwrap();
        assert!(manager.get_groups().unwrap().is_empty());
        assert!(manager.get_pending_welcomes().unwrap().is_empty());

        cleanup_dir(&dir);
    }

    /// Tests that `CircleManager` works with encrypted storage.
    ///
    /// This test is ignored by default because it requires a system keyring.
    #[test]
    #[ignore = "requires system keyring - run with --ignored flag"]
    fn circle_manager_encrypted_creates_successfully() {
        let dir = unique_temp_dir("prod_circle_encrypted");

        let result = CircleManager::new(&dir, None);

        assert!(result.is_ok(), "CircleManager should work with keyring");

        // Verify basic operations work
        let manager = result.unwrap();
        assert!(manager.get_circles().unwrap().is_empty());
        assert!(manager.get_all_contacts().unwrap().is_empty());

        cleanup_dir(&dir);
    }

    /// Tests that production encrypted storage either succeeds (keyring present)
    /// or fails with a descriptive keyring/storage error (keyring absent, e.g.
    /// CI).
    ///
    /// Asserting in BOTH arms removes the prior tautology: the old version put
    /// every assertion inside `if let Err(..)`, so on a keyring-present machine
    /// it silently asserted nothing yet still passed — masquerading as a
    /// verified error path. The `--ignored` `storage_encrypted_creates_successfully`
    /// exercises the success path deeply when a keyring is available.
    #[test]
    fn storage_encrypted_creates_or_reports_keyring_unavailable() {
        let dir = unique_temp_dir("prod_storage_error");
        let config = StorageConfig::new(&dir);

        match config.create_storage() {
            // Keyring present: the encrypted-storage creation path must succeed
            // (reaching this arm IS the success contract).
            Ok(_storage) => {}
            // Keyring absent: the failure must be a descriptive keyring/storage
            // error, never an opaque one.
            Err(e) => {
                let msg = e.to_string().to_lowercase();
                assert!(
                    msg.contains("keyring") || msg.contains("storage") || msg.contains("service"),
                    "missing-keyring failure must be descriptive, got: {e}"
                );
            }
        }

        cleanup_dir(&dir);
    }
}

// ============================================================================
// Receiver-Side Auto-Commit Tests
//
// Exercise the production bug described in Fix #1:
//
//   When a remaining member processes a leaver's `SelfRemove` proposal,
//   MDK's `auto_commit_proposal` stages a pending commit and returns
//   `MessageProcessingResult::Proposal(UpdateGroupResult)`. Haven
//   previously discarded the outbound evolution event, so the local
//   MLS epoch never advanced and the departed member kept showing up
//   in `get_members`. After the fix, `to_location_result` surfaces the
//   event on `LocationMessageResult::GroupUpdate::evolution_event` so
//   the caller can publish it, merge the pending commit, and advance
//   the epoch.
// ============================================================================

mod receiver_side_auto_commit_tests {
    use super::helpers::{cleanup_dir, create_key_package_event, unique_temp_dir};
    use super::*;
    use mdk_core::prelude::MessageProcessingResult;
    use nostr::Keys;

    /// Three-party MLS group handle used by the receiver-side auto-commit
    /// test. Carol is the remaining non-admin member who will process
    /// Bob's `SelfRemove` proposal.
    ///
    /// `alice_mdk` is retained even though the current tests do not
    /// read from it post-setup — dropping the manager early would also
    /// drop its `SQLCipher` connection while Bob's and Carol's managers
    /// are still live against the same group state. Prefixed with `_`
    /// to silence dead-code lints.
    struct ThreePartyGroup {
        _alice_mdk: MdkManager,
        alice_dir: PathBuf,
        bob_mdk: MdkManager,
        bob_keys: Keys,
        bob_dir: PathBuf,
        carol_mdk: MdkManager,
        carol_keys: Keys,
        carol_dir: PathBuf,
        group_id: GroupId,
    }

    impl ThreePartyGroup {
        fn cleanup(&self) {
            cleanup_dir(&self.alice_dir);
            cleanup_dir(&self.bob_dir);
            cleanup_dir(&self.carol_dir);
        }
    }

    /// Builds a three-party group:
    ///   - Alice (admin) creates the group with Bob + Carol as initial members.
    ///   - Bob and Carol each process their welcomes.
    ///
    /// All three parties are now on the same epoch and can encrypt/decrypt
    /// messages. Uses `helpers::create_key_package_event` for real MLS key
    /// material. Mirrors the two-party helper's sequencing.
    fn setup_three_party_group(prefix: &str) -> ThreePartyGroup {
        let relays = vec!["wss://relay.test.com".to_string()];

        let alice_dir = unique_temp_dir(&format!("{prefix}_alice"));
        let alice_mdk =
            MdkManager::new_unencrypted(&alice_dir).expect("should create alice manager");
        let alice_keys = Keys::generate();

        let bob_dir = unique_temp_dir(&format!("{prefix}_bob"));
        let bob_mdk = MdkManager::new_unencrypted(&bob_dir).expect("should create bob manager");
        let bob_keys = Keys::generate();

        let carol_dir = unique_temp_dir(&format!("{prefix}_carol"));
        let carol_mdk =
            MdkManager::new_unencrypted(&carol_dir).expect("should create carol manager");
        let carol_keys = Keys::generate();

        let bob_kp_event = create_key_package_event(&bob_mdk, &bob_keys, &relays);
        let carol_kp_event = create_key_package_event(&carol_mdk, &carol_keys, &relays);

        let config = LocationGroupConfig::new("Three Party Test Group")
            .with_description("Receiver-side auto-commit integration test")
            .with_relay("wss://relay.test.com")
            .with_admin(alice_keys.public_key().to_hex());

        let group_result = alice_mdk
            .create_group(
                &alice_keys.public_key().to_hex(),
                vec![bob_kp_event, carol_kp_event],
                config,
            )
            .expect("should create three-party group");

        let group_id = group_result.group.mls_group_id.clone();

        // Alice finalizes the create+add commit.
        alice_mdk
            .merge_pending_commit(&group_id)
            .expect("should merge alice's pending commit");

        // Bob and Carol each process their welcomes.
        for (mdk, pk_hex) in [
            (&bob_mdk, bob_keys.public_key().to_hex()),
            (&carol_mdk, carol_keys.public_key().to_hex()),
        ] {
            let welcome_rumor = group_result
                .welcome_rumors
                .iter()
                .find(|rumor| {
                    rumor
                        .tags
                        .iter()
                        .any(|t| t.as_slice().iter().any(|s| s.eq_ignore_ascii_case(&pk_hex)))
                })
                .unwrap_or_else(|| {
                    group_result
                        .welcome_rumors
                        .first()
                        .expect("should have at least one welcome rumor")
                });

            mdk.process_welcome(&nostr::EventId::all_zeros(), welcome_rumor)
                .expect("should process welcome");
            let pending = mdk
                .get_pending_welcomes()
                .expect("should get pending welcomes");
            let welcome = pending
                .iter()
                .find(|w| w.mls_group_id == group_id)
                .expect("should find welcome for this group");
            mdk.accept_welcome(welcome).expect("should accept welcome");
        }

        ThreePartyGroup {
            _alice_mdk: alice_mdk,
            alice_dir,
            bob_mdk,
            bob_keys,
            bob_dir,
            carol_mdk,
            carol_keys,
            carol_dir,
            group_id,
        }
    }

    /// Core regression test for Fix #1.
    ///
    /// Flow:
    ///   1. Alice (admin) + Bob + Carol are in a three-party group.
    ///   2. Bob calls `leave_group` → MDK returns an `UpdateGroupResult`
    ///      carrying a signed `kind:445` evolution event (the
    ///      `SelfRemove` proposal).
    ///   3. Carol processes that event via `process_message`. As a
    ///      non-admin receiver, MDK's `auto_commit_proposal` stages a
    ///      pending commit and returns
    ///      `MessageProcessingResult::Proposal(UpdateGroupResult)`.
    ///   4. After `to_location_result`, Carol's `GroupUpdate` MUST
    ///      carry `evolution_event: Some(_)` — this is the event the
    ///      Flutter layer is responsible for publishing.
    ///   5. Before publishing, Carol still sees Bob as a member (the
    ///      commit is only pending). After Carol treats the event as
    ///      its own advance (`process_message` on herself) + merges the
    ///      pending commit, Bob is removed and the epoch advances.
    ///
    /// This mirrors the `auto_commit_proposal` → `publish_and_merge`
    /// pattern implemented upstream in `whitenoise-rs/src/whitenoise/groups/publish.rs`.
    #[test]
    fn non_admin_receiver_gets_evolution_event_and_advances_epoch() {
        let g = setup_three_party_group("nonadmin_selfremove");

        // Sanity: all three parties are members on the same epoch.
        let members_before = g
            .carol_mdk
            .get_members(&g.group_id)
            .expect("carol should see members before Bob leaves");
        assert_eq!(
            members_before.len(),
            3,
            "expected Alice+Bob+Carol before leave"
        );
        assert!(
            members_before.contains(&g.bob_keys.public_key()),
            "Bob must start as a member"
        );
        let carol_epoch_before = g
            .carol_mdk
            .get_group(&g.group_id)
            .expect("carol: get_group should work")
            .expect("carol: group should exist")
            .epoch;

        // (2) Bob leaves — produces a signed kind 445 evolution event
        //     carrying the SelfRemove proposal.
        let leave_result = g.bob_mdk.leave_group(&g.group_id).expect("bob leaves");
        let self_remove_event = leave_result.evolution_event;
        assert_eq!(
            self_remove_event.kind,
            nostr::Kind::MlsGroupMessage,
            "leave_group must emit a kind:445 message"
        );

        // (3) Carol processes Bob's SelfRemove. As a non-admin, MDK
        //     auto-commits → returns Proposal(UpdateGroupResult).
        let processing_result = g
            .carol_mdk
            .process_message(&self_remove_event)
            .expect("carol: process_message should not error");

        let carol_auto_commit = match &processing_result {
            MessageProcessingResult::Proposal(r) => r.evolution_event.clone(),
            other => {
                panic!("non-admin Carol must get MessageProcessingResult::Proposal; got {other:?}")
            }
        };
        assert_eq!(
            carol_auto_commit.kind,
            nostr::Kind::MlsGroupMessage,
            "auto-committed commit must be a kind:445 message"
        );

        // (4) `to_location_result` must surface the evolution event —
        //     this is the exact mapping the FFI layer depends on.
        let location_result = MdkManager::to_location_result(processing_result);
        match &location_result {
            LocationMessageResult::GroupUpdate {
                group_id,
                evolution_event,
            } => {
                assert_eq!(group_id, &g.group_id, "mls_group_id must round-trip");
                let ev = evolution_event
                    .as_ref()
                    .expect("Proposal arm MUST carry Some(evolution_event)");
                assert_eq!(
                    ev.id, carol_auto_commit.id,
                    "evolution_event must be the same event MDK produced"
                );
            }
            other => {
                panic!("to_location_result on a Proposal must return GroupUpdate; got {other:?}")
            }
        }

        // (5a) Before merging, Carol's epoch has NOT advanced and Bob
        //      is still a member (the commit is pending).
        let carol_epoch_mid = g
            .carol_mdk
            .get_group(&g.group_id)
            .expect("carol: get_group should work")
            .expect("carol: group should exist")
            .epoch;
        assert_eq!(
            carol_epoch_mid, carol_epoch_before,
            "epoch MUST NOT advance before merge_pending_commit"
        );

        // (5b) Carol merges the pending commit — this is what the
        //      Flutter layer's `finalize_pending_commit` call drives.
        g.carol_mdk
            .merge_pending_commit(&g.group_id)
            .expect("carol: merge_pending_commit should succeed");

        let carol_epoch_after = g
            .carol_mdk
            .get_group(&g.group_id)
            .expect("carol: get_group should work")
            .expect("carol: group should exist")
            .epoch;
        assert!(
            carol_epoch_after > carol_epoch_before,
            "epoch MUST advance after merge; before={carol_epoch_before:?}, after={carol_epoch_after:?}"
        );

        let members_after = g
            .carol_mdk
            .get_members(&g.group_id)
            .expect("carol should see members after merge");
        assert!(
            !members_after.contains(&g.bob_keys.public_key()),
            "Bob must be evicted after the SelfRemove commit is merged"
        );
        assert!(
            members_after.contains(&g.carol_keys.public_key()),
            "Carol must remain a member"
        );

        g.cleanup();
    }

    /// Companion to the non-admin test: verify that the **admin** side
    /// of a peer's `SelfRemove` also receives `evolution_event: Some(_)`.
    ///
    /// In a two-party group (Alice admin, Bob member), Bob's `leave_group`
    /// emits a `SelfRemove` proposal. When Alice processes that event,
    /// MDK's `auto_commit_proposal` must stage a pending commit on her
    /// side too — the admin is not exempt from the auto-commit flow.
    /// If this regressed, the admin's own local epoch would stall and
    /// every subsequent location message from Bob (prior to the leave
    /// landing via some other path) would fail to decrypt.
    #[test]
    fn admin_receiver_gets_evolution_event_from_peer_selfremove() {
        // Reuse the three-party setup — it is the simplest way to get
        // a real admin + real non-admin without re-implementing a
        // dedicated two-party helper. Carol is irrelevant to this test
        // and is simply left alone.
        let g = setup_three_party_group("admin_selfremove");

        let alice_epoch_before = g
            ._alice_mdk
            .get_group(&g.group_id)
            .expect("alice: get_group should work")
            .expect("alice: group should exist")
            .epoch;

        let leave = g.bob_mdk.leave_group(&g.group_id).expect("bob leaves");

        // Alice — the admin — processes Bob's SelfRemove event.
        let processing = g
            ._alice_mdk
            .process_message(&leave.evolution_event)
            .expect("alice: process_message ok");

        let alice_auto_commit = match &processing {
            MessageProcessingResult::Proposal(r) => r.evolution_event.clone(),
            other => panic!(
                "admin Alice must get MessageProcessingResult::Proposal with an \
                 auto-commit from MDK; got {other:?}"
            ),
        };
        assert_eq!(
            alice_auto_commit.kind,
            nostr::Kind::MlsGroupMessage,
            "admin auto-committed event must be a kind:445 message"
        );

        let location_result = MdkManager::to_location_result(processing);
        match &location_result {
            LocationMessageResult::GroupUpdate {
                group_id,
                evolution_event,
            } => {
                assert_eq!(group_id, &g.group_id);
                let ev = evolution_event
                    .as_ref()
                    .expect("admin-side Proposal arm MUST carry Some(evolution_event)");
                assert_eq!(ev.id, alice_auto_commit.id);
            }
            other => {
                panic!("to_location_result on a Proposal must return GroupUpdate; got {other:?}")
            }
        }

        // Merging on Alice's side advances her epoch and removes Bob.
        g._alice_mdk
            .merge_pending_commit(&g.group_id)
            .expect("alice: merge_pending_commit should succeed");

        let alice_epoch_after = g
            ._alice_mdk
            .get_group(&g.group_id)
            .expect("alice: get_group should work")
            .expect("alice: group should exist")
            .epoch;
        assert!(
            alice_epoch_after > alice_epoch_before,
            "admin's epoch MUST advance after merge; before={alice_epoch_before:?}, \
             after={alice_epoch_after:?}"
        );

        let members_after = g
            ._alice_mdk
            .get_members(&g.group_id)
            .expect("alice should see members after merge");
        assert!(
            !members_after.contains(&g.bob_keys.public_key()),
            "Bob must be evicted from the admin's member list after the SelfRemove \
             commit merges"
        );

        g.cleanup();
    }

    /// Guard test: the `evolution_event` we hand out from `to_location_result`
    /// is a signed `kind:445` event. The Flutter layer serializes this
    /// directly to relays, so a regression that swaps this for some
    /// other kind would silently brick receiver-side auto-commits.
    #[test]
    fn proposal_evolution_event_is_signed_kind_445() {
        let g = setup_three_party_group("kind_445_guard");

        let leave = g.bob_mdk.leave_group(&g.group_id).expect("bob leaves");
        let processing = g
            .carol_mdk
            .process_message(&leave.evolution_event)
            .expect("carol: process_message ok");

        if let LocationMessageResult::GroupUpdate {
            evolution_event: Some(ev),
            ..
        } = MdkManager::to_location_result(processing)
        {
            assert_eq!(ev.kind, nostr::Kind::MlsGroupMessage);
            // RM-5: cryptographically verify the signature rather than merely
            // checking `sig` is non-empty. `verify()` checks BOTH the Schnorr
            // signature over the event id AND that the id is correctly derived
            // from (pubkey, created_at, kind, tags, content). MDK signs commit
            // events with an ephemeral key; the Flutter layer relays this event
            // verbatim, so an unsigned, mis-signed, or content-tampered event
            // here would brick receiver-side auto-commits. A non-empty-string
            // check would pass for a garbage signature — `verify()` does not.
            ev.verify().expect(
                "commit evolution_event must carry a valid signature before reaching the FFI",
            );
        } else {
            panic!("expected GroupUpdate with Some(evolution_event)");
        }

        g.cleanup();
    }
}
