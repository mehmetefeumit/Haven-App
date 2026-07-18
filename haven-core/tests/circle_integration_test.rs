//! Integration tests for Circle management module.
//!
//! These tests verify the behavior of the Circle module including:
//! - `CircleManager` lifecycle and operations
//! - `CircleStorage` database operations
//! - Contact management
//! - Membership state management
//! - UI state persistence
//! - Invitation flow (storage-level)
//!
//! MLS-dependent tests use real MDK with unencrypted storage
//! (no mocking needed).

use std::env;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use haven_core::circle::{
    Circle, CircleConfig, CircleCreationResult, CircleManager, CircleMembership, CircleStorage,
    CircleType, CircleUiState, Contact, GiftWrappedWelcome, LeavePlan, MemberKeyPackage,
    MembershipStatus,
};
use haven_core::nostr::mls::types::GroupId;
use haven_core::nostr::mls::GroupIdExt as _;

// Atomic counter for unique test directories
static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

fn unique_temp_dir(prefix: &str) -> PathBuf {
    let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
    env::temp_dir().join(format!(
        "haven_circle_integ_{}_{}_{}",
        prefix,
        std::process::id(),
        id
    ))
}

fn cleanup_dir(dir: &PathBuf) {
    let _ = std::fs::remove_dir_all(dir);
}

fn create_test_circle(id: u8) -> Circle {
    Circle {
        mls_group_id: GroupId::from_slice(&[id; 32]),
        nostr_group_id: [id; 32],
        display_name: format!("Test Circle {id}"),
        circle_type: CircleType::LocationSharing,
        relays: vec![
            "wss://relay.damus.io".to_string(),
            "wss://relay.primal.net".to_string(),
        ],
        created_at: 1_000_000 + i64::from(id),
        updated_at: 2_000_000 + i64::from(id),
    }
}

fn create_test_membership(id: u8, status: MembershipStatus) -> CircleMembership {
    CircleMembership {
        mls_group_id: GroupId::from_slice(&[id; 32]),
        status,
        inviter_pubkey: if status == MembershipStatus::Pending {
            Some(format!("{id:064x}"))
        } else {
            None
        },
        invited_at: 1_000_000,
        responded_at: if status == MembershipStatus::Pending {
            None
        } else {
            Some(2_000_000)
        },
    }
}

#[allow(dead_code)] // Will be used when MDK mocking is available
fn create_test_contact(id: u8) -> Contact {
    Contact {
        pubkey: format!("{id:064x}"),
        display_name: Some(format!("Contact {id}")),
        notes: Some(format!("Notes for contact {id}")),
        created_at: 1_000_000,
        updated_at: 2_000_000,
    }
}

// ============================================================================
// CircleManager Lifecycle Tests
// ============================================================================

mod circle_manager_lifecycle_tests {
    use super::*;

    #[test]
    fn manager_new_creates_data_directory() {
        let dir = unique_temp_dir("mgr_creates_dir");

        // Directory should not exist yet
        assert!(!dir.exists());

        let _manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        // Directory should now exist
        assert!(dir.exists());
        assert!(dir.is_dir());

        // Database file should exist
        let db_path = dir.join("circles.db");
        assert!(db_path.exists());

        cleanup_dir(&dir);
    }

    #[test]
    fn manager_new_with_nested_directory() {
        let base_dir = unique_temp_dir("mgr_nested");
        let nested_dir = base_dir.join("level1").join("level2").join("level3");

        assert!(!nested_dir.exists());

        let _manager = CircleManager::new_unencrypted(&nested_dir, &nostr::Keys::generate())
            .expect("should create manager");

        assert!(nested_dir.exists());
        assert!(nested_dir.join("circles.db").exists());

        cleanup_dir(&base_dir);
    }

    #[test]
    fn manager_new_with_existing_directory() {
        let dir = unique_temp_dir("mgr_existing");
        std::fs::create_dir_all(&dir).unwrap();

        let _manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        assert!(dir.exists());
        assert!(dir.join("circles.db").exists());

        cleanup_dir(&dir);
    }

    // DELETED-WITH-SUBJECT: `manager_multiple_instances_same_directory` — Rule 14
    // forbids two live `AccountDeviceSession`s on one DB file (divergent hydrated
    // epoch state = forward-secrecy erosion). Opening two `CircleManager`s on the
    // same data dir is no longer a supported (or safe) construction.

    #[tokio::test]
    async fn manager_get_circles_returns_empty_initially() {
        let dir = unique_temp_dir("mgr_empty_circles");
        let manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        let circles = manager.get_circles().await.expect("should get circles");
        assert!(circles.is_empty());

        cleanup_dir(&dir);
    }

    #[tokio::test]
    async fn manager_get_visible_circles_returns_empty_initially() {
        let dir = unique_temp_dir("mgr_empty_visible");
        let manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        let circles = manager
            .get_visible_circles()
            .await
            .expect("should get visible circles");
        assert!(circles.is_empty());

        cleanup_dir(&dir);
    }

    #[tokio::test]
    async fn manager_get_circle_nonexistent_returns_none() {
        let dir = unique_temp_dir("mgr_get_none");
        let manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        let fake_id = GroupId::from_slice(&[99; 32]);
        let result = manager
            .get_circle(&fake_id)
            .await
            .expect("should not error");
        assert!(result.is_none());

        cleanup_dir(&dir);
    }
}

// ============================================================================
// Contact Management Tests (fully testable without MDK)
// ============================================================================

mod contact_management_tests {
    use super::*;

    #[test]
    fn set_contact_creates_new_contact() {
        let dir = unique_temp_dir("contact_create");
        let manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        let contact = manager
            .set_contact("abc123", Some("Alice"), Some("Friend from work"))
            .expect("should set contact");

        assert_eq!(contact.pubkey, "abc123");
        assert_eq!(contact.display_name, Some("Alice".to_string()));
        assert_eq!(contact.notes, Some("Friend from work".to_string()));
        assert!(contact.created_at > 0);
        assert!(contact.updated_at > 0);

        cleanup_dir(&dir);
    }

    #[test]
    fn set_contact_with_minimal_data() {
        let dir = unique_temp_dir("contact_minimal");
        let manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        let contact = manager
            .set_contact("pubkey123", Some("Bob"), None)
            .expect("should set contact");

        assert_eq!(contact.pubkey, "pubkey123");
        assert_eq!(contact.display_name, Some("Bob".to_string()));
        assert!(contact.notes.is_none());

        cleanup_dir(&dir);
    }

    #[test]
    fn set_contact_with_no_display_name() {
        let dir = unique_temp_dir("contact_no_name");
        let manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        let contact = manager
            .set_contact("pubkey456", None, Some("Some notes"))
            .expect("should set contact");

        assert_eq!(contact.pubkey, "pubkey456");
        assert!(contact.display_name.is_none());
        assert_eq!(contact.notes, Some("Some notes".to_string()));

        cleanup_dir(&dir);
    }

    #[test]
    fn get_contact_retrieves_saved_contact() {
        let dir = unique_temp_dir("contact_get");
        let manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        manager
            .set_contact("xyz789", Some("Charlie"), Some("Neighbor"))
            .expect("should set contact");

        let retrieved = manager
            .get_contact("xyz789")
            .expect("should get contact")
            .expect("contact should exist");

        assert_eq!(retrieved.pubkey, "xyz789");
        assert_eq!(retrieved.display_name, Some("Charlie".to_string()));
        assert_eq!(retrieved.notes, Some("Neighbor".to_string()));

        cleanup_dir(&dir);
    }

    #[test]
    fn get_contact_nonexistent_returns_none() {
        let dir = unique_temp_dir("contact_get_none");
        let manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        let result = manager
            .get_contact("nonexistent")
            .expect("should not error");
        assert!(result.is_none());

        cleanup_dir(&dir);
    }

    #[test]
    fn set_contact_updates_existing_contact() {
        let dir = unique_temp_dir("contact_update");
        let manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        let contact1 = manager
            .set_contact("update123", Some("Original Name"), None)
            .expect("should set contact");
        let created_at = contact1.created_at;

        // Update the contact
        let contact2 = manager
            .set_contact("update123", Some("Updated Name"), Some("Updated notes"))
            .expect("should update contact");

        // created_at should be preserved
        assert_eq!(contact2.created_at, created_at);
        // updated_at should be newer
        assert!(contact2.updated_at >= contact1.updated_at);
        // Data should be updated
        assert_eq!(contact2.display_name, Some("Updated Name".to_string()));
        assert_eq!(contact2.notes, Some("Updated notes".to_string()));

        cleanup_dir(&dir);
    }

    #[test]
    fn get_all_contacts_returns_all_saved_contacts() {
        let dir = unique_temp_dir("contact_get_all");
        let manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        // Create multiple contacts
        manager
            .set_contact("contact1", Some("Alice"), None)
            .expect("should set contact");
        manager
            .set_contact("contact2", Some("Bob"), None)
            .expect("should set contact");
        manager
            .set_contact("contact3", Some("Charlie"), None)
            .expect("should set contact");

        let contacts = manager.get_all_contacts().expect("should get all contacts");

        assert_eq!(contacts.len(), 3);

        // Verify all contacts are present
        let pubkeys: Vec<String> = contacts.iter().map(|c| c.pubkey.clone()).collect();
        assert!(pubkeys.contains(&"contact1".to_string()));
        assert!(pubkeys.contains(&"contact2".to_string()));
        assert!(pubkeys.contains(&"contact3".to_string()));

        cleanup_dir(&dir);
    }

    #[test]
    fn get_all_contacts_returns_empty_when_none_exist() {
        let dir = unique_temp_dir("contact_get_all_empty");
        let manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        let contacts = manager.get_all_contacts().expect("should get all contacts");
        assert!(contacts.is_empty());

        cleanup_dir(&dir);
    }

    #[test]
    fn delete_contact_removes_contact() {
        let dir = unique_temp_dir("contact_delete");
        let manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        manager
            .set_contact("delete123", Some("To Delete"), None)
            .expect("should set contact");

        // Verify contact exists
        assert!(manager.get_contact("delete123").unwrap().is_some());

        // Delete contact
        manager
            .delete_contact("delete123")
            .expect("should delete contact");

        // Verify contact is gone
        assert!(manager.get_contact("delete123").unwrap().is_none());

        cleanup_dir(&dir);
    }

    #[test]
    fn delete_contact_nonexistent_succeeds() {
        let dir = unique_temp_dir("contact_delete_nonexistent");
        let manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        // Deleting non-existent contact should not error
        manager
            .delete_contact("nonexistent")
            .expect("should not error");

        cleanup_dir(&dir);
    }

    #[test]
    fn contact_with_unicode_display_name() {
        let dir = unique_temp_dir("contact_unicode");
        let manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        let contact = manager
            .set_contact("unicode123", Some("José García"), None)
            .expect("should set contact");

        assert_eq!(contact.display_name, Some("José García".to_string()));

        let retrieved = manager.get_contact("unicode123").unwrap().unwrap();
        assert_eq!(retrieved.display_name, Some("José García".to_string()));

        cleanup_dir(&dir);
    }

    #[test]
    fn contact_with_long_notes() {
        let dir = unique_temp_dir("contact_long_notes");
        let manager = CircleManager::new_unencrypted(&dir, &nostr::Keys::generate())
            .expect("should create manager");

        let long_notes = "This is a very long note field that contains a lot of information about the contact. It might include their background, how we met, important details to remember, and various other pieces of information that are relevant to our relationship.".to_string();

        let contact = manager
            .set_contact("notes123", Some("Person"), Some(&long_notes))
            .expect("should set contact");

        assert_eq!(contact.notes, Some(long_notes.clone()));

        let retrieved = manager.get_contact("notes123").unwrap().unwrap();
        assert_eq!(retrieved.notes, Some(long_notes));

        cleanup_dir(&dir);
    }
}

// ============================================================================
// CircleStorage Direct Tests (storage-level operations)
// ============================================================================

mod circle_storage_tests {
    use super::*;

    #[test]
    fn storage_save_and_get_circle() {
        let dir = unique_temp_dir("storage_circle");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");
        let circle = create_test_circle(1);

        storage.save_circle(&circle).expect("should save circle");

        let retrieved = storage
            .get_circle(&circle.mls_group_id)
            .expect("should get circle")
            .expect("circle should exist");

        assert_eq!(
            retrieved.mls_group_id.as_slice(),
            circle.mls_group_id.as_slice()
        );
        assert_eq!(retrieved.nostr_group_id, circle.nostr_group_id);
        assert_eq!(retrieved.display_name, circle.display_name);
        assert_eq!(retrieved.circle_type, circle.circle_type);

        cleanup_dir(&dir);
    }

    #[test]
    fn storage_save_circle_with_direct_share_type() {
        let dir = unique_temp_dir("storage_direct_share");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");
        let circle = Circle {
            circle_type: CircleType::DirectShare,
            ..create_test_circle(1)
        };

        storage.save_circle(&circle).expect("should save circle");

        let retrieved = storage.get_circle(&circle.mls_group_id).unwrap().unwrap();
        assert_eq!(retrieved.circle_type, CircleType::DirectShare);

        cleanup_dir(&dir);
    }

    #[test]
    #[allow(clippy::similar_names)] // circle1, circle2, circle3 are intentionally similar
    fn storage_get_all_circles_ordered_by_updated_at() {
        let dir = unique_temp_dir("storage_all_ordered");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");

        // Create circles with different updated_at timestamps
        let circle1 = Circle {
            updated_at: 1_000_000,
            ..create_test_circle(1)
        };
        let circle2 = Circle {
            updated_at: 3_000_000,
            ..create_test_circle(2)
        };
        let circle3 = Circle {
            updated_at: 2_000_000,
            ..create_test_circle(3)
        };

        storage.save_circle(&circle1).unwrap();
        storage.save_circle(&circle2).unwrap();
        storage.save_circle(&circle3).unwrap();

        let circles = storage.get_all_circles().unwrap();
        assert_eq!(circles.len(), 3);

        // Should be ordered by updated_at DESC
        assert_eq!(circles[0].updated_at, 3_000_000);
        assert_eq!(circles[1].updated_at, 2_000_000);
        assert_eq!(circles[2].updated_at, 1_000_000);

        cleanup_dir(&dir);
    }

    #[test]
    fn storage_delete_circle_removes_related_data() {
        let dir = unique_temp_dir("storage_delete");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");
        let circle = create_test_circle(1);
        let membership = create_test_membership(1, MembershipStatus::Accepted);
        let ui_state = CircleUiState {
            mls_group_id: GroupId::from_slice(&[1; 32]),
            last_read_message_id: Some("msg123".to_string()),
            pin_order: Some(1),
            is_muted: false,
        };

        // Save all related data
        storage.save_circle(&circle).unwrap();
        storage.save_membership(&membership).unwrap();
        storage.save_ui_state(&ui_state).unwrap();

        // Delete circle
        storage.delete_circle(&circle.mls_group_id).unwrap();

        // Verify all related data is deleted
        assert!(storage.get_circle(&circle.mls_group_id).unwrap().is_none());
        assert!(storage
            .get_membership(&circle.mls_group_id)
            .unwrap()
            .is_none());
        assert!(storage
            .get_ui_state(&circle.mls_group_id)
            .unwrap()
            .is_none());

        cleanup_dir(&dir);
    }

    #[test]
    fn storage_save_and_get_membership() {
        let dir = unique_temp_dir("storage_membership");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");
        let circle = create_test_circle(1);
        let membership = create_test_membership(1, MembershipStatus::Pending);

        storage.save_circle(&circle).unwrap();
        storage.save_membership(&membership).unwrap();

        let retrieved = storage
            .get_membership(&membership.mls_group_id)
            .unwrap()
            .unwrap();

        assert_eq!(retrieved.status, MembershipStatus::Pending);
        assert_eq!(retrieved.inviter_pubkey, membership.inviter_pubkey);
        assert_eq!(retrieved.invited_at, membership.invited_at);
        assert!(retrieved.responded_at.is_none());

        cleanup_dir(&dir);
    }

    #[test]
    fn storage_update_membership_status() {
        let dir = unique_temp_dir("storage_update_status");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");
        let circle = create_test_circle(1);
        let membership = create_test_membership(1, MembershipStatus::Pending);

        storage.save_circle(&circle).unwrap();
        storage.save_membership(&membership).unwrap();

        let now = 3_000_000_i64;
        storage
            .update_membership_status(
                &membership.mls_group_id,
                MembershipStatus::Accepted,
                Some(now),
            )
            .unwrap();

        let retrieved = storage
            .get_membership(&membership.mls_group_id)
            .unwrap()
            .unwrap();

        assert_eq!(retrieved.status, MembershipStatus::Accepted);
        assert_eq!(retrieved.responded_at, Some(now));

        cleanup_dir(&dir);
    }

    #[test]
    fn storage_update_membership_status_to_declined() {
        let dir = unique_temp_dir("storage_decline");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");
        let circle = create_test_circle(1);
        let membership = create_test_membership(1, MembershipStatus::Pending);

        storage.save_circle(&circle).unwrap();
        storage.save_membership(&membership).unwrap();

        let now = 3_000_000_i64;
        storage
            .update_membership_status(
                &membership.mls_group_id,
                MembershipStatus::Declined,
                Some(now),
            )
            .unwrap();

        let retrieved = storage
            .get_membership(&membership.mls_group_id)
            .unwrap()
            .unwrap();

        assert_eq!(retrieved.status, MembershipStatus::Declined);
        assert_eq!(retrieved.responded_at, Some(now));

        cleanup_dir(&dir);
    }

    #[test]
    fn storage_update_membership_status_nonexistent_fails() {
        let dir = unique_temp_dir("storage_update_nonexistent");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");

        let result = storage.update_membership_status(
            &GroupId::from_slice(&[99; 32]),
            MembershipStatus::Accepted,
            None,
        );

        assert!(result.is_err());

        cleanup_dir(&dir);
    }

    #[test]
    fn storage_save_and_get_ui_state() {
        let dir = unique_temp_dir("storage_ui_state");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");
        let circle = create_test_circle(1);
        let ui_state = CircleUiState {
            mls_group_id: GroupId::from_slice(&[1; 32]),
            last_read_message_id: Some("msg123".to_string()),
            pin_order: Some(5),
            is_muted: true,
        };

        storage.save_circle(&circle).unwrap();
        storage.save_ui_state(&ui_state).unwrap();

        let retrieved = storage
            .get_ui_state(&ui_state.mls_group_id)
            .unwrap()
            .unwrap();

        assert_eq!(retrieved.last_read_message_id, Some("msg123".to_string()));
        assert_eq!(retrieved.pin_order, Some(5));
        assert!(retrieved.is_muted);

        cleanup_dir(&dir);
    }

    #[test]
    fn storage_ui_state_with_minimal_data() {
        let dir = unique_temp_dir("storage_ui_minimal");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");
        let circle = create_test_circle(1);
        let ui_state = CircleUiState {
            mls_group_id: GroupId::from_slice(&[1; 32]),
            last_read_message_id: None,
            pin_order: None,
            is_muted: false,
        };

        storage.save_circle(&circle).unwrap();
        storage.save_ui_state(&ui_state).unwrap();

        let retrieved = storage
            .get_ui_state(&ui_state.mls_group_id)
            .unwrap()
            .unwrap();

        assert!(retrieved.last_read_message_id.is_none());
        assert!(retrieved.pin_order.is_none());
        assert!(!retrieved.is_muted);

        cleanup_dir(&dir);
    }

    #[test]
    fn storage_save_ui_state_updates_existing() {
        let dir = unique_temp_dir("storage_ui_update");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");
        let circle = create_test_circle(1);
        let mut ui_state = CircleUiState {
            mls_group_id: GroupId::from_slice(&[1; 32]),
            last_read_message_id: Some("msg123".to_string()),
            pin_order: Some(5),
            is_muted: false,
        };

        storage.save_circle(&circle).unwrap();
        storage.save_ui_state(&ui_state).unwrap();

        // Update UI state
        ui_state.last_read_message_id = Some("msg456".to_string());
        ui_state.is_muted = true;
        storage.save_ui_state(&ui_state).unwrap();

        let retrieved = storage
            .get_ui_state(&ui_state.mls_group_id)
            .unwrap()
            .unwrap();

        assert_eq!(retrieved.last_read_message_id, Some("msg456".to_string()));
        assert!(retrieved.is_muted);

        cleanup_dir(&dir);
    }
}

// ============================================================================
// Invitation Flow Tests (storage-level, no MDK)
// ============================================================================

mod invitation_flow_tests {
    use super::*;

    #[test]
    fn storage_pending_membership_flow() {
        let dir = unique_temp_dir("invitation_pending");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");
        let circle = create_test_circle(1);

        // Save circle with pending membership
        let membership = CircleMembership {
            mls_group_id: circle.mls_group_id.clone(),
            status: MembershipStatus::Pending,
            inviter_pubkey: Some("inviter_pubkey_hex".to_string()),
            invited_at: 1_000_000,
            responded_at: None,
        };

        storage.save_circle(&circle).unwrap();
        storage.save_membership(&membership).unwrap();

        // Verify pending state
        let retrieved = storage
            .get_membership(&circle.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(retrieved.status, MembershipStatus::Pending);
        assert_eq!(
            retrieved.inviter_pubkey,
            Some("inviter_pubkey_hex".to_string())
        );
        assert!(retrieved.responded_at.is_none());

        cleanup_dir(&dir);
    }

    #[test]
    fn storage_accept_invitation_updates_status() {
        let dir = unique_temp_dir("invitation_accept");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");
        let circle = create_test_circle(1);
        let membership = create_test_membership(1, MembershipStatus::Pending);

        storage.save_circle(&circle).unwrap();
        storage.save_membership(&membership).unwrap();

        // Accept invitation
        let now = 2_000_000_i64;
        storage
            .update_membership_status(&circle.mls_group_id, MembershipStatus::Accepted, Some(now))
            .unwrap();

        let updated = storage
            .get_membership(&circle.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(updated.status, MembershipStatus::Accepted);
        assert_eq!(updated.responded_at, Some(now));

        cleanup_dir(&dir);
    }

    #[test]
    fn storage_decline_invitation_updates_status() {
        let dir = unique_temp_dir("invitation_decline");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");
        let circle = create_test_circle(1);
        let membership = create_test_membership(1, MembershipStatus::Pending);

        storage.save_circle(&circle).unwrap();
        storage.save_membership(&membership).unwrap();

        // Decline invitation
        let now = 2_000_000_i64;
        storage
            .update_membership_status(&circle.mls_group_id, MembershipStatus::Declined, Some(now))
            .unwrap();

        let updated = storage
            .get_membership(&circle.mls_group_id)
            .unwrap()
            .unwrap();
        assert_eq!(updated.status, MembershipStatus::Declined);
        assert_eq!(updated.responded_at, Some(now));

        cleanup_dir(&dir);
    }

    #[test]
    fn storage_multiple_pending_invitations() {
        let dir = unique_temp_dir("invitation_multiple");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");

        // Create multiple circles with pending invitations
        for id in 1..=3 {
            let circle = create_test_circle(id);
            let membership = create_test_membership(id, MembershipStatus::Pending);

            storage.save_circle(&circle).unwrap();
            storage.save_membership(&membership).unwrap();
        }

        // Verify all circles exist
        let circles = storage.get_all_circles().unwrap();
        assert_eq!(circles.len(), 3);

        // Verify all memberships are pending
        for circle in circles {
            let membership = storage
                .get_membership(&circle.mls_group_id)
                .unwrap()
                .unwrap();
            assert_eq!(membership.status, MembershipStatus::Pending);
        }

        cleanup_dir(&dir);
    }
}

// ============================================================================
// CircleConfig Builder Tests
// ============================================================================

mod circle_config_tests {
    use super::*;

    #[test]
    fn config_new_creates_default() {
        let config = CircleConfig::new("Test Circle");

        assert_eq!(config.name, "Test Circle");
        assert!(config.description.is_none());
        assert_eq!(config.circle_type, CircleType::LocationSharing);
        assert!(config.relays.is_empty());
    }

    #[test]
    fn config_with_description() {
        let config = CircleConfig::new("Family").with_description("Family circle");

        assert_eq!(config.name, "Family");
        assert_eq!(config.description, Some("Family circle".to_string()));
    }

    #[test]
    fn config_with_type() {
        let config = CircleConfig::new("Direct").with_type(CircleType::DirectShare);

        assert_eq!(config.circle_type, CircleType::DirectShare);
    }

    #[test]
    fn config_with_relay() {
        let config = CircleConfig::new("Circle").with_relay("wss://relay.example.com");

        assert_eq!(config.relays.len(), 1);
        assert_eq!(config.relays[0], "wss://relay.example.com");
    }

    #[test]
    fn config_with_multiple_relays() {
        let config = CircleConfig::new("Circle")
            .with_relay("wss://relay1.example.com")
            .with_relay("wss://relay2.example.com")
            .with_relay("wss://relay3.example.com");

        assert_eq!(config.relays.len(), 3);
        assert_eq!(config.relays[0], "wss://relay1.example.com");
        assert_eq!(config.relays[2], "wss://relay3.example.com");
    }

    #[test]
    fn config_with_relays_from_vec() {
        let relays = vec![
            "wss://relay1.com".to_string(),
            "wss://relay2.com".to_string(),
        ];
        let config = CircleConfig::new("Circle").with_relays(relays);

        assert_eq!(config.relays.len(), 2);
    }

    #[test]
    fn config_builder_chain() {
        let config = CircleConfig::new("My Circle")
            .with_description("A test circle")
            .with_type(CircleType::DirectShare)
            .with_relay("wss://relay1.com")
            .with_relays(["wss://relay2.com", "wss://relay3.com"]);

        assert_eq!(config.name, "My Circle");
        assert_eq!(config.description, Some("A test circle".to_string()));
        assert_eq!(config.circle_type, CircleType::DirectShare);
        assert_eq!(config.relays.len(), 3);
    }

    #[test]
    fn config_with_unicode_name() {
        let config = CircleConfig::new("Familie Müller").with_description("Deutsche Familie");

        assert_eq!(config.name, "Familie Müller");
        assert_eq!(config.description, Some("Deutsche Familie".to_string()));
    }
}

// ============================================================================
// MembershipStatus Visibility Tests
// ============================================================================

mod membership_status_tests {
    use super::*;

    #[test]
    fn pending_is_not_visible() {
        // Pending invitations are shown via the invitations provider,
        // not in the circle list.
        assert!(!MembershipStatus::Pending.is_visible());
    }

    #[test]
    fn accepted_is_visible() {
        assert!(MembershipStatus::Accepted.is_visible());
    }

    #[test]
    fn declined_is_not_visible() {
        assert!(!MembershipStatus::Declined.is_visible());
    }

    #[test]
    fn storage_get_visible_filters_declined() {
        let dir = unique_temp_dir("status_visible");
        let db_path = dir.join("test.db");
        std::fs::create_dir_all(&dir).unwrap();

        let storage = CircleStorage::new(&db_path, None).expect("should create storage");

        // Create circles with different membership statuses
        for (id, status) in [
            (1, MembershipStatus::Pending),
            (2, MembershipStatus::Accepted),
            (3, MembershipStatus::Declined),
        ] {
            let circle = create_test_circle(id);
            let membership = create_test_membership(id, status);

            storage.save_circle(&circle).unwrap();
            storage.save_membership(&membership).unwrap();
        }

        // Get all circles
        let all_circles = storage.get_all_circles().unwrap();
        assert_eq!(all_circles.len(), 3);

        // Filter to visible only (accepted only, not pending or declined)
        let visible_count = all_circles
            .iter()
            .filter(|c| {
                storage
                    .get_membership(&c.mls_group_id)
                    .unwrap()
                    .is_some_and(|m| m.status.is_visible())
            })
            .count();

        assert_eq!(visible_count, 1);

        cleanup_dir(&dir);
    }
}

// ============================================================================
// MLS-dependent Tests (using real MDK with unencrypted storage)
// ============================================================================

mod mls_dependent_tests {
    //! Dark Matter (DM-5a) re-expression of the MLS-dependent circle tests.
    //!
    //! Ported to the async `CircleManager`/`SessionManager` idiom (manager
    //! identity == sender keys; KeyPackages via the DM-2b maintenance builder).
    //! Subject-gone tests are DELETED with a note: the `self_update_*` /
    //! `groups_needing_self_update_*` families (engine owns convergence, no
    //! `self_update`); `admin_handoff_transfers_admin_*` (`propose_admin_handoff`
    //! is a documented GAP — no admin-policy codec in v0.9.4); the basic
    //! create/add/remove/get-member/invitation/finalize/clear tests (covered by
    //! the `src/circle/manager.rs` inline suite). The UNIQUE, high-value coverage
    //! kept + re-expressed here is the welcome-delivery cascade, the create_circle
    //! relay defaulting, and the two crown-jewel cross-party gates: forward
    //! secrecy on removal (RC-1) and add/remove convergence (RC-3/RC-4).

    use super::*;

    use haven_core::nostr::mls::types::LocationMessageResult;
    use haven_core::relay::maintenance::build_kp_maintenance_events;
    use nostr::Keys;

    // ── Construction helpers (manager identity == its keys) ───────────────────

    fn make_manager(prefix: &str) -> (CircleManager, Keys, PathBuf) {
        let dir = unique_temp_dir(prefix);
        let keys = Keys::generate();
        let manager =
            CircleManager::new_unencrypted(&dir, &keys).expect("should create circle manager");
        (manager, keys, dir)
    }

    /// Mints a signed kind-30443 KeyPackage event for `manager` (whose identity
    /// MUST be `keys`), via the real DM-2b publish path.
    async fn kp_event(manager: &CircleManager, keys: &Keys, relays: &[String]) -> nostr::Event {
        build_kp_maintenance_events(manager.session(), keys, relays, None)
            .await
            .expect("build key package event")
            .event
    }

    fn member(kp: nostr::Event, inbox: Vec<String>, nip65: Vec<String>) -> MemberKeyPackage {
        MemberKeyPackage {
            key_package_event: kp,
            inbox_relays: inbox,
            nip65_relays: nip65,
        }
    }

    // ── KeyPackage validity / uniqueness ──────────────────────────────────────

    #[tokio::test]
    async fn fresh_key_package_content_is_strict_base64_and_parses() {
        use base64::Engine as _;
        let (bob, bob_keys, bob_dir) = make_manager("mls_kp_bob");
        let relays = vec!["wss://relay.example.com".to_string()];
        let bob_kp = kp_event(&bob, &bob_keys, &relays).await;

        // (1) Strict base64 STANDARD — the exact production encoding.
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(&bob_kp.content)
            .expect("KeyPackage content MUST be strict base64 (STANDARD alphabet)");
        assert!(!decoded.is_empty(), "decoded KeyPackage bytes non-empty");

        // (2) A genuine KeyPackage: Alice creates a circle with Bob's event,
        // which forces the engine to parse + validate it. One welcome proves it.
        let (alice, alice_keys, alice_dir) = make_manager("mls_kp_alice");
        let members = vec![member(bob_kp, relays.clone(), vec![])];
        let config = CircleConfig::new("KP Validity Test")
            .with_type(CircleType::LocationSharing)
            .with_relays(relays.clone());
        let result = alice
            .create_circle(&alice_keys, members, &config, &relays)
            .await
            .expect("create_circle must accept a genuine KeyPackage");
        assert_eq!(result.welcome_events.len(), 1);

        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
    }

    #[tokio::test]
    async fn fresh_key_packages_are_unique() {
        let (mgr, keys, dir) = make_manager("mls_kp_unique");
        let relays = vec!["wss://relay.example.com".to_string()];
        let a = kp_event(&mgr, &keys, &relays).await;
        let b = kp_event(&mgr, &keys, &relays).await;
        assert_ne!(
            a.content, b.content,
            "each KeyPackage must contain unique MLS key material"
        );
        cleanup_dir(&dir);
    }

    // ── Two-party setup + join helpers ────────────────────────────────────────

    struct TwoPartyCircleSetup {
        alice_manager: CircleManager,
        alice_keys: Keys,
        alice_dir: PathBuf,
        bob_manager: CircleManager,
        bob_keys: Keys,
        bob_dir: PathBuf,
        result: CircleCreationResult,
    }

    impl TwoPartyCircleSetup {
        fn cleanup(&self) {
            cleanup_dir(&self.alice_dir);
            cleanup_dir(&self.bob_dir);
        }
    }

    /// Alice creates a circle inviting Bob (not yet confirmed/joined).
    async fn setup_circle_with_invite(prefix: &str) -> TwoPartyCircleSetup {
        let relays = vec!["wss://relay.test.com".to_string()];
        let (alice_manager, alice_keys, alice_dir) = make_manager(&format!("{prefix}_alice"));
        let (bob_manager, bob_keys, bob_dir) = make_manager(&format!("{prefix}_bob"));

        let bob_kp = kp_event(&bob_manager, &bob_keys, &relays).await;
        let members = vec![member(bob_kp, relays.clone(), vec![])];
        let config = CircleConfig::new("Two Party")
            .with_type(CircleType::LocationSharing)
            .with_relays(relays.clone());
        let result = alice_manager
            .create_circle(&alice_keys, members, &config, &relays)
            .await
            .expect("create circle");

        TwoPartyCircleSetup {
            alice_manager,
            alice_keys,
            alice_dir,
            bob_manager,
            bob_keys,
            bob_dir,
            result,
        }
    }

    /// Bob holds + accepts the gift-wrapped welcome to join.
    async fn activate_joiner(
        joiner: &CircleManager,
        joiner_keys: &Keys,
        welcome: &GiftWrappedWelcome,
    ) {
        joiner
            .process_gift_wrapped_invitation(joiner_keys, &welcome.event)
            .await
            .expect("joiner holds welcome");
        joiner
            .accept_invitation(&welcome.event.id)
            .await
            .expect("joiner accepts welcome");
    }

    fn sentinel_location(lat: f64, lon: f64) -> haven_core::location::LocationMessage {
        haven_core::location::LocationMessage::new(lat, lon)
    }

    /// Encrypts a location and returns the publishable kind-445 event.
    async fn encrypt_location_event(
        manager: &CircleManager,
        keys: &Keys,
        group_id: &GroupId,
        lat: f64,
        lon: f64,
    ) -> nostr::Event {
        let loc = sentinel_location(lat, lon);
        let (event, _ngid, _relays) = manager
            .encrypt_location(group_id, &keys.public_key(), &loc, 60)
            .await
            .expect("encrypt location");
        event
    }

    /// Asserts `receiver.decrypt_location(event)` yields a Location from
    /// `sender_keys` decoding to `(lat, lon)`.
    async fn assert_decrypts_to_location(
        receiver: &CircleManager,
        event: &nostr::Event,
        sender_keys: &Keys,
        lat: f64,
        lon: f64,
    ) {
        let results = receiver
            .decrypt_location(event)
            .await
            .expect("decrypt location");
        let (sender, content) = results
            .iter()
            .find_map(|r| match r {
                LocationMessageResult::Location {
                    sender_pubkey,
                    content,
                    ..
                } => Some((sender_pubkey.clone(), content.clone())),
                _ => None,
            })
            .unwrap_or_else(|| panic!("expected a Location result, got {results:?}"));
        assert_eq!(sender, sender_keys.public_key().to_hex());
        let decoded = haven_core::location::LocationMessage::from_string(&content).expect("parse");
        assert!((decoded.latitude - lat).abs() < 1e-9);
        assert!((decoded.longitude - lon).abs() < 1e-9);
    }

    async fn member_hex_set(manager: &CircleManager, group_id: &GroupId) -> Vec<String> {
        let mut v: Vec<String> = manager
            .get_members(group_id)
            .await
            .expect("get members")
            .into_iter()
            .map(|m| m.pubkey)
            .collect();
        v.sort();
        v
    }

    // ── Three-party active circle (Alice admin + Bob + Charlie) ───────────────

    struct ThreePartyActiveCircle {
        alice_manager: CircleManager,
        alice_keys: Keys,
        alice_dir: PathBuf,
        bob_manager: CircleManager,
        bob_keys: Keys,
        bob_dir: PathBuf,
        charlie_manager: CircleManager,
        charlie_keys: Keys,
        charlie_dir: PathBuf,
        group_id: GroupId,
    }

    impl ThreePartyActiveCircle {
        fn cleanup(&self) {
            cleanup_dir(&self.alice_dir);
            cleanup_dir(&self.bob_dir);
            cleanup_dir(&self.charlie_dir);
        }
    }

    async fn setup_three_party_active_circle(prefix: &str) -> ThreePartyActiveCircle {
        let relays = vec!["wss://relay.test.com".to_string()];
        let (alice_manager, alice_keys, alice_dir) = make_manager(&format!("{prefix}_alice"));
        let (bob_manager, bob_keys, bob_dir) = make_manager(&format!("{prefix}_bob"));
        let (charlie_manager, charlie_keys, charlie_dir) =
            make_manager(&format!("{prefix}_charlie"));

        let bob_kp = kp_event(&bob_manager, &bob_keys, &relays).await;
        let charlie_kp = kp_event(&charlie_manager, &charlie_keys, &relays).await;
        let members = vec![
            member(bob_kp, relays.clone(), vec![]),
            member(charlie_kp, relays.clone(), vec![]),
        ];
        let config = CircleConfig::new("Three Party Active")
            .with_type(CircleType::LocationSharing)
            .with_relays(relays.clone());
        let result = alice_manager
            .create_circle(&alice_keys, members, &config, &relays)
            .await
            .expect("create three-party circle");
        let group_id = result.circle.mls_group_id.clone();
        alice_manager
            .confirm_published(result.pending)
            .await
            .expect("alice confirms creation");

        for w in &result.welcome_events {
            let (joiner, jkeys) = if w.recipient_pubkey == bob_keys.public_key().to_hex() {
                (&bob_manager, &bob_keys)
            } else {
                (&charlie_manager, &charlie_keys)
            };
            activate_joiner(joiner, jkeys, w).await;
        }

        ThreePartyActiveCircle {
            alice_manager,
            alice_keys,
            alice_dir,
            bob_manager,
            bob_keys,
            bob_dir,
            charlie_manager,
            charlie_keys,
            charlie_dir,
            group_id,
        }
    }

    // ── create_circle + join smoke ────────────────────────────────────────────

    #[tokio::test]
    async fn create_circle_and_bob_joins() {
        let s = setup_circle_with_invite("create_join").await;
        let group_id = s.result.circle.mls_group_id.clone();
        s.alice_manager
            .confirm_published(s.result.pending)
            .await
            .expect("alice confirms creation");
        activate_joiner(&s.bob_manager, &s.bob_keys, &s.result.welcome_events[0]).await;

        assert_eq!(
            member_hex_set(&s.alice_manager, &group_id).await,
            member_hex_set(&s.bob_manager, &group_id).await,
            "alice and bob converge on the same member set"
        );
        assert_eq!(member_hex_set(&s.alice_manager, &group_id).await.len(), 2);
        s.cleanup();
    }

    #[tokio::test]
    async fn plan_leave_nonadmin_returns_nonadmin() {
        let s = setup_circle_with_invite("plan_leave_nonadmin").await;
        let group_id = s.result.circle.mls_group_id.clone();
        s.alice_manager
            .confirm_published(s.result.pending)
            .await
            .unwrap();
        activate_joiner(&s.bob_manager, &s.bob_keys, &s.result.welcome_events[0]).await;

        let plan = s
            .bob_manager
            .plan_leave(&group_id, &s.bob_keys.public_key())
            .await
            .expect("plan_leave");
        assert!(matches!(plan, LeavePlan::NonAdmin));
        s.cleanup();
    }

    #[tokio::test]
    async fn plan_leave_sole_admin_with_peer_returns_handoff() {
        let s = setup_circle_with_invite("plan_leave_admin").await;
        let group_id = s.result.circle.mls_group_id.clone();
        s.alice_manager
            .confirm_published(s.result.pending)
            .await
            .unwrap();
        activate_joiner(&s.bob_manager, &s.bob_keys, &s.result.welcome_events[0]).await;

        let plan = s
            .alice_manager
            .plan_leave(&group_id, &s.alice_keys.public_key())
            .await
            .expect("plan_leave");
        assert!(matches!(plan, LeavePlan::AdminHandoff { .. }));
        s.cleanup();
    }

    // DELETED-WITH-SUBJECT: `admin_handoff_transfers_admin_and_group_stays_usable`
    // — `propose_admin_handoff`/`propose_self_demote` are a documented GAP (no
    // admin-policy component codec in v0.9.4); the inline suite asserts the GAP
    // error. `self_update_produces_evolution_event_*`, `self_update_rollback_*`,
    // `groups_needing_self_update_reflects_rotation_state` — the engine owns
    // convergence; `self_update` is deleted. `manager_finalize_pending_commit` /
    // `clear_pending_commit_rolls_back_*` — re-expressed as
    // `confirm_published`/`publish_failed` in the inline suite.

    // ── Welcome-delivery cascade (UNIQUE integration coverage) ────────────────

    /// Creates a one-member circle with the given member relay lists and returns
    /// that member's welcome `recipient_relays`.
    async fn welcome_relays_for(
        inbox_relays: Vec<String>,
        nip65_relays: Vec<String>,
    ) -> Vec<String> {
        let relays = vec!["wss://relay.test.com".to_string()];
        let (alice, alice_keys, alice_dir) = make_manager("cascade_alice");
        let (bob, bob_keys, bob_dir) = make_manager("cascade_bob");
        let bob_kp = kp_event(&bob, &bob_keys, &relays).await;
        let members = vec![member(bob_kp, inbox_relays, nip65_relays)];
        let config = CircleConfig::new("Cascade Test")
            .with_type(CircleType::LocationSharing)
            .with_relays(relays);
        let result = alice
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect("create circle");
        assert_eq!(result.welcome_events.len(), 1);
        let out = result.welcome_events[0].recipient_relays.clone();
        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
        out
    }

    #[tokio::test]
    async fn cascade_uses_inbox_relays_when_present() {
        let inbox = vec![
            "wss://inbox1.example.com".to_string(),
            "wss://inbox2.example.com".to_string(),
        ];
        let relays =
            welcome_relays_for(inbox.clone(), vec!["wss://nip65.example.com".to_string()]).await;
        assert_eq!(relays, inbox);
    }

    #[tokio::test]
    async fn cascade_uses_nip65_when_inbox_empty() {
        let nip65 = vec![
            "wss://nip65-1.example.com".to_string(),
            "wss://nip65-2.example.com".to_string(),
        ];
        let relays = welcome_relays_for(vec![], nip65.clone()).await;
        assert_eq!(relays, nip65, "fall back to NIP-65 when inbox is empty");
    }

    #[tokio::test]
    async fn cascade_inbox_takes_priority_over_nip65() {
        let inbox = vec!["wss://inbox-priority.example.com".to_string()];
        let relays = welcome_relays_for(
            inbox.clone(),
            vec!["wss://nip65-nouse.example.com".to_string()],
        )
        .await;
        assert_eq!(relays, inbox);
        assert!(!relays.iter().any(|r| r.contains("nip65-nouse")));
    }

    #[tokio::test]
    async fn cascade_uses_creator_fallback_when_member_empty() {
        let relays = vec!["wss://relay.test.com".to_string()];
        let (alice, alice_keys, alice_dir) = make_manager("cascade_fb_alice");
        let (bob, bob_keys, bob_dir) = make_manager("cascade_fb_bob");
        let bob_kp = kp_event(&bob, &bob_keys, &relays).await;
        let members = vec![member(bob_kp, vec![], vec![])];
        let config = CircleConfig::new("Creator Fallback")
            .with_type(CircleType::LocationSharing)
            .with_relays(relays);
        let creator_inbox = vec!["wss://creator-inbox.example.com".to_string()];
        let result = alice
            .create_circle(&alice_keys, members, &config, &creator_inbox)
            .await
            .expect("create via creator fallback");
        assert_eq!(result.welcome_events[0].recipient_relays, creator_inbox);
        for d in haven_core::circle::PRODUCTION_DEFAULT_RELAYS {
            assert!(!result.welcome_events[0]
                .recipient_relays
                .iter()
                .any(|r| r.starts_with(d)));
        }
        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
    }

    #[tokio::test]
    async fn cascade_fails_closed_when_all_empty() {
        let relays = vec!["wss://relay.test.com".to_string()];
        let (alice, alice_keys, alice_dir) = make_manager("cascade_fc_alice");
        let (bob, bob_keys, bob_dir) = make_manager("cascade_fc_bob");
        let bob_kp = kp_event(&bob, &bob_keys, &relays).await;
        let members = vec![member(bob_kp, vec![], vec![])];
        let config = CircleConfig::new("Fail Closed")
            .with_type(CircleType::LocationSharing)
            .with_relays(relays);
        let err = alice
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect_err("must fail closed when no delivery relay exists");
        assert!(matches!(
            err,
            haven_core::circle::CircleError::MissingWelcomeRelays
        ));
        let msg = err.to_string();
        for d in haven_core::circle::PRODUCTION_DEFAULT_RELAYS {
            assert!(
                !msg.contains(d),
                "fail-closed error must not mention a default relay"
            );
        }
        assert!(
            alice.get_circles().await.expect("get_circles").is_empty(),
            "fail-closed create_circle must persist no circle"
        );
        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
    }

    #[tokio::test]
    async fn cascade_multi_member_independent_resolution() {
        let relays = vec!["wss://relay.test.com".to_string()];
        let (alice, alice_keys, alice_dir) = make_manager("cascade_multi_alice");
        let (bob, bob_keys, bob_dir) = make_manager("cascade_multi_bob");
        let (charlie, charlie_keys, charlie_dir) = make_manager("cascade_multi_charlie");
        let bob_kp = kp_event(&bob, &bob_keys, &relays).await;
        let charlie_kp = kp_event(&charlie, &charlie_keys, &relays).await;

        let bob_inbox = vec!["wss://bob-inbox.example.com".to_string()];
        let charlie_nip65 = vec!["wss://charlie-nip65.example.com".to_string()];
        let members = vec![
            member(bob_kp, bob_inbox.clone(), vec![]),
            member(charlie_kp, vec![], charlie_nip65.clone()),
        ];
        let config = CircleConfig::new("Multi-Member Cascade")
            .with_type(CircleType::LocationSharing)
            .with_relays(relays);
        let result = alice
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect("create circle");
        assert_eq!(result.welcome_events.len(), 2);

        let bob_w = result
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == bob_keys.public_key().to_hex())
            .expect("bob welcome");
        assert_eq!(bob_w.recipient_relays, bob_inbox);
        let charlie_w = result
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == charlie_keys.public_key().to_hex())
            .expect("charlie welcome");
        assert_eq!(charlie_w.recipient_relays, charlie_nip65);

        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
        cleanup_dir(&charlie_dir);
    }

    #[tokio::test]
    async fn cascade_inbox_relays_differ_from_keypackage_relays() {
        let kp_relays = vec!["wss://kp-discovery.example.com".to_string()];
        let inbox_relays = vec!["wss://inbox-delivery.example.com".to_string()];
        let (alice, alice_keys, alice_dir) = make_manager("cascade_distinct_alice");
        let (bob, bob_keys, bob_dir) = make_manager("cascade_distinct_bob");
        // KeyPackage minted with the discovery relays; delivery uses inbox relays.
        let bob_kp = kp_event(&bob, &bob_keys, &kp_relays).await;
        let members = vec![member(bob_kp, inbox_relays.clone(), vec![])];
        let config = CircleConfig::new("Distinct Relay Test")
            .with_type(CircleType::LocationSharing)
            .with_relays(kp_relays.clone());
        let result = alice
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect("create circle");
        assert_eq!(result.welcome_events[0].recipient_relays, inbox_relays);
        assert!(!result.welcome_events[0]
            .recipient_relays
            .iter()
            .any(|r| r.contains("kp-discovery")));
        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
    }

    // ── create_circle relay defaulting ────────────────────────────────────────

    #[tokio::test]
    async fn create_circle_uses_user_inbox_relays_when_config_empty() {
        use haven_core::circle::RelayType;
        let relays = vec!["wss://relay.test.com".to_string()];
        let (alice, alice_keys, alice_dir) = make_manager("subst_inbox");
        alice.seed_relay_defaults_if_unseeded().expect("seed");
        alice
            .add_user_relay("wss://alice-custom-inbox.example.com", RelayType::Inbox)
            .expect("add inbox");
        alice
            .add_user_relay("wss://alice-kp-only.example.com", RelayType::KeyPackage)
            .expect("add kp");

        let (bob, bob_keys, bob_dir) = make_manager("subst_inbox_bob");
        let bob_kp = kp_event(&bob, &bob_keys, &relays).await;
        let members = vec![member(
            bob_kp,
            vec!["wss://bob-inbox.example.com".to_string()],
            vec![],
        )];
        let config = CircleConfig::new("Subst Inbox").with_type(CircleType::LocationSharing);
        assert!(config.relays.is_empty());

        let result = alice
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect("create circle");
        let alice_inbox = alice
            .list_user_relays(RelayType::Inbox)
            .expect("list inbox");
        assert_eq!(result.circle.relays, alice_inbox);
        assert!(result
            .circle
            .relays
            .iter()
            .any(|u| u.contains("alice-custom-inbox")));
        assert!(!result
            .circle
            .relays
            .iter()
            .any(|u| u.contains("alice-kp-only")));
        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
    }

    #[tokio::test]
    async fn create_circle_falls_back_to_defaults_when_user_inbox_empty() {
        let relays = vec!["wss://relay.test.com".to_string()];
        let (alice, alice_keys, alice_dir) = make_manager("subst_defaults");
        // Intentionally NOT seeding relay defaults — leave Inbox empty.
        let (bob, bob_keys, bob_dir) = make_manager("subst_defaults_bob");
        let bob_kp = kp_event(&bob, &bob_keys, &relays).await;
        let members = vec![member(
            bob_kp,
            vec!["wss://bob-inbox.example.com".to_string()],
            vec![],
        )];
        let config = CircleConfig::new("Subst Defaults").with_type(CircleType::LocationSharing);
        assert!(config.relays.is_empty());

        let result = alice
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect("create via defensive fallback");
        let expected: Vec<String> = haven_core::circle::PRODUCTION_DEFAULT_RELAYS
            .iter()
            .map(|s| (*s).to_string())
            .collect();
        assert_eq!(result.circle.relays, expected);
        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
    }

    #[tokio::test]
    async fn create_circle_uses_explicit_relays_when_provided() {
        use haven_core::circle::RelayType;
        let (alice, alice_keys, alice_dir) = make_manager("explicit_relays");
        alice.seed_relay_defaults_if_unseeded().expect("seed");
        alice
            .add_user_relay("wss://alice-inbox.example.com", RelayType::Inbox)
            .expect("add inbox");
        let (bob, bob_keys, bob_dir) = make_manager("explicit_relays_bob");
        let bob_kp = kp_event(&bob, &bob_keys, &["wss://bob.example.com".to_string()]).await;
        let members = vec![member(
            bob_kp,
            vec!["wss://bob-inbox.example.com".to_string()],
            vec![],
        )];
        let explicit = vec!["wss://explicit-only.example.com".to_string()];
        let config = CircleConfig::new("Explicit Relays")
            .with_type(CircleType::LocationSharing)
            .with_relays(explicit.clone());
        let result = alice
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect("create circle");
        assert_eq!(result.circle.relays, explicit);
        assert!(!result
            .circle
            .relays
            .iter()
            .any(|u| u.contains("alice-inbox")));
        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
    }

    // ── Crown jewels: forward secrecy + convergence ───────────────────────────

    /// RC-1 (forward secrecy): after Alice removes Bob and confirms the removal
    /// commit, a FRESH location Alice encrypts at the new epoch MUST be
    /// undecryptable by the evicted Bob, while remaining member Charlie decrypts
    /// it. `exporter_secret` retention is engine-internal now, so this is
    /// asserted purely through observable decrypt outcomes.
    #[tokio::test]
    async fn removed_member_cannot_decrypt_post_removal_location() {
        let c = setup_three_party_active_circle("fs_removal").await;

        // Baseline: while Bob is a member, both he and Charlie decrypt Alice's
        // location (proving the later failure is caused by the removal).
        let pre =
            encrypt_location_event(&c.alice_manager, &c.alice_keys, &c.group_id, 40.0, -70.0).await;
        assert_decrypts_to_location(&c.bob_manager, &pre, &c.alice_keys, 40.0, -70.0).await;
        assert_decrypts_to_location(&c.charlie_manager, &pre, &c.alice_keys, 40.0, -70.0).await;

        let epoch_before = c.alice_manager.group_epoch(&c.group_id).await.unwrap();

        // Alice removes Bob and confirms — rotates to a new epoch excluding Bob.
        let removal = c
            .alice_manager
            .remove_members(&c.group_id, &[c.bob_keys.public_key().to_hex()])
            .await
            .expect("alice removes bob");
        c.alice_manager
            .confirm_published(removal.pending)
            .await
            .expect("alice confirms removal");
        let epoch_after = c.alice_manager.group_epoch(&c.group_id).await.unwrap();
        assert!(
            epoch_after > epoch_before,
            "removing a member MUST advance the epoch (forward-secrecy boundary)"
        );

        // Charlie applies the removal commit and converges to the new epoch.
        c.charlie_manager
            .decrypt_location(&removal.commit_event)
            .await
            .expect("charlie processes removal");
        assert_eq!(
            c.charlie_manager.group_epoch(&c.group_id).await.unwrap(),
            epoch_after,
            "Charlie must converge to Alice's post-removal epoch"
        );

        // Alice encrypts a FRESH location at the new epoch.
        let post =
            encrypt_location_event(&c.alice_manager, &c.alice_keys, &c.group_id, 41.0, -71.0).await;

        // (1) The evicted Bob MUST NOT recover plaintext — any non-Location
        //     outcome (empty/Stale/error) is the correct secure result.
        let bob_results = c.bob_manager.decrypt_location(&post).await;
        if let Ok(results) = &bob_results {
            assert!(
                !results
                    .iter()
                    .any(|r| matches!(r, LocationMessageResult::Location { .. })),
                "FORWARD SECRECY VIOLATION: removed member decrypted a post-removal location"
            );
        }

        // (2) Charlie (remaining) still decrypts at the new epoch.
        assert_decrypts_to_location(&c.charlie_manager, &post, &c.alice_keys, 41.0, -71.0).await;

        // (3) Alice's roster: no Bob, still Charlie.
        let alice_members = member_hex_set(&c.alice_manager, &c.group_id).await;
        assert!(!alice_members.contains(&c.bob_keys.public_key().to_hex()));
        assert!(alice_members.contains(&c.charlie_keys.public_key().to_hex()));

        c.cleanup();
    }

    /// RC-3 (cross-party convergence) + RC-4 (usable == cross-party decrypt):
    /// Bob processes Alice's add and remove commits and converges to the SAME
    /// member set AND epoch as Alice, and decrypts a post-commit location.
    #[tokio::test]
    async fn peer_converges_on_member_set_and_epoch_after_commits() {
        let s = setup_circle_with_invite("converge").await;
        let group_id = s.result.circle.mls_group_id.clone();
        s.alice_manager
            .confirm_published(s.result.pending)
            .await
            .unwrap();
        activate_joiner(&s.bob_manager, &s.bob_keys, &s.result.welcome_events[0]).await;

        assert_eq!(
            s.alice_manager.group_epoch(&group_id).await.unwrap(),
            s.bob_manager.group_epoch(&group_id).await.unwrap(),
            "alice and bob start on the same epoch"
        );

        // --- ADD Charlie ---
        let (charlie, charlie_keys, charlie_dir) = make_manager("converge_charlie");
        let relays = vec!["wss://relay.test.com".to_string()];
        let charlie_kp = kp_event(&charlie, &charlie_keys, &relays).await;
        let add = s
            .alice_manager
            .add_members_with_welcomes(
                &s.alice_keys,
                &group_id,
                vec![member(charlie_kp, relays.clone(), vec![])],
                &relays,
            )
            .await
            .expect("alice adds charlie");
        assert_eq!(add.commit_event.kind, nostr::Kind::Custom(445));
        s.alice_manager
            .confirm_published(add.pending)
            .await
            .expect("confirm add");

        let bob_add = s
            .bob_manager
            .decrypt_location(&add.commit_event)
            .await
            .expect("bob processes add");
        assert!(bob_add
            .iter()
            .any(|r| matches!(r, LocationMessageResult::GroupUpdate { .. })));
        assert_eq!(
            s.alice_manager.group_epoch(&group_id).await.unwrap(),
            s.bob_manager.group_epoch(&group_id).await.unwrap(),
            "epochs converge after the add"
        );
        assert_eq!(
            member_hex_set(&s.alice_manager, &group_id).await,
            member_hex_set(&s.bob_manager, &group_id).await,
        );
        assert_eq!(member_hex_set(&s.alice_manager, &group_id).await.len(), 3);

        // --- REMOVE Charlie ---
        let remove = s
            .alice_manager
            .remove_members(&group_id, &[charlie_keys.public_key().to_hex()])
            .await
            .expect("alice removes charlie");
        assert_eq!(remove.commit_event.kind, nostr::Kind::Custom(445));
        s.alice_manager
            .confirm_published(remove.pending)
            .await
            .expect("confirm remove");

        let bob_remove = s
            .bob_manager
            .decrypt_location(&remove.commit_event)
            .await
            .expect("bob processes remove");
        assert!(bob_remove
            .iter()
            .any(|r| matches!(r, LocationMessageResult::GroupUpdate { .. })));
        assert_eq!(
            s.alice_manager.group_epoch(&group_id).await.unwrap(),
            s.bob_manager.group_epoch(&group_id).await.unwrap(),
            "epochs converge after the remove"
        );
        assert_eq!(
            member_hex_set(&s.alice_manager, &group_id).await,
            member_hex_set(&s.bob_manager, &group_id).await,
        );

        // RC-4: Bob decrypts a post-commit location from Alice.
        let post =
            encrypt_location_event(&s.alice_manager, &s.alice_keys, &group_id, 12.5, 34.5).await;
        assert_decrypts_to_location(&s.bob_manager, &post, &s.alice_keys, 12.5, 34.5).await;

        cleanup_dir(&charlie_dir);
        s.cleanup();
    }
}
