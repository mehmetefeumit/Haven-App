/// The background publish cycle must abandon its own work when the service is
/// stopping, and `onDestroy` must be bounded by a number the UI isolate's
/// handover budget is derived from.
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
/// The same argument bounds the drain itself. `onDestroy` is what frees the
/// MLS database's Rule-14 guard (it disposes the manager on its way out), so
/// its duration IS the budget `requestSessionHandover` waits out on the UI
/// side. Unbounded, it inherits a relay retry ladder the foreground then spends
/// on a blank map — which is why the two numbers are defined together in
/// `mls_session_handover.dart` and pinned against each other below.
///
/// The publish cycle itself is bridge-bound (it drives `CircleManagerFfi`
/// directly, so `flutter test` cannot reach it); the cancellable wait, the
/// shutdown race and the in-flight cycle are exposed on their own so these
/// properties are provable without a device.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/background_location_task.dart';
import 'package:haven/src/services/mls_session_handover.dart';
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

  group('onDestroy is bounded, and the handover budget says so honestly', () {
    // The service's `onDestroy` is what frees the Rule-14 guard (it disposes
    // the manager on its way out), so its duration IS the UI isolate's
    // handover budget. Left unbounded it inherits a relay retry ladder — three
    // attempts of a 5 s connect plus a 10 s ack, ~49 s — and the foreground
    // spends that on a blank map before giving up on a service that was going
    // to comply.

    test('a publish that outlives the drain budget does not hold teardown',
        () async {
      final handler = BackgroundLocationTaskHandler()
        ..teardownDrainBudget = const Duration(milliseconds: 20);
      // Never completes: the relay ladder still grinding when the stop lands.
      final wedged = Completer<void>();
      handler.inFlightPublishForTest = wedged.future;

      await expectLater(
        handler.onDestroy(DateTime.now(), false),
        completes,
        reason: 'an unbounded drain here is the handover budget being a lie',
      );
      expect(
        wedged.isCompleted,
        isFalse,
        reason: 'the publish was abandoned, not awaited — which costs one '
            'location sample and no MLS state: an application message stages '
            'no commit, so Rule 13 is not in play',
      );
    });

    test('a publish that finishes inside the budget is still awaited',
        () async {
      // The complement. A bound that cut every cycle short would tear down
      // services mid-publish on EVERY stop, wasting the epoch advance the
      // existing drain exists to protect.
      final handler = BackgroundLocationTaskHandler();
      final cycle = Completer<void>();
      handler.inFlightPublishForTest = cycle.future;

      var destroyed = false;
      unawaited(
        handler.onDestroy(DateTime.now(), false).then((_) => destroyed = true),
      );
      await pumpEventQueue();
      expect(
        destroyed,
        isFalse,
        reason: 'teardown must wait for the publish already under way',
      );

      cycle.complete();
      await pumpEventQueue();
      expect(destroyed, isTrue);
    });

    test('a wedged publish is abandoned but a wedged commit-critical fetch '
        'is NOT', () async {
      // The drain budget is a licence to abandon a LOCATION SAMPLE, and
      // nothing else. `fetchMemberLocations` can publish a receiver-side
      // auto-commit (a peer's SelfRemove) and then confirm it; a teardown that
      // gave up between those two steps would shut down the relay and dispose
      // the manager underneath a commit that is possibly already on a relay,
      // leaving it neither confirmed nor rolled back — Rule 13 broken, and the
      // group wedged in `PendingPublish`. So that window is drained WITHOUT a
      // budget, and this is the test that says the two are not the same wait.
      // A ZERO budget, so "the bounded phase has given up" is an event-loop
      // fact rather than a wall-clock hope: a zero-duration timeout fires on
      // the next turn, which `pumpEventQueue` below guarantees. With a
      // millisecond budget the check underneath could pass simply because the
      // budget had not elapsed yet — and it did, silently, against a mutant
      // that bounded the commit-critical drain too.
      final handler = BackgroundLocationTaskHandler()
        ..teardownDrainBudget = Duration.zero;
      final wedgedPublish = Completer<void>();
      final wedgedFetch = Completer<void>();
      handler
        ..inFlightPublishForTest = wedgedPublish.future
        ..inFlightCommitCriticalForTest = wedgedFetch.future;

      var destroyed = false;
      final destroy = handler
          .onDestroy(DateTime.now(), false)
          .then((_) => destroyed = true);

      await pumpEventQueue();
      expect(
        destroyed,
        isFalse,
        reason: 'the commit-critical window has not finished, so teardown '
            'must not have proceeded to the relay shutdown and the manager '
            'dispose that would strand its commit',
      );

      // Only the fetch finishing may release it — the publish is still wedged
      // and stays wedged, which is exactly the point: one is abandonable and
      // the other is not.
      wedgedFetch.complete();
      await expectLater(destroy, completes);
      expect(destroyed, isTrue);
      expect(
        wedgedPublish.isCompleted,
        isFalse,
        reason: 'the location publish was abandoned, as designed',
      );
    });

    test('the handover budget covers the drain the service is allowed',
        () async {
      // The two numbers are one number seen from both ends. A handover that
      // expires first gives up on a compliant service and wastes its single
      // retry; there is no reading under which it should be the smaller.
      expect(
        handoverTimeout,
        greaterThan(kBackgroundTeardownDrainBudget),
        reason: 'the guard is freed AFTER the drain — by the dispose that '
            'follows it — so the wait must outlast the drain, not match it',
      );
    });
  });

  group('a step racing teardown is abandoned, not awaited', () {
    // The GPS one-shot is the longest single step in a cycle and holds no MLS
    // state while it runs, so a stopping service must not sit inside it.

    test('an in-flight step gives up the moment onDestroy starts', () async {
      final handler = BackgroundLocationTaskHandler();
      final fix = Completer<Object>();
      final raced = handler.raceShutdownForTest<Object>(fix.future);

      await handler.onDestroy(DateTime.now(), false);

      expect(await raced, isNull, reason: 'abandoned, so there is no result');
      expect(fix.isCompleted, isFalse);
    });

    test('a step started after shutdown never even begins waiting', () async {
      final handler = BackgroundLocationTaskHandler();
      await handler.onDestroy(DateTime.now(), false);

      expect(
        await handler.raceShutdownForTest<Object>(Completer<Object>().future),
        isNull,
      );
    });

    test('without a shutdown the step returns its real result', () async {
      // The complement: a race that always abandons would publish nothing.
      final handler = BackgroundLocationTaskHandler();
      expect(
        await handler.raceShutdownForTest<Object>(Future<Object>.value(42)),
        42,
      );
    });
  });

  test('a session is not opened for a service that is stopping', () async {
    // `_ensureSession` can spend two 5 s liveness probes and the gap between
    // them, all to open a database this isolate is about to hand back.
    final handler = BackgroundLocationTaskHandler();
    var registryReads = 0;
    handler.overrideIsSessionLive = (({required dataDir}) async {
      registryReads++;
      return true;
    });

    await handler.onDestroy(DateTime.now(), false);

    expect(await handler.ensureSessionForTest(dataDir: '/haven'), isFalse);
    expect(
      registryReads,
      0,
      reason: 'the refusal must precede the probe, not follow it',
    );
  });
}
