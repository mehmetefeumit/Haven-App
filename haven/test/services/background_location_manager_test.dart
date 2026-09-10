/// Tests for BackgroundLocationManager.isForegroundActive staleness math
/// and the markForegroundActive / readLastPublishTime / writeLastPublishTime /
/// isBackgroundSharingEnabled helpers.
///
/// T1: markForegroundActive(active: true) writes current epoch ms.
/// T2: markForegroundActive(active: false) writes 0.
/// T3: readLastPublishTime / writeLastPublishTime round-trip.
/// T4: isBackgroundSharingEnabled defaults false, returns true when key true.
///
/// Staleness threshold tests:
///
/// Seeds kForegroundActiveAtMsKey via SharedPreferences.setMockInitialValues
/// with timestamps relative to DateTime.now(). Because isForegroundActive
/// reads DateTime.now() internally, we subtract a known offset from
/// DateTime.now().millisecondsSinceEpoch when seeding so the test is
/// deterministic enough (assertions have 1+ second of margin from real-clock
/// drift).
///
/// The staleness threshold is 2 * kBackgroundRepeatInterval = 144 seconds.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // Helper: seed kForegroundActiveAtMsKey and call isForegroundActive().
  // ---------------------------------------------------------------------------

  Future<bool> check(int? storedMs) async {
    SharedPreferences.setMockInitialValues(
      storedMs != null ? {kForegroundActiveAtMsKey: storedMs} : {},
    );
    return BackgroundLocationManager.isForegroundActive();
  }

  group('BackgroundLocationManager.isForegroundActive — staleness check', () {
    // -------------------------------------------------------------------------
    // Case 1: key unset → returns false
    // -------------------------------------------------------------------------
    test('returns false when kForegroundActiveAtMsKey is unset', () async {
      final result = await check(null);
      expect(
        result,
        isFalse,
        reason: 'no stored timestamp — foreground not considered active',
      );
    });

    // -------------------------------------------------------------------------
    // Case 2: key == 0 (deliberate handoff) → returns false
    // -------------------------------------------------------------------------
    test(
      'returns false when kForegroundActiveAtMsKey is 0 (deliberate handoff)',
      () async {
        final result = await check(0);
        expect(
          result,
          isFalse,
          reason: 'zero timestamp is the clean-pause handoff sentinel',
        );
      },
    );

    // -------------------------------------------------------------------------
    // Case 3: 30 seconds old — well within 144-second window → true
    // -------------------------------------------------------------------------
    test(
      'returns true when timestamp is 30 s old (well within 144 s window)',
      () async {
        final storedMs = DateTime.now().millisecondsSinceEpoch - 30 * 1000;
        final result = await check(storedMs);
        expect(
          result,
          isTrue,
          reason: '30 s old timestamp is within the 144 s staleness window',
        );
      },
    );

    // -------------------------------------------------------------------------
    // Case 4: 100 seconds old — within 144-second window → true
    // -------------------------------------------------------------------------
    test(
      'returns true when timestamp is 100 s old (within 144 s window)',
      () async {
        final storedMs = DateTime.now().millisecondsSinceEpoch - 100 * 1000;
        final result = await check(storedMs);
        expect(
          result,
          isTrue,
          reason: '100 s old timestamp is within the 144 s staleness window',
        );
      },
    );

    // -------------------------------------------------------------------------
    // Case 5: 200 seconds old — past 144-second threshold → false
    // -------------------------------------------------------------------------
    test(
      'returns false when timestamp is 200 s old (past 144 s threshold)',
      () async {
        final storedMs = DateTime.now().millisecondsSinceEpoch - 200 * 1000;
        final result = await check(storedMs);
        final thresholdSecs = (kBackgroundRepeatInterval * 2).inSeconds;
        expect(
          result,
          isFalse,
          reason:
              '200 s old timestamp exceeds 2 * kBackgroundRepeatInterval '
              '($thresholdSecs s) and must be treated as stale',
        );
      },
    );

    // -------------------------------------------------------------------------
    // Case 6: timestamp in the FUTURE (backward clock jump) → false
    // -------------------------------------------------------------------------
    test(
      'returns false when the stored timestamp is in the future '
      '(backward clock jump)',
      () async {
        // A backward clock jump — NTP correction, a manual date change, an
        // RTC that comes up wrong at boot — leaves a timestamp the foreground
        // wrote at a wall-clock time that is now in the future. The age is
        // then NEGATIVE, which `age < threshold` alone reads as "the
        // foreground just wrote this": the FGS mutes its own publish cycle
        // for as long as the clock takes to catch up, silently, with the
        // toggle still reading ON. Hours of a future stamp is entirely
        // reachable (a device that briefly believed it was in another day).
        final storedMs =
            DateTime.now().millisecondsSinceEpoch + 6 * 60 * 60 * 1000;
        final result = await check(storedMs);
        expect(
          result,
          isFalse,
          reason:
              'an impossible (future) timestamp must read as stale, never as '
              'a live foreground — otherwise a backward clock jump mutes the '
              'background publisher until the clock catches up',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Battery-optimization verdict persistence
  // ---------------------------------------------------------------------------

  group('BackgroundLocationManager — battery-optimization verdict', () {
    test('defaults to not-denied when nothing was ever recorded', () async {
      SharedPreferences.setMockInitialValues({});

      expect(
        await BackgroundLocationManager.isBatteryOptimizationDenied(),
        isFalse,
        reason:
            'an absent key means the question was never asked (or this is '
            'not Android); it must never render the advisory',
      );
    });

    test('round-trips the recorded verdict in both directions', () async {
      SharedPreferences.setMockInitialValues({});

      await BackgroundLocationManager.recordBatteryOptimizationDenied(
        denied: true,
      );
      expect(
        await BackgroundLocationManager.isBatteryOptimizationDenied(),
        isTrue,
        reason:
            'a declined exemption must OUTLIVE the transient snackbar — that '
            'is the whole point of persisting it',
      );

      await BackgroundLocationManager.recordBatteryOptimizationDenied(
        denied: false,
      );
      expect(
        await BackgroundLocationManager.isBatteryOptimizationDenied(),
        isFalse,
        reason:
            'granting the exemption later must clear the advisory, not leave '
            'a permanent warning',
      );
    });

    test('a failed probe degrades to the last recorded answer, not to '
        '"exemption held"', () async {
      // The plugin channel is absent on this host, which is the same shape as
      // a real probe failure. Falling back to `false` there would silently
      // retract a warning the OS never withdrew; falling back to the last
      // recorded answer keeps the surface truthful until the next successful
      // probe.
      Future<bool> failingProbe() async =>
          throw StateError('channel unavailable');

      SharedPreferences.setMockInitialValues({
        kBatteryOptimizationDeniedKey: true,
      });
      expect(
        await BackgroundLocationManager.refreshBatteryOptimizationDenied(
          probeExemption: failingProbe,
        ),
        isTrue,
      );

      SharedPreferences.setMockInitialValues({});
      expect(
        await BackgroundLocationManager.refreshBatteryOptimizationDenied(
          probeExemption: failingProbe,
        ),
        isFalse,
        reason:
            'with nothing recorded there is nothing to warn about — the '
            'fallback must not invent a denial either',
      );
    });

    test('a successful probe overwrites a stale recorded answer', () async {
      // The write-back is what makes the persisted value a usable fallback
      // rather than a permanent first impression.
      SharedPreferences.setMockInitialValues({
        kBatteryOptimizationDeniedKey: true,
      });

      expect(
        await BackgroundLocationManager.refreshBatteryOptimizationDenied(
          probeExemption: () async => true, // exemption now held
        ),
        isFalse,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kBatteryOptimizationDeniedKey), isFalse);
    });

    test('the verdict is cleared when the identity is deleted', () async {
      // Every SharedPreferences key needs a deliberate fate on the delete path
      // (scripts/ci/check_identity_delete_prefs_residue.sh). This one is
      // cleared rather than kept: a fresh identity must not inherit a warning
      // earned by the deleted one, and it re-probes live on its first visit
      // to the settings page anyway.
      SharedPreferences.setMockInitialValues({
        kBatteryOptimizationDeniedKey: true,
        kBackgroundLastPublishMsKey: 1234,
      });

      await BackgroundLocationManager.clearPublishHistoryOnIdentityDelete();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kBatteryOptimizationDeniedKey), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // T1: markForegroundActive(active: true) writes current epoch ms
  // ---------------------------------------------------------------------------

  group('BackgroundLocationManager.markForegroundActive active:true (T1)', () {
    test('writes current epoch ms (within ±5 s of DateTime.now()) to '
        'kForegroundActiveAtMsKey when active is true', () async {
      SharedPreferences.setMockInitialValues({});

      final beforeMs = DateTime.now().millisecondsSinceEpoch;
      await BackgroundLocationManager.markForegroundActive(active: true);
      final afterMs = DateTime.now().millisecondsSinceEpoch;

      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getInt(kForegroundActiveAtMsKey);

      expect(
        stored,
        isNotNull,
        reason: 'markForegroundActive(active:true) must write an int value',
      );
      expect(
        stored,
        greaterThanOrEqualTo(beforeMs),
        reason:
            'stored timestamp must be >= time measured just before the call',
      );
      expect(
        stored,
        lessThanOrEqualTo(afterMs + 5000),
        reason: 'stored timestamp must be within 5 s of the call time',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // T2: markForegroundActive(active: false) writes 0
  // ---------------------------------------------------------------------------

  group(
    'BackgroundLocationManager.markForegroundActive — active:false (T2)',
    () {
      test('writes 0 to kForegroundActiveAtMsKey when active is false '
          '(deliberate handoff sentinel)', () async {
        // Seed with a real timestamp first to confirm it gets overwritten.
        SharedPreferences.setMockInitialValues({
          kForegroundActiveAtMsKey: DateTime.now().millisecondsSinceEpoch,
        });

        await BackgroundLocationManager.markForegroundActive(active: false);

        final prefs = await SharedPreferences.getInstance();
        final stored = prefs.getInt(kForegroundActiveAtMsKey);

        expect(
          stored,
          equals(0),
          reason:
              'markForegroundActive(active:false) must write 0 (clean-pause '
              'handoff sentinel)',
        );
      });
    },
  );

  // ---------------------------------------------------------------------------
  // T3: readLastPublishTime / writeLastPublishTime round-trip
  // ---------------------------------------------------------------------------

  group('BackgroundLocationManager — readLastPublishTime/writeLastPublishTime '
      'round-trip (T3)', () {
    test('reads back the same DateTime written by writeLastPublishTime '
        '(equality at ms granularity)', () async {
      SharedPreferences.setMockInitialValues({});

      // Use a fixed DateTime with ms precision to avoid sub-ms rounding.
      final written = DateTime.fromMillisecondsSinceEpoch(
        DateTime(2026, 3, 15, 12, 30, 45, 123).millisecondsSinceEpoch,
      );

      await BackgroundLocationManager.writeLastPublishTime(written);
      final read = await BackgroundLocationManager.readLastPublishTime();

      expect(
        read,
        isNotNull,
        reason: 'readLastPublishTime must return non-null after a write',
      );
      expect(
        read!.millisecondsSinceEpoch,
        equals(written.millisecondsSinceEpoch),
        reason:
            'read DateTime must equal written DateTime at millisecond '
            'granularity',
      );
    });

    test('readLastPublishTime returns null when kBackgroundLastPublishMsKey '
        'is absent', () async {
      SharedPreferences.setMockInitialValues({});

      final result = await BackgroundLocationManager.readLastPublishTime();

      expect(
        result,
        isNull,
        reason:
            'readLastPublishTime must return null when no timestamp '
            'has ever been written',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // T4: isBackgroundSharingEnabled
  // ---------------------------------------------------------------------------

  group('BackgroundLocationManager.isBackgroundSharingEnabled (T4)', () {
    test('defaults to false when kBackgroundSharingKey is absent', () async {
      SharedPreferences.setMockInitialValues({});

      final result =
          await BackgroundLocationManager.isBackgroundSharingEnabled();

      expect(
        result,
        isFalse,
        reason:
            'isBackgroundSharingEnabled must default to false when the '
            'preference key has never been written',
      );
    });

    test('returns true when kBackgroundSharingKey is set to true', () async {
      SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true});

      final result =
          await BackgroundLocationManager.isBackgroundSharingEnabled();

      expect(
        result,
        isTrue,
        reason:
            'isBackgroundSharingEnabled must return true when the '
            'preference key is explicitly set to true',
      );
    });

    test(
      'returns false when kBackgroundSharingKey is explicitly set to false',
      () async {
        SharedPreferences.setMockInitialValues({kBackgroundSharingKey: false});

        final result =
            await BackgroundLocationManager.isBackgroundSharingEnabled();

        expect(
          result,
          isFalse,
          reason:
              'isBackgroundSharingEnabled must return false when the '
              'preference key is explicitly set to false',
        );
      },
    );
  });

  group('BackgroundLocationManager.isBackgroundIdle — M7 catch-up gate', () {
    test('true when foreground inactive AND FGS idle', () async {
      SharedPreferences.setMockInitialValues({kBackgroundIdleKey: true});
      expect(await BackgroundLocationManager.isBackgroundIdle(), isTrue);
    });

    test(
      'true when foreground inactive AND idle key unset (FGS never ran)',
      () async {
        SharedPreferences.setMockInitialValues({});
        expect(await BackgroundLocationManager.isBackgroundIdle(), isTrue);
      },
    );

    test('false when the foreground UI isolate is active', () async {
      SharedPreferences.setMockInitialValues({
        kForegroundActiveAtMsKey: DateTime.now().millisecondsSinceEpoch,
        kBackgroundIdleKey: true,
      });
      expect(
        await BackgroundLocationManager.isBackgroundIdle(),
        isFalse,
        reason: 'a background sweep must not run while the foreground writes',
      );
    });

    test(
      'false when the FGS publish isolate is mid-cycle (idle=false)',
      () async {
        SharedPreferences.setMockInitialValues({kBackgroundIdleKey: false});
        expect(await BackgroundLocationManager.isBackgroundIdle(), isFalse);
      },
    );
  });

  group('BackgroundLocationManager.signalTask', () {
    // The plugin's own channel, so the assertion is on what really crosses to
    // the service rather than on a seam invented for the test.
    const channel = MethodChannel('flutter_foreground_task/methods');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];

    setUp(() {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      calls.clear();
    });

    test('the signal string is the WHOLE payload', () async {
      BackgroundLocationManager.signalTask(kForegroundPausedSignal);
      await pumpEventQueue();

      expect(calls, hasLength(1), reason: 'one signal, one send');
      expect(calls.single.method, 'sendData');
      expect(
        calls.single.arguments,
        kForegroundPausedSignal,
        reason: 'presence-only: the payload carries no identity, no '
            'coordinate, no circle and no timestamp — everything the task '
            'acts on it re-reads from its own gates',
      );
    });

    test('each signal is forwarded verbatim, in order', () async {
      BackgroundLocationManager.signalTask(kForegroundPausedSignal);
      BackgroundLocationManager.signalTask(kForegroundResumedSignal);
      await pumpEventQueue();

      expect(
        calls.map((c) => c.arguments).toList(),
        [kForegroundPausedSignal, kForegroundResumedSignal],
        reason: 'the task distinguishes the two by string alone, so a sender '
            'that rewrote, coalesced or reordered them would silently invert '
            'which isolate owns the platform location request',
      );
    });
  });
}
