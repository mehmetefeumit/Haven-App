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
  FakeLocationService({required this.latitude, required this.longitude});

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

/// Sentinel coordinates used by the Alice role.
///
/// Open Arctic Ocean, north of the Siberian shelf: far from any populated area,
/// hermetic relay only, so the value is unmistakable in a log.
///
/// The DIGITS matter as much as the place, because the log scanner searches
/// each axis at four and five decimals too
/// (`tooling/e2e/ci/host-needles.sh`, which declares these three pairs and
/// pins the rule): no 4-digit ascending or descending run, no repeated 3-digit
/// group, and an integer part outside 00-59 on both axes so no spelling can
/// equal the seconds field of an iOS log timestamp. The ladder these used to be
/// (`12.345678` and friends) collided with Apple's push daemon in CI run
/// 35311161479. Change one here and change it there, or the lane searches its
/// logs for a value the app never used.
const double aliceFakeLatitude = 78.641977;
const double aliceFakeLongitude = 121.094612;

/// Sentinel coordinates used by the Bob role.
const double bobFakeLatitude = 79.343842;
const double bobFakeLongitude = 117.194008;

/// Sentinel coordinates used by the Carol role.
///
/// Same ocean as Alice + Bob and the same digit discipline, far enough apart
/// that a decoded `kind 25442` content can be matched against a single role at
/// a glance.
const double carolFakeLatitude = 79.586509;
const double carolFakeLongitude = 125.149447;
