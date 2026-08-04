/// Shared CI-only WorkManager wiring for the three `m7_worker_*_test.dart`
/// runtime-proof targets (`docs/M7_BACKGROUND_SHARING.md` D6,
/// `docs/E2E_TROUBLESHOOTING.md`): a one-off task the lane can actually
/// force-run cold, and a dispatcher that makes the cold worker able to reach
/// the hermetic CI relay.
///
/// ## Why a one-off task, alongside the production periodic task
///
/// Each target's arming code already calls `registerBackgroundCatchup()`,
/// which schedules the production ~15-min PERIODIC WorkManager task. But
/// `tooling/e2e/ci/run-m7-background-catchup.sh` force-runs the worker cold
/// via `adb shell cmd jobscheduler run` AFTER `am kill`, and WorkManager's
/// `ForceStopRunnable` reschedules a force-stopped PERIODIC task to its
/// next ~15-min window instead of running it — the force-run never
/// actually boots the worker, so the lane can never observe a marker. This
/// is fundamental WorkManager behavior, not a defect in the periodic
/// registration.
///
/// A ONE-OFF task, by contrast, is re-enqueued to run ASAP after the same
/// `ForceStopRunnable` reschedule, so the shell's force-run genuinely boots
/// a cold worker process. [registerM7CiOneOffCatchup] enqueues one IN
/// ADDITION to (never instead of) `registerBackgroundCatchup()`, so the
/// periodic-task production path stays exercised exactly as before.
///
/// ## Why a CI-only DISPATCHER too (read before editing — this is the whole
/// reason Phase A can assert delivery instead of only bootstrap)
///
/// The debug-only `ws://` loopback opt-in
/// (`allowWsLoopbackForTest` → `ALLOW_WS_LOOPBACK_FOR_TEST`, an install-once
/// `OnceLock` in `haven-core/src/relay/manager.rs`) is PROCESS-GLOBAL and has
/// NO on-disk form. Unlike the SQLCipher key — which persists in the Android
/// Keystore and is exactly why the cold worker can open Alice's database —
/// nothing carries the opt-in from the drive process into the worker process
/// that WorkManager starts after `am kill`.
///
/// So without this dispatcher the cold worker rejected `ws://10.0.2.2:7777`
/// in `validate_single_relay_url` before it ever opened a socket, and its
/// sweep returned `locations=0, relayErrors>=1` — provably, in CI run
/// 30792258968:
///
/// ```text
/// [phase-a] sweep counters: circles=1 locations=0 relayErrors=1
/// ```
///
/// The lane could therefore only ever assert BOOTSTRAP (that the isolate
/// booted Rust + keyring + SQLCipher and swept), never DELIVERY — the flag
/// that was supposed to assert delivery, `M7_REQUIRE_DECRYPT`, defaulted to 0
/// and was set in no workflow, because at 1 it failed by construction
/// (`docs/CI_HARDENING_BACKLOG.md` B2).
///
/// [m7CiCallbackDispatcher] closes that gap by installing the opt-in in the
/// COLD process, then delegating to `runBackgroundCatchupWake()` — the
/// production wake body, unmodified. Nothing about the gate chain, the
/// bootstrap, or the sweep is re-implemented here; the ONLY delta versus
/// production is the opt-in install, which cannot exist in a release build
/// (the release `allow_ws_loopback_for_test` is a stub returning `Err`, and
/// this whole file lives under `integration_test/`).
///
/// ## It also makes the NEGATIVE phases mean what they claim
///
/// Phases C1/C2 assert "the gate declined the wake AND strfry stayed silent".
/// Until this dispatcher existed, that silence was over-determined: a leaked
/// wake could not have reached the plaintext relay even with every gate wide
/// open, because the opt-in was absent. Installing it UNCONDITIONALLY here
/// (for every wake in these CI builds, not just Phase A's) makes the relay
/// genuinely reachable, so strfry silence now proves the GATE and not the
/// harness.
library;

import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/widgets.dart';
import 'package:haven/src/rust/api.dart' show allowWsLoopbackForTest;
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/background_catchup_worker.dart'
    show kBackgroundCatchupTaskName, runBackgroundCatchupWake;
import 'package:workmanager/workmanager.dart';

/// `uniqueName` of the CI-only one-off catch-up task.
///
/// Deliberately distinct from [kBackgroundCatchupTaskName] (the periodic
/// task's `uniqueName`) so WorkManager treats the two as separate work
/// items — `enqueueUniqueWork` only de-duplicates within the SAME
/// `uniqueName`. `taskName` (passed positionally below) stays the shared
/// production constant so the dispatcher runs the identical
/// `runBackgroundCatchupTask` gate chain for either task.
const String m7CiOneOffUniqueName = 'm7-ci-catchup-oneshot';

/// Logged by [m7CiCallbackDispatcher] once the `ws://` loopback opt-in is
/// installed in the cold worker process.
///
/// The `e2e-background-catchup` lane greps this VERBATIM to distinguish
/// "the worker could reach the relay and found nothing" from "the worker was
/// never able to reach the relay". Those produce the same `locations=0`
/// counter and mean opposite things, and conflating them is how a delivery
/// assertion turns into a bootstrap assertion wearing its name. Change it
/// here, in `tooling/e2e/ci/run-m7-background-catchup.sh`, and in
/// `scripts/ci/check_m7_background_delivery_assertion.sh` TOGETHER.
const String kM7CiLoopbackArmedMarker = '[M7CI] ws:// loopback opt-in armed';

/// Logged when the opt-in could NOT be installed — the cold worker will then
/// reject the plaintext CI relay, and the phase must fail with THAT reason
/// rather than with a misleading "peer location was never delivered".
const String kM7CiLoopbackFailedMarker =
    '[M7CI] ws:// loopback opt-in FAILED — cold worker cannot reach the CI '
    'relay';

/// CI-only WorkManager entry-point: prepare the cold isolate the way
/// production does, additionally arm the debug `ws://` loopback opt-in for
/// THIS process, then run the production wake body.
///
/// Registered by [registerM7CiOneOffCatchup], which calls
/// `Workmanager().initialize` with this handle AFTER the target has already
/// run the production `registerBackgroundCatchup()` — so the production
/// registration path stays exercised and only the executed entry-point
/// differs.
///
/// Steps 0–2 mirror the production `callbackDispatcher` exactly: release
/// debugPrint silencer, `WidgetsFlutterBinding`, then `DartPluginRegistrant`
/// BEFORE any platform-channel call. Step 2b is the only addition.
@pragma('vm:entry-point')
void m7CiCallbackDispatcher() {
  // (0) Mirrors production: silence debugPrint in release. These CI targets
  // are always debug-built, so this is parity, not policy.
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  // (1) Binding first — always.
  WidgetsFlutterBinding.ensureInitialized();
  // (2) Plugin registrant second — before ANY platform-channel call.
  DartPluginRegistrant.ensureInitialized();

  Workmanager().executeTask((taskName, inputData) async {
    // (2b) THE ONLY DELTA vs production. The bridge must be up before the FFI
    // call, so init it here; the production bootstrap's own `RustLib.init()`
    // is duplicate-init tolerant and simply logs a note when it runs second.
    await _armWsLoopbackForColdWorker();
    // (3) The production wake body, verbatim.
    return runBackgroundCatchupWake();
  });
}

/// Installs the debug-only `ws://` loopback opt-in in this (cold) process.
///
/// Best-effort and self-describing: on failure it logs
/// [kM7CiLoopbackFailedMarker] and returns, letting the wake proceed exactly
/// as it did before this dispatcher existed. The lane then fails naming the
/// opt-in instead of blaming the receive path.
Future<void> _armWsLoopbackForColdWorker() async {
  try {
    await RustLib.init();
  } on Object catch (e) {
    // Bridge already up on this engine — tolerate; a genuine init failure
    // surfaces at the FFI call below (Security Rule 8: runtimeType only).
    debugPrint('[M7CI] RustLib.init note: ${e.runtimeType}');
  }
  try {
    allowWsLoopbackForTest();
    debugPrint(kM7CiLoopbackArmedMarker);
  } on Object catch (e) {
    debugPrint('$kM7CiLoopbackFailedMarker: ${e.runtimeType}');
  }
}

/// Registers the CI-only dispatcher and enqueues the one-off catch-up task
/// the shell script force-runs.
///
/// Call AFTER `registerBackgroundCatchup()` in each `m7_worker_*` target —
/// this is an ADDITION, never a replacement. `registerBackgroundCatchup()`
/// still runs the production registration (including its own
/// `Workmanager().initialize(callbackDispatcher)` and the ~15-min periodic
/// task); this then re-points the stored callback handle at
/// [m7CiCallbackDispatcher] so whichever task WorkManager runs boots a worker
/// that can actually reach the hermetic relay.
///
/// - `taskName` = [kBackgroundCatchupTaskName]: identical to the periodic
///   task's, so the dispatcher runs the exact same
///   `runBackgroundCatchupTask` gate chain (flag → consent → pending-wipe
///   → FGS-alive → foreground-active → sweep).
/// - `initialDelay` = 60s: keeps the one-off task pending (un-consumed)
///   through the drive's own exit and the shell's `am kill`, instead of
///   letting WorkManager opportunistically run it during the live
///   foreground drive — an early run would both mark the one-off DONE
///   (nothing left for the shell's later force-run to trigger) and could
///   trip the worker's foreground-active gate (D4). Force-run ignores the
///   remaining delay, so 60s only needs to outlast the drive + go-cold
///   window, not the force-run itself.
/// - No `constraints`: the production periodic task requires network +
///   battery-not-low; a constrained job is harder to force-run, so this
///   one-off is deliberately unconstrained (omitting the parameter maps to
///   the native default `Constraints.NONE`).
/// - `existingWorkPolicy: replace`: idempotent across CI retries of the
///   same target.
Future<void> registerM7CiOneOffCatchup() async {
  // Re-point the stored callback handle at the CI dispatcher. Must come AFTER
  // registerBackgroundCatchup()'s own initialize() call, which would otherwise
  // overwrite this one — WorkManager keeps a single handle per app.
  await Workmanager().initialize(m7CiCallbackDispatcher);

  await Workmanager().registerOneOffTask(
    m7CiOneOffUniqueName,
    kBackgroundCatchupTaskName,
    initialDelay: const Duration(seconds: 60),
    existingWorkPolicy: ExistingWorkPolicy.replace,
  );
}
