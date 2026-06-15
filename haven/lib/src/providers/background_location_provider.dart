/// Provider for the background location sharing toggle and the
/// foreground-service lifecycle that backs it.
///
/// The setting is persisted in [SharedPreferences] (not secure storage)
/// because it is not secret and must be accessible from the background
/// Dart isolate without async initialization overhead.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/background_location_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Callback type for requesting the necessary foreground-service permissions.
///
/// Defined as a typedef so tests can inject a fake without starting the
/// real platform plugin (Phase 5 test seam).
typedef EnsurePermissionsFn = Future<EnsurePermissionsResult> Function();

/// Function type for starting the background foreground service.
///
/// Defined as a typedef so tests can inject a fake in place of
/// [BackgroundLocationManager.startService] without hitting the real
/// Android foreground-service plugin.
typedef StartServiceFn = Future<void> Function({required Function callback});

/// Function type for stopping the background foreground service.
///
/// Defined as a typedef so tests can inject a fake in place of
/// [BackgroundLocationManager.stopService].
typedef StopServiceFn = Future<void> Function();

/// Notifier for the background sharing preference.
///
/// Loads the persisted value on construction (defaulting to `false`)
/// and exposes a setter that writes through to [SharedPreferences].
class BackgroundSharingNotifier extends StateNotifier<bool> {
  /// Creates a [BackgroundSharingNotifier].
  ///
  /// The optional [ensurePermissions] parameter is a test seam: tests can
  /// supply a fake implementation without starting the real platform plugin.
  /// Production callers omit it and receive
  /// [BackgroundLocationManager.ensurePermissions].
  ///
  /// The optional [isAndroid] parameter is a test seam that overrides the
  /// [Platform.isAndroid] check inside [setEnabled]. Tests on non-Android
  /// runners pass `true` to exercise the Android permission-gating branch.
  /// Production callers omit it and receive the real platform value.
  BackgroundSharingNotifier({
    EnsurePermissionsFn? ensurePermissions,
    bool? isAndroid,
  }) : _ensurePermissions =
           ensurePermissions ?? BackgroundLocationManager.ensurePermissions,
       _isAndroid = isAndroid ?? Platform.isAndroid,
       super(false) {
    _load();
  }

  final EnsurePermissionsFn _ensurePermissions;

  /// Whether the current platform is Android.
  ///
  /// Overridable in tests via the constructor parameter.
  final bool _isAndroid;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = prefs.getBool(kBackgroundSharingKey) ?? false;
    } on Object catch (e) {
      debugPrint('[BackgroundSharing] load failed: ${e.runtimeType}');
    }
  }

  /// Enables or disables background location sharing.
  ///
  /// On Android, when enabling, requests the required notification and
  /// battery-optimization permissions first via
  /// [BackgroundLocationManager.ensurePermissions]. Returns the permission
  /// result so the caller can show appropriate UI feedback:
  ///
  /// - [EnsurePermissionsNotificationDenied] → the toggle is kept OFF; the
  ///   caller should show an error and not start the service.
  /// - [EnsurePermissionsBatteryOptDenied] → the toggle is kept ON (soft
  ///   warning); the caller may show an advisory snackbar.
  /// - [EnsurePermissionsGranted] → silent success.
  ///
  /// When disabling, or on iOS, no permission check is performed and
  /// `null` is returned.
  ///
  /// PRECONDITION (compliance): when [enabled] is `true`, the caller MUST first
  /// show and obtain the BACKGROUND prominent disclosure via
  /// `LocationDisclosureController.ensureDisclosed(includeBackground: true)`
  /// and only call this on acceptance. Enabling here triggers the Android
  /// foreground-service permission and the iOS "Always" escalation prompt, so
  /// invoking it without the background disclosure would violate Google Play's
  /// "disclosure before collection" rule. This gate is wired in
  /// `LocationSettingsPage`
  /// (lib/src/pages/settings/location_settings_page.dart); any new caller MUST
  /// do the same.
  Future<EnsurePermissionsResult?> setEnabled({required bool enabled}) async {
    if (enabled && _isAndroid) {
      final result = await _ensurePermissions();
      if (result is EnsurePermissionsNotificationDenied) {
        // Fatal: keep toggle OFF and persist false so a prior true from a
        // previous session doesn't survive to the next launch.
        state = false;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(kBackgroundSharingKey, false);
        } on Object catch (e) {
          debugPrint('[BackgroundSharing] write failed: ${e.runtimeType}');
        }
        return result;
      }
      // EnsurePermissionsGranted or EnsurePermissionsBatteryOptDenied:
      // persist true in both cases but surface the result for UI feedback.
      state = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(kBackgroundSharingKey, true);
      } on Object catch (e) {
        debugPrint('[BackgroundSharing] write failed: ${e.runtimeType}');
      }
      return result;
    }

    // On iOS, when enabling, attempt to escalate to "Always" location
    // permission so the background stream can keep the process alive.
    // Non-blocking: a denial does not revert the toggle.
    if (enabled && Platform.isIOS) {
      try {
        final current = await geo.Geolocator.checkPermission();
        if (current == geo.LocationPermission.whileInUse) {
          await geo.Geolocator.requestPermission();
        }
      } on Object catch (e) {
        debugPrint(
          '[BackgroundSharing] iOS permission escalation failed: '
          '${e.runtimeType}',
        );
      }
    }

    // Disabling (or iOS): unconditional.
    state = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kBackgroundSharingKey, enabled);
    } on Object catch (e) {
      debugPrint('[BackgroundSharing] write failed: ${e.runtimeType}');
    }
    return null;
  }
}

/// Provider exposing whether background location sharing is enabled.
///
/// Defaults to `false` (opt-in). The value is persisted across app restarts.
final backgroundSharingProvider =
    StateNotifierProvider<BackgroundSharingNotifier, bool>((ref) {
      return BackgroundSharingNotifier();
    });

/// Test seam: exposes [Platform.isAndroid] as an overridable provider so that
/// [backgroundServiceLifecycleProvider] can be exercised on non-Android
/// test runners by overriding this provider in a [ProviderScope].
final platformIsAndroidProvider = Provider<bool>((_) => Platform.isAndroid);

/// Production foreground-service function pair.
///
/// Exposed as a Riverpod provider so tests can override start/stop without
/// hitting the real Android foreground-service plugin.
///
/// Each value is a function reference matching [StartServiceFn] and
/// [StopServiceFn] respectively.
final backgroundServiceFunctionsProvider =
    Provider<({StartServiceFn start, StopServiceFn stop})>((_) {
      return (
        start: BackgroundLocationManager.startService,
        stop: BackgroundLocationManager.stopService,
      );
    });

/// Side-effect provider that starts/stops the Android foreground service
/// in response to the toggle and identity state.
///
/// This is the **only** place that starts the service. It must be called
/// while the activity is visible — Android 12+ rejects
/// `FOREGROUND_SERVICE_LOCATION` start requests originating from a
/// non-visible activity (which is what `AppLifecycleState.paused`
/// corresponds to). Watching this provider from the root widget's
/// `build()` ensures the start request is issued from the visible
/// foreground.
///
/// The service then stays running across pause/resume transitions
/// (publishing in the background while the UI is hidden, deferring to
/// the foreground scheduler while the UI is active — see
/// [kForegroundActiveAtMsKey]).
///
/// No-op on iOS (background sharing on iOS uses the geolocator
/// background stream from `map_shell.dart`).
///
/// **Not** `autoDispose`: a transient drop in listeners (hot reload,
/// widget tree rebuild that removes the `ref.watch` momentarily)
/// would otherwise tear down the service and require a re-start that
/// might fall foul of Android 12+ background-start checks if it
/// happens off the main thread or after a pause.
final backgroundServiceLifecycleProvider = Provider<void>((ref) {
  // Read from overridable provider so tests can exercise this on non-Android
  // runners without hitting the real Platform.isAndroid value.
  final isAndroid = ref.watch(platformIsAndroidProvider);
  if (!isAndroid) return;

  final enabled = ref.watch(backgroundSharingProvider);
  final identityAsync = ref.watch(identityProvider);

  // Resolve the injectable service functions (start/stop).
  final fns = ref.watch(backgroundServiceFunctionsProvider);

  // Tear down the service when the provider is disposed (app shut
  // down, identity removed, toggle flipped off, etc.).
  ref.onDispose(() {
    unawaited(fns.stop());
  });

  // Fix 5: Do not change service state during a transient identity reload.
  // ref.invalidate(identityProvider) briefly produces AsyncLoading before
  // resolving — treating loading as null would stop/restart the service on
  // every invalidation, wasting battery and risking Android 12+ background-
  // start rejection if the restart happens off the visible-activity window.
  if (identityAsync.isLoading) return;

  // Error state (identity corrupt / keyring failure) → stop the service.
  // The user must re-authenticate; publishing with a broken identity would
  // silently fail or advance MLS epochs incorrectly.
  final identity = identityAsync.valueOrNull;

  if (!enabled || identity == null) {
    // Toggle off or no identity → stop any running service.
    unawaited(fns.stop());
    return;
  }

  // Start the service from the visible activity. Idempotent if the
  // service is already running.
  unawaited(fns.start(callback: backgroundCallback));
});
