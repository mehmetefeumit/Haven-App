/// iOS-native background catch-up channel handler (M7-D).
///
/// ## Purpose
///
/// Registers the MethodChannel handler that native SLC and BGTask wakes use to
/// trigger a receive-only catch-up sweep from Swift. Also provides
/// [cancelNativeSchedulers] for Dart to stop SLC monitoring and cancel
/// BGAppRefreshTask requests (wired into
/// `BackgroundLocationManager.disableBackgroundScheduling()` at the M7-D
/// extension point).
///
/// ## Channel names
///
/// - `haven.app/ios_background_catchup` — Swift → Dart ("runCatchup" method).
///   Shared by both `HavenSLCHandler` and `HavenBGTaskHandler`; both call the
///   same Dart method so one handler registration covers both wake paths.
/// - `haven.app/ios_slc_teardown` — Dart → Swift, "stopSLC" (HavenSLCHandler).
/// - `haven.app/ios_bgtask_teardown` — Dart → Swift, "cancelAllBGTasks"
///   (HavenBGTaskHandler).
///   SLC and BGTask teardown use SEPARATE channels on purpose: iOS keeps only
///   ONE `setMethodCallHandler` per channel name, so a shared teardown channel
///   would let whichever handler registered last silently overwrite the other's
///   handler — leaving one scheduler uncancellable on disable.
///
/// ## LIVE since M7-E
///
/// The channel handler is registered unconditionally (it must be live to reply
/// to any early native trigger). The `runCatchup` handler re-checks:
///   1. Whether `backgroundCatchupEnabled` is true (compile-time const —
///      `true` since M7-E; a rolled-back build exits here with no FFI/relay
///      activity).
///   2. Whether background sharing is enabled (user's persisted intent) — also
///      checked inside `CatchupService.runCatchup(isBackgroundWake: true)`.
///
/// The native side submits BGTasks / starts SLC monitoring only when its
/// `isEnabled()` predicate holds (`HavenBGTaskHandler` / `HavenSLCHandler`:
/// bg-sharing UserDefaults key AND the mirror key below both true). Arming
/// happens at launch and — because the launch-time arm runs before Dart
/// writes the mirror — again in `applicationDidEnterBackground` (A3), which
/// closes the one-launch lag after an upgrade or a same-session enable.
///
/// ## Sweep budget (D3 — deliberately NOT raised to the Android worker's 25)
///
/// This handler calls `runCatchup(isBackgroundWake: true)` with the DEFAULT
/// `maxDurationSecs` (20). The SLC background window grants ~23 s inside a
/// ~30 s budget and the Dart engine is already running when the channel
/// fires (no bootstrap cost), so 20 s of sweep + dispatch overhead fits with
/// margin; raising it would risk iOS expiration-handler races for zero gain.
/// The Android WorkManager worker uses 25 (cold wake is its only receive
/// opportunity) — see `background_catchup_worker.dart`.
///
/// ## Main()-race handling
///
/// The Dart engine starts asynchronously; there are ~10 awaits in `main()`
/// before the app is fully initialised. To avoid losing a native trigger that
/// fires before the handler is registered:
///
///   - `HavenSLCHandler` fires from the CLLocationManager delegate, which runs
///     on the main thread after the engine is running (not at launch). The
///     23-second background task window provides time for the handler to
///     register. If the reply is `FlutterMethodNotImplemented`, Swift falls
///     back to scheduling a BGAppRefreshTask.
///   - `HavenBGTaskHandler` handles `FlutterMethodNotImplemented` by calling
///     `setTaskCompleted(success: true)` and scheduling the next BGTask.
///
/// The Dart-ready ping approach (sending a "ready" method call from Dart after
/// registration) was considered but rejected: both Swift handlers already
/// handle `FlutterMethodNotImplemented` gracefully by either falling back to
/// BGTask or completing the task without penalty, so a ping is redundant.
///
/// ## Background-catchup mirror key
///
/// At startup, `writeCatchupEnabledMirror()` writes the compile-time
/// `backgroundCatchupEnabled` constant to SharedPreferences under
/// `flutter.background_catchup_enabled`. Swift reads this key before starting
/// SLC monitoring or scheduling a BGTask. Since M7-E the value written is
/// `true`, so the native side arms once the user's background-sharing toggle
/// is also on; a rollback build rewrites `false` on its first launch, which
/// re-inerts the native side without a Swift change.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/services/catchup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Channel constants (match Swift handler names exactly)
// ---------------------------------------------------------------------------

/// MethodChannel name for native → Dart "runCatchup" triggers.
///
/// Shared by HavenSLCHandler and HavenBGTaskHandler on the Swift side.
const String _kCatchupChannelName = 'haven.app/ios_background_catchup';

/// MethodChannel names for Dart → native scheduler teardown.
///
/// SLC and BGTask each own a SEPARATE teardown channel: iOS keeps only ONE
/// method-call handler per channel name, so a shared channel would let one
/// handler's registration silently overwrite the other's.
const String _kSlcTeardownChannelName = 'haven.app/ios_slc_teardown';
const String _kBgTaskTeardownChannelName = 'haven.app/ios_bgtask_teardown';

/// SharedPreferences key used by Dart to mirror the compile-time
/// `backgroundCatchupEnabled` constant to the Swift side.
///
/// SharedPreferences stores values under the `flutter.` prefix in
/// UserDefaults on iOS, so this Dart key `background_catchup_enabled`
/// is read by Swift as `flutter.background_catchup_enabled`.
const String _kBgCatchupEnabledMirrorKey = 'background_catchup_enabled';

// ---------------------------------------------------------------------------
// Startup mirror write
// ---------------------------------------------------------------------------

/// Writes the compile-time `backgroundCatchupEnabled` constant to
/// SharedPreferences so the Swift native side can read it before the Dart
/// handler is registered.
///
/// Must be called from `main()` as early as possible, before any native wake
/// could fire. On non-iOS platforms this is a no-op.
///
/// ## Why this is needed
///
/// The Swift handlers (`HavenSLCHandler`, `HavenBGTaskHandler`) gate all
/// scheduling on two UserDefaults keys:
///   1. `flutter.haven.background_sharing` — the user's persisted intent.
///   2. `flutter.background_catchup_enabled` — mirrors this Dart constant.
///
/// Without (2), a fresh install that has background sharing enabled from a
/// previous session could start scheduling wakes even before the compile-time
/// flag is active. Writing the mirror on every launch ensures the Swift side
/// always reflects the current build's intent.
///
/// The `flutter.` prefix is added automatically by SharedPreferences on iOS,
/// so we write `background_catchup_enabled` here and Swift reads
/// `flutter.background_catchup_enabled`.
Future<void> writeCatchupEnabledMirror() async {
  if (!Platform.isIOS) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBgCatchupEnabledMirrorKey, backgroundCatchupEnabled);
  } on Object catch (e) {
    // Non-fatal: the Swift side defaults to false when the key is absent,
    // so a failure here keeps the native side safely inert.
    debugPrint(
      '[iOSCatchup] writeCatchupEnabledMirror failed: ${e.runtimeType}',
    );
  }
}

// ---------------------------------------------------------------------------
// Channel handler registration
// ---------------------------------------------------------------------------

/// Registers the MethodChannel handler for native iOS background catch-up
/// triggers ("runCatchup" from HavenSLCHandler / HavenBGTaskHandler).
///
/// Must be called from `main()` before `runApp`. On non-iOS platforms this is
/// a no-op (the channels are iOS-only).
///
/// The [catchupService] parameter is injectable for tests so the handler can
/// be verified without the FFI bridge or SharedPreferences setup.
///
/// ## Gate chain (LIVE since M7-E)
///
/// The handler re-checks `backgroundCatchupEnabled` as its first gate: on a
/// rolled-back build (flag `false`) it returns immediately with no FFI or
/// relay activity even if native code somehow invokes the channel. The second
/// gate is `CatchupService.runCatchup(isBackgroundWake: true)`, which
/// re-checks the user's persisted sharing intent (C3 chokepoint) — so a wake
/// after opt-out still cannot reach the relay. Two independent gates,
/// belt-and-suspenders.
void registerIosBackgroundCatchupHandler({
  required CatchupService catchupService,
}) {
  if (!Platform.isIOS) return;

  const MethodChannel(_kCatchupChannelName).setMethodCallHandler((call) async {
    if (call.method != 'runCatchup') {
      throw PlatformException(
        code: 'UNIMPLEMENTED',
        message: 'Unknown method: ${call.method}',
      );
    }

    // Gate 1: compile-time flag (true since M7-E; rollback gate).
    // This is the first thing checked so a false flag exits immediately with
    // no SharedPreferences read, no FFI call, no relay activity.
    if (!backgroundCatchupEnabled) {
      debugPrint(
        '[iOSCatchup] runCatchup: backgroundCatchupEnabled=false — no-op',
      );
      return null; // null reply = success (no error)
    }

    // Gate 2: run the catch-up sweep (re-checks isBackgroundSharingEnabled
    // inside CatchupService as the C3 chokepoint).
    //
    // This never throws into the reply — CatchupService.runCatchup is
    // documented best-effort and always returns CatchupResult (never throws).
    await catchupService.runCatchup(isBackgroundWake: true);
    return null;
  });
}

// ---------------------------------------------------------------------------
// Scheduler teardown (Dart → Native)
// ---------------------------------------------------------------------------

/// Sends teardown calls to the Swift native side to stop SLC monitoring and
/// cancel all pending BGAppRefreshTask requests.
///
/// Called from `BackgroundLocationManager.disableBackgroundScheduling()` at
/// the M7-D extension point. On non-iOS platforms this is a no-op.
///
/// Best-effort: each call is wrapped in its own try/catch so a failure on one
/// channel does not prevent the other from being cancelled.
Future<void> cancelNativeSchedulers() async {
  if (!Platform.isIOS) return;

  // SLC and BGTask each have their OWN teardown channel (see channel-name
  // docs above) so both handlers are reachable.
  const slcTeardown = MethodChannel(_kSlcTeardownChannelName);
  const bgTaskTeardown = MethodChannel(_kBgTaskTeardownChannelName);

  // Stop SLC monitoring on the Swift side (HavenSLCHandler listens for
  // "stopSLC" on its own channel).
  try {
    await slcTeardown.invokeMethod<void>('stopSLC');
    debugPrint('[iOSCatchup] stopSLC sent');
  } on Object catch (e) {
    // Channel may not be ready (e.g. called before engine starts, or on a
    // device where CLLocationManager is not available).
    debugPrint('[iOSCatchup] stopSLC failed: ${e.runtimeType}');
  }

  // Cancel all pending BGAppRefreshTask requests (HavenBGTaskHandler listens
  // for "cancelAllBGTasks" on its own channel).
  try {
    await bgTaskTeardown.invokeMethod<void>('cancelAllBGTasks');
    debugPrint('[iOSCatchup] cancelAllBGTasks sent');
  } on Object catch (e) {
    debugPrint('[iOSCatchup] cancelAllBGTasks failed: ${e.runtimeType}');
  }
}
