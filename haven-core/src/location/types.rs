//! Location data types.

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

/// Precision level for coordinate obfuscation.
///
/// Determines how many decimal places are retained when obfuscating coordinates.
/// Lower precision means more privacy but less accuracy.
///
/// # Precision Table
///
/// | Precision | Decimal Places | Approximate Radius |
/// |-----------|----------------|-------------------|
/// | Private   | 2              | ~1.1 km           |
/// | Standard  | 4              | ~11 m             |
/// | Enhanced  | 5              | ~1.1 m            |
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum LocationPrecision {
    /// 2 decimal places (~1.1km radius) - maximum privacy
    Private,
    /// 4 decimal places (~11m radius) - balanced privacy and accuracy
    Standard,
    /// 5 decimal places (~1.1m radius) - default for precise family sharing
    #[default]
    Enhanced,
}

impl LocationPrecision {
    /// Returns the number of decimal places for this precision level.
    #[must_use]
    pub const fn decimal_places(self) -> i32 {
        match self {
            Self::Private => 2,
            Self::Standard => 4,
            Self::Enhanced => 5,
        }
    }
}

/// A privacy-focused location message.
///
/// This struct represents a location that has been obfuscated for privacy.
/// It only contains the minimum necessary information for family location sharing.
///
/// # Privacy Features
///
/// - Coordinates are obfuscated to the specified precision
/// - Metadata (device ID, altitude, speed, heading) is never serialized
/// - Automatic expiration (24 hours default)
/// - Geohash encoding for approximate location matching
///
/// # Example
///
/// ```
/// use haven_core::location::LocationMessage;
///
/// let location = LocationMessage::new(37.7749295, -122.4194155);
/// // Raw coordinates: 37.7749295, -122.4194155
/// // Obfuscated:      37.77493,   -122.41942 (5 decimals - Enhanced precision)
/// assert_eq!(location.latitude, 37.77493);
/// assert_eq!(location.longitude, -122.41942);
/// ```
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocationMessage {
    /// Obfuscated latitude (precision determined by `precision` field)
    pub latitude: f64,

    /// Obfuscated longitude (precision determined by `precision` field)
    pub longitude: f64,

    /// Geohash representation for approximate location matching
    pub geohash: String,

    /// When location was recorded (UTC)
    pub timestamp: DateTime<Utc>,

    /// When this location expires (24 hours default)
    pub expires_at: DateTime<Utc>,

    /// Precision level used for obfuscation
    pub precision: LocationPrecision,

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

impl LocationMessage {
    /// Creates a new `LocationMessage` with default precision (Enhanced: 5 decimals).
    ///
    /// The coordinates will be obfuscated to 5 decimal places (~1.1m radius).
    /// Geohash is generated at precision 8 (~19m × 38m cell).
    /// Expiration is set to 24 hours from now.
    ///
    /// # Arguments
    ///
    /// * `lat` - Raw latitude from GPS
    /// * `lon` - Raw longitude from GPS
    ///
    /// # Examples
    ///
    /// ```
    /// use haven_core::location::LocationMessage;
    ///
    /// let location = LocationMessage::new(37.7749295, -122.4194155);
    /// // Uses Enhanced precision (5 decimals) by default
    /// assert_eq!(location.latitude, 37.77493);
    /// assert_eq!(location.longitude, -122.41942);
    /// assert_eq!(location.geohash.len(), 8);
    /// ```
    #[must_use]
    pub fn new(lat: f64, lon: f64) -> Self {
        Self::with_precision(lat, lon, LocationPrecision::default())
    }

    /// Creates a new `LocationMessage` with custom precision.
    ///
    /// # Arguments
    ///
    /// * `lat` - Raw latitude from GPS
    /// * `lon` - Raw longitude from GPS
    /// * `precision` - Desired precision level for obfuscation
    ///
    /// # Examples
    ///
    /// ```
    /// use haven_core::location::{LocationMessage, LocationPrecision};
    ///
    /// let location = LocationMessage::with_precision(
    ///     37.7749295,
    ///     -122.4194155,
    ///     LocationPrecision::Private,
    /// );
    /// assert_eq!(location.latitude, 37.77);  // 2 decimal places
    /// ```
    #[must_use]
    pub fn with_precision(lat: f64, lon: f64, precision: LocationPrecision) -> Self {
        use crate::location::privacy::{location_to_geohash, obfuscate_coordinate};

        // SECURITY: Input validation - ensure coordinates are valid
        // Latitude must be -90.0 to 90.0, Longitude must be -180.0 to 180.0
        // This prevents malicious or corrupted data from being processed
        let validated_lat = if lat.is_finite() && (-90.0..=90.0).contains(&lat) {
            lat
        } else {
            0.0 // Default to equator if invalid
        };

        let validated_lon = if lon.is_finite() && (-180.0..=180.0).contains(&lon) {
            lon
        } else {
            0.0 // Default to prime meridian if invalid
        };

        let obfuscated_lat = obfuscate_coordinate(validated_lat, precision);
        let obfuscated_lon = obfuscate_coordinate(validated_lon, precision);

        Self {
            latitude: obfuscated_lat,
            longitude: obfuscated_lon,
            geohash: location_to_geohash(obfuscated_lat, obfuscated_lon, 8),
            timestamp: Utc::now(),
            expires_at: Utc::now() + Duration::hours(24),
            precision,
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
    /// assert!(!location.is_expired());  // Just created, not expired
    /// ```
    #[must_use]
    pub fn is_expired(&self) -> bool {
        Utc::now() > self.expires_at
    }

    /// Creates a `LocationMessage` from JSON string.
    ///
    /// # Errors
    ///
    /// Returns an error if the JSON is invalid or missing required fields.
    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }

    /// Converts this `LocationMessage` to a JSON string.
    ///
    /// Note: Privacy-sensitive fields (`device_id`, `altitude`, etc.) are NOT included.
    ///
    /// # Errors
    ///
    /// Returns an error if serialization fails (extremely rare).
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }
}

/// Settings for location sharing.
///
/// These settings control how location data is collected, obfuscated, and shared.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocationSettings {
    /// Precision level for coordinate obfuscation
    pub precision: LocationPrecision,

    /// Update interval in minutes (5-60)
    pub update_interval_minutes: u32,

    /// Whether to include geohash tags in Nostr events (default: false for privacy)
    ///
    /// When enabled:
    /// - Relays can filter events by approximate location (city-level)
    /// - Reduces data usage when traveling
    /// - Relays see which ~5km area you're in
    ///
    /// When disabled (default):
    /// - Maximum privacy - relays see nothing
    /// - Slightly higher data usage
    pub include_geohash_in_events: bool,
}

impl Default for LocationSettings {
    fn default() -> Self {
        Self {
            precision: LocationPrecision::default(),
            update_interval_minutes: 5,
            include_geohash_in_events: false, // Privacy-first default
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn location_precision_decimal_places() {
        assert_eq!(LocationPrecision::Private.decimal_places(), 2);
        assert_eq!(LocationPrecision::Standard.decimal_places(), 4);
        assert_eq!(LocationPrecision::Enhanced.decimal_places(), 5);
    }

    #[test]
    fn location_precision_default_is_enhanced() {
        assert_eq!(LocationPrecision::default(), LocationPrecision::Enhanced);
    }

    #[test]
    fn location_message_new_obfuscates_to_enhanced_precision() {
        let location = LocationMessage::new(37.774_929_5, -122.419_415_5);

        // Should be obfuscated to 5 decimal places (Enhanced is default)
        assert_eq!(location.latitude, 37.774_93);
        assert_eq!(location.longitude, -122.419_42);
        assert_eq!(location.precision, LocationPrecision::Enhanced);
    }

    #[test]
    fn location_message_with_precision_private() {
        let location = LocationMessage::with_precision(
            37.774_929_5,
            -122.419_415_5,
            LocationPrecision::Private,
        );

        // Should be obfuscated to 2 decimal places
        assert_eq!(location.latitude, 37.77);
        assert_eq!(location.longitude, -122.42);
    }

    #[test]
    fn location_message_with_precision_enhanced() {
        let location = LocationMessage::with_precision(
            37.774_929_5,
            -122.419_415_5,
            LocationPrecision::Enhanced,
        );

        // Should be obfuscated to 5 decimal places
        assert_eq!(location.latitude, 37.774_93);
        assert_eq!(location.longitude, -122.419_42);
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
        // Set expiration to 1 hour ago
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

        let json = location.to_json().unwrap();

        // Verify private fields are NOT in JSON
        assert!(!json.contains("device_id"));
        assert!(!json.contains("secret-device-id"));
        assert!(!json.contains("altitude"));
        assert!(!json.contains("speed"));
        assert!(!json.contains("heading"));
        assert!(!json.contains("raw_accuracy"));

        // Verify public fields ARE in JSON
        assert!(json.contains("latitude"));
        assert!(json.contains("longitude"));
        assert!(json.contains("geohash"));
        assert!(json.contains("timestamp"));
        assert!(json.contains("expires_at"));
    }

    #[test]
    fn location_message_roundtrip_json() {
        let original = LocationMessage::new(37.7749, -122.4194);
        let json = original.to_json().unwrap();
        let deserialized = LocationMessage::from_json(&json).unwrap();

        assert_eq!(original.latitude, deserialized.latitude);
        assert_eq!(original.longitude, deserialized.longitude);
        assert_eq!(original.geohash, deserialized.geohash);
        assert_eq!(original.precision, deserialized.precision);
    }

    #[test]
    fn location_settings_default_values() {
        let settings = LocationSettings::default();

        assert_eq!(settings.precision, LocationPrecision::Enhanced);
        assert_eq!(settings.update_interval_minutes, 5);
        assert!(!settings.include_geohash_in_events); // Privacy-first
    }

    // SECURITY TESTS - Input Validation

    #[test]
    fn location_message_rejects_nan_latitude() {
        let location = LocationMessage::new(f64::NAN, -122.4194);
        // Should default to 0.0 for invalid input
        assert_eq!(location.latitude, 0.0);
    }

    #[test]
    fn location_message_rejects_nan_longitude() {
        let location = LocationMessage::new(37.7749, f64::NAN);
        // Should default to 0.0 for invalid input
        assert_eq!(location.longitude, 0.0);
    }

    #[test]
    fn location_message_rejects_infinity_latitude() {
        let location = LocationMessage::new(f64::INFINITY, -122.4194);
        // Should default to 0.0 for invalid input
        assert_eq!(location.latitude, 0.0);
    }

    #[test]
    fn location_message_rejects_out_of_range_latitude() {
        // Latitude must be -90.0 to 90.0
        let location = LocationMessage::new(91.0, -122.4194);
        assert_eq!(location.latitude, 0.0);

        let location2 = LocationMessage::new(-91.0, -122.4194);
        assert_eq!(location2.latitude, 0.0);
    }

    #[test]
    fn location_message_rejects_out_of_range_longitude() {
        // Longitude must be -180.0 to 180.0
        let location = LocationMessage::new(37.7749, 181.0);
        assert_eq!(location.longitude, 0.0);

        let location2 = LocationMessage::new(37.7749, -181.0);
        assert_eq!(location2.longitude, 0.0);
    }

    #[test]
    fn location_message_accepts_valid_boundaries() {
        // Test boundary values
        let north_pole = LocationMessage::new(90.0, 0.0);
        assert_eq!(north_pole.latitude, 90.0);

        let south_pole = LocationMessage::new(-90.0, 0.0);
        assert_eq!(south_pole.latitude, -90.0);

        let date_line = LocationMessage::new(0.0, 180.0);
        assert_eq!(date_line.longitude, 180.0);

        let neg_date_line = LocationMessage::new(0.0, -180.0);
        assert_eq!(neg_date_line.longitude, -180.0);
    }
}
