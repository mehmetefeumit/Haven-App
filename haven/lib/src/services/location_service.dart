/// Abstract interface for location services.
///
/// Provides a platform-agnostic API for accessing device location.
/// This abstraction allows for:
/// - Easy testing with mock implementations
/// - Platform-specific implementations
/// - Clean separation of concerns
///
/// Implementations:
/// - GeolocatorLocationService - Production implementation using geolocator
library;

/// Exception thrown when location operations fail.
class LocationServiceException implements Exception {
  /// Creates a [LocationServiceException] with the given message.
  LocationServiceException(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => 'LocationServiceException: $message';
}

/// Position data from GPS.
///
/// This is a simplified version containing only the fields we need.
/// Privacy-sensitive fields (altitude, speed, heading) will be stripped
/// before sending to Rust core.
class Position {
  /// Creates a new [Position].
  const Position({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracy,
    this.altitude,
    this.speed,
    this.heading,
  });

  /// The latitude of this position in degrees.
  /// Normalized to the interval -90.0 to +90.0.
  final double latitude;

  /// The longitude of the position in degrees.
  /// Normalized to the interval -180.0 to +180.0.
  final double longitude;

  /// The time at which this position was determined.
  final DateTime timestamp;

  /// The estimated horizontal accuracy of the position in meters.
  ///
  /// This field will NOT be sent to the Rust core for privacy.
  final double? accuracy;

  /// The altitude of the device in meters.
  /// Privacy-sensitive, not sent to server.
  final double? altitude;

  /// The speed of the device in meters/second.
  /// Privacy-sensitive, not sent to server.
  final double? speed;

  /// The heading of the device in degrees.
  /// Privacy-sensitive, not sent to server.
  final double? heading;

  @override
  String toString() =>
      'Position(lat: $latitude, lon: $longitude, time: $timestamp)';
}

/// Abstract interface for location services.
abstract class LocationService {
  /// Gets the current location once.
  ///
  /// Throws [LocationServiceException] if:
  /// - Permission is denied
  /// - Location services are disabled
  /// - Unable to determine location
  Future<Position> getCurrentLocation();

  /// Gets the current location with a fresh GPS read (no cached fallback).
  ///
  /// This method forces a fresh location read from the GPS hardware
  /// without falling back to cached/last known position. Useful for
  /// periodic updates where you want to ensure you're getting the
  /// latest position, not stale data.
  ///
  /// Throws [LocationServiceException] if:
  /// - Permission is denied
  /// - Location services are disabled
  /// - Unable to get a fresh location fix
  Future<Position> getCurrentLocationFresh();

  /// Gets a stream of location updates.
  ///
  /// The stream will emit new positions when:
  /// - The device moves a significant distance
  /// - Time interval elapses (platform-dependent)
  ///
  /// Throws [LocationServiceException] if:
  /// - Permission is denied
  /// - Location services are disabled
  Stream<Position> getLocationStream();

  /// Checks if location services are enabled.
  Future<bool> isLocationServiceEnabled();

  /// Requests location permission.
  ///
  /// Returns `true` if permission is granted.
  Future<bool> requestPermission();

  /// Checks current location permission status.
  Future<LocationPermissionStatus> checkPermission();
}

/// Location permission status.
enum LocationPermissionStatus {
  /// Permission has not been requested yet.
  notDetermined,

  /// Permission is denied.
  denied,

  /// Permission is denied forever (user selected "Don't ask again").
  deniedForever,

  /// Permission is granted while the app is in use.
  whileInUse,

  /// Permission is granted always (including background).
  always,
}
