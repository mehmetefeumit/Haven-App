/// Manages the background location sharing service.
///
/// Provides static methods to start, stop, and query the foreground service
/// (Android) and coordinates cross-isolate state via `SharedPreferences`.
/// The actual background work runs in `BackgroundLocationTaskHandler`.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/locale_provider.dart'
    show resolveAppLocalizations;
import 'package:haven/src/services/background_catchup_worker.dart';
import 'package:haven/src/services/ios_background_catchup.dart';
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
  ///
  /// Holds the RESOLVED text, not a message key, so a language change reads as
  /// a genuine difference and repaints rather than being deduped away.
  static String? _lastNotificationText;

  /// Initializes the foreground task configuration.
  ///
  /// Safe to call multiple times. Should be called early (from `main`
  /// or the lifecycle provider) so the channel exists by the time
  /// [startService] is called.
  ///
  /// [channelName] and [channelDescription] are what Android shows for this
  /// channel in the system settings app, so they are user-visible copy and must
  /// arrive already localized — this class has no widget tree and cannot
  /// resolve them (same rule as [startService]'s `notificationText`).
  ///
  /// **Note**: Android locks a notification channel's IMPORTANCE at creation;
  /// bumping the channel id is the only way to change it in shipped builds. Its
  /// name and description carry no such lock — `createNotificationChannel`
  /// updates both for an existing id — so re-running `init()` with a new
  /// language re-labels the channel in place, and the user sees the change on
  /// the next launch after switching languages.
  static void init({
    required String channelName,
    required String channelDescription,
  }) {
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
        channelName: channelName,
        channelDescription: channelDescription,
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
        // M7-E: restart the FGS after a device reboot, paired with the
        // RebootReceiver enabled in AndroidManifest.xml (guard 14c/14e pin
        // both). Only resurrects a service that was RUNNING at shutdown —
        // background sharing toggled off means no service existed, so user
        // opt-out is preserved across reboots.
        autoRunOnBoot: true,
        // `allowWakeLock` is deliberately ABSENT, so the plugin's default
        // (true) stands and its permanent PARTIAL_WAKE_LOCK is held for the
        // whole session. It is the only wake source for the no-fix watchdog
        // (indoors on a GNSS-only device nothing else wakes the isolate) and
        // for the "armed but never delivered" recovery, so setting it false
        // here stops background sharing silently rather than saving battery.
        // The scoped `Haven:publish` lock (PublishWakeLock.kt) is additive
        // until that wake source exists; guard check (1) and
        // `fgs_plugin_wake_lock_policy_test.dart` pin the absence.
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

  /// Last recorded answer to "does Android still battery-optimize Haven?".
  ///
  /// A FALLBACK only — the live answer comes from
  /// [refreshBatteryOptimizationDenied]. Persisted so a failed probe degrades
  /// to the last known truth instead of silently claiming the exemption is
  /// held. Absent key → `false` (never asked, or not Android).
  static Future<bool> isBatteryOptimizationDenied() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getBool(kBatteryOptimizationDeniedKey) ?? false;
    } on Object catch (e) {
      debugPrint(
        '[BackgroundManager] battery-opt read failed: ${e.runtimeType}',
      );
      return false;
    }
  }

  /// Records whether Android still applies battery optimization to Haven.
  ///
  /// Called with the answer the OS just gave, so the advisory the user sees
  /// is never a guess: [ensurePermissions] returning
  /// [EnsurePermissionsBatteryOptDenied] writes `true`, a granted exemption
  /// writes `false`.
  static Future<void> recordBatteryOptimizationDenied({
    required bool denied,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kBatteryOptimizationDeniedKey, denied);
    } on Object catch (e) {
      debugPrint(
        '[BackgroundManager] battery-opt write failed: ${e.runtimeType}',
      );
    }
  }

  /// Asks Android whether it still battery-optimizes Haven, and records the
  /// answer.
  ///
  /// The persisted flag alone is a WRITE-ONLY cache: the exemption can be
  /// granted or revoked from Android Settings, or by an OEM battery manager,
  /// without ever passing through Haven — so a page that trusted the flag
  /// would keep asserting "battery optimization is still on" forever after a
  /// grant made outside the app. This is the live read; the flag it refreshes
  /// exists only so a failed probe has something truthful to fall back to.
  ///
  /// Android-only by construction: the caller
  /// (`batteryOptimizationDeniedProvider`) gates on the platform, so the
  /// plugin channel is never touched elsewhere. Off Android the plugin answers
  /// `true` (exempt) without a channel call, which is why that gate — not this
  /// method — is what keeps the persisted flag from being overwritten there.
  ///
  /// [probeExemption] is a test seam for the failure branch: the real probe
  /// cannot be made to fail on a test host, and the branch decides whether a
  /// transient channel error silently retracts a warning the OS never
  /// withdrew.
  static Future<bool> refreshBatteryOptimizationDenied({
    @visibleForTesting Future<bool> Function()? probeExemption,
  }) async {
    try {
      final exempt = await (probeExemption == null
          ? FlutterForegroundTask.isIgnoringBatteryOptimizations
          : probeExemption());
      await recordBatteryOptimizationDenied(denied: !exempt);
      return !exempt;
    } on Object catch (e) {
      debugPrint(
        '[BackgroundManager] battery-opt probe failed: ${e.runtimeType}',
      );
      return isBatteryOptimizationDenied();
    }
  }

  /// Opens Android's battery-optimization settings screen, then re-probes.
  ///
  /// Returns the refreshed "still optimized" answer so the caller can update
  /// its UI without a second read. `openIgnoreBatteryOptimizationSettings`
  /// only navigates — the user may grant, deny, or simply come back — so the
  /// exemption is always re-read rather than assumed.
  static Future<bool> openBatteryOptimizationSettings() async {
    try {
      await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
    } on Object catch (e) {
      debugPrint(
        '[BackgroundManager] battery-opt settings failed: ${e.runtimeType}',
      );
    }
    return refreshBatteryOptimizationDenied();
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
  ///
  /// [notificationText] must already be localized. The service isolate has no
  /// widget tree and therefore no localizations, so every string this class
  /// shows is resolved by the caller in the UI isolate (see
  /// `appLocalizationsProvider`) and passed in.
  static Future<void> startService({
    required Function callback,
    required String notificationText,
  }) async {
    if (!_initialized) {
      // `main()` configures the channel in the user's chosen language long
      // before the app can reach this, so only an entrypoint that never ran it
      // (an integration-test target) lands here — and it still needs a channel,
      // because the plugin cannot start a service without one. The device
      // locale is the best this layer can see: it has no container, and so no
      // access to an in-app language override.
      final l10n = resolveAppLocalizations(null);
      init(
        channelName: l10n.fgsChannelName,
        channelDescription: l10n.fgsChannelDescription,
      );
    }

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
      notificationText: notificationText,
      callback: callback,
    );

    switch (result) {
      case ServiceRequestSuccess():
        debugPrint('[BackgroundManager] Service started');
        // Seed the dedup field so the first updateNotification with the same
        // start-time text becomes a true no-op and avoids a redundant redraw.
        _lastNotificationText = notificationText;
      case ServiceRequestFailure(:final error):
        debugPrint('[BackgroundManager] Start failed: ${error.runtimeType}');
    }
  }

  /// Updates the running service's notification text without restarting.
  ///
  /// Used to differentiate the notification copy when the app is in the
  /// foreground vs. backgrounded (`fgsNotificationOpen` vs.
  /// `fgsNotificationSharing`). Silently no-ops if the service is not running
  /// or if [text] is identical to the last text sent (dedup to prevent OEM
  /// notification-drawer chime and reflow animation on rapid calls).
  ///
  /// [text] must already be localized, for the reason given on [startService].
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

  /// Sends a presence-only [signal] to the foreground-service task.
  ///
  /// The string IS the whole message ([kForegroundPausedSignal] /
  /// [kForegroundResumedSignal]) and it never leaves the process: the task
  /// re-reads identity, consent and foreground ownership from its own gates,
  /// so a signal prompts work rather than authorising it.
  ///
  /// Silently dropped when the service is not running — the plugin checks that
  /// itself (`ForegroundService.sendData`), and a signal to a dead task has
  /// nothing to prompt.
  static void signalTask(String signal) =>
      FlutterForegroundTask.sendDataToTask(signal);

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
  ///
  /// A timestamp in the FUTURE is treated as stale, not as active. A backward
  /// clock jump (NTP correction, manual date change, timezone-less RTC on
  /// boot) makes the age negative, which a bare `age < threshold` test reads
  /// as "the foreground just wrote this" — muting the FGS's publish cycle for
  /// as long as it takes the clock to catch up, which can be hours.
  ///
  /// The tolerance is deliberately ZERO — no "a few ms ahead is fine" slack —
  /// because there is no source of spurious futures to absorb: the writer
  /// ([markForegroundActive]) and this reader read the SAME wall clock, and
  /// the write happens-before the read, so a negative age can only mean the
  /// clock genuinely stepped backwards in between. And a spurious `false`
  /// would be cheap even if one could occur: it cannot let the background
  /// isolate steal a live foreground session, because the reclaim path gates
  /// on its own fail-closed two-probe liveness check
  /// (`_attemptSessionReclaim`) rather than on this flag.
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
      if (age < Duration.zero) return false;
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

  /// Idempotent teardown of **all** background scheduling for Haven.
  ///
  /// Must be called from BOTH:
  ///   - [BackgroundSharingNotifier.setEnabled]`(enabled: false)` — so that
  ///     a user who toggles sharing OFF receives an immediate guarantee that
  ///     no further background activity occurs, even from a previously-queued
  ///     OS wakeup.
  ///   - [IdentityNotifier.deleteIdentity] — so that account deletion also
  ///     cancels every scheduled wake.
  ///
  /// Stops the Android foreground service, clears the cross-isolate
  /// SharedPreferences coordination keys, cancels the Android WorkManager
  /// periodic task (M7-C), and cancels the iOS SLC monitoring and
  /// BGAppRefreshTask requests (M7-D).
  ///
  /// This is **best-effort and idempotent**: each step is wrapped in its own
  /// try/catch so a failure in one step does not prevent the others from
  /// running. Only the [runtimeType] of any error is logged (never the
  /// error message itself, which could contain internal state). The caller
  /// need not await an error-free completion — a partial teardown is still
  /// better than no teardown.
  static Future<void> disableBackgroundScheduling() async {
    // --- Step 1: Stop the Android foreground service. ---
    // Idempotent — stopService() already guards with isRunningService check.
    try {
      await stopService();
    } on Object catch (e) {
      debugPrint(
        '[BackgroundManager] disableBackgroundScheduling: '
        'stopService failed: ${e.runtimeType}',
      );
    }

    // --- Step 2: Clear the cross-isolate coordination keys. ---
    // kBackgroundIdleKey: signals the FGS publish isolate is idle. Once the
    //   service is stopped (step 1) this key is stale; clearing it ensures a
    //   new session cannot inherit a stale "idle=false" that would cause
    //   `isBackgroundIdle()` to return false even though no service is running.
    // kForegroundActiveAtMsKey: signals the foreground UI isolate is active.
    //   Clearing it ensures a queued OS waker cannot see a stale "active"
    //   timestamp and mistakenly skip its intent re-check (it won't reach FFI
    //   anyway because the CatchupService chokepoint gates on the persisted
    //   kBackgroundSharingKey, but belt-and-suspenders).
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.remove(kBackgroundIdleKey),
        prefs.remove(kForegroundActiveAtMsKey),
      ]);
    } on Object catch (e) {
      debugPrint(
        '[BackgroundManager] disableBackgroundScheduling: '
        'prefs clear failed: ${e.runtimeType}',
      );
    }

    // --- M7-C: Android WorkManager cancel ---
    // Cancels any queued WorkManager periodic task so a previously-scheduled
    // OS wake cannot fire after the user has disabled background sharing.
    // cancelBackgroundCatchup() guards with Platform.isAndroid internally
    // and calls Workmanager().cancelAll() unconditionally of the
    // backgroundCatchupEnabled flag — a stale task from a flag-ON build must
    // still be cancellable after a flag rollback. Best-effort (caller's
    // try/catch absorbs any thrown error).
    try {
      await cancelBackgroundCatchup();
    } on Object catch (e) {
      debugPrint(
        '[BackgroundManager] disableBackgroundScheduling: '
        'WorkManager cancel failed: ${e.runtimeType}',
      );
    }

    // --- M7-D (iOS SLC + BGTaskScheduler) ---
    // Calls the Swift teardown channels: HavenSLCHandler.stopMonitoring()
    // via "stopSLC" and BGTaskScheduler.cancelAllTaskRequests() via
    // "cancelAllBGTasks". Best-effort (caller's try/catch absorbs thrown
    // errors). No-ops on non-iOS platforms (cancelNativeSchedulers() guards
    // with Platform.isIOS internally).
    try {
      await cancelNativeSchedulers();
    } on Object catch (e) {
      debugPrint(
        '[BackgroundManager] disableBackgroundScheduling: '
        'iOS scheduler cancel failed: ${e.runtimeType}',
      );
    }

    debugPrint('[BackgroundManager] disableBackgroundScheduling: complete');
  }

  /// Clears the background-publish HISTORY timestamps left behind after an
  /// identity is deleted: [kBackgroundLastPublishMsKey] (wall-clock time of
  /// the deleted identity's last location transmission) and
  /// [kBackgroundSessionReclaimAtMsKey] (last MLS session-reclaim attempt).
  ///
  /// Deliberately separate from [disableBackgroundScheduling], which owns
  /// only the cross-isolate COORDINATION keys ([kBackgroundIdleKey] /
  /// [kForegroundActiveAtMsKey]) — those are reset on every disable
  /// (including a mere background-sharing toggle-off) because a resumed
  /// session needs them neutral. These two are a record of what the DELETED
  /// identity did and must not survive account deletion, but must NOT be
  /// cleared by a toggle-off (the values remain meaningful if the user
  /// re-enables sharing under the SAME identity).
  ///
  /// Throws on a prefs failure; the delete path treats that as best-effort so
  /// it never blocks the primary objective of removing the identity's secret
  /// key.
  static Future<void> clearPublishHistoryOnIdentityDelete() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.remove(kBackgroundLastPublishMsKey),
      prefs.remove(kBackgroundSessionReclaimAtMsKey),
      // The battery-optimization verdict is a cached OS answer, not identity
      // data, but it is cleared here rather than kept: it is only ever shown
      // while background sharing is on, the next identity re-probes it live on
      // its first settings visit, and leaving it would greet a fresh identity
      // with a warning inherited from the deleted one.
      prefs.remove(kBatteryOptimizationDeniedKey),
    ]);
  }

  /// Whether it is appropriate for a background CATCH-UP wake (M7) to run.
  ///
  /// True only when NO other MLS writer is active — the foreground UI isolate
  /// is not active AND the FGS publish isolate is idle — so a background sweep
  /// does not wastefully race them. This is a LIVENESS/BATTERY gate ONLY; it is
  /// NOT the fork-safety mechanism (the persisted staged-commit marker checked
  /// inside `has_pending_commit` is, and it holds even if this flag misfires).
  ///
  /// Fails CONSERVATIVE: on a read error it returns `false` (skip the wake) —
  /// the foreground path catches up losslessly on the next resume.
  static Future<bool> isBackgroundIdle() async {
    try {
      if (await isForegroundActive()) return false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      // The FGS writes `false` while mid-publish and `true` when idle; an
      // unset key (FGS never ran) is treated as idle.
      return prefs.getBool(kBackgroundIdleKey) ?? true;
    } on Object catch (e) {
      debugPrint(
        '[BackgroundManager] isBackgroundIdle read failed: ${e.runtimeType}',
      );
      return false;
    }
  }
}
