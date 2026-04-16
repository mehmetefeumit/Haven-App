import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/jittered_scheduler.dart';

void main() {
  group('JitteredScheduler', () {
    test('first tick fires after sampled interval, not immediately', () {
      FakeAsync().run((async) {
        var tickCount = 0;
        final scheduler = JitteredScheduler(
          nominal: const Duration(minutes: 5),
          sampleIntervalSecs: (_) => 180,
          onTick: () => tickCount++,
        )..start();

        // Scheduler is armed but not yet fired.
        expect(scheduler.isActive, isTrue);
        expect(scheduler.lastScheduledDelay, const Duration(seconds: 180));
        expect(tickCount, 0);

        async.elapse(const Duration(seconds: 179));
        expect(tickCount, 0);

        async.elapse(const Duration(seconds: 1));
        expect(tickCount, 1);

        scheduler.cancel();
      });
    });

    test('reschedules with a fresh sample on each tick', () {
      FakeAsync().run((async) {
        final samples = [180, 420, 300, 240];
        var sampleIdx = 0;
        var tickCount = 0;
        final scheduler = JitteredScheduler(
          nominal: const Duration(minutes: 5),
          sampleIntervalSecs: (_) => samples[sampleIdx++],
          onTick: () => tickCount++,
        )..start();

        // 180 + 420 + 300 + 240 = 1140s = 19 min
        async.elapse(const Duration(minutes: 19));
        expect(tickCount, 4);
        expect(sampleIdx, greaterThanOrEqualTo(4));

        scheduler.cancel();
      });
    });

    test('cancel() stops future ticks', () {
      FakeAsync().run((async) {
        var tickCount = 0;
        final scheduler = JitteredScheduler(
          nominal: const Duration(minutes: 5),
          sampleIntervalSecs: (_) => 300,
          onTick: () => tickCount++,
        )..start();

        async.elapse(const Duration(minutes: 2));
        scheduler.cancel();
        expect(scheduler.isActive, isFalse);
        expect(scheduler.lastScheduledDelay, isNull);

        async.elapse(const Duration(minutes: 10));
        expect(tickCount, 0);
      });
    });

    test('cancel() is idempotent', () {
      final scheduler =
          JitteredScheduler(
              nominal: const Duration(minutes: 5),
              sampleIntervalSecs: (_) => 300,
              onTick: () {},
            )
            ..start()
            ..cancel();
      expect(scheduler.cancel, returnsNormally);
      expect(scheduler.isActive, isFalse);
    });

    test('start() after cancel() resumes ticking', () {
      FakeAsync().run((async) {
        var tickCount = 0;
        final scheduler = JitteredScheduler(
          nominal: const Duration(minutes: 5),
          sampleIntervalSecs: (_) => 200,
          onTick: () => tickCount++,
        )..start();

        async.elapse(const Duration(seconds: 200));
        expect(tickCount, 1);

        scheduler.cancel();
        async.elapse(const Duration(seconds: 500));
        expect(tickCount, 1);

        scheduler.start();
        async.elapse(const Duration(seconds: 200));
        expect(tickCount, 2);

        scheduler.cancel();
      });
    });

    test('start() on an active scheduler is a no-op', () {
      FakeAsync().run((async) {
        var sampleCount = 0;
        final scheduler = JitteredScheduler(
          nominal: const Duration(minutes: 5),
          sampleIntervalSecs: (_) {
            sampleCount++;
            return 300;
          },
          onTick: () {},
        )..start();
        expect(sampleCount, 1);

        scheduler
          ..start()
          ..start();
        expect(sampleCount, 1, reason: 'double-start must not resample');

        scheduler.cancel();
      });
    });

    test('onTick exception is swallowed and scheduler rearms', () {
      FakeAsync().run((async) {
        var tickCount = 0;
        final scheduler = JitteredScheduler(
          nominal: const Duration(minutes: 5),
          sampleIntervalSecs: (_) => 180,
          onTick: () {
            tickCount++;
            if (tickCount == 1) {
              throw StateError('boom');
            }
          },
        )..start();

        async.elapse(const Duration(seconds: 180));
        expect(tickCount, 1);

        async.elapse(const Duration(seconds: 180));
        expect(tickCount, 2, reason: 'must continue firing after exception');

        scheduler.cancel();
      });
    });

    test('sampleIntervalSecs exception falls back to nominal', () {
      FakeAsync().run((async) {
        var tickCount = 0;
        var callCount = 0;
        final scheduler = JitteredScheduler(
          nominal: const Duration(seconds: 300),
          sampleIntervalSecs: (_) {
            callCount++;
            // First sample throws; subsequent samples succeed.
            if (callCount == 1) {
              throw StateError('ffi unavailable');
            }
            return 300;
          },
          onTick: () => tickCount++,
        )..start();

        // Fallback delay is nominal = 300s.
        expect(scheduler.lastScheduledDelay, const Duration(seconds: 300));

        async.elapse(const Duration(seconds: 300));
        expect(tickCount, 1);

        scheduler.cancel();
      });
    });

    test('cancel() called from inside onTick prevents rearm', () {
      FakeAsync().run((async) {
        var tickCount = 0;
        late final JitteredScheduler scheduler;
        scheduler = JitteredScheduler(
          nominal: const Duration(minutes: 5),
          sampleIntervalSecs: (_) => 180,
          onTick: () {
            tickCount++;
            scheduler.cancel();
          },
        )..start();

        async.elapse(const Duration(seconds: 180));
        expect(tickCount, 1);
        expect(scheduler.isActive, isFalse);

        async.elapse(const Duration(minutes: 10));
        expect(tickCount, 1, reason: 'cancel-in-onTick must block rearm');
      });
    });
  });
}
