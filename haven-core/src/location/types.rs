//! Location data types.

use std::fmt;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

/// Freshness window for a location update, in seconds.
///
/// Used as the offset for `LocationMessage::expires_at` (client-side
/// freshness signal). After this window passes, clients display the
/// event as stale / last-known rather than fresh. At 15 minutes and a
/// 2-minute nominal publish cadence, this covers ~7 missed publish cycles
/// before a location degrades to "stale" — providing resilience against
/// brief reconnects without holding stale data as "fresh".
///
/// Typed as `i64` to match `chrono::Duration::seconds`, so no
/// fallible conversion is needed at call sites.
pub const LOCATION_FRESHNESS_TTL_SECS: i64 = 15 * 60;

/// Receiver-side persistent retention window, in seconds.
///
/// Every receiver hard-codes this value when computing `purge_after`
/// for cached last-known-location rows. It is not configurable: stale
/// rows are dropped from disk after exactly 1 day, regardless of any
/// hint embedded in the encrypted payload.
pub const LOCATION_RETENTION_SECS: u64 = 24 * 60 * 60;

/// A location message shared with circle members.
///
/// Coordinates are sent at full GPS precision. Privacy-sensitive metadata
/// (device ID, altitude, speed, heading, raw accuracy) is never serialized.
///
/// # Example
///
/// ```
/// use haven_core::location::LocationMessage;
///
/// let location = LocationMessage::new(37.7749295, -122.4194155);
/// assert_eq!(location.latitude, 37.7749295);
/// assert_eq!(location.longitude, -122.4194155);
/// ```
#[derive(Clone, Serialize, Deserialize)]
pub struct LocationMessage {
    /// Latitude (exact GPS reading)
    pub latitude: f64,

    /// Longitude (exact GPS reading)
    pub longitude: f64,

    /// Geohash representation for compact location matching
    pub geohash: String,

    /// When location was recorded (UTC)
    pub timestamp: DateTime<Utc>,

    /// When this location becomes stale (15 minutes default).
    ///
    /// Client-side freshness signal. After this timestamp, the event
    /// should be displayed as a last-known/stale position, not as
    /// fresh data. Distinct from the receiver-side persistence window
    /// (`LOCATION_RETENTION_SECS`, hard-coded at 1 day): this is when
    /// the displayed pin turns "stale", not when the row is purged.
    pub expires_at: DateTime<Utc>,

    /// Sender's self-chosen display name, visible only to circle members
    /// after MLS decryption. Never published to relays in the clear.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,

    // Privacy-sensitive fields - NEVER serialized
    /// Device ID (not serialized for privacy)
    #[serde(skip)]
    pub device_id: Option<String>,

    /// Raw GPS accuracy in meters (not serialized for privacy)
    #[serde(skip)]
    pub raw_accuracy: Option<f64>,

    /// Altitude in meters (not serialized for privacy)
    #[serde(skip)]
    pub altitude: Option<f64>,

    /// Speed in meters/second (not serialized for privacy)
    #[serde(skip)]
    pub speed: Option<f64>,

    /// Heading in degrees (not serialized for privacy)
    #[serde(skip)]
    pub heading: Option<f64>,
}

impl fmt::Debug for LocationMessage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LocationMessage")
            .field("latitude", &"<redacted>")
            .field("longitude", &"<redacted>")
            .field("geohash", &"<redacted>")
            .field("timestamp", &self.timestamp)
            .field("expires_at", &self.expires_at)
            .field("display_name", &"<redacted>")
            .field("device_id", &"<redacted>")
            .field("raw_accuracy", &"<redacted>")
            .field("altitude", &"<redacted>")
            .field("speed", &"<redacted>")
            .field("heading", &"<redacted>")
            .finish()
    }
}

impl LocationMessage {
    /// Creates a new `LocationMessage` with the exact GPS coordinates.
    ///
    /// Geohash is generated at precision 8 (~19m × 38m cell).
    /// `expires_at` is set to `LOCATION_FRESHNESS_TTL_SECS` (15 minutes) from
    /// now — this is the freshness window, not the persistence window.
    ///
    /// # Arguments
    ///
    /// * `lat` - Latitude from GPS
    /// * `lon` - Longitude from GPS
    ///
    /// # Examples
    ///
    /// ```
    /// use haven_core::location::LocationMessage;
    ///
    /// let location = LocationMessage::new(37.7749295, -122.4194155);
    /// assert_eq!(location.latitude, 37.7749295);
    /// assert_eq!(location.longitude, -122.4194155);
    /// assert_eq!(location.geohash.len(), 8);
    /// ```
    #[must_use]
    pub fn new(lat: f64, lon: f64) -> Self {
        use crate::location::geohash::location_to_geohash;

        // SECURITY: Input validation - ensure coordinates are valid.
        // Latitude must be -90.0 to 90.0, Longitude must be -180.0 to 180.0.
        let validated_lat = if lat.is_finite() && (-90.0..=90.0).contains(&lat) {
            lat
        } else {
            0.0
        };

        let validated_lon = if lon.is_finite() && (-180.0..=180.0).contains(&lon) {
            lon
        } else {
            0.0
        };

        Self {
            latitude: validated_lat,
            longitude: validated_lon,
            geohash: location_to_geohash(validated_lat, validated_lon, 8),
            timestamp: Utc::now(),
            expires_at: Utc::now() + Duration::seconds(LOCATION_FRESHNESS_TTL_SECS),
            display_name: None,
            device_id: None,
            raw_accuracy: None,
            altitude: None,
            speed: None,
            heading: None,
        }
    }

    /// Checks if this location has expired.
    ///
    /// # Examples
    ///
    /// ```
    /// use haven_core::location::LocationMessage;
    ///
    /// let location = LocationMessage::new(37.7749, -122.4194);
    /// assert!(!location.is_expired());
    /// ```
    #[must_use]
    pub fn is_expired(&self) -> bool {
        Utc::now() > self.expires_at
    }

    /// Sets the sender's display name (sanitized: trimmed, max 64 chars, no control chars).
    #[must_use]
    pub fn with_display_name(mut self, name: Option<String>) -> Self {
        self.display_name = sanitize_display_name(name);
        self
    }

    /// Creates a `LocationMessage` from a string.
    ///
    /// # Errors
    ///
    /// Returns an error if the string is invalid or missing required fields.
    pub fn from_string(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }

    /// Converts this `LocationMessage` to a string.
    ///
    /// Note: Privacy-sensitive fields (`device_id`, `altitude`, etc.) are NOT included.
    ///
    /// # Errors
    ///
    /// Returns an error if serialization fails (extremely rare).
    pub fn to_string(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }
}

/// Sanitizes a display name: trims whitespace, strips control characters,
/// and caps at 64 characters. Returns `None` if the result is empty.
#[must_use]
pub fn sanitize_display_name(name: Option<String>) -> Option<String> {
    name.map(|n| n.trim().to_string())
        .filter(|n| !n.is_empty())
        .map(|n| n.chars().filter(|c| !c.is_control()).collect::<String>())
        .filter(|n| !n.is_empty())
        .map(|n| {
            if n.chars().count() > 64 {
                n.chars().take(64).collect()
            } else {
                n
            }
        })
}

/// Settings for location sharing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocationSettings {
    /// Update interval in minutes (5-60)
    pub update_interval_minutes: u32,
}

impl Default for LocationSettings {
    fn default() -> Self {
        Self {
            update_interval_minutes: 5,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn location_message_new_preserves_exact_coordinates() {
        let location = LocationMessage::new(37.774_929_5, -122.419_415_5);

        assert_eq!(location.latitude, 37.774_929_5);
        assert_eq!(location.longitude, -122.419_415_5);
    }

    #[test]
    fn location_message_geohash_has_8_characters() {
        let location = LocationMessage::new(37.7749, -122.4194);
        assert_eq!(location.geohash.len(), 8);
    }

    #[test]
    fn location_message_not_expired_when_created() {
        let location = LocationMessage::new(37.7749, -122.4194);
        assert!(!location.is_expired());
    }

    #[test]
    fn location_message_is_expired_when_past_expiration() {
        let mut location = LocationMessage::new(37.7749, -122.4194);
        location.expires_at = Utc::now() - Duration::hours(1);
        assert!(location.is_expired());
    }

    #[test]
    fn location_message_json_excludes_private_fields() {
        let mut location = LocationMessage::new(37.7749, -122.4194);
        location.device_id = Some("secret-device-id".to_string());
        location.altitude = Some(100.0);
        location.speed = Some(5.5);
        location.heading = Some(270.0);
        location.raw_accuracy = Some(10.0);

        let json = location.to_string().unwrap();

        assert!(!json.contains("device_id"));
        assert!(!json.contains("secret-device-id"));
        assert!(!json.contains("altitude"));
        assert!(!json.contains("speed"));
        assert!(!json.contains("heading"));
        assert!(!json.contains("raw_accuracy"));

        assert!(json.contains("latitude"));
        assert!(json.contains("longitude"));
        assert!(json.contains("geohash"));
        assert!(json.contains("timestamp"));
        assert!(json.contains("expires_at"));
    }

    #[test]
    fn location_message_roundtrip_json() {
        let original = LocationMessage::new(37.7749, -122.4194);
        let json = original.to_string().unwrap();
        let deserialized = LocationMessage::from_string(&json).unwrap();

        assert_eq!(original.latitude, deserialized.latitude);
        assert_eq!(original.longitude, deserialized.longitude);
        assert_eq!(original.geohash, deserialized.geohash);
    }

    #[test]
    fn location_settings_default_values() {
        let settings = LocationSettings::default();
        assert_eq!(settings.update_interval_minutes, 5);
    }

    // SECURITY TESTS - Input Validation

    #[test]
    fn location_message_rejects_nan_latitude() {
        let location = LocationMessage::new(f64::NAN, -122.4194);
        assert_eq!(location.latitude, 0.0);
    }

    #[test]
    fn location_message_rejects_nan_longitude() {
        let location = LocationMessage::new(37.7749, f64::NAN);
        assert_eq!(location.longitude, 0.0);
    }

    #[test]
    fn location_message_rejects_infinity_latitude() {
        let location = LocationMessage::new(f64::INFINITY, -122.4194);
        assert_eq!(location.latitude, 0.0);
    }

    #[test]
    fn location_message_rejects_out_of_range_latitude() {
        let location = LocationMessage::new(91.0, -122.4194);
        assert_eq!(location.latitude, 0.0);

        let location2 = LocationMessage::new(-91.0, -122.4194);
        assert_eq!(location2.latitude, 0.0);
    }

    #[test]
    fn location_message_rejects_out_of_range_longitude() {
        let location = LocationMessage::new(37.7749, 181.0);
        assert_eq!(location.longitude, 0.0);

        let location2 = LocationMessage::new(37.7749, -181.0);
        assert_eq!(location2.longitude, 0.0);
    }

    #[test]
    fn location_message_accepts_valid_boundaries() {
        let north_pole = LocationMessage::new(90.0, 0.0);
        assert_eq!(north_pole.latitude, 90.0);

        let south_pole = LocationMessage::new(-90.0, 0.0);
        assert_eq!(south_pole.latitude, -90.0);

        let date_line = LocationMessage::new(0.0, 180.0);
        assert_eq!(date_line.longitude, 180.0);

        let neg_date_line = LocationMessage::new(0.0, -180.0);
        assert_eq!(neg_date_line.longitude, -180.0);
    }

    // DISPLAY NAME TESTS

    #[test]
    fn display_name_builder_sets_name() {
        let location = LocationMessage::new(0.0, 0.0).with_display_name(Some("Alice".to_string()));
        assert_eq!(location.display_name, Some("Alice".to_string()));
    }

    #[test]
    fn display_name_none_by_default() {
        let location = LocationMessage::new(0.0, 0.0);
        assert_eq!(location.display_name, None);
    }

    #[test]
    fn display_name_serialized_when_present() {
        let location = LocationMessage::new(0.0, 0.0).with_display_name(Some("Alice".to_string()));
        let json = location.to_string().unwrap();
        assert!(json.contains("\"display_name\":\"Alice\""));
    }

    #[test]
    fn display_name_omitted_when_none() {
        let location = LocationMessage::new(0.0, 0.0);
        let json = location.to_string().unwrap();
        assert!(!json.contains("display_name"));
    }

    #[test]
    fn unknown_legacy_fields_are_ignored() {
        // Older Haven builds emitted a `precision` field; deserialization must
        // tolerate it (and any other unknown field) for forward compatibility.
        let json = r#"{"latitude":0.0,"longitude":0.0,"geohash":"s0000000","timestamp":"2025-01-01T00:00:00Z","expires_at":"2025-01-02T00:00:00Z","precision":"Enhanced","retention_secs":86400}"#;
        let location = LocationMessage::from_string(json).unwrap();
        assert_eq!(location.latitude, 0.0);
        assert_eq!(location.longitude, 0.0);
    }

    // FRESHNESS WINDOW TESTS

    #[test]
    fn expires_at_uses_freshness_ttl() {
        let location = LocationMessage::new(0.0, 0.0);
        let expected_offset = Duration::seconds(LOCATION_FRESHNESS_TTL_SECS);
        let delta = (location.expires_at - location.timestamp) - expected_offset;
        assert!(delta.num_seconds().abs() <= 2, "delta was {delta:?}");
    }

    #[test]
    fn display_name_deserialization_with_field() {
        let json = r#"{"latitude":0.0,"longitude":0.0,"geohash":"s0000000","timestamp":"2025-01-01T00:00:00Z","expires_at":"2025-01-02T00:00:00Z","display_name":"Bob"}"#;
        let location = LocationMessage::from_string(json).unwrap();
        assert_eq!(location.display_name, Some("Bob".to_string()));
    }

    #[test]
    fn display_name_roundtrip() {
        let original =
            LocationMessage::new(37.7749, -122.4194).with_display_name(Some("Alice".to_string()));
        let json = original.to_string().unwrap();
        let deserialized = LocationMessage::from_string(&json).unwrap();
        assert_eq!(deserialized.display_name, Some("Alice".to_string()));
    }

    #[test]
    fn display_name_sanitize_trims_whitespace() {
        let location =
            LocationMessage::new(0.0, 0.0).with_display_name(Some("  Alice  ".to_string()));
        assert_eq!(location.display_name, Some("Alice".to_string()));
    }

    #[test]
    fn display_name_sanitize_strips_control_chars() {
        let location =
            LocationMessage::new(0.0, 0.0).with_display_name(Some("Ali\x00ce\n".to_string()));
        assert_eq!(location.display_name, Some("Alice".to_string()));
    }

    #[test]
    fn display_name_sanitize_truncates_at_64_chars() {
        let long_name = "A".repeat(100);
        let location = LocationMessage::new(0.0, 0.0).with_display_name(Some(long_name));
        assert_eq!(location.display_name.as_ref().map(|n| n.len()), Some(64));
    }

    #[test]
    fn display_name_sanitize_empty_becomes_none() {
        let location = LocationMessage::new(0.0, 0.0).with_display_name(Some(String::new()));
        assert_eq!(location.display_name, None);

        let location2 = LocationMessage::new(0.0, 0.0).with_display_name(Some("   ".to_string()));
        assert_eq!(location2.display_name, None);
    }

    #[test]
    fn display_name_sanitize_only_control_chars_becomes_none() {
        let location =
            LocationMessage::new(0.0, 0.0).with_display_name(Some("\x00\x01\x02".to_string()));
        assert_eq!(location.display_name, None);
    }
}
