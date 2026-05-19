//! Geohash encoding/decoding helpers.
//!
//! Geohash is a geocoding system that encodes geographic coordinates into a
//! short string. Each additional character provides ~5x more precision.

/// Converts latitude/longitude to a geohash string.
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
/// ```
///
/// # Error Handling
///
/// Returns an empty string when encoding fails (NaN, infinite, or out-of-range
/// coordinates). With validated GPS input this should never occur.
#[must_use]
pub fn location_to_geohash(lat: f64, lon: f64, precision: u8) -> String {
    geohash::encode(geohash::Coord { x: lon, y: lat }, precision as usize)
        .unwrap_or_else(|_| String::new())
}

/// Decodes a geohash string to approximate latitude/longitude.
///
/// Returns the center point of the geohash cell.
///
/// # Examples
///
/// ```
/// use haven_core::location::{geohash_to_location, location_to_geohash};
///
/// let geohash = location_to_geohash(37.7749, -122.4194, 8);
/// let (lat, lon) = geohash_to_location(&geohash);
/// assert!((lat - 37.7749).abs() < 0.0001);
/// assert!((lon - -122.4194).abs() < 0.0001);
/// ```
///
/// # Error Handling
///
/// Returns `(0.0, 0.0)` if decoding fails (empty string or invalid characters).
#[must_use]
pub fn geohash_to_location(geohash: &str) -> (f64, f64) {
    if geohash.is_empty() {
        return (0.0, 0.0);
    }
    geohash::decode(geohash).map_or((0.0, 0.0), |(coord, _, _)| (coord.y, coord.x))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn geohash_length_matches_precision() {
        let geohash = location_to_geohash(37.7749, -122.4194, 8);
        assert_eq!(geohash.len(), 8);
    }

    #[test]
    fn geohash_roundtrip_within_tolerance() {
        let lat = 37.7749;
        let lon = -122.4194;
        let geohash = location_to_geohash(lat, lon, 8);
        let (decoded_lat, decoded_lon) = geohash_to_location(&geohash);

        assert!((decoded_lat - lat).abs() < 0.0001);
        assert!((decoded_lon - lon).abs() < 0.0001);
    }

    #[test]
    fn nan_latitude_returns_empty() {
        let result = location_to_geohash(f64::NAN, -122.4194, 8);
        assert!(result.is_empty());
    }

    #[test]
    fn nan_longitude_returns_empty() {
        let result = location_to_geohash(37.7749, f64::NAN, 8);
        assert!(result.is_empty());
    }

    #[test]
    fn out_of_range_returns_empty() {
        let result = location_to_geohash(95.0, -122.4194, 8);
        assert!(result.is_empty());
    }

    #[test]
    fn empty_geohash_returns_zero() {
        let (lat, lon) = geohash_to_location("");
        assert_eq!(lat, 0.0);
        assert_eq!(lon, 0.0);
    }

    #[test]
    fn invalid_geohash_returns_zero() {
        let (lat, lon) = geohash_to_location("not-a-geohash");
        assert_eq!(lat, 0.0);
        assert_eq!(lon, 0.0);
    }
}
