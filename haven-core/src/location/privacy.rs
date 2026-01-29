//! Privacy-focused location obfuscation and geohash encoding.
//!
//! This module provides functions for:
//! - Coordinate obfuscation (reducing precision for privacy)
//! - Geohash encoding (approximate location representation)
//! - Geohash decoding (for testing and verification)

use super::types::LocationPrecision;

/// Obfuscates a coordinate to a specified precision by reducing decimal places.
///
/// This function implements privacy protection by reducing the precision of GPS
/// coordinates. The precision parameter determines how many decimal places to retain.
///
/// # Precision vs. Accuracy
///
/// | Decimal Places | Approximate Radius | Use Case |
/// |----------------|-------------------|----------|
/// | 2              | ~1.1 km           | City-level privacy |
/// | 4              | ~11 m             | Family sharing (default) |
/// | 5              | ~1.1 m            | High precision |
///
/// # Arguments
///
/// * `coord` - Raw coordinate (latitude or longitude)
/// * `precision` - Desired precision level
///
/// # Examples
///
/// ```
/// use haven_core::location::{obfuscate_coordinate, LocationPrecision};
///
/// let raw_lat = 37.7749295;
/// let obfuscated = obfuscate_coordinate(raw_lat, LocationPrecision::Standard);
/// assert_eq!(obfuscated, 37.7749);  // 4 decimal places
/// ```
#[must_use]
pub fn obfuscate_coordinate(coord: f64, precision: LocationPrecision) -> f64 {
    // SECURITY: Input validation to prevent NaN and invalid coordinates
    // This protects against malicious or corrupted GPS data
    if !coord.is_finite() {
        // Return 0.0 for NaN or Infinity - caller should validate
        return 0.0;
    }

    let decimals = precision.decimal_places();
    let multiplier = 10_f64.powi(decimals);
    (coord * multiplier).round() / multiplier
}

/// Converts latitude/longitude to a geohash string.
///
/// Geohash is a geocoding system that encodes geographic coordinates into a
/// short string of letters and digits. Each additional character provides
/// approximately 5x more precision.
///
/// # Geohash Precision Table
///
/// | Length | Cell Width | Cell Height | Use Case |
/// |--------|-----------|-------------|----------|
/// | 5      | ±2.4 km   | ±2.4 km     | City-level (relay filtering) |
/// | 6      | ±0.61 km  | ±0.61 km    | Neighborhood |
/// | 7      | ±0.076 km | ±0.15 km    | Street |
/// | 8      | ±0.019 km | ±0.019 km   | Building (matches 4-decimal coords) |
///
/// # Arguments
///
/// * `lat` - Latitude
/// * `lon` - Longitude
/// * `precision` - Geohash length (typically 5-8)
///
/// # Examples
///
/// ```
/// use haven_core::location::location_to_geohash;
///
/// let geohash = location_to_geohash(37.7749, -122.4194, 8);
/// assert_eq!(geohash.len(), 8);
/// // Output: "9q8yyz8r"
/// ```
///
/// # Error Handling
///
/// Returns an empty string if encoding fails. This is extremely rare and indicates
/// invalid input coordinates such as:
/// - NaN (Not a Number) values
/// - Infinite values
/// - Out-of-range coordinates (latitude not in -90..90, longitude not in -180..180)
///
/// Callers should check for empty strings if validation is needed, though in normal
/// operation with GPS data this should never occur.
#[must_use]
pub fn location_to_geohash(lat: f64, lon: f64, precision: u8) -> String {
    geohash::encode(geohash::Coord { x: lon, y: lat }, precision as usize)
        .unwrap_or_else(|_| String::new())
}

/// Decodes a geohash string to approximate latitude/longitude.
///
/// Returns the center point of the geohash cell. The precision of the result
/// depends on the length of the geohash string.
///
/// # Arguments
///
/// * `geohash` - Geohash string to decode
///
/// # Returns
///
/// Tuple of (latitude, longitude) representing the center of the geohash cell.
///
/// # Examples
///
/// ```
/// use haven_core::location::{location_to_geohash, geohash_to_location};
///
/// let original_lat = 37.7749;
/// let original_lon = -122.4194;
///
/// let geohash = location_to_geohash(original_lat, original_lon, 8);
/// let (decoded_lat, decoded_lon) = geohash_to_location(&geohash);
///
/// // Decoded coordinates should be very close to original
/// assert!((decoded_lat - original_lat).abs() < 0.0001);
/// assert!((decoded_lon - original_lon).abs() < 0.0001);
/// ```
///
/// # Error Handling
///
/// Returns (0.0, 0.0) if decoding fails. This occurs when the geohash string is:
/// - Empty
/// - Contains invalid characters (not in base32 alphabet)
/// - Malformed or corrupted
///
/// Note: (0.0, 0.0) is a valid coordinate (Gulf of Guinea, off Africa's coast), so
/// callers validating output should check the input geohash first if (0.0, 0.0) is
/// a possible valid result in their use case.
#[must_use]
pub fn geohash_to_location(geohash: &str) -> (f64, f64) {
    geohash::decode(geohash)
        .map(|(coord, _, _)| (coord.y, coord.x))
        .unwrap_or((0.0, 0.0))
}

/// Calculates the approximate error radius for a given geohash precision.
///
/// Returns the maximum distance (in meters) from the geohash center to any
/// point within the geohash cell. This is a constant-time lookup operation.
///
/// # Arguments
///
/// * `precision` - Geohash length (1-10, where higher = more precise)
///
/// # Examples
///
/// ```
/// use haven_core::location::privacy::geohash_error_radius;
///
/// let error_8 = geohash_error_radius(8);
/// assert_eq!(error_8, 19.0);  // Precision 8 is ±19m
/// ```
#[must_use]
pub const fn geohash_error_radius(precision: u8) -> f64 {
    // Approximate error radius in meters
    match precision {
        1 => 2_500_000.0, // ±2500 km
        2 => 630_000.0,   // ±630 km
        3 => 78_000.0,    // ±78 km
        4 => 20_000.0,    // ±20 km
        5 => 2_400.0,     // ±2.4 km
        6 => 610.0,       // ±610 m
        7 => 76.0,        // ±76 m
        8 => 19.0,        // ±19 m
        9 => 2.4,         // ±2.4 m
        10 => 0.6,        // ±0.6 m
        _ => 0.0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn obfuscate_to_4_decimals() {
        let raw_lat = 37.774_929_5;
        let obfuscated = obfuscate_coordinate(raw_lat, LocationPrecision::Standard);
        assert_eq!(obfuscated, 37.7749);

        // Verify precision loss is minimal
        assert!((raw_lat - obfuscated).abs() < 0.0001);
    }

    #[test]
    fn obfuscate_to_2_decimals() {
        let raw_lat = 37.774_929_5;
        let obfuscated = obfuscate_coordinate(raw_lat, LocationPrecision::Private);
        assert_eq!(obfuscated, 37.77);
    }

    #[test]
    fn obfuscate_to_5_decimals() {
        let raw_lat = 37.774_929_5;
        let obfuscated = obfuscate_coordinate(raw_lat, LocationPrecision::Enhanced);
        assert_eq!(obfuscated, 37.774_93);
    }

    #[test]
    fn obfuscate_negative_longitude() {
        let raw_lon = -122.419_415_5;
        let obfuscated = obfuscate_coordinate(raw_lon, LocationPrecision::Standard);
        assert_eq!(obfuscated, -122.4194);
    }

    #[test]
    fn geohash_precision_8() {
        let geohash = location_to_geohash(37.7749, -122.4194, 8);
        assert_eq!(geohash.len(), 8);
    }

    #[test]
    fn geohash_decode_accuracy() {
        let original_lat = 37.7749;
        let original_lon = -122.4194;

        let geohash = location_to_geohash(original_lat, original_lon, 8);
        let (decoded_lat, decoded_lon) = geohash_to_location(&geohash);

        // Precision 8 should be within ~20m, which is ~0.0002 degrees
        assert!((decoded_lat - original_lat).abs() < 0.0002);
        assert!((decoded_lon - original_lon).abs() < 0.0002);
    }

    #[test]
    fn geohash_roundtrip() {
        let lat = 37.7749;
        let lon = -122.4194;

        let geohash = location_to_geohash(lat, lon, 8);
        let (decoded_lat, decoded_lon) = geohash_to_location(&geohash);

        // Re-encode the decoded coordinates
        let geohash2 = location_to_geohash(decoded_lat, decoded_lon, 8);

        // Should produce the same geohash
        assert_eq!(geohash, geohash2);
    }

    #[test]
    fn geohash_different_precisions() {
        let lat = 37.7749;
        let lon = -122.4194;

        let geo5 = location_to_geohash(lat, lon, 5);
        let geo8 = location_to_geohash(lat, lon, 8);

        assert_eq!(geo5.len(), 5);
        assert_eq!(geo8.len(), 8);

        // Precision 8 should start with precision 5
        assert!(geo8.starts_with(&geo5));
    }

    #[test]
    fn geohash_error_radius_values() {
        assert_eq!(geohash_error_radius(8), 19.0);
        assert_eq!(geohash_error_radius(7), 76.0);
        assert_eq!(geohash_error_radius(5), 2_400.0);
    }

    #[test]
    fn obfuscate_zero_coordinate() {
        let obfuscated = obfuscate_coordinate(0.0, LocationPrecision::Standard);
        assert_eq!(obfuscated, 0.0);
    }

    #[test]
    fn geohash_handles_edge_cases() {
        // North Pole
        let geo_north = location_to_geohash(90.0, 0.0, 8);
        assert_eq!(geo_north.len(), 8);

        // South Pole
        let geo_south = location_to_geohash(-90.0, 0.0, 8);
        assert_eq!(geo_south.len(), 8);

        // International Date Line
        let geo_dateline = location_to_geohash(0.0, 180.0, 8);
        assert_eq!(geo_dateline.len(), 8);
    }

    #[test]
    fn obfuscate_maintains_sign() {
        let neg_coord = -37.774_929_5;
        let obfuscated = obfuscate_coordinate(neg_coord, LocationPrecision::Standard);
        assert!(obfuscated < 0.0); // Should remain negative
        assert_eq!(obfuscated, -37.7749);
    }

    #[test]
    fn geohash_nearby_locations_share_prefix() {
        let lat1 = 37.7749;
        let lon1 = -122.4194;

        // Location ~100m away
        let lat2 = 37.7758;
        let lon2 = -122.4203;

        let geo1 = location_to_geohash(lat1, lon1, 8);
        let geo2 = location_to_geohash(lat2, lon2, 8);

        // Should share most of the prefix (at least 6 characters)
        let common_prefix_len = geo1
            .chars()
            .zip(geo2.chars())
            .take_while(|(a, b)| a == b)
            .count();

        assert!(common_prefix_len >= 6);
    }

    // SECURITY TESTS - Input Validation

    #[test]
    fn obfuscate_handles_nan() {
        let result = obfuscate_coordinate(f64::NAN, LocationPrecision::Standard);
        assert_eq!(result, 0.0);
    }

    #[test]
    fn obfuscate_handles_infinity() {
        let result = obfuscate_coordinate(f64::INFINITY, LocationPrecision::Standard);
        assert_eq!(result, 0.0);
    }

    #[test]
    fn obfuscate_handles_neg_infinity() {
        let result = obfuscate_coordinate(f64::NEG_INFINITY, LocationPrecision::Standard);
        assert_eq!(result, 0.0);
    }
}
