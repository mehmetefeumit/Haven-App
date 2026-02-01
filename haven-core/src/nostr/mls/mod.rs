//! MLS integration for Nostr event encryption using MDK.
//!
//! This module provides the MDK (Marmot Development Kit) integration for
//! secure group messaging with forward secrecy. It includes:
//!
//! - `MdkManager`: Main interface for group and message operations
//! - `MlsGroupContext`: Context for encryption/decryption operations
//! - Storage configuration for SQLite-backed persistence
//!
//! # Architecture
//!
//! ```text
//! Flutter App
//!     ↓
//! MdkManager (group lifecycle, message handling)
//!     ↓
//! MDK (MLS protocol implementation)
//!     ↓
//! SQLite Storage (persistent group/key state)
//! ```

mod context;
mod manager;
pub mod storage;
pub mod types;

pub use context::MlsGroupContext;
pub use manager::MdkManager;
pub use storage::StorageConfig;
pub use types::{LocationGroupConfig, LocationGroupInfo, LocationMessageResult};
