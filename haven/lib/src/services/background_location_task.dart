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
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/background_identity_service.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Top-level callback required by [FlutterForegroundTask].
///
/// Must be annotated with `@pragma('vm:entry-point')` so the Dart
/// compiler does not tree-shake it. Registered in `main.dart`.
@pragma('vm:entry-point')
void backgroundCallback() {
  FlutterForegroundTask.setTaskHandler(BackgroundLocationTaskHandler());
}

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

  /// Next allowed publish time (jitter target).
  DateTime _nextPublishAt = DateTime.now();

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
  static const String _precisionStorageKey = 'haven.location_precision';

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

      // 4. Create the circle manager (opens the same SQLCipher DB).
      //    Tests inject a pre-built instance via [overrideCircleManager];
      //    only one CircleManagerFfi may exist per isolate or MLS state
      //    will diverge across two in-memory MDK caches.
      _circleManager =
          overrideCircleManager ??
          await CircleManagerFfi.newInstance(dataDir: dataDir);

      // 5. Create identity manager and load from secure storage.
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
      } else if (_identityManager != null) {
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

      // 8. Seed the jitter target from the last foreground publish time.
      final prefs = await SharedPreferences.getInstance();
      final lastMs = prefs.getInt(kBackgroundLastPublishMsKey);
      if (lastMs != null) {
        final lastPublish = DateTime.fromMillisecondsSinceEpoch(lastMs);
        final nextSecs = _sampleJitteredInterval();
        _nextPublishAt = lastPublish.add(Duration(seconds: nextSecs));
      }

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
      // 1. Jitter skip — wait until the sampled target time.
      if (timestamp.isBefore(_nextPublishAt)) return;

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
        // Reschedule so we don't immediately fire the moment the
        // foreground goes inactive — let the jitter window apply.
        _scheduleNext();
        return;
      }

      // 4. Read the precision preference from secure storage.
      final ffiLabel = await _readPrecisionFfiLabel();
      if (ffiLabel == null) {
        // Hidden mode — skip publishing entirely.
        _scheduleNext();
        return;
      }

      // 5. Acquire a GPS fix.
      final position = await _locationService!.getCurrentLocation();

      // 6. Read display name preference.
      final displayName = prefs.getString('haven.display_name.$_pubkeyHex');

      // 7. Get accepted circles. Uses the Dart-side `CircleService` so
      //    the same `Circle` value can be reused for the fetch step
      //    below — `LocationSharingService.fetchMemberLocations` requires
      //    the Dart abstraction (members + relays + nostrGroupId), not
      //    the FFI struct.
      if (_circleService == null) {
        _scheduleNext();
        return;
      }
      final circles = await _circleService!.getVisibleCircles();
      final accepted = circles
          .where((c) => c.membershipStatus == MembershipStatus.accepted)
          .toList();

      if (accepted.isEmpty) {
        _scheduleNext();
        return;
      }

      // 8. Encrypt and publish to each circle (sequentially to avoid
      //    MLS epoch counter races across groups — different groups are
      //    independent but sequential is safer for DB locking).
      //    Re-check foreground ownership immediately before each
      //    encryptLocation call: the user can resume during any of the
      //    preceding awaits (precision read, GPS fix, getVisibleCircles).
      //    If the foreground reclaimed ownership, break out rather than
      //    advancing an MLS epoch concurrently.
      var publishCount = 0;
      for (final circle in accepted) {
        // Fix 4: Re-check before each MLS epoch advance.
        if (await BackgroundLocationManager.isForegroundActive()) {
          debugPrint(
            '[BackgroundTask] Foreground reclaimed ownership mid-loop — '
            'aborting remaining circles.',
          );
          _scheduleNext();
          return;
        }

        try {
          final encrypted = await _circleManager!.encryptLocation(
            mlsGroupId: circle.mlsGroupId,
            senderPubkeyHex: _pubkeyHex!,
            latitude: position.latitude,
            longitude: position.longitude,
            displayName: displayName,
            precisionLabel: ffiLabel,
            updateIntervalSecs: BigInt.from(
              kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds,
            ),
          );

          await _relayService!.publishEvent(
            eventJson: encrypted.eventJson,
            relays: encrypted.relays,
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
      if (_locationSharingService != null) {
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
      }

      // 12. Schedule next publish.
      _scheduleNext();

      debugPrint(
        '[BackgroundTask] Published to $publishCount/${accepted.length}, '
        'fetched $fetchCount/${accepted.length} circle(s), next in '
        '${_nextPublishAt.difference(DateTime.now()).inSeconds}s',
      );
    } on Object catch (e) {
      debugPrint('[BackgroundTask] Publish cycle FAILED: ${e.runtimeType}');
      // Schedule next attempt even on failure.
      _scheduleNext();
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

  /// Schedules the next publish at a jittered offset from now.
  void _scheduleNext() {
    final nextSecs = _sampleJitteredInterval();
    _nextPublishAt = DateTime.now().add(Duration(seconds: nextSecs));
  }

  /// Reads the precision preference and maps it to the Rust FFI label.
  ///
  /// Returns `null` for stealth mode ("hidden").
  Future<String?> _readPrecisionFfiLabel() async {
    final raw = await _secureStorage.read(key: _precisionStorageKey);
    // Default to 'neighborhood' → 'Standard' if unset.
    final levelName = raw ?? 'neighborhood';
    return privacyLevelToFfiLabel(levelName);
  }

  /// Maps a `PrivacyLevel.name` string to the Rust `LocationPrecision` label.
  ///
  /// Mirrors the `ffiLabel` extension in the foreground isolate without
  /// depending on the widget library.
  ///
  /// Exposed for testing via `@visibleForTesting`. Do not call from
  /// production code outside this class — use the `ffiLabel` extension on
  /// `PrivacyLevel` in the foreground isolate instead.
  ///
  /// PRIVACY INVARIANT: `'hidden'` MUST return `null`. Any non-null return
  /// value causes the background task to publish the user's location. Callers
  /// must check for `null` and suppress publishing when this method returns it.
  @visibleForTesting
  static String? privacyLevelToFfiLabel(String levelName) {
    return switch (levelName) {
      'exact' => 'Enhanced',
      'neighborhood' => 'Standard',
      'city' => 'Private',
      'hidden' => null,
      _ => 'Standard', // Safe default.
    };
  }
}
