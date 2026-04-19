/// Tests for BackgroundIdleWaiter polling/timeout/default-true behaviors.
///
/// Uses injected clock and prefsGetter seams so no real
/// Future.delayed wall-clock time is consumed.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/background_idle_waiter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const waiter = BackgroundIdleWaiter();

  // ---------------------------------------------------------------------------
  // Helper: build a fake clock that returns increasing timestamps.
  //
  // Each call to the returned function advances the simulated time by [step].
  // Starts at [base].
  // ---------------------------------------------------------------------------
  DateTime Function() buildClock(
    DateTime base, {
    required Duration step,
  }) {
    var current = base;
    return () {
      final t = current;
      current = current.add(step);
      return t;
    };
  }

  // ---------------------------------------------------------------------------
  // Test 1: Returns true immediately when kBackgroundIdleKey == true at t=0.
  // Relies on the 5-second default maxWait (no redundant argument needed).
  // ---------------------------------------------------------------------------

  group('BackgroundIdleWaiter — returns true immediately', () {
    test(
      'returns true on first poll when kBackgroundIdleKey is set to true',
      () async {
        SharedPreferences.setMockInitialValues({
          kBackgroundIdleKey: true,
        });
        final prefs = await SharedPreferences.getInstance();

        // Clock advances 1 ms per call; with a 5 s maxWait the loop would
        // never time out naturally — the early-return-on-true fires first.
        final base = DateTime(2026);
        final clock = buildClock(base, step: const Duration(milliseconds: 1));

        final result = await waiter.waitUntilIdle(
          clock: clock,
          prefsGetter: () async => prefs,
        );

        expect(result, isTrue, reason: 'idle flag true should return true');
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Test 2: Returns false after deadline when key stays false the whole window.
  //
  // Strategy: pass pollInterval: Duration.zero to avoid real Future.delayed
  // waits, and a clock that advances by more than maxWait per call so
  // now().isBefore(deadline) flips false quickly.
  // ---------------------------------------------------------------------------

  group('BackgroundIdleWaiter — timeout returns false', () {
    test(
      'returns false when kBackgroundIdleKey stays false and deadline passes',
      () async {
        SharedPreferences.setMockInitialValues({
          kBackgroundIdleKey: false,
        });
        final prefs = await SharedPreferences.getInstance();

        // maxWait of 1 ms so the simulated clock only needs to advance by 2 ms
        // to exceed the deadline.
        const maxWait = Duration(milliseconds: 1);

        // Clock step > maxWait → the first call sets the base for the deadline,
        // subsequent calls return a time past the deadline immediately.
        final base = DateTime(2026);
        final clock = buildClock(
          base,
          step: const Duration(milliseconds: 2),
        );

        final result = await waiter.waitUntilIdle(
          maxWait: maxWait,
          pollInterval: Duration.zero,
          clock: clock,
          prefsGetter: () async => prefs,
        );

        expect(result, isFalse, reason: 'deadline exceeded should time out');
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Test 3: Default-true on cold start — unset key returns true immediately.
  //
  // When kBackgroundIdleKey is absent, prefs.getBool returns null, and the
  // implementation uses ?? true, so the first poll must return true without
  // waiting. Relies on 5-second default maxWait.
  // ---------------------------------------------------------------------------

  group('BackgroundIdleWaiter — default true on cold start', () {
    test(
      'returns true immediately when kBackgroundIdleKey is unset (cold start)',
      () async {
        // No key present — simulates a fresh install or first run.
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();

        final base = DateTime(2026);
        final clock = buildClock(base, step: const Duration(milliseconds: 1));

        final result = await waiter.waitUntilIdle(
          clock: clock,
          prefsGetter: () async => prefs,
        );

        expect(
          result,
          isTrue,
          reason:
              'absent key is treated as idle (background never started)'
              ' — default-true invariant',
        );
      },
    );
  });
}
