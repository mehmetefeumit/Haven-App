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

pub mod discovery;
mod error;
mod manager;
pub mod publishers;
mod types;

pub use discovery::{discovery_relays, set_discovery_relays_for_test, PRODUCTION_DISCOVERY_RELAYS};
pub use error::{RelayError, RelayResult};
pub use manager::{allow_ws_loopback_for_test, ws_loopback_allowed_for_test, RelayManager};
pub use publishers::{
    build_nip09_deletion, build_relay_list_event, build_unpublish_event, dedup_relay_targets,
    PublisherError, PublisherResult,
};
pub use types::{PublishResult, RelayConnectionStatus, RelayEventCheck, RelayStatus};
