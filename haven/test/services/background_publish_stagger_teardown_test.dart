/// The background publish cycle's decorrelation wait must be cancellable.
///
/// ## Why this is a separate, load-bearing property
///
/// The background cycle now holds each circle's publish more than a second
/// past the previous one, so that two circles' kind-445 events cannot carry the
/// same whole-second `created_at`. That wait sits inside `_publishCycle`, and
/// `onDestroy` awaits the in-flight cycle before it tears anything down — so a
/// plain `Future.delayed` between circles would spend Android's service-stop
/// window sleeping, for no benefit at all (nothing is being published while it
/// waits).
///
/// `onDestroy` therefore signals shutdown BEFORE it awaits, and every
/// decorrelation wait races that signal. The cost of the stagger at teardown is
/// the one publish already under way, not the rest of the burst's spread.
///
/// The publish cycle itself is bridge-bound (it drives `CircleManagerFfi`
/// directly, so `flutter test` cannot reach it); the wait is exposed on its own
/// so this property is provable without a device.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/background_location_task.dart';
import 'package:haven/src/services/publish_stagger.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'onDestroy releases an in-flight decorrelation wait instead of sitting '
    'out the rest of the spread',
    () async {
      final handler = BackgroundLocationTaskHandler();
      final stopwatch = Stopwatch()..start();

      // A full spread's worth of waiting, as a burst of many circles would
      // schedule.
      final wait = handler.staggerWaitForTest(kPublishStaggerMaxSpread);
      await handler.onDestroy(DateTime.now(), false);
      await wait;

      stopwatch.stop();
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason:
            'the wait must lose its race with the shutdown signal — otherwise '
            'stopping the service blocks for the whole '
            '${kPublishStaggerMaxSpread.inSeconds}s stagger budget, inside '
            'the window Android gives it to stop',
      );
    },
  );

  test('a wait started after shutdown returns immediately', () async {
    final handler = BackgroundLocationTaskHandler();
    await handler.onDestroy(DateTime.now(), false);

    final stopwatch = Stopwatch()..start();
    await handler.staggerWaitForTest(kPublishStaggerMaxSpread);
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('without a shutdown the wait actually waits', () async {
    // The complement: a cancellable wait that never waits would decorrelate
    // nothing at all.
    final handler = BackgroundLocationTaskHandler();
    final stopwatch = Stopwatch()..start();
    await handler.staggerWaitForTest(const Duration(milliseconds: 250));
    stopwatch.stop();

    expect(stopwatch.elapsed, greaterThanOrEqualTo(
      const Duration(milliseconds: 200),
    ));
  });
}
