/// Android WorkManager periodic-task registration and the top-level
/// `callbackDispatcher` entry-point for the M7 background catch-up floor.
///
/// ## Architecture (read before editing)
///
/// WorkManager schedules a PeriodicTask that fires at most every ~15 min
/// (the Android minimum). Each wake spins up a **new** FlutterEngine /
/// Dart runtime. The safeguards that keep a wake privacy-safe and
/// fork-safe, in gate order (docs/M7E_GO_LIVE_PLAN.md D2 + A1):
///
///   0. **Compile-time flag (rollback gate, A1):** `backgroundCatchupEnabled`
///      is re-checked FIRST on every wake, so flipping the const back to
///      `false` re-inerts even devices that already hold a live JobScheduler
///      registration + stored callback handle from a flag-ON build.
///   1. **Durable-intent re-check (C2):** reads `kBackgroundSharingKey`.
///      If false → clean no-op; zero FFI / relay activity. Fail-CLOSED.
///   2. **Pending-MLS-wipe marker (M10.1):** reads `kPendingMlsWipeKey`
///      directly (never constructs `PendingMlsWipeService`, never attempts
///      the wipe itself — declining is the whole job). Marker set OR read
///      error → clean no-op, BEFORE any code path that could SQLite-create
///      a fresh decryptable DB. Fail-CLOSED.
///   3. **FGS fast-path bail (battery only):** if the foreground service is
///      running we skip the sweep to avoid a boot-cost Rust runtime for
///      work the FGS already covers. This is a BATTERY optimization — it
///      is NOT the fork-safety mechanism. The Rust `WRITER_LOCK` (M7-B) is.
///      Fail-OPEN (error → proceed).
///   4. **Foreground-active fast-path (battery only, D4):** FGS dead but
///      the UI isolate is active → the map-shell pollers already receive,
///      so skip the boot cost. Fail-OPEN.
///   5. **`CatchupService` chokepoint (C3):** `runCatchup(isBackground
///      Wake:true)` re-checks the sharing flag again inside Dart before
///      any FFI call, then runs the receive-only Rust sweep
///      (`run_catchup_all_circles` — never authors; yields `Skipped` to any
///      authoring writer via `try_acquire_background`).
///
/// ## LIVE since M7-E
///
/// `backgroundCatchupEnabled == true` (compile-time const in
/// `live_sync_provider.dart`, flipped at M7-E — see
/// `docs/M7E_GO_LIVE_PLAN.md`). [registerBackgroundCatchup] registers the
/// ~15-min WorkManager periodic task from the FGS enable path, and each wake
/// runs [_runCatchupViaWorkerBootstrap] when every gate passes.
///
/// **Rollback = flip the const back to `false`** (plan §7): registration
/// stops, and gate 0 above makes every already-queued wake a clean no-op.
/// [cancelBackgroundCatchup] stays deliberately flag-INDEPENDENT so stale
/// tasks remain cancellable after a rollback.
///
/// ## Logging (Security Rule 5/6)
///
/// Every exit path emits a presence-only marker (public consts below, pinned
/// by unit test AND grepped verbatim by the `e2e-m7-background` CI lane).
/// Markers carry fixed strings + `CatchupResult` COUNTERS only — never
/// coordinates, pubkeys, group ids, event ids, or raw errors. Failures are
/// logged as `runtimeType` only. `callbackDispatcher` replicates `main()`'s
/// `kReleaseMode` debugPrint silencer (A7) because this isolate never runs
/// `main()`.
///
/// ## Runtime proof (cannot be asserted in flutter test)
///
/// The bootstrap path (RustLib.init + keyring + SQLCipher open in a
/// WorkManager isolate) is proven by the `e2e-m7-background` emulator lane
/// (Phases A/B/C1/C2) and the local pixel8a runbook — see
/// `docs/M7E_GO_LIVE_PLAN.md` §5/§6/D6.
library;

// dart: imports come before package: imports (directives_ordering).
// DartPluginRegistrant lives in dart:ui — it registers all method-channel
// plugin implementations in the headless isolate so SharedPreferences,
// flutter_secure_storage, flutter_foreground_task, etc. are accessible.
import 'dart:convert' show base64Decode;
import 'dart:io' show Platform;
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/catchup_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/pending_mls_wipe_service.dart';
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
// Logcat markers (public consts — A10)
//
// The e2e-m7-background CI lane greps adb logcat for these EXACT strings
// (docs/M7E_GO_LIVE_PLAN.md D6, Phases A/C1/C2), and the unit tests pin the
// literals. Change a marker, the lane script, and the test TOGETHER — a lone
// edit here silently breaks the runtime-proof lane. All markers are
// presence-only: fixed strings + counters, zero secret/identifying material.
// ---------------------------------------------------------------------------

/// Gate-0 exit: the compile-time flag is off (rolled-back build servicing a
/// stale registered task).
const String kCatchupWorkerFlagDisabledMarker =
    '[CatchupWorker] wake: backgroundCatchupEnabled=false — no-op';

/// Gate-1 exit: the user's durable background-sharing intent is off.
const String kCatchupWorkerConsentDisabledMarker =
    '[CatchupWorker] wake: consent disabled — no-op';

/// Gate-2 exit: the M10.1 pending-MLS-wipe marker is set.
const String kCatchupWorkerPendingWipeMarker =
    '[CatchupWorker] wake: pending-wipe marker set — no-op';

/// Gate-3 exit: the foreground service already covers receive.
const String kCatchupWorkerFgsAliveMarker =
    '[CatchupWorker] wake: FGS alive — skip';

/// Gate-4 exit: the foreground UI isolate is active (map-shell pollers
/// already receive).
const String kCatchupWorkerForegroundActiveMarker =
    '[CatchupWorker] wake: foreground active — skip';

/// Bootstrap re-check exit (D1 step 3b): the pending-wipe marker was set
/// while the bootstrap ran — abort before any DB open.
const String kCatchupWorkerPendingWipePostBootstrapMarker =
    '[CatchupWorker] wake: pending-wipe marker set post-bootstrap — no-op';

/// Bootstrap re-check exit (A11): consent was revoked while the bootstrap
/// ran — abort before any DB open.
const String kCatchupWorkerConsentDisabledPostBootstrapMarker =
    '[CatchupWorker] wake: consent disabled post-bootstrap — no-op';

/// Bootstrap exit (A2): no identity in secure storage (e.g. post-logout) —
/// abort BEFORE `CircleManagerFfi.newInstance` so the wake cannot
/// SQLite-create a fresh empty DB + keyring key as post-logout residue.
const String kCatchupWorkerNoIdentityMarker =
    '[CatchupWorker] wake: no identity — no-op';

/// Bootstrap success: FFI + keyring + identity + DB + relays are up; the
/// sweep is about to run (grepped by Phase A of the CI lane).
const String kCatchupWorkerBootstrapOkMarker = '[CatchupWorker] bootstrap ok';

/// Prefix of the sweep-completion line; the full line appends the
/// `CatchupResult` counters (`circles= locations= commits= staged= cursors=
/// deadline= relayErrors=`) — counters only, never content.
const String kCatchupWorkerSweepCompletePrefix =
    '[CatchupWorker] sweep complete:';

// ---------------------------------------------------------------------------
// Identity access (mirrors background_location_task.dart — the FGS template)
// ---------------------------------------------------------------------------

/// Secure storage for reading the identity. MUST mirror the FGS template
/// (`background_location_task.dart`) so a background wake can read the key
/// under the same iOS accessibility class (harmless on Android).
const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  ),
);

/// Storage key of the Nostr identity (must match the foreground providers).
const String _kIdentityStorageKey = 'haven.nostr.identity';

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
/// - `isPendingMlsWipe`: reads `kPendingMlsWipeKey` from SharedPreferences
///   (M10.1). The production impl reads the pref DIRECTLY — it must NOT
///   construct `PendingMlsWipeService` (that requires a `CircleService`,
///   whose construction path is exactly what this gate exists to avoid).
/// - `isRunningService`: reads `FlutterForegroundTask.isRunningService`.
///   Tests inject a stub that avoids the platform channel.
/// - `isForegroundActive`: reads the staleness-checked
///   [BackgroundLocationManager.isForegroundActive] flag (D4).
/// - `runCatchup`: the actual sweep. Tests inject a recording stub.
/// - `catchupEnabled`: gate 0. Defaults to the compile-time
///   `backgroundCatchupEnabled` const so production call sites bind to the
///   flag; tests pass an explicit value to exercise both branches (the
///   same pattern as the iOS handler's `catchupEnabled` test seam).
///
/// Returns `true` on success (WorkManager will not reschedule on success),
/// `false` if the catch-up threw (WorkManager retries based on back-off
/// policy — for a periodic task this effectively means "wait for the next
/// scheduled window").
///
/// The exit paths, in gate order (see the library doc for rationale):
///
/// 0. **Flag off** → return `true` (rollback gate, A1; a stale registered
///    task on a rolled-back build must no-op cleanly, not retry-loop).
/// 1. **Sharing disabled** → return `true` (clean no-op; do NOT return false
///    — that signals "retry", which is wrong when the user has opted out).
///    Read error → same (fail-CLOSED).
/// 2. **Pending MLS wipe** → return `true` (M10.1: never open/create MLS
///    state mid-wipe; the worker NEVER attempts the wipe itself). Read
///    error → treated as set (fail-CLOSED).
/// 3. **FGS alive** → return `true` (battery fast-path; the FGS covers
///    receive). Read error → proceed (fail-OPEN).
/// 4. **Foreground active** → return `true` (battery fast-path; the UI
///    pollers cover receive). Read error → proceed (fail-OPEN).
/// 5. **Run catch-up** → return `true` on success, `false` on throw.
Future<bool> runBackgroundCatchupTask({
  required Future<bool> Function() isBackgroundSharingEnabled,
  required Future<bool> Function() isPendingMlsWipe,
  required Future<bool> Function() isRunningService,
  required Future<bool> Function() isForegroundActive,
  required Future<void> Function() runCatchup,
  bool catchupEnabled = backgroundCatchupEnabled,
}) async {
  // Gate 0 (A1): compile-time flag re-check — FIRST, before any prefs read.
  // This is what makes the one-commit rollback complete: devices updated in
  // place keep their persisted JobScheduler job + stored callback handle,
  // so the flag must be re-checked at every wake, not only at registration.
  if (!catchupEnabled) {
    debugPrint(kCatchupWorkerFlagDisabledMarker);
    return true; // clean no-op; nothing else may run
  }

  // Gate 1 (C2): durable-intent re-check.
  // Read kBackgroundSharingKey from SharedPreferences. If false → hard
  // no-op. This is executed AFTER the binding / plugin registrant are
  // initialized (see callbackDispatcher), so SharedPreferences is accessible.
  try {
    final enabled = await isBackgroundSharingEnabled();
    if (!enabled) {
      debugPrint(kCatchupWorkerConsentDisabledMarker);
      return true; // clean no-op; no relay or FFI activity
    }
  } on Object catch (e) {
    // Fail-safe: treat unknown as disabled so a corrupt SharedPreferences
    // cannot accidentally enable background relay activity after opt-out.
    debugPrint(
      '[CatchupWorker] wake: consent check failed — treating as disabled: '
      '${e.runtimeType}',
    );
    return true;
  }

  // Gate 2 (M10.1, D2): pending-MLS-wipe marker. Security gate, fail-CLOSED:
  // marker set OR unreadable → decline the wake so it cannot touch (or
  // SQLite-create) MLS state that a logout is trying to destroy. The worker
  // NEVER attempts the wipe itself — that needs a CircleService, would race
  // the main-isolate M10.1 launch retry, and has no user-visible recovery
  // path from a headless isolate. Declining is the whole job.
  try {
    final wipePending = await isPendingMlsWipe();
    if (wipePending) {
      debugPrint(kCatchupWorkerPendingWipeMarker);
      return true; // clean no-op
    }
  } on Object catch (e) {
    debugPrint(
      '[CatchupWorker] wake: pending-wipe check failed — treating as set: '
      '${e.runtimeType}',
    );
    return true;
  }

  // Gate 3: FGS alive → skip (battery fast-path, NOT the fork-safety mech).
  // The Rust WRITER_LOCK (M7-B) is the actual exclusion mechanism.
  try {
    final fgsRunning = await isRunningService();
    if (fgsRunning) {
      debugPrint(kCatchupWorkerFgsAliveMarker);
      return true; // FGS covers receive; no work needed here
    }
  } on Object {
    // Cannot read FGS state — proceed conservatively (let the sweep try;
    // the WRITER_LOCK will serialize it safely with any concurrent FGS).
  }

  // Gate 4 (D4): foreground UI active → skip. Catches FGS-dead-but-UI-active
  // (OEM killed the service; user reopened the app): the map-shell pollers
  // are already receiving, so the marginal sweep would pay a full per-wake
  // Rust engine + SQLCipher boot for nothing. Battery gate ONLY — a read
  // error PROCEEDS (fail-open) so a persistent error cannot silently starve
  // the catch-up floor (correctness never depends on this gate: the sweep is
  // cursor-idempotent and excluded by the Rust WRITER_LOCK).
  try {
    final foregroundActive = await isForegroundActive();
    if (foregroundActive) {
      debugPrint(kCatchupWorkerForegroundActiveMarker);
      return true; // UI pollers cover receive
    }
  } on Object {
    // Cannot read foreground state — proceed (fail-open, see above).
  }

  // Step 5: Run the catch-up sweep.
  try {
    await runCatchup();
    return true;
  } on Object catch (e) {
    // Signal WorkManager to apply back-off / retry at next window.
    // runtimeType only — never the error itself (Security Rule 8).
    debugPrint('[CatchupWorker] sweep failed: ${e.runtimeType}');
    return false;
  }
}

// ---------------------------------------------------------------------------
// callbackDispatcher — WorkManager entry-point
// ---------------------------------------------------------------------------

/// Top-level WorkManager entry-point. Must be annotated with
/// `@pragma('vm:entry-point')` so the Dart VM retains it after tree-shaking.
///
/// **Order is critical**:
///
///   0. `kReleaseMode` debugPrint silencer (A7) — this isolate never runs
///      `main()`, so main()'s release silencer does not apply here.
///      Replicated first so no later line can leak to logcat in release.
///   1. `WidgetsFlutterBinding.ensureInitialized()` — must precede the
///      registrant; without it `DartPluginRegistrant.ensureInitialized()`
///      panics on some engines.
///   2. `DartPluginRegistrant.ensureInitialized()` — registers all plugins
///      (including `shared_preferences`) so platform channels are reachable.
///      This MUST precede any platform-channel call. Doing it inside
///      `executeTask` (which the workmanager plugin itself calls) is too late
///      — some channel calls fire during `MethodChannel.setMethodCallHandler`
///      setup before the task body runs.
///   3. Run the gate chain via [runBackgroundCatchupTask] (flag → consent →
///      pending-wipe → FGS-alive → foreground-active → sweep).
///   4. `Workmanager().executeTask(...)` — bridges the Dart task body back
///      to WorkManager's native side to signal completion.
///
/// Steps 1–2 happen BEFORE `executeTask` so the SharedPreferences channel
/// and flutter_foreground_task channel are ready by the time the task body
/// runs.
@pragma('vm:entry-point')
void callbackDispatcher() {
  // (0) A7: silence debugPrint in release builds (replicates main.dart's
  // defense-in-depth pattern — the markers below are presence-only counters
  // anyway, but a future log regression must not leak to logcat either).
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  // (1) Binding first — always.
  WidgetsFlutterBinding.ensureInitialized();
  // (2) Plugin registrant second — before ANY platform-channel call.
  DartPluginRegistrant.ensureInitialized();

  // (3+4) Execute the task body.
  Workmanager().executeTask((taskName, inputData) async {
    return runBackgroundCatchupTask(
      isBackgroundSharingEnabled: () async {
        final prefs = await SharedPreferences.getInstance();
        // L1: reload so a cross-isolate opt-out written after this isolate's
        // first getInstance() is seen (cheap; this gate runs once per wake).
        await prefs.reload();
        return prefs.getBool(kBackgroundSharingKey) ?? false;
      },
      // Direct pref read (D2) — deliberately NOT PendingMlsWipeService,
      // whose construction requires the very CircleService path this gate
      // exists to keep closed. Reuses the instance gate 1 just loaded
      // (fresh in this brand-new isolate; the bootstrap re-check below
      // reload()s again before any DB open).
      isPendingMlsWipe: () async {
        final prefs = await SharedPreferences.getInstance();
        return prefs.getBool(kPendingMlsWipeKey) ?? false;
      },
      isRunningService: () => FlutterForegroundTask.isRunningService,
      // D4: staleness-checked foreground flag (auto-expires after
      // 2 × kBackgroundRepeatInterval, so a stale value cannot permanently
      // starve the floor). Its own read error already returns false.
      isForegroundActive: BackgroundLocationManager.isForegroundActive,
      runCatchup: _runCatchupViaWorkerBootstrap,
    );
  });
}

/// Boots the minimal service set in the WorkManager isolate and runs one
/// receive-only catch-up sweep (D1, as amended by A2/A10/A11).
///
/// The WorkManager isolate never ran `main()`, so it bootstraps the bridge
/// itself — by DIRECT construction of exactly what [CatchupService] needs
/// (no `ProviderContainer`: a run-once headless isolate has no watchers, and
/// riverpod would silently widen the background surface with every future
/// edit to the provider graph). This mirrors the ONE field-proven
/// background-isolate bootstrap (the FGS `onStart` in
/// `background_location_task.dart`) minus its authoring tail:
///
///   1. `RustLib.init()` — duplicate-init tolerant (A10).
///   2. `initKeyringStore()` — idempotent; MDK reads the SQLCipher key.
///   3. Shared data-dir resolver (M7-6 — no MLS split-brain), then the
///      M10.1/A11 re-check: `prefs.reload()` picks up cross-isolate writes;
///      a wipe marker or consent flip that landed during 1–3 aborts BEFORE
///      any DB open could SQLite-create a fresh decryptable DB.
///   4. Identity FIRST (A2): read + load the identity, zero the Dart byte
///      copy in `finally` (Security Rule 9), and bail on a missing identity
///      BEFORE `CircleManagerFfi.newInstance` — a wake racing a successful
///      logout must not create a fresh empty DB + keyring key (residue the
///      M10.1 launch retry does NOT clean — it only covers the
///      marker-still-set branch).
///   5. ONE `CircleManagerFfi` per isolate (same rule as the FGS template).
///   6. Relay service up, then the C3 chokepoint:
///      `CatchupService.runCatchup(isBackgroundWake: true)` re-checks
///      consent internally before any FFI/relay call. `maxDurationSecs: 25`
///      (D3): bounds only the Rust sweep; deliberately above the foreground
///      default (20) because a cold background wake is the only receive
///      opportunity a backgrounded device gets — total wall clock stays far
///      inside JobScheduler's execution ceiling.
///   7. `finally`: best-effort relay shutdown.
///
/// Any throw propagates to [runBackgroundCatchupTask]'s step-5 catch
/// (logged as runtimeType only → `false` → WorkManager back-off). This
/// FFI-bound path is proven by the emulator lane, not unit tests (exactly
/// like the FGS `onStart`).
Future<void> _runCatchupViaWorkerBootstrap() async {
  // 1. FFI bridge for THIS isolate. Defensive duplicate-init tolerance
  //    (A10): RustLib.init() throws if the bridge is somehow already up on
  //    this engine; suppress that and let a REAL initialization failure
  //    surface at the first FFI call below (mirrors integration_test/
  //    app_test.dart's setUpAll pattern).
  try {
    await RustLib.init();
  } on Object catch (e) {
    debugPrint('[CatchupWorker] RustLib.init note: ${e.runtimeType}');
  }

  // 2. Platform keyring (idempotent) — MDK reads the SQLCipher key from it.
  await initKeyringStore();

  // 3. Single shared data-dir resolver (M7-6; no MLS split-brain).
  final dataDir = await const PathProviderDataDirectory().getDataDirectory();

  // 3b. M10.1 re-check (D1 step 3b + A11): the pending-wipe marker — or a
  //     consent flip — may have been written by the main isolate while
  //     steps 1–3 ran. reload() picks up the cross-isolate write; marker
  //     set ⇒ abort BEFORE the DB open below can SQLite-create a fresh
  //     decryptable DB. The same reload re-reads consent at zero extra
  //     cost (A11).
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  if (prefs.getBool(kPendingMlsWipeKey) ?? false) {
    debugPrint(kCatchupWorkerPendingWipePostBootstrapMarker);
    return;
  }
  if (!(prefs.getBool(kBackgroundSharingKey) ?? false)) {
    debugPrint(kCatchupWorkerConsentDisabledPostBootstrapMarker);
    return;
  }

  // 4. Identity FIRST (A2) — before any CircleManagerFfi exists. Zero the
  //    Dart-side copy of the secret bytes in `finally`: the Rust FFI
  //    boundary already zeroizes its input, but Dart has no guaranteed
  //    zeroize — the best-effort overwrite reduces the window the secret
  //    sits in managed memory (Security Rule 9). Only the pubkey hex
  //    leaves this block.
  String? pubkeyHex;
  final identityManager = await NostrIdentityManager.newInstance();
  final storedBytes = await _secureStorage.read(key: _kIdentityStorageKey);
  if (storedBytes != null) {
    final bytes = base64Decode(storedBytes);
    try {
      await identityManager.loadFromBytes(secretBytes: bytes);
      if (identityManager.hasIdentity()) {
        pubkeyHex = identityManager.pubkeyHex();
      }
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }
  if (pubkeyHex == null) {
    // No identity (e.g. the wake raced a completed logout, or the user never
    // onboarded): bail before the DB open below can create post-logout
    // residue (a fresh empty SQLCipher DB + keyring key).
    debugPrint(kCatchupWorkerNoIdentityMarker);
    return;
  }

  // 5. ONE CircleManagerFfi per isolate (same rule as the FGS template):
  //    two instances would diverge across two in-memory MDK caches.
  final circleManager = await CircleManagerFfi.newInstance(dataDir: dataDir);

  // 6. Relay service.
  final relayService = NostrRelayService();
  await relayService.initialize();
  try {
    debugPrint(kCatchupWorkerBootstrapOkMarker);
    // 7. Terminate in the M7 chokepoint — receive-only sweep, NOT the FGS
    //    authoring cycle. isBackgroundWake:true re-checks consent inside
    //    (C3). maxDurationSecs: 25 per D3 (bounds the Rust sweep only).
    final result = await CatchupService(
      circleManagerFactory: () async => circleManager,
      ownPubkeyHex: () async => pubkeyHex,
      relayService: relayService,
      // L1: RELOAD the consent pref at the C3 chokepoint so an opt-out that
      // lands DURING this bootstrap (between the step-3b reload above and here
      // — the DB-open + relay-init gap) is seen, instead of the default
      // reader's cached snapshot. Closes the sub-second post-opt-out window in
      // which a receive-only sweep could still connect to a relay.
      isBackgroundSharingEnabled: () async {
        final p = await SharedPreferences.getInstance();
        await p.reload();
        return p.getBool(kBackgroundSharingKey) ?? false;
      },
    ).runCatchup(isBackgroundWake: true, maxDurationSecs: 25);
    // Presence-only counters (CatchupResult is counters-only by
    // construction) — the exact line Phase A of the CI lane parses.
    debugPrint(
      '$kCatchupWorkerSweepCompletePrefix circles=${result.circlesSwept} '
      'locations=${result.locationsApplied} commits=${result.commitsApplied} '
      'staged=${result.autoCommitsStaged} cursors=${result.cursorsAdvanced} '
      'deadline=${result.deadlineHit} relayErrors=${result.relayErrors}',
    );
  } finally {
    try {
      await relayService.shutdown();
    } on Object catch (_) {
      // Best-effort teardown (FGS template's onDestroy discipline).
    }
  }
}

// ---------------------------------------------------------------------------
// Registration / cancellation (foreground-side API)
// ---------------------------------------------------------------------------

/// Registers the WorkManager periodic catch-up task.
///
/// **Early-returns without registering anything when
/// `backgroundCatchupEnabled == false`** (the compile-time flag from
/// `live_sync_provider.dart` — `true` since M7-E, so registration is LIVE).
/// With a rolled-back flag this is the primary inertness gate; gate 0 inside
/// [runBackgroundCatchupTask] covers tasks that were registered before the
/// rollback.
///
/// With the flag true:
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
  // Flag gate: do NOTHING while the flag is off (rollback posture).
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
