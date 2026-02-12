/// Service providers for dependency injection.
///
/// These providers expose singleton instances of services throughout the app.
/// Override these in tests with mock implementations using ProviderScope.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_identity_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/relay_service.dart';

/// Provides the identity service singleton.
///
/// Uses [NostrIdentityService] in production.
/// Override with a mock in tests:
/// ```dart
/// ProviderScope(
///   overrides: [
///     identityServiceProvider.overrideWithValue(mockIdentityService),
///   ],
///   child: MyWidget(),
/// )
/// ```
final identityServiceProvider = Provider<IdentityService>((ref) {
  return NostrIdentityService();
});

/// Provides the location service singleton.
///
/// Uses [GeolocatorLocationService] in production.
final locationServiceProvider = Provider<LocationService>((ref) {
  return GeolocatorLocationService();
});

/// Provides the circle service singleton.
///
/// Uses [NostrCircleService] in production.
final circleServiceProvider = Provider<CircleService>((ref) {
  return NostrCircleService();
});

/// Provides the relay service singleton.
///
/// Uses [NostrRelayService] in production.
final relayServiceProvider = Provider<RelayService>((ref) {
  return NostrRelayService();
});

/// Provides the location sharing service singleton.
///
/// Uses [LocationSharingService] for encrypt-publish-fetch-decrypt pipeline.
final locationSharingServiceProvider = Provider<LocationSharingService>((ref) {
  return LocationSharingService(
    circleService: ref.read(circleServiceProvider),
    relayService: ref.read(relayServiceProvider),
  );
});
