//! MLS group context for location sharing.
//!
//! This module provides the `MlsGroupContext` which wraps MDK group state
//! and provides the interface needed for encrypting and decrypting location events.

use std::sync::Arc;

use nostr::prelude::{Event, UnsignedEvent};

use super::manager::MdkManager;
use super::types::{GroupId, MessageProcessingResult};
use crate::nostr::error::{NostrError, Result};

/// Context for an MLS group used for location sharing.
///
/// This struct holds the necessary state to encrypt and decrypt location events
/// using MDK. It wraps an `MdkManager` and `GroupId` to provide a simplified
/// interface for location-specific operations.
///
/// # Security
///
/// - Exporter secrets are managed internally by MDK (never exposed)
/// - Each epoch has a unique exporter secret
/// - Forward secrecy is maintained by MDK when processing commits
///
/// # Example
///
/// ```no_run
/// use std::sync::Arc;
/// use std::path::Path;
/// use haven_core::nostr::mls::{MdkManager, MlsGroupContext};
/// use haven_core::nostr::mls::types::GroupId;
///
/// let manager = Arc::new(MdkManager::new(Path::new("/tmp/data")).unwrap());
/// let group_id = GroupId::from_slice(&[1, 2, 3]);
/// let ctx = MlsGroupContext::new(manager, group_id, "nostr-group-id");
/// ```
pub struct MlsGroupContext {
    /// The Nostr group ID (used in h tag for routing)
    nostr_group_id: String,

    /// Reference to the MDK manager
    manager: Arc<MdkManager>,

    /// The MLS group ID
    group_id: GroupId,
}

impl MlsGroupContext {
    /// Creates a new MLS group context.
    ///
    /// # Arguments
    ///
    /// * `manager` - Reference to the MDK manager
    /// * `group_id` - The MLS group ID
    /// * `nostr_group_id` - The Nostr group identifier (for h tag routing)
    ///
    /// # Example
    ///
    /// ```no_run
    /// use std::sync::Arc;
    /// use std::path::Path;
    /// use haven_core::nostr::mls::{MdkManager, MlsGroupContext};
    /// use haven_core::nostr::mls::types::GroupId;
    ///
    /// let manager = Arc::new(MdkManager::new(Path::new("/tmp/data")).unwrap());
    /// let group_id = GroupId::from_slice(&[1, 2, 3]);
    /// let ctx = MlsGroupContext::new(manager, group_id, "nostr-group-hex");
    /// ```
    #[must_use]
    pub fn new(manager: Arc<MdkManager>, group_id: GroupId, nostr_group_id: &str) -> Self {
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
    #[must_use]
    pub const fn mls_group_id(&self) -> &GroupId {
        &self.group_id
    }

    /// Returns a reference to the MDK manager.
    #[must_use]
    pub const fn manager(&self) -> &Arc<MdkManager> {
        &self.manager
    }

    /// Returns the current epoch number.
    ///
    /// The epoch is queried from MDK's group state.
    ///
    /// # Errors
    ///
    /// Returns an error if the group cannot be found.
    pub fn epoch(&self) -> Result<u64> {
        let group = self
            .manager
            .get_group(&self.group_id)?
            .ok_or_else(|| NostrError::GroupNotFound(hex::encode(self.group_id.as_slice())))?;
        Ok(group.epoch)
    }

    /// Validates that this context can be used for the given epoch.
    ///
    /// # Errors
    ///
    /// Returns an error if the epoch doesn't match or if the group cannot be found.
    pub fn validate_epoch(&self, expected_epoch: u64) -> Result<()> {
        let current = self.epoch()?;
        if current != expected_epoch {
            return Err(NostrError::ExporterSecretUnavailable(expected_epoch));
        }
        Ok(())
    }

    /// Encrypts an unsigned event (rumor) for this group.
    ///
    /// This delegates to MDK's `create_message` which handles:
    /// - MLS encryption using the group's current epoch key
    /// - Event signing
    /// - Creating a kind 445 outer event
    ///
    /// # Arguments
    ///
    /// * `rumor` - The unsigned event to encrypt
    ///
    /// # Returns
    ///
    /// A fully signed and encrypted Nostr event (kind 445) ready for relay transmission.
    ///
    /// # Errors
    ///
    /// Returns an error if encryption fails.
    pub fn encrypt_event(&self, rumor: UnsignedEvent) -> Result<Event> {
        self.manager.create_message(&self.group_id, rumor)
    }

    /// Decrypts a received event for this group.
    ///
    /// This delegates to MDK's `process_message` which handles:
    /// - Signature verification
    /// - MLS decryption
    /// - Epoch validation and updates
    ///
    /// # Arguments
    ///
    /// * `event` - The encrypted event to decrypt
    ///
    /// # Returns
    ///
    /// A `MessageProcessingResult` indicating the type of message:
    /// - `ApplicationMessage` - Contains the decrypted content
    /// - `Proposal` / `Commit` / `ExternalJoinProposal` - Group management messages
    /// - `Unprocessable` - Message could not be processed
    ///
    /// # Errors
    ///
    /// Returns an error if decryption or processing fails.
    pub fn decrypt_event(&self, event: &Event) -> Result<MessageProcessingResult> {
        self.manager.process_message(event)
    }
}

impl std::fmt::Debug for MlsGroupContext {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MlsGroupContext")
            .field("nostr_group_id", &self.nostr_group_id)
            .field("group_id", &hex::encode(self.group_id.as_slice()))
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn temp_dir() -> PathBuf {
        let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
        env::temp_dir().join(format!("haven_ctx_test_{}_{}", std::process::id(), id))
    }

    fn test_manager() -> (Arc<MdkManager>, PathBuf) {
        let dir = temp_dir();
        let manager = Arc::new(MdkManager::new_unencrypted(&dir).expect("create manager"));
        (manager, dir)
    }

    fn cleanup(dir: &PathBuf) {
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn new_creates_context() {
        let (manager, dir) = test_manager();
        let group_id = GroupId::from_slice(&[1, 2, 3]);
        let ctx = MlsGroupContext::new(manager, group_id, "test-group");

        assert_eq!(ctx.nostr_group_id(), "test-group");
        assert_eq!(ctx.mls_group_id().as_slice(), &[1, 2, 3]);

        cleanup(&dir);
    }

    #[test]
    fn manager_returns_reference() {
        let (manager, dir) = test_manager();
        let group_id = GroupId::from_slice(&[1, 2, 3]);
        let ctx = MlsGroupContext::new(manager.clone(), group_id, "test");

        // Should return the same manager
        assert!(Arc::ptr_eq(ctx.manager(), &manager));

        cleanup(&dir);
    }

    #[test]
    fn debug_output_contains_group_info() {
        let (manager, dir) = test_manager();
        let group_id = GroupId::from_slice(&[1, 2, 3]);
        let ctx = MlsGroupContext::new(manager, group_id, "my-group");

        let debug_output = format!("{ctx:?}");

        assert!(debug_output.contains("MlsGroupContext"));
        assert!(debug_output.contains("my-group"));
        assert!(debug_output.contains("010203")); // hex-encoded group_id

        cleanup(&dir);
    }

    #[test]
    fn epoch_fails_for_nonexistent_group() {
        let (manager, dir) = test_manager();
        let fake_group_id = GroupId::from_slice(&[99, 99, 99]);
        let ctx = MlsGroupContext::new(manager, fake_group_id, "test");

        let result = ctx.epoch();
        assert!(result.is_err());

        cleanup(&dir);
    }

    #[test]
    fn validate_epoch_fails_for_nonexistent_group() {
        let (manager, dir) = test_manager();
        let fake_group_id = GroupId::from_slice(&[99, 99, 99]);
        let ctx = MlsGroupContext::new(manager, fake_group_id, "test");

        let result = ctx.validate_epoch(1);
        assert!(result.is_err());

        cleanup(&dir);
    }

    #[test]
    fn different_contexts_have_different_nostr_ids() {
        let (manager, dir) = test_manager();
        let group_id = GroupId::from_slice(&[1, 2, 3]);

        let ctx1 = MlsGroupContext::new(manager.clone(), group_id.clone(), "group-1");
        let ctx2 = MlsGroupContext::new(manager, group_id, "group-2");

        assert_ne!(ctx1.nostr_group_id(), ctx2.nostr_group_id());

        cleanup(&dir);
    }
}
