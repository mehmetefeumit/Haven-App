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
      SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true});

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
}
