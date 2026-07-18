//! MLS integration for Nostr event encryption using the Marmot "Dark Matter"
//! MLS stack (`cgka-engine` / `cgka-session` / `cgka-traits` / `storage-sqlite`
//! / `transport-nostr-peeler`).
//!
//! This module provides Haven's interface to the Dark Matter MLS engine for
//! secure group messaging with forward secrecy:
//!
//! - [`SessionManager`]: the main interface for group and message operations,
//!   wrapping one `AccountDeviceSession` behind a `tokio` mutex.
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

mod context;
mod manager;
mod signer;
pub mod storage;
pub mod types;
mod welcome;

pub use context::MlsGroupContext;
pub use manager::redact_hex_sequences;
pub use manager::{SessionManager, DEFAULT_EXPORTER_LABEL};
pub use signer::HavenIdentityProofSigner;
pub use storage::StorageConfig;
pub use types::{GroupIdExt, LocationGroupConfig, LocationGroupInfo, LocationMessageResult};
pub use welcome::{PendingWelcome, PendingWelcomeStore, WelcomePreview};
