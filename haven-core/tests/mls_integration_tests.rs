//! Integration tests for MLS module functionality.
//!
//! These tests verify the behavior of the MLS integration components including:
//! - `MdkManager` lifecycle and operations
//! - `MlsGroupContext` with MDK
//! - `StorageConfig` edge cases
//! - `LocationMessageResult` variants

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

        if let LocationMessageResult::GroupUpdate { group_id: gid } = location_result {
            assert_eq!(gid.as_slice(), &[1, 2, 3, 4]);
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

        if let LocationMessageResult::GroupUpdate { group_id: gid } = location_result {
            assert_eq!(gid.as_slice(), &[5, 6, 7, 8]);
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

        let ctx = MlsGroupContext::new(manager, fake_group_id, "test");

        let result = ctx.epoch();
        assert!(result.is_err());
        if let Err(NostrError::GroupNotFound(id)) = result {
            // Error now contains the nostr_group_id (not hex-encoded MLS group ID)
            assert!(!id.is_empty());
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
        assert!(debug_str.contains("abc123"));
        assert!(debug_str.contains("latitude"));
    }

    #[test]
    fn location_result_debug_group_update_variant() {
        let group_id = GroupId::from_slice(&[4, 5, 6]);

        let result = LocationMessageResult::GroupUpdate {
            group_id,
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

        let result = CircleManager::new(&dir);

        assert!(result.is_ok(), "CircleManager should work with keyring");

        // Verify basic operations work
        let manager = result.unwrap();
        assert!(manager.get_circles().unwrap().is_empty());
        assert!(manager.get_all_contacts().unwrap().is_empty());

        cleanup_dir(&dir);
    }

    /// Tests that production storage fails gracefully without a keyring.
    ///
    /// This test verifies the error message is helpful when keyring is unavailable.
    /// It's not ignored because it tests the error path which should work everywhere.
    #[test]
    fn storage_encrypted_provides_clear_error_without_keyring() {
        // This test only makes sense in environments without a keyring
        // On systems with a keyring, the storage will succeed instead of failing

        let dir = unique_temp_dir("prod_storage_error");

        let config = StorageConfig::new(&dir);
        let result = config.create_storage();

        // Either the storage succeeds (keyring available) or fails with a clear error
        if let Err(e) = result {
            let error_msg = e.to_string();
            // Error should mention keyring or storage initialization
            assert!(
                error_msg.contains("keyring")
                    || error_msg.contains("Keyring")
                    || error_msg.contains("storage")
                    || error_msg.contains("Storage"),
                "Error message should be descriptive: {error_msg}"
            );
        }
        // If it succeeded, that's fine too - keyring was available

        cleanup_dir(&dir);
    }
}
