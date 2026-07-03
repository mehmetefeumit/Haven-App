/// Android WorkManager periodic-task registration and the top-level
/// `callbackDispatcher` entry-point for the M7-C background catch-up floor.
///
/// ## Architecture (read before editing)
///
/// WorkManager schedules a PeriodicTask that fires at most every ~15 min
/// (the Android minimum). Each wake spins up a **new** FlutterEngine /
/// Dart runtime. The three safeguards that prevent MDK forking are:
///
///   1. **Durable-intent re-check (C2):** the FIRST executable step in
///      `callbackDispatcher` reads `kBackgroundSharingKey`. If false →
///      clean no-op; zero FFI / relay activity.
///   2. **FGS fast-path bail (battery only):** if the foreground service is
///      running we skip the sweep to avoid a boot-cost Rust runtime for
///      work the FGS already covers. This is a BATTERY optimization — it
///      is NOT the fork-safety mechanism. The Rust `WRITER_LOCK` (M7-B) is.
///   3. **`CatchupService` chokepoint (C3):** `runCatchup(isBackground
///      Wake:true)` re-checks the sharing flag again inside Dart before
///      any FFI call.
///
/// ## SHIPPED INERT
///
/// [registerBackgroundCatchup] early-returns when
/// `backgroundCatchupEnabled == false` (compile-time const in
/// `live_sync_provider.dart`). With the flag OFF:
///   - Nothing registers a WorkManager task.
///   - The Android `RebootReceiver` stays `android:enabled="false"`.
///   - CI (fresh install, bg-sharing OFF) does zero background work.
///
/// Flipping to `true` is the M7-E step, after device validation passes.
///
/// ## On-device validation required (cannot be asserted in flutter test)
///
///   - Writer-exclusion TOCTOU proof: overlapped FGS-restart + worker wake
///     → assert zero MDK `Failed` entries, zero epoch divergence.
///   - No-network-after-disable: enable → background → observe relay REQ →
///     disable → assert zero further REQ (network capture).
///   - Reboot: enabled-then-reboot → FGS restarts; disabled → no-op.
///   - `MissingPluginException` absent (registrant order correct).
///   - RebootReceiver fires (no `tools:node="replace"` strip).
library;

// dart: imports come before package: imports (directives_ordering).
// DartPluginRegistrant lives in dart:ui — it registers all method-channel
// plugin implementations in the headless isolate so SharedPreferences,
// flutter_foreground_task, etc. are accessible.
import 'dart:io' show Platform;
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

// ---------------------------------------------------------------------------
// Public task constants
// ---------------------------------------------------------------------------

/// Unique name / task-name for the periodic catch-up WorkManager task.
///
/// A single constant serves as both the `uniqueName` (de-duplication key)
/// and the `taskName` (value passed to the [BackgroundTaskHandler] callback).
const String kBackgroundCatchupTaskName = 'haven.background_catchup';

// ---------------------------------------------------------------------------
// Testable inner logic
// ---------------------------------------------------------------------------

/// Inner logic of the WorkManager task, factored out so it can be unit-tested
/// without a real WorkManager runtime.
///
/// Parameters are injectable fakes for tests:
///
/// - `isBackgroundSharingEnabled`: reads `kBackgroundSharingKey` from
///   SharedPreferences. Tests inject a synchronous stub.
/// - `isRunningService`: reads `FlutterForegroundTask.isRunningService`.
///   Tests inject a stub that avoids the platform channel.
/// - `runCatchup`: the actual sweep. Tests inject a recording stub.
///
/// Returns `true` on success (WorkManager will not reschedule on success),
/// `false` if the catch-up threw (WorkManager retries based on back-off
/// policy — for a periodic task this effectively means "wait for the next
/// scheduled window").
///
/// The three exit paths, in order:
///
/// 1. **Sharing disabled** → return `true` (clean no-op; do NOT return false
///    — that signals "retry", which is wrong when the user has opted out).
/// 2. **FGS alive** → return `true` (battery fast-path; the FGS covers
///    receive).
/// 3. **Run catch-up** → return `true` on success, `false` on throw.
Future<bool> runBackgroundCatchupTask({
  required Future<bool> Function() isBackgroundSharingEnabled,
  required Future<bool> Function() isRunningService,
  required Future<void> Function() runCatchup,
}) async {
  // Step 1 (C2): durable-intent re-check.
  // Read kBackgroundSharingKey from SharedPreferences. If false → hard
  // no-op. This is executed AFTER the binding / plugin registrant are
  // initialized (see callbackDispatcher), so SharedPreferences is accessible.
  try {
    final enabled = await isBackgroundSharingEnabled();
    if (!enabled) {
      return true; // clean no-op; no relay or FFI activity
    }
  } on Object {
    // Fail-safe: treat unknown as disabled so a corrupt SharedPreferences
    // cannot accidentally enable background relay activity after opt-out.
    return true;
  }

  // Step 2: FGS alive → skip (battery fast-path, NOT the fork-safety mech).
  // The Rust WRITER_LOCK (M7-B) is the actual exclusion mechanism.
  try {
    final fgsRunning = await isRunningService();
    if (fgsRunning) {
      return true; // FGS covers receive; no work needed here
    }
  } on Object {
    // Cannot read FGS state — proceed conservatively (let the sweep try;
    // the WRITER_LOCK will serialize it safely with any concurrent FGS).
  }

  // Step 3: Run the catch-up sweep.
  try {
    await runCatchup();
    return true;
  } on Object {
    // Signal WorkManager to apply back-off / retry at next window.
    return false;
  }
}

// ---------------------------------------------------------------------------
// callbackDispatcher — WorkManager entry-point
// ---------------------------------------------------------------------------

/// Top-level WorkManager entry-point. Must be annotated with
/// `@pragma('vm:entry-point')` so the Dart VM retains it after tree-shaking.
///
/// **Order is critical** (addresses constraint 2(a) from the plan):
///
///   1. `WidgetsFlutterBinding.ensureInitialized()` — must be FIRST; without
///      it `DartPluginRegistrant.ensureInitialized()` panics on some engines.
///   2. `DartPluginRegistrant.ensureInitialized()` — registers all plugins
///      (including `shared_preferences`) so platform channels are reachable.
///      This MUST precede any platform-channel call. Doing it inside
///      `executeTask` (which the workmanager plugin itself calls) is too late
///      — some channel calls fire during `MethodChannel.setMethodCallHandler`
///      setup before the task body runs.
///   3. Read `kBackgroundSharingKey` (intent re-check) and `isRunningService`
///      via [runBackgroundCatchupTask].
///   4. `Workmanager().executeTask(...)` — bridges the Dart task body back
///      to WorkManager's native side to signal completion.
///
/// Steps 1–2 happen BEFORE `executeTask` so the SharedPreferences channel
/// and flutter_foreground_task channel are ready by the time the task body
/// runs.
@pragma('vm:entry-point')
void callbackDispatcher() {
  // (1) Binding first — always.
  WidgetsFlutterBinding.ensureInitialized();
  // (2) Plugin registrant second — before ANY platform-channel call.
  DartPluginRegistrant.ensureInitialized();

  // (3+4) Execute the task body.
  Workmanager().executeTask((taskName, inputData) async {
    return runBackgroundCatchupTask(
      isBackgroundSharingEnabled: () async {
        final prefs = await SharedPreferences.getInstance();
        return prefs.getBool(kBackgroundSharingKey) ?? false;
      },
      isRunningService: () => FlutterForegroundTask.isRunningService,
      runCatchup: _runCatchupViaProviders,
    );
  });
}

/// Boots a minimal provider graph and runs the catch-up sweep.
///
/// Separated from [callbackDispatcher] so tests can inject their own
/// `runCatchup` stub into [runBackgroundCatchupTask] without triggering the
/// full FFI + Riverpod initialization path.
///
/// This is called only from the live WorkManager entry-point, so it is
/// intentionally not covered by unit tests (those test
/// [runBackgroundCatchupTask] with stubs). Device/CI integration tests cover
/// the full path.
///
/// See the M7-E milestone for the real implementation.
Future<void> _runCatchupViaProviders() async {
  // INERT stub — unreachable while backgroundCatchupEnabled == false because
  // registerBackgroundCatchup() never registers the WorkManager task, so
  // callbackDispatcher never runs. The fork/privacy-relevant GATING
  // (intent re-check, FGS-alive fast-path) lives in runBackgroundCatchupTask
  // and IS unit-tested; only this actual-sweep call is deferred.
  //
  // M7-E real implementation (device/CI-validated — see
  // docs/M7_BACKGROUND_SHARING_PLAN.md "M7-E enable-time steps"): the
  // WorkManager isolate does NOT run main(), so it must bootstrap the bridge
  // itself before it can resolve catchupServiceProvider — a bare
  // ProviderContainer() is NOT sufficient. Mirror main()'s init:
  //   await RustLib.init();                                   // FFI bridge
  //   final dataDir = await const PathProviderDataDirectory()
  //       .getDataDirectory();                                // circles.db path
  //   final container = ProviderContainer(/* same overrides main() uses */);
  //   try {
  //     await container.read(catchupServiceProvider)
  //         .runCatchup(isBackgroundWake: true, maxDurationSecs: 25);
  //   } finally {
  //     container.dispose();
  //   }
  // This whole path (RustLib.init + keyring + SQLCipher open in a WorkManager
  // background isolate) is only exercisable on a device/CI, which is why it is
  // stubbed here and validated at flag-flip time, in lockstep with M7-E.
}

// ---------------------------------------------------------------------------
// Registration / cancellation (foreground-side API)
// ---------------------------------------------------------------------------

/// Registers the WorkManager periodic catch-up task.
///
/// **Early-returns without registering anything when
/// `backgroundCatchupEnabled == false`** (the compile-time flag from
/// `live_sync_provider.dart`). This is the primary inertness gate: with the
/// flag off, calling this function from the FGS enable path does nothing.
///
/// When the flag is true (M7-E rollout):
///   - Calls `Workmanager().initialize(callbackDispatcher)` to register the
///     Dart entry-point with the native side.
///   - Calls `Workmanager().registerPeriodicTask` with:
///     - `uniqueName` = [kBackgroundCatchupTaskName] (de-duplicated by WM)
///     - `frequency` = 15 min (Android OS minimum; actual cadence ≥ 15 min)
///     - `constraints` = network connected + battery not low
///     - `existingWorkPolicy` = [ExistingPeriodicWorkPolicy.keep] so a
///       running task is not cancelled when the user re-enables sharing
///       after a toggle.
///
/// Safe to call multiple times (WorkManager deduplicates by `uniqueName`
/// with the `keep` policy). Must only be called on Android (guarded by
/// `Platform.isAndroid` internally).
Future<void> registerBackgroundCatchup() async {
  // Primary inertness gate: do NOTHING while the flag is off.
  // Tree-shakes the entire registration path in flag-OFF release builds.
  if (!backgroundCatchupEnabled) return;

  if (!Platform.isAndroid) return;

  await Workmanager().initialize(callbackDispatcher);

  await Workmanager().registerPeriodicTask(
    kBackgroundCatchupTaskName,
    kBackgroundCatchupTaskName,
    // 15 min is the Android minimum; passing the Duration explicitly is
    // equivalent to passing null (defaults to 15 min) but more explicit.
    frequency: const Duration(minutes: 15),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    constraints: Constraints(
      networkType: NetworkType.connected,
      requiresBatteryNotLow: true,
    ),
  );
}

/// Cancels the WorkManager periodic catch-up task.
///
/// Called unconditionally from
/// `BackgroundLocationManager.disableBackgroundScheduling()` — the cancel
/// must NOT depend on `backgroundCatchupEnabled` because a stale task
/// registered from a flag-ON build must still be cancellable after the flag
/// is flipped back to OFF (e.g. during a rollback).
///
/// Silently no-ops on non-Android platforms (guards with
/// `Platform.isAndroid`). The inner `cancelAll()` call is best-effort; any
/// thrown error is swallowed by the caller's try/catch in
/// `BackgroundLocationManager.disableBackgroundScheduling()`.
Future<void> cancelBackgroundCatchup() async {
  if (!Platform.isAndroid) return;
  await Workmanager().cancelAll();
}
