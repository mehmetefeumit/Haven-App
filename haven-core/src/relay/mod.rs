//! Relay management for Nostr event publishing and fetching.
//!
//! This module provides relay connectivity for Haven, handling all
//! communication with Nostr relays via direct WSS connections.
//!
//! # Security Model
//!
//! - **WSS only**: Plaintext ws:// connections are rejected
//! - **Direct connections**: Uses nostr-sdk Client for relay communication
//!
//! # Architecture
//!
//! ```text
//! Haven App
//!     |
//!     v
//! RelayManager
//!     |
//!     v
//! nostr-sdk Client
//!     |
//!     v
//! Nostr Relays (WSS)
//! ```

mod error;
mod manager;
mod types;

pub use error::{RelayError, RelayResult};
pub use manager::RelayManager;
pub use types::{PublishResult, RelayConnectionStatus, RelayStatus};
