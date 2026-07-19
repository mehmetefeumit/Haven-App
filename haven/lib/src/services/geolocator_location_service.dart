/// Production implementation of [LocationService] using the geolocator package.
///
/// This implementation provides high-accuracy location tracking with:
/// - Best accuracy possible for precise location data
/// - Forces Android LocationManager (bypasses Google Play Services for F-Droid)
/// - Frequent updates for real-time tracking
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/location_service.dart';

/// Abstraction for geolocator static methods.
///
/// This allows for dependency injection in tests.
abstract class GeolocatorWrapper {
  /// Checks if location services are enabled.
  Future<bool> isLocationServiceEnabled();

  /// Checks current location permission.
  Future<geo.LocationPermission> checkPermission();

  /// Requests location permission.
  Future<geo.LocationPermission> requestPermission();

  /// Gets the current position.
  Future<geo.Position> getCurrentPosition({
    required geo.LocationSettings locationSettings,
  });

  /// Gets the last known position.
  Future<geo.Position?> getLastKnownPosition();

  /// Gets a stream of position updates.
  Stream<geo.Position> getPositionStream({
    required geo.LocationSettings locationSettings,
  });
}

/// Production implementation that delegates to Geolocator static methods.
class DefaultGeolocatorWrapper implements GeolocatorWrapper {
  /// Creates a new [DefaultGeolocatorWrapper].
  const DefaultGeolocatorWrapper();

  @override
  Future<bool> isLocationServiceEnabled() {
    return geo.Geolocator.isLocationServiceEnabled();
  }

  @override
  Future<geo.LocationPermission> checkPermission() {
    return geo.Geolocator.checkPermission();
  }

  @override
  Future<geo.LocationPermission> requestPermission() {
    return geo.Geolocator.requestPermission();
  }

  @override
  Future<geo.Position> getCurrentPosition({
    required geo.LocationSettings locationSettings,
  }) {
    return geo.Geolocator.getCurrentPosition(
      locationSettings: locationSettings,
    );
  }

  @override
  Future<geo.Position?> getLastKnownPosition() {
    return geo.Geolocator.getLastKnownPosition();
  }

  @override
  Stream<geo.Position> getPositionStream({
    required geo.LocationSettings locationSettings,
  }) {
    return geo.Geolocator.getPositionStream(locationSettings: locationSettings);
  }
}

/// Production location service implementation using geolocator.
///
/// Configuration:
/// - **Android**: Forces LocationManager API (NOT Google Play Services)
/// - **Accuracy**: Best - uses GPS for maximum precision
/// - **Update frequency**: Continuous updates via stream
/// - **User Experience**: Optimized for responsive, accurate location tracking
///
/// ## Single unified stream (iOS background invariant)
///
/// geolocator supports exactly ONE active position stream: the Dart side
/// caches it (`GeolocatorApple._positionStream`) and silently returns the
/// cached stream — old settings and all — to any later `getPositionStream`
/// call, while the native side rejects a second concurrent listen outright.
/// Therefore this service exposes a single [getLocationStream] whose iOS
/// `AppleSettings` are chosen by the caller-supplied
/// `backgroundSharingEnabled` intent at subscription time. There must never
/// be a second stream-returning API: a "background variant" stream would
/// silently inherit the foreground session's settings (the exact defect that
/// broke iOS background publishing). CI pins this invariant
/// (`scripts/ci/check_ios_background_publish.sh`).
class GeolocatorLocationService implements LocationService {
  /// Creates a new [GeolocatorLocationService].
  ///
  /// Optionally accepts a [GeolocatorWrapper] for testing. The optional
  /// [isIOS] flag is a test seam overriding the [Platform.isIOS] check that
  /// selects [geo.AppleSettings] vs [geo.AndroidSettings]; production callers
  /// omit it and receive the real platform value.
  GeolocatorLocationService({GeolocatorWrapper? geolocator, bool? isIOS})
    : _geolocator = geolocator ?? const DefaultGeolocatorWrapper(),
      _isIOS = isIOS ?? Platform.isIOS;

  final GeolocatorWrapper _geolocator;

  /// Whether this device is running iOS.
  ///
  /// Drives the [geo.AppleSettings] vs [geo.AndroidSettings] selection.
  /// Passing [geo.AndroidSettings] on iOS is a latent bug: the
  /// `forceLocationManager` flag is meaningless to CLLocationManager and the
  /// wrong settings class can degrade the cold-start fix the location
  /// publisher depends on.
  final bool _isIOS;

  /// Timeout for location requests - balanced for accuracy and UX.
  static const Duration _locationTimeout = Duration(seconds: 30);

  /// Latest position delivered by the unified stream ([getLocationStream]).
  ///
  /// Served by [getCurrentLocation] while fresher than
  /// [kStreamPositionMaxAge] so publish cycles never depend on the one-shot
  /// `getCurrentPosition` path while the app is backgrounded on iOS — the
  /// plugin's one-time CLLocationManager hard-codes
  /// `allowsBackgroundLocationUpdates = NO`, so a backgrounded one-shot can
  /// only stall for [_locationTimeout] and fall back anyway. Cleared via
  /// [clearCachedPosition] on logout and on background-sharing opt-out.
  Position? _lastStreamPosition;

  /// Whether the app UI is currently foregrounded.
  ///
  /// A plain synchronous in-memory seam set by `map_shell.dart`'s
  /// `didChangeAppLifecycleState` (paused → false, resumed → true; the
  /// transient `inactive`/`hidden` states are deliberately not distinct for
  /// this purpose). Defaults to `true` so a freshly constructed instance
  /// (cold start, tests, the Android FGS isolate) behaves as foreground.
  /// Only consulted by [getCurrentLocation]'s iOS branch to avoid a doomed
  /// backgrounded one-shot.
  bool _foregroundActive = true;

  /// Sets the foreground-active hint consulted by [getCurrentLocation].
  // ignore: avoid_setters_without_getters
  set foregroundActive(bool value) => _foregroundActive = value;

  /// Clears the cached stream position.
  ///
  /// Called on logout (`deleteIdentity`) and when background sharing is
  /// disabled, so plaintext coordinates never outlive the session intent
  /// that produced them (mirrors `LocationSharingService.wipeAll`'s
  /// cache-wiping posture).
  void clearCachedPosition() => _lastStreamPosition = null;

  /// Builds the [geo.LocationSettings] for a one-shot position read,
  /// platform-correct: [geo.AppleSettings] on iOS, [geo.AndroidSettings]
  /// (forcing the platform LocationManager to bypass Google Play Services)
  /// elsewhere. Both use best accuracy and the cold-fix [_locationTimeout].
  geo.LocationSettings _currentPositionSettings() {
    if (_isIOS) {
      // Accuracy defaults to LocationAccuracy.best.
      return geo.AppleSettings(timeLimit: _locationTimeout);
    }
    return geo.AndroidSettings(
      forceLocationManager: true, // Bypass Google Play Services
      timeLimit: _locationTimeout,
    );
  }

  /// Builds the [geo.LocationSettings] for the single continuous stream.
  ///
  /// Mirrors [_currentPositionSettings] platform handling, both with a 1 m
  /// distance filter for responsive, precise tracking.
  ///
  /// On iOS the background-capable flags are a pure function of the user's
  /// background-sharing intent, NOT of lifecycle state:
  /// - `backgroundSharingEnabled: true` → `allowBackgroundLocationUpdates`
  ///   and `showBackgroundLocationIndicator` are both `true`, so the
  ///   CLLocationManager session (necessarily started while foregrounded —
  ///   the toggle lives in foreground-only UI) keeps the process alive and
  ///   publishing when the app is backgrounded, with the indicator giving
  ///   the user continuous transparency. When-In-Use authorization
  ///   suffices for this foreground-started continuation; "Always" is only
  ///   needed for the receive-only SLC relaunch path.
  /// - `backgroundSharingEnabled: false` → both flags are EXPLICITLY
  ///   `false`. `AppleSettings` defaults `allowBackgroundLocationUpdates`
  ///   to `true`, which before this fix silently kept every user's GPS and
  ///   app process alive in the background regardless of consent; the
  ///   explicit `false` makes opt-out users suspend normally.
  ///
  /// `pauseLocationUpdatesAutomatically` is unconditionally `false`: an
  /// auto-paused session stops delivering and (for a When-In-Use app) may
  /// never resume until relaunch.
  geo.LocationSettings _streamSettings({
    required bool backgroundSharingEnabled,
  }) {
    if (_isIOS) {
      // Accuracy defaults to LocationAccuracy.best.
      return geo.AppleSettings(
        distanceFilter: 1, // Update when device moves 1+ meter for precision
        allowBackgroundLocationUpdates: backgroundSharingEnabled,
        showBackgroundLocationIndicator: backgroundSharingEnabled,
        // Explicit (despite matching the plugin default) because an
        // auto-paused session is a liveness hazard — see the doc above —
        // and the CI guard pins this exact assignment.
        // ignore: avoid_redundant_argument_values
        pauseLocationUpdatesAutomatically: false,
      );
    }
    return geo.AndroidSettings(
      distanceFilter: 1, // Update when device moves 1+ meter for precision
      forceLocationManager: true, // Bypass Google Play Services
      intervalDuration: const Duration(seconds: 1), // Maximum update frequency
    );
  }

  @override
  Future<Position> getCurrentLocation() async {
    // Serve the unified stream's latest fix while fresh — measured against
    // the GPS fix time (`Position.timestamp`), not a Dart-side clock. This
    // is the ONLY publish-path GPS source that works while backgrounded on
    // iOS (see [_lastStreamPosition]).
    final cached = _lastStreamPosition;
    if (cached != null &&
        DateTime.now().difference(cached.timestamp) <= kStreamPositionMaxAge) {
      return cached;
    }

    // Backgrounded on iOS with no fresh stream fix: the one-shot below
    // cannot deliver (its CLLocationManager never enables background
    // updates) — skip straight to the last known fix instead of stalling
    // for the 30 s timeout. Presence-only logging; never log coordinates.
    if (_isIOS && !_foregroundActive) {
      try {
        final lastPosition = await _geolocator.getLastKnownPosition();
        if (lastPosition != null) {
          return _convertPosition(lastPosition);
        }
      } on Exception catch (e) {
        debugPrint(
          '[Location] backgrounded last-known lookup failed: ${e.runtimeType}',
        );
        // Fall through to the foreground chain as a final attempt.
      }
    }

    // Check if location services are enabled
    final serviceEnabled = await _geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw LocationServiceException(
        'Location services are disabled. Please enable location services.',
      );
    }

    // Check permission
    final permission = await _geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      final requested = await _geolocator.requestPermission();
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
      final geoPosition = await _geolocator.getCurrentPosition(
        locationSettings: _currentPositionSettings(),
      );
      return _convertPosition(geoPosition);
    } on Exception catch (e) {
      // Fallback to last known position if fresh position unavailable
      try {
        final lastPosition = await _geolocator.getLastKnownPosition();
        if (lastPosition != null) {
          return _convertPosition(lastPosition);
        }
      } on Exception {
        // Ignore error from getLastKnownPosition
      }

      debugPrint('Failed to get location: ${e.runtimeType}');
      throw LocationServiceException(
        'Failed to get location. '
        'Please ensure location services are enabled.',
      );
    }
  }

  @override
  Future<Position> getCurrentLocationFresh() async {
    // Check if location services are enabled
    final serviceEnabled = await _geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw LocationServiceException(
        'Location services are disabled. Please enable location services.',
      );
    }

    // Check permission
    final permission = await _geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      final requested = await _geolocator.requestPermission();
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
      final geoPosition = await _geolocator.getCurrentPosition(
        locationSettings: _currentPositionSettings(),
      );
      return _convertPosition(geoPosition);
    } on Object catch (e) {
      debugPrint('Failed to get fresh location: ${e.runtimeType}');
      throw LocationServiceException(
        'Failed to get fresh location. '
        'Please ensure location services are enabled.',
      );
    }
  }

  /// Returns the single continuous position stream.
  ///
  /// [backgroundSharingEnabled] selects the iOS background-capable
  /// `AppleSettings` (see [_streamSettings]); it is ignored on Android,
  /// where background publishing is the foreground service's job. Adding an
  /// optional named parameter to the parameterless
  /// [LocationService.getLocationStream] contract is a legal override —
  /// interface-typed callers are unaffected; `locationStreamProvider`
  /// passes the toggle state through the concrete type.
  ///
  /// Every emission is teed into [_lastStreamPosition] so
  /// [getCurrentLocation] can serve a warm fix without a one-shot request.
  @override
  Stream<Position> getLocationStream({bool backgroundSharingEnabled = false}) {
    return _geolocator
        .getPositionStream(
          locationSettings: _streamSettings(
            backgroundSharingEnabled: backgroundSharingEnabled,
          ),
        )
        .map(_convertPosition)
        .map((position) {
          _lastStreamPosition = position;
          return position;
        });
  }

  @override
  Future<bool> isLocationServiceEnabled() async {
    return _geolocator.isLocationServiceEnabled();
  }

  @override
  Future<bool> requestPermission() async {
    final permission = await _geolocator.requestPermission();
    return permission == geo.LocationPermission.whileInUse ||
        permission == geo.LocationPermission.always;
  }

  @override
  Future<LocationPermissionStatus> checkPermission() async {
    final permission = await _geolocator.checkPermission();
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
