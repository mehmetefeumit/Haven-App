//! Location module for Haven.
//!
//! Provides privacy-focused location determination with:
//! - Coordinate obfuscation to configurable precision
//! - Geohash encoding for approximate location sharing
//! - Automatic metadata stripping (device ID, altitude, speed, etc.)
//! - Expiration handling (24-hour default)
//!
//! # Privacy Guarantees
//!
//! - Coordinates are obfuscated before leaving the device
//! - Metadata is never serialized to JSON
//! - All location data has expiration timestamps
//! - Geohash precision is configurable per use case
//!
//! # Example Usage
//!
//! ```
//! use haven_core::location::{LocationMessage, LocationPrecision};
//!
//! // Create an obfuscated location with default precision (Enhanced: 5 decimals)
//! let location = LocationMessage::new(37.7749295, -122.4194155);
//! println!("Obfuscated: {}, {}", location.latitude, location.longitude);
//! println!("Geohash: {}", location.geohash);
//!
//! // Use custom precision for maximum privacy
//! let private_location = LocationMessage::with_precision(
//!     37.7749295,
//!     -122.4194155,
//!     LocationPrecision::Private, // Only 2 decimal places
//! );
//! println!("Private: {}, {}", private_location.latitude, private_location.longitude);
//!
//! // Check expiration
//! assert!(!location.is_expired()); // Fresh locations aren't expired
//!
//! // Serialize for transmission (metadata is NOT included)
//! let json = serde_json::to_string(&location).unwrap();
//! println!("JSON: {}", json);
//! ```

pub mod nostr;
pub mod privacy;
pub mod types;

pub use privacy::{geohash_to_location, location_to_geohash, obfuscate_coordinate};
pub use types::{LocationMessage, LocationPrecision, LocationSettings};
