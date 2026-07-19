/// Location state providers.
///
/// Provides reactive access to device location with automatic
/// stream management and cleanup.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/location_service.dart';

/// Stream provider for continuous location updates.
///
/// Automatically manages the location stream subscription and cleanup.
/// Emits new positions when the device moves.
///
/// Watches [backgroundSharingProvider] so the single geolocator stream is
/// torn down and re-created with the matching iOS `AppleSettings` whenever
/// the user's background-sharing intent changes (geolocator supports only
/// ONE stream; settings can only change via a full rebuild — see
/// `GeolocatorLocationService`). The toggle lives in foreground-only UI, so
/// an ENABLING rebuild always starts the background-capable CLLocationManager
/// session while foregrounded, as iOS requires. A disable-while-paused
/// rebuild only ever downgrades (removes the keep-alive), which is safe.
/// Note: `BackgroundSharingNotifier` rebuilds start at `false` until the
/// persisted value loads — a momentary extra rebuild while foregrounded,
/// harmless by design (fail-closed toward no background capability).
///
/// On the disabled rebuild the service's cached stream position is cleared,
/// so plaintext coordinates never outlive the consent that produced them.
///
/// Usage:
/// ```dart
/// final locationAsync = ref.watch(locationStreamProvider);
/// return locationAsync.when(
///   data: (position) => Text('${position.latitude}, ${position.longitude}'),
///   loading: () => const CircularProgressIndicator(),
///   error: (_, __) => Text('Location unavailable'),
/// );
/// ```
final locationStreamProvider = StreamProvider<Position>((ref) {
  final service = ref.watch(locationServiceProvider);
  final backgroundSharingEnabled = ref.watch(backgroundSharingProvider);
  if (service is GeolocatorLocationService) {
    if (!backgroundSharingEnabled) {
      service.clearCachedPosition();
    }
    return service.getLocationStream(
      backgroundSharingEnabled: backgroundSharingEnabled,
    );
  }
  return service.getLocationStream();
});
