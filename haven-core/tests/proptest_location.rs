//! Property-based tests for location serialization and privacy.
//!
//! These tests verify:
//! - D1: `LocationMessage` serialization roundtrip at coordinate boundaries
//! - D3: Private metadata fields never leak into serialized JSON

// Roundtrip tests intentionally compare deserialized floats for bit-exact equality,
// because serde_json preserves the exact IEEE 754 representation.
#![allow(clippy::float_cmp)]

use haven_core::location::{LocationMessage, LocationPrecision};
use proptest::prelude::*;

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

/// Verifies that all three precision levels produce valid JSON output that
/// roundtrips correctly. Each precision truncates to a different number of
/// decimal places, so this tests that the serialization format handles all
/// three variants.
#[test]
fn d1_all_precision_levels_produce_valid_output() {
    let precisions = [
        LocationPrecision::Private,
        LocationPrecision::Standard,
        LocationPrecision::Enhanced,
    ];

    for precision in precisions {
        let location = LocationMessage::with_precision(37.774_929_5, -122.419_415_5, precision);
        let json = location.to_string().unwrap();

        assert!(!json.is_empty(), "JSON must not be empty for {precision:?}");

        let recovered = LocationMessage::from_string(&json).unwrap();
        assert_eq!(
            recovered.latitude, location.latitude,
            "Latitude must survive roundtrip for {precision:?}"
        );
        assert_eq!(
            recovered.longitude, location.longitude,
            "Longitude must survive roundtrip for {precision:?}"
        );
        assert_eq!(
            recovered.precision, precision,
            "Precision variant must survive roundtrip"
        );
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(200))]

    /// Property: Any valid coordinate pair roundtrips through JSON without data
    /// loss. The obfuscated coordinates and geohash are deterministic for a
    /// given input, so the recovered values must match exactly.
    #[test]
    fn d1_arbitrary_valid_coordinates_roundtrip(
        lat in -90.0f64..=90.0,
        lon in -180.0f64..=180.0,
    ) {
        let location = LocationMessage::new(lat, lon);
        let json = location.to_string().expect("serialization must succeed");
        let recovered = LocationMessage::from_string(&json).expect("deserialization must succeed");

        prop_assert_eq!(recovered.latitude, location.latitude);
        prop_assert_eq!(recovered.longitude, location.longitude);
        prop_assert_eq!(recovered.geohash, location.geohash);
        prop_assert_eq!(recovered.precision, location.precision);
    }

    /// Property: Every precision level produces a valid roundtrip for
    /// arbitrary valid coordinates.
    #[test]
    fn d1_any_precision_roundtrip(
        lat in -90.0f64..=90.0,
        lon in -180.0f64..=180.0,
        precision_idx in 0usize..3,
    ) {
        let precision = match precision_idx {
            0 => LocationPrecision::Private,
            1 => LocationPrecision::Standard,
            _ => LocationPrecision::Enhanced,
        };

        let location = LocationMessage::with_precision(lat, lon, precision);
        let json = location.to_string().expect("serialization must succeed");
        let recovered = LocationMessage::from_string(&json).expect("deserialization must succeed");

        prop_assert_eq!(recovered.latitude, location.latitude);
        prop_assert_eq!(recovered.longitude, location.longitude);
        prop_assert_eq!(recovered.precision, location.precision);
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
