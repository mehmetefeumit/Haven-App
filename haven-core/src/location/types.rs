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

/// Default value for how long a sender asks receivers to retain
/// their stale location in the persistent last-known-location cache.
///
/// Transmitted inside the encrypted inner `LocationMessage` as
/// `retention_secs`. Receivers honour this as a soft contract; it is
/// not cryptographically enforced.
pub const DEFAULT_SENDER_RETENTION_SECS: u64 = 24 * 60 * 60;

/// Hard receiver-side ceiling on `retention_secs`, regardless of the
/// value a sender requests. Defends against a misbehaving or forked
/// client asking receivers to store other people's locations forever.
///
/// This value is small enough (30 days = `2_592_000` seconds) that the
/// downstream `i64` conversion via `try_from` is infallible — callers
/// that have clamped to this ceiling may `.expect()` the conversion.
pub const LOCATION_RECEIVER_MAX_RETENTION_SECS: u64 = 30 * 24 * 60 * 60;

/// Serde default for `LocationMessage::retention_secs`, used when
/// deserializing events from older Haven builds that omit the field.
const fn default_retention_secs() -> u64 {
    DEFAULT_SENDER_RETENTION_SECS
}

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

    /// Stable textual label for this precision level.
    ///
    /// Used on both sides of the FFI boundary to avoid coupling the
    /// wire format to the compiler-generated `Debug` representation,
    /// which is explicitly not a stable serialization format.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Private => "Private",
            Self::Standard => "Standard",
            Self::Enhanced => "Enhanced",
        }
    }

    /// Parses a textual precision label. Case-sensitive; only the
    /// canonical values returned by [`Self::label`] are accepted.
    ///
    /// # Errors
    ///
    /// Returns `Err` with an error message if `value` is not one of
    /// `"Private"`, `"Standard"`, or `"Enhanced"`.
    pub fn from_label(value: &str) -> Result<Self, String> {
        match value {
            "Private" => Ok(Self::Private),
            "Standard" => Ok(Self::Standard),
            "Enhanced" => Ok(Self::Enhanced),
            other => Err(format!(
                "Invalid precision label: {other:?} (expected Private/Standard/Enhanced)"
            )),
        }
    }
}

impl fmt::Display for LocationPrecision {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.label())
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
/// - Freshness window via `expires_at` (15 minutes default)
/// - Sender-controlled persistent retention via `retention_secs`
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
#[derive(Clone, Serialize, Deserialize)]
pub struct LocationMessage {
    /// Obfuscated latitude (precision determined by `precision` field)
    pub latitude: f64,

    /// Obfuscated longitude (precision determined by `precision` field)
    pub longitude: f64,

    /// Geohash representation for approximate location matching
    pub geohash: String,

    /// When location was recorded (UTC)
    pub timestamp: DateTime<Utc>,

    /// When this location becomes stale (15 minutes default).
    ///
    /// Client-side freshness signal. After this timestamp, the event
    /// should be displayed as a last-known/stale position, not as
    /// fresh data. Not to be confused with `retention_secs`, which
    /// controls how long the receiver may persist the stale entry.
    pub expires_at: DateTime<Utc>,

    /// Precision level used for obfuscation
    pub precision: LocationPrecision,

    /// Sender's self-chosen display name, visible only to circle members
    /// after MLS decryption. Never published to relays in the clear.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,

    /// Maximum seconds a receiver should retain this location in its
    /// persistent last-known-location cache.
    ///
    /// The sender picks this value (typically via a settings page) to
    /// express how long other circle members may keep their stale copy
    /// of this user's location. Receivers enforce it as a soft contract,
    /// clamped to `LOCATION_RECEIVER_MAX_RETENTION_SECS`. A value of 0
    /// means "do not persist at all"; receivers may still display the
    /// location during the current session but must not write it to disk
    /// and must drop any prior stored row for this sender.
    ///
    /// This is not cryptographically enforced — a modified client could
    /// ignore it. The UI must be honest about this.
    #[serde(default = "default_retention_secs")]
    pub retention_secs: u64,

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
            .field("precision", &self.precision)
            .field("timestamp", &self.timestamp)
            .field("expires_at", &self.expires_at)
            .field("retention_secs", &self.retention_secs)
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
    /// Creates a new `LocationMessage` with default precision (Enhanced: 5 decimals).
    ///
    /// The coordinates will be obfuscated to 5 decimal places (~1.1m radius).
    /// Geohash is generated at precision 8 (~19m × 38m cell).
    /// `expires_at` is set to `LOCATION_FRESHNESS_TTL_SECS` (15 minutes) from
    /// now — this is the freshness window, not the persistence window.
    /// `retention_secs` defaults to `DEFAULT_SENDER_RETENTION_SECS` (24 hours).
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
            expires_at: Utc::now() + Duration::seconds(LOCATION_FRESHNESS_TTL_SECS),
            precision,
            display_name: None,
            retention_secs: DEFAULT_SENDER_RETENTION_SECS,
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

    /// Sets the sender's display name (sanitized: trimmed, max 64 chars, no control chars).
    #[must_use]
    pub fn with_display_name(mut self, name: Option<String>) -> Self {
        self.display_name = sanitize_display_name(name);
        self
    }

    /// Sets the sender's requested persistent retention window, in seconds.
    ///
    /// Values larger than `LOCATION_RECEIVER_MAX_RETENTION_SECS` are
    /// clamped to that ceiling. A value of 0 is preserved and signals
    /// receivers to immediately drop any stored row for this sender.
    #[must_use]
    pub fn with_retention_secs(mut self, secs: u64) -> Self {
        self.retention_secs = secs.min(LOCATION_RECEIVER_MAX_RETENTION_SECS);
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

        let json = location.to_string().unwrap();

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
        let json = original.to_string().unwrap();
        let deserialized = LocationMessage::from_string(&json).unwrap();

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
    fn display_name_backward_compat_deserialization() {
        // JSON without display_name field should deserialize to None
        let json = r#"{"latitude":0.0,"longitude":0.0,"geohash":"s0000000","timestamp":"2025-01-01T00:00:00Z","expires_at":"2025-01-02T00:00:00Z","precision":"Enhanced"}"#;
        let location = LocationMessage::from_string(json).unwrap();
        assert_eq!(location.display_name, None);
    }

    // RETENTION_SECS TESTS

    #[test]
    fn retention_secs_default_on_new() {
        let location = LocationMessage::new(0.0, 0.0);
        assert_eq!(location.retention_secs, DEFAULT_SENDER_RETENTION_SECS);
    }

    #[test]
    fn retention_secs_builder_sets_value() {
        let location = LocationMessage::new(0.0, 0.0).with_retention_secs(3600);
        assert_eq!(location.retention_secs, 3600);
    }

    #[test]
    fn retention_secs_builder_clamps_to_receiver_max() {
        let location = LocationMessage::new(0.0, 0.0).with_retention_secs(u64::MAX);
        assert_eq!(
            location.retention_secs,
            LOCATION_RECEIVER_MAX_RETENTION_SECS
        );
    }

    #[test]
    fn retention_secs_zero_preserved() {
        // 0 is the "do not persist" sentinel and must survive the clamp.
        let location = LocationMessage::new(0.0, 0.0).with_retention_secs(0);
        assert_eq!(location.retention_secs, 0);
    }

    #[test]
    fn retention_secs_serialized_in_json() {
        let location = LocationMessage::new(0.0, 0.0).with_retention_secs(3600);
        let json = location.to_string().unwrap();
        assert!(json.contains("\"retention_secs\":3600"));
    }

    #[test]
    fn retention_secs_forward_compat_deserialization() {
        // A JSON blob from an older Haven build without retention_secs must
        // deserialize with the default value.
        let json = r#"{"latitude":0.0,"longitude":0.0,"geohash":"s0000000","timestamp":"2025-01-01T00:00:00Z","expires_at":"2025-01-02T00:00:00Z","precision":"Enhanced"}"#;
        let location = LocationMessage::from_string(json).unwrap();
        assert_eq!(location.retention_secs, DEFAULT_SENDER_RETENTION_SECS);
    }

    #[test]
    fn retention_secs_roundtrip_with_zero() {
        let original = LocationMessage::new(37.7749, -122.4194).with_retention_secs(0);
        let json = original.to_string().unwrap();
        let deserialized = LocationMessage::from_string(&json).unwrap();
        assert_eq!(deserialized.retention_secs, 0);
    }

    #[test]
    fn retention_secs_roundtrip_with_max() {
        let original = LocationMessage::new(0.0, 0.0)
            .with_retention_secs(LOCATION_RECEIVER_MAX_RETENTION_SECS);
        let json = original.to_string().unwrap();
        let deserialized = LocationMessage::from_string(&json).unwrap();
        assert_eq!(
            deserialized.retention_secs,
            LOCATION_RECEIVER_MAX_RETENTION_SECS
        );
    }

    // FRESHNESS WINDOW TESTS

    #[test]
    fn expires_at_uses_freshness_ttl() {
        let location = LocationMessage::new(0.0, 0.0);
        let expected_offset = Duration::seconds(LOCATION_FRESHNESS_TTL_SECS);
        let delta = (location.expires_at - location.timestamp) - expected_offset;
        // Allow up to a 2-second skew from the two Utc::now() calls inside new().
        assert!(delta.num_seconds().abs() <= 2, "delta was {delta:?}");
    }

    #[test]
    fn display_name_deserialization_with_field() {
        let json = r#"{"latitude":0.0,"longitude":0.0,"geohash":"s0000000","timestamp":"2025-01-01T00:00:00Z","expires_at":"2025-01-02T00:00:00Z","precision":"Enhanced","display_name":"Bob"}"#;
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
