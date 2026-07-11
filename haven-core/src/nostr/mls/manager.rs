//! MDK Manager for group and message operations.
//!
//! This module provides `MdkManager`, the main interface for MDK operations
//! in haven-core. It wraps the MDK library and provides a simplified API
//! for location sharing use cases.

use std::path::Path;

use mdk_core::prelude::*;
use mdk_core::MDK;
use mdk_sqlite_storage::MdkSqliteStorage;
use nostr::prelude::*;

use super::storage::StorageConfig;
use super::types::{
    CommitClassification, KeyPackageBundle, LocationGroupConfig, LocationMessageResult, MlsGroup,
    MlsMessage, MlsWelcome,
};
use crate::nostr::error::{NostrError, Result};

/// Redacts long hex sequences from error messages to prevent MLS group ID leakage.
///
/// Replaces any contiguous hex sequence of 16+ characters with `[REDACTED]`.
/// MDK errors may include raw MLS group IDs which must not reach the UI.
#[must_use]
pub fn redact_hex_sequences(msg: &str) -> String {
    let bytes = msg.as_bytes();
    let mut result = String::with_capacity(msg.len());
    let mut i = 0;

    while i < bytes.len() {
        if bytes[i].is_ascii_hexdigit() {
            let start = i;
            while i < bytes.len() && bytes[i].is_ascii_hexdigit() {
                i += 1;
            }
            if i - start >= 16 {
                result.push_str("[REDACTED]");
            } else {
                result.push_str(&msg[start..i]);
            }
        } else {
            result.push(bytes[i] as char);
            i += 1;
        }
    }

    result
}

/// The result of [`MdkManager::process_message_classified`].
///
/// Folds the three live-sync-relevant outcomes — a processed message, a
/// buffer-eligible competing commit, and any other (redacted) failure — into a
/// single enum so the engine cannot treat a competing-commit error as fatal.
#[derive(Debug)]
pub enum ClassifiedProcessing {
    /// The message was processed; carries the MDK result. Boxed because
    /// `MessageProcessingResult` is much larger than the other variants and this
    /// enum is a transient return value (boxing keeps the move cheap without a
    /// hot-path penalty on the failure arms).
    Processed(Box<MessageProcessingResult>),
    /// A same-epoch sibling commit racing our own pending commit. The engine
    /// buffers the raw event for MIP-03 convergence; the cursor must not advance.
    CompetingCommit,
    /// Any other failure. The detail is already redacted (Security Rule 8).
    Failed(String),
}

/// The MLS `content_type` of a settle-window competitor, read by
/// [`MdkManager::peek_content_type`] WITHOUT any group mutation (REV-1
/// corroboration-gate fork-prevention peek).
///
/// The leave-convergence fix partitions settle-window competitors by this
/// classification BEFORE the destructive trial-apply: a [`Self::Proposal`] (e.g.
/// a peer `SelfRemove`) is SKIPPED (never trial-applied — the fork-prevention
/// half), a [`Self::Commit`] is a genuine convergence competitor, a
/// [`Self::Application`] is a Location to collect, and a [`Self::Unpeekable`]
/// (no stored secret / undecryptable / unparseable) is a fail-safe
/// NON-destructive skip. The peek NEVER reads the competitor's `sender()`
/// (corroboration-gate), so a forged-sender `SelfRemove` cannot evict a victim.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeekedContent {
    /// An MLS Proposal (any wire format) — DEFER, never trial-apply.
    Proposal,
    /// An MLS Commit (any wire format) — a genuine convergence competitor.
    Commit,
    /// An MLS application message (a Location) — collect, never a competitor.
    Application,
    /// No stored exporter secret for the peek epoch, or the outer layer failed
    /// to decrypt/parse — fail-safe NON-destructive skip (never trial-apply).
    Unpeekable,
}

/// Classifies an MDK `process_message` error for the live-sync settle machinery.
///
/// A same-epoch sibling commit racing our own pending commit surfaces from MDK
/// as [`mdk_core::Error::OwnCommitPending`]; a stale commit re-applied after a
/// rollback can surface as [`mdk_core::Error::CannotDecryptOwnMessage`]; and a
/// commit one epoch behind surfaces as
/// [`mdk_core::Error::ProcessMessageWrongEpoch`] with the `is_commit` flag set.
/// All three are buffer-eligible competitors; every other error is a plain drop.
///
/// Reads only the error discriminant (and the `WrongEpoch` `is_commit` flag) —
/// no secret material is inspected. See
/// [`crate::nostr::mls::CommitClassification`].
#[must_use]
pub const fn classify_mdk_error(err: &mdk_core::Error) -> CommitClassification {
    match err {
        mdk_core::Error::OwnCommitPending | mdk_core::Error::CannotDecryptOwnMessage => {
            CommitClassification::CompetingCommit
        }
        mdk_core::Error::ProcessMessageWrongEpoch(_, is_commit) if *is_commit => {
            CommitClassification::CompetingCommit
        }
        _ => CommitClassification::Other,
    }
}

/// Extension trait for converting MDK errors to `NostrError`.
///
/// Redacts potential MLS group IDs from error messages before propagation.
trait MdkResultExt<T> {
    /// Converts the error to a `NostrError::MdkError` with redacted hex sequences.
    fn map_mdk_err(self) -> Result<T>;
}

impl<T, E: std::fmt::Display> MdkResultExt<T> for std::result::Result<T, E> {
    fn map_mdk_err(self) -> Result<T> {
        self.map_err(|e| NostrError::MdkError(redact_hex_sequences(&e.to_string())))
    }
}

/// Manager for MDK operations.
///
/// This struct wraps MDK and provides a high-level API for:
/// - Group creation and management
/// - Message encryption and decryption
/// - Welcome handling for group joining
///
/// # Example
///
/// ```no_run
/// use std::path::Path;
/// use haven_core::nostr::mls::MdkManager;
///
/// let manager = MdkManager::new(Path::new("/path/to/data")).unwrap();
/// ```
pub struct MdkManager {
    mdk: MDK<MdkSqliteStorage>,
}

impl MdkManager {
    /// Creates a new MDK manager with `SQLite` storage.
    ///
    /// # Arguments
    ///
    /// * `data_dir` - Path to the directory for storing the MDK database
    ///
    /// # Errors
    ///
    /// Returns an error if the storage cannot be initialized.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use std::path::Path;
    /// use haven_core::nostr::mls::MdkManager;
    ///
    /// let manager = MdkManager::new(Path::new("/path/to/data")).unwrap();
    /// ```
    pub fn new(data_dir: &Path) -> Result<Self> {
        let storage_config = StorageConfig::new(data_dir);
        let storage = storage_config.create_storage()?;
        let mdk = MDK::new(storage);

        Ok(Self { mdk })
    }

    /// Creates a new `MdkManager` with unencrypted storage.
    ///
    /// # Warning
    ///
    /// This creates an unencrypted database. Sensitive MLS state will be stored
    /// in plaintext. Only use this for testing or development purposes.
    ///
    /// # Arguments
    ///
    /// * `data_dir` - Path to the directory where MDK data will be stored
    ///
    /// # Errors
    ///
    /// Returns an error if the storage cannot be initialized.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn new_unencrypted(data_dir: &Path) -> Result<Self> {
        let storage_config = StorageConfig::new(data_dir);
        let storage = storage_config.create_storage_unencrypted()?;
        let mdk = MDK::new(storage);

        Ok(Self { mdk })
    }

    /// Creates a new location sharing group.
    ///
    /// # Arguments
    ///
    /// * `creator_pubkey` - The Nostr public key (hex) of the group creator
    /// * `member_key_packages` - Key package events for initial members
    /// * `config` - Group configuration
    ///
    /// # Returns
    ///
    /// Returns `GroupResult` containing the created group and welcome messages
    /// for the other members.
    ///
    /// # Errors
    ///
    /// Returns an error if group creation fails.
    pub fn create_group(
        &self,
        creator_pubkey: &str,
        member_key_packages: Vec<Event>,
        config: LocationGroupConfig,
    ) -> Result<GroupResult> {
        // Parse creator pubkey
        let creator_pk = PublicKey::from_hex(creator_pubkey)
            .map_err(|e| NostrError::InvalidEvent(format!("Invalid creator pubkey: {e}")))?;

        // Parse relay URLs
        let relays: Vec<RelayUrl> = config
            .relays
            .iter()
            .filter_map(|r| RelayUrl::parse(r).ok())
            .collect();

        // Parse admin pubkeys
        let admins: Vec<PublicKey> = config
            .admins
            .iter()
            .filter_map(|pk| PublicKey::from_hex(pk).ok())
            .collect();

        // Build MDK config
        let mdk_config = NostrGroupConfigData::new(
            config.name,
            config.description,
            None, // image_hash
            None, // image_key
            None, // image_nonce
            relays,
            admins,
        );

        // Create the group
        self.mdk
            .create_group(&creator_pk, member_key_packages, mdk_config)
            .map_mdk_err()
    }

    /// Processes a welcome message.
    ///
    /// This stores the welcome and prepares it for acceptance.
    ///
    /// # Arguments
    ///
    /// * `wrapper_event_id` - The ID of the gift-wrapped event
    /// * `rumor_event` - The decrypted rumor event containing the welcome
    ///
    /// # Returns
    ///
    /// Returns the stored welcome.
    ///
    /// # Errors
    ///
    /// Returns an error if the welcome cannot be processed.
    pub fn process_welcome(
        &self,
        wrapper_event_id: &EventId,
        rumor_event: &UnsignedEvent,
    ) -> Result<MlsWelcome> {
        self.mdk
            .process_welcome(wrapper_event_id, rumor_event)
            .map_mdk_err()
    }

    /// Accepts a welcome message to join a group.
    ///
    /// # Arguments
    ///
    /// * `welcome` - The welcome to accept
    ///
    /// # Errors
    ///
    /// Returns an error if the welcome cannot be accepted.
    pub fn accept_welcome(&self, welcome: &MlsWelcome) -> Result<()> {
        self.mdk.accept_welcome(welcome).map_mdk_err()
    }

    /// Declines a welcome message, marking the group as inactive.
    ///
    /// # Errors
    ///
    /// Returns an error if the welcome cannot be declined.
    pub fn decline_welcome(&self, welcome: &MlsWelcome) -> Result<()> {
        self.mdk.decline_welcome(welcome).map_mdk_err()
    }

    /// Gets pending welcome messages that haven't been accepted yet.
    ///
    /// # Returns
    ///
    /// A list of pending welcomes.
    ///
    /// # Errors
    ///
    /// Returns an error if welcomes cannot be retrieved.
    pub fn get_pending_welcomes(&self) -> Result<Vec<MlsWelcome>> {
        self.mdk.get_pending_welcomes(None).map_mdk_err()
    }

    /// Creates an encrypted message for a group.
    ///
    /// This takes an unsigned Nostr event (the "rumor") and encrypts it
    /// using MLS for the specified group.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID
    /// * `rumor` - The unsigned event to encrypt
    /// * `expiration` - Optional NIP-40 absolute timestamp attached to the
    ///   outer kind:445 wrapper. When `Some`, relays honoring NIP-40 will
    ///   drop the event after that time. This wrapper builds the MDK
    ///   `EventTag::expiration` internally so that `mdk_core` types do not
    ///   leak into haven-core's surface.
    ///
    ///   **Protocol invariant — only location messages set this.** Welcomes,
    ///   commits, and proposals MUST pass `None`. MLS state recovery requires
    ///   every commit since an offline member's last known epoch; expired
    ///   commits desync the offline member with no recovery path short of
    ///   re-Welcome. Locations may TTL because stale coordinates carry no
    ///   value; commits are the durable backbone of group state. The
    ///   regression tests `add_members_evolution_event_has_no_expiration_tag`,
    ///   `remove_members_evolution_event_has_no_expiration_tag`, and
    ///   `self_update_evolution_event_has_no_expiration_tag` in
    ///   `circle/manager.rs` fail the build if this invariant breaks.
    ///
    /// # Returns
    ///
    /// Returns a signed, encrypted Nostr event (kind 445) ready for publishing.
    ///
    /// # Errors
    ///
    /// Returns an error if encryption fails.
    pub fn create_message(
        &self,
        group_id: &GroupId,
        rumor: UnsignedEvent,
        expiration: Option<Timestamp>,
    ) -> Result<Event> {
        let tags = expiration.map(|ts| vec![EventTag::expiration(ts)]);
        self.mdk.create_message(group_id, rumor, tags).map_mdk_err()
    }

    /// Processes an incoming encrypted message.
    ///
    /// This decrypts and processes a kind 445 MLS group message.
    ///
    /// # Arguments
    ///
    /// * `event` - The encrypted event to process
    ///
    /// # Returns
    ///
    /// Returns `MessageProcessingResult` indicating the type of message
    /// (application message, proposal, commit, etc.).
    ///
    /// # Errors
    ///
    /// Returns an error if decryption or processing fails.
    pub fn process_message(&self, event: &Event) -> Result<MessageProcessingResult> {
        self.mdk.process_message(event).map_mdk_err()
    }

    /// Processes an incoming event, classifying any failure for the live-sync
    /// settle machinery.
    ///
    /// Unlike [`Self::process_message`], a failure is not collapsed to an opaque
    /// string: a same-epoch sibling commit racing our own pending commit
    /// (MDK `OwnCommitPending` / stale `WrongEpoch`-commit /
    /// `CannotDecryptOwnMessage`) is surfaced as
    /// [`ClassifiedProcessing::CompetingCommit`] so the engine can buffer it for
    /// convergence instead of dropping it and forking the group. Every other
    /// failure becomes [`ClassifiedProcessing::Failed`] with a redacted detail.
    ///
    /// This never returns a `Result`: it folds success and the three outcome
    /// classes into one enum so the caller cannot accidentally treat a
    /// competing-commit error as a fatal error.
    pub fn process_message_classified(&self, event: &Event) -> ClassifiedProcessing {
        match self.mdk.process_message(event) {
            Ok(result) => ClassifiedProcessing::Processed(Box::new(result)),
            Err(ref e) => match classify_mdk_error(e) {
                CommitClassification::CompetingCommit => ClassifiedProcessing::CompetingCommit,
                CommitClassification::Other => {
                    ClassifiedProcessing::Failed(redact_hex_sequences(&e.to_string()))
                }
            },
        }
    }

    /// Non-destructively classifies a settle-window competitor by its MLS
    /// `content_type`, decrypting ONLY the outer exporter-secret layer at the
    /// pre-merge `epoch` — no `MlsGroup` mutation, no ratchet advance, no storage
    /// write (REV-1 corroboration-gate fork-prevention peek).
    ///
    /// Returns [`PeekedContent::Unpeekable`] (a fail-safe skip) whenever the
    /// stored exporter secret for `epoch` is absent or the outer layer fails to
    /// decrypt/parse, so the walk NEVER trial-applies an unpeekable competitor.
    /// The ChaCha20-Poly1305 decrypt byte-matches MDK's
    /// `decrypt_message_with_exporter_secret` (the BLOCKING decrypt-parity gate),
    /// so a competitor the peek can decrypt is classified exactly as MDK would.
    /// (The NIP-44 legacy fallback is enabled unconditionally here rather than
    /// gated per-event as MDK does — that only widens WHICH events decrypt, never
    /// the resulting `content_type`, and any divergence fails safe; see
    /// [`super::peek_crypto`].)
    pub fn peek_content_type(
        &self,
        event: &Event,
        group_id: &GroupId,
        epoch: u64,
    ) -> PeekedContent {
        use openmls::prelude::tls_codec::Deserialize as _;
        use openmls::prelude::{ContentType, MlsMessageIn};

        // 1. Fetch the STORED exporter secret at the PRE-MERGE `epoch` (never
        //    `epoch + 1`, which would fail open into the exact REV-1 fork). A
        //    None secret — never stored, or pruned out of the retention window —
        //    fails SAFE: we never guess a classification.
        let Ok(Some(secret)) = self.stored_exporter_secret(group_id, epoch) else {
            return PeekedContent::Unpeekable;
        };

        // 2. Decrypt ONLY the outer exporter-secret layer, byte-for-byte as MDK
        //    does (ChaCha20-Poly1305 + the NIP-44 legacy fallback). The decrypted
        //    transport bytes live in a `Zeroizing` buffer and are scrubbed at the
        //    end of this scope. Any decrypt failure fails SAFE to `Unpeekable`.
        //    NB: this does NOT decrypt the inner MLS ciphertext — a Location's
        //    coordinates stay ratchet-keyed and are never exposed here.
        let Some(plaintext) = super::peek_crypto::decrypt_message_with_any_supported_format(
            &secret,
            &event.content,
            true,
        ) else {
            return PeekedContent::Unpeekable;
        };

        // 3. Read the MLS `content_type` — the SAME pre-decryption cleartext
        //    routing field MDK reads before `process_message` (process.rs:57), so
        //    the peek and MDK can never disagree. Read-only: no `MlsGroup`
        //    mutation, no ratchet advance, no storage write. Any parse failure
        //    (incl. a non-protocol body like a Welcome/KeyPackage) fails SAFE.
        let Ok(mls_message) = MlsMessageIn::tls_deserialize_exact(plaintext.as_slice()) else {
            return PeekedContent::Unpeekable;
        };
        let Ok(protocol_message) = mls_message.try_into_protocol_message() else {
            return PeekedContent::Unpeekable;
        };

        match protocol_message.content_type() {
            ContentType::Proposal => PeekedContent::Proposal,
            ContentType::Commit => PeekedContent::Commit,
            ContentType::Application => PeekedContent::Application,
        }
    }

    /// Returns the STORED MIP-03 group-event exporter secret for `epoch`, or
    /// `None` when it was never stored or has aged out of MDK's retention window.
    ///
    /// This is the un-gated PRODUCTION sibling of the `#[cfg(test)]`
    /// [`Self::get_stored_exporter_secret`] (which returns only a `bool`): the
    /// REV-1 [`Self::peek_content_type`] peek needs the raw secret BYTES to
    /// decrypt a competitor's outer layer at the pre-merge epoch. It stays
    /// strictly in-Rust — the raw secret is borrowed, used, and dropped
    /// (zeroized) within the peek and is NEVER exposed over the FFI boundary.
    ///
    /// Reaches the storage provider through the public `OpenMlsProvider` trait
    /// (the same path as [`Self::has_live_key_material`]), so no MDK edit is
    /// needed.
    ///
    /// # Errors
    ///
    /// Returns an error (hex-redacted) if the underlying storage query fails.
    fn stored_exporter_secret(
        &self,
        group_id: &GroupId,
        epoch: u64,
    ) -> Result<Option<group_types::GroupExporterSecret>> {
        use mdk_storage_traits::groups::GroupStorage;
        use openmls_traits::OpenMlsProvider;

        self.mdk
            .provider
            .storage()
            .get_group_exporter_secret(group_id, epoch)
            .map_mdk_err()
    }

    /// After an epoch-advancing commit applies, sweep this group's out-of-order
    /// FUTURE-epoch decrypt failures (`state=Failed, epoch IS NULL`) back to
    /// `Retryable`, so a re-delivered successor commit is no longer permanently
    /// rejected by MDK's Step-0 dedup once its predecessor has advanced us into
    /// the reachable epoch. Returns the number of rows swept.
    ///
    /// ## Why this is needed (and fork-safe)
    ///
    /// The live-sync engine feeds MDK commits in relay-arrival order (no
    /// `created_at` sort). A commit framed for a FUTURE epoch (N+1→N+2) arriving
    /// before its predecessor (N→N+1) fails the outer exporter-secret decrypt,
    /// and MDK records it `state=Failed, epoch=NULL` in the persistent
    /// `processed_messages` table. MDK's Step-0 dedup then returns a cached
    /// `Unprocessable` for that `event_id` FOREVER — even after the predecessor
    /// advances us into its epoch — because MDK sweeps `Failed → Retryable` ONLY
    /// inside its `is_better_candidate` ROLLBACK path, never on a plain forward
    /// apply. Left unswept the member is stuck an epoch behind, restart-proof
    /// (the table is persistent `SQLCipher`).
    ///
    /// This reuses MDK's OWN retry primitives — the exact
    /// `find_failed_messages_for_retry` + `mark_processed_message_retryable`
    /// pair MDK runs after a rollback (`mdk-core` `messages/error_handling.rs`)
    /// — through the public `OpenMlsProvider::storage()` handle (same access path
    /// as [`Self::stored_exporter_secret`]). No second `SQLite` connection (the MDK
    /// DB is rollback-journal with `busy_timeout = 0`, so a 2nd writer would risk
    /// `SQLITE_BUSY`) and no raw SQL. The caller MUST hold `crate::write_lock`
    /// (this is an MDK-DB write).
    ///
    /// **Fork-safe by construction:** `find_failed_messages_for_retry` is scoped
    /// to `mls_group_id = ? AND state='failed' AND epoch IS NULL`. A same-epoch
    /// convergence race LOSER always reaches MDK's INNER MLS layer (epoch N's
    /// secret is in the lookback window) and is recorded with a concrete
    /// `epoch = Some(N)` — so it is EXCLUDED by the `epoch IS NULL` filter and can
    /// never be swept; only genuine future/pruned-epoch decrypt failures qualify.
    /// The sweep flips a dedup STATE flag only; it never applies MLS state —
    /// re-delivery still runs the full processor regime gate + MDK validation.
    ///
    /// ## Remove on the MDK Dark-Matter migration
    ///
    /// This works around upstream MDK issue #633 ("Future-epoch application
    /// messages permanently lost in stored convergence"), fixed ONLY in the
    /// post-0.9 "Dark Matter" rewrite via a stored-convergence buffer. Our pin
    /// (mdk-core 0.7.1, rev 93ae324) and the last old-line release (v0.8.0) have
    /// byte-identical failure-path files, so the recovery must live here until we
    /// migrate to MDK >0.9 — at which point DELETE this method and its call sites.
    /// See <https://github.com/marmot-protocol/mdk/issues/633>.
    ///
    /// # Errors
    ///
    /// Errors only if the initial `find_failed_messages_for_retry` query fails.
    /// A per-row `mark_processed_message_retryable` failure (incl. the expected
    /// `NotFound` when the row is already non-`failed`) is logged hex-redacted and
    /// skipped — best-effort, mirroring mdk-core's own rollback loop; never the
    /// `event_id` (Security Rule 6/8).
    pub fn retry_failed_future_epoch_messages(&self, group_id: &GroupId) -> Result<usize> {
        use mdk_storage_traits::messages::MessageStorage;
        use openmls_traits::OpenMlsProvider;

        let storage = self.mdk.provider.storage();
        let event_ids = storage
            .find_failed_messages_for_retry(group_id)
            .map_mdk_err()?;
        let mut swept = 0usize;
        for event_id in &event_ids {
            if let Err(e) = storage.mark_processed_message_retryable(event_id) {
                log::debug!(
                    "retry_failed_future_epoch_messages: mark retryable skipped: {}",
                    redact_hex_sequences(&e.to_string())
                );
            } else {
                swept += 1;
            }
        }
        Ok(swept)
    }

    /// Gets a specific group by ID.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID
    ///
    /// # Returns
    ///
    /// Returns `Some(Group)` if found, `None` otherwise.
    ///
    /// # Errors
    ///
    /// Returns an error if the storage cannot be accessed.
    pub fn get_group(&self, group_id: &GroupId) -> Result<Option<MlsGroup>> {
        self.mdk.get_group(group_id).map_mdk_err()
    }

    /// Gets all groups.
    ///
    /// # Returns
    ///
    /// Returns a list of all groups the user is a member of.
    ///
    /// # Errors
    ///
    /// Returns an error if the storage cannot be accessed.
    pub fn get_groups(&self) -> Result<Vec<MlsGroup>> {
        self.mdk.get_groups().map_mdk_err()
    }

    /// Gets all members of a group.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID
    ///
    /// # Returns
    ///
    /// Returns a set of member public keys.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is not found.
    pub fn get_members(&self, group_id: &GroupId) -> Result<std::collections::BTreeSet<PublicKey>> {
        self.mdk.get_members(group_id).map_mdk_err()
    }

    /// Returns the ratchet tree info for a group (test/feature-only).
    ///
    /// Exposes MDK's `get_ratchet_tree_info` so integration tests can assert
    /// MLS-level properties (e.g. MIP-00 Rule 1: MLS signing keys must differ
    /// from Nostr identity keys).
    ///
    /// # Errors
    ///
    /// Returns an error if the group is not found.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn get_ratchet_tree_info(
        &self,
        group_id: &GroupId,
    ) -> Result<mdk_core::prelude::RatchetTreeInfo> {
        self.mdk.get_ratchet_tree_info(group_id).map_mdk_err()
    }

    /// Reports whether a stored group-event exporter secret exists for a
    /// specific epoch (test/feature-only).
    ///
    /// Returns `Ok(true)` when the exporter secret is still retained for the
    /// given epoch, `Ok(false)` when it has been pruned (or was never stored).
    /// After pruning (see `max_past_epochs` in MDK config), old epoch
    /// secrets must no longer be retrievable — this accessor lets
    /// integration tests verify MIP-03 Rule 5 (exporter-secret lifecycle)
    /// without crossing the FFI boundary with raw secret bytes.
    ///
    /// # Errors
    ///
    /// Returns an error if the underlying storage query fails.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn get_stored_exporter_secret(&self, group_id: &GroupId, epoch: u64) -> Result<bool> {
        use mdk_storage_traits::groups::GroupStorage;
        use openmls_traits::OpenMlsProvider;

        // Pull the storage provider out through the OpenMlsProvider trait
        // (the concrete `storage` field on MdkProvider is private; MDK's own
        // `storage()` helper is pub(crate), so the trait method is the only
        // stable way in from a downstream crate).
        self.mdk
            .provider
            .storage()
            .get_group_exporter_secret(group_id, epoch)
            .map(|opt| opt.is_some())
            .map_mdk_err()
    }

    /// Leaves a group.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID to leave
    ///
    /// # Returns
    ///
    /// Returns an event that should be published to notify the group.
    ///
    /// # Errors
    ///
    /// Returns an error if leaving fails.
    pub fn leave_group(&self, group_id: &GroupId) -> Result<UpdateGroupResult> {
        self.mdk.leave_group(group_id).map_mdk_err()
    }

    /// Self-demotes the current user from admin status in a group.
    ///
    /// Admins must call this before leaving a group (MIP-03 requirement).
    /// After self-demotion, the pending commit must be merged before leaving.
    ///
    /// # Errors
    ///
    /// Returns an error if the user is not an admin or demotion fails.
    pub fn self_demote(&self, group_id: &GroupId) -> Result<UpdateGroupResult> {
        self.mdk.self_demote(group_id).map_mdk_err()
    }

    /// Performs a self-update on the user's leaf node in a group.
    ///
    /// This rotates the user's key material in the MLS tree, restoring
    /// forward secrecy after joining (MIP-02 MUST). The consumed
    /// `KeyPackage`'s `init_key` was published to relays — rotating it ensures
    /// that anyone who cached the `init_key` can no longer derive group secrets.
    ///
    /// Creates a pending commit that must be merged (on publish success)
    /// or cleared (on publish failure).
    ///
    /// # Errors
    ///
    /// Returns an error if the self-update proposal or commit fails.
    pub fn self_update(&self, group_id: &GroupId) -> Result<UpdateGroupResult> {
        self.mdk.self_update(group_id).map_mdk_err()
    }

    /// Returns group IDs that need a self-update.
    ///
    /// A group needs a self-update when:
    /// - `SelfUpdateState::Required` — post-join self-update not yet completed
    /// - `SelfUpdateState::CompletedAt(t)` — last rotation older than `threshold_secs`
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn groups_needing_self_update(&self, threshold_secs: u64) -> Result<Vec<GroupId>> {
        self.mdk
            .groups_needing_self_update(threshold_secs)
            .map_mdk_err()
    }

    /// Clears a pending MLS commit, rolling back a failed publish attempt.
    ///
    /// Call this when a relay publish fails after an operation that creates
    /// a pending commit (add/remove members, leave, self-update, etc.).
    ///
    /// # Errors
    ///
    /// Returns an error if there is no pending commit or clearing fails.
    pub fn clear_pending_commit(&self, group_id: &GroupId) -> Result<()> {
        self.mdk.clear_pending_commit(group_id).map_mdk_err()
    }

    /// Wipes all local MDK state for a group (tree, epoch secrets, keys,
    /// proposals, messages, processed messages, snapshots, relays, welcomes).
    ///
    /// Idempotent: deleting a nonexistent group is a no-op. Local-only — no
    /// MLS proposals or Nostr events are published. Used by the leave flow
    /// to purge forward-secrecy–sensitive material immediately after the
    /// `SelfRemove` proposal reaches relays, since the leaver's remaining
    /// secrets are only useful for decrypting past ciphertext.
    ///
    /// # Errors
    ///
    /// Returns an error if the underlying storage deletion fails.
    pub fn delete_group(&self, group_id: &GroupId) -> Result<()> {
        self.mdk.delete_group(group_id).map_mdk_err()
    }

    /// Default limit for message retrieval to prevent memory exhaustion.
    pub const DEFAULT_MESSAGE_LIMIT: usize = 500;

    /// Gets messages for a group with default pagination limits.
    ///
    /// This method retrieves up to [`DEFAULT_MESSAGE_LIMIT`] most recent messages
    /// to prevent memory exhaustion from groups with many messages.
    /// Use [`get_messages_paginated`] for custom pagination.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID
    ///
    /// # Returns
    ///
    /// Returns a list of decrypted messages for the group.
    ///
    /// # Errors
    ///
    /// Returns an error if messages cannot be retrieved.
    pub fn get_messages(&self, group_id: &GroupId) -> Result<Vec<MlsMessage>> {
        self.get_messages_paginated(group_id, Some(Self::DEFAULT_MESSAGE_LIMIT), None)
    }

    /// Gets messages for a group with custom pagination.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID
    /// * `limit` - Maximum number of messages to return (None for no limit)
    /// * `offset` - Number of messages to skip (None for no offset)
    ///
    /// # Returns
    ///
    /// Returns a list of decrypted messages for the group.
    ///
    /// # Errors
    ///
    /// Returns an error if messages cannot be retrieved.
    pub fn get_messages_paginated(
        &self,
        group_id: &GroupId,
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> Result<Vec<MlsMessage>> {
        use mdk_storage_traits::groups::Pagination;

        let pagination = if limit.is_some() || offset.is_some() {
            Some(Pagination::new(limit, offset))
        } else {
            None
        };

        self.mdk.get_messages(group_id, pagination).map_mdk_err()
    }

    /// Adds members to an existing group.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID
    /// * `key_packages` - Key package events (kind 30443 or 443) for the members to add
    ///
    /// # Returns
    ///
    /// Returns `UpdateGroupResult` containing evolution events and welcome messages.
    /// The evolution event should be published to group relays, and welcome messages
    /// should be gift-wrapped and sent to new members.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is not found or member addition fails.
    pub fn add_members(
        &self,
        group_id: &GroupId,
        key_packages: &[Event],
    ) -> Result<UpdateGroupResult> {
        self.mdk.add_members(group_id, key_packages).map_mdk_err()
    }

    /// Removes members from an existing group.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID
    /// * `member_pubkeys` - Public keys (hex) of members to remove
    ///
    /// # Returns
    ///
    /// Returns `UpdateGroupResult` containing the evolution event to publish.
    ///
    /// # Errors
    ///
    /// Returns an error if the group is not found, any member is not in the group,
    /// or removal fails.
    pub fn remove_members(
        &self,
        group_id: &GroupId,
        member_pubkeys: &[String],
    ) -> Result<UpdateGroupResult> {
        // Parse pubkeys
        let pubkeys: Vec<PublicKey> = member_pubkeys
            .iter()
            .filter_map(|pk| PublicKey::from_hex(pk).ok())
            .collect();

        if pubkeys.is_empty() && !member_pubkeys.is_empty() {
            return Err(NostrError::InvalidEvent(
                "No valid public keys provided".to_string(),
            ));
        }

        self.mdk.remove_members(group_id, &pubkeys).map_mdk_err()
    }

    /// Merges a pending MLS commit after publishing.
    ///
    /// Call this after successfully publishing an evolution event to finalize
    /// the group state change. This completes add/remove member operations.
    ///
    /// # Arguments
    ///
    /// * `group_id` - The MLS group ID with a pending commit
    ///
    /// # Errors
    ///
    /// Returns an error if there is no pending commit or merge fails.
    pub fn merge_pending_commit(&self, group_id: &GroupId) -> Result<()> {
        self.mdk.merge_pending_commit(group_id).map_mdk_err()
    }

    /// Replaces the group's admin list with `admins` via a
    /// `GroupContextExtensions` commit.
    ///
    /// Creates a pending commit — caller must publish the evolution event and
    /// then merge (on ACK) or clear (on failure).
    ///
    /// # Errors
    ///
    /// Returns an error if a pubkey is invalid, the caller is not authorized,
    /// or MDK rejects the update.
    pub fn update_admins(
        &self,
        group_id: &GroupId,
        admins: &[PublicKey],
    ) -> Result<UpdateGroupResult> {
        let update = mdk_core::prelude::NostrGroupDataUpdate::new().admins(admins.to_vec());
        self.mdk.update_group_data(group_id, update).map_mdk_err()
    }

    /// Replaces the group's relay list (MIP-01 group-data extension) with
    /// `relays` via a `GroupContextExtensions` commit.
    ///
    /// Exact mirror of [`update_admins`](Self::update_admins). Creates a
    /// pending commit — the caller publishes the returned evolution event and
    /// then merges (on ACK) or clears (on failure). MDK enforces admin
    /// authorization against the live MLS group context, so no Haven-side
    /// admin gate is added (one could drift from MLS truth).
    ///
    /// # Errors
    ///
    /// Returns an error if the caller is not an admin or MDK rejects the
    /// update.
    pub fn update_relays(
        &self,
        group_id: &GroupId,
        relays: &[RelayUrl],
    ) -> Result<UpdateGroupResult> {
        let update = mdk_core::prelude::NostrGroupDataUpdate::new().relays(relays.to_vec());
        self.mdk.update_group_data(group_id, update).map_mdk_err()
    }

    /// Returns the group's current relay set from MDK's authoritative store.
    ///
    /// MDK keeps its own `group_relays` store in sync with the MLS group-data
    /// extension on every processed/merged commit
    /// (`sync_group_metadata_from_mls` -> `replace_group_relays`), so this is
    /// the post-commit relay set on both the producer and consumer sides. The
    /// returned `Vec` is sorted (MDK stores a `BTreeSet`), giving callers a
    /// deterministic order for an order-insensitive comparison against the
    /// app-level circle relay list.
    ///
    /// # Errors
    ///
    /// Returns an error if MDK cannot read the group's relays.
    pub fn get_group_relays(&self, group_id: &GroupId) -> Result<Vec<RelayUrl>> {
        Ok(self
            .mdk
            .get_relays(group_id)
            .map_mdk_err()?
            .into_iter()
            .collect())
    }

    /// Finds a group by its Nostr group ID.
    ///
    /// This is useful for routing incoming messages that contain the Nostr group ID
    /// in their h-tag.
    ///
    /// # Arguments
    ///
    /// * `nostr_group_id` - The 32-byte Nostr group ID from an h-tag
    ///
    /// # Returns
    ///
    /// Returns `Some(Group)` if found, `None` otherwise.
    ///
    /// # Errors
    ///
    /// Returns an error if storage cannot be accessed.
    pub fn get_group_by_nostr_id(&self, nostr_group_id: &[u8; 32]) -> Result<Option<MlsGroup>> {
        // MDK doesn't have a direct lookup by nostr_group_id, so we iterate
        let groups = self.get_groups()?;
        Ok(groups
            .into_iter()
            .find(|g| &g.nostr_group_id == nostr_group_id))
    }

    /// Creates a key package for publishing to relays.
    ///
    /// This generates MLS key material and returns the data needed to build
    /// a Nostr key package event. Includes tags for both addressable kind 30443
    /// (preferred) and legacy kind 443. The caller must sign the event with
    /// their Nostr identity key and publish it to the specified relays.
    ///
    /// # Arguments
    ///
    /// * `identity_pubkey` - The user's Nostr public key (hex)
    /// * `relays` - Relay URLs where the key package will be published
    ///
    /// # Returns
    ///
    /// Returns a `KeyPackageBundle` containing the event content and tags
    /// for both kind 30443 and kind 443.
    ///
    /// # Errors
    ///
    /// Returns an error if key package generation fails.
    pub fn create_key_package(
        &self,
        identity_pubkey: &str,
        relays: &[String],
    ) -> Result<KeyPackageBundle> {
        self.create_key_package_with_d(identity_pubkey, relays, None)
    }

    /// Creates a key package, optionally reusing a stable NIP-33 `d` tag.
    ///
    /// When `existing_d_tag` is `Some(d)`, the returned kind 30443 bundle's
    /// NIP-33 addressable identifier (`d` tag) is **overridden** to `d` so a
    /// rotation REPLACES the same `(kind, pubkey, d)` coordinate on relays
    /// instead of minting a brand-new address. When `None`, MDK's fresh random
    /// `d` is used unchanged (the pre-M8 behavior).
    ///
    /// # Why override the tag instead of passing it to MDK
    ///
    /// The pinned MDK rev (`93ae324`) does **not** expose an
    /// `existing_d_tag`/`KeyPackageOptions` parameter (that arrived in a later
    /// rev White Noise uses). At this rev the `d` value is a random 32-byte hex
    /// identifier generated purely for the Nostr event's `d` tag — it is
    /// computed AFTER the MLS `hash_ref` and content and is **not** bound into
    /// the key package material, the `hash_ref`, or any signature. Overriding it
    /// on the returned tag list is therefore functionally identical to the
    /// later MDK's `existing_d_tag`, and MDK stays PRISTINE (no fork/patch).
    ///
    /// Only the canonical kind 30443 event carries a `d` tag; the legacy kind
    /// 443 twin has none, so `existing_d_tag` never affects `tags_443`.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid, no valid relay URLs are
    /// provided, or key package generation fails.
    pub fn create_key_package_with_d(
        &self,
        identity_pubkey: &str,
        relays: &[String],
        existing_d_tag: Option<&str>,
    ) -> Result<KeyPackageBundle> {
        // Parse pubkey
        let pubkey = PublicKey::from_hex(identity_pubkey)
            .map_err(|e| NostrError::InvalidEvent(format!("Invalid pubkey: {e}")))?;

        // Parse relay URLs
        let relay_urls: Vec<RelayUrl> = relays
            .iter()
            .filter_map(|r| RelayUrl::parse(r).ok())
            .collect();

        if relay_urls.is_empty() && !relays.is_empty() {
            return Err(NostrError::InvalidEvent(
                "No valid relay URLs provided".to_string(),
            ));
        }

        // Create key package via MDK (returns KeyPackageEventData)
        let kp_data = self
            .mdk
            .create_key_package_for_event(&pubkey, relay_urls)
            .map_mdk_err()?;

        // Convert nostr::Tag to Vec<Vec<String>>, stripping the NIP-70
        // protected tag (["-"]). MIP-00 specifies this tag as optional and
        // recommends omitting it unless publishing to relays that support
        // NIP-42 AUTH + NIP-70. Most popular relays reject protected events.
        let filter_tags = |tags: Vec<Tag>| -> Vec<Vec<String>> {
            tags.into_iter()
                .filter(|tag| tag.kind() != TagKind::Protected)
                .map(|tag| tag.to_vec().into_iter().collect())
                .collect()
        };

        let mut tags_30443 = filter_tags(kp_data.tags_30443);
        // The effective `d` value we surface: MDK's random one, or the stable
        // override applied to BOTH the tag list and the returned `d_tag`.
        let effective_d = match existing_d_tag {
            Some(stable) => {
                Self::override_d_tag(&mut tags_30443, stable);
                stable.to_string()
            }
            None => kp_data.d_tag,
        };

        Ok(KeyPackageBundle {
            content: kp_data.content,
            tags_30443,
            tags_443: filter_tags(kp_data.tags_443),
            hash_ref: kp_data.hash_ref,
            d_tag: effective_d,
            relays: relays.to_vec(),
        })
    }

    /// Rewrites the `["d", <value>]` identifier tag in a kind 30443 tag list.
    ///
    /// The MDK-built canonical tag list always contains exactly one `d` tag as
    /// its first element. This replaces its value with `stable`. If (defensively)
    /// no `d` tag is present, one is prepended so the event stays addressable.
    fn override_d_tag(tags: &mut Vec<Vec<String>>, stable: &str) {
        if let Some(tag) = tags
            .iter_mut()
            .find(|t| t.first().map(String::as_str) == Some("d"))
        {
            // ["d", "<value>"] — replace the value, keep the "d" key.
            if tag.len() >= 2 {
                tag[1] = stable.to_string();
            } else {
                tag.push(stable.to_string());
            }
        } else {
            tags.insert(0, vec!["d".to_string(), stable.to_string()]);
        }
    }

    /// Returns whether the private MLS init-key material for a published
    /// `KeyPackage` is still LIVE in local storage — the M8-2 live-material gate.
    ///
    /// `hash_ref_bytes` is the serialized `KeyPackageRef` MDK returned when the
    /// `KeyPackage` was created (as recorded in `published_key_packages`). This
    /// queries the `OpenMLS` `StorageProvider` (reachable through MDK's public
    /// `provider`) for that key package:
    ///
    /// * `Ok(true)`  — the private material is present ⇒ the published event is
    ///   LIVE and still usable to process an incoming Welcome.
    /// * `Ok(false)` — the material is absent (consumed by a Welcome and then
    ///   deleted, or never stored) ⇒ the published event is DEAD; republishing
    ///   over it is safe and required.
    ///
    /// # Consumed-but-present nuance (documented gap)
    ///
    /// MDK builds all key packages as `last_resort`, and `OpenMLS` only deletes a
    /// key package on Welcome-join when it is NOT `last_resort` — so at this
    /// rev a `KeyPackage`'s material is effectively never auto-deleted, and Haven
    /// never calls `delete_key_package_from_storage`. The gate is therefore
    /// correct and future-proof (it flips to DEAD the moment deletion lands in
    /// M10) but, at M8, a `KeyPackage` that has already been *consumed* by a
    /// Welcome without a subsequent delete still reads as LIVE. That is the
    /// documented consumed-but-present gap; it never causes an *unsafe*
    /// republish, only a slightly conservative "don't republish" decision.
    ///
    /// # Errors
    ///
    /// Returns an error if the stored `hash_ref` cannot be deserialized or the
    /// storage query fails. All error strings are hex-redacted.
    pub fn has_live_key_material(&self, hash_ref_bytes: &[u8]) -> Result<bool> {
        use mdk_storage_traits::mls_codec::MlsCodec;
        use openmls::ciphersuite::hash_ref::HashReference;
        use openmls::key_packages::KeyPackageBundle as OpenMlsKeyPackageBundle;
        use openmls_traits::storage::StorageProvider;
        use openmls_traits::OpenMlsProvider;

        let hash_ref: HashReference = MlsCodec::deserialize(hash_ref_bytes)
            .map_err(|e| NostrError::MdkError(redact_hex_sequences(&e.to_string())))?;

        let live: Option<OpenMlsKeyPackageBundle> = self
            .mdk
            .provider
            .storage()
            .key_package(&hash_ref)
            .map_err(|e| NostrError::MdkError(redact_hex_sequences(&e.to_string())))?;

        Ok(live.is_some())
    }

    /// Converts a `MessageProcessingResult` to a simpler `LocationMessageResult`.
    ///
    /// This is a helper for processing location-specific messages.
    ///
    /// # Auto-committed proposal handling
    ///
    /// MDK's `auto_commit_proposal` path (see
    /// `mdk_core/src/messages/proposal.rs`) stages a pending commit and
    /// returns `MessageProcessingResult::Proposal(UpdateGroupResult)` when
    /// a peer's `SelfRemove` proposal is auto-committed. The caller owes
    /// a publish-then-merge cycle on the `evolution_event`; without it
    /// the local MLS epoch never advances and the departed member keeps
    /// appearing in `get_members`. We surface the event on
    /// [`LocationMessageResult::GroupUpdate::evolution_event`] so the
    /// FFI/Flutter layer can carry it out.
    ///
    /// The `PendingProposal` variant deliberately maps with
    /// `evolution_event = None`: MDK stores the proposal locally but
    /// does **not** create a commit, so there is nothing for the
    /// receiver to publish. Pending proposals are committed later by an
    /// admin via a normal add/remove flow.
    ///
    /// # Ignored proposals (admin-gate / validation drops)
    ///
    /// `MessageProcessingResult::IgnoredProposal` is folded into the
    /// same `GroupUpdate { evolution_event: None }` shape as plain
    /// commits and pending proposals: from the caller's point of view
    /// nothing actionable happened. The historical "ghost admin"
    /// failure (MDK silently dropping an admin's `SelfRemove`) is no
    /// longer reachable from production code paths — Haven's
    /// `LeavePlan` (`haven-core/src/circle/leave.rs`) drives
    /// `propose_self_demote` before `propose_leave`, so admins never
    /// emit a raw `SelfRemove`, and MDK's own sender-side admin-gate
    /// (`mdk-core/src/groups.rs::leave_group`) would refuse it even if
    /// they tried. The reason string is redacted and emitted at
    /// `debug!` level for diagnostics (mirrors White Noise's handler in
    /// `whitenoise-rs/src/whitenoise/event_processor/event_handlers/handle_mls_message.rs`);
    /// the residual cases (epoch races, validator drops) self-heal on
    /// the next poll.
    #[must_use]
    pub fn to_location_result(result: MessageProcessingResult) -> LocationMessageResult {
        match result {
            MessageProcessingResult::ApplicationMessage(msg) => LocationMessageResult::Location {
                sender_pubkey: msg.pubkey.to_hex(),
                content: msg.content,
                group_id: msg.mls_group_id,
            },
            MessageProcessingResult::Proposal(r) => LocationMessageResult::GroupUpdate {
                group_id: r.mls_group_id,
                evolution_event: Some(r.evolution_event),
            },
            MessageProcessingResult::Commit { mls_group_id }
            | MessageProcessingResult::ExternalJoinProposal { mls_group_id }
            | MessageProcessingResult::PendingProposal { mls_group_id, .. } => {
                LocationMessageResult::GroupUpdate {
                    group_id: mls_group_id,
                    evolution_event: None,
                }
            }
            MessageProcessingResult::IgnoredProposal {
                mls_group_id,
                reason,
            } => {
                log::debug!(
                    "[MdkManager] IgnoredProposal: {}",
                    redact_hex_sequences(&reason)
                );
                LocationMessageResult::GroupUpdate {
                    group_id: mls_group_id,
                    evolution_event: None,
                }
            }
            MessageProcessingResult::Unprocessable { mls_group_id } => {
                LocationMessageResult::Unprocessable {
                    group_id: mls_group_id,
                    reason: "Message could not be processed".to_string(),
                }
            }
            MessageProcessingResult::PreviouslyFailed => LocationMessageResult::PreviouslyFailed,
        }
    }
}

impl std::fmt::Debug for MdkManager {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MdkManager")
            .field("mdk", &"<MDK instance>")
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::sync::atomic::{AtomicU64, Ordering};

    // Atomic counter for unique test directories
    static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn temp_dir() -> std::path::PathBuf {
        let id = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
        env::temp_dir().join(format!("haven_mdk_test_{}_{}", std::process::id(), id))
    }

    #[test]
    fn manager_new_unencrypted_creates_instance() {
        let dir = temp_dir();
        let result = MdkManager::new_unencrypted(&dir);
        assert!(result.is_ok());

        // Cleanup
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn manager_debug_does_not_leak() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();
        let debug_output = format!("{:?}", manager);

        assert!(debug_output.contains("MdkManager"));
        assert!(!debug_output.contains("secret"));

        // Cleanup
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_groups_returns_empty_initially() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let groups = manager.get_groups().unwrap();
        assert!(groups.is_empty());

        // Cleanup
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_pending_welcomes_returns_empty_initially() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let welcomes = manager.get_pending_welcomes().unwrap();
        assert!(welcomes.is_empty());

        // Cleanup
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_group_nonexistent_returns_none() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[1, 2, 3]);
        let result = manager.get_group(&fake_id);

        assert!(result.is_ok());
        assert!(result.unwrap().is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_members_nonexistent_group_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[4, 5, 6]);
        let result = manager.get_members(&fake_id);

        assert!(result.is_err());
        if let Err(NostrError::MdkError(msg)) = result {
            assert!(!msg.is_empty());
        } else {
            panic!("Expected MdkError");
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_messages_nonexistent_group_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[7, 8, 9]);
        let result = manager.get_messages(&fake_id);

        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn leave_group_nonexistent_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[10, 11, 12]);
        let result = manager.leave_group(&fake_id);

        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_group_invalid_pubkey_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let config = LocationGroupConfig::new("Test");
        let result = manager.create_group("invalid-hex!!", vec![], config);

        assert!(result.is_err());
        if let Err(NostrError::InvalidEvent(msg)) = result {
            assert!(msg.contains("Invalid creator pubkey"));
        } else {
            panic!("Expected InvalidEvent error");
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_group_short_pubkey_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let config = LocationGroupConfig::new("Test");
        // Valid hex but too short
        let result = manager.create_group("abcd1234", vec![], config);

        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_group_filters_invalid_relay_urls() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        // Mix of valid and invalid relay URLs
        let config = LocationGroupConfig::new("Test")
            .with_relay("wss://valid.relay.com")
            .with_relay("not-a-valid-url")
            .with_relay("wss://another-valid.relay.com")
            .with_relay(""); // Empty URL

        // Need a valid 32-byte pubkey (64 hex chars)
        let valid_pubkey = "a".repeat(64);

        // This will fail because we don't have a valid key package
        // but we're testing that relay parsing doesn't cause additional errors
        let result = manager.create_group(&valid_pubkey, vec![], config);

        // It will fail due to invalid pubkey (all 'a's is not a valid curve point)
        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_group_filters_invalid_admin_pubkeys() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        // Mix of valid and invalid admin pubkeys
        let valid_admin = "b".repeat(64);
        let config = LocationGroupConfig::new("Test")
            .with_admin(&valid_admin)
            .with_admin("invalid-admin")
            .with_admin(""); // Empty admin

        let valid_pubkey = "c".repeat(64);

        let result = manager.create_group(&valid_pubkey, vec![], config);

        // Will fail, but for cryptographic reasons, not parsing
        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    // Note: ApplicationMessage and ProposalResult tests are covered in integration tests
    // because we can't easily construct those types in unit tests without MDK internals.
    // The Commit, ExternalJoinProposal, and Unprocessable variants are tested below.

    #[test]
    fn to_location_result_commit() {
        let group_id = super::super::types::GroupId::from_slice(&[7, 8, 9]);

        let processing_result = MessageProcessingResult::Commit {
            mls_group_id: group_id.clone(),
        };
        let location_result = MdkManager::to_location_result(processing_result);

        if let LocationMessageResult::GroupUpdate {
            group_id: gid,
            evolution_event,
        } = location_result
        {
            assert_eq!(gid.as_slice(), &[7, 8, 9]);
            assert!(
                evolution_event.is_none(),
                "Commit variant should not carry an evolution event"
            );
        } else {
            panic!("Expected GroupUpdate variant from Commit");
        }
    }

    #[test]
    fn to_location_result_external_join() {
        let group_id = super::super::types::GroupId::from_slice(&[10, 11, 12]);

        let processing_result = MessageProcessingResult::ExternalJoinProposal {
            mls_group_id: group_id.clone(),
        };
        let location_result = MdkManager::to_location_result(processing_result);

        if let LocationMessageResult::GroupUpdate {
            group_id: gid,
            evolution_event,
        } = location_result
        {
            assert_eq!(gid.as_slice(), &[10, 11, 12]);
            assert!(
                evolution_event.is_none(),
                "ExternalJoinProposal should not carry an evolution event"
            );
        } else {
            panic!("Expected GroupUpdate variant from ExternalJoinProposal");
        }
    }

    #[test]
    fn to_location_result_pending_proposal_has_no_evolution_event() {
        // PendingProposal is stored by MDK without creating a commit.
        // `to_location_result` must map it to GroupUpdate with no
        // evolution_event — there is nothing for the receiver to publish.
        // This is the contract the Flutter layer depends on to avoid
        // publishing a phantom event for Add/Remove proposals pending
        // admin approval.
        let group_id = super::super::types::GroupId::from_slice(&[33, 34, 35]);

        let processing_result = MessageProcessingResult::PendingProposal {
            mls_group_id: group_id.clone(),
        };
        let location_result = MdkManager::to_location_result(processing_result);

        if let LocationMessageResult::GroupUpdate {
            group_id: gid,
            evolution_event,
        } = location_result
        {
            assert_eq!(gid.as_slice(), &[33, 34, 35]);
            assert!(
                evolution_event.is_none(),
                "PendingProposal must not carry an evolution event — MDK has \
                 not created a commit, so there is nothing to publish"
            );
        } else {
            panic!("Expected GroupUpdate variant from PendingProposal");
        }
    }

    #[test]
    fn to_location_result_unprocessable() {
        let group_id = super::super::types::GroupId::from_slice(&[13, 14, 15]);

        let processing_result = MessageProcessingResult::Unprocessable {
            mls_group_id: group_id.clone(),
        };
        let location_result = MdkManager::to_location_result(processing_result);

        if let LocationMessageResult::Unprocessable {
            group_id: gid,
            reason,
        } = location_result
        {
            assert_eq!(gid.as_slice(), &[13, 14, 15]);
            assert!(reason.contains("could not be processed"));
        } else {
            panic!("Expected Unprocessable variant");
        }
    }

    #[test]
    fn classify_mdk_error_flags_racing_sibling_as_competing_commit() {
        // The exact error a same-epoch sibling commit produces while we hold our
        // own pending commit (MDK process.rs returns this).
        assert_eq!(
            classify_mdk_error(&mdk_core::Error::OwnCommitPending),
            CommitClassification::CompetingCommit
        );
        // A stale commit re-applied after a rollback.
        assert_eq!(
            classify_mdk_error(&mdk_core::Error::CannotDecryptOwnMessage),
            CommitClassification::CompetingCommit
        );
        // A commit one epoch behind: is_commit = true → competing.
        assert_eq!(
            classify_mdk_error(&mdk_core::Error::ProcessMessageWrongEpoch(7, true)),
            CommitClassification::CompetingCommit
        );
    }

    #[test]
    fn classify_mdk_error_treats_non_commit_and_other_failures_as_plain_drops() {
        // A stale *non-commit* (e.g. an application message a past epoch) must
        // NOT be buffered as a competitor — is_commit = false.
        assert_eq!(
            classify_mdk_error(&mdk_core::Error::ProcessMessageWrongEpoch(7, false)),
            CommitClassification::Other
        );
        // Unrelated failures are plain drops.
        assert_eq!(
            classify_mdk_error(&mdk_core::Error::ProcessMessageWrongGroupId),
            CommitClassification::Other
        );
        assert_eq!(
            classify_mdk_error(&mdk_core::Error::MessageFromNonMember),
            CommitClassification::Other
        );
        assert_eq!(
            classify_mdk_error(&mdk_core::Error::ProcessMessageOther("boom".to_string())),
            CommitClassification::Other
        );
        // An after-eviction message and a non-admin commit must NOT be buffered
        // as fork competitors — they fall through the wildcard to `Other`. Pin
        // them so a future refactor cannot silently route them to CompetingCommit.
        assert_eq!(
            classify_mdk_error(&mdk_core::Error::ProcessMessageUseAfterEviction),
            CommitClassification::Other
        );
        assert_eq!(
            classify_mdk_error(&mdk_core::Error::CommitFromNonAdmin),
            CommitClassification::Other
        );
    }

    /// IgnoredProposal events fold into the same benign `GroupUpdate`
    /// shape as plain commits — the historical ghost-admin failure path
    /// is unreachable (the production `LeavePlan` issues `self_demote`
    /// before `propose_leave`, and MDK's sender-side gate would refuse
    /// a raw admin SelfRemove anyway). The reason string is logged at
    /// `debug!` level after `redact_hex_sequences`, never surfaced.
    #[test]
    fn to_location_result_ignored_proposal_maps_to_group_update() {
        let group_id = super::super::types::GroupId::from_slice(&[16, 17, 18]);
        let processing_result = MessageProcessingResult::IgnoredProposal {
            mls_group_id: group_id.clone(),
            reason: "SelfRemove rejected: sender is an admin".to_string(),
        };

        let location_result = MdkManager::to_location_result(processing_result);

        match location_result {
            LocationMessageResult::GroupUpdate {
                group_id: gid,
                evolution_event,
            } => {
                assert_eq!(gid.as_slice(), &[16, 17, 18]);
                assert!(
                    evolution_event.is_none(),
                    "IgnoredProposal must not carry an outbound evolution event — \
                     there is nothing for the caller to publish"
                );
            }
            other => panic!(
                "IgnoredProposal must map to GroupUpdate{{ evolution_event: None }}, \
                 got {:?}",
                other
            ),
        }
    }

    #[test]
    fn add_members_nonexistent_group_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[20, 21, 22]);
        let result = manager.add_members(&fake_id, &[]);

        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn remove_members_empty_pubkeys_with_invalid_input_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[23, 24, 25]);
        // Provide invalid pubkeys that will all fail parsing
        let invalid_pubkeys = ["not-valid".to_string(), "also-invalid".to_string()];
        let result = manager.remove_members(&fake_id, &invalid_pubkeys);

        assert!(result.is_err());
        if let Err(NostrError::InvalidEvent(msg)) = result {
            assert!(msg.contains("No valid public keys"));
        } else {
            panic!("Expected InvalidEvent error");
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn remove_members_nonexistent_group_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[26, 27, 28]);
        // Use a valid pubkey format but group doesn't exist
        let valid_pubkey =
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".to_string();
        let result = manager.remove_members(&fake_id, &[valid_pubkey]);

        // Should fail because group doesn't exist (not because of invalid pubkey)
        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn merge_pending_commit_nonexistent_group_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_id = super::super::types::GroupId::from_slice(&[29, 30, 31]);
        let result = manager.merge_pending_commit(&fake_id);

        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_group_by_nostr_id_nonexistent_returns_none() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let fake_nostr_id = [0u8; 32];
        let result = manager.get_group_by_nostr_id(&fake_nostr_id);

        assert!(result.is_ok());
        assert!(result.unwrap().is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_key_package_invalid_pubkey_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let result =
            manager.create_key_package("invalid-hex!!", &["wss://relay.example.com".to_string()]);

        assert!(result.is_err());
        if let Err(NostrError::InvalidEvent(msg)) = result {
            assert!(msg.contains("Invalid pubkey"));
        } else {
            panic!("Expected InvalidEvent error");
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_key_package_invalid_relay_urls_fails() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        // Valid pubkey format
        let valid_pubkey = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

        // All invalid relay URLs
        let result = manager.create_key_package(
            valid_pubkey,
            &["not-a-url".to_string(), "also-not-valid".to_string()],
        );

        assert!(result.is_err());
        if let Err(NostrError::InvalidEvent(msg)) = result {
            assert!(msg.contains("No valid relay URLs"));
        } else {
            panic!("Expected InvalidEvent error");
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_key_package_with_valid_inputs_succeeds() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        // Use a real valid pubkey (generated from secp256k1)
        // This is just a test pubkey, not a real identity
        let valid_pubkey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

        let result =
            manager.create_key_package(valid_pubkey, &["wss://relay.example.com".to_string()]);

        assert!(result.is_ok());
        let bundle = result.unwrap();

        // Verify the bundle has content
        assert!(!bundle.content.is_empty());

        // Verify tags were generated for both event kinds
        assert!(!bundle.tags_30443.is_empty());
        assert!(!bundle.tags_443.is_empty());
        // Verify hash_ref and d_tag are present
        assert!(!bundle.hash_ref.is_empty());
        assert!(!bundle.d_tag.is_empty());

        // Verify relays are preserved
        assert_eq!(bundle.relays.len(), 1);
        assert_eq!(bundle.relays[0], "wss://relay.example.com");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Reads the `d` value out of a kind 30443 tag list.
    fn d_of(tags: &[Vec<String>]) -> Option<String> {
        tags.iter()
            .find(|t| t.first().map(String::as_str) == Some("d"))
            .and_then(|t| t.get(1).cloned())
    }

    #[test]
    fn create_key_package_with_d_overrides_canonical_d_tag() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();
        let valid_pubkey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
        let stable = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899";

        let bundle = manager
            .create_key_package_with_d(
                valid_pubkey,
                &["wss://relay.example.com".to_string()],
                Some(stable),
            )
            .expect("create with stable d");

        // Both the returned d_tag and the canonical tag list carry the override.
        assert_eq!(bundle.d_tag, stable);
        assert_eq!(d_of(&bundle.tags_30443).as_deref(), Some(stable));
        // Exactly one `d` tag; legacy twin still has none.
        let d_count = bundle
            .tags_30443
            .iter()
            .filter(|t| t.first().map(String::as_str) == Some("d"))
            .count();
        assert_eq!(d_count, 1, "must not duplicate the d tag");
        assert!(d_of(&bundle.tags_443).is_none(), "443 twin has no d tag");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_key_package_relays_tag_enumerates_all_passed_relays() {
        // M8-6 PC-1 pin: the `relays` argument becomes the MIP-00 `relays` tag
        // of the 30443, which tells an inviter which relays to deliver the
        // Welcome to. The per-relay maintenance heal MUST build the KeyPackage
        // CONTENT from the FULL own relay set (never the narrowed publish
        // target), so a healed KeyPackage advertises the same relay set as a
        // normal publish — preserving Welcome-delivery redundancy.
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();
        let pk = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
        let full = [
            "wss://a.example.com".to_string(),
            "wss://b.example.com".to_string(),
            "wss://c.example.com".to_string(),
        ];
        let bundle = manager
            .create_key_package_with_d(pk, &full, None)
            .expect("create");
        let relays_tag = bundle
            .tags_30443
            .iter()
            .find(|t| t.first().map(String::as_str) == Some("relays"))
            .expect("a relays tag");
        for r in &full {
            assert!(
                relays_tag.iter().any(|v| v == r),
                "the relays tag must enumerate every passed relay (missing {r})"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn create_key_package_with_none_uses_fresh_random_d() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();
        let valid_pubkey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

        let a = manager
            .create_key_package_with_d(valid_pubkey, &["wss://relay.example.com".to_string()], None)
            .expect("a");
        let b = manager
            .create_key_package_with_d(valid_pubkey, &["wss://relay.example.com".to_string()], None)
            .expect("b");

        // Without an override MDK mints a fresh random d each time.
        assert_ne!(a.d_tag, b.d_tag);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn has_live_key_material_true_for_freshly_created_package() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();
        let valid_pubkey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

        let bundle = manager
            .create_key_package(valid_pubkey, &["wss://relay.example.com".to_string()])
            .expect("create");

        // Freshly created ⇒ private material is stored ⇒ LIVE.
        assert!(manager
            .has_live_key_material(&bundle.hash_ref)
            .expect("query"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn has_live_key_material_false_for_unknown_hash_ref() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();
        let valid_pubkey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

        // Create one package to obtain a well-formed hash_ref, then flip a byte
        // so it deserializes to a HashReference that was never stored ⇒ DEAD.
        let bundle = manager
            .create_key_package(valid_pubkey, &["wss://relay.example.com".to_string()])
            .expect("create");
        let mut unknown = bundle.hash_ref.clone();
        let last = unknown.len() - 1;
        unknown[last] ^= 0xff;

        assert!(!manager
            .has_live_key_material(&unknown)
            .expect("query unknown"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Verify that the NIP-70 protected tag (`["-"]`) is stripped from the
    /// `KeyPackageBundle` returned by `create_key_package`.
    ///
    /// MDK's `create_key_package_for_event` adds `Tag::protected()` (NIP-70)
    /// to its output. Most production relays reject protected events, so
    /// `create_key_package` must filter that tag out before returning the
    /// bundle. This test confirms the filter is applied at the bundle level,
    /// before the caller ever touches the tags.
    #[test]
    fn create_key_package_strips_nip70_protected_tag_from_bundle() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let valid_pubkey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
        let relays = vec!["wss://relay.example.com".to_string()];

        let bundle = manager
            .create_key_package(valid_pubkey, &relays)
            .expect("create_key_package should succeed with valid inputs");

        // The NIP-70 protected tag serialises as ["-"]. Assert that no tag
        // in either tag set has "-" as its first (and only) element.
        let has_protected = |tags: &[Vec<String>]| {
            tags.iter()
                .any(|tag_vec| tag_vec.first().is_some_and(|k| k == "-"))
        };
        let has_protected_tag =
            has_protected(&bundle.tags_30443) || has_protected(&bundle.tags_443);

        assert!(
            !has_protected_tag,
            "KeyPackageBundle must not contain the NIP-70 protected tag [\"-\"]; \
             most production relays reject protected events"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Verifies the tags_30443 / tags_443 invariant the FFI layer relies on
    /// when signing the kind 443 twin: the legacy tag list must equal the
    /// addressable tag list with the NIP-33 `d` tag removed (and only the
    /// `d` tag — every other tag must be preserved verbatim).
    ///
    /// If MDK ever changes how it derives `tags_443` (e.g. drops additional
    /// tags), the FFI's twin signing would silently produce events whose
    /// metadata diverges from the canonical kind 30443. This test guards
    /// against that drift.
    #[test]
    fn key_package_bundle_legacy_tags_equal_canonical_minus_d() {
        let dir = temp_dir();
        let manager = MdkManager::new_unencrypted(&dir).unwrap();

        let valid_pubkey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
        let relays = vec!["wss://relay.example.com".to_string()];

        let bundle = manager
            .create_key_package(valid_pubkey, &relays)
            .expect("create_key_package should succeed with valid inputs");

        // tags_30443 must include exactly one `d` tag (NIP-33 addressable).
        let d_tag_count_30443 = bundle
            .tags_30443
            .iter()
            .filter(|tag_vec| tag_vec.first().is_some_and(|k| k == "d"))
            .count();
        assert_eq!(
            d_tag_count_30443, 1,
            "kind 30443 tags must contain exactly one `d` tag for NIP-33"
        );

        // tags_443 must contain no `d` tag (legacy non-replaceable).
        let d_tag_count_443 = bundle
            .tags_443
            .iter()
            .filter(|tag_vec| tag_vec.first().is_some_and(|k| k == "d"))
            .count();
        assert_eq!(
            d_tag_count_443, 0,
            "legacy kind 443 tags must not include the `d` tag"
        );

        // tags_443 must equal tags_30443 with the `d` tag stripped.
        let canonical_minus_d: Vec<Vec<String>> = bundle
            .tags_30443
            .iter()
            .filter(|tag_vec| tag_vec.first().is_none_or(|k| k != "d"))
            .cloned()
            .collect();
        assert_eq!(
            canonical_minus_d, bundle.tags_443,
            "tags_443 must equal tags_30443 with `d` removed; FFI signs the \
             twin assuming this exact invariant"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn redact_hex_sequences_preserves_short_hex() {
        assert_eq!(
            redact_hex_sequences("error code abcd1234"),
            "error code abcd1234"
        );
    }

    #[test]
    fn redact_hex_sequences_redacts_long_hex() {
        let msg = "group 0123456789abcdef0123456789abcdef not found";
        let redacted = redact_hex_sequences(msg);
        assert_eq!(redacted, "group [REDACTED] not found");
        assert!(!redacted.contains("0123456789"));
    }

    #[test]
    fn redact_hex_sequences_handles_no_hex() {
        assert_eq!(
            redact_hex_sequences("plain error message"),
            "plain error message"
        );
    }

    #[test]
    fn redact_hex_sequences_redacts_trailing_hex() {
        let msg = "error: 0123456789abcdef0123456789abcdef";
        assert_eq!(redact_hex_sequences(msg), "error: [REDACTED]");
    }

    #[test]
    fn redact_hex_sequences_preserves_15_char_hex() {
        // 15 hex chars should NOT be redacted (threshold is 16)
        assert_eq!(
            redact_hex_sequences("id=0123456789abcde end"),
            "id=0123456789abcde end"
        );
    }

    #[test]
    fn redact_hex_sequences_redacts_16_char_hex() {
        // Exactly 16 hex chars SHOULD be redacted
        assert_eq!(
            redact_hex_sequences("id=0123456789abcdef end"),
            "id=[REDACTED] end"
        );
    }
}
