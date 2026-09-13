// The scoped `Haven:publish` wake lock, from the Dart side of the channel.
//
// What can be proven here is the WIRE: which method is invoked, and the exact
// millisecond value that reaches the native handler. The native half — the
// PARTIAL_WAKE_LOCK itself, its `[1, 30_000]` coercion and its idempotent
// release — has no JVM test in this repo; it is held by
// `scripts/ci/check_android_location_power.sh` (checks 1-3),
// `test/lints/fgs_plugin_wake_lock_policy_test.dart` and the B1 e2e lane's
// `dumpsys power` oracle.
//
// The channel is the seam the foreground-service cycle tests use to order
// acquire/release against `encryptLocation` without a device, so it is exposed
// (`PublishWakeLock.channel`) rather than hidden behind an interface nothing
// else would implement.
@TestOn('vm')
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/publish_wake_lock.dart';

import '../helpers/log_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PublishWakeLock', () {
    const wakeLock = PublishWakeLock();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];

    tearDown(() {
      messenger.setMockMethodCallHandler(PublishWakeLock.channel, null);
      calls.clear();
    });

    void mock([Future<Object?>? Function(MethodCall call)? handler]) {
      messenger.setMockMethodCallHandler(PublishWakeLock.channel, (call) async {
        calls.add(call);
        return handler?.call(call);
      });
    }

    test('acquire forwards the timeout in ms', () async {
      mock();

      await wakeLock.acquire();

      expect(calls.single.method, 'acquire');
      expect(calls.single.arguments, kPublishWakeLockTimeout.inMilliseconds);
    });

    test('acquire forwards a shorter timeout unchanged', () async {
      mock();

      await wakeLock.acquire(timeout: const Duration(seconds: 5));

      expect(calls.single.arguments, 5000);
    });

    test('acquire never asks for more than kPublishWakeLockTimeout', () async {
      mock();

      // The native handler coerces into `[1, MAX_TIMEOUT_MS]` and is the
      // authority; this cap is the Dart half, so a caller that outgrows the
      // constant is capped on both sides rather than silently on one.
      await wakeLock.acquire(timeout: const Duration(minutes: 5));

      expect(calls.single.arguments, kPublishWakeLockTimeout.inMilliseconds);
    });

    test('release invokes the native release', () async {
      mock();

      await wakeLock.release();

      expect(calls.single.method, 'release');
      expect(calls.single.arguments, isNull);
    });

    test('every release is forwarded, never deduplicated in Dart', () async {
      // NOT idempotence: that is native and unobservable from here
      // (`PublishWakeLock.kt` releases under `if (it.isHeld)`, and the lock is
      // `setReferenceCounted(false)`), and it is pinned by
      // `check_android_location_power.sh` checks 1-3. What this pins is that
      // the Dart client keeps NO held-state of its own — the native lock, not
      // a cached bool that the native timeout can silently invalidate, decides
      // whether a release does anything.
      mock();

      await wakeLock.release();
      await wakeLock.release();

      expect(calls.map((c) => c.method), ['release', 'release']);
    });

    test('a missing channel is a no-op, not an error', () async {
      // No mock handler installed: every host test, and every iOS run, take
      // this path — the channel exists only in the foreground-service engine.
      await expectLater(wakeLock.acquire(), completes);
      await expectLater(wakeLock.release(), completes);
    });

    test('a PlatformException is swallowed on both methods', () async {
      mock((_) => throw PlatformException(code: 'boom'));

      // A failed acquire must never abort a publish cycle: the plugin's own
      // permanent lock is still the wake source in P2a, so the cycle is
      // correct without this lock, only less bounded.
      await expectLater(wakeLock.acquire(), completes);
      await expectLater(wakeLock.release(), completes);
    });

    test('a PlatformException is logged by CODE, never by message', () async {
      // Rule 8, on a boundary that carries native text: `PlatformException`'s
      // message on this channel is whatever `PowerManager` (or a future
      // handler) put there — a file path under /data/user/0, a package name,
      // a SecurityException's own prose. The code is a fixed vocabulary this
      // side chose, so it is the only half that can be logged.
      mock(
        (_) => throw PlatformException(
          code: 'WAKE_LOCK_DENIED',
          message: '/data/user/0/com.oblivioustech.haven denied Haven:publish',
        ),
      );
      final logged = LogCapture.install();

      await wakeLock.acquire();
      await wakeLock.release();

      expect(logged.lines, hasLength(2), reason: 'both methods report');
      logged.assertContains('WAKE_LOCK_DENIED');
      expect(
        logged.joined,
        isNot(contains('/data/user/0')),
        reason: 'the native message never reaches a log line, so it can never '
            'reach a bug report either',
      );
      logged.assertNoNeedles([
        '/data/user/0/com.oblivioustech.haven denied Haven:publish',
      ]);
    });

    test('an error that is not the channel saying no propagates', () async {
      // The complement of the two swallow tests, and the reason the catch
      // clauses are NAMED rather than `on Object`: MissingPluginException and
      // PlatformException mean "there is no lock here" and "the platform
      // refused", both of which a publish cycle is designed to shrug off.
      // Anything else is a defect in this isolate, and swallowing it here
      // would hide it once per publish cycle, forever, on the isolate with no
      // UI to notice.
      messenger.setMockMessageHandler(
        PublishWakeLock.channel.name,
        (_) => throw StateError('binary messenger is wedged'),
      );
      addTearDown(
        () => messenger.setMockMessageHandler(
          PublishWakeLock.channel.name,
          null,
        ),
      );

      await expectLater(wakeLock.acquire(), throwsStateError);
      await expectLater(wakeLock.release(), throwsStateError);
    });
  });
}
