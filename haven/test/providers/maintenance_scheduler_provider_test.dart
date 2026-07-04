import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/maintenance_scheduler_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/maintenance_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_relay_service.dart';

/// A fake circle-manager FFI handle (never actually invoked).
class _FakeCircleManager implements CircleManagerFfi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

/// A [MaintenanceService] whose task methods are recorded + controllable, so
/// the scheduler can be driven deterministically without the FFI bridge.
///
/// NOTE: this override bypasses `MaintenanceService._withSecret` entirely, so
/// the secret-scrub logic is NOT exercised here — that is covered by
/// `maintenance_service_test.dart`. These tests prove scheduling behavior only.
class _FakeMaintenanceService extends MaintenanceService {
  _FakeMaintenanceService()
      : super(
          relayService: MockRelayService(),
          circleManagerFactory: () async => _FakeCircleManager(),
          identitySecretBytes: () async => const <int>[],
        );

  int kpCalls = 0;
  int relayListCalls = 0;
  int healthCalls = 0;

  /// When set, the KP task blocks on this until completed (overlap tests).
  Completer<void>? kpGate;

  /// When set, the Nth KeyPackage call blocks on the completer this returns
  /// (per-call gating for the cross-generation overlap test). Takes precedence
  /// over [kpGate]. The index is 0-based over KeyPackage calls.
  Completer<void>? Function(int callIndex)? kpGateFor;

  /// When set, the relay-list task blocks on this until completed.
  Completer<void>? relayListGate;

  /// When true, the KP task throws (fail-soft tests).
  bool throwOnKp = false;

  @override
  Future<KeyPackageMaintenanceResult> maintainKeyPackage() async {
    final callIndex = kpCalls;
    kpCalls++;
    if (throwOnKp) throw StateError('kp boom');
    final gate = kpGateFor?.call(callIndex) ?? kpGate;
    if (gate != null) await gate.future;
    return const KeyPackageMaintenanceResult.empty();
  }

  @override
  Future<RelayListMaintenanceResult> maintainRelayList() async {
    relayListCalls++;
    if (relayListGate != null) await relayListGate!.future;
    return const RelayListMaintenanceResult.empty();
  }

  @override
  Future<SubscriptionHealthResult> maintainSubscriptionHealth() async {
    healthCalls++;
    return const SubscriptionHealthResult.empty();
  }
}

/// A maintenance service whose health task throws (fail-soft health test).
class _ThrowingHealthService extends _FakeMaintenanceService {
  @override
  Future<SubscriptionHealthResult> maintainSubscriptionHealth() async {
    healthCalls++;
    throw StateError('health boom');
  }
}

/// Builds a container overriding the maintenance service (with [fake]) AND the
/// login-publish provider (so the first KeyPackage tick's causal handoff does
/// not try to build the real publisher). [loginPublish] defaults to an
/// immediately-resolved success.
ProviderContainer _containerWith(
  _FakeMaintenanceService fake, {
  Future<bool>? loginPublish,
}) {
  return ProviderContainer(
    overrides: [
      maintenanceServiceProvider.overrideWithValue(fake),
      keyPackagePublisherProvider.overrideWith(
        (ref) => loginPublish ?? Future.value(true),
      ),
    ],
  );
}

void main() {
  group('MaintenanceScheduler — fire-on-start', () {
    test('fires each task exactly once after its initial delay', () {
      fakeAsync((async) {
        final fake = _FakeMaintenanceService();
        final container = _containerWith(fake)
          ..read(maintenanceSchedulerProvider.notifier);

        // Nothing fires immediately (all three have an initial settle delay).
        async.flushMicrotasks();
        expect(fake.relayListCalls, 0);
        expect(fake.healthCalls, 0);
        expect(fake.kpCalls, 0);

        // Initial delays: relay-list 1 min, health 90 s, KeyPackage 2 min.
        async.elapse(const Duration(seconds: 90));
        expect(fake.relayListCalls, 1, reason: 'relay-list fires at ~1 min');
        expect(fake.healthCalls, 1, reason: 'health fires at ~90 s');
        expect(fake.kpCalls, 0, reason: 'KeyPackage waits for its 2 min delay');

        // Past all initial delays but before any recurs (10/30/15 min). The
        // KeyPackage tick also awaits the (immediately-resolved) login publish.
        async.elapse(const Duration(minutes: 2));
        expect(fake.relayListCalls, 1);
        expect(fake.healthCalls, 1);
        expect(fake.kpCalls, 1);

        container.dispose();
      });
    });
  });

  group('MaintenanceScheduler — causal handoff', () {
    test('first KeyPackage tick waits for the login publish to settle', () {
      fakeAsync((async) {
        final loginPublish = Completer<bool>();
        final fake = _FakeMaintenanceService();
        final container = _containerWith(
          fake,
          loginPublish: loginPublish.future,
        )..read(maintenanceSchedulerProvider.notifier);

        // Past the 2 min KP initial delay but before the 60 s settle timeout
        // (fires at ~3 min): the tick has started but is blocked awaiting the
        // still-pending login publish.
        async.elapse(const Duration(minutes: 2, seconds: 30));
        expect(
          fake.kpCalls,
          0,
          reason: 'KP probe must not run until the login publish settles',
        );

        // Settle the login publish → the tick proceeds to the FFI probe.
        loginPublish.complete(true);
        async.flushMicrotasks();
        expect(fake.kpCalls, 1);

        container.dispose();
      });
    });

    test('proceeds anyway if the login publish times out', () {
      fakeAsync((async) {
        // A login publish that never completes → the 60 s timeout fires and
        // the tick proceeds regardless (maintenance is the safety net).
        final fake = _FakeMaintenanceService();
        final container = _containerWith(
          fake,
          loginPublish: Completer<bool>().future,
        )..read(maintenanceSchedulerProvider.notifier);

        // 2 min initial delay + 60 s timeout cap = ~3 min before the probe.
        async.elapse(const Duration(minutes: 3, seconds: 5));
        expect(fake.kpCalls, 1, reason: 'timeout must not stall maintenance');

        container.dispose();
      });
    });
  });

  group('MaintenanceScheduler — no-overlap', () {
    test('skips a concurrent KeyPackage tick while one is in flight', () async {
      final fake = _FakeMaintenanceService()..kpGate = Completer<void>();
      final container = _containerWith(fake);
      addTearDown(container.dispose);
      final notifier = container.read(maintenanceSchedulerProvider.notifier);

      // Start tick #1. Drain all pending microtasks (the causal-handoff await
      // + the maintainKeyPackage call) so it reaches the gate block.
      final first = notifier.triggerKeyPackageTickForTest();
      await Future<void>.delayed(Duration.zero);
      expect(notifier.keyPackageInFlightForTest, isTrue);
      expect(fake.kpCalls, 1);

      // Tick #2 while #1 is still in flight → skipped by the guard.
      await notifier.triggerKeyPackageTickForTest();
      expect(fake.kpCalls, 1, reason: 'overlapping tick must be skipped');

      // Release #1 and let it settle.
      fake.kpGate!.complete();
      await first;
      expect(notifier.keyPackageInFlightForTest, isFalse);
    });

    test('skips a concurrent relay-list tick while one is in flight', () async {
      final fake = _FakeMaintenanceService()..relayListGate = Completer<void>();
      final container = _containerWith(fake);
      addTearDown(container.dispose);
      final notifier = container.read(maintenanceSchedulerProvider.notifier);

      final first = notifier.triggerRelayListTickForTest();
      await Future<void>.delayed(Duration.zero);
      expect(fake.relayListCalls, 1);

      await notifier.triggerRelayListTickForTest();
      expect(
        fake.relayListCalls,
        1,
        reason: 'overlapping relay-list tick must be skipped',
      );

      fake.relayListGate!.complete();
      await first;
    });
  });

  group('MaintenanceScheduler — subscription health (M8-4)', () {
    test('fires at ~90 s then recurs on its 15 min cadence', () {
      fakeAsync((async) {
        final fake = _FakeMaintenanceService();
        final container = _containerWith(fake)
          ..read(maintenanceSchedulerProvider.notifier);

        async.elapse(const Duration(seconds: 60));
        expect(fake.healthCalls, 0, reason: 'health waits its 90 s delay');

        async.elapse(const Duration(seconds: 45)); // total 105 s
        expect(fake.healthCalls, 1, reason: 'health fires at ~90 s');

        // Next tick after ~15 min (jittered ±25 % → within [11.25, 18.75] min).
        async.elapse(const Duration(minutes: 20));
        expect(
          fake.healthCalls,
          greaterThanOrEqualTo(2),
          reason: 'health self-reschedules on its cadence',
        );

        container.dispose();
      });
    });

    test('a throwing health tick does not kill its loop', () async {
      // The health task swallows throws in its own try/catch (engine may not
      // be up); the loop must survive.
      final fake = _ThrowingHealthService();
      final container = _containerWith(fake);
      addTearDown(container.dispose);
      final notifier = container.read(maintenanceSchedulerProvider.notifier);

      await notifier.triggerHealthTickForTest();
      expect(fake.healthCalls, 1);
      expect(
        notifier.hasArmedTimersForTest,
        isTrue,
        reason: 'a throwing health tick still reschedules',
      );
    });
  });

  group('MaintenanceScheduler — cancel', () {
    test('invalidate cancels the timers and stops rescheduling', () {
      fakeAsync((async) {
        final fake = _FakeMaintenanceService();
        final container = _containerWith(fake)
          ..read(maintenanceSchedulerProvider.notifier);

        async.elapse(const Duration(minutes: 3));
        expect(fake.kpCalls, 1);
        expect(fake.relayListCalls, 1);

        container.invalidate(maintenanceSchedulerProvider);

        // No reader holds the provider after invalidate, so the notifier tears
        // down and is NOT rebuilt (non-autoDispose + no watcher stays dead).
        async
          ..flushMicrotasks()
          ..elapse(const Duration(minutes: 60));
        expect(fake.kpCalls, 1, reason: 'no reschedule after invalidate');
        expect(fake.relayListCalls, 1);

        container.dispose();
      });
    });
  });

  group('MaintenanceScheduler — fail-soft', () {
    test('a throwing tick does not kill the loop; it reschedules', () {
      fakeAsync((async) {
        final fake = _FakeMaintenanceService()..throwOnKp = true;
        final container = _containerWith(fake);
        final notifier = container.read(
          maintenanceSchedulerProvider.notifier,
        );

        // First KP tick fires at ~2 min and throws (swallowed).
        async.elapse(const Duration(minutes: 3));
        expect(fake.kpCalls, 1);
        expect(
          notifier.hasArmedTimersForTest,
          isTrue,
          reason: 'a throwing tick still reschedules the next one',
        );

        // The loop is alive: a later tick fires again once it stops throwing.
        fake.throwOnKp = false;
        async.elapse(const Duration(minutes: 15));
        expect(fake.kpCalls, greaterThanOrEqualTo(2));

        container.dispose();
      });
    });
  });

  group('MaintenanceScheduler — generation fence (re-login safety)', () {
    test('invalidate + re-read reuses the instance but fences old ticks', () {
      fakeAsync((async) {
        final fake = _FakeMaintenanceService();
        final container = _containerWith(fake);
        final a = container.read(maintenanceSchedulerProvider.notifier);

        // Complete a first-generation cycle.
        async.elapse(const Duration(minutes: 3));
        final kpAfterGen1 = fake.kpCalls;
        expect(kpAfterGen1, 1);

        // Re-login: invalidate then re-read. Riverpod reuses the instance and
        // re-runs build() on it (a new generation).
        container.invalidate(maintenanceSchedulerProvider);
        final b = container.read(maintenanceSchedulerProvider.notifier);
        expect(identical(a, b), isTrue, reason: 'same instance is reused');

        // The new generation runs its own fresh cycle (no double-timer / no
        // stuck in-flight flag from the old generation).
        async.elapse(const Duration(minutes: 3));
        expect(
          fake.kpCalls,
          kpAfterGen1 + 1,
          reason: 'exactly one KP tick per generation cycle — no double-arm',
        );

        container.dispose();
      });
    });

    test('a stale in-flight tick does not re-arm after a new generation',
        () async {
      final fake = _FakeMaintenanceService()..kpGate = Completer<void>();
      final container = _containerWith(fake);
      addTearDown(container.dispose);
      final notifier = container.read(maintenanceSchedulerProvider.notifier);

      // gen-1 build armed the KP timer once.
      expect(notifier.keyPackageArmCountForTest, 1);

      // Start a gen-1 KP tick; block it mid-FFI (past its login-publish await).
      final staleTick = notifier.triggerKeyPackageTickForTest();
      await Future<void>.delayed(Duration.zero);
      expect(fake.kpCalls, 1);

      // New generation supersedes it (re-login): gen-2 build re-arms (count 2).
      container
        ..invalidate(maintenanceSchedulerProvider)
        ..read(maintenanceSchedulerProvider.notifier);
      expect(notifier.keyPackageArmCountForTest, 2);

      // Release the stale gen-1 tick. Its `finally` sees its generation is
      // superseded and must NOT arm a timer. Without the fence, it would
      // re-arm here (count → 3), orphaning gen-2's timer and spawning a second
      // loop. The fence keeps the count at 2.
      fake.kpGate!.complete();
      await staleTick;
      expect(
        notifier.keyPackageArmCountForTest,
        2,
        reason: 'superseded tick must not re-arm (no orphan / double loop)',
      );
      expect(notifier.keyPackageInFlightForTest, isFalse);
    });

    test('a stale tick does not clobber the new generation in-flight guard',
        () async {
      // Per-call gates: call 0 (gen-1 tick A) → gateA, call 1 (gen-2 tick B) →
      // gateB, so the stale and current ticks can be released independently.
      final gateA = Completer<void>();
      final gateB = Completer<void>();
      final fake = _FakeMaintenanceService()
        ..kpGateFor = ((i) => i == 0 ? gateA : gateB);
      final container = _containerWith(fake);
      addTearDown(container.dispose);
      final notifier = container.read(maintenanceSchedulerProvider.notifier);

      // gen-1 tick A: runs, blocks in the FFI (in flight).
      final tickA = notifier.triggerKeyPackageTickForTest();
      await Future<void>.delayed(Duration.zero);
      expect(fake.kpCalls, 1);
      expect(notifier.keyPackageInFlightForTest, isTrue);

      // Re-login: same instance rebuilds → gen-2 (build resets the in-flight
      // flag). Tick A is now stale but still awaiting gateA.
      container
        ..invalidate(maintenanceSchedulerProvider)
        ..read(maintenanceSchedulerProvider.notifier);

      // gen-2 tick B: runs, blocks in the FFI (in flight, guard = true).
      final tickB = notifier.triggerKeyPackageTickForTest();
      await Future<void>.delayed(Duration.zero);
      expect(fake.kpCalls, 2);
      expect(notifier.keyPackageInFlightForTest, isTrue);

      // Release the STALE gen-1 tick. Its finally must NOT clear the flag —
      // otherwise it would clobber gen-2's in-flight guard (Expected true).
      gateA.complete();
      await tickA;
      expect(
        notifier.keyPackageInFlightForTest,
        isTrue,
        reason: 'stale tick must not reset the current generation in-flight guard',
      );

      // Cleanup: release B.
      gateB.complete();
      await tickB;
    });
  });
}
