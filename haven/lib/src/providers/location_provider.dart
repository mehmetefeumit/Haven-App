/// Location state providers.
///
/// Provides reactive access to device location with automatic
/// stream management and cleanup.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/location_service.dart';

/// Whether the platform location stream must KEEP running across a pause.
///
/// | background sharing | iOS | Android |
/// |---|---|---|
/// | on  | KEEP — the session IS the keep-alive | release |
/// | off | release | release |
///
/// True only on the iOS background-sharing branch: that CLLocationManager
/// session is the only thing keeping the process executable, so releasing it
/// at pause would end publishing outright. Everywhere else the platform
/// subscription is released — on Android the foreground service owns
/// background publishing and the UI isolate's 1 Hz / 1 m registration is pure
/// drain, and with sharing off the app is genuinely going idle.
///
/// Called directly by `MapShell._onPaused`. Deliberately a top-level function
/// rather than a third `MapShell` static: a static of the same name would
/// shadow this one inside the class, so a delegate would need a second name
/// for one rule — the duplication this single definition exists to avoid.
bool shouldKeepLocationStreamWhilePaused({
  required bool backgroundSharingEnabled,
  required bool isIOS,
}) => backgroundSharingEnabled && isIOS;

/// Test seam exposing [Platform.isIOS] as an overridable provider.
///
/// The keep rule above is platform-dependent, and both of its arms must be
/// exercised on a host test runner. `GeolocatorLocationService` has the same
/// seam as a constructor flag; `MapShell`'s statics keep their explicit
/// `isIOS:` parameter.
final isIOSProvider = Provider<bool>((_) => Platform.isIOS);

/// Whether the app UI is currently foregrounded.
///
/// Written by `MapShell._setForegroundActive` — the one place that already
/// mirrors the lifecycle transition into the location service — and read by
/// [locationStreamProvider] to refuse starting a location session from the
/// background.
///
/// The initial value is DERIVED from the binding rather than defaulting to a
/// literal: on a background launch (an iOS SLC/region relaunch, which builds
/// providers before the first frame) a literal `true` would let the provider
/// open a background-capable session that iOS refuses outright — failing OPEN
/// on the invariant that no such session is ever started from the background.
/// A not-yet-dispatched state (`null`) maps to `true`, which is the ordinary
/// foreground launch; `inactive` is the transient the OS sandwiches around
/// `resumed` and is not treated as backgrounded.
final appForegroundProvider = StateProvider<bool>((_) {
  return switch (WidgetsBinding.instance.lifecycleState) {
    AppLifecycleState.resumed || AppLifecycleState.inactive || null => true,
    _ => false,
  };
});

/// Stream provider for continuous location updates.
///
/// Automatically manages the location stream subscription and cleanup.
/// Emits new positions when the device moves.
///
/// Watches [backgroundSharingProvider] so the single position stream is torn
/// down and re-created with the matching intent whenever the user's
/// background-sharing choice changes: on iOS that intent becomes the native
/// session's `allowsBackgroundLocationUpdates`, on Android geolocator supports
/// only ONE stream and its settings can only change via a full rebuild (see
/// `GeolocatorLocationService`). The toggle lives in foreground-only UI, so an
/// ENABLING rebuild always starts the background-capable CLLocationManager
/// session while foregrounded, as iOS requires — and the native owner refuses
/// such a start from the background outright. A disable-while-paused
/// rebuild only ever downgrades (removes the keep-alive), which is safe.
/// Note: `BackgroundSharingNotifier` rebuilds start at `false` until the
/// persisted value loads — a momentary extra rebuild while foregrounded,
/// harmless by design (fail-closed toward no background capability).
///
/// On the disabled rebuild the service's cached stream position is cleared,
/// so plaintext coordinates never outlive the consent that produced them.
///
/// ## What a rebuild can and cannot do
///
/// A rebuild is NOT the pause/resume mechanism. A watched-provider write
/// cancels the running subscription synchronously but SCHEDULES the rebuild
/// inside a frame, and Flutter disables frames before the lifecycle observers
/// run — so a release that rides a rebuild happens at RESUME, not at pause.
/// The pause-time release is a direct, synchronous
/// `GeolocatorLocationService.suspendStream()` call from
/// `MapShell._onPaused`; the restart is `resumeStream()` from `_onResumed`.
/// All this provider does about lifecycle is refuse to START anything while
/// the app is not foregrounded.
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

  // Deliberate `ref.read`: reading without watching is what keeps the RUNNING
  // foreground build independent of the foreground state. A `watch` out here
  // would cancel the kept iOS session on the pause write and rebuild it at
  // the resume frame — the one restart iOS refuses to honour.
  if (!ref.read(appForegroundProvider)) {
    // Built while not foregrounded: a background launch (an iOS SLC/region
    // relaunch before the first frame) or a forced flush. Never START a
    // session here. The resume write rebuilds this provider — this branch is
    // the only place that watches the foreground state.
    ref.watch(appForegroundProvider);
    // Per build, and never `Stream.empty()`: an empty stream COMPLETES, and a
    // completed position stream is an outage to every listener; a controller
    // shared across builds would throw "Stream has already been listened to"
    // on the second build and surface as an error instead.
    final paused = StreamController<Position>();
    ref.onDispose(paused.close);
    return paused.stream;
  }

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
