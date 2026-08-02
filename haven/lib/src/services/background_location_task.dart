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
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/per_circle_due_tracker.dart';
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
class BackgroundLocationTaskHandler extends TaskHandler {
  CircleManagerFfi? _circleManager;
  NostrIdentityManager? _identityManager;
  NostrRelayService? _relayService;
  GeolocatorLocationService? _locationService;
  LocationEventService? _locationEventService;
  NostrCircleService? _circleService;
  LocationSharingService? _locationSharingService;
  String? _pubkeyHex;

  /// In-flight publish future, tracked so `onDestroy` can await it
  /// rather than nulling services mid-cycle.
  Future<void>? _inFlightPublish;

  /// Independent per-circle publish scheduling (privacy: decorrelation). Each
  /// circle is registered "due now" when the background first owns publishing,
  /// then re-armed on its OWN jittered cadence, so a relay can't correlate a
  /// device's circles by co-timing. Cleared whenever the foreground owns
  /// publishing so the handoff back re-seeds every circle due-now (bounding the
  /// inter-publish gap to one cycle).
  final PerCircleDueTracker _dueTracker = PerCircleDueTracker();

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
      //    site already gates on `_pubkeyHex == null || _circleManager ==
      //    null` and no-ops, matching the pre-migration no-identity
      //    behaviour.
      if (overrideCircleManager != null) {
        _circleManager = overrideCircleManager;
      } else if (_identityManager!.hasIdentity()) {
        // Re-fetched fresh rather than reusing `bytes` above (already
        // zeroized) — Security Rule 9.
        final identitySecretBytes = await _identityManager!.getSecretBytes();
        _circleManager = await CircleManagerFfi.newInstance(
          dataDir: dataDir,
          identitySecretBytes: identitySecretBytes,
        );
      }

      // 6. Create relay, location, and jitter services.
      _relayService = overrideRelayService ?? NostrRelayService();
      await _relayService!.initialize();
      _locationService = overrideLocationService ?? GeolocatorLocationService();
      _locationEventService = LocationEventService();

      // 7. Construct circle + location-sharing services so the background
      //    isolate can fetch peer locations alongside publishing. The
      //    circle service shares the existing CircleManagerFfi to avoid
      //    spawning a second MLS state cache over the same DB. The
      //    identity adapter only exposes pubkey hex — secret material
      //    stays inside the underlying NostrIdentityManager.
      if (overrideLocationSharingService != null) {
        _locationSharingService = overrideLocationSharingService;
      } else if (_identityManager != null && _circleManager != null) {
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
    // Runs BEFORE `_publishCycle`, which returns immediately while
    // `_circleManager == null` — the P0-1 steady state, and precisely the state
    // whose recoverability the probe exists to measure. Compiled out unless the
    // probe dart-define is set.
    await _probeSessionAvailability();

    await _setIdle(false);
    try {
      await _publishCycle(timestamp);
    } finally {
      _inFlightPublish = null;
      await _setIdle(true);
    }
  }

  /// Whether the P0-1 session-availability probe is compiled in.
  ///
  /// Build-time only, defaults OFF, and additionally `#[cfg]`-equivalent gated
  /// on debug via [kDebugMode] at the call site — a release binary can never
  /// run it. Set with
  /// `--dart-define=HAVEN_P0_1_PROBE=true` for the experiment described in
  /// `docs/P0_1_FGS_SESSION_PLAN.md` §2, and delete both this flag and
  /// [_probeSessionAvailability] once that question is answered.
  static const bool _p0_1ProbeEnabled = bool.fromEnvironment(
    'HAVEN_P0_1_PROBE',
  );

  /// Verbatim prefix the probe's runner greps for. Keep in sync with
  /// `tooling/e2e/ci/run-p0-1-session-probe.sh`.
  static const String _probeMarker = '[P0-1-PROBE]';

  /// Answers ONE question: can this isolate open the MLS database right now?
  ///
  /// The P0-1 fix plan proposes that the foreground service stop opening its
  /// own session and instead route work to the main isolate, falling back to
  /// opening one itself when no main isolate exists (a cold service start).
  /// Two independent reviews argued that fallback can never succeed, because
  /// the Rule-14 guard is held by an `Arc` inside a Rust process-global
  /// (`static SESSION`, the live-sync engine) that OUTLIVES the main isolate:
  /// when the Activity is destroyed the routing target dies while the guard
  /// stays held, so there is nobody to route to AND no way to acquire.
  ///
  /// If that is right, the routing design is unbuildable as specified and the
  /// architecture must change. This probe settles it empirically instead of by
  /// argument, and it is deliberately the smallest possible instrument.
  ///
  /// ## Why it disposes immediately
  ///
  /// On success this would OWN the guard, and holding it would (a) change the
  /// very state being measured, and (b) lock the foreground out on the user's
  /// next launch with no recovery path — the mirror image of P0-1. Acquire,
  /// record, release. The probe must never leave the process in a state it
  /// did not find it in.
  ///
  /// ## Why it does not log the raw error
  ///
  /// Only the Rule-14 rejection is a fixed, content-free literal. The other
  /// failure modes at this call site (identity decode, keyring, SQLCipher)
  /// carry upstream text that is not ours and is not known-safe (Rule 8), so
  /// the outcome is CLASSIFIED into a closed set and only the classification
  /// is printed.
  Future<void> _probeSessionAvailability() async {
    if (!_p0_1ProbeEnabled || !kDebugMode) return;
    final identity = _identityManager;
    if (identity == null) {
      debugPrint('$_probeMarker SKIPPED — no identity loaded in this isolate.');
      return;
    }

    CircleManagerFfi? probe;
    try {
      final dataDir = await const PathProviderDataDirectory()
          .getDataDirectory();
      // Re-fetched per use rather than held (Security Rule 9) and zeroed below.
      final secretBytes = await identity.getSecretBytes();
      try {
        probe = await CircleManagerFfi.newInstance(
          dataDir: dataDir,
          identitySecretBytes: secretBytes,
        );
      } finally {
        secretBytes.fillRange(0, secretBytes.length, 0);
      }
      debugPrint(
        '$_probeMarker ACQUIRED — the MLS guard was FREE from this isolate. '
        'A cold-start fallback CAN open a session here.',
      );
    } on Object catch (e) {
      // The Rule-14 message is a fixed literal in
      // `haven-core/src/nostr/mls/storage.rs` and carries no path or secret;
      // matching it is what lets the probe distinguish "someone holds the
      // guard" from "the open failed for an unrelated reason".
      final blockedByRule14 = e.toString().contains(
        'already open on this database',
      );
      debugPrint(
        '$_probeMarker REFUSED rule14=$blockedByRule14 '
        'type=${e.runtimeType} — the MLS guard is HELD by another live '
        'session in this process.',
      );
    } finally {
      // Never hold what we only came to measure.
      probe?.dispose();
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
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  // ---------------------------------------------------------------------------
  // Publish cycle
  // ---------------------------------------------------------------------------

  Future<void> _publishCycle(DateTime timestamp) async {
    try {
      // Per-circle jitter now lives in `_dueTracker` (step 7 below), so there
      // is no single cycle-wide jitter gate here — the master `onRepeatEvent`
      // cadence (`kBackgroundRepeatInterval`) is just the polling granularity.

      // 2. Abort if no identity is loaded.
      if (_pubkeyHex == null || _circleManager == null) return;

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

      // Per-circle decorrelation: register each eligible circle "due now" the
      // first time we see it while owning publishing, then publish only the
      // circles whose own independent jittered time has come. Prune first so a
      // left/blocked circle's schedule is dropped.
      final eligibleKeys = <String>{
        for (final c in accepted) _bgCircleKey(c.nostrGroupId),
      };
      _dueTracker.pruneToKeys(eligibleKeys);
      for (final key in eligibleKeys) {
        _dueTracker.seedIfAbsent(key, timestamp);
      }
      final dueCircles = accepted
          .where(
            (c) => _dueTracker.isDue(_bgCircleKey(c.nostrGroupId), timestamp),
          )
          .toList();

      // Nothing due this cycle → skip the GPS fix + publish entirely (battery:
      // no wake cost when no circle is scheduled).
      if (dueCircles.isEmpty) return;

      // 4. Acquire a GPS fix (only now that at least one circle is due).
      final position = await _locationService!.getCurrentLocation();

      // 8. Encrypt and publish to each DUE circle (sequentially to avoid MLS
      //    epoch counter races across groups — different groups are independent
      //    but sequential is safer for DB locking). Re-check foreground
      //    ownership immediately before each encryptLocation call: the user can
      //    resume during any of the preceding awaits (GPS fix, circle fetch).
      //    If the foreground reclaimed ownership, break out rather than
      //    advancing an MLS epoch concurrently.
      var publishCount = 0;
      for (final circle in dueCircles) {
        // Fix 4: Re-check before each MLS epoch advance.
        if (await BackgroundLocationManager.isForegroundActive()) {
          debugPrint(
            '[BackgroundTask] Foreground reclaimed ownership mid-loop — '
            'aborting remaining circles.',
          );
          return;
        }

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
        '[BackgroundTask] Published to $publishCount/${dueCircles.length} due '
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
