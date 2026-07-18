//! Integration tests for MLS module functionality (Dark Matter port, DM-5a).
//!
//! Verifies the DM MLS surface:
//! - `SessionManager` lifecycle + inspection (unknown-group behavior).
//! - `MlsGroupContext` over `Arc<SessionManager>` (async).
//! - `StorageConfig` path derivation (now `session.sqlite`).
//! - `LocationGroupConfig` / `LocationMessageResult` shapes.
//! - A black-box re-expression of the peer-`SelfRemove` eviction invariant.
//!
//! Pre-migration tests whose SUBJECT was deleted are dropped with a note:
//! `MdkManager`, `get_messages`, `create_group(pubkey, …)` validation,
//! `to_location_result(MessageProcessingResult)` and its `Proposal`/`evolution_event`
//! mapping, `Unprocessable`/`GroupUpdate.evolution_event` variants, and the
//! two-sessions-on-one-DB test (Rule 14 forbids it).

mod helpers;

use std::env;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use haven_core::nostr::mls::storage::StorageConfig;
use haven_core::nostr::mls::types::{GroupId, LocationGroupConfig, LocationMessageResult};
use haven_core::nostr::mls::{GroupIdExt as _, MlsGroupContext, SessionManager};

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

fn new_session(prefix: &str) -> (SessionManager, PathBuf) {
    let dir = unique_temp_dir(prefix);
    let keys = nostr::Keys::generate();
    let session =
        SessionManager::new_unencrypted(&dir, &keys).expect("should create session manager");
    (session, dir)
}

// ============================================================================
// SessionManager Tests
// ============================================================================

mod session_manager_tests {
    use super::*;

    #[tokio::test]
    async fn manager_find_group_returns_none_for_nonexistent() {
        let (manager, dir) = new_session("find_group_none");
        let fake = GroupId::from_slice(&[1, 2, 3, 4, 5]);
        let result = manager.find_group(&fake).await;
        assert!(result.is_ok());
        assert!(result.unwrap().is_none(), "unknown group must map to None");
        cleanup_dir(&dir);
    }

    #[tokio::test]
    async fn manager_members_fails_for_nonexistent_group() {
        let (manager, dir) = new_session("members_fail");
        let fake = GroupId::from_slice(&[1, 2, 3, 4, 5]);
        assert!(manager.members(&fake).await.is_err());
        cleanup_dir(&dir);
    }

    #[tokio::test]
    async fn manager_leave_group_fails_for_nonexistent_group() {
        let (manager, dir) = new_session("leave_fail");
        let fake = GroupId::from_slice(&[1, 2, 3, 4, 5]);
        assert!(manager.leave_group(&fake).await.is_err());
        cleanup_dir(&dir);
    }

    #[tokio::test]
    async fn manager_epoch_fails_for_nonexistent_group() {
        let (manager, dir) = new_session("epoch_fail");
        let fake = GroupId::from_slice(&[9, 9, 9]);
        assert!(manager.epoch(&fake).await.is_err());
        cleanup_dir(&dir);
    }

    // DELETED-WITH-SUBJECT: `manager_get_messages_fails_for_nonexistent_group`
    // (`get_messages` is gone — Haven keeps its own message store), the two
    // `create_group_with_*_pubkey_fails` tests (`create_group` takes
    // `Vec<KeyPackage>`, no creator-pubkey-string validation), and
    // `manager_multiple_instances_same_directory` (Rule 14 forbids two live
    // `AccountDeviceSession`s on one DB file — divergent hydrated state).
}

// ============================================================================
// MlsGroupContext Tests (async, over Arc<SessionManager>)
// ============================================================================

mod mls_group_context_tests {
    use super::*;

    fn ctx(prefix: &str, nostr_hex: &str, gid: &[u8]) -> (MlsGroupContext, PathBuf) {
        let (manager, dir) = new_session(prefix);
        let group_id = GroupId::from_slice(gid);
        (
            MlsGroupContext::new(Arc::new(manager), group_id, nostr_hex),
            dir,
        )
    }

    #[test]
    fn context_creation() {
        let (c, dir) = ctx("ctx_creation", "nostr-group-hex", &[1, 2, 3, 4]);
        assert_eq!(c.nostr_group_id(), "nostr-group-hex");
        cleanup_dir(&dir);
    }

    #[tokio::test]
    async fn context_epoch_fails_for_nonexistent_group_without_leaking_mls_id() {
        // RE-EXPRESSED: the context no longer surfaces the nostr_group_id in the
        // error (the engine returns a redacted `MdkError`), but the surviving
        // privacy invariant (Rule 4/6) is that the REAL MLS group id hex never
        // appears in the surfaced error.
        let gid = [99u8; 32];
        let mls_hex = hex::encode(gid);
        let (manager, dir) = new_session("ctx_epoch_fail");
        let context = MlsGroupContext::new(Arc::new(manager), GroupId::from_slice(&gid), "test");

        let err = context.epoch().await.expect_err("missing group must error");
        assert!(
            !err.to_string().contains(&mls_hex),
            "the real MLS group id must never appear in the surfaced error"
        );
        cleanup_dir(&dir);
    }

    #[tokio::test]
    async fn context_validate_epoch_fails_for_nonexistent_group() {
        let (c, dir) = ctx("ctx_validate_epoch", "test", &[99, 99]);
        assert!(c.validate_epoch(1).await.is_err());
        cleanup_dir(&dir);
    }

    #[test]
    fn context_debug_output_redacts_mls_id() {
        let (c, dir) = ctx("ctx_debug", "my-group", &[1, 2, 3]);
        let debug_output = format!("{c:?}");
        assert!(debug_output.contains("MlsGroupContext"));
        assert!(debug_output.contains("my-group"));
        assert!(debug_output.contains("<redacted>"));
        assert!(
            !debug_output.contains("010203"),
            "MLS group id must not appear"
        );
        cleanup_dir(&dir);
    }

    #[test]
    fn context_with_empty_and_unicode_nostr_group_id() {
        let (c1, d1) = ctx("ctx_empty", "", &[1, 2, 3]);
        assert_eq!(c1.nostr_group_id(), "");
        cleanup_dir(&d1);

        let (c2, d2) = ctx("ctx_unicode", "groupe-familial-français", &[1, 2, 3]);
        assert_eq!(c2.nostr_group_id(), "groupe-familial-français");
        cleanup_dir(&d2);
    }
}

// ============================================================================
// StorageConfig Tests (path derivation → session.sqlite)
// ============================================================================

mod storage_config_tests {
    use super::*;

    #[test]
    fn storage_config_database_path_is_session_sqlite() {
        let config = StorageConfig::new("/some/path");
        assert_eq!(
            config.database_path(),
            PathBuf::from("/some/path/session.sqlite")
        );
        // The legacy pre-migration path is still derivable for the cutover wipe.
        assert_eq!(
            config.legacy_database_path(),
            PathBuf::from("/some/path/haven_mdk.db")
        );
    }

    #[test]
    fn storage_config_relative_path() {
        let config = StorageConfig::new("relative/path");
        assert_eq!(config.data_dir, PathBuf::from("relative/path"));
        assert_eq!(
            config.database_path(),
            PathBuf::from("relative/path/session.sqlite")
        );
    }

    #[test]
    fn storage_config_empty_path() {
        let config = StorageConfig::new("");
        assert_eq!(config.data_dir, PathBuf::from(""));
        assert_eq!(config.database_path(), PathBuf::from("session.sqlite"));
    }

    #[test]
    fn storage_config_debug_impl_and_clone() {
        let config = StorageConfig::new("/test/path");
        let debug_str = format!("{config:?}");
        assert!(debug_str.contains("StorageConfig"));
        assert!(debug_str.contains("/test/path"));
        let cloned = config.clone();
        assert_eq!(config.data_dir, cloned.data_dir);
    }

    #[test]
    fn in_memory_storage_opens() {
        // DM re-expression of the deleted `create_storage_unencrypted` factory:
        // the unencrypted store is now a static in-memory `SqliteAccountStorage`.
        StorageConfig::in_memory_storage().expect("in-memory storage should open");
    }
}

// ============================================================================
// LocationGroupConfig Tests (unchanged)
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
    fn config_with_relays_from_iter_and_empty() {
        let relays = ["wss://r1.com", "wss://r2.com", "wss://r3.com"];
        assert_eq!(
            LocationGroupConfig::new("Test")
                .with_relays(relays)
                .relays
                .len(),
            3
        );
        let empty: Vec<String> = vec![];
        assert!(LocationGroupConfig::new("Test")
            .with_relays(empty)
            .relays
            .is_empty());
    }

    #[test]
    fn config_debug_output_and_clone() {
        let config = LocationGroupConfig::new("Test Group")
            .with_description("A test")
            .with_relay("wss://relay.example.com")
            .with_admin("admin123");
        let debug_str = format!("{config:?}");
        assert!(debug_str.contains("Test Group"));
        assert!(debug_str.contains("A test"));
        assert!(debug_str.contains("relay.example.com"));
        assert!(debug_str.contains("admin123"));
        let cloned = config.clone();
        assert_eq!(config.name, cloned.name);
        assert_eq!(config.relays, cloned.relays);
        assert_eq!(config.admins, cloned.admins);
    }
}

// ============================================================================
// LocationMessageResult Tests (new DM variants)
// ============================================================================

mod location_message_result_tests {
    use super::*;

    #[test]
    fn location_result_debug_location_variant_redacts() {
        let result = LocationMessageResult::Location {
            sender_pubkey: "abc123".to_string(),
            content: r#"{"latitude":37.7}"#.to_string(),
            group_id: GroupId::from_slice(&[1, 2, 3]),
            epoch: 4,
        };
        let debug_str = format!("{result:?}");
        assert!(debug_str.contains("Location"));
        assert!(
            !debug_str.contains("abc123"),
            "sender_pubkey must be redacted"
        );
        assert!(!debug_str.contains("latitude"), "content must be redacted");
        assert!(debug_str.contains("<redacted>"));
        // The epoch is a non-secret sort key and is shown.
        assert!(debug_str.contains('4'));
    }

    #[test]
    fn location_result_debug_group_update_and_joined_and_invalidated_and_unrecoverable() {
        let g = GroupId::from_slice(&[4, 5, 6]);
        for (r, label) in [
            (
                LocationMessageResult::GroupUpdate {
                    group_id: g.clone(),
                },
                "GroupUpdate",
            ),
            (
                LocationMessageResult::Joined {
                    group_id: g.clone(),
                },
                "Joined",
            ),
            (
                LocationMessageResult::Invalidated {
                    group_id: g.clone(),
                },
                "Invalidated",
            ),
            (
                LocationMessageResult::Unrecoverable {
                    group_id: g.clone(),
                },
                "Unrecoverable",
            ),
        ] {
            let debug_str = format!("{r:?}");
            assert!(
                debug_str.contains(label),
                "Debug must name the {label} variant"
            );
            assert!(
                debug_str.contains("<redacted>"),
                "group_id must be redacted"
            );
        }
    }
}

// ============================================================================
// Production Storage Tests (require system keyring)
// ============================================================================

mod production_storage_tests {
    use super::*;
    use haven_core::circle::CircleManager;

    #[test]
    #[ignore = "requires system keyring - run with --ignored flag"]
    fn storage_encrypted_opens_successfully() {
        let dir = unique_temp_dir("prod_storage_encrypted");
        std::fs::create_dir_all(&dir).unwrap();
        let config = StorageConfig::new(&dir);
        assert!(
            config.open_encrypted_storage().is_ok(),
            "encrypted storage should open with a keyring"
        );
        cleanup_dir(&dir);
    }

    #[test]
    #[ignore = "requires system keyring - run with --ignored flag"]
    fn session_manager_encrypted_creates_successfully() {
        let dir = unique_temp_dir("prod_manager_encrypted");
        let keys = nostr::Keys::generate();
        assert!(
            SessionManager::new(&dir, &keys).is_ok(),
            "SessionManager should open with a keyring"
        );
        cleanup_dir(&dir);
    }

    #[tokio::test]
    #[ignore = "requires system keyring - run with --ignored flag"]
    async fn circle_manager_encrypted_creates_successfully() {
        let dir = unique_temp_dir("prod_circle_encrypted");
        let keys = nostr::Keys::generate();
        let manager = CircleManager::new(&dir, &keys, None).expect("circle manager with keyring");
        assert!(manager.get_circles().await.unwrap().is_empty());
        assert!(manager.get_all_contacts().unwrap().is_empty());
        cleanup_dir(&dir);
    }

    /// Production encrypted storage either succeeds (keyring present) or fails
    /// with a descriptive keyring/storage error (keyring absent, e.g. CI).
    #[test]
    fn storage_encrypted_opens_or_reports_keyring_unavailable() {
        let dir = unique_temp_dir("prod_storage_error");
        std::fs::create_dir_all(&dir).unwrap();
        let config = StorageConfig::new(&dir);
        match config.open_encrypted_storage() {
            Ok(_storage) => {}
            Err(e) => {
                let msg = e.to_string().to_lowercase();
                assert!(
                    msg.contains("keyring")
                        || msg.contains("storage")
                        || msg.contains("service")
                        || msg.contains("key"),
                    "missing-keyring failure must be descriptive, got: {e}"
                );
            }
        }
        cleanup_dir(&dir);
    }
}

// ============================================================================
// Peer-SelfRemove eviction (RE-EXPRESSED from receiver_side_auto_commit_tests)
//
// The pre-migration tests drove `leave_group().evolution_event` +
// `process_message` → `MessageProcessingResult::Proposal` →
// `to_location_result().GroupUpdate.evolution_event` + `merge_pending_commit`.
// That whole taxonomy is engine-internal now. The surviving INVARIANT — a
// member's `SelfRemove` proposal, once processed + converged by a remaining
// admin, evicts the leaver and advances the epoch — is re-expressed black-box
// over the engine loop (ingest → auto-publish → confirm → advance_convergence).
// ============================================================================

mod selfremove_eviction_tests {
    use super::helpers;
    use haven_core::nostr::mls::types::PublishWork;
    use haven_core::nostr::mls::SessionManager;

    #[tokio::test]
    async fn peer_selfremove_evicts_the_leaver_and_advances_epoch() {
        let g = helpers::setup_two_party_group("selfremove_evict").await;
        let bob_hex = g.bob_keys.public_key().to_hex();
        let epoch_before = g.alice.epoch(&g.group_id).await.unwrap();
        assert_eq!(g.alice.member_pubkeys(&g.group_id).await.unwrap().len(), 2);

        // Bob (non-admin) proposes SelfRemove.
        let leave = g.bob.leave_group(&g.group_id).await.expect("bob leaves");
        let proposal = leave
            .publish
            .iter()
            .find_map(|w| match w {
                PublishWork::Proposal { msg } => Some(msg.clone()),
                _ => None,
            })
            .expect("SelfRemove proposal");
        let proposal_event = SessionManager::transport_message_to_event(&proposal).unwrap();

        // Alice (admin) ingests the proposal: Processed, but the removal is NOT
        // applied yet — the engine schedules a jitter-delayed auto-commit (so
        // remaining members don't all commit the same SelfRemove at once). The
        // group is queued for convergence.
        g.alice
            .process_event(&proposal_event)
            .await
            .expect("alice ingests proposal");
        assert!(
            g.alice
                .member_pubkeys(&g.group_id)
                .await
                .unwrap()
                .contains(&bob_hex),
            "the removal must not apply on the bare proposal (jitter-delayed auto-commit)"
        );

        // Poll advance_convergence past the jitter window; when the auto-commit
        // surfaces as AutoPublish, CAPTURE its commit (the wire artifact that MUST
        // reach peers before applying — Rule 13/F13; the DM-3 stopgap confirmed it
        // without ever publishing it, forking remaining members) and confirm it.
        let mut evicted = false;
        let mut captured_commit: Option<haven_core::nostr::mls::types::Event> = None;
        for _ in 0..40 {
            let eff = g
                .alice
                .advance_convergence(&g.group_id)
                .await
                .expect("advance convergence");
            for w in &eff.publish {
                if let PublishWork::AutoPublish { pending, msg } = w {
                    captured_commit = Some(
                        SessionManager::transport_message_to_event(msg)
                            .expect("auto-commit converts to a publishable kind-445 event"),
                    );
                    g.alice
                        .confirm_published(*pending)
                        .await
                        .expect("confirm auto-commit");
                }
            }
            if !g
                .alice
                .member_pubkeys(&g.group_id)
                .await
                .unwrap()
                .contains(&bob_hex)
            {
                evicted = true;
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }

        assert!(
            evicted,
            "the leaver must be evicted from the admin's roster after the \
             jitter-delayed SelfRemove auto-commit is confirmed"
        );
        assert!(
            g.alice.epoch(&g.group_id).await.unwrap() > epoch_before,
            "the admin's epoch must advance past the SelfRemove commit"
        );

        // Strengthen (this test previously MASKED the gap by confirming the
        // auto-commit without ever publishing it): the auto-commit MUST be a real,
        // broadcastable kind-445 commit carrying the pseudonymous nostr_group_id —
        // never the raw MLS group id (Rule 4) — i.e. the exact wire artifact the
        // old optimistic-confirm path dropped. The cross-member convergence proof
        // (a third member receiving THIS published commit) lives in
        // `selfremove_autopublish_e2e`.
        let commit = captured_commit.expect("the eviction surfaced a publishable auto-commit");
        assert_eq!(
            commit.kind,
            nostr::Kind::Custom(445),
            "the auto-commit is a kind-445 group message ready for the circle's relays"
        );
        helpers::assert_no_raw_mls_group_id_leak(&commit, g.group_id.as_slice(), &g.nostr_group_id);

        g.cleanup();
    }
}
