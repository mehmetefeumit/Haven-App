/// The scoped `Haven:publish` partial wake lock the Android foreground service
/// holds across one publish cycle (fix → encrypt → publish → ack → fetch).
///
/// The `flutter_foreground_task` plugin already holds a PERMANENT, untimed
/// `PARTIAL_WAKE_LOCK` for the whole background session, and Haven keeps it:
/// it is the only wake source for the no-fix watchdog (indoors on a GNSS-only
/// device, nothing else wakes the isolate) and for the "armed but never
/// delivered" recovery. So this lock saves nothing today. What it does is make
/// the CPU hold of a publish cycle Haven's own and bounded — every acquire
/// expires after [kPublishWakeLockTimeout] whatever Dart does next — so that
/// removing the permanent lock, once a replacement wake source is proven, is a
/// deletion rather than a redesign (`docs/POWER_EFFICIENCY_PLAN.md` D4).
///
/// Release is the CALLER's, from the cycle's own `finally` — and, once a stop
/// has been signalled, from the task's `onDestroy` `finally` INSTEAD, because
/// the drain abandons a publish that overruns its budget and that publish's
/// `finally` would otherwise land mid-teardown and, the lock being
/// `setReferenceCounted(false)`, drop the hold the rest of the teardown runs
/// under. Never from the plugin's Kotlin lifecycle listeners: they run before
/// Dart's `onDestroy` has begun draining.
///
/// The channel exists only inside the foreground-service Flutter engine
/// (`PublishWakeLock.kt`, registered from `HavenApplication.onCreate`). On the
/// UI isolate, on iOS and in host tests there is no handler, and every call is
/// a silent no-op.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:haven/src/constants/location.dart';

/// [MethodChannel] client for the native `Haven:publish` wake lock.
class PublishWakeLock {
  /// Creates a [PublishWakeLock].
  const PublishWakeLock();

  /// The platform channel shared with the native `PublishWakeLock` object.
  ///
  /// Exposed so the foreground-service cycle tests can order acquire/release
  /// against the encrypt and publish calls without a device.
  @visibleForTesting
  static const MethodChannel channel = MethodChannel(
    'haven.app/publish_wake_lock',
  );

  /// Holds the CPU awake for at most [timeout], re-posting the timer when the
  /// lock is already held (the native lock is not reference-counted).
  ///
  /// Await it before the first encrypt: the channel call is asynchronous, so
  /// only awaiting makes "acquired before the fix leaves the device" an order
  /// rather than a race.
  Future<void> acquire({Duration timeout = kPublishWakeLockTimeout}) {
    // The native side coerces into `[1, MAX_TIMEOUT_MS]` and is the authority
    // — Dart must not be able to ask for a longer hold than the constant. This
    // cap is the near half of the same bound, so an over-long request is
    // visible in the recorded call rather than only in `dumpsys power`.
    final ms = math.min(
      timeout.inMilliseconds,
      kPublishWakeLockTimeout.inMilliseconds,
    );
    return _invoke('acquire', ms);
  }

  /// Releases the lock if it is held. Idempotent, on both sides of the channel.
  Future<void> release() => _invoke('release', null);

  Future<void> _invoke(String method, Object? arguments) async {
    try {
      await channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Expected off the foreground-service engine (UI isolate, iOS, tests):
      // there is no lock to hold there, so this is not worth a log line per
      // publish cycle.
    } on PlatformException catch (e) {
      debugPrint('[PublishWakeLock] $method failed: ${e.code}');
    }
  }
}
