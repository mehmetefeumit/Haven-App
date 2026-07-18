//! MLS group context for location sharing.
//!
//! This module provides [`MlsGroupContext`], a thin holder pairing a
//! [`SessionManager`] with one group's identifiers. It exposes the group's
//! transport (Nostr) id for h-tag routing and async encrypt/decrypt helpers
//! that delegate to the engine session.

use std::sync::Arc;

use nostr::prelude::{Event, UnsignedEvent};

use super::manager::SessionManager;
use super::types::GroupId;
use crate::nostr::error::{NostrError, Result};
use cgka_session::{IngestEffects, SessionEffects};

/// Context for an MLS group used for location sharing.
///
/// Holds an `Arc<SessionManager>` plus the MLS `GroupId` and the transport
/// `nostr_group_id`, providing a group-scoped interface for encrypt/decrypt.
///
/// # Security
///
/// - Exporter secrets are managed internally by the engine (never exposed).
/// - Each epoch has a unique exporter secret; forward secrecy is maintained by
///   the engine when it applies commits.
/// - The real MLS `GroupId` is `pub(crate)` and Debug-redacted; downstream /
///   FFI code uses [`Self::nostr_group_id`] instead (Rule 4).
pub struct MlsGroupContext {
    /// The Nostr group ID (used in the h tag for routing).
    nostr_group_id: String,
    /// Reference to the session manager.
    manager: Arc<SessionManager>,
    /// The MLS group ID.
    group_id: GroupId,
}

impl MlsGroupContext {
    /// Creates a new MLS group context.
    #[must_use]
    pub fn new(manager: Arc<SessionManager>, group_id: GroupId, nostr_group_id: &str) -> Self {
        Self {
            nostr_group_id: nostr_group_id.to_string(),
            manager,
            group_id,
        }
    }

    /// Returns the Nostr group ID for the h tag.
    #[must_use]
    pub fn nostr_group_id(&self) -> &str {
        &self.nostr_group_id
    }

    /// Returns the MLS group ID.
    ///
    /// `pub(crate)` to prevent downstream code (including FFI) from accessing the
    /// real MLS group ID. Use [`Self::nostr_group_id`] for external identifiers.
    // Dark Matter: consumed by DM-4's FFI group-lifecycle surface; only the
    // context unit test exercises it in the current lib build.
    #[allow(dead_code)]
    #[must_use]
    pub(crate) const fn mls_group_id(&self) -> &GroupId {
        &self.group_id
    }

    /// Returns a reference to the session manager.
    #[must_use]
    pub const fn manager(&self) -> &Arc<SessionManager> {
        &self.manager
    }

    /// Returns the current epoch number.
    ///
    /// # Errors
    ///
    /// Returns an error if the group cannot be found.
    pub async fn epoch(&self) -> Result<u64> {
        self.manager.epoch(&self.group_id).await
    }

    /// Validates that this context can be used for the given epoch.
    ///
    /// # Errors
    ///
    /// Returns an error if the epoch doesn't match or the group is not found.
    pub async fn validate_epoch(&self, expected_epoch: u64) -> Result<()> {
        let current = self.epoch().await?;
        if current != expected_epoch {
            return Err(NostrError::ExporterSecretUnavailable(expected_epoch));
        }
        Ok(())
    }

    /// Encrypts an unsigned inner rumor for this group.
    ///
    /// Delegates to [`SessionManager::create_message`], which enforces the W9
    /// inner-sender invariant and returns the publishable transport work.
    ///
    /// # Errors
    ///
    /// Returns an error if encryption/send fails.
    pub async fn encrypt_event(&self, rumor: UnsignedEvent) -> Result<SessionEffects> {
        self.manager.create_message(&self.group_id, rumor).await
    }

    /// Decrypts / ingests a received event for this group.
    ///
    /// Delegates to [`SessionManager::process_event`]. The returned
    /// [`IngestEffects`] carries the ingest outcome and any drained events for
    /// the caller to fold via [`SessionManager::location_result_from_event`].
    ///
    /// # Errors
    ///
    /// Returns an error only for hard ingest failures.
    pub async fn decrypt_event(&self, event: &Event) -> Result<IngestEffects> {
        self.manager.process_event(event).await
    }
}

impl std::fmt::Debug for MlsGroupContext {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MlsGroupContext")
            .field("nostr_group_id", &self.nostr_group_id)
            .field("group_id", &"<redacted>")
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::Keys;
    use std::env;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn temp_dir() -> PathBuf {
        let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
        env::temp_dir().join(format!("haven_ctx_test_{}_{}", std::process::id(), id))
    }

    fn test_manager() -> (Arc<SessionManager>, PathBuf) {
        let dir = temp_dir();
        let keys = Keys::generate();
        let manager =
            Arc::new(SessionManager::new_unencrypted(&dir, &keys).expect("create manager"));
        (manager, dir)
    }

    fn cleanup(dir: &PathBuf) {
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn new_creates_context() {
        let (manager, dir) = test_manager();
        let group_id = GroupId::new(vec![1, 2, 3]);
        let ctx = MlsGroupContext::new(manager, group_id, "test-group");
        assert_eq!(ctx.nostr_group_id(), "test-group");
        assert_eq!(ctx.mls_group_id().as_slice(), &[1, 2, 3]);
        cleanup(&dir);
    }

    #[test]
    fn manager_returns_reference() {
        let (manager, dir) = test_manager();
        let group_id = GroupId::new(vec![1, 2, 3]);
        let ctx = MlsGroupContext::new(manager.clone(), group_id, "test");
        assert!(Arc::ptr_eq(ctx.manager(), &manager));
        cleanup(&dir);
    }

    #[test]
    fn debug_redacts_group_id() {
        let (manager, dir) = test_manager();
        let group_id = GroupId::new(vec![1, 2, 3]);
        let ctx = MlsGroupContext::new(manager, group_id, "my-group");
        let out = format!("{ctx:?}");
        assert!(out.contains("MlsGroupContext"));
        assert!(out.contains("my-group"));
        assert!(out.contains("<redacted>"));
        assert!(!out.contains("010203"));
        cleanup(&dir);
    }

    #[tokio::test]
    async fn epoch_fails_for_nonexistent_group() {
        let (manager, dir) = test_manager();
        let ctx = MlsGroupContext::new(manager, GroupId::new(vec![99, 99, 99]), "test");
        assert!(ctx.epoch().await.is_err());
        cleanup(&dir);
    }

    #[tokio::test]
    async fn validate_epoch_fails_for_nonexistent_group() {
        let (manager, dir) = test_manager();
        let ctx = MlsGroupContext::new(manager, GroupId::new(vec![99, 99, 99]), "test");
        assert!(ctx.validate_epoch(1).await.is_err());
        cleanup(&dir);
    }
}
