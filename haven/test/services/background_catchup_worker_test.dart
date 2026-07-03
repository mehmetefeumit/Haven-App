/// Unit tests for the M7-C WorkManager background catch-up worker logic.
///
/// Tests verify:
///
/// (1) **Disabled-intent early return**: when `isBackgroundSharingEnabled()`
///     returns false, `runBackgroundCatchupTask` returns true and the
///     `runCatchup` stub is NEVER called (no relay/FFI activity after opt-out).
///
/// (2) **FGS-alive fast-path**: when sharing is enabled but the FGS is
///     running, `runBackgroundCatchupTask` returns true and `runCatchup`
///     is NEVER called (battery optimisation: FGS already covers receive).
///
/// (3) **Normal sweep**: when sharing is enabled AND the FGS is not running,
///     `runCatchup` IS called and the task returns true.
///
/// (4) **Catch-up failure → false**: when `runCatchup` throws,
///     `runBackgroundCatchupTask` returns false (signals WorkManager to
///     apply back-off policy).
///
/// (5) **Sharing-check failure → clean no-op (true)**: when
///     `isBackgroundSharingEnabled()` throws, the task returns true
///     (fail-safe: treat unknown as disabled, no relay activity).
///
/// (6) **FGS-check failure → proceeds to sweep**: when `isRunningService()`
///     throws, the task still attempts the sweep (conservative: let the
///     Rust WRITER_LOCK serialize concurrent access safely).
///
/// (7) **disableBackgroundScheduling cancels WorkManager (M7-C wiring)**:
///     `BackgroundLocationManager.disableBackgroundScheduling` must call
///     `cancelBackgroundCatchup`, which is wired at the M7-C extension
///     point. Verified by observable effect: the method completes normally
///     on non-Android (no MissingPluginException propagates) AND clears
///     the expected SharedPreferences coordination keys.
///
/// These tests are purely unit-level (no WorkManager runtime, no platform
/// channels). `runBackgroundCatchupTask` takes injected fakes for all
/// platform interactions.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/background_catchup_worker.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds the injection tuple for [runBackgroundCatchupTask].
typedef _InjectedTask = ({
  Future<bool> Function() isBackgroundSharingEnabled,
  Future<bool> Function() isRunningService,
  Future<void> Function() runCatchup,
  List<String> calls, // records which steps were reached
});

_InjectedTask _makeTask({
  bool sharingEnabled = true,
  bool throwOnSharingCheck = false,
  bool fgsRunning = false,
  bool throwOnFgsCheck = false,
  bool catchupThrows = false,
}) {
  final calls = <String>[];
  return (
    isBackgroundSharingEnabled: () async {
      calls.add('sharingCheck');
      if (throwOnSharingCheck) throw StateError('prefs unavailable');
      return sharingEnabled;
    },
    isRunningService: () async {
      calls.add('fgsCheck');
      if (throwOnFgsCheck) throw StateError('channel unavailable');
      return fgsRunning;
    },
    runCatchup: () async {
      calls.add('catchup');
      if (catchupThrows) throw StateError('FFI error');
    },
    calls: calls,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // (1) Sharing disabled → early return, no catch-up
  // ---------------------------------------------------------------------------
  group('runBackgroundCatchupTask — (1) sharing disabled', () {
    test(
      'returns true and does NOT call runCatchup when sharing is disabled',
      () async {
        final t = _makeTask(sharingEnabled: false);

        final result = await runBackgroundCatchupTask(
          isBackgroundSharingEnabled: t.isBackgroundSharingEnabled,
          isRunningService: t.isRunningService,
          runCatchup: t.runCatchup,
        );

        expect(
          result,
          isTrue,
          reason:
              'Clean no-op must return true (not false, which signals retry) '
              'when the user has disabled background sharing',
        );
        expect(
          t.calls,
          ['sharingCheck'],
          reason:
              'Must exit after the intent re-check — must NOT reach fgsCheck '
              'or runCatchup',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // (2) FGS alive → fast-path bail, no catch-up
  // ---------------------------------------------------------------------------
  group('runBackgroundCatchupTask — (2) FGS alive', () {
    test(
      'returns true and does NOT call runCatchup when FGS is running',
      () async {
        final t = _makeTask(fgsRunning: true);

        final result = await runBackgroundCatchupTask(
          isBackgroundSharingEnabled: t.isBackgroundSharingEnabled,
          isRunningService: t.isRunningService,
          runCatchup: t.runCatchup,
        );

        expect(
          result,
          isTrue,
          reason:
              'FGS alive is a battery fast-path bail — task returns true '
              'because the FGS already covers receive',
        );
        expect(
          t.calls,
          ['sharingCheck', 'fgsCheck'],
          reason:
              'Must reach sharingCheck and fgsCheck but NOT runCatchup',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // (3) Sharing enabled, FGS not running → sweep runs
  // ---------------------------------------------------------------------------
  group('runBackgroundCatchupTask — (3) normal sweep', () {
    test(
      'calls runCatchup and returns true when sharing is on and FGS is dead',
      () async {
        final t = _makeTask();

        final result = await runBackgroundCatchupTask(
          isBackgroundSharingEnabled: t.isBackgroundSharingEnabled,
          isRunningService: t.isRunningService,
          runCatchup: t.runCatchup,
        );

        expect(result, isTrue);
        expect(
          t.calls,
          ['sharingCheck', 'fgsCheck', 'catchup'],
          reason:
              'All three steps must run when sharing is enabled and the '
              'FGS is not running',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // (4) Catch-up throws → returns false (signal WorkManager back-off)
  // ---------------------------------------------------------------------------
  group('runBackgroundCatchupTask — (4) catch-up failure', () {
    test('returns false when runCatchup throws', () async {
      final t = _makeTask(catchupThrows: true);

      final result = await runBackgroundCatchupTask(
        isBackgroundSharingEnabled: t.isBackgroundSharingEnabled,
        isRunningService: t.isRunningService,
        runCatchup: t.runCatchup,
      );

      expect(
        result,
        isFalse,
        reason:
            'A catch-up failure must return false to signal WorkManager '
            'to apply its back-off policy at the next window',
      );
      expect(t.calls.contains('catchup'), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // (5) Sharing-check throws → clean no-op (true), no catch-up
  // ---------------------------------------------------------------------------
  group('runBackgroundCatchupTask — (5) sharing-check failure (fail-safe)', () {
    test(
      'returns true and does NOT call runCatchup when sharingCheck throws',
      () async {
        final t = _makeTask(throwOnSharingCheck: true);

        final result = await runBackgroundCatchupTask(
          isBackgroundSharingEnabled: t.isBackgroundSharingEnabled,
          isRunningService: t.isRunningService,
          runCatchup: t.runCatchup,
        );

        expect(
          result,
          isTrue,
          reason:
              'Fail-safe: a corrupt SharedPreferences must not accidentally '
              'enable background relay activity after opt-out. Return true '
              '(not false) to avoid an infinite retry loop.',
        );
        expect(
          t.calls.contains('catchup'),
          isFalse,
          reason: 'runCatchup must NOT be called when the intent check fails',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // (6) FGS-check throws → proceeds to sweep (conservative)
  // ---------------------------------------------------------------------------
  group('runBackgroundCatchupTask — (6) FGS-check failure', () {
    test('proceeds to runCatchup when isRunningService throws', () async {
      final t = _makeTask(throwOnFgsCheck: true);

      final result = await runBackgroundCatchupTask(
        isBackgroundSharingEnabled: t.isBackgroundSharingEnabled,
        isRunningService: t.isRunningService,
        runCatchup: t.runCatchup,
      );

      expect(
        result,
        isTrue,
        reason:
            'When the FGS check fails we cannot determine liveness, so we '
            'proceed conservatively to the sweep — the Rust WRITER_LOCK '
            'serializes concurrent access safely.',
      );
      expect(
        t.calls.contains('catchup'),
        isTrue,
        reason: 'runCatchup must be attempted even when the FGS-check throws',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // (7) disableBackgroundScheduling cancels WorkManager (M7-C wiring)
  //
  // We verify the observable effects of the wiring:
  //   (a) The method completes normally (best-effort; WorkManager's
  //       MissingPluginException from the test environment is absorbed
  //       by the try/catch inside disableBackgroundScheduling).
  //   (b) The coordination SharedPreferences keys are still cleared.
  //
  // We cannot directly assert that cancelBackgroundCatchup() was called
  // (it's a module-level function, not injectable here), but we can verify
  // the surrounding contract: the overall teardown still succeeds and clears
  // the keys it is responsible for. The workmanager channel is not registered
  // in the test environment — the test relies on the existing try/catch in
  // disableBackgroundScheduling swallowing that error.
  // ---------------------------------------------------------------------------
  group(
    'disableBackgroundScheduling (M7-C) — WorkManager cancel is wired',
    () {
      test(
        'completes normally and clears coordination keys even in test env',
        () async {
          // Seed both coordination keys with non-trivial values.
          // Must be called inside the test body so the mock is active when
          // disableBackgroundScheduling() calls
          // SharedPreferences.getInstance().
          SharedPreferences.setMockInitialValues({
            kBackgroundIdleKey: false,
            kForegroundActiveAtMsKey: DateTime.now().millisecondsSinceEpoch,
            'some.unrelated.key': 99,
          });

          // Await directly (not via expectLater+returnsNormally — that matcher
          // does not await the returned Future for async functions).
          // disableBackgroundScheduling() calls cancelBackgroundCatchup().
          // On Linux (non-Android), cancelBackgroundCatchup() returns early
          // without hitting the WorkManager channel, so no
          // MissingPluginException is thrown here.
          await BackgroundLocationManager.disableBackgroundScheduling();

          final prefs = await SharedPreferences.getInstance();
          expect(
            prefs.containsKey(kBackgroundIdleKey),
            isFalse,
            reason:
                'disableBackgroundScheduling must clear kBackgroundIdleKey '
                'as part of the M7-C teardown',
          );
          expect(
            prefs.containsKey(kForegroundActiveAtMsKey),
            isFalse,
            reason:
                'disableBackgroundScheduling must clear '
                'kForegroundActiveAtMsKey as part of the M7-C teardown',
          );
          // Unrelated key must survive.
          expect(prefs.getInt('some.unrelated.key'), 99);
        },
      );

      test(
        'is idempotent — calling twice does not throw',
        () async {
          // Seed empty prefs — keys already absent; must not throw.
          SharedPreferences.setMockInitialValues({});
          await BackgroundLocationManager.disableBackgroundScheduling();
          // Second call with absent keys must also complete without error.
          await BackgroundLocationManager.disableBackgroundScheduling();
        },
      );
    },
  );
}
