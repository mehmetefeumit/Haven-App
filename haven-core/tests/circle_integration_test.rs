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
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

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
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

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
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

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
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

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
        let manager = CircleManager::new_unencrypted(&dir).expect("should create manager");

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

    /// RC-6: the `KeyPackage` content must be *strictly* base64-encoded
    /// (`STANDARD` alphabet, per MIP-00/MIP-02) — not merely "hex OR base64",
    /// which the old assertion satisfied for almost any blob (hex-decode
    /// accepts any even-length hex string, so the permissive OR let a garbage
    /// payload pass). We assert the exact production encoding and then prove
    /// the decoded bytes are a *real* `KeyPackage` by feeding the event into
    /// the group-creation path, which `tls_deserialize`s and cryptographically
    /// validates it via MDK's `parse_key_package`. A blob that is valid base64
    /// but not a genuine `KeyPackage` cannot produce a welcome.
    #[tokio::test]
    async fn manager_create_key_package_content_is_valid_hex() {
        use base64::Engine as _;

        let bob_dir = unique_temp_dir("mls_kp_hex_bob");
        let bob_manager = CircleManager::new_unencrypted(&bob_dir).expect("should create manager");
        let bob_keys = Keys::generate();
        let relays = vec!["wss://relay.example.com".to_string()];

        let bundle = bob_manager
            .create_key_package(&bob_keys.public_key().to_hex(), &relays)
            .expect("should create key package");

        // (1) Strict base64 STANDARD — the exact production encoding. The
        // NO_PAD / URL_SAFE alphabets and plain hex are all rejected here.
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(&bundle.content)
            .expect("KeyPackage content MUST be strict base64 (STANDARD alphabet)");
        assert!(!decoded.is_empty(), "decoded KeyPackage bytes non-empty");

        // (2) Parseable as a genuine KeyPackage: Alice creates a group using
        // Bob's event, which forces MDK's parse_key_package to deserialize and
        // validate the decoded bytes. Exactly one welcome proves it parsed.
        let alice_dir = unique_temp_dir("mls_kp_hex_alice");
        let alice_manager =
            CircleManager::new_unencrypted(&alice_dir).expect("should create alice manager");
        let alice_keys = Keys::generate();

        let bob_kp_event = create_kp_event_from_circle_manager(&bob_manager, &bob_keys, &relays);
        let members = vec![MemberKeyPackage {
            key_package_event: bob_kp_event,
            inbox_relays: relays.clone(),
            nip65_relays: vec![],
        }];
        let config = CircleConfig::new("KP Validity Test")
            .with_type(CircleType::LocationSharing)
            .with_relays(relays);

        let result = alice_manager
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect("create_circle must accept a genuine KeyPackage");
        assert_eq!(
            result.welcome_events.len(),
            1,
            "a valid KeyPackage must yield exactly one welcome (proves it parsed + validated)"
        );

        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
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

    /// Drives a joiner's `CircleManager` through the real
    /// process-then-accept welcome flow so it becomes a fully active MLS
    /// member with a local circle row (needed for `encrypt_location`). Uses
    /// only the public API — the same path the Flutter layer drives.
    async fn activate_joiner(
        joiner_manager: &CircleManager,
        joiner_keys: &Keys,
        welcome: &GiftWrappedWelcome,
    ) {
        let invitation = joiner_manager
            .process_gift_wrapped_invitation(joiner_keys, &welcome.event)
            .await
            .expect("joiner should process gift-wrapped welcome");
        joiner_manager
            .accept_invitation(&invitation.mls_group_id)
            .expect("joiner should accept invitation");
    }

    /// Finds the gift-wrapped welcome destined for `recipient` by pubkey.
    fn welcome_for<'a>(
        result: &'a CircleCreationResult,
        recipient: &Keys,
    ) -> &'a GiftWrappedWelcome {
        let hex = recipient.public_key().to_hex();
        result
            .welcome_events
            .iter()
            .find(|w| w.recipient_pubkey == hex)
            .expect("a welcome must exist for the recipient")
    }

    /// Encrypts a location from `sender` into a kind-445 event for the circle.
    ///
    /// Returns the outer event the peer will attempt to decrypt. The sentinel
    /// coordinates let cross-party tests assert the *plaintext* survived the
    /// MLS round-trip, not merely that decryption returned `Ok`.
    fn encrypt_sentinel_location(
        sender_manager: &CircleManager,
        sender_keys: &Keys,
        group_id: &GroupId,
        lat: f64,
        lon: f64,
    ) -> nostr::Event {
        let location = haven_core::location::LocationMessage::new(lat, lon);
        let (event, _ngid, _relays) = sender_manager
            .encrypt_location(group_id, &sender_keys.public_key(), &location, 300)
            .expect("sender should encrypt location");
        event
    }

    /// Decrypts a kind-445 event and asserts it is a `Location` whose
    /// coordinates match the sentinels (within geohash round-trip tolerance)
    /// and whose sender is `expected_sender`. Returns nothing on success;
    /// panics with a descriptive message otherwise. This is the
    /// "group remains usable == cross-party decrypt" check (RC-4).
    fn assert_decrypts_to_location(
        receiver_manager: &CircleManager,
        event: &nostr::Event,
        expected_sender: &Keys,
        lat: f64,
        lon: f64,
    ) {
        use haven_core::nostr::mls::types::LocationMessageResult;
        let result = receiver_manager
            .decrypt_location(event)
            .expect("receiver should process the kind-445 event without error");
        match result {
            LocationMessageResult::Location {
                sender_pubkey,
                content,
                ..
            } => {
                assert_eq!(
                    sender_pubkey,
                    expected_sender.public_key().to_hex(),
                    "decrypted sender must match the real encrypting identity"
                );
                let recovered = haven_core::location::LocationMessage::from_string(&content)
                    .expect("decrypted content must deserialize to a LocationMessage");
                assert!(
                    (recovered.latitude - lat).abs() < 1e-6,
                    "decrypted latitude must match the sentinel plaintext"
                );
                assert!(
                    (recovered.longitude - lon).abs() < 1e-6,
                    "decrypted longitude must match the sentinel plaintext"
                );
            }
            other => panic!("expected decrypted Location, got {other:?}"),
        }
    }

    /// A fully-active three-party circle (Alice admin, Bob + Charlie members),
    /// all on the same epoch, each with a local circle row. Built entirely
    /// through the public `CircleManager` API.
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

    /// Sets up a three-party circle where Bob and Charlie are both active
    /// members. Alice creates the group with both invitees, finalizes her
    /// creation commit, and each joiner processes + accepts their welcome.
    /// After this returns, all three share an identical member set and epoch
    /// and can encrypt/decrypt cross-party.
    async fn setup_three_party_active_circle(prefix: &str) -> ThreePartyActiveCircle {
        let relays = vec!["wss://relay.test.com".to_string()];

        let alice_dir = unique_temp_dir(&format!("{prefix}_alice"));
        let alice_manager = CircleManager::new_unencrypted(&alice_dir).expect("alice manager");
        let alice_keys = Keys::generate();

        let bob_dir = unique_temp_dir(&format!("{prefix}_bob"));
        let bob_manager = CircleManager::new_unencrypted(&bob_dir).expect("bob manager");
        let bob_keys = Keys::generate();

        let charlie_dir = unique_temp_dir(&format!("{prefix}_charlie"));
        let charlie_manager =
            CircleManager::new_unencrypted(&charlie_dir).expect("charlie manager");
        let charlie_keys = Keys::generate();

        let bob_kp = create_kp_event_from_circle_manager(&bob_manager, &bob_keys, &relays);
        let charlie_kp =
            create_kp_event_from_circle_manager(&charlie_manager, &charlie_keys, &relays);

        let members = vec![
            MemberKeyPackage {
                key_package_event: bob_kp,
                inbox_relays: relays.clone(),
                nip65_relays: vec![],
            },
            MemberKeyPackage {
                key_package_event: charlie_kp,
                inbox_relays: relays.clone(),
                nip65_relays: vec![],
            },
        ];

        let config = CircleConfig::new("Test Circle")
            .with_type(CircleType::LocationSharing)
            .with_relays(relays);

        let result = alice_manager
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect("should create circle");

        let group_id = result.circle.mls_group_id.clone();

        // Alice finalizes her creation commit so the group is active for her.
        alice_manager
            .finalize_pending_commit(&group_id)
            .expect("alice finalize creation commit");

        // Both joiners process + accept their welcomes.
        activate_joiner(&bob_manager, &bob_keys, welcome_for(&result, &bob_keys)).await;
        activate_joiner(
            &charlie_manager,
            &charlie_keys,
            welcome_for(&result, &charlie_keys),
        )
        .await;

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

    /// Returns the sorted set of member pubkey-hex strings for a group.
    fn member_hex_set(manager: &CircleManager, group_id: &GroupId) -> Vec<String> {
        let mut v: Vec<String> = manager
            .get_members(group_id)
            .expect("should get members")
            .into_iter()
            .map(|m| m.pubkey)
            .collect();
        v.sort();
        v
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

    /// RC-5: *execute* the admin handoff rather than only asserting the
    /// `LeavePlan::AdminHandoff` intent. Alice (sole admin) promotes Bob,
    /// commits the promotion and her own self-demotion, Bob processes both
    /// commits, and we assert the protocol outcome cross-party: Bob is the
    /// sole admin afterwards and the group still encrypts→decrypts between
    /// the two parties.
    ///
    /// Scope note (fragility budget): this drives the deterministic prefix of
    /// the leave sequence documented on [`CircleManager::plan_leave`] —
    /// `propose_admin_handoff` → finalize → `propose_self_demote` → finalize.
    /// It deliberately stops before `propose_leave`/`complete_leave`: that
    /// final step emits a `SelfRemove` *proposal* that a remaining member must
    /// later commit (RFC 9420 §12.1.2), so the leaver's own roster does not
    /// advance synchronously and asserting on it here would be racy. The
    /// stable, security-relevant invariant — admin authority transferred to
    /// the successor and the group remains usable — is fully asserted.
    #[tokio::test]
    #[allow(clippy::too_many_lines)] // One cohesive multi-step handoff scenario.
    async fn admin_handoff_transfers_admin_and_group_stays_usable() {
        let setup = setup_circle_with_invite("handoff_exec").await;
        let group_id = setup.result.circle.mls_group_id.clone();

        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("alice finalize creation commit");
        activate_joiner(
            &setup.bob_manager,
            &setup.bob_keys,
            &setup.result.welcome_events[0],
        )
        .await;

        let alice_pk = setup.alice_keys.public_key();
        let bob_pk = setup.bob_keys.public_key();
        let alice_hex = alice_pk.to_hex();
        let bob_hex = bob_pk.to_hex();

        // Preconditions: Alice is the sole admin; the plan is AdminHandoff{Bob}.
        let is_admin = |m: &CircleManager, hex: &str| {
            m.get_members(&group_id)
                .expect("get members")
                .into_iter()
                .find(|x| x.pubkey == hex)
                .is_some_and(|x| x.is_admin)
        };
        assert!(
            is_admin(&setup.alice_manager, &alice_hex),
            "Alice starts admin"
        );
        assert!(
            !is_admin(&setup.alice_manager, &bob_hex),
            "Bob starts non-admin"
        );
        match setup
            .alice_manager
            .plan_leave(&group_id, &alice_pk)
            .expect("plan_leave")
        {
            LeavePlan::AdminHandoff { successor } => {
                assert_eq!(successor, bob_pk, "successor must be the sole peer Bob");
            }
            other => panic!("expected AdminHandoff, got {other:?}"),
        }

        // --- Step 1: promote Bob to admin, finalize, Bob processes. ---
        let handoff_commit = setup
            .alice_manager
            .propose_admin_handoff(&group_id, &bob_pk)
            .expect("alice proposes admin handoff")
            .evolution_event;
        assert_eq!(
            handoff_commit.kind,
            nostr::Kind::Custom(445),
            "handoff evolution event must be kind 445"
        );
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("alice finalizes handoff");

        setup
            .bob_manager
            .decrypt_location(&handoff_commit)
            .expect("bob processes handoff commit");

        // After the handoff, BOTH parties (cross-party) must see Bob as admin.
        assert!(
            is_admin(&setup.alice_manager, &bob_hex),
            "Alice's view: Bob must be admin after handoff"
        );
        assert!(
            is_admin(&setup.bob_manager, &bob_hex),
            "Bob's own view: Bob must be admin after handoff (cross-party convergence)"
        );

        // --- Step 2: Alice self-demotes, finalize, Bob processes. ---
        let demote_commit = setup
            .alice_manager
            .propose_self_demote(&group_id)
            .expect("alice proposes self-demote")
            .evolution_event;
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("alice finalizes self-demote");

        setup
            .bob_manager
            .decrypt_location(&demote_commit)
            .expect("bob processes self-demote commit");

        // The successor is now the SOLE admin, observed from both sides.
        assert!(
            is_admin(&setup.bob_manager, &bob_hex),
            "Bob remains admin after Alice's demotion"
        );
        assert!(
            !is_admin(&setup.bob_manager, &alice_hex),
            "Bob's view: Alice is no longer admin after self-demote"
        );
        assert!(
            !is_admin(&setup.alice_manager, &alice_hex),
            "Alice's view: Alice is no longer admin after self-demote"
        );

        // --- Group still usable cross-party after the handoff. ---
        // Bob (the new admin) encrypts; Alice decrypts.
        let from_bob = encrypt_sentinel_location(
            &setup.bob_manager,
            &setup.bob_keys,
            &group_id,
            35.68,
            139.69,
        );
        assert_decrypts_to_location(
            &setup.alice_manager,
            &from_bob,
            &setup.bob_keys,
            35.68,
            139.69,
        );

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

        // Capture the epoch BEFORE the add so we can assert the membership
        // change advances the MLS epoch (new epoch => new exporter secret =>
        // new encryption key), not merely the member count.
        let epoch_before_add = setup
            .alice_manager
            .group_epoch(&group_id)
            .expect("should read epoch before add");

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

        // The add-member commit MUST advance the epoch (encryption-key rotation).
        let epoch_after_add = setup
            .alice_manager
            .group_epoch(&group_id)
            .expect("should read epoch after add");
        assert!(
            epoch_after_add > epoch_before_add,
            "add-member commit must advance the MLS epoch (key rotation): \
             before={epoch_before_add}, after={epoch_after_add}"
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

        // Capture the epoch BEFORE the removal so we can assert the membership
        // change advances the MLS epoch (new epoch => new exporter secret =>
        // new encryption key), not merely the member count.
        let epoch_before_remove = setup
            .alice_manager
            .group_epoch(&group_id)
            .expect("should read epoch before remove");

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

        // The remove-member commit MUST advance the epoch (key rotation; the
        // evicted member's key material becomes stale — forward secrecy).
        let epoch_after_remove = setup
            .alice_manager
            .group_epoch(&group_id)
            .expect("should read epoch after remove");
        assert!(
            epoch_after_remove > epoch_before_remove,
            "remove-member commit must advance the MLS epoch (key rotation): \
             before={epoch_before_remove}, after={epoch_after_remove}"
        );

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

        // The add created a PENDING commit but must not advance the epoch until
        // it is merged. Capture the pre-finalize epoch to prove that
        // finalize_pending_commit is what advances it (encryption-key rotation).
        let epoch_before_finalize = setup
            .alice_manager
            .group_epoch(&group_id)
            .expect("should read epoch before finalize");

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

        // Finalizing the pending commit MUST advance the epoch (key rotation).
        let epoch_after_finalize = setup
            .alice_manager
            .group_epoch(&group_id)
            .expect("should read epoch after finalize");
        assert!(
            epoch_after_finalize > epoch_before_finalize,
            "finalize_pending_commit must advance the MLS epoch (key rotation): \
             before={epoch_before_finalize}, after={epoch_after_finalize}"
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

        // Activate Bob so "group remains usable" can be proven by an actual
        // cross-party decrypt (RC-4), not just a local get_members read-back.
        activate_joiner(
            &setup.bob_manager,
            &setup.bob_keys,
            &setup.result.welcome_events[0],
        )
        .await;

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
        let epoch_before_add = setup
            .alice_manager
            .group_epoch(&group_id)
            .expect("alice epoch before add");

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
            .add_members(&group_id, &[charlie_kp])
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
        // The rolled-back add must not have advanced the epoch.
        assert_eq!(
            setup.alice_manager.group_epoch(&group_id).unwrap(),
            epoch_before_add,
            "a cleared (rolled-back) add must not advance the epoch"
        );

        // RC-4: the group is still usable for the original members AFTER the
        // rollback — Alice encrypts, Bob (still on the same epoch) decrypts.
        let after_rollback = encrypt_sentinel_location(
            &setup.alice_manager,
            &setup.alice_keys,
            &group_id,
            51.50,
            -0.12,
        );
        assert_decrypts_to_location(
            &setup.bob_manager,
            &after_rollback,
            &setup.alice_keys,
            51.50,
            -0.12,
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
        // The finalized re-add MUST advance the epoch.
        assert!(
            setup.alice_manager.group_epoch(&group_id).unwrap() > epoch_before_add,
            "the finalized re-add MUST advance the epoch past the pre-add value"
        );

        cleanup_dir(&charlie_dir);
        setup.cleanup();
    }

    /// Self-update produces a kind 445 evolution event AND performs a real
    /// key rotation: the group epoch MUST advance once the commit is merged
    /// (RC-2), and "usable" means a peer can decrypt a post-rotation location
    /// from Alice — not a local `get_members` read-back (RC-4). A no-op that
    /// merely emitted a kind-445 without rotating, or that left the peer on a
    /// stale epoch, would fail here.
    #[tokio::test]
    async fn self_update_produces_evolution_event_and_group_remains_usable() {
        let setup = setup_circle_with_invite("self_update").await;
        let group_id = setup.result.circle.mls_group_id.clone();

        // Finalize Alice's pending commit from create_circle
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize creation commit");

        // Activate Bob as a real member so the rotation can be observed
        // cross-party.
        activate_joiner(
            &setup.bob_manager,
            &setup.bob_keys,
            &setup.result.welcome_events[0],
        )
        .await;

        // RC-2: capture the epoch before the self-update.
        let epoch_before = setup
            .alice_manager
            .group_epoch(&group_id)
            .expect("alice epoch before self-update");

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

        // Before merge, the epoch MUST NOT have advanced (commit is pending).
        assert_eq!(
            setup.alice_manager.group_epoch(&group_id).unwrap(),
            epoch_before,
            "epoch must not advance before the self-update commit is merged"
        );

        // Capture the evolution event so Bob can apply the same rotation.
        let update_commit = update_result.evolution_event;

        // Merge the pending commit
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize self-update commit");

        // RC-2: the epoch MUST advance after the merge — proof of real key
        // rotation, not a cosmetic kind-445 emission.
        let epoch_after = setup
            .alice_manager
            .group_epoch(&group_id)
            .expect("alice epoch after self-update");
        assert!(
            epoch_after > epoch_before,
            "self-update + merge MUST advance the epoch (real key rotation); \
             before={epoch_before}, after={epoch_after}"
        );

        // Membership is unchanged by a self-update (preserve original coverage).
        let members = setup
            .alice_manager
            .get_members(&group_id)
            .expect("should get members after self-update");
        assert_eq!(
            members.len(),
            2,
            "Should still have 2 members after self-update"
        );

        // Bob applies Alice's rotation commit and converges to the new epoch.
        setup
            .bob_manager
            .decrypt_location(&update_commit)
            .expect("bob processes the self-update commit");
        assert_eq!(
            setup.bob_manager.group_epoch(&group_id).unwrap(),
            epoch_after,
            "Bob must converge to Alice's post-rotation epoch"
        );

        // RC-4: "usable" == Bob decrypts a post-rotation location from Alice.
        let post = encrypt_sentinel_location(
            &setup.alice_manager,
            &setup.alice_keys,
            &group_id,
            48.85,
            2.35,
        );
        assert_decrypts_to_location(&setup.bob_manager, &post, &setup.alice_keys, 48.85, 2.35);

        setup.cleanup();
    }

    /// Self-update can be rolled back via `clear_pending_commit` without
    /// bricking the group. RC-2: a *rolled-back* self-update MUST NOT advance
    /// the epoch (no rotation actually happened), while the retry that IS
    /// merged MUST advance it. RC-4: after the retry, a peer can decrypt a
    /// post-rotation location from Alice.
    #[tokio::test]
    async fn self_update_rollback_leaves_group_usable() {
        let setup = setup_circle_with_invite("self_update_rollback").await;
        let group_id = setup.result.circle.mls_group_id.clone();

        // Finalize Alice's pending commit from create_circle
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize creation commit");

        activate_joiner(
            &setup.bob_manager,
            &setup.bob_keys,
            &setup.result.welcome_events[0],
        )
        .await;

        let epoch_start = setup
            .alice_manager
            .group_epoch(&group_id)
            .expect("alice epoch at start");

        // Perform self-update then roll it back
        setup
            .alice_manager
            .self_update(&group_id)
            .expect("should perform self-update");

        setup
            .alice_manager
            .clear_pending_commit(&group_id)
            .expect("should clear self-update pending commit");

        // RC-2: a rolled-back self-update must leave the epoch exactly where
        // it started — the rotation was discarded, not applied.
        assert_eq!(
            setup.alice_manager.group_epoch(&group_id).unwrap(),
            epoch_start,
            "rolling back a self-update MUST NOT advance the epoch"
        );

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
        let retry_commit = retry_result.evolution_event;

        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("should finalize retry self-update");

        // RC-2: the merged retry MUST advance the epoch past the start.
        let epoch_after_retry = setup
            .alice_manager
            .group_epoch(&group_id)
            .expect("alice epoch after retry");
        assert!(
            epoch_after_retry > epoch_start,
            "the merged retry self-update MUST advance the epoch; \
             start={epoch_start}, after={epoch_after_retry}"
        );

        // RC-4: Bob applies the retry rotation and can decrypt a fresh
        // location from Alice at the new epoch.
        setup
            .bob_manager
            .decrypt_location(&retry_commit)
            .expect("bob processes the retry self-update commit");
        let post = encrypt_sentinel_location(
            &setup.alice_manager,
            &setup.alice_keys,
            &group_id,
            -33.86,
            151.20,
        );
        assert_decrypts_to_location(&setup.bob_manager, &post, &setup.alice_keys, -33.86, 151.20);

        setup.cleanup();
    }

    /// `groups_needing_self_update` returns a group after welcome acceptance
    /// (Required state) and no longer returns it after a self-update is
    /// finalized (`CompletedAt` state).
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
    /// Returns the `recipient_relays` from the generated `GiftWrappedWelcome`.
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
    async fn cascade_uses_creator_fallback_when_member_empty() {
        // Tier 3: a member with no advertised relays falls back to the
        // creator's own inbox relays (passed as `creator_fallback_relays`) —
        // never to public defaults.
        let relays = vec!["wss://relay.test.com".to_string()];

        let alice_dir = unique_temp_dir("cascade_creatorfb_alice");
        let alice_manager =
            CircleManager::new_unencrypted(&alice_dir).expect("should create alice manager");
        let alice_keys = Keys::generate();

        let bob_dir = unique_temp_dir("cascade_creatorfb_bob");
        let bob_manager =
            CircleManager::new_unencrypted(&bob_dir).expect("should create bob manager");
        let bob_keys = Keys::generate();
        let bob_kp_event = create_kp_event_from_circle_manager(&bob_manager, &bob_keys, &relays);

        let members = vec![MemberKeyPackage {
            key_package_event: bob_kp_event,
            inbox_relays: vec![],
            nip65_relays: vec![],
        }];

        let config = CircleConfig::new("Creator Fallback Cascade")
            .with_type(CircleType::LocationSharing)
            .with_relays(relays);

        let creator_inbox = vec!["wss://creator-inbox.example.com".to_string()];
        let result = alice_manager
            .create_circle(&alice_keys, members, &config, &creator_inbox)
            .await
            .expect("should create circle via creator fallback");

        assert_eq!(result.welcome_events.len(), 1);
        assert_eq!(
            result.welcome_events[0].recipient_relays, creator_inbox,
            "tier-3 delivery must use the creator's own inbox relays"
        );
        for d in haven_core::circle::PRODUCTION_DEFAULT_RELAYS {
            assert!(
                !result.welcome_events[0]
                    .recipient_relays
                    .iter()
                    .any(|r| r.starts_with(d)),
                "tier-3 delivery must never include a public default ({d})"
            );
        }

        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
    }

    #[tokio::test]
    async fn cascade_fails_closed_when_all_empty() {
        // Two-plane leak invariant: when a member advertises no inbox/NIP-65
        // relays AND the creator passes no fallback relays, delivery FAILS
        // CLOSED rather than falling back to public defaults — which would
        // expose the recipient's pubkey to those relays.
        let relays = vec!["wss://relay.test.com".to_string()];

        let alice_dir = unique_temp_dir("cascade_failclosed_alice");
        let alice_manager =
            CircleManager::new_unencrypted(&alice_dir).expect("should create alice manager");
        let alice_keys = Keys::generate();

        let bob_dir = unique_temp_dir("cascade_failclosed_bob");
        let bob_manager =
            CircleManager::new_unencrypted(&bob_dir).expect("should create bob manager");
        let bob_keys = Keys::generate();
        let bob_kp_event = create_kp_event_from_circle_manager(&bob_manager, &bob_keys, &relays);

        let members = vec![MemberKeyPackage {
            key_package_event: bob_kp_event,
            inbox_relays: vec![],
            nip65_relays: vec![],
        }];

        let config = CircleConfig::new("Fail Closed Cascade")
            .with_type(CircleType::LocationSharing)
            .with_relays(relays);

        let err = alice_manager
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect_err("must fail closed when no delivery relay exists");
        assert!(
            matches!(err, haven_core::circle::CircleError::MissingWelcomeRelays),
            "expected MissingWelcomeRelays, got {err:?}"
        );
        // The error must NOT carry any default relay URL (no leak in errors).
        let msg = err.to_string();
        for d in haven_core::circle::PRODUCTION_DEFAULT_RELAYS {
            assert!(
                !msg.contains(d),
                "fail-closed error must not mention a default relay ({d})"
            );
        }
        // No phantom state: failing closed leaves NO circle in storage (the
        // pre-check runs before the MLS group is created / persisted).
        let circles = alice_manager.get_circles().expect("get_circles");
        assert!(
            circles.is_empty(),
            "fail-closed create_circle must persist no circle"
        );

        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
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

    // ------------------------------------------------------------------
    // create_circle substitution tests (per RelayType::Inbox refactor)
    //
    // When the caller passes `config.relays = []`, `create_circle` must
    // substitute the user's Inbox relays from `RelayPreferencesStorage`
    // (NOT the user's KeyPackage relays — that would conflate kind:445
    // group-message relays with kind 30443/10051 KeyPackage discovery).
    // Falls back to the default relay list only if the user list is also empty.
    // ------------------------------------------------------------------

    #[tokio::test]
    async fn create_circle_uses_user_inbox_relays_when_config_empty() {
        use haven_core::circle::RelayType;

        let alice_dir = unique_temp_dir("subst_inbox");
        let alice_manager = CircleManager::new_unencrypted(&alice_dir).expect("alice manager");
        let alice_keys = Keys::generate();

        // Seed Alice's prefs and add a custom inbox relay so we can
        // distinguish "took user inbox" from "took default relays".
        alice_manager
            .seed_relay_defaults_if_unseeded()
            .expect("seed");
        alice_manager
            .add_user_relay("wss://alice-custom-inbox.example.com", RelayType::Inbox)
            .expect("add inbox relay");
        // Add a different KP relay so we can confirm it's NOT used here.
        alice_manager
            .add_user_relay("wss://alice-kp-only.example.com", RelayType::KeyPackage)
            .expect("add kp relay");

        // Bob is a member with his own inbox relays so the cascade is
        // unaffected by Alice's substitution.
        let bob_dir = unique_temp_dir("subst_inbox_bob");
        let bob_manager = CircleManager::new_unencrypted(&bob_dir).expect("bob manager");
        let bob_keys = Keys::generate();
        let bob_kp = create_kp_event_from_circle_manager(
            &bob_manager,
            &bob_keys,
            &["wss://bob-relay.example.com".to_string()],
        );
        let members = vec![MemberKeyPackage {
            key_package_event: bob_kp,
            inbox_relays: vec!["wss://bob-inbox.example.com".to_string()],
            nip65_relays: vec![],
        }];

        // CRITICAL: pass config.relays = vec![] to trigger substitution.
        let config = CircleConfig::new("Subst Inbox Test").with_type(CircleType::LocationSharing);
        // No .with_relays — relays Vec is empty.
        assert!(config.relays.is_empty());

        let result = alice_manager
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect("create_circle should succeed");

        // The CIRCLE'S relays (used for kind:445 publish) must equal Alice's
        // Inbox list — both seeded defaults AND the custom relay.
        let alice_inbox = alice_manager
            .list_user_relays(RelayType::Inbox)
            .expect("list inbox");
        assert_eq!(
            result.circle.relays, alice_inbox,
            "circle.relays must equal user's Inbox list, not KeyPackage list"
        );
        assert!(
            result
                .circle
                .relays
                .iter()
                .any(|u| u.contains("alice-custom-inbox.example.com")),
            "must include user's custom Inbox relay"
        );
        assert!(
            !result
                .circle
                .relays
                .iter()
                .any(|u| u.contains("alice-kp-only.example.com")),
            "must NOT include KeyPackage-only relay (semantically wrong)"
        );

        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
    }

    #[tokio::test]
    async fn create_circle_falls_back_to_defaults_when_user_inbox_empty() {
        // Defensive path: an unseeded fresh manager (or a user who somehow
        // ended up with an empty Inbox category despite the storage rules).
        // create_circle must not produce a Welcome with an empty `relays`
        // tag — MDK rejects those — so it falls back to the default relays.
        let alice_dir = unique_temp_dir("subst_defaults");
        let alice_manager = CircleManager::new_unencrypted(&alice_dir).expect("alice manager");
        let alice_keys = Keys::generate();

        // DO NOT call seed_relay_defaults_if_unseeded — leave Inbox empty.

        let bob_dir = unique_temp_dir("subst_defaults_bob");
        let bob_manager = CircleManager::new_unencrypted(&bob_dir).expect("bob manager");
        let bob_keys = Keys::generate();
        let bob_kp = create_kp_event_from_circle_manager(
            &bob_manager,
            &bob_keys,
            &["wss://bob-relay.example.com".to_string()],
        );
        let members = vec![MemberKeyPackage {
            key_package_event: bob_kp,
            inbox_relays: vec!["wss://bob-inbox.example.com".to_string()],
            nip65_relays: vec![],
        }];

        let config =
            CircleConfig::new("Subst Defaults Test").with_type(CircleType::LocationSharing);
        assert!(config.relays.is_empty());

        let result = alice_manager
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect("create_circle must still succeed via defensive fallback");

        let expected_defaults: Vec<String> = haven_core::circle::PRODUCTION_DEFAULT_RELAYS
            .iter()
            .map(|s| (*s).to_string())
            .collect();
        assert_eq!(
            result.circle.relays, expected_defaults,
            "must fall back to default relays when user Inbox list is empty"
        );

        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
    }

    #[tokio::test]
    async fn create_circle_uses_explicit_relays_when_provided() {
        // Sanity: when the caller passes a non-empty config.relays, that
        // list is used verbatim — substitution only happens for empty.
        use haven_core::circle::RelayType;

        let alice_dir = unique_temp_dir("explicit_relays");
        let alice_manager = CircleManager::new_unencrypted(&alice_dir).expect("alice manager");
        let alice_keys = Keys::generate();
        alice_manager
            .seed_relay_defaults_if_unseeded()
            .expect("seed");
        alice_manager
            .add_user_relay("wss://alice-inbox.example.com", RelayType::Inbox)
            .expect("add inbox");

        let bob_dir = unique_temp_dir("explicit_relays_bob");
        let bob_manager = CircleManager::new_unencrypted(&bob_dir).expect("bob manager");
        let bob_keys = Keys::generate();
        let bob_kp = create_kp_event_from_circle_manager(
            &bob_manager,
            &bob_keys,
            &["wss://bob.example.com".to_string()],
        );
        let members = vec![MemberKeyPackage {
            key_package_event: bob_kp,
            inbox_relays: vec!["wss://bob-inbox.example.com".to_string()],
            nip65_relays: vec![],
        }];

        let explicit = vec!["wss://explicit-only.example.com".to_string()];
        let config = CircleConfig::new("Explicit Relays Test")
            .with_type(CircleType::LocationSharing)
            .with_relays(explicit.clone());

        let result = alice_manager
            .create_circle(&alice_keys, members, &config, &[])
            .await
            .expect("create_circle should succeed");

        assert_eq!(
            result.circle.relays, explicit,
            "non-empty config.relays must be used verbatim (no substitution)"
        );
        assert!(
            !result
                .circle
                .relays
                .iter()
                .any(|u| u.contains("alice-inbox.example.com")),
            "user Inbox list must not be merged in when config.relays is explicit"
        );

        cleanup_dir(&alice_dir);
        cleanup_dir(&bob_dir);
    }

    // ------------------------------------------------------------------
    // Cross-party forward secrecy & commit convergence
    //
    // These tests wire up GENUINE cross-party MLS processing using
    // multiple `CircleManager` instances. The original circle tests were
    // single-instance: the peer never processed Alice's commits and never
    // decrypted her messages, so an `Ok(())` / `get_members` read-back
    // would pass even if forward secrecy or epoch rotation were broken.
    // ------------------------------------------------------------------

    /// RC-1 (forward secrecy): after Alice removes Bob and finalizes the
    /// removal commit, Bob is on a stale epoch. A *fresh* location Alice
    /// encrypts at the new epoch MUST be undecryptable by the evicted Bob
    /// (his exporter secret can't open the new epoch), while a remaining
    /// member (Charlie) can still decrypt it. This is the property the
    /// whole effort exists for — `exporter_secret` appears 0× in this file
    /// today, and the removal tests only asserted `get_members().len()`.
    #[tokio::test]
    async fn removed_member_cannot_decrypt_post_removal_location() {
        let c = setup_three_party_active_circle("fs_removal").await;

        // Baseline: while Bob is still a member, he can decrypt Alice's
        // location. This guarantees the later failure is caused by the
        // removal, not by a broken setup.
        let pre =
            encrypt_sentinel_location(&c.alice_manager, &c.alice_keys, &c.group_id, 40.0, -70.0);
        assert_decrypts_to_location(&c.bob_manager, &pre, &c.alice_keys, 40.0, -70.0);
        // Charlie must also process this epoch-N message so his ratchet stays
        // in lock-step with Alice; otherwise his later decrypt could fail for
        // reasons unrelated to the removal.
        assert_decrypts_to_location(&c.charlie_manager, &pre, &c.alice_keys, 40.0, -70.0);

        let epoch_before = c
            .alice_manager
            .group_epoch(&c.group_id)
            .expect("alice epoch before removal");

        // Alice removes Bob and finalizes — this rotates the group to a new
        // epoch from which Bob's leaf is excluded. The returned evolution
        // event is the removal commit the remaining members must apply.
        let removal_commit = c
            .alice_manager
            .remove_members(&c.group_id, &[c.bob_keys.public_key().to_hex()])
            .expect("alice removes bob")
            .evolution_event;

        c.alice_manager
            .finalize_pending_commit(&c.group_id)
            .expect("alice finalizes removal");

        let epoch_after = c
            .alice_manager
            .group_epoch(&c.group_id)
            .expect("alice epoch after removal");
        assert!(
            epoch_after > epoch_before,
            "removing a member MUST advance the epoch (forward secrecy boundary)"
        );

        // Charlie (a remaining member) processes Alice's removal commit so he
        // advances to the new epoch alongside her.
        c.charlie_manager
            .decrypt_location(&removal_commit)
            .expect("charlie processes the removal commit");
        assert_eq!(
            c.charlie_manager.group_epoch(&c.group_id).unwrap(),
            epoch_after,
            "Charlie must converge to Alice's post-removal epoch"
        );

        // Alice now encrypts a FRESH location at the new epoch.
        let remove_evt =
            encrypt_sentinel_location(&c.alice_manager, &c.alice_keys, &c.group_id, 41.0, -71.0);

        // (1) The evicted Bob MUST NOT be able to recover plaintext from the
        //     new-epoch location. He is the subject of the removal commit (he
        //     cannot process his own eviction) and holds only old-epoch
        //     secrets, so his exporter secret can't open the new epoch. Any
        //     non-`Location` outcome (Err, Unprocessable, PreviouslyFailed) is
        //     the correct, secure result — Bob obtained no plaintext.
        let bob_result = c.bob_manager.decrypt_location(&remove_evt);
        if let Ok(haven_core::nostr::mls::types::LocationMessageResult::Location { .. }) =
            bob_result
        {
            panic!("FORWARD SECRECY VIOLATION: removed member decrypted a post-removal location");
        }

        // (2) The remaining member Charlie CAN still decrypt — the group is
        //     fully functional for legitimate members at the new epoch.
        assert_decrypts_to_location(&c.charlie_manager, &remove_evt, &c.alice_keys, 41.0, -71.0);

        // (3) Alice's own roster no longer contains Bob but still contains
        //     Charlie (the surviving member).
        let alice_members = member_hex_set(&c.alice_manager, &c.group_id);
        assert!(
            !alice_members.contains(&c.bob_keys.public_key().to_hex()),
            "Bob must be gone from Alice's member set after removal"
        );
        assert!(
            alice_members.contains(&c.charlie_keys.public_key().to_hex()),
            "Charlie must remain in Alice's member set after Bob's removal"
        );

        c.cleanup();
    }

    /// RC-3 (cross-party commit convergence) + RC-4 (usable == cross-party
    /// decrypt): Bob processes Alice's add and remove evolution commits and
    /// converges to the SAME member set AND the SAME epoch as Alice, and can
    /// decrypt a post-commit location from Alice. A single-instance test
    /// would miss a divergence where the peer's epoch silently lagged.
    #[tokio::test]
    #[allow(clippy::too_many_lines)] // One cohesive add-then-remove convergence scenario.
    async fn peer_converges_on_member_set_and_epoch_after_commits() {
        // Start with a two-party active circle (Alice + Bob) so the *add*
        // commit (adding Charlie) is observed by an existing peer (Bob).
        let setup = setup_circle_with_invite("converge").await;
        let group_id = setup.result.circle.mls_group_id.clone();
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("alice finalize creation commit");
        activate_joiner(
            &setup.bob_manager,
            &setup.bob_keys,
            &setup.result.welcome_events[0],
        )
        .await;

        // Alice and Bob must agree at the starting epoch.
        assert_eq!(
            setup.alice_manager.group_epoch(&group_id).unwrap(),
            setup.bob_manager.group_epoch(&group_id).unwrap(),
            "Alice and Bob must start on the same epoch"
        );
        assert_eq!(
            member_hex_set(&setup.alice_manager, &group_id),
            member_hex_set(&setup.bob_manager, &group_id),
            "Alice and Bob must start with the same member set"
        );

        // --- ADD: Alice adds Charlie ---
        let charlie_dir = unique_temp_dir("converge_charlie");
        let charlie_manager =
            CircleManager::new_unencrypted(&charlie_dir).expect("charlie manager");
        let charlie_keys = Keys::generate();
        let relays = vec!["wss://relay.test.com".to_string()];
        let charlie_kp =
            create_kp_event_from_circle_manager(&charlie_manager, &charlie_keys, &relays);

        let add_commit = setup
            .alice_manager
            .add_members(&group_id, std::slice::from_ref(&charlie_kp))
            .expect("alice adds charlie")
            .evolution_event;
        assert_eq!(
            add_commit.kind,
            nostr::Kind::Custom(445),
            "add-member evolution event must be kind 445"
        );
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("alice finalizes add");

        // Bob processes Alice's add commit. As a plain commit (not a
        // SelfRemove proposal) MDK applies it immediately, advancing Bob's
        // epoch with no separate merge.
        let bob_add_outcome = setup
            .bob_manager
            .decrypt_location(&add_commit)
            .expect("bob processes add commit");
        assert!(
            matches!(
                bob_add_outcome,
                haven_core::nostr::mls::types::LocationMessageResult::GroupUpdate { .. }
            ),
            "Alice's add commit must surface to Bob as a GroupUpdate"
        );

        // Convergence after the add.
        assert_eq!(
            setup.alice_manager.group_epoch(&group_id).unwrap(),
            setup.bob_manager.group_epoch(&group_id).unwrap(),
            "Alice and Bob epochs must converge after the add commit"
        );
        assert_eq!(
            member_hex_set(&setup.alice_manager, &group_id),
            member_hex_set(&setup.bob_manager, &group_id),
            "Alice and Bob member sets must converge after the add commit"
        );
        assert_eq!(
            member_hex_set(&setup.alice_manager, &group_id).len(),
            3,
            "group should now have Alice + Bob + Charlie"
        );

        // --- REMOVE: Alice removes Charlie ---
        let remove_commit = setup
            .alice_manager
            .remove_members(&group_id, &[charlie_keys.public_key().to_hex()])
            .expect("alice removes charlie")
            .evolution_event;
        assert_eq!(
            remove_commit.kind,
            nostr::Kind::Custom(445),
            "remove-member evolution event must be kind 445"
        );
        setup
            .alice_manager
            .finalize_pending_commit(&group_id)
            .expect("alice finalizes remove");

        let bob_remove_outcome = setup
            .bob_manager
            .decrypt_location(&remove_commit)
            .expect("bob processes remove commit");
        assert!(
            matches!(
                bob_remove_outcome,
                haven_core::nostr::mls::types::LocationMessageResult::GroupUpdate { .. }
            ),
            "Alice's remove commit must surface to Bob as a GroupUpdate"
        );

        // Convergence after the remove.
        assert_eq!(
            setup.alice_manager.group_epoch(&group_id).unwrap(),
            setup.bob_manager.group_epoch(&group_id).unwrap(),
            "Alice and Bob epochs must converge after the remove commit"
        );
        assert_eq!(
            member_hex_set(&setup.alice_manager, &group_id),
            member_hex_set(&setup.bob_manager, &group_id),
            "Alice and Bob member sets must converge after the remove commit"
        );

        // RC-4: "usable" means Bob actually decrypts a post-commit location
        // from Alice — not a local read-back.
        let post = encrypt_sentinel_location(
            &setup.alice_manager,
            &setup.alice_keys,
            &group_id,
            12.5,
            34.5,
        );
        assert_decrypts_to_location(&setup.bob_manager, &post, &setup.alice_keys, 12.5, 34.5);

        cleanup_dir(&charlie_dir);
        setup.cleanup();
    }
}
