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
/// The publish cycle is reachable on the host (see
/// `test/mocks/background_task_fakes.dart`), but the cancellable wait, the
/// shutdown race and the in-flight cycle are exposed on their own so these
/// properties are provable in isolation, without a roster or a fix.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/background_location_task.dart';
import 'package:haven/src/services/mls_session_handover.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/publish_stagger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/log_capture.dart';
import '../mocks/background_task_fakes.dart';

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

    // Through the real registry: the service's own relay service over a pool
    // whose drives park. A ZERO budget, so "the bounded phase has given up"
    // is an event-loop fact rather than a wall-clock hope.
    test('a seal parked inside its drive is abandoned at the bound', () async {
      final pool = _ParkedPool();
      final relay = NostrRelayService(
        openPool: () async => pool,
        fixOf: (_, _) async => _Opaque(),
      );
      final seal = relay.sealLocation(
        circle: _Opaque(),
        mlsGroupId: const [1],
        latitude: 1,
        longitude: 2,
        foreground: false,
      );
      await pumpEventQueue();
      expect(pool.parked, ['seal'], reason: 'premise: inside its drive');
      final handler = BackgroundLocationTaskHandler()
        ..teardownDrainBudget = Duration.zero
        ..inFlightPublishForTest = seal
        ..relayServiceForTest = relay;

      await expectLater(
        handler.onDestroy(DateTime.now(), false),
        completes,
        reason: 'a location drive waited out past the bound outlasts the '
            "UI's handover budget",
      );
      expect(pool.shutdowns, 1, reason: 'and the pool is shut under it');
      pool.release();
    });

    test('a leave drive parked holds onDestroy until it ends', () async {
      final logs = LogCapture.install();
      final pool = _ParkedPool();
      final relay = NostrRelayService(openPool: () async => pool);
      final leave = relay.resumeLeave(
        circle: _Opaque(),
        mlsGroupId: const [1],
        foreground: false,
      );
      await pumpEventQueue();
      expect(pool.parked, ['resumeLeave']);
      final handler = BackgroundLocationTaskHandler()
        ..teardownDrainBudget = Duration.zero
        ..inFlightPublishForTest = leave
        ..relayServiceForTest = relay;

      var destroyed = false;
      final destroy = handler
          .onDestroy(DateTime.now(), false)
          .then((_) => destroyed = true);
      await pumpEventQueue();
      expect(
        destroyed,
        isFalse,
        reason: 'the leave drive was cut short by the teardown',
      );
      expect(pool.shutdowns, 0);

      pool.release();
      await expectLater(destroy, completes);
      expect(pool.shutdowns, 1);
      logs
        ..assertContains('[BackgroundTask] onDestroy: draining driver entries')
        ..assertNoNeedles(['wss://']);
    });

    test('the drain line names nothing a drive in flight failed with',
        () async {
      final logs = LogCapture.install();
      final failing = Completer<void>();
      final handler = BackgroundLocationTaskHandler()
        ..teardownDrainBudget = Duration.zero
        ..relayServiceForTest = (FakeNostrRelayService()
          ..inFlightNonLocationDrives = failing.future);

      final destroy = handler.onDestroy(DateTime.now(), false);
      await pumpEventQueue();
      failing.completeError(
        StateError('group ${'ab' * 32} at wss://planted.example'),
      );
      await destroy;

      logs
        ..assertContains('[BackgroundTask] onDestroy: draining driver entries')
        ..assertNoNeedles(['ab' * 32, 'wss://planted.example']);
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

/// A pool whose seal and leave drives park until [release].
class _ParkedPool implements RelayManagerFfi {
  final List<String> parked = [];
  final Completer<void> _gate = Completer<void>();
  int shutdowns = 0;

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<SealOutcomeFfi> sealLocationDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required LocationMessage location,
    required bool foreground,
  }) async {
    parked.add('seal');
    await _gate.future;
    return const SealOutcomeFfi(replayed: [], errored: false);
  }

  @override
  Future<LeaveOutcomeFfi> resumeLeaveDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) async {
    parked.add('resumeLeave');
    await _gate.future;
    return const LeaveOutcomeFfi(status: LeaveStatusFfi.proposed);
  }

  @override
  Future<void> shutdown() async => shutdowns++;

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

class _Opaque implements CircleManagerFfi, LocationMessage {
  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}
