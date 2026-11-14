//! MLS integration for Nostr event encryption using the Marmot "Dark Matter"
//! MLS stack (`cgka-engine` / `cgka-session` / `cgka-traits` / `storage-sqlite`
//! / `transport-nostr-peeler`).
//!
//! This module provides Haven's interface to the Dark Matter MLS engine for
//! secure group messaging with forward secrecy:
//!
//! - [`SessionManager`]: the main interface for group and message operations,
//!   wrapping one `AccountDeviceSession` behind a `tokio` mutex.
//! - [`RetentionBoundPeeler`]: the installed transport peeler, which bounds the
//!   NIP-40 expiration of every outbound kind-445 application message so a
//!   circle created without the retention component cannot publish an unstamped
//!   one.
//! - [`HavenIdentityProofSigner`]: the hardened account-identity-proof signer
//!   binding the MLS leaf to the Nostr identity (security F1).
//! - [`PendingWelcomeStore`]: the hold-before-ingest pending-welcome store
//!   (security F3).
//! - [`MlsGroupContext`]: a group-scoped encrypt/decrypt context.
//! - Storage configuration for the encrypted `session.sqlite`.
//!
//! # Architecture
//!
//! ```text
//! Flutter App
//!     ↓
//! SessionManager (group lifecycle, message handling — async, &mut serialized)
//!     ↓
//! AccountDeviceSession → CgkaEngine (MLS protocol) + TransportPeeler (445/1059)
//!     ↓
//! SqliteAccountStorage (encrypted session.sqlite)
//! ```

mod commit_notes;
mod context;
mod engine_gate;
pub(crate) mod epoch_stall;
mod kept_input;
#[cfg(test)]
pub(crate) mod ledger_test_support;
mod manager;
mod retention;
mod signer;
pub mod storage;
pub mod types;
mod welcome;

#[cfg(test)]
pub(crate) use commit_notes::a_notice_drops_only_what_it_read;
pub use commit_notes::{
    ChangeNote, ChangeNotice, CommitNotes, KeptTarget, KeptWelcomeRoute, RestageWait, RouteUnread,
};
pub use context::MlsGroupContext;
pub(crate) use epoch_stall::{EpochStallEvidence, StallEvidence};
pub use kept_input::{KeptEvent, KeptInput, KEPT_BYTES_PER_CIRCLE, KEPT_EVENTS_PER_CIRCLE};
pub use manager::redact_hex_sequences;
pub use manager::{
    app_message_past_epoch_limit, chain_effects, max_rewind_commits, refetch_spacing_secs,
    OwedRange, RangePass, RefusedRedeliveryLedger, SessionManager, TrackedKeyPackage,
    DEFAULT_EXPORTER_LABEL, DEFAULT_MAX_PAST_EPOCHS, HAND_BACK_SLICE, HAND_BACK_WHOLE,
    MAX_REFUSED_IDS_PER_GROUP, MAX_REQUEUE_ATTEMPTS, REFETCH_SPACING_BASE_SECS,
    REFETCH_SPACING_CAP_SECS, REQUEUE_SET_ASIDE_REMOVALS,
};
pub(crate) use manager::{
    AwayHold, IngestClass, PlaneStanding, RemovalRequeue, SEND_PEEL_DRAIN_ADVANCES,
};
#[cfg(any(test, feature = "test-utils"))]
pub use manager::{HandBackStop, StoreFault, ORDER_PANIC_FOR_TEST};
pub use manager::{MeshDrive, MeshKeyStore, MeshPacket, StoredMeshKey, MESH_ON_MAX_MS};
pub use retention::{bounded_retention_secs, RetentionBoundPeeler};
pub use signer::HavenIdentityProofSigner;
pub use storage::StorageConfig;
pub use types::{
    GroupIdExt, LocationGroupConfig, LocationGroupInfo, LocationMessageResult, PreAuthRejection,
    ScreenedIngest,
};
pub use welcome::{PendingWelcome, PendingWelcomeStore, WelcomePreview};
