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

pub mod catchup;
pub mod cursor;
pub mod discovery;
mod error;
pub mod live_sync;
mod manager;
pub mod publishers;
mod types;

pub use catchup::{CatchupOutcome, ReceiveOnlyOutcome};
pub use cursor::{
    cap_timestamp_to_now, since_for_stream, SubscribePhase, GROUP_INITIAL_BUFFER_SECS,
    GROUP_RESUBSCRIBE_BUFFER_SECS, INBOX_GIFTWRAP_LOOKBACK_SECS, STREAM_GROUP_445,
    STREAM_INBOX_1059,
};
pub use discovery::{discovery_relays, set_discovery_relays_for_test, PRODUCTION_DISCOVERY_RELAYS};
pub use error::{RelayError, RelayResult};
pub use manager::{allow_ws_loopback_for_test, ws_loopback_allowed_for_test, RelayManager};
pub use publishers::{
    build_nip09_deletion, build_relay_list_event, build_unpublish_event, dedup_relay_targets,
    PublisherError, PublisherResult,
};
pub use types::{
    PublishResult, RelayConnectionStatus, RelayEventCheck, RelayFetchOutcome, RelayStatus,
};
