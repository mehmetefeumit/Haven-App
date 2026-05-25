/// Deterministic fake [LocationService] for E2E tests.
///
/// Production code uses `GeolocatorLocationService` which requires the
/// device's location permission and a real GPS fix. Neither is reliable
/// in a headless emulator: permission grants may need adb intent
/// gymnastics and the emulator's mock GPS reports `(0, 0)` unless
/// configured. Scenarios that need deterministic coordinates inject
/// this fake via a `locationServiceProvider` override so the production
/// publish path runs end-to-end without touching geolocator.
///
/// The fake intentionally implements every method on the interface:
/// returning realistic defaults from `requestPermission` /
/// `checkPermission` / `isLocationServiceEnabled` keeps the production
/// `locationPublisherProvider` code path linear (no early-returns due
/// to "permission denied").
library;

import 'dart:async';

import 'package:haven/src/services/location_service.dart';

/// A [LocationService] that always returns a fixed [Position] and reports
/// "always-on" permission state.
class FakeLocationService implements LocationService {
  /// Creates a fake that emits [latitude] / [longitude] for every read.
  FakeLocationService({
    required this.latitude,
    required this.longitude,
  });

  /// Latitude emitted by every `getCurrentLocation*` call.
  final double latitude;

  /// Longitude emitted by every `getCurrentLocation*` call.
  final double longitude;

  Position _position() => Position(
    latitude: latitude,
    longitude: longitude,
    timestamp: DateTime.now(),
  );

  @override
  Future<Position> getCurrentLocation() async => _position();

  @override
  Future<Position> getCurrentLocationFresh() async => _position();

  @override
  Stream<Position> getLocationStream() async* {
    yield _position();
  }

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<LocationPermissionStatus> checkPermission() async =>
      LocationPermissionStatus.always;
}

/// Sentinel coordinates used by scenario_03's Alice role.
///
/// Far from any populated area so the values are unmistakable in logs.
/// Same numerical pattern as the encryption-pipeline test sentinels.
const double aliceFakeLatitude = 12.345678;
const double aliceFakeLongitude = 87.654321;

/// Sentinel coordinates used by scenario_03's Bob role.
const double bobFakeLatitude = 13.456789;
const double bobFakeLongitude = 89.876543;
