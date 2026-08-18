/// Background location sharing task handler.
///
/// Runs in a separate Dart isolate (Android foreground service) and
/// periodically publishes the user's encrypted location to all accepted
/// circles. Uses the same Rust FFI pipeline as the foreground publisher
/// but with its own service instances to avoid cross-isolate state sharing.
///
/// ## Jitter strategy
///
/// The `FlutterForegroundTask` repeat interval is set to
/// [kBackgroundRepeatInterval] (72 s, the minimum jittered interval).
/// Each `onRepeatEvent` call samples a fresh jittered target time and skips
/// early ticks, achieving the full `[72 s, 168 s]` publish cadence
/// without requiring dynamic interval changes.
///
/// ## MLS safety
///
/// Only one isolate publishes at a time (single-owner model). The
/// foreground cancels its publish timer before starting this service,
/// and stops this service before restarting its own timer on resume.
/// The existing [kLocationPublishOverlapGuard] absorbs any transition
/// window.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/location_publish_scheduler_provider.dart'
    show filterPublishEligibleCircles;
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/background_identity_service.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/circle_service.dart' show Circle;
import 'package:haven/src/services/foreground_liveness_probe.dart';
import 'package:haven/src/services/fresh_secret.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/pending_mls_wipe_service.dart';
import 'package:haven/src/services/per_circle_due_tracker.dart';
import 'package:haven/src/services/publish_stagger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Top-level callback required by [FlutterForegroundTask].
///
/// Must be annotated with `@pragma('vm:entry-point')` so the Dart
/// compiler does not tree-shake it. Registered in `main.dart`.
@pragma('vm:entry-point')
void backgroundCallback() {
  // A7: silence debugPrint in release builds. This isolate has its OWN
  // `FlutterEngine` and never runs `main()`, so `main.dart`'s silencer does not
  // reach it — `background_catchup_worker.dart`'s `callbackDispatcher` already
  // replicates it for exactly this reason. Without it, every `[BackgroundTask]`
  // line reaches release logcat, and those lines are not innocuous: the
  // publish summary carries the user's circle COUNT and a per-cycle timing
  // oracle, which together reconstruct a Haven activity timeline for anyone
  // with `adb logcat`, a bug-report capture, or an OEM/MDM log collector.
  //
  // Safe for CI: the E2E oracles grep these markers, but every lane drives a
  // debug APK — the same combination `e2e-background-catchup` relies on today.
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  FlutterForegroundTask.setTaskHandler(BackgroundLocationTaskHandler());
}

/// Whether the background isolate may publish location this cycle, given the
/// two raw disclosure flags as `SharedPreferences` returns them.
///
/// Both must be explicitly `true`. Google Play's "disclosure before collection"
/// rule requires an affirmative in-app disclosure before location is collected,
/// and the background variant is the one carrying the "even when the app is
/// closed or not in use" sentence — precisely what this isolate does.
///
/// **A missing flag is a refusal, not a default.** `getBool` returns `null` for
/// a key that was never written (a fresh install, a wiped profile, a key
/// renamed by a future migration). Treating `null` as permission would let
/// exactly those cases publish location with no disclosure ever shown, so the
/// null-coalescing here is the security property, not a formality — which is
/// why it is a named, tested predicate rather than an inline `??` pair.
///
/// Extracted as a free function so the truth table is unit-testable without the
/// Rust bridge, `SharedPreferences`, or a device.
@visibleForTesting
bool backgroundPublishDisclosureAccepted({
  required bool? foregroundAccepted,
  required bool? backgroundAccepted,
}) => (foregroundAccepted ?? false) && (backgroundAccepted ?? false);

/// Handles periodic location publishing in the background.
///
/// Lifecycle:
/// 1. [onStart] — initializes Rust FFI, services, and identity
/// 2. [onRepeatEvent] — fires every ~72 s; skips if jitter target not reached
/// 3. [onDestroy] — tears down relay connections
/// Why a session reclaim was or was not authorised.
///
/// Split out of [BackgroundLocationTaskHandler] so the gate logic is reachable
/// from a unit test. It used to live inline, where the only thing testing it was
/// a source-text scan — that could prove a gate's *token* appeared before the
/// destructive call, but not that its branch actually declined, and it could not
/// see the comparison operator in the rate limit at all.
enum SessionReclaimDecision {
  /// Every precondition holds; the caller may run the liveness probe and, if
  /// that reports the main isolate gone, reclaim.
  proceed,

  /// No data directory resolved — nothing to open.
  noDataDir,

  /// No identity loaded, so there is no session to open even if the guard were
  /// free.
  noIdentity,

  /// An MLS wipe is owed. Re-opening the database would recreate state that is
  /// supposed to be destroyed, so this outranks every other consideration.
  wipePending,

  /// The Rule-14 guard is not held, so the open failed for some other reason (a
  /// locked keyring, a full disk) that a reclaim cannot fix.
  guardNotHeld,

  /// A reclaim was attempted too recently.
  backoffActive,
}

/// Evaluates the gates that do not require I/O.
///
/// Pure by construction: every input is a value the caller has already
/// gathered, so the decision can be exercised exhaustively without a Rust
/// bridge, a foreground service, or a second isolate.
///
/// The liveness probe is deliberately NOT folded in — it is the one gate that
/// must run last and costs a cross-isolate round trip, so the caller applies it
/// only after this returns [SessionReclaimDecision.proceed].
@visibleForTesting
SessionReclaimDecision evaluateSessionReclaimGates({
  required bool hasDataDir,
  required bool hasIdentity,
  required bool wipePending,
  required bool guardHeld,
  required int? lastAttemptMs,
  required int nowMs,
  required Duration backoff,
}) {
  if (!hasDataDir) return SessionReclaimDecision.noDataDir;
  if (!hasIdentity) return SessionReclaimDecision.noIdentity;
  if (wipePending) return SessionReclaimDecision.wipePending;
  if (!guardHeld) return SessionReclaimDecision.guardNotHeld;
  if (lastAttemptMs != null) {
    final elapsed = nowMs - lastAttemptMs;
    // A NEGATIVE elapsed means the wall clock moved backwards (a manual change
    // or a large NTP correction). Treating that as "no time has passed" would
    // latch the limit until the clock caught up — potentially forever, which
    // would disable recovery entirely. A stamp in the future is not evidence of
    // a recent attempt, so let it through; the caller rewrites the stamp.
    if (elapsed >= 0 && elapsed < backoff.inMilliseconds) {
      return SessionReclaimDecision.backoffActive;
    }
  }
  return SessionReclaimDecision.proceed;
}

class BackgroundLocationTaskHandler extends TaskHandler {
  CircleManagerFfi? _circleManager;
  NostrIdentityManager? _identityManager;
  NostrRelayService? _relayService;
  GeolocatorLocationService? _locationService;
  LocationEventService? _locationEventService;
  NostrCircleService? _circleService;
  LocationSharingService? _locationSharingService;
  String? _pubkeyHex;

  /// Data directory resolved in [onStart], retained so a session reclaim can
  /// re-open the manager without re-resolving it.
  String? _dataDir;

  /// Liveness probe against the main isolate. Consulted before any reclaim.
  final ForegroundLivenessProbe _livenessProbe = ForegroundLivenessProbe();

  /// In-flight publish future, tracked so `onDestroy` can await it
  /// rather than nulling services mid-cycle.
  Future<void>? _inFlightPublish;

  /// Independent per-circle publish scheduling (privacy: decorrelation). Each
  /// circle is registered on its own CSPRNG-staggered due-time when the
  /// background first owns publishing, then re-armed on its OWN jittered
  /// cadence, so a relay can't correlate a device's circles by co-timing.
  /// Cleared whenever the foreground owns publishing, which is why the SEED
  /// has to be staggered: it re-runs on every foreground→background handoff.
  final PerCircleDueTracker _dueTracker = PerCircleDueTracker();

  /// CSPRNG gaps that keep two circles' kind-445 events out of the same
  /// wall-clock second (the engine stamps the outer `created_at` from the
  /// inner event's whole-second clock — see [PublishStagger]).
  ///
  /// The isolate builds its own rather than reading a provider: there is no
  /// Riverpod container here. Both planes share the same bounds via the
  /// constants in `publish_stagger.dart`.
  final PublishStagger _stagger = PublishStagger();

  /// Completed the moment [onDestroy] begins, so a decorrelation wait inside
  /// [_publishCycle] aborts instead of holding teardown open.
  ///
  /// `onDestroy` awaits [_inFlightPublish] before tearing anything down, and
  /// Android gives a stopping foreground service a short window — a plain
  /// `Future.delayed` between circles would spend that window sleeping. This
  /// makes every such wait cancellable, so the cost of the stagger at teardown
  /// is one in-flight publish, not the whole remaining spread.
  final Completer<void> _shutdownSignal = Completer<void>();

  bool get _shuttingDown => _shutdownSignal.isCompleted;

  /// Last time the background ran the all-circles peer-location fetch.
  /// Throttles the fetch to ~`kLocationUpdateInterval` so per-circle publish
  /// decorrelation (which wakes more often) does not multiply background relay
  /// round-trips by the circle count (battery parity — see `_publishCycle`).
  DateTime? _lastBackgroundFetchAt;

  /// Number of completed publish cycles since the last prune. The bg
  /// isolate calls `pruneExpiredLastKnown` once every
  /// [_cyclesPerPrune] cycles to bound the SQLCipher last-known table
  /// during long backgrounded sessions. Foreground also prunes hourly
  /// (`map_shell.dart::_pruneTimer`); the two are idempotent because
  /// `prune_expired_last_known` is a single SQLite DELETE under a
  /// per-instance `Mutex<Connection>` (`haven-core/src/circle/storage.rs:1166`).
  int _cyclesSinceLastPrune = 0;

  /// Run prune approximately once per hour at the nominal 120 s cadence.
  /// Matches the foreground hourly cadence and avoids duplicate writes.
  static const int _cyclesPerPrune = 30;

  /// Hooks for tests: when non-null, [onStart] uses these instead of
  /// constructing fresh instances. Production callers pass `null`.
  ///
  /// The hooks must form a consistent set — sharing the same
  /// `CircleManagerFfi` between [_circleManager], [_circleService], and
  /// [_locationSharingService] is the test's responsibility.
  @visibleForTesting
  CircleManagerFfi? overrideCircleManager;

  /// Test-only override for the relay service.
  @visibleForTesting
  NostrRelayService? overrideRelayService;

  /// Test-only override for the geolocation service.
  @visibleForTesting
  GeolocatorLocationService? overrideLocationService;

  /// Test-only override for the location-sharing service.
  @visibleForTesting
  LocationSharingService? overrideLocationSharingService;

  /// Test-only override for the Rule-14 liveness query (`isSessionLive`).
  ///
  /// Production leaves this `null` and calls the real FFI. Without this seam
  /// the whole `_ensureSession`/`_attemptSessionReclaim` orchestration could
  /// only be pinned by scanning the source text (see
  /// `session_reclaim_gate_test.dart`), which proves a gate's token appears in
  /// the right order but not that the gated code path actually runs and
  /// produces the right outcome against a scripted sequence of answers.
  @visibleForTesting
  Future<bool> Function({required String dataDir})? overrideIsSessionLive;

  /// Test-only override for [forceReleaseLiveSession]. See
  /// [overrideIsSessionLive] for why this seam exists.
  @visibleForTesting
  Future<ForceReleaseOutcomeFfi> Function()? overrideForceReleaseLiveSession;

  /// Test-only override for the liveness-probe confirmation timeout.
  ///
  /// Production uses the real [kLivenessProbeTimeout] (5 s, "generous relative
  /// to a publish cycle" — see `foreground_liveness_probe_test.dart`). A
  /// behavioural test of the full two-probe reclaim sequence would otherwise
  /// cost 2 × 5 s plus the gap below for every "genuinely dead foreground"
  /// case, so this is shortened in tests — never in production, where the
  /// default is the unmodified real constant.
  @visibleForTesting
  Duration livenessProbeTimeout = kLivenessProbeTimeout;

  /// Test-only override for the gap between the two confirmation probes
  /// (production default: [kLivenessProbeGap], 3 s). See
  /// [livenessProbeTimeout].
  @visibleForTesting
  Duration livenessProbeGap = kLivenessProbeGap;

  /// Test-only override for whether the cross-isolate liveness channel is
  /// ready (production default: [foregroundTaskChannelReady]).
  ///
  /// A "not ready" channel makes [ForegroundLivenessProbe.mainIsolateIsAlive]
  /// return `true` (alive) immediately, without ever waiting or accepting a
  /// simulated reply — the correct fail-closed production behaviour when no
  /// port is registered, but it would make every reclaim test trivially
  /// "alive" regardless of what the test scripts, since `flutter test` never
  /// has a real cross-isolate port. Forcing this `true` in a test lets the
  /// probe run its real ping/timeout/reply protocol instead.
  @visibleForTesting
  bool Function() livenessChannelReady = foregroundTaskChannelReady;

  /// Test-only override for the `hasIdentity` gate input to
  /// [evaluateSessionReclaimGates].
  ///
  /// Production leaves this `null` and reads the real
  /// `_identityManager?.hasIdentity()`. [NostrIdentityManager] is an FFI
  /// opaque handle with no fake construction available outside the Rust
  /// bridge, so a host test that wants to exercise the gates AFTER the
  /// identity check — the guard/backoff/probe machinery this file exists
  /// for — has no other way to make that check pass.
  @visibleForTesting
  bool? overrideHasIdentity;

  /// Cached nominal publish interval as [BigInt] to avoid per-tick allocation.
  static final BigInt _nominalSecsBigInt = BigInt.from(
    kLocationUpdateInterval.inSeconds,
  );

  /// Secure storage for reading identity and preferences.
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  // ---------------------------------------------------------------------------
  // Storage keys (must match the providers in the foreground isolate).
  // ---------------------------------------------------------------------------
  static const String _identityStorageKey = 'haven.nostr.identity';

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[BackgroundTask] onStart (starter=$starter)');

    // Clear the idle flag — the background isolate is now active.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kBackgroundIdleKey, false);
    } on Object catch (_) {
      // Non-fatal — the flag is a best-effort coordination mechanism.
    }

    try {
      // 1. Initialize Rust FFI in this isolate.
      await RustLib.init();

      // 2. Initialize the platform keyring store (idempotent).
      await initKeyringStore();

      // 3. Resolve the data directory (same path as foreground isolate).
      final dataDir = await const PathProviderDataDirectory()
          .getDataDirectory();

      // 4. Create identity manager and load from secure storage. MUST run
      //    BEFORE the circle manager (step 5, below): Dark Matter's
      //    `CircleManagerFfi.newInstance` hard-requires the identity secret
      //    bytes at construction time (it binds the account identity, the
      //    NIP-59 welcome signer, and the account-identity-proof signer).
      _identityManager = await NostrIdentityManager.newInstance();
      final storedBytes = await _secureStorage.read(key: _identityStorageKey);
      if (storedBytes != null) {
        final bytes = base64Decode(storedBytes);
        try {
          await _identityManager!.loadFromBytes(secretBytes: bytes);
          if (_identityManager!.hasIdentity()) {
            _pubkeyHex = _identityManager!.pubkeyHex();
          }
        } finally {
          // Zero the Dart-side copy of the secret bytes. The Rust FFI
          // boundary already zeroizes its input, but Dart has no
          // guaranteed zeroize — best-effort overwrite reduces the
          // window the secret sits in managed memory.
          bytes.fillRange(0, bytes.length, 0);
        }
      }

      // 5. Create the circle manager (opens the same SQLCipher DB), only if
      //    an identity was loaded (Dark Matter identity gating — see step 4).
      //    Tests inject a pre-built instance via [overrideCircleManager];
      //    only one CircleManagerFfi may exist per isolate or MLS state
      //    will diverge across two in-memory engine sessions. With no
      //    identity, `_circleManager` stays null — every downstream call
      //    site already gates on it and no-ops, matching the pre-migration
      //    no-identity behaviour.
      //
      //    The failure is caught INSIDE `_openCircleManager` on purpose. This
      //    open is the one step that fails routinely for a recoverable reason
      //    (the Rule-14 guard held by a session whose isolate is gone), and
      //    letting it throw here would skip steps 6 and 7 as well — leaving the
      //    isolate with no relay service and no location-sharing service, so a
      //    later recovery that rebuilt only the manager could not publish.
      _dataDir = dataDir;
      await _openCircleManager();

      // 6. Create relay, location, and jitter services.
      await _ensureAuxServices();

      // 7. Construct circle + location-sharing services so the background
      //    isolate can fetch peer locations alongside publishing. The
      //    circle service shares the existing CircleManagerFfi to avoid
      //    spawning a second MLS state cache over the same DB. The
      //    identity adapter only exposes pubkey hex — secret material
      //    stays inside the underlying NostrIdentityManager.
      _wireSharingServices();

      // 8. Per-circle publish scheduling (privacy: decorrelation) is seeded
      //    lazily in `_publishCycle` — each circle is registered "due now" the
      //    first cycle the background actually owns publishing, then re-armed
      //    on its own independent jittered cadence. No single seed timestamp is
      //    needed (or read): seeding due-now bounds a circle's worst-case
      //    inter-publish gap across the foreground→background handoff to one
      //    background cycle, keeping the kind-445 TTL no-gap invariant intact.

      debugPrint(
        '[BackgroundTask] Initialized '
        '(identity=${_pubkeyHex != null ? "loaded" : "none"}, '
        'locationSharing=${_locationSharingService != null})',
      );
    } on Object catch (e) {
      debugPrint('[BackgroundTask] onStart FAILED: ${e.runtimeType}');
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Skip if a previous cycle is still running to preserve the MLS
    // single-writer invariant. Under poor network conditions a cycle
    // could exceed the 72 s repeat interval.
    if (_inFlightPublish != null) return;

    _inFlightPublish = _runCycleWithIdleTracking(timestamp);
  }

  Future<void> _runCycleWithIdleTracking(DateTime timestamp) async {
    // CRITICAL: MUST await before any publish work. The foreground isolate
    // reads kBackgroundIdleKey from disk via SharedPreferences, so the flip
    // to false must be persisted before _publishCycle starts. A race within
    // the async write window (a few ms) would let _waitForBackgroundIdle
    // return immediately on a foreground resume, causing both isolates to
    // call encryptLocation concurrently.
    await _setIdle(false);
    try {
      await _publishCycle(timestamp);
    } finally {
      _inFlightPublish = null;
      await _setIdle(true);
    }
  }

  /// Writes the cross-isolate idle flag. Best-effort — failures here
  /// only widen the window the foreground waits on `_waitForBackgroundIdle`,
  /// they cannot break the MLS single-writer invariant (the 60 s
  /// overlap guard is the authoritative defense).
  Future<void> _setIdle(bool idle) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kBackgroundIdleKey, idle);
    } on Object catch (_) {
      // Non-fatal.
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('[BackgroundTask] onDestroy (isTimeout=$isTimeout)');

    // Release any decorrelation wait FIRST, before the await below. The cycle
    // paces its per-circle publishes seconds apart on purpose; without this
    // signal `onDestroy` would sit in `await _inFlightPublish` for the rest of
    // the burst's spread, inside Android's stop window. Signalling first turns
    // that into "finish the publish already in flight, then stop".
    if (!_shutdownSignal.isCompleted) _shutdownSignal.complete();

    // Await any in-flight publish cycle so it can finish its
    // `encryptLocation` + `publishEvent` calls before we tear down
    // services. Without this, nulling `_relayService` mid-publish
    // would waste an MLS epoch advance (encrypt succeeds, publish
    // fails because the relay handle is gone).
    try {
      await _inFlightPublish;
    } on Object catch (_) {
      // Publish errors are already handled inside `_publishCycle`.
    }

    try {
      await _relayService?.shutdown();
    } on Object catch (_) {
      // Ignore shutdown errors.
    }

    // Null the high-level services first so any callbacks that fire
    // mid-teardown find the underlying handles still valid.
    _locationSharingService = null;
    _circleService = null;

    // Hand the MLS DB's Rule-14 single-session slot back BEFORE dropping the
    // reference. Rust statics — including the `LIVE_SESSIONS` registry backing
    // that rule — are shared by EVERY Dart isolate in the one loaded `.so`, and
    // the guard is released only when Rust drops the manager. Nulling alone
    // defers that to a GC in an isolate that is about to be torn down, so the
    // slot can stay registered after this task is gone and lock the FOREGROUND
    // out of its own database ("an MLS session is already open on this
    // database") until the process dies. `dispose()` is idempotent and this is
    // the last use of the handle — same discipline as the WorkManager worker's
    // teardown in `background_catchup_worker.dart`.
    try {
      _circleManager?.dispose();
    } on Object catch (_) {
      // Best-effort, like the relay shutdown above.
    }
    _circleManager = null;
    _identityManager = null;
    _relayService = null;
    _locationService = null;
    _locationEventService = null;
    _pubkeyHex = null;

    // Signal to the foreground isolate that no publish cycle is in
    // flight. The foreground reads this flag on resume to know it is
    // safe to start its own publisher without violating the MLS
    // single-owner invariant.
    await _setIdle(true);
  }

  @override
  void onReceiveData(Object data) {
    // `onReceiveData` is the ONE dispatch point for everything sent to this
    // task, so anything added later must branch here rather than assume it is
    // reached. The probe reports whether it consumed the payload; today it is
    // the only sender, so an unconsumed payload has no other handler to reach.
    if (_livenessProbe.onData(data)) return;
    debugPrint('[BackgroundTask] unrouted task data: ${data.runtimeType}');
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  // ---------------------------------------------------------------------------
  // Publish cycle
  // ---------------------------------------------------------------------------

  /// Opens the circle manager, leaving `_circleManager` null on failure.
  ///
  /// Never throws: see the call site in [onStart] for why a failure here must
  /// not abort the rest of initialisation.
  Future<void> _openCircleManager() async {
    if (overrideCircleManager != null) {
      _circleManager = overrideCircleManager;
      return;
    }
    final dataDir = _dataDir;
    if (dataDir == null || !(_identityManager?.hasIdentity() ?? false)) return;
    try {
      // Re-fetched fresh rather than reusing the onStart copy (already
      // zeroized), and scrubbed again on the way out — Security Rule 9.
      //
      // `withFreshSecret` owns the `finally` that wipes it. Fetching into a
      // bare local, as this did, leaves the raw 32-byte nsec in the isolate's
      // Dart heap for the GC to relocate rather than erase. That mattered more
      // after this method gained a second caller: the reclaim path can run
      // every backoff window, so each attempt used to mint another copy that
      // was never wiped.
      _circleManager = await withFreshSecret(
        _identityManager!.getSecretBytes,
        (secret) => CircleManagerFfi.newInstance(
          dataDir: dataDir,
          identitySecretBytes: secret,
        ),
      );
    } on Object catch (e) {
      // Generic in the UI sense (Rule 8): the type alone, never the message,
      // which can carry MLS group ids or relay URLs.
      debugPrint(
        '[BackgroundTask] circle manager open failed: ${e.runtimeType}',
      );
    }
  }

  /// Creates the relay / location / event services if they are absent.
  ///
  /// Separated from [onStart] so it can be re-run. `NostrRelayService.initialize`
  /// rethrows, and in `onStart` that exception is caught only by the outer
  /// handler — which aborts the remaining steps. Because the manager is opened
  /// BEFORE this, a throw here used to leave the isolate holding the Rule-14
  /// guard with no circle service and no sharing service, and nothing could
  /// repair it: the recovery path keys off `_circleManager == null`, which is
  /// false in that state. The isolate then held the guard hostage — unusable
  /// itself and blocking the main isolate from opening — until the OS restarted
  /// the service.
  Future<void> _ensureAuxServices() async {
    if (_relayService == null) {
      final relay = overrideRelayService ?? NostrRelayService();
      // Assign only after a successful initialize, so a failed attempt leaves
      // the field null and the next cycle retries rather than reusing a
      // half-initialised service.
      await relay.initialize();
      _relayService = relay;
    }
    _locationService ??= overrideLocationService ?? GeolocatorLocationService();
    _locationEventService ??= LocationEventService();
  }

  /// Repairs an isolate that holds a manager but never finished wiring.
  ///
  /// Non-destructive: it touches no other isolate's session, so unlike a
  /// reclaim it needs no liveness gate.
  Future<bool> _repairSharingServices() async {
    try {
      await _ensureAuxServices();
    } on Object catch (e) {
      debugPrint('[BackgroundTask] service repair failed: ${e.runtimeType}');
      return false;
    }
    _wireSharingServices();
    return _locationSharingService != null;
  }

  /// Builds the circle + location-sharing services over the current manager.
  ///
  /// No-op when the manager is absent, so it is safe to call both from
  /// [onStart] and after a recovery.
  void _wireSharingServices() {
    if (overrideLocationSharingService != null) {
      _locationSharingService = overrideLocationSharingService;
      return;
    }
    if (_identityManager == null ||
        _circleManager == null ||
        _relayService == null) {
      return;
    }
    _circleService = NostrCircleService.withInjectedManager(
      relayService: _relayService!,
      injectedManager: _circleManager!,
    );
    _locationSharingService = LocationSharingService(
      circleService: _circleService!,
      relayService: _relayService!,
      identityService: BackgroundIdentityService(_identityManager!),
    );
  }

  /// Acquires a usable session, escalating only as far as the situation needs.
  ///
  /// # Why an open is tried before any reclaim
  ///
  /// The two are different problems and were conflated. A reclaim is for a
  /// guard held by an isolate that is GONE; it declines outright when the guard
  /// is free (`guardNotHeld`), because stopping or releasing anything would
  /// achieve nothing. But the normal path to this isolate owning a session is
  /// exactly that free case: the foreground hands the session over at pause, so
  /// by the time this runs there is usually nothing to reclaim — just something
  /// to open.
  ///
  /// Wiring the reclaim as the ONLY recovery therefore left the service
  /// declining to open a database that was sitting available, and background
  /// publishing stayed dead through the very handoff meant to enable it.
  ///
  /// The registry query comes first because it is cheap and side-effect-free.
  /// It is advisory — the guard can change state immediately after — but the
  /// acquire remains the authority and fails closed, so a lost race costs one
  /// cycle, never correctness.
  Future<bool> _ensureSession() async {
    final dataDir = _dataDir;
    if (dataDir == null) return false;

    final bool guardHeld;
    try {
      guardHeld = await _isSessionLive(dataDir: dataDir);
    } on Object catch (e) {
      // Cannot tell: do not open blind and do not escalate.
      debugPrint('[BackgroundTask] session query failed: ${e.runtimeType}');
      return false;
    }

    if (guardHeld) {
      // Someone else holds it. Only the reclaim path knows whether that is
      // recoverable, and it carries the gates that decide.
      return _attemptSessionReclaim();
    }

    // Free — the post-handoff steady state. Just take it.
    await _openCircleManager();
    if (_circleManager == null) return false;
    _wireSharingServices();
    if (_locationSharingService != null) {
      debugPrint('[BackgroundTask] session acquired');
      return true;
    }
    return _repairSharingServices();
  }

  /// Tries to recover from "the MLS session is held by an isolate that is
  /// gone".
  ///
  /// Returns `true` only if a usable `_circleManager` exists afterwards.
  ///
  /// # Why this is gated so heavily
  ///
  /// `forceReleaseLiveSession` stops the process-global live-sync engine. If
  /// the main isolate is actually ALIVE, that engine is ITS engine: the stream
  /// ends, nothing restarts it (`NostrSubscriptionService` registers no
  /// `onDone`), and the guard is still held by the main isolate's own handle —
  /// so the reclaim
  /// destroys live receive and gains nothing. Every gate below exists to make
  /// sure that case is excluded before the destructive call, and every one of
  /// them fails CLOSED (declining to reclaim) when it cannot get an answer.
  Future<bool> _attemptSessionReclaim() async {
    final dataDir = _dataDir;

    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      await prefs.reload();
    } on Object catch (e) {
      debugPrint(
        '[BackgroundTask] reclaim: prefs unavailable (${e.runtimeType})',
      );
      return false;
    }

    // Is the guard actually held? Asked of the registry, never by classifying
    // an error string: Haven's FFI errors interpolate remote-authored text (a
    // circle admin controls the group's routing relays, and the relay gate
    // formats a rejected URL into its message), so a substring test would let a
    // remote party trigger this path at will.
    bool guardHeld = false;
    if (dataDir != null) {
      try {
        guardHeld = await _isSessionLive(dataDir: dataDir);
      } on Object catch (e) {
        debugPrint(
          '[BackgroundTask] reclaim: liveness query failed (${e.runtimeType})',
        );
        return false;
      }
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final decision = evaluateSessionReclaimGates(
      hasDataDir: dataDir != null,
      hasIdentity:
          overrideHasIdentity ?? (_identityManager?.hasIdentity() ?? false),
      wipePending: prefs.getBool(kPendingMlsWipeKey) ?? false,
      guardHeld: guardHeld,
      lastAttemptMs: prefs.getInt(kBackgroundSessionReclaimAtMsKey),
      nowMs: nowMs,
      backoff: kBackgroundSessionReclaimBackoff,
    );
    if (decision != SessionReclaimDecision.proceed) {
      debugPrint('[BackgroundTask] reclaim: declined (${decision.name})');
      return false;
    }

    // Consume the backoff HERE — before the probe, not after it.
    //
    // Recording it only on the reclaim path (as an earlier version did) meant a
    // "main isolate alive" verdict never advanced the limit. That is the normal
    // steady state whenever a user backgrounds the app with sharing on: the
    // main isolate keeps its handle, so the open keeps failing and this runs on
    // EVERY 72-second tick, firing a full cross-isolate probe each time. Each
    // probe is an independent chance for a GC pause or a jank frame to look
    // like death, so hundreds of rolls per afternoon turn a rare misread into a
    // likely one. Consuming the limit unconditionally bounds the attempts —
    // and it keeps the original crash-safety property, since a crash between
    // here and the release still leaves the limit spent.
    try {
      await prefs.setInt(kBackgroundSessionReclaimAtMsKey, nowMs);
    } on Object catch (e) {
      debugPrint(
        '[BackgroundTask] reclaim: backoff write failed (${e.runtimeType})',
      );
      return false;
    }

    // The decisive gate: only a DEAD main isolate may be reclaimed from. The
    // foreground-active heartbeat cannot answer this (the Android pause path
    // writes 0 while keeping the session), so ask the isolate itself.
    //
    // Confirmed with a SECOND probe. One silent window can be a garbage
    // collection or a slow frame in an isolate that is perfectly alive, and
    // acting on that destroys its live receive. Two consecutive silences,
    // separated by a fresh round trip, are far harder to produce by transient
    // jank. Both fail closed to "alive".
    _livenessProbe.resetRound();
    if (await _livenessProbe.mainIsolateIsAlive(
      timeout: livenessProbeTimeout,
      channelReady: livenessChannelReady,
    )) {
      debugPrint('[BackgroundTask] reclaim: declined, main isolate alive');
      return false;
    }
    // Space the confirmation. Issued back-to-back the two probes observe one
    // contiguous window, so a single sustained stall — the main isolate blocked
    // on a sync FFI call while this isolate holds the same SQLCipher locks —
    // satisfies both, which is precisely what a confirmation is supposed to
    // rule out. A gap makes them independent samples.
    await Future<void>.delayed(livenessProbeGap);
    if (await _livenessProbe.mainIsolateIsAlive(
      timeout: livenessProbeTimeout,
      channelReady: livenessChannelReady,
    )) {
      debugPrint('[BackgroundTask] reclaim: declined, main isolate answered '
          'on retry');
      return false;
    }
    // A reply for EITHER probe, including one that landed after its own wait
    // elapsed, is proof of life. Both probes timing out is not the same as
    // nothing ever answering.
    if (_livenessProbe.sawRecentReply) {
      debugPrint('[BackgroundTask] reclaim: declined, late reply observed');
      return false;
    }

    // Re-check the guard after the probes. The window between the first query
    // and here is seconds wide, and if the holder released in the meantime
    // there is nothing to reclaim — just open.
    if (dataDir != null) {
      try {
        if (!await _isSessionLive(dataDir: dataDir)) {
          debugPrint('[BackgroundTask] reclaim: guard freed while probing');
          await _openCircleManager();
          if (_circleManager == null) return false;
          _wireSharingServices();
          return _locationSharingService != null;
        }
      } on Object catch (e) {
        debugPrint(
          '[BackgroundTask] reclaim: re-check failed (${e.runtimeType})',
        );
        return false;
      }
    }

    final ForceReleaseOutcomeFfi outcome;
    try {
      outcome = await _forceReleaseLiveSession();
    } on Object catch (e) {
      debugPrint(
        '[BackgroundTask] reclaim: release failed (${e.runtimeType})',
      );
      return false;
    }
    debugPrint('[BackgroundTask] reclaim: release outcome=${outcome.name}');
    // `StopTimedOut` means a supervisor task is still running and may still
    // hold the manager — the open would fail anyway, and retrying it would only
    // add noise. `NoSession` means the holder was never the engine (a leaked
    // handle this cannot reach), so the open will likely fail too; attempt it
    // once regardless, since the registry said the guard was held and this is
    // the cheapest way to learn whether it has since been released.
    if (outcome == ForceReleaseOutcomeFfi.stopTimedOut) return false;

    await _openCircleManager();
    if (_circleManager == null) return false;
    _wireSharingServices();
    if (_locationSharingService == null) return false;
    debugPrint('[BackgroundTask] reclaim: session recovered');
    return true;
  }

  /// The Rule-14 liveness query this handler uses: [overrideIsSessionLive] in
  /// tests, the real FFI [isSessionLive] otherwise. See
  /// [overrideIsSessionLive] for why this indirection exists.
  Future<bool> _isSessionLive({required String dataDir}) {
    final override = overrideIsSessionLive;
    if (override != null) return override(dataDir: dataDir);
    return isSessionLive(dataDir: dataDir);
  }

  /// The session-reclaim call this handler uses:
  /// [overrideForceReleaseLiveSession] in tests, the real FFI
  /// [forceReleaseLiveSession] otherwise.
  Future<ForceReleaseOutcomeFfi> _forceReleaseLiveSession() {
    final override = overrideForceReleaseLiveSession;
    if (override != null) return override();
    return forceReleaseLiveSession();
  }

  Future<void> _publishCycle(DateTime timestamp) async {
    try {
      // Per-circle jitter now lives in `_dueTracker` (step 7 below), so there
      // is no single cycle-wide jitter gate here — the master `onRepeatEvent`
      // cadence (`kBackgroundRepeatInterval`) is just the polling granularity.

      // 2. Abort if no identity is loaded. A MISSING MANAGER is no longer fatal
      //    here — it may be the recoverable "Rule-14 guard held by an isolate
      //    that is gone" case, which is retried below once the foreground gate
      //    has confirmed this isolate owns publishing.
      if (_pubkeyHex == null) return;

      // 3. Defer to the foreground UI isolate while it is active.
      //    BackgroundLocationManager.isForegroundActive() uses a
      //    timestamp-based staleness check: if the foreground was killed
      //    without cleaning up (OOM, force-stop), the stale timestamp is
      //    automatically expired after 2 * kBackgroundRepeatInterval (144 s).
      //    The default when the key has never been written is `true` so that
      //    a cold Android service auto-restart (before MapShell.initState
      //    writes the flag) does not race with whatever the foreground does
      //    next — BackgroundLocationManager.isForegroundActive() treats a
      //    null/missing key as `false`, but the explicit ?? true guard below
      //    protects the window before the first markForegroundActive write.
      //    The service stays running so it can take over the moment the
      //    foreground pauses, without re-incurring an Android 12+
      //    background-start that would be rejected for
      //    `FOREGROUND_SERVICE_LOCATION`.
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      // Fix 2: when the key has never been written (cold-start Android
      // auto-restart before MapShell.initState runs), assume the foreground
      // is active so the background doesn't race it. Once the foreground
      // writes the first timestamp on init/resume, normal staleness checks
      // apply via BackgroundLocationManager.isForegroundActive().
      final bool foregroundActive;
      if (prefs.getInt(kForegroundActiveAtMsKey) == null) {
        foregroundActive = true;
      } else {
        foregroundActive = await BackgroundLocationManager.isForegroundActive();
      }
      if (foregroundActive) {
        // The foreground owns publishing: keep NO per-circle schedule state so
        // that the moment the foreground goes inactive, every circle is seeded
        // "due now" (bounding the handoff gap to one background cycle).
        _dueTracker.pruneToKeys(<String>{});
        return;
      }

      // 3b. No manager? Try to recover the MLS session, but only from HERE —
      //     after the gate above has established the foreground is not
      //     publishing. Recovery stops the process-global live-sync engine, so
      //     running it from `onStart` (which executes regardless of foreground
      //     state) could tear down a session the visible UI is actively using.
      //     Placing it here inherits that decision from code that already owns
      //     it, rather than adding a second, parallel judgement of the same
      //     question. `_attemptSessionReclaim` adds the gates specific to the
      //     destructive step, including a direct liveness probe.
      if (_circleManager == null) {
        if (!await _ensureSession()) return;
      } else if (_locationSharingService == null) {
        // The manager opened but the wiring did not finish (see
        // `_ensureAuxServices`). No reclaim is warranted — this isolate already
        // owns the session — but without this the isolate would hold the
        // Rule-14 guard forever while publishing nothing.
        if (!await _repairSharingServices()) return;
      }

      // 6b. Play "disclosure before collection" — NEVER publish location from
      //     the background without both accepted disclosures.
      //
      //     The foreground publisher has always enforced the foreground flag
      //     (`location_publish_scheduler_provider.dart:214`); this path
      //     enforced NOTHING, so background publishing was strictly weaker than
      //     foreground publishing on the one consent gate Play requires. That
      //     asymmetry was invisible only because this isolate could not publish
      //     at all (CI_HARDENING_BACKLOG.md P0-1) — it would have become live
      //     the moment P0-1 was fixed, which is why the gate lands first.
      //
      //     BOTH flags are required, and the background one is the stricter,
      //     load-bearing half: it is the disclosure carrying the "even when the
      //     app is closed or not in use" sentence, which is exactly what this
      //     isolate does. Both paths that can enable background sharing already
      //     call `ensureDisclosed(includeBackground: true)` first
      //     (`location_settings_page.dart:64-68`,
      //     `create_identity_screen.dart:274-277`), so requiring them here is a
      //     no-op for every legitimately-enabled user and a fail-closed runtime
      //     enforcement of what is otherwise only a documented precondition on
      //     `BackgroundSharingNotifier.setEnabled`.
      //
      //     Reads the same `prefs` snapshot reloaded above (step 3), so it sees
      //     a revocation written by the UI isolate on the very next cycle.
      final foregroundDisclosed = prefs.getBool(kLocationDisclosureAcceptedKey);
      final backgroundDisclosed = prefs.getBool(
        kLocationDisclosureBackgroundAcceptedKey,
      );
      if (!backgroundPublishDisclosureAccepted(
        foregroundAccepted: foregroundDisclosed,
        backgroundAccepted: backgroundDisclosed,
      )) {
        debugPrint(
          '[BackgroundTask] Publish BLOCKED — location disclosure not '
          'accepted (foreground=$foregroundDisclosed, '
          'background=$backgroundDisclosed).',
        );
        return;
      }

      // 7. Get eligible circles. Uses the Dart-side `CircleService` so the same
      //    `Circle` value can be reused for the fetch step below — and applies
      //    the SAME eligibility filter as the foreground publisher
      //    (`filterPublishEligibleCircles`): accepted, not a pre-cutover
      //    orphan, not engine-blocked (Rule 8). (Previously it only filtered
      //    on `accepted`, so it kept retrying orphaned/blocked circles that can
      //    never succeed.)
      if (_circleService == null) return;
      final circles = await _circleService!.getVisibleCircles();
      final accepted = filterPublishEligibleCircles(circles, _circleService!);

      if (accepted.isEmpty) return;

      // Per-circle decorrelation: register each eligible circle on its OWN
      // CSPRNG-staggered due-time the first time we see it while owning
      // publishing, then publish only the circles whose own time has come.
      // Prune first so a left/blocked circle's schedule is dropped.
      //
      // The seed MUST be staggered, not shared. `pruneToKeys({})` above empties
      // the tracker on every cycle where the foreground owns publishing, so
      // this seed re-runs on EVERY foreground→background handoff — a shared
      // `timestamp` therefore made every circle due in the same instant on
      // every handoff, and the loop below then published them all inside one
      // wall-clock second, i.e. with one identical `created_at`.
      final eligibleKeys = <String>{
        for (final c in accepted) _bgCircleKey(c.nostrGroupId),
      };
      _dueTracker
        ..pruneToKeys(eligibleKeys)
        ..seedStaggered(eligibleKeys, timestamp, _stagger);

      // Select the circles whose own due-time falls inside this cycle's
      // stagger window, most-overdue first. The horizon (rather than a bare
      // `isDue(key, timestamp)`) is what lets a freshly staggered circle be
      // serviced by THIS cycle: `onRepeatEvent` is a 72 s poll, so anything
      // not picked up now waits a full interval.
      final byKey = <String, Circle>{
        for (final c in accepted) _bgCircleKey(c.nostrGroupId): c,
      };
      final dueKeys = _dueTracker.dueKeysUpTo(
        eligibleKeys,
        timestamp.add(kPublishStaggerMaxSpread),
      );

      // Nothing due this cycle → skip the GPS fix + publish entirely (battery:
      // no wake cost when no circle is scheduled).
      if (dueKeys.isEmpty) return;

      // 4. Acquire a GPS fix (only now that at least one circle is due).
      final position = await _locationService!.getCurrentLocation();

      // 8. Encrypt and publish to each DUE circle, one at a time and MORE THAN
      //    A SECOND APART.
      //
      //    Sequential alone is not enough. The engine stamps the outer
      //    kind-445 `created_at` from the inner app event's whole-second
      //    clock, so back-to-back publishes carry a byte-identical
      //    `created_at` — an equality inside the SIGNED event that links two
      //    circles to one device for anyone holding both, including from
      //    different relays or an archive. `onRepeatEvent` is a coarse 72 s
      //    poll, so independent per-circle due-times routinely land in the
      //    same cycle; the per-circle tracker cannot space them on its own.
      //
      //    Each circle therefore waits until the later of (a) its own due-time
      //    and (b) a fresh CSPRNG gap after the previous publish STARTED. The
      //    spread is budgeted: once the next slot would fall past the deadline
      //    the loop stops and leaves the rest due for the next master tick,
      //    rather than compressing the gaps back to zero.
      //
      //    Re-check foreground ownership immediately before each
      //    encryptLocation call: the user can resume during any of the
      //    preceding awaits (GPS fix, circle fetch, decorrelation wait). If the
      //    foreground reclaimed ownership, break out rather than advancing an
      //    MLS epoch concurrently.
      var publishCount = 0;
      final publishPhaseStart = DateTime.now();
      final publishDeadline = publishPhaseStart.add(kPublishStaggerMaxSpread);
      DateTime? lastPublishStartedAt;
      for (final key in dueKeys) {
        final circle = byKey[key];
        if (circle == null) continue;

        final notBefore = nextBackgroundPublishSlot(
          dueAt: _dueTracker.dueAt(key),
          lastPublishStartedAt: lastPublishStartedAt,
          gap: _stagger.sampleGap(totalPublishes: dueKeys.length),
          phaseStart: publishPhaseStart,
          deadline: publishDeadline,
        );
        if (notBefore == null) {
          debugPrint(
            '[BackgroundTask] Stagger budget spent — deferring the remaining '
            'due circle(s) to the next cycle.',
          );
          break;
        }
        final wait = notBefore.difference(DateTime.now());
        if (wait > Duration.zero) {
          await _sleepUnlessShuttingDown(wait);
          if (_shuttingDown) break;
        }

        // Fix 4: Re-check before each MLS epoch advance.
        if (await BackgroundLocationManager.isForegroundActive()) {
          debugPrint(
            '[BackgroundTask] Foreground reclaimed ownership mid-loop — '
            'aborting remaining circles.',
          );
          return;
        }
        lastPublishStartedAt = DateTime.now();

        try {
          final encrypted = await _circleManager!.encryptLocation(
            mlsGroupId: circle.mlsGroupId,
            senderPubkeyHex: _pubkeyHex!,
            latitude: position.latitude,
            longitude: position.longitude,
            updateIntervalSecs: BigInt.from(
              kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds,
            ),
          );

          await _relayService!.publishEvent(
            eventJson: encrypted.eventJson,
            relays: encrypted.relays,
          );

          // Re-arm THIS circle on its own fresh jittered cadence (independent
          // per circle — the decorrelation guarantee).
          _dueTracker.markPublished(
            _bgCircleKey(circle.nostrGroupId),
            DateTime.now(),
            _sampleJitteredInterval(),
          );
          publishCount++;
        } on Object catch (e) {
          debugPrint(
            '[BackgroundTask] Publish failed for circle: ${e.runtimeType}',
          );
        }
      }

      // 9. Fetch peer locations for each accepted circle. Piggybacks on
      //    the wake-up the publish step already paid for: the radio is
      //    awake, the relay WebSocket is open, and the GPS fix is
      //    cached. Without this, the SQLCipher last-known store grows
      //    stale during long backgrounded sessions and the foreground
      //    rehydrates to old data on resume.
      //
      //    Throttled to `kLocationUpdateInterval`: per-circle publish
      //    decorrelation makes "a circle is due" fire more often than the
      //    old single cycle-wide gate, but fetching ALL circles on every
      //    such wake would multiply the background relay round-trips by the
      //    circle count. Gating the fetch on its own ~nominal cadence keeps
      //    background fetch frequency (and battery) at parity with the
      //    pre-decorrelation behaviour regardless of how many circles the
      //    user is in.
      //
      //    Receiver-side auto-commit: `fetchMemberLocations` may
      //    publish + finalise an evolution event when MDK
      //    auto-commits a peer's `SelfRemove` proposal. The single-
      //    writer envelope (`_runCycleWithIdleTracking`) covers this
      //    full flow. If the auto-commit publish fails, the existing
      //    location service rolls back via `clearPendingCommit` and
      //    leaves the proposal un-seen for retry on the next cycle —
      //    we tolerate the failure here (catch + debugPrint per
      //    circle) and let the next cycle re-process the same proposal
      //    from a clean local epoch.
      var fetchCount = 0;
      final fetchDue = _lastBackgroundFetchAt == null ||
          timestamp.difference(_lastBackgroundFetchAt!) >=
              kLocationUpdateInterval;
      if (fetchDue && _locationSharingService != null) {
        _lastBackgroundFetchAt = timestamp;
        for (final circle in accepted) {
          if (await BackgroundLocationManager.isForegroundActive()) {
            debugPrint(
              '[BackgroundTask] Foreground reclaimed ownership before fetch '
              '— aborting remaining fetches.',
            );
            break;
          }
          try {
            await _locationSharingService!.fetchMemberLocations(circle: circle);
            fetchCount++;
          } on Object catch (e) {
            debugPrint(
              '[BackgroundTask] Fetch failed for circle: ${e.runtimeType}',
            );
          }
        }
      }

      // 10. Persist the publish timestamp for cross-isolate coordination.
      final now = DateTime.now();
      await BackgroundLocationManager.writeLastPublishTime(now);

      // 11. Periodic prune of expired last-known rows. Hourly cadence
      //     mirrors the foreground `_pruneTimer`; both are idempotent
      //     because `prune_expired_last_known` is a single SQLite
      //     DELETE under a per-instance Mutex<Connection>.
      _cyclesSinceLastPrune++;
      if (_cyclesSinceLastPrune >= _cyclesPerPrune &&
          _circleService != null &&
          !await BackgroundLocationManager.isForegroundActive()) {
        _cyclesSinceLastPrune = 0;
        try {
          final removed = await _circleService!.pruneExpiredLastKnown();
          debugPrint('[BackgroundTask] Pruned $removed expired row(s).');
        } on Object catch (e) {
          debugPrint('[BackgroundTask] Prune failed: ${e.runtimeType}');
        }
        try {
          await _circleService!.pruneProcessedGiftWraps();
        } on Object catch (e) {
          debugPrint(
            '[BackgroundTask] pruneProcessedGiftWraps failed: ${e.runtimeType}',
          );
        }
      }

      // Per-circle next-publish times were re-armed inline (markPublished) as
      // each due circle published — there is no single cycle-wide reschedule.
      debugPrint(
        '[BackgroundTask] Published to $publishCount/${dueKeys.length} due '
        'circle(s) (${accepted.length} eligible), fetched '
        '$fetchCount/${accepted.length} circle(s).',
      );
    } on Object catch (e) {
      debugPrint('[BackgroundTask] Publish cycle FAILED: ${e.runtimeType}');
      // Per-circle schedules re-arm on the next successful publish; a failed
      // cycle leaves due circles due, so the next master tick retries them.
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Waits [d], or returns early the moment [onDestroy] starts.
  ///
  /// A decorrelation gap must never become a teardown stall. `onDestroy`
  /// completes [_shutdownSignal] before it awaits the in-flight cycle, so the
  /// worst this costs a stopping service is the publish already under way.
  ///
  /// The losing `Future.delayed` timer is left to expire on its own — it holds
  /// nothing but a timer slot in an isolate that is being torn down anyway,
  /// and cancelling it would need a `Timer` handle this call has no other use
  /// for.
  Future<void> _sleepUnlessShuttingDown(Duration d) async {
    if (d <= Duration.zero || _shuttingDown) return;
    await Future.any<void>(<Future<void>>[
      Future<void>.delayed(d),
      _shutdownSignal.future,
    ]);
  }

  /// Test seam for [_sleepUnlessShuttingDown].
  ///
  /// The publish cycle it lives in is bridge-bound (it drives `CircleManagerFfi`
  /// directly, so `flutter test` cannot reach it), but the cancellability of
  /// the wait is exactly the property that keeps a decorrelation gap from
  /// becoming a teardown stall — so it is reachable on its own.
  @visibleForTesting
  Future<void> staggerWaitForTest(Duration d) => _sleepUnlessShuttingDown(d);

  /// Test seam for [_ensureSession].
  ///
  /// `_ensureSession` and `_attemptSessionReclaim` are otherwise reachable
  /// only through [onRepeatEvent], which is gated behind the FFI-bound
  /// identity load in [onStart] — unreachable under `flutter test`. Setting
  /// [_dataDir] here (never reachable from a test otherwise, since it is
  /// private) is what lets the guard/backoff/probe machinery run against the
  /// `override*` seams above without a device.
  @visibleForTesting
  Future<bool> ensureSessionForTest({required String dataDir}) {
    _dataDir = dataDir;
    return _ensureSession();
  }

  /// Samples a jittered publish interval via the Rust CSPRNG.
  int _sampleJitteredInterval() {
    try {
      return _locationEventService!
          .jitteredPublishIntervalSecs(nominalSecs: _nominalSecsBigInt)
          .toInt();
    } on Object catch (_) {
      // Fallback to nominal on FFI error.
      return kLocationUpdateInterval.inSeconds;
    }
  }

  /// Hex-encodes a `nostrGroupId` for use as a per-circle due-tracker key.
  /// Matches the foreground `_circleKey` / `LocationSharingService._circleKey`
  /// convention (the public `#h` value — never the real MLS group id, Rule 4).
  static String _bgCircleKey(List<int> nostrGroupId) =>
      nostrGroupId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
