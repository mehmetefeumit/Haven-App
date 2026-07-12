/// Unit tests for the M7-C/M7-E WorkManager background catch-up worker logic.
///
/// Tests verify the full gate chain of `runBackgroundCatchupTask` (final
/// M7-E order per docs/M7_BACKGROUND_SHARING.md D2 + amendment A1):
///
///   gate 0 — compile-time flag (`backgroundCatchupEnabled`; rollback gate)
///   gate 1 — consent (durable-intent re-check, fail-CLOSED)
///   gate 2 — pending-MLS-wipe marker (M10.1, fail-CLOSED)
///   gate 3 — FGS alive (battery fast-path, fail-OPEN)
///   gate 4 — foreground active (battery fast-path, fail-OPEN)
///   then the receive-only sweep.
///
/// (0) **Flag off → no-op before anything**: `catchupEnabled: false` returns
///     true with ZERO closure calls — the rollback story (plan §7/A1) depends
///     on a flag-OFF build no-op'ing an already-registered periodic task.
///
/// (1) **Disabled-intent early return**: when `isBackgroundSharingEnabled()`
///     returns false, `runBackgroundCatchupTask` returns true and the
///     `runCatchup` stub is NEVER called (no relay/FFI activity after opt-out).
///
/// (2) **Pending-wipe gate**: when the M10.1 marker is set (or its read
///     throws), the task is a clean no-op ordered AFTER consent and BEFORE
///     the battery gates; the worker never attempts the wipe itself.
///
/// (3) **FGS-alive fast-path**: when sharing is enabled but the FGS is
///     running, `runBackgroundCatchupTask` returns true and `runCatchup`
///     is NEVER called (battery optimisation: FGS already covers receive).
///
/// (4) **Foreground-active fast-path**: FGS dead but the UI isolate is
///     active → skip (the map-shell pollers already receive); a read error
///     proceeds (fail-open — the WRITER_LOCK is the safety net).
///
/// (5) **Normal sweep + full order pin**: green path calls the gates in
///     exactly consent → wipe → FGS → foreground → catchup.
///
/// (6) **Catch-up failure → false**: when `runCatchup` throws,
///     `runBackgroundCatchupTask` returns false (signals WorkManager to
///     apply back-off policy).
///
/// (7) **Security-gate failures fail closed**: a throwing consent or wipe
///     check returns true (clean no-op) with no sweep.
///
/// (8) **Battery-gate failures fail open**: a throwing FGS or foreground
///     check proceeds to the sweep.
///
/// (9) **Marker-string pins (A10)**: the exported logcat marker consts are
///     pinned to the EXACT literals the e2e-m7-background CI lane greps —
///     drift here silently breaks the runtime-proof lane, so the pin fails
///     first.
///
/// (10) **disableBackgroundScheduling cancels WorkManager (M7-C wiring)**:
///     verified by observable effect (completes normally + clears the
///     coordination SharedPreferences keys).
///
/// These tests are purely unit-level (no WorkManager runtime, no platform
/// channels). `runBackgroundCatchupTask` takes injected fakes for all
/// platform interactions.
library;

import 'package:flutter/foundation.dart';
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
  Future<bool> Function() isPendingMlsWipe,
  Future<bool> Function() isRunningService,
  Future<bool> Function() isForegroundActive,
  Future<void> Function() runCatchup,
  List<String> calls, // records which steps were reached
});

_InjectedTask _makeTask({
  bool sharingEnabled = true,
  bool throwOnSharingCheck = false,
  bool wipePending = false,
  bool throwOnWipeCheck = false,
  bool fgsRunning = false,
  bool throwOnFgsCheck = false,
  bool foregroundActive = false,
  bool throwOnForegroundCheck = false,
  bool catchupThrows = false,
}) {
  final calls = <String>[];
  return (
    isBackgroundSharingEnabled: () async {
      calls.add('sharingCheck');
      if (throwOnSharingCheck) throw StateError('prefs unavailable');
      return sharingEnabled;
    },
    isPendingMlsWipe: () async {
      calls.add('wipeCheck');
      if (throwOnWipeCheck) throw StateError('prefs unavailable');
      return wipePending;
    },
    isRunningService: () async {
      calls.add('fgsCheck');
      if (throwOnFgsCheck) throw StateError('channel unavailable');
      return fgsRunning;
    },
    isForegroundActive: () async {
      calls.add('foregroundCheck');
      if (throwOnForegroundCheck) throw StateError('prefs unavailable');
      return foregroundActive;
    },
    runCatchup: () async {
      calls.add('catchup');
      if (catchupThrows) throw StateError('FFI error');
    },
    calls: calls,
  );
}

/// Invokes [runBackgroundCatchupTask] with the tuple's closures.
///
/// When [catchupEnabled] is null the parameter is OMITTED so the call binds
/// to the production default (`= backgroundCatchupEnabled`, the compile-time
/// const — `true` since M7-E).
Future<bool> _run(_InjectedTask t, {bool? catchupEnabled}) =>
    catchupEnabled == null
        ? runBackgroundCatchupTask(
            isBackgroundSharingEnabled: t.isBackgroundSharingEnabled,
            isPendingMlsWipe: t.isPendingMlsWipe,
            isRunningService: t.isRunningService,
            isForegroundActive: t.isForegroundActive,
            runCatchup: t.runCatchup,
          )
        : runBackgroundCatchupTask(
            isBackgroundSharingEnabled: t.isBackgroundSharingEnabled,
            isPendingMlsWipe: t.isPendingMlsWipe,
            isRunningService: t.isRunningService,
            isForegroundActive: t.isForegroundActive,
            runCatchup: t.runCatchup,
            catchupEnabled: catchupEnabled,
          );

/// Captures `debugPrint` output for the current test, restoring the original
/// in a tear-down. Returns the live log list.
List<String?> _captureDebugPrint() {
  final log = <String?>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) => log.add(message);
  addTearDown(() => debugPrint = original);
  return log;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // (0) Gate 0 — compile-time flag off → no-op BEFORE any other gate (A1)
  // ---------------------------------------------------------------------------
  group('runBackgroundCatchupTask — (0) gate 0 flag off (rollback gate)', () {
    test(
      'returns true with ZERO gate calls when catchupEnabled is false',
      () async {
        final log = _captureDebugPrint();
        final t = _makeTask();

        final result = await _run(t, catchupEnabled: false);

        expect(
          result,
          isTrue,
          reason:
              'Flag-off must be a clean no-op (true), not a retry (false) — '
              'a rolled-back build with a stale registered periodic task '
              'must not spin WorkManager back-off forever',
        );
        expect(
          t.calls,
          isEmpty,
          reason:
              'Gate 0 is FIRST (A1): a flag-off wake must exit before the '
              'consent read, before any prefs/platform-channel/FFI activity',
        );
        expect(
          log,
          contains(kCatchupWorkerFlagDisabledMarker),
          reason: 'Gate-0 exit must emit its presence-only logcat marker',
        );
      },
    );

    test(
      'the default binds to the compile-time const (true since M7-E): '
      'omitting catchupEnabled proceeds past gate 0',
      () async {
        final t = _makeTask();

        // No catchupEnabled argument → production default
        // (= backgroundCatchupEnabled). Since M7-E the const is true, so the
        // chain must reach the consent gate (and beyond).
        await _run(t);

        expect(
          t.calls,
          isNotEmpty,
          reason:
              'With backgroundCatchupEnabled == true (M7-E release state) '
              'the default-bound gate 0 must pass through to gate 1',
        );
        expect(t.calls.first, 'sharingCheck');
      },
    );
  });

  // ---------------------------------------------------------------------------
  // (1) Sharing disabled → early return, no catch-up
  // ---------------------------------------------------------------------------
  group('runBackgroundCatchupTask — (1) sharing disabled', () {
    test(
      'returns true and does NOT call runCatchup when sharing is disabled',
      () async {
        final log = _captureDebugPrint();
        final t = _makeTask(sharingEnabled: false);

        final result = await _run(t);

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
              'Must exit after the intent re-check — must NOT reach the '
              'wipe/FGS/foreground checks or runCatchup',
        );
        expect(
          log,
          contains(kCatchupWorkerConsentDisabledMarker),
          reason:
              'Gate-1 exit must emit the exact marker Phase C2 of the '
              'e2e-m7-background lane polls for',
        );
      },
    );

    test(
      'consent disabled AND wipe pending → exits at consent (gate 1 first)',
      () async {
        final t = _makeTask(sharingEnabled: false, wipePending: true);

        final result = await _run(t);

        expect(result, isTrue);
        expect(
          t.calls,
          ['sharingCheck'],
          reason:
              'Gate 1 (consent) stays FIRST among the runtime gates: the '
              'wipe check must never run when the user has opted out',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // (2) Pending-MLS-wipe marker (M10.1) — gate 2, fail-closed
  // ---------------------------------------------------------------------------
  group('runBackgroundCatchupTask — (2) pending-wipe gate (M10.1)', () {
    test(
      'marker set → returns true; FGS/foreground checks and runCatchup '
      'never called',
      () async {
        final log = _captureDebugPrint();
        final t = _makeTask(wipePending: true);

        final result = await _run(t);

        expect(
          result,
          isTrue,
          reason:
              'A pending wipe is a clean no-op (true) — the worker must '
              'DECLINE to touch MLS state, never retry-loop against it',
        );
        expect(
          t.calls,
          ['sharingCheck', 'wipeCheck'],
          reason:
              'Gate 2 is ordered AFTER consent and BEFORE the battery '
              'gates — an aborted wake must not have probed the FGS or '
              'foreground state, and must never reach the sweep',
        );
        expect(
          log,
          contains(kCatchupWorkerPendingWipeMarker),
          reason:
              'Gate-2 exit must emit the exact marker Phase C1 of the '
              'e2e-m7-background lane polls for',
        );
      },
    );

    test(
      'marker read throws → returns true (fail-CLOSED), no sweep',
      () async {
        final t = _makeTask(throwOnWipeCheck: true);

        final result = await _run(t);

        expect(
          result,
          isTrue,
          reason:
              'Security gates fail closed: if the wipe marker cannot be '
              'read it must be treated as SET (clean no-op) so a corrupt '
              'prefs store cannot let a wake resurrect mid-wipe MLS state',
        );
        expect(
          t.calls,
          ['sharingCheck', 'wipeCheck'],
          reason: 'Nothing past gate 2 may run on a wipe-check error',
        );
      },
    );

    test('marker unset → proceeds to the battery gates and the sweep',
        () async {
      final t = _makeTask();

      final result = await _run(t);

      expect(result, isTrue);
      expect(t.calls, contains('catchup'));
    });
  });

  // ---------------------------------------------------------------------------
  // (3) FGS alive → fast-path bail, no catch-up
  // ---------------------------------------------------------------------------
  group('runBackgroundCatchupTask — (3) FGS alive', () {
    test(
      'returns true and does NOT call runCatchup when FGS is running',
      () async {
        final log = _captureDebugPrint();
        final t = _makeTask(fgsRunning: true);

        final result = await _run(t);

        expect(
          result,
          isTrue,
          reason:
              'FGS alive is a battery fast-path bail — task returns true '
              'because the FGS already covers receive',
        );
        expect(
          t.calls,
          ['sharingCheck', 'wipeCheck', 'fgsCheck'],
          reason:
              'Must pass the security gates, then exit at the FGS check '
              'without probing foreground state or running the sweep',
        );
        expect(log, contains(kCatchupWorkerFgsAliveMarker));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // (4) Foreground active → fast-path bail (D4); read error fails OPEN
  // ---------------------------------------------------------------------------
  group('runBackgroundCatchupTask — (4) foreground active (D4)', () {
    test(
      'returns true and does NOT call runCatchup when the UI is active',
      () async {
        final log = _captureDebugPrint();
        final t = _makeTask(foregroundActive: true);

        final result = await _run(t);

        expect(
          result,
          isTrue,
          reason:
              'FGS-dead-but-UI-active: the map-shell pollers already '
              'receive, so the wake must skip a full Rust+SQLCipher boot',
        );
        expect(
          t.calls,
          ['sharingCheck', 'wipeCheck', 'fgsCheck', 'foregroundCheck'],
          reason: 'All four gates run, then the sweep is skipped',
        );
        expect(log, contains(kCatchupWorkerForegroundActiveMarker));
      },
    );

    test('foreground check throws → proceeds to sweep (fail-OPEN)', () async {
      final t = _makeTask(throwOnForegroundCheck: true);

      final result = await _run(t);

      expect(
        result,
        isTrue,
        reason:
            'Battery gates fail open: a persistent read error must not '
            'silently kill the catch-up floor — the sweep is receive-only, '
            'cursor-idempotent, and excluded by the Rust WRITER_LOCK',
      );
      expect(
        t.calls,
        ['sharingCheck', 'wipeCheck', 'fgsCheck', 'foregroundCheck', 'catchup'],
        reason: 'runCatchup must be attempted when the foreground check '
            'throws',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // (5) Green path — the full gate ORDER pin (single sequence assert)
  // ---------------------------------------------------------------------------
  group('runBackgroundCatchupTask — (5) full gate order', () {
    test(
      'green path calls gates in order consent → wipe → FGS → foreground → '
      'catchup',
      () async {
        final t = _makeTask();

        final result = await _run(t);

        expect(result, isTrue);
        expect(
          t.calls,
          [
            'sharingCheck',
            'wipeCheck',
            'fgsCheck',
            'foregroundCheck',
            'catchup',
          ],
          reason:
              'THE order pin (plan D2/A1): security gates (consent, wipe — '
              'fail-closed) strictly before battery gates (FGS, foreground '
              '— fail-open), sweep last. Any reordering is a security '
              'regression, not a refactor.',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // (6) Catch-up throws → returns false (signal WorkManager back-off)
  // ---------------------------------------------------------------------------
  group('runBackgroundCatchupTask — (6) catch-up failure', () {
    test('returns false when runCatchup throws', () async {
      final t = _makeTask(catchupThrows: true);

      final result = await _run(t);

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
  // (7) Sharing-check throws → clean no-op (true), no catch-up
  // ---------------------------------------------------------------------------
  group('runBackgroundCatchupTask — (7) sharing-check failure (fail-safe)', () {
    test(
      'returns true and does NOT call runCatchup when sharingCheck throws',
      () async {
        final t = _makeTask(throwOnSharingCheck: true);

        final result = await _run(t);

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
        expect(
          t.calls.contains('wipeCheck'),
          isFalse,
          reason: 'A consent-check error exits before gate 2',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // (8) FGS-check throws → proceeds to sweep (conservative)
  // ---------------------------------------------------------------------------
  group('runBackgroundCatchupTask — (8) FGS-check failure', () {
    test('proceeds to runCatchup when isRunningService throws', () async {
      final t = _makeTask(throwOnFgsCheck: true);

      final result = await _run(t);

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
  // (9) Marker-string const pins (A10)
  //
  // The e2e-m7-background CI lane greps logcat for these EXACT literals
  // (Phases A/C1/C2 of docs/M7_BACKGROUND_SHARING.md D6). Any drift makes the
  // lane silently red, so the literals are pinned here — change the lane
  // and this test together, never one of them.
  // ---------------------------------------------------------------------------
  group('worker logcat markers — exact literals pinned (A10)', () {
    test('gate-exit markers match the lane greps', () {
      expect(
        kCatchupWorkerFlagDisabledMarker,
        '[CatchupWorker] wake: backgroundCatchupEnabled=false — no-op',
      );
      expect(
        kCatchupWorkerConsentDisabledMarker,
        '[CatchupWorker] wake: consent disabled — no-op',
      );
      expect(
        kCatchupWorkerPendingWipeMarker,
        '[CatchupWorker] wake: pending-wipe marker set — no-op',
      );
      expect(
        kCatchupWorkerFgsAliveMarker,
        '[CatchupWorker] wake: FGS alive — skip',
      );
      expect(
        kCatchupWorkerForegroundActiveMarker,
        '[CatchupWorker] wake: foreground active — skip',
      );
    });

    test('bootstrap-phase markers match the lane greps', () {
      expect(
        kCatchupWorkerPendingWipePostBootstrapMarker,
        '[CatchupWorker] wake: pending-wipe marker set post-bootstrap — no-op',
      );
      expect(
        kCatchupWorkerConsentDisabledPostBootstrapMarker,
        '[CatchupWorker] wake: consent disabled post-bootstrap — no-op',
      );
      expect(
        kCatchupWorkerNoIdentityMarker,
        '[CatchupWorker] wake: no identity — no-op',
      );
      expect(kCatchupWorkerBootstrapOkMarker, '[CatchupWorker] bootstrap ok');
      expect(
        kCatchupWorkerSweepCompletePrefix,
        '[CatchupWorker] sweep complete:',
      );
    });

    test('negative-assert markers are NOT substrings of the bootstrap '
        're-check markers (lane grep isolation)', () {
      // Phases C1/C2 assert the positive marker appears AND that neither
      // "bootstrap ok" nor "sweep complete" appears. The post-bootstrap
      // re-check markers must therefore not collide with the gate markers
      // or the phase-A markers.
      expect(
        kCatchupWorkerPendingWipePostBootstrapMarker,
        isNot(contains(kCatchupWorkerPendingWipeMarker)),
      );
      expect(
        kCatchupWorkerConsentDisabledPostBootstrapMarker,
        isNot(contains(kCatchupWorkerConsentDisabledMarker)),
      );
      expect(
        kCatchupWorkerPendingWipePostBootstrapMarker,
        isNot(contains(kCatchupWorkerBootstrapOkMarker)),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // (10) disableBackgroundScheduling cancels WorkManager (M7-C wiring)
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
