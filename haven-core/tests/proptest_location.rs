//! Property-based tests for location serialization and privacy.
//!
//! These tests verify:
//! - D1: `LocationMessage` serialization roundtrip at coordinate boundaries
//! - D3: Private metadata fields never leak into serialized JSON

// Some roundtrip checks compare deserialized floats for bit-exact equality
// at well-behaved boundary values; arbitrary-input cases compare with a
// tight epsilon because `serde_json` may lose up to ~1 ULP for arbitrary
// f64 inputs.
#![allow(clippy::float_cmp)]

use haven_core::location::LocationMessage;
use proptest::prelude::*;

/// Tight roundtrip tolerance for arbitrary f64 inputs through JSON.
const FLOAT_ROUNDTRIP_EPSILON: f64 = 1e-12;

// ============================================================================
// D1: LocationMessage serialization roundtrip with boundary coordinates
// ============================================================================

/// Verifies that zero coordinates (0.0, 0.0) survive a JSON roundtrip without
/// corruption. The equator/prime-meridian intersection is a valid real-world
/// location and must not be silently dropped or altered.
#[test]
fn d1_zero_coordinates_roundtrip() {
    let location = LocationMessage::new(0.0, 0.0);
    let json = location.to_string().unwrap();
    let recovered = LocationMessage::from_string(&json).unwrap();

    assert_eq!(
        recovered.latitude, 0.0,
        "Zero latitude must survive roundtrip"
    );
    assert_eq!(
        recovered.longitude, 0.0,
        "Zero longitude must survive roundtrip"
    );
    assert_eq!(
        recovered.geohash, location.geohash,
        "Geohash must survive roundtrip"
    );
}

/// Verifies that the maximum valid latitude (+90.0, North Pole) and minimum
/// valid latitude (-90.0, South Pole) roundtrip correctly through JSON
/// serialization.
#[test]
fn d1_latitude_boundaries_roundtrip() {
    for lat in [90.0_f64, -90.0] {
        let location = LocationMessage::new(lat, 0.0);
        let json = location.to_string().unwrap();
        let recovered = LocationMessage::from_string(&json).unwrap();

        assert_eq!(
            recovered.latitude, location.latitude,
            "Latitude boundary {lat} must survive roundtrip"
        );
    }
}

/// Verifies that the maximum valid longitude (+180.0) and minimum valid
/// longitude (-180.0) roundtrip correctly through JSON serialization.
#[test]
fn d1_longitude_boundaries_roundtrip() {
    for lon in [180.0_f64, -180.0] {
        let location = LocationMessage::new(0.0, lon);
        let json = location.to_string().unwrap();
        let recovered = LocationMessage::from_string(&json).unwrap();

        assert_eq!(
            recovered.longitude, location.longitude,
            "Longitude boundary {lon} must survive roundtrip"
        );
    }
}

/// Verifies that negative coordinates near the valid boundaries roundtrip
/// correctly. Uses -89.999 and -179.999 to test values very close to the
/// minimum without hitting the exact boundary.
#[test]
fn d1_negative_near_boundary_roundtrip() {
    let location = LocationMessage::new(-89.999, -179.999);
    let json = location.to_string().unwrap();
    let recovered = LocationMessage::from_string(&json).unwrap();

    assert_eq!(
        recovered.latitude, location.latitude,
        "Near-boundary negative latitude must survive roundtrip"
    );
    assert_eq!(
        recovered.longitude, location.longitude,
        "Near-boundary negative longitude must survive roundtrip"
    );
}

/// Strategy that mixes fully arbitrary `f64` values (including subnormals
/// and huge magnitudes), a band straddling the valid longitude/latitude
/// edges, the non-finite trio, and the exact ±90 / ±180 seams plus values
/// a hair beyond them. This deliberately drives the clamp branch in
/// `LocationMessage::new` that the valid-range-only strategy never reaches.
fn unrestricted_coordinate() -> impl Strategy<Value = f64> {
    prop_oneof![
        any::<f64>(),
        -200.0..200.0,
        Just(f64::NAN),
        Just(f64::INFINITY),
        Just(f64::NEG_INFINITY),
        Just(90.0),
        Just(-90.0),
        Just(180.0),
        Just(-180.0),
        Just(90.0001),
        Just(180.0001),
    ]
}

/// Mirror of the production clamp in `LocationMessage::new`: any non-finite
/// or out-of-range value collapses to `0.0`, everything else passes through
/// unchanged. Kept independent of the source so the property cross-checks
/// the contract rather than re-deriving it from the same code under test.
fn expected_clamp(value: f64, max_abs: f64) -> f64 {
    if value.is_finite() && value.abs() <= max_abs {
        value
    } else {
        0.0
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(200))]

    /// Property: Any valid coordinate pair roundtrips through JSON within
    /// a tight tolerance. `serde_json` may lose up to ~1 ULP for arbitrary
    /// f64 values, so the comparison uses an absolute epsilon rather than
    /// bit-exact equality.
    #[test]
    fn d1_arbitrary_valid_coordinates_roundtrip(
        lat in -90.0f64..=90.0,
        lon in -180.0f64..=180.0,
    ) {
        let location = LocationMessage::new(lat, lon);
        let json = location.to_string().expect("serialization must succeed");
        let recovered = LocationMessage::from_string(&json).expect("deserialization must succeed");

        prop_assert!((recovered.latitude - location.latitude).abs() < FLOAT_ROUNDTRIP_EPSILON);
        prop_assert!((recovered.longitude - location.longitude).abs() < FLOAT_ROUNDTRIP_EPSILON);
        prop_assert_eq!(recovered.geohash, location.geohash);
    }

    /// Property (RP-1): The constructed coordinates are ALWAYS finite and in
    /// `[-90,90] × [-180,180]`, and every non-finite / out-of-range input is
    /// clamped to exactly `0.0`. This exercises the validation branch that
    /// the valid-range-only strategy above never reaches — without it the
    /// clamp could be deleted and the suite would still pass.
    #[test]
    fn d1_arbitrary_unrestricted_coordinates_are_clamped_and_in_range(
        lat in unrestricted_coordinate(),
        lon in unrestricted_coordinate(),
    ) {
        let location = LocationMessage::new(lat, lon);

        // Output invariant: always finite and inside the WGS84 envelope.
        prop_assert!(location.latitude.is_finite(), "latitude must be finite");
        prop_assert!(location.longitude.is_finite(), "longitude must be finite");
        prop_assert!(
            (-90.0..=90.0).contains(&location.latitude),
            "latitude {} escaped [-90,90]",
            location.latitude
        );
        prop_assert!(
            (-180.0..=180.0).contains(&location.longitude),
            "longitude {} escaped [-180,180]",
            location.longitude
        );

        // Clamp semantics: invalid inputs become 0.0, valid inputs pass through.
        prop_assert_eq!(location.latitude, expected_clamp(lat, 90.0));
        prop_assert_eq!(location.longitude, expected_clamp(lon, 180.0));

        // A finite, in-range output must always serialize and round-trip.
        let json = location.to_string().expect("serialization must succeed");
        let recovered = LocationMessage::from_string(&json).expect("deserialization must succeed");
        prop_assert!((recovered.latitude - location.latitude).abs() < FLOAT_ROUNDTRIP_EPSILON);
        prop_assert!((recovered.longitude - location.longitude).abs() < FLOAT_ROUNDTRIP_EPSILON);
    }

    /// Property (RP-1): Coordinates pressed right up against the antimeridian
    /// (lon → ±180) and the poles (lat → ±90) survive a full
    /// `to_string` → `from_string` round-trip with both coordinates and the
    /// derived geohash intact. These seams are where geohash quantization and
    /// the inclusive clamp boundary interact, so a regression that mishandled
    /// the edge (e.g. an exclusive bound) would surface here.
    #[test]
    fn d1_antimeridian_and_pole_geohash_roundtrip(
        lat_edge in 89.0f64..=90.0,
        lon_edge in 179.0f64..=180.0,
        north in any::<bool>(),
        east in any::<bool>(),
    ) {
        let lat = if north { lat_edge } else { -lat_edge };
        let lon = if east { lon_edge } else { -lon_edge };

        let location = LocationMessage::new(lat, lon);

        // These inputs are all in-range, so the clamp must NOT fire.
        prop_assert_eq!(location.latitude, lat);
        prop_assert_eq!(location.longitude, lon);
        prop_assert!(!location.geohash.is_empty(), "edge coords must geohash");
        prop_assert_eq!(location.geohash.len(), 8);

        let json = location.to_string().expect("serialization must succeed");
        let recovered = LocationMessage::from_string(&json).expect("deserialization must succeed");

        prop_assert!((recovered.latitude - location.latitude).abs() < FLOAT_ROUNDTRIP_EPSILON);
        prop_assert!((recovered.longitude - location.longitude).abs() < FLOAT_ROUNDTRIP_EPSILON);
        prop_assert_eq!(recovered.geohash, location.geohash);
    }
}

// ============================================================================
// D3: Private fields never appear in serialized LocationMessage
// ============================================================================

/// Verifies that privacy-sensitive metadata fields (`device_id`, `altitude`,
/// `speed`, `heading`, `raw_accuracy`) are never present in the serialized
/// JSON output, regardless of whether they contain values.
#[test]
fn d3_private_fields_absent_when_populated() {
    let mut location = LocationMessage::new(37.7749, -122.4194);
    location.device_id = Some("iPhone-ABC-123".to_string());
    location.altitude = Some(42.5);
    location.speed = Some(5.5);
    location.heading = Some(270.0);
    location.raw_accuracy = Some(8.5);

    let json = location.to_string().unwrap();

    let forbidden = ["device_id", "altitude", "speed", "heading", "raw_accuracy"];
    for field in &forbidden {
        assert!(
            !json.contains(field),
            "Private field '{field}' must not appear in serialized JSON"
        );
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(200))]

    /// Property: For any valid coordinate, the serialized JSON never contains
    /// any of the private metadata field names. This guards against accidental
    /// `serde(skip)` removal during refactoring.
    #[test]
    fn d3_private_fields_never_in_json(
        lat in -90.0f64..=90.0,
        lon in -180.0f64..=180.0,
    ) {
        let location = LocationMessage::new(lat, lon);
        let json = location.to_string().expect("serialization must succeed");

        let forbidden = ["device_id", "altitude", "speed", "heading", "raw_accuracy"];
        for field in &forbidden {
            prop_assert!(
                !json.contains(field),
                "Private field '{}' leaked into serialized JSON: {}",
                field,
                json,
            );
        }
    }
}
