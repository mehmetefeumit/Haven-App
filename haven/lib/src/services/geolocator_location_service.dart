/// Production implementation of [LocationService] using the geolocator package.
///
/// This implementation provides high-accuracy location tracking with:
/// - Best accuracy possible for precise location data
/// - Forces Android LocationManager (bypasses Google Play Services for F-Droid)
/// - Frequent updates for real-time tracking
library;

import 'package:geolocator/geolocator.dart' as geo;
import 'package:haven/src/services/location_service.dart';

/// Production location service implementation using geolocator.
///
/// Configuration:
/// - **Android**: Forces LocationManager API (NOT Google Play Services)
/// - **Accuracy**: Best - uses GPS for maximum precision
/// - **Update frequency**: Continuous updates via stream
/// - **User Experience**: Optimized for responsive, accurate location tracking
class GeolocatorLocationService implements LocationService {
  /// Timeout for location requests - balanced for accuracy and UX.
  static const Duration _locationTimeout = Duration(seconds: 30);
  @override
  Future<Position> getCurrentLocation() async {
    // Check if location services are enabled
    final serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw LocationServiceException(
        'Location services are disabled. Please enable location services.',
      );
    }

    // Check permission
    final permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      final requested = await geo.Geolocator.requestPermission();
      if (requested == geo.LocationPermission.denied) {
        throw LocationServiceException('Location permission denied');
      }
      if (requested == geo.LocationPermission.deniedForever) {
        throw LocationServiceException(
          'Location permission denied forever. Please enable in settings.',
        );
      }
    }

    // Get location with best accuracy (default)
    try {
      final geoPosition = await geo.Geolocator.getCurrentPosition(
        forceAndroidLocationManager: true, // Bypass Google Play Services
        timeLimit: _locationTimeout,
      );
      return _convertPosition(geoPosition);
    } on Exception catch (e) {
      // Fallback to last known position if fresh position unavailable
      try {
        final lastPosition = await geo.Geolocator.getLastKnownPosition(
          forceAndroidLocationManager: true,
        );
        if (lastPosition != null) {
          return _convertPosition(lastPosition);
        }
      } on Exception {
        // Ignore error from getLastKnownPosition
      }

      throw LocationServiceException(
        'Failed to get location. '
        'Please ensure location services are enabled.\n'
        'Error: $e',
      );
    }
  }

  @override
  Future<Position> getCurrentLocationFresh() async {
    // Check if location services are enabled
    final serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw LocationServiceException(
        'Location services are disabled. Please enable location services.',
      );
    }

    // Check permission
    final permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      final requested = await geo.Geolocator.requestPermission();
      if (requested == geo.LocationPermission.denied) {
        throw LocationServiceException('Location permission denied');
      }
      if (requested == geo.LocationPermission.deniedForever) {
        throw LocationServiceException(
          'Location permission denied forever. Please enable in settings.',
        );
      }
    }

    // Force a fresh GPS read with best accuracy (default)
    // NO fallback to cached data
    try {
      final geoPosition = await geo.Geolocator.getCurrentPosition(
        forceAndroidLocationManager: true,
        timeLimit: _locationTimeout,
      );
      return _convertPosition(geoPosition);
    } catch (e) {
      throw LocationServiceException(
        'Failed to get fresh location. '
        'Please ensure location services are enabled.\n'
        'Error: $e',
      );
    }
  }

  @override
  Stream<Position> getLocationStream() {
    return geo.Geolocator.getPositionStream(
      locationSettings: geo.AndroidSettings(
        // Using best accuracy (default) for maximum precision
        distanceFilter: 1, // Update when device moves 1+ meter for precision
        forceLocationManager: true, // Bypass Google Play Services
        intervalDuration: const Duration(
          seconds: 1,
        ), // Maximum update frequency
      ),
    ).map(_convertPosition);
  }

  @override
  Future<bool> isLocationServiceEnabled() async {
    return geo.Geolocator.isLocationServiceEnabled();
  }

  @override
  Future<bool> requestPermission() async {
    final permission = await geo.Geolocator.requestPermission();
    return permission == geo.LocationPermission.whileInUse ||
        permission == geo.LocationPermission.always;
  }

  @override
  Future<LocationPermissionStatus> checkPermission() async {
    final permission = await geo.Geolocator.checkPermission();
    return _convertPermissionStatus(permission);
  }

  /// Converts geolocator Position to our Position type.
  Position _convertPosition(geo.Position geoPosition) {
    return Position(
      latitude: geoPosition.latitude,
      longitude: geoPosition.longitude,
      timestamp: geoPosition.timestamp,
      accuracy: geoPosition.accuracy,
      altitude: geoPosition.altitude,
      speed: geoPosition.speed,
      heading: geoPosition.heading,
    );
  }

  /// Converts geolocator permission status to our enum.
  LocationPermissionStatus _convertPermissionStatus(
    geo.LocationPermission permission,
  ) {
    switch (permission) {
      case geo.LocationPermission.denied:
        return LocationPermissionStatus.denied;
      case geo.LocationPermission.deniedForever:
        return LocationPermissionStatus.deniedForever;
      case geo.LocationPermission.whileInUse:
        return LocationPermissionStatus.whileInUse;
      case geo.LocationPermission.always:
        return LocationPermissionStatus.always;
      case geo.LocationPermission.unableToDetermine:
        return LocationPermissionStatus.notDetermined;
    }
  }
}
