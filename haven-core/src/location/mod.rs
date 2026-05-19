//! Location module for Haven.
//!
//! Provides location messages encrypted via MLS group messaging, with:
//! - Geohash encoding for compact location representation
//! - Automatic metadata stripping (device ID, altitude, speed, etc.)
//! - Freshness/retention windows
//!
//! # Example Usage
//!
//! ```
//! use haven_core::location::LocationMessage;
//!
//! let location = LocationMessage::new(37.7749295, -122.4194155);
//! assert!(!location.geohash.is_empty());
//!
//! // Check expiration
//! assert!(!location.is_expired());
//!
//! // Serialize for transmission (metadata is NOT included)
//! let json = serde_json::to_string(&location).unwrap();
//! let _ = json;
//! ```

pub mod geohash;
pub mod nostr;
pub(crate) mod ttl;
pub mod types;

pub use geohash::{geohash_to_location, location_to_geohash};
pub use ttl::{compute_jittered_publish_interval_secs, PUBLISH_INTERVAL_JITTER_FRACTION_BP};
pub use types::{
    LocationMessage, LocationSettings, LOCATION_FRESHNESS_TTL_SECS, LOCATION_RETENTION_SECS,
};
