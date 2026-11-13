//! Relay management for Nostr event publishing and fetching.
//!
//! This module provides relay connectivity for Haven, handling all
//! communication with Nostr relays via direct WSS connections.
//!
//! # Security Model
//!
//! - **WSS only**: Plaintext ws:// connections are rejected
//! - **Direct connections**: Uses nostr-sdk Client for relay communication
//! - **Verified events**: every relay event's id and signature are checked
//!   before anything acts on it (`verified`), on the one client constructor
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
pub mod clock_skew;
pub mod cursor;
#[cfg(any(test, feature = "test-utils"))]
pub mod dial_witness;
pub mod discovery;
mod error;
pub mod fanout;
pub mod live_sync;
pub mod maintenance;
mod manager;
pub mod negentropy;
pub mod publishers;
#[cfg(any(test, feature = "test-utils"))]
pub mod recording_front;
pub mod retick;
#[cfg(any(test, feature = "test-utils"))]
pub mod scripted_relay;
mod types;
pub mod url_norm;
mod verified;

pub use catchup::{CatchupOutcome, ReceiveOnlyOutcome};
pub use clock_skew::{
    classify_publish_outcome, classify_relay_rejection, publish_retry_is_hopeless,
    DeviceClockComplaint, CLOCK_SKEW_ALERT_THRESHOLD_SECS, DEVICE_CLOCK_REJECTED_TOKEN,
    TOTAL_LOSS_SKEW_SECS,
};
pub use cursor::{
    cap_timestamp_to_now, cursor_ms_for_event, since_for_stream, SubscribePhase,
    GROUP_INITIAL_BUFFER_SECS, GROUP_RESUBSCRIBE_BUFFER_SECS, INBOX_GIFTWRAP_LOOKBACK_SECS,
    INBOX_RESUBSCRIBE_LOOKBACK_SECS, STREAM_GROUP_445, STREAM_INBOX_1059,
};
pub use discovery::{discovery_relays, set_discovery_relays_for_test, PRODUCTION_DISCOVERY_RELAYS};
pub use error::{InvalidUrlReason, RelayError, RelayResult};
#[cfg(feature = "test-utils")]
pub use manager::NegProbe;
pub use manager::{
    allow_ws_loopback_for_test, ws_loopback_allowed_for_test, FanoutTransport, MemberLookup,
    Nip65Relays, RelayManager,
};
pub(crate) use manager::{foreign_relay_dialable, retain_dialable_foreign_relays};
pub use publishers::{
    build_nip09_deletion, build_nip65_relay_list_event, build_relay_list_event,
    build_unpublish_event, dedup_relay_targets, superseding_created_at, PublisherError,
    PublisherResult,
};
pub use types::{PublishResult, RelayConnectionStatus, RelayFetchOutcome, RelayStatus};
pub use url_norm::{canonicalize, normalize_relay_url};

use crate::log_alias::{self, LogAliasClass, LogHandle};

/// The log handle for a circle whose id is in hand as `hex(nostr_group_id)`.
///
/// The subscribe and receive planes carry the id as hex, while
/// [`log_alias::circle`] takes the 32 bytes; `log_alias` normalises both to the
/// same canonical form, so a line here and a line elsewhere name one circle by
/// one handle (Security Rule 15).
pub(crate) fn circle_handle(group_id_hex: &str) -> LogHandle {
    log_alias::alias(LogAliasClass::Circle, group_id_hex.as_bytes())
}
