//! Nostr integration for location sharing.
//!
//! This module handles publishing location data to Nostr relays using:
//! - Marmot event kind 445 (Group Message)
//! - MLS encryption for end-to-end security
//! - Optional geohash tags for relay filtering
//! - Automatic expiration handling (NIP-40)
//!
//! # Privacy Features
//!
//! - Location is encrypted before publishing
//! - Geohash tags are optional (disabled by default)
//! - All traffic routes through Tor (to be implemented)

use super::types::LocationMessage;

/// Builder for creating Nostr location events.
///
/// This struct is responsible for constructing Nostr events that contain
/// encrypted location data. It supports optional geohash tagging for
/// relay-side filtering.
///
/// # Examples
///
/// ```
/// use haven_core::location::nostr::LocationEventBuilder;
///
/// let builder = LocationEventBuilder::new(false);  // No geohash tags
/// ```
#[derive(Debug, Clone)]
pub struct LocationEventBuilder {
    /// Whether to include geohash tags in events (user-configurable)
    include_geohash_tag: bool,
}

impl LocationEventBuilder {
    /// Creates a new `LocationEventBuilder`.
    ///
    /// # Arguments
    ///
    /// * `include_geohash_tag` - Whether to add geohash tags to events
    ///
    /// # Examples
    ///
    /// ```
    /// use haven_core::location::nostr::LocationEventBuilder;
    ///
    /// // Maximum privacy - no geohash tags
    /// let builder = LocationEventBuilder::new(false);
    ///
    /// // Performance mode - include geohash tags for relay filtering
    /// let builder_perf = LocationEventBuilder::new(true);
    /// ```
    #[must_use]
    pub const fn new(include_geohash_tag: bool) -> Self {
        Self {
            include_geohash_tag,
        }
    }

    /// Prepares location data for publishing to Nostr.
    ///
    /// This method serializes the location to JSON. In a future implementation,
    /// it will also encrypt the data with MLS and create a Nostr event.
    ///
    /// # Arguments
    ///
    /// * `location` - The location message to publish
    ///
    /// # Returns
    ///
    /// JSON string representation of the location (to be encrypted in future)
    ///
    /// # Errors
    ///
    /// Returns an error if JSON serialization fails.
    ///
    /// # Examples
    ///
    /// ```
    /// use haven_core::location::{LocationMessage, nostr::LocationEventBuilder};
    ///
    /// let location = LocationMessage::new(37.7749, -122.4194);
    /// let builder = LocationEventBuilder::new(false);
    ///
    /// let json = builder.prepare_location_data(&location).unwrap();
    /// assert!(json.contains("latitude"));
    /// ```
    pub fn prepare_location_data(&self, location: &LocationMessage) -> Result<String, String> {
        location.to_json().map_err(|e| e.to_string())
    }

    /// Returns whether geohash tags will be included in events.
    #[must_use]
    pub const fn includes_geohash_tag(&self) -> bool {
        self.include_geohash_tag
    }
}

impl Default for LocationEventBuilder {
    fn default() -> Self {
        Self::new(false) // Privacy-first default
    }
}

// Future implementation will include:
// - MLS encryption integration
// - Nostr event creation (kind 445)
// - Geohash tag generation (precision 5 for relay filtering)
// - NIP-40 expiration tags
// - Tor routing via arti-client
// - Relay publishing

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_builder_new_with_geohash() {
        let builder = LocationEventBuilder::new(true);
        assert!(builder.includes_geohash_tag());
    }

    #[test]
    fn event_builder_new_without_geohash() {
        let builder = LocationEventBuilder::new(false);
        assert!(!builder.includes_geohash_tag());
    }

    #[test]
    fn event_builder_default_privacy_first() {
        let builder = LocationEventBuilder::default();
        assert!(!builder.includes_geohash_tag()); // Privacy-first default
    }

    #[test]
    fn prepare_location_data_success() {
        let location = LocationMessage::new(37.7749, -122.4194);
        let builder = LocationEventBuilder::new(false);

        let json = builder.prepare_location_data(&location).unwrap();

        assert!(json.contains("latitude"));
        assert!(json.contains("longitude"));
        assert!(json.contains("geohash"));
        assert!(json.contains("timestamp"));
    }

    #[test]
    fn prepare_location_data_excludes_private_fields() {
        let mut location = LocationMessage::new(37.7749, -122.4194);
        location.device_id = Some("secret".to_string());
        location.altitude = Some(100.0);

        let builder = LocationEventBuilder::new(false);
        let json = builder.prepare_location_data(&location).unwrap();

        // Verify private fields are NOT in the prepared data
        assert!(!json.contains("device_id"));
        assert!(!json.contains("secret"));
        assert!(!json.contains("altitude"));
    }
}
