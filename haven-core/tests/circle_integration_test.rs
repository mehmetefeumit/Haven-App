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
    CircleType, CircleUiState, Contact, LeavePlan, MemberKeyPackage, MembershipStatus,
};
use haven_core::nostr::mls::types::GroupId;

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
            "wss://relay.nostr.wine".to_string(),
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
        avatar_path: Some(format!("/path/to/avatar_{id}.jpg")),
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

        let _manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

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

        let _manager = CircleManager::new_unencrypted(&nested_dir).expect("should create manager");

        assert!(nested_dir.exists());
        assert!(nested_dir.join("circles.db").exists());

        cleanup_dir(&base_dir);
    }

    #[test]
    fn manager_new_with_existing_directory() {
        let dir = unique_temp_dir("mgr_existing");
        std::fs::create_dir_all(&dir).unwrap();

        let _manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        assert!(dir.exists());
        assert!(dir.join("circles.db").exists());

        cleanup_dir(&dir);
    }

    #[test]
    fn manager_multiple_instances_same_directory() {
        let dir = unique_temp_dir("mgr_multi_instance");

        let manager1 = CircleManager::new_unencrypted(&dir).expect("should create first manager");
        let circles1 = manager1.get_circles().expect("should get circles");
        assert!(circles1.is_empty());

        // Create second manager pointing to same directory
        let manager2 = CircleManager::new_unencrypted(&dir).expect("should create second manager");
        let circles2 = manager2.get_circles().expect("should get circles");
        assert!(circles2.is_empty());

        cleanup_dir(&dir);
    }

    #[test]
    fn manager_get_circles_returns_empty_initially() {
        let dir = unique_temp_dir("mgr_empty_circles");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        let circles = manager.get_circles().expect("should get circles");
        assert!(circles.is_empty());

        cleanup_dir(&dir);
    }

    #[test]
    fn manager_get_visible_circles_returns_empty_initially() {
        let dir = unique_temp_dir("mgr_empty_visible");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        let circles = manager
            .get_visible_circles()
            .expect("should get visible circles");
        assert!(circles.is_empty());

        cleanup_dir(&dir);
    }

    #[test]
    fn manager_get_circle_nonexistent_returns_none() {
        let dir = unique_temp_dir("mgr_get_none");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        let fake_id = GroupId::from_slice(&[99; 32]);
        let result = manager.get_circle(&fake_id).expect("should not error");
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
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        let contact = manager
            .set_contact(
                "abc123",
                Some("Alice"),
                Some("/path/to/avatar.jpg"),
                Some("Friend from work"),
            )
            .expect("should set contact");

        assert_eq!(contact.pubkey, "abc123");
        assert_eq!(contact.display_name, Some("Alice".to_string()));
        assert_eq!(contact.avatar_path, Some("/path/to/avatar.jpg".to_string()));
        assert_eq!(contact.notes, Some("Friend from work".to_string()));
        assert!(contact.created_at > 0);
        assert!(contact.updated_at > 0);

        cleanup_dir(&dir);
    }

    #[test]
    fn set_contact_with_minimal_data() {
        let dir = unique_temp_dir("contact_minimal");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        let contact = manager
            .set_contact("pubkey123", Some("Bob"), None, None)
            .expect("should set contact");

        assert_eq!(contact.pubkey, "pubkey123");
        assert_eq!(contact.display_name, Some("Bob".to_string()));
        assert!(contact.avatar_path.is_none());
        assert!(contact.notes.is_none());

        cleanup_dir(&dir);
    }

    #[test]
    fn set_contact_with_no_display_name() {
        let dir = unique_temp_dir("contact_no_name");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        let contact = manager
            .set_contact("pubkey456", None, Some("/avatar.png"), None)
            .expect("should set contact");

        assert_eq!(contact.pubkey, "pubkey456");
        assert!(contact.display_name.is_none());
        assert_eq!(contact.avatar_path, Some("/avatar.png".to_string()));

        cleanup_dir(&dir);
    }

    #[test]
    fn get_contact_retrieves_saved_contact() {
        let dir = unique_temp_dir("contact_get");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        manager
            .set_contact(
                "xyz789",
                Some("Charlie"),
                Some("/avatar.jpg"),
                Some("Neighbor"),
            )
            .expect("should set contact");

        let retrieved = manager
            .get_contact("xyz789")
            .expect("should get contact")
            .expect("contact should exist");

        assert_eq!(retrieved.pubkey, "xyz789");
        assert_eq!(retrieved.display_name, Some("Charlie".to_string()));
        assert_eq!(retrieved.avatar_path, Some("/avatar.jpg".to_string()));
        assert_eq!(retrieved.notes, Some("Neighbor".to_string()));

        cleanup_dir(&dir);
    }

    #[test]
    fn get_contact_nonexistent_returns_none() {
        let dir = unique_temp_dir("contact_get_none");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        let result = manager
            .get_contact("nonexistent")
            .expect("should not error");
        assert!(result.is_none());

        cleanup_dir(&dir);
    }

    #[test]
    fn set_contact_updates_existing_contact() {
        let dir = unique_temp_dir("contact_update");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        let contact1 = manager
            .set_contact("update123", Some("Original Name"), None, None)
            .expect("should set contact");
        let created_at = contact1.created_at;

        // Update the contact
        let contact2 = manager
            .set_contact(
                "update123",
                Some("Updated Name"),
                Some("/new_avatar.jpg"),
                Some("Updated notes"),
            )
            .expect("should update contact");

        // created_at should be preserved
        assert_eq!(contact2.created_at, created_at);
        // updated_at should be newer
        assert!(contact2.updated_at >= contact1.updated_at);
        // Data should be updated
        assert_eq!(contact2.display_name, Some("Updated Name".to_string()));
        assert_eq!(contact2.avatar_path, Some("/new_avatar.jpg".to_string()));
        assert_eq!(contact2.notes, Some("Updated notes".to_string()));

        cleanup_dir(&dir);
    }

    #[test]
    fn get_all_contacts_returns_all_saved_contacts() {
        let dir = unique_temp_dir("contact_get_all");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        // Create multiple contacts
        manager
            .set_contact("contact1", Some("Alice"), None, None)
            .expect("should set contact");
        manager
            .set_contact("contact2", Some("Bob"), None, None)
            .expect("should set contact");
        manager
            .set_contact("contact3", Some("Charlie"), None, None)
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
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        let contacts = manager.get_all_contacts().expect("should get all contacts");
        assert!(contacts.is_empty());

        cleanup_dir(&dir);
    }

    #[test]
    fn delete_contact_removes_contact() {
        let dir = unique_temp_dir("contact_delete");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        manager
            .set_contact("delete123", Some("To Delete"), None, None)
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
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        // Deleting non-existent contact should not error
        manager
            .delete_contact("nonexistent")
            .expect("should not error");

        cleanup_dir(&dir);
    }

    #[test]
    fn contact_with_unicode_display_name() {
        let dir = unique_temp_dir("contact_unicode");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        let contact = manager
            .set_contact("unicode123", Some("José García"), None, None)
            .expect("should set contact");

        assert_eq!(contact.display_name, Some("José García".to_string()));

        let retrieved = manager.get_contact("unicode123").unwrap().unwrap();
        assert_eq!(retrieved.display_name, Some("José García".to_string()));

        cleanup_dir(&dir);
    }

    #[test]
    fn contact_with_long_notes() {
        let dir = unique_temp_dir("contact_long_notes");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        let long_notes = "This is a very long note field that contains a lot of information about the contact. It might include their background, how we met, important details to remember, and various other pieces of information that are relevant to our relationship.".to_string();

        let contact = manager
            .set_contact("notes123", Some("Person"), None, Some(&long_notes))
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
    use super::*;

    use nostr::{EventBuilder, Keys, Kind};

    // ------------------------------------------------------------------
    // Key package tests (no CircleManager::create_circle needed)
    // ------------------------------------------------------------------

    #[test]
    fn manager_create_key_package_with_valid_identity() {
        let dir = unique_temp_dir("mls_create_kp");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        // Use a real valid secp256k1 pubkey (generator point)
        let valid_pubkey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

        let bundle = manager
            .create_key_package(valid_pubkey, &["wss://relay.example.com".to_string()])
            .expect("should create key package");

        // Verify the bundle contains content and tags
        assert!(
            !bundle.content.is_empty(),
            "Key package content must not be empty"
        );
        assert!(
            !bundle.tags_443.is_empty(),
            "Key package tags (kind 443) must not be empty"
        );
        assert!(
            !bundle.tags_30443.is_empty(),
            "Key package tags (kind 30443) must not be empty"
        );
        assert_eq!(bundle.relays.len(), 1);
        assert_eq!(bundle.relays[0], "wss://relay.example.com");

        cleanup_dir(&dir);
    }

    #[test]
    fn manager_create_key_package_content_is_valid_hex() {
        let dir = unique_temp_dir("mls_kp_hex");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        let valid_pubkey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

        let bundle = manager
            .create_key_package(valid_pubkey, &["wss://relay.example.com".to_string()])
            .expect("should create key package");

        // Content should be valid hex (MLS key package bytes)
        assert!(
            hex::decode(&bundle.content).is_ok()
                || base64::Engine::decode(
                    &base64::engine::general_purpose::STANDARD,
                    &bundle.content
                )
                .is_ok(),
            "Key package content should be valid hex or base64 encoding"
        );

        cleanup_dir(&dir);
    }

    #[test]
    fn manager_create_key_package_multiple_relays() {
        let dir = unique_temp_dir("mls_kp_multi_relay");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        let valid_pubkey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
        let relays = vec![
            "wss://relay1.example.com".to_string(),
            "wss://relay2.example.com".to_string(),
        ];

        let bundle = manager
            .create_key_package(valid_pubkey, &relays)
            .expect("should create key package");

        assert_eq!(bundle.relays.len(), 2);

        cleanup_dir(&dir);
    }

    #[test]
    fn manager_create_key_package_produces_unique_packages() {
        let dir = unique_temp_dir("mls_kp_unique");
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

        let valid_pubkey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
        let relays = vec!["wss://relay.example.com".to_string()];

        let bundle1 = manager
            .create_key_package(valid_pubkey, &relays)
            .expect("should create key package 1");
        let bundle2 = manager
            .create_key_package(valid_pubkey, &relays)
            .expect("should create key package 2");

        // Each key package should be unique (different MLS key material)
        assert_ne!(
            bundle1.content, bundle2.content,
            "Each key package should contain unique MLS key material"
        );

        cleanup_dir(&dir);
    }

    // ------------------------------------------------------------------
    // CircleManager full lifecycle tests (create_circle and beyond)
    // ------------------------------------------------------------------

    /// Helper: Creates a signed key package event (kind 443) using a
    /// `CircleManager` (which wraps `MdkManager` privately).
    fn create_kp_event_from_circle_manager(
        manager: &CircleManager,
        keys: &Keys,
        relays: &[String],
    ) -> nostr::Event {
        let pubkey_hex = keys.public_key().to_hex();
        let bundle = manager
            .create_key_package(&pubkey_hex, relays)
            .expect("should create key package");

        let tags: Vec<nostr::Tag> = bundle
            .tags_443
            .into_iter()
            .map(|tag_vec| nostr::Tag::parse(&tag_vec).expect("should parse tag"))
            .collect();

        EventBuilder::new(Kind::MlsKeyPackage, bundle.content)
            .tags(tags)
            .sign_with_keys(keys)
            .expect("should sign key package event")
    }

    /// Result of the reusable two-party `CircleManager` setup.
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

    /// Reusable async helper: creates two `CircleManager` instances,
    /// generates Bob's key package, and has Alice create a circle
    /// inviting Bob.
    async fn setup_circle_with_invite(prefix: &str) -> TwoPartyCircleSetup {
        let relays = vec!["wss://relay.test.com".to_string()];

        let alice_dir = unique_temp_dir(&format!("{prefix}_alice"));
        let alice_manager =
            CircleManager::new_unencrypted(&alice_dir).expect("should create alice manager");
        let alice_keys = Keys::generate();

        let bob_dir = unique_temp_dir(&format!("{prefix}_bob"));
        let bob_manager =
            CircleManager::new_unencrypted(&bob_dir).expect("should create bob manager");
        let bob_keys = Keys::generate();

        // Bob creates a key package
        let bob_kp_event = create_kp_event_from_circle_manager(&bob_manager, &bob_keys, &relays);

        let members = vec![MemberKeyPackage {
            key_package_event: bob_kp_event,
            inbox_relays: relays.clone(),
            nip65_relays: vec![],
        }];

        let config = CircleConfig::new("Test Circle")
            .with_type(CircleType::LocationSharing)
            .with_relays(relays);

        let result = alice_manager
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect("should create circle");

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

    #[tokio::test]
    async fn manager_create_circle() {
        let setup = setup_circle_with_invite("create_circle").await;

        // Verify the circle has the correct name and type
        assert_eq!(setup.result.circle.display_name, "Test Circle");
        assert_eq!(setup.result.circle.circle_type, CircleType::LocationSharing);

        // Verify one welcome event was generated for Bob
        assert_eq!(
            setup.result.welcome_events.len(),
            1,
            "Should have one welcome for Bob"
        );
        assert_eq!(
            setup.result.welcome_events[0].recipient_pubkey,
            setup.bob_keys.public_key().to_hex()
        );

        // Verify the circle is stored with Accepted status
        let circles = setup
            .alice_manager
            .get_circles()
            .expect("should get circles");
        assert_eq!(circles.len(), 1);
        assert_eq!(circles[0].circle.display_name, "Test Circle");
        assert_eq!(circles[0].membership.status, MembershipStatus::Accepted);

        setup.cleanup();
    }

    #[tokio::test]
    async fn manager_plan_leave_admin_with_peers_returns_handoff() {
        let setup = setup_circle_with_invite("plan_leave_admin_with_peers").await;
        let group_id = setup.result.circle.mls_group_id.clone();

        // Finalize the pending commit so the group is fully active.
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize pending commit");

        // Bob is already in the MLS tree (added at create_circle time), so
        // Alice's plan is AdminHandoff with Bob as successor.
        let plan = setup
            .alice_manager
            .plan_leave(&group_id, &setup.alice_keys.public_key())
            .expect("plan_leave should succeed");
        match plan {
            LeavePlan::AdminHandoff { successor } => {
                assert_eq!(
                    successor,
                    setup.bob_keys.public_key(),
                    "sole admin with one peer should hand off to that peer",
                );
            }
            other => panic!("expected AdminHandoff, got {other:?}"),
        }

        setup.cleanup();
    }

    #[tokio::test]
    async fn manager_abandon_circle_local_only_sole_member() {
        let setup = setup_circle_with_invite("abandon_sole_member").await;
        let group_id = setup.result.circle.mls_group_id.clone();
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("finalize");

        // Remove Bob so Alice is truly alone in the MLS tree.
        setup
            .alice_manager
            .remove_members(&group_id, &[setup.bob_keys.public_key().to_hex()])
            .expect("remove bob");
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("finalize removal");

        // plan_leave reports Abandon once Alice is the sole member.
        let plan = setup
            .alice_manager
            .plan_leave(&group_id, &setup.alice_keys.public_key())
            .expect("plan_leave");
        assert!(matches!(plan, LeavePlan::Abandon));

        // Abandon clears only local storage — MDK orphan state is tolerated
        // because no MLS operation can succeed with a sole admin / sole member.
        setup
            .alice_manager
            .abandon_circle_local_only(&group_id)
            .expect("abandon should succeed for sole member");

        let circles = setup.alice_manager.get_circles().expect("get circles");
        assert!(circles.is_empty(), "abandon should remove local row");

        setup.cleanup();
    }

    #[tokio::test]
    async fn manager_plan_leave_nonadmin_returns_nonadmin() {
        // Alice creates the circle and Bob joins. Bob is a non-admin member
        // and his plan_leave should be `NonAdmin`.
        let setup = setup_circle_with_invite("plan_leave_nonadmin").await;
        let group_id = setup.result.circle.mls_group_id.clone();
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("finalize alice commit");

        // Bob processes the welcome so he is an active group member.
        let welcome_event = setup.result.welcome_events.first().expect("welcome event");
        let invitation = setup
            .bob_manager
            .process_gift_wrapped_invitation(&setup.bob_keys, &welcome_event.event)
            .await
            .expect("bob processes invite");
        setup
            .bob_manager
            .accept_invitation(&invitation.mls_group_id)
            .expect("bob accepts");

        let plan = setup
            .bob_manager
            .plan_leave(&invitation.mls_group_id, &setup.bob_keys.public_key())
            .expect("plan_leave");
        assert!(matches!(plan, LeavePlan::NonAdmin));

        setup.cleanup();
    }

    #[tokio::test]
    async fn manager_add_members() {
        let setup = setup_circle_with_invite("add_members").await;
        let group_id = setup.result.circle.mls_group_id.clone();

        // Finalize Alice's pending commit from circle creation
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize pending commit");

        // Create Charlie with a separate CircleManager
        let charlie_dir = unique_temp_dir("add_members_charlie");
        let charlie_manager =
            CircleManager::new_unencrypted(&charlie_dir).expect("should create charlie manager");
        let charlie_keys = Keys::generate();
        let relays = vec!["wss://relay.test.com".to_string()];

        let charlie_kp =
            create_kp_event_from_circle_manager(&charlie_manager, &charlie_keys, &relays);

        // Alice adds Charlie
        setup
            .alice_manager
            .add_members(&group_id, &[charlie_kp])
            .expect("should add charlie");

        // Finalize the add-member commit
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize add commit");

        // Verify 3 members: Alice, Bob, Charlie
        let members = setup
            .alice_manager
            .get_members(&group_id)
            .expect("should get members");
        assert_eq!(
            members.len(),
            3,
            "Should have 3 members after adding Charlie"
        );

        cleanup_dir(&charlie_dir);
        setup.cleanup();
    }

    #[tokio::test]
    async fn manager_remove_members() {
        let setup = setup_circle_with_invite("remove_members").await;
        let group_id = setup.result.circle.mls_group_id.clone();

        // Finalize Alice's pending commit from circle creation
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize pending commit");

        // Alice removes Bob
        let bob_pubkey = setup.bob_keys.public_key().to_hex();
        setup
            .alice_manager
            .remove_members(&group_id, &[bob_pubkey])
            .expect("should remove bob");

        // Finalize the remove-member commit
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize remove commit");

        // Verify only Alice remains
        let members = setup
            .alice_manager
            .get_members(&group_id)
            .expect("should get members");
        assert_eq!(members.len(), 1, "Should have 1 member after removing Bob");
        assert_eq!(members[0].pubkey, setup.alice_keys.public_key().to_hex());

        setup.cleanup();
    }

    #[tokio::test]
    async fn manager_get_members() {
        let setup = setup_circle_with_invite("get_members").await;
        let group_id = setup.result.circle.mls_group_id.clone();

        // Finalize Alice's pending commit from circle creation
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize pending commit");

        let members = setup
            .alice_manager
            .get_members(&group_id)
            .expect("should get members");

        assert_eq!(members.len(), 2, "Should have Alice and Bob");

        let alice_hex = setup.alice_keys.public_key().to_hex();
        let bob_hex = setup.bob_keys.public_key().to_hex();

        let alice_member = members
            .iter()
            .find(|m| m.pubkey == alice_hex)
            .expect("Alice should be a member");
        let bob_member = members
            .iter()
            .find(|m| m.pubkey == bob_hex)
            .expect("Bob should be a member");

        assert!(alice_member.is_admin, "Alice should be admin (creator)");
        assert!(!bob_member.is_admin, "Bob should not be admin");

        setup.cleanup();
    }

    #[tokio::test]
    async fn manager_process_invitation() {
        let setup = setup_circle_with_invite("process_invite").await;

        // Finalize Alice's pending commit so the group is active
        setup
            .alice_manager
            .finalize_pending_commit(&setup.result.circle.mls_group_id)
            .expect("should finalize pending commit");

        // Bob processes the gift-wrapped welcome
        let gift_wrap = &setup.result.welcome_events[0];
        let invitation = setup
            .bob_manager
            .process_gift_wrapped_invitation(&setup.bob_keys, &gift_wrap.event)
            .await
            .expect("should process invitation");

        // Verify the invitation metadata (name extracted from Welcome)
        assert_eq!(invitation.circle_name, "Test Circle");
        assert_eq!(
            invitation.inviter_pubkey,
            setup.alice_keys.public_key().to_hex()
        );

        // Verify it shows in pending invitations
        let pending = setup
            .bob_manager
            .get_pending_invitations()
            .expect("should get pending");
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].circle_name, "Test Circle");

        setup.cleanup();
    }

    #[tokio::test]
    async fn manager_accept_invitation() {
        let setup = setup_circle_with_invite("accept_invite").await;
        let group_id = setup.result.circle.mls_group_id.clone();

        // Finalize Alice's pending commit
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize pending commit");

        // Bob processes the gift-wrapped welcome
        let gift_wrap = &setup.result.welcome_events[0];
        let invitation = setup
            .bob_manager
            .process_gift_wrapped_invitation(&setup.bob_keys, &gift_wrap.event)
            .await
            .expect("should process invitation");

        // Bob accepts the invitation
        let circle_with_members = setup
            .bob_manager
            .accept_invitation(&invitation.mls_group_id)
            .expect("should accept invitation");

        assert_eq!(circle_with_members.circle.display_name, "Test Circle");
        assert_eq!(
            circle_with_members.membership.status,
            MembershipStatus::Accepted
        );

        // No more pending invitations
        let pending = setup
            .bob_manager
            .get_pending_invitations()
            .expect("should get pending");
        assert!(pending.is_empty(), "No pending invitations after accepting");

        setup.cleanup();
    }

    #[tokio::test]
    async fn manager_decline_invitation() {
        let setup = setup_circle_with_invite("decline_invite").await;
        let group_id = setup.result.circle.mls_group_id.clone();

        // Finalize Alice's pending commit
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize pending commit");

        // Bob processes the gift-wrapped welcome
        let gift_wrap = &setup.result.welcome_events[0];
        let invitation = setup
            .bob_manager
            .process_gift_wrapped_invitation(&setup.bob_keys, &gift_wrap.event)
            .await
            .expect("should process invitation");

        // Bob declines the invitation
        setup
            .bob_manager
            .decline_invitation(&invitation.mls_group_id)
            .expect("should decline invitation");

        // No pending invitations
        let pending = setup
            .bob_manager
            .get_pending_invitations()
            .expect("should get pending");
        assert!(pending.is_empty(), "No pending invitations after declining");

        // Not in visible circles
        let visible = setup
            .bob_manager
            .get_visible_circles()
            .expect("should get visible circles");
        assert!(visible.is_empty(), "Declined circle should not be visible");

        setup.cleanup();
    }

    #[tokio::test]
    async fn manager_finalize_pending_commit() {
        let setup = setup_circle_with_invite("finalize_commit").await;
        let group_id = setup.result.circle.mls_group_id.clone();

        // Finalize Alice's pending commit from create_circle
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize pending commit");

        // Add Charlie
        let charlie_dir = unique_temp_dir("finalize_commit_charlie");
        let charlie_manager =
            CircleManager::new_unencrypted(&charlie_dir).expect("should create charlie manager");
        let charlie_keys = Keys::generate();
        let relays = vec!["wss://relay.test.com".to_string()];

        let charlie_kp =
            create_kp_event_from_circle_manager(&charlie_manager, &charlie_keys, &relays);

        // Alice adds Charlie (creates a pending commit)
        setup
            .alice_manager
            .add_members(&group_id, &[charlie_kp])
            .expect("should add charlie");

        // Finalize the pending commit
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize add commit");

        // Verify 3 members after finalization
        let members = setup
            .alice_manager
            .get_members(&group_id)
            .expect("should get members");
        assert_eq!(
            members.len(),
            3,
            "Should have 3 members after finalizing add commit"
        );

        cleanup_dir(&charlie_dir);
        setup.cleanup();
    }

    #[tokio::test]
    async fn clear_pending_commit_rolls_back_and_group_remains_usable() {
        let setup = setup_circle_with_invite("clear_pending").await;
        let group_id = setup.result.circle.mls_group_id.clone();

        // Finalize Alice's pending commit from create_circle so the group is active
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize creation commit");

        // Record member count before the add (Alice + Bob = 2)
        let members_before = setup
            .alice_manager
            .get_members(&group_id)
            .expect("should get members before add");
        assert_eq!(
            members_before.len(),
            2,
            "Should have 2 members (Alice + Bob) before add"
        );

        // Create Charlie with a separate CircleManager
        let charlie_dir = unique_temp_dir("clear_pending_charlie");
        let charlie_manager =
            CircleManager::new_unencrypted(&charlie_dir).expect("should create charlie manager");
        let charlie_keys = Keys::generate();
        let relays = vec!["wss://relay.test.com".to_string()];

        let charlie_kp =
            create_kp_event_from_circle_manager(&charlie_manager, &charlie_keys, &relays);

        // Alice adds Charlie — this creates a pending commit
        setup
            .alice_manager
            .add_members(&group_id, &[charlie_kp.clone()])
            .expect("should add charlie (pending)");

        // Instead of finalizing, CLEAR (rollback) the pending commit
        setup
            .alice_manager
            .clear_pending_commit(&group_id)
            .expect("should clear pending commit");

        // Verify rollback: Charlie is NOT in the group
        let members_after_clear = setup
            .alice_manager
            .get_members(&group_id)
            .expect("should get members after clear");
        assert_eq!(
            members_after_clear.len(),
            2,
            "Should still have 2 members after clearing pending commit (Charlie rolled back)"
        );

        // Verify the group is still usable: Alice can add Charlie again
        let charlie_kp2 =
            create_kp_event_from_circle_manager(&charlie_manager, &charlie_keys, &relays);

        setup
            .alice_manager
            .add_members(&group_id, &[charlie_kp2])
            .expect("should add charlie again after rollback");

        // This time, finalize the commit
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize add commit after rollback");

        // Verify 3 members: Alice, Bob, Charlie
        let members_final = setup
            .alice_manager
            .get_members(&group_id)
            .expect("should get members after finalized add");
        assert_eq!(
            members_final.len(),
            3,
            "Should have 3 members after successfully re-adding Charlie"
        );

        cleanup_dir(&charlie_dir);
        setup.cleanup();
    }

    /// Self-update produces a kind 445 evolution event and the group remains
    /// usable after the pending commit is finalized.
    #[tokio::test]
    async fn self_update_produces_evolution_event_and_group_remains_usable() {
        let setup = setup_circle_with_invite("self_update").await;
        let group_id = setup.result.circle.mls_group_id.clone();

        // Finalize Alice's pending commit from create_circle
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize creation commit");

        // Perform self-update — creates a pending commit
        let update_result = setup
            .alice_manager
            .self_update(&group_id)
            .expect("should perform self-update");

        // Evolution event should be a kind 445 event
        assert_eq!(
            update_result.evolution_event.kind,
            nostr::Kind::Custom(445),
            "Self-update evolution event should be kind 445"
        );

        // Self-update should not produce welcome events
        assert!(
            update_result.welcome_rumors.is_none()
                || update_result.welcome_rumors.as_ref().unwrap().is_empty(),
            "Self-update should not produce welcome events"
        );

        // Merge the pending commit
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize self-update commit");

        // Verify group is still usable: Alice can still get members
        let members = setup
            .alice_manager
            .get_members(&group_id)
            .expect("should get members after self-update");
        assert_eq!(
            members.len(),
            2,
            "Should still have 2 members after self-update"
        );

        setup.cleanup();
    }

    /// Self-update can be rolled back via clear_pending_commit without
    /// bricking the group.
    #[tokio::test]
    async fn self_update_rollback_leaves_group_usable() {
        let setup = setup_circle_with_invite("self_update_rollback").await;
        let group_id = setup.result.circle.mls_group_id.clone();

        // Finalize Alice's pending commit from create_circle
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize creation commit");

        // Perform self-update then roll it back
        setup
            .alice_manager
            .self_update(&group_id)
            .expect("should perform self-update");

        setup
            .alice_manager
            .clear_pending_commit(&group_id)
            .expect("should clear self-update pending commit");

        // Verify group is still usable after rollback
        let members = setup
            .alice_manager
            .get_members(&group_id)
            .expect("should get members after self-update rollback");
        assert_eq!(
            members.len(),
            2,
            "Should still have 2 members after self-update rollback"
        );

        // Can perform self-update again after rollback
        let retry_result = setup
            .alice_manager
            .self_update(&group_id)
            .expect("should perform self-update after rollback");

        assert_eq!(
            retry_result.evolution_event.kind,
            nostr::Kind::Custom(445),
            "Retry self-update should produce kind 445 event"
        );

        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize retry self-update");

        setup.cleanup();
    }

    /// `groups_needing_self_update` returns a group after welcome acceptance
    /// (Required state) and no longer returns it after a self-update is
    /// finalized (CompletedAt state).
    #[tokio::test]
    async fn groups_needing_self_update_reflects_rotation_state() {
        let setup = setup_circle_with_invite("groups_needing_update").await;
        let group_id = setup.result.circle.mls_group_id.clone();

        // Finalize Alice's pending commit from create_circle.
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize creation commit");

        // Alice created the group → NotRequired. She should NOT appear.
        let needing = setup
            .alice_manager
            .groups_needing_self_update(3600)
            .expect("should query groups needing self-update");
        assert!(
            !needing.contains(&group_id),
            "Group creator should not need self-update"
        );

        // Bob processes and accepts the welcome → Required state.
        let gift_wrap = &setup.result.welcome_events[0];
        let invitation = setup
            .bob_manager
            .process_gift_wrapped_invitation(&setup.bob_keys, &gift_wrap.event)
            .await
            .expect("Bob should process invitation");
        setup
            .bob_manager
            .accept_invitation(&invitation.mls_group_id)
            .expect("Bob should accept invitation");

        // Bob accepted the welcome → Required. He SHOULD appear.
        let bob_needing = setup
            .bob_manager
            .groups_needing_self_update(3600)
            .expect("Bob should query groups needing self-update");
        assert!(
            bob_needing.contains(&group_id),
            "Bob should need self-update after joining"
        );

        // Bob performs self-update and finalizes → CompletedAt.
        setup
            .bob_manager
            .self_update(&group_id)
            .expect("Bob should perform self-update");
        setup
            .bob_manager
            .finalize_pending_commit(&group_id)
            .expect("Bob should finalize self-update commit");

        // Bob should no longer need self-update (threshold = 1 hour).
        let bob_after = setup
            .bob_manager
            .groups_needing_self_update(3600)
            .expect("Bob should query after self-update");
        assert!(
            !bob_after.contains(&group_id),
            "Bob should not need self-update after completing it"
        );

        // Threshold boundary: threshold = 0 means "everything is stale",
        // so the just-completed group should appear again.
        let bob_zero_threshold = setup
            .bob_manager
            .groups_needing_self_update(0)
            .expect("Bob should query with zero threshold");
        assert!(
            bob_zero_threshold.contains(&group_id),
            "Zero threshold should treat all groups as stale"
        );

        setup.cleanup();
    }

    // ------------------------------------------------------------------
    // Cascading relay resolution tests
    // ------------------------------------------------------------------

    /// Helper: creates a circle with a single member using the given relay lists.
    /// Returns the recipient_relays from the generated GiftWrappedWelcome.
    async fn create_circle_and_get_welcome_relays(
        inbox_relays: Vec<String>,
        nip65_relays: Vec<String>,
    ) -> Vec<String> {
        let relays = vec!["wss://relay.test.com".to_string()];

        let alice_dir = unique_temp_dir("cascade_alice");
        let alice_manager =
            CircleManager::new_unencrypted(&alice_dir).expect("should create alice manager");
        let alice_keys = Keys::generate();

        let bob_dir = unique_temp_dir("cascade_bob");
        let bob_manager =
            CircleManager::new_unencrypted(&bob_dir).expect("should create bob manager");
        let bob_keys = Keys::generate();

        let bob_kp_event = create_kp_event_from_circle_manager(&bob_manager, &bob_keys, &relays);

        let members = vec![MemberKeyPackage {
            key_package_event: bob_kp_event,
            inbox_relays,
            nip65_relays,
        }];

        let config = CircleConfig::new("Cascade Test")
            .with_type(CircleType::LocationSharing)
            .with_relays(relays);

        let result = alice_manager
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect("should create circle");

        assert_eq!(
            result.welcome_events.len(),
            1,
            "Should produce exactly one Welcome for one member"
        );
        let welcome_relays = result.welcome_events[0].recipient_relays.clone();

        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);

        welcome_relays
    }

    #[tokio::test]
    async fn cascade_uses_inbox_relays_when_present() {
        let inbox = vec![
            "wss://inbox1.example.com".to_string(),
            "wss://inbox2.example.com".to_string(),
        ];
        let nip65 = vec!["wss://nip65.example.com".to_string()];

        let relays = create_circle_and_get_welcome_relays(inbox.clone(), nip65).await;

        assert_eq!(relays, inbox, "Should use inbox relays when available");
    }

    #[tokio::test]
    async fn cascade_uses_nip65_when_inbox_empty() {
        let inbox = vec![];
        let nip65 = vec![
            "wss://nip65-1.example.com".to_string(),
            "wss://nip65-2.example.com".to_string(),
        ];

        let relays = create_circle_and_get_welcome_relays(inbox, nip65.clone()).await;

        assert_eq!(
            relays, nip65,
            "Should fall back to NIP-65 relays when inbox is empty"
        );
    }

    #[tokio::test]
    async fn cascade_uses_defaults_when_both_empty() {
        let inbox = vec![];
        let nip65 = vec![];

        let relays = create_circle_and_get_welcome_relays(inbox, nip65).await;

        // Should be exactly the DEFAULT_RELAYS from circle/types.rs
        let expected: Vec<String> = haven_core::circle::DEFAULT_RELAYS
            .iter()
            .map(|r| (*r).to_string())
            .collect();
        assert_eq!(
            relays, expected,
            "Should fall back to exact default relays when both inbox and NIP-65 are empty"
        );
    }

    #[tokio::test]
    async fn cascade_inbox_takes_priority_over_nip65() {
        let inbox = vec!["wss://inbox-priority.example.com".to_string()];
        let nip65 = vec!["wss://nip65-should-not-use.example.com".to_string()];

        let relays = create_circle_and_get_welcome_relays(inbox.clone(), nip65).await;

        assert_eq!(
            relays, inbox,
            "Inbox relays must take priority over NIP-65 relays"
        );
        assert!(
            !relays.contains(&"wss://nip65-should-not-use.example.com".to_string()),
            "NIP-65 relays must not be used when inbox relays exist"
        );
    }

    #[tokio::test]
    async fn cascade_multi_member_independent_resolution() {
        let relays = vec!["wss://relay.test.com".to_string()];

        let alice_dir = unique_temp_dir("cascade_multi_alice");
        let alice_manager =
            CircleManager::new_unencrypted(&alice_dir).expect("should create alice manager");
        let alice_keys = Keys::generate();

        // Bob has inbox relays
        let bob_dir = unique_temp_dir("cascade_multi_bob");
        let bob_manager =
            CircleManager::new_unencrypted(&bob_dir).expect("should create bob manager");
        let bob_keys = Keys::generate();
        let bob_kp = create_kp_event_from_circle_manager(&bob_manager, &bob_keys, &relays);

        // Charlie has only NIP-65 relays (no inbox)
        let charlie_dir = unique_temp_dir("cascade_multi_charlie");
        let charlie_manager =
            CircleManager::new_unencrypted(&charlie_dir).expect("should create charlie manager");
        let charlie_keys = Keys::generate();
        let charlie_kp =
            create_kp_event_from_circle_manager(&charlie_manager, &charlie_keys, &relays);

        let bob_inbox = vec!["wss://bob-inbox.example.com".to_string()];
        let charlie_nip65 = vec!["wss://charlie-nip65.example.com".to_string()];

        let members = vec![
            MemberKeyPackage {
                key_package_event: bob_kp,
                inbox_relays: bob_inbox.clone(),
                nip65_relays: vec![],
            },
            MemberKeyPackage {
                key_package_event: charlie_kp,
                inbox_relays: vec![],
                nip65_relays: charlie_nip65.clone(),
            },
        ];

        let config = CircleConfig::new("Multi-Member Cascade Test")
            .with_type(CircleType::LocationSharing)
            .with_relays(relays);

        let result = alice_manager
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect("should create circle");

        assert_eq!(result.welcome_events.len(), 2, "Should have 2 welcomes");

        // Bob's welcome should use his inbox relays
        let bob_welcome = result
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == bob_keys.public_key().to_hex())
            .expect("Should find Bob's welcome");
        assert_eq!(
            bob_welcome.recipient_relays, bob_inbox,
            "Bob should use inbox relays"
        );

        // Charlie's welcome should use his NIP-65 relays (no inbox)
        let charlie_welcome = result
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == charlie_keys.public_key().to_hex())
            .expect("Should find Charlie's welcome");
        assert_eq!(
            charlie_welcome.recipient_relays, charlie_nip65,
            "Charlie should fall back to NIP-65 relays"
        );

        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
        cleanup_dir(&charlie_dir);
    }

    /// Verifies that Welcome delivery uses inbox relays (kind 10050),
    /// not the `KeyPackage` publish relays (kind 10051). The two lists
    /// are intentionally different to catch any accidental mixing.
    #[tokio::test]
    async fn cascade_inbox_relays_differ_from_keypackage_relays() {
        // KeyPackage was published to kind 10051 relays
        let keypackage_publish_relays = vec!["wss://kp-discovery.example.com".to_string()];
        // But inbox relays (kind 10050) are different
        let inbox_relays = vec!["wss://inbox-delivery.example.com".to_string()];

        let alice_dir = unique_temp_dir("cascade_distinct_alice");
        let alice_manager =
            CircleManager::new_unencrypted(&alice_dir).expect("should create alice manager");
        let alice_keys = Keys::generate();

        let bob_dir = unique_temp_dir("cascade_distinct_bob");
        let bob_manager =
            CircleManager::new_unencrypted(&bob_dir).expect("should create bob manager");
        let bob_keys = Keys::generate();

        // KeyPackage created with kind 10051 relays (discovery path)
        let bob_kp = create_kp_event_from_circle_manager(
            &bob_manager,
            &bob_keys,
            &keypackage_publish_relays,
        );

        // But MemberKeyPackage carries kind 10050 inbox relays (delivery path)
        let members = vec![MemberKeyPackage {
            key_package_event: bob_kp,
            inbox_relays: inbox_relays.clone(),
            nip65_relays: vec![],
        }];

        let config = CircleConfig::new("Distinct Relay Test")
            .with_type(CircleType::LocationSharing)
            .with_relays(keypackage_publish_relays.clone());

        let result = alice_manager
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect("should create circle");

        assert_eq!(result.welcome_events.len(), 1);
        let welcome = &result.welcome_events[0];

        // Welcome must be delivered to inbox relays (10050), not KeyPackage relays (10051)
        assert_eq!(
            welcome.recipient_relays, inbox_relays,
            "Welcome must use inbox relays (kind 10050), not KeyPackage publish relays (kind 10051)"
        );
        assert!(
            !welcome
                .recipient_relays
                .contains(&"wss://kp-discovery.example.com".to_string()),
            "KeyPackage discovery relays must not be used for Welcome delivery"
        );

        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
    }
}
