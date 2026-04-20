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
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
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
  String? _pubkeyHex;

  /// In-flight publish future, tracked so `onDestroy` can await it
  /// rather than nulling services mid-cycle.
  Future<void>? _inFlightPublish;

  /// Next allowed publish time (jitter target).
  DateTime _nextPublishAt = DateTime.now();

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
  static const String _retentionStorageKey = 'haven.sender_retention_secs';

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
      _circleManager = await CircleManagerFfi.newInstance(dataDir: dataDir);

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
      _relayService = NostrRelayService();
      await _relayService!.initialize();
      _locationService = GeolocatorLocationService();
      _locationEventService = LocationEventService();

      // 7. Seed the jitter target from the last foreground publish time.
      final prefs = await SharedPreferences.getInstance();
      final lastMs = prefs.getInt(kBackgroundLastPublishMsKey);
      if (lastMs != null) {
        final lastPublish = DateTime.fromMillisecondsSinceEpoch(lastMs);
        final nextSecs = _sampleJitteredInterval();
        _nextPublishAt = lastPublish.add(Duration(seconds: nextSecs));
      }

      debugPrint(
        '[BackgroundTask] Initialized '
        '(identity=${_pubkeyHex != null ? "loaded" : "none"})',
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

      // 6. Read retention and display name preferences.
      final retentionSecs = await _readRetentionSecs();
      final displayName = prefs.getString('haven.display_name.$_pubkeyHex');

      // 7. Get accepted circles.
      final circles = await _circleManager!.getVisibleCircles();
      final accepted = circles
          .where((c) => c.membershipStatus == 'accepted')
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
      //    preceding awaits (precision read, GPS fix, retention read,
      //    getVisibleCircles). If the foreground reclaimed ownership,
      //    break out rather than advancing an MLS epoch concurrently.
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
            mlsGroupId: circle.circle.mlsGroupId,
            senderPubkeyHex: _pubkeyHex!,
            latitude: position.latitude,
            longitude: position.longitude,
            displayName: displayName,
            retentionSecs: BigInt.from(retentionSecs),
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

      // 9. Persist the publish timestamp for cross-isolate coordination.
      final now = DateTime.now();
      await BackgroundLocationManager.writeLastPublishTime(now);

      // 10. Schedule next publish.
      _scheduleNext();

      debugPrint(
        '[BackgroundTask] Published to $publishCount/${accepted.length} '
        'circle(s), next in '
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

  /// Reads the sender retention preference from secure storage.
  Future<int> _readRetentionSecs() async {
    final raw = await _secureStorage.read(key: _retentionStorageKey);
    if (raw == null) return 86400; // Default: 24 hours.
    return int.tryParse(raw) ?? 86400;
  }
}
