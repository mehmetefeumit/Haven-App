/// Manages the background location sharing service.
///
/// Provides static methods to start, stop, and query the foreground service
/// (Android) and coordinates cross-isolate state via `SharedPreferences`.
/// The actual background work runs in `BackgroundLocationTaskHandler`.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:haven/src/constants/location.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Result returned by [BackgroundLocationManager.ensurePermissions].
///
/// Callers use this to decide whether to proceed with enabling the
/// background service and what (if any) feedback to show the user.
sealed class EnsurePermissionsResult {
  const EnsurePermissionsResult();
}

/// All required permissions are granted; the service may start.
class EnsurePermissionsGranted extends EnsurePermissionsResult {
  /// Creates an [EnsurePermissionsGranted] result.
  const EnsurePermissionsGranted();
}

/// The user denied the `POST_NOTIFICATIONS` permission.
///
/// This is fatal for foreground-service UX on Android 13+: without the
/// notification the service is invisible and many OEMs will kill it.
/// The caller should revert the toggle to OFF.
class EnsurePermissionsNotificationDenied extends EnsurePermissionsResult {
  /// Creates an [EnsurePermissionsNotificationDenied] result.
  const EnsurePermissionsNotificationDenied();
}

/// The user declined to disable battery optimization.
///
/// The foreground service can still start but may be throttled by Doze
/// mode on older OEMs. This is a soft warning — the caller should keep
/// the toggle ON but show an advisory message.
class EnsurePermissionsBatteryOptDenied extends EnsurePermissionsResult {
  /// Creates an [EnsurePermissionsBatteryOptDenied] result.
  const EnsurePermissionsBatteryOptDenied();
}

/// Manages the background location sharing foreground service.
///
/// On Android, this wraps [FlutterForegroundTask] to create a persistent
/// foreground service with `TYPE_LOCATION`. On iOS, the service is not
/// started — background location relies on the geolocator background
/// stream keeping the process alive (see `map_shell.dart`).
///
/// ## Lifecycle model
///
/// The service is started from a visible activity (via
/// `backgroundServiceLifecycleProvider` in the UI layer) when the user
/// has enabled the background-sharing toggle and an identity is loaded.
/// **It is not started from `didChangeAppLifecycleState(paused)`** —
/// Android 12+ enforces that `FOREGROUND_SERVICE_LOCATION` services
/// must be started while the app has a visible activity, which is
/// already past by the time `paused` fires (== `Activity.onStop()`).
///
/// The service then runs continuously while the toggle is on. The
/// background task handler short-circuits its `onRepeatEvent` while
/// the foreground UI isolate owns publishing (see [kForegroundActiveAtMsKey]
/// in `lib/src/constants/location.dart`).
class BackgroundLocationManager {
  BackgroundLocationManager._();

  /// Whether the foreground task configuration has been initialised.
  static bool _initialized = false;

  /// Last notification text sent to [FlutterForegroundTask.updateService].
  ///
  /// Used to short-circuit redundant `updateService` calls that would
  /// cause the notification to redraw (audible chime / animation on some OEMs).
  /// Reset to `null` by [stopService] so the next start re-applies text.
  static String? _lastNotificationText;

  /// Initializes the foreground task configuration.
  ///
  /// Safe to call multiple times. Should be called early (from `main`
  /// or the lifecycle provider) so the channel exists by the time
  /// [startService] is called.
  ///
  /// **Note**: Android does **not** allow modifying notification channel
  /// importance after creation. Bumping the channel id is the only way
  /// to change importance in shipped builds.
  static void init() {
    if (_initialized) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        // Bumped from `haven_location_v2` to force re-creation of the
        // notification channel on existing installs. Android locks channel
        // importance at creation time — a new ID is the only way to change
        // it. v3 moves from DEFAULT to LOW importance: the notification
        // remains visible in the drawer but produces no sound and no
        // heads-up popup, which is correct behaviour for a long-running
        // status notification. DEFAULT was causing it to compete with
        // high-priority alerts on some OEMs.
        channelId: 'haven_location_v3',
        channelName: 'Location Sharing',
        channelDescription:
            'Keeps Haven sharing your encrypted location in the background.',
        // channelImportance and priority default to LOW in 9.2.x, which is
        // correct: visible in the notification drawer, no sound, no heads-up.
        // Hide notification content from the lock screen — only the
        // app name shows. Protects against shoulder-surfing the
        // foreground service text on a locked device.
        visibility: NotificationVisibility.VISIBILITY_SECRET,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(
          kBackgroundRepeatInterval.inMilliseconds,
        ),
      ),
    );

    _initialized = true;
  }

  /// Ensures notification and battery-optimization permissions are granted.
  ///
  /// Must be called before [startService]. On Android 13+ the
  /// `POST_NOTIFICATIONS` runtime permission is required for the
  /// foreground-service notification to appear in the notification drawer.
  ///
  /// Returns [EnsurePermissionsGranted] when all permissions are satisfied,
  /// [EnsurePermissionsNotificationDenied] when the user denied the
  /// notification permission (fatal — caller should revert the toggle),
  /// or [EnsurePermissionsBatteryOptDenied] when the user declined to
  /// disable battery optimization (soft warning — service still starts).
  static Future<EnsurePermissionsResult> ensurePermissions() async {
    // 1. Notification permission (Android 13+ / API 33).
    var notifPerm = await FlutterForegroundTask.checkNotificationPermission();
    if (notifPerm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
      notifPerm = await FlutterForegroundTask.checkNotificationPermission();
    }
    if (notifPerm != NotificationPermission.granted) {
      return const EnsurePermissionsNotificationDenied();
    }

    // 2. Battery optimization exemption (soft — decline is common).
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        return const EnsurePermissionsBatteryOptDenied();
      }
    }

    return const EnsurePermissionsGranted();
  }

  /// Starts the background location sharing service.
  ///
  /// On Android, creates a foreground service with a persistent
  /// notification. The [callback] must be the top-level
  /// `backgroundCallback` function registered in `main.dart`.
  ///
  /// **Must be called from a visible activity** (Android 12+
  /// background-start restriction for `FOREGROUND_SERVICE_LOCATION`).
  /// Callers should call [ensurePermissions] before this method so the
  /// notification is visible and the service survives Doze mode.
  static Future<void> startService({required Function callback}) async {
    init();

    final isRunning = await FlutterForegroundTask.isRunningService;
    if (isRunning) {
      debugPrint('[BackgroundManager] Service already running');
      return;
    }

    final result = await FlutterForegroundTask.startService(
      // 4831: stable 4-digit id chosen to avoid collisions with the
      // default value (1) used by many plugin examples and other FGS-based
      // packages that may share a process notification namespace.
      serviceId: 4831,
      serviceTypes: [ForegroundServiceTypes.location],
      notificationTitle: 'Haven',
      notificationText:
          'Haven is sending and receiving location information',
      callback: callback,
    );

    switch (result) {
      case ServiceRequestSuccess():
        debugPrint('[BackgroundManager] Service started');
        // Seed the dedup field so the first updateNotification with the same
        // start-time text becomes a true no-op and avoids a redundant redraw.
        _lastNotificationText =
            'Haven is sending and receiving location information';
      case ServiceRequestFailure(:final error):
        debugPrint('[BackgroundManager] Start failed: ${error.runtimeType}');
    }
  }

  /// Updates the running service's notification text without restarting.
  ///
  /// Used to differentiate the notification copy when the app is in the
  /// foreground vs. backgrounded (e.g. "Haven is open" vs. "Sharing
  /// your location"). Silently no-ops if the service is not running or
  /// if [text] is identical to the last text sent (dedup to prevent OEM
  /// notification-drawer chime and reflow animation on rapid calls).
  static Future<void> updateNotification({required String text}) async {
    if (_lastNotificationText == text) return; // dedup
    final isRunning = await FlutterForegroundTask.isRunningService;
    if (!isRunning) return;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Haven',
        notificationText: text,
      );
      _lastNotificationText = text; // only update after success
    } on Object catch (e) {
      debugPrint('[BackgroundManager] Update failed: ${e.runtimeType}');
    }
  }

  /// Stops the background location sharing service.
  static Future<void> stopService() async {
    final isRunning = await FlutterForegroundTask.isRunningService;
    if (!isRunning) return;

    final result = await FlutterForegroundTask.stopService();

    switch (result) {
      case ServiceRequestSuccess():
        debugPrint('[BackgroundManager] Service stopped');
        // Reset so the next startService + updateNotification pair sends
        // a fresh updateService call even if the text is the same.
        _lastNotificationText = null;
      case ServiceRequestFailure(:final error):
        debugPrint('[BackgroundManager] Stop failed: ${error.runtimeType}');
    }
  }

  /// Whether the foreground service is currently running.
  static Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  /// Reads the last background publish timestamp from shared preferences.
  ///
  /// Returns `null` if no background publish has occurred this session.
  static Future<DateTime?> readLastPublishTime() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(kBackgroundLastPublishMsKey);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Writes the last publish timestamp to shared preferences.
  static Future<void> writeLastPublishTime(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      kBackgroundLastPublishMsKey,
      time.millisecondsSinceEpoch,
    );
  }

  /// Whether the user has enabled background sharing.
  static Future<bool> isBackgroundSharingEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kBackgroundSharingKey) ?? false;
  }

  /// Marks the foreground UI isolate as active or inactive.
  ///
  /// When [active] is `true`, writes the current millisecond timestamp to
  /// [kForegroundActiveAtMsKey]. While a recent timestamp is present, the
  /// background task handler skips its publish cycle to preserve the MLS
  /// single-writer invariant.
  ///
  /// When [active] is `false`, writes `0` to signal a deliberate handoff.
  /// This is the "clean pause" path — OOM/force-stop leaves whatever
  /// timestamp was last written, which [isForegroundActive] will detect
  /// as stale after `2 * kBackgroundRepeatInterval`.
  static Future<void> markForegroundActive({required bool active}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      kForegroundActiveAtMsKey,
      active ? DateTime.now().millisecondsSinceEpoch : 0,
    );
  }

  /// Returns `true` if the foreground UI isolate is considered active.
  ///
  /// Reads [kForegroundActiveAtMsKey] from [SharedPreferences] and applies
  /// a staleness check: the foreground is treated as active only when the
  /// stored timestamp is non-zero AND was written within the last
  /// `2 * kBackgroundRepeatInterval`.
  ///
  /// This prevents a stuck "foreground active" state when the process is
  /// killed (OOM, force-stop) without the clean-pause write of `0` —
  /// after `2 * kBackgroundRepeatInterval` the background isolate will
  /// resume publishing.
  static Future<bool> isForegroundActive() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final ts = prefs.getInt(kForegroundActiveAtMsKey);
      if (ts == null || ts == 0) return false;
      final stalenessThreshold =
          kBackgroundRepeatInterval * 2; // 2 * kBackgroundRepeatInterval
      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(ts),
      );
      return age < stalenessThreshold;
    } on Object catch (e) {
      debugPrint(
        '[BackgroundManager] isForegroundActive read failed: ${e.runtimeType}',
      );
      // On read failure, assume not active so the background can proceed
      // rather than stalling indefinitely.
      return false;
    }
  }
}
