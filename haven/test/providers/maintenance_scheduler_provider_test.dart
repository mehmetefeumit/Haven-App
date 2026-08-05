import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/profile_refresh_tiers.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/maintenance_scheduler_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/maintenance_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_profile_service.dart';
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

  /// What the KP task reports. Defaults to a confirmed-healthy tick; set it to
  /// a [KeyPackageMaintenanceFailed] to drive the retry ladder.
  KeyPackageMaintenanceOutcome kpOutcome = const KeyPackageMaintenanceHealthy(
    canonicalOnRelays: 1,
    respondersProbed: 1,
  );

  @override
  Future<KeyPackageMaintenanceOutcome> maintainKeyPackage() async {
    final callIndex = kpCalls;
    kpCalls++;
    if (throwOnKp) throw StateError('kp boom');
    final gate = kpGateFor?.call(callIndex) ?? kpGate;
    if (gate != null) await gate.future;
    return kpOutcome;
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

/// Identity used by the profile anti-entropy tick's roster union.
final _testIdentity = Identity(
  pubkeyHex:
      'dddd1234dddd1234dddd1234dddd1234dddd1234dddd1234dddd1234dddd1234',
  npub: 'npub1test',
  createdAt: DateTime(2024),
);

/// Builds a container overriding the maintenance service (with [fake]) AND the
/// login-publish provider (so the first KeyPackage tick's causal handoff does
/// not try to build the real publisher). [loginPublish] defaults to an
/// immediately-resolved success.
ProviderContainer _containerWith(
  _FakeMaintenanceService fake, {
  Future<KeyPackageMaintenanceOutcome>? loginPublish,
  MockProfileService? profileService,
}) {
  return ProviderContainer(
    overrides: [
      maintenanceServiceProvider.overrideWithValue(fake),
      keyPackagePublisherProvider.overrideWith(
        (ref) =>
            loginPublish ??
            Future.value(
              const KeyPackageMaintenanceHealthy(
                canonicalOnRelays: 1,
                respondersProbed: 1,
              ),
            ),
      ),
      // The profile anti-entropy tick resolves the roster union through the
      // circle + identity providers. Without these the tick would reach the
      // real keyring/FFI, so an unrelated scheduling assertion could fail on
      // a secure-storage error that has nothing to do with scheduling.
      profileServiceProvider.overrideWithValue(
        profileService ?? MockProfileService(),
      ),
      circleServiceProvider.overrideWithValue(
        MockCircleService(circles: [TestCircleFactory.createCircle()]),
      ),
      identityProvider.overrideWith((_) async => _testIdentity),
    ],
  );
}

/// Granularity of [_timeToNextKpTick]'s sampling — every measured gap is
/// accurate to within one of these.
const _tickSamplingStep = Duration(seconds: 1);

/// Steps [async] forward until [fake] records another `KeyPackage` tick, and
/// returns how long that took.
///
/// Measures WHEN the loop actually came back, which is the only externally
/// visible consequence of the scheduler having understood the outcome. Fails
/// the test if no tick arrives inside [deadline].
Duration _timeToNextKpTick(
  FakeAsync async,
  _FakeMaintenanceService fake, {
  Duration deadline = const Duration(minutes: 25),
}) {
  final before = fake.kpCalls;
  var waited = Duration.zero;
  while (waited < deadline) {
    async
      ..elapse(_tickSamplingStep)
      ..flushMicrotasks();
    waited += _tickSamplingStep;
    if (fake.kpCalls > before) return waited;
  }
  fail('no KeyPackage tick arrived within $deadline');
}

/// Matches a duration inside the scheduler's documented ±25 % jitter envelope
/// around [nominal], allowing one sampling step of slack on each side.
Matcher _withinJitterOf(Duration nominal) => allOf(
      greaterThanOrEqualTo(nominal * 0.75 - _tickSamplingStep),
      lessThanOrEqualTo(nominal * 1.25 + _tickSamplingStep),
    );

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
        final loginPublish = Completer<KeyPackageMaintenanceOutcome>();
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
        loginPublish.complete(
          const KeyPackageMaintenanceHealthy(
            canonicalOnRelays: 1,
            respondersProbed: 1,
          ),
        );
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
          loginPublish: Completer<KeyPackageMaintenanceOutcome>().future,
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

  group('MaintenanceScheduler — profile anti-entropy', () {
    /// Counts batched profile refreshes reaching the service.
    int refreshes(MockProfileService svc) =>
        svc.methodCalls
            .where((c) => c.method == 'refreshMemberProfiles')
            .length;

    test('does not fire before its initial settle delay', () {
      fakeAsync((async) {
        final svc = MockProfileService();
        final container = _containerWith(
          _FakeMaintenanceService(),
          profileService: svc,
        )..read(maintenanceSchedulerProvider.notifier);

        // MapShell already fires a cold-start refresh ~5 s in, so an early
        // tick here would be a guaranteed duplicate.
        async
          ..flushMicrotasks()
          ..elapse(const Duration(minutes: 9));
        expect(refreshes(svc), 0);

        container.dispose();
      });
    });

    test('fires after the initial delay and self-reschedules', () {
      fakeAsync((async) {
        final svc = MockProfileService();
        final container = _containerWith(
          _FakeMaintenanceService(),
          profileService: svc,
        )..read(maintenanceSchedulerProvider.notifier);

        async
          ..elapse(const Duration(minutes: 11))
          ..flushMicrotasks();
        expect(refreshes(svc), 1, reason: 'first tick at the 10 min settle');

        // Nominal 45 min ±25 % → the next tick lands by 56.25 min at worst.
        async
          ..elapse(const Duration(minutes: 57))
          ..flushMicrotasks();
        expect(
          refreshes(svc),
          greaterThanOrEqualTo(2),
          reason: 'the sweep must re-arm itself, not fire once',
        );

        container.dispose();
      });
    });

    test('uses the periodic staleness tier, not a forced fetch', () {
      fakeAsync((async) {
        final svc = MockProfileService();
        final container = _containerWith(
          _FakeMaintenanceService(),
          profileService: svc,
        )..read(maintenanceSchedulerProvider.notifier);

        async
          ..elapse(const Duration(minutes: 11))
          ..flushMicrotasks();

        final call = svc.methodCalls.firstWhere(
          (c) => c.method == 'refreshMemberProfiles',
        );
        expect(
          call.args['maxAge'],
          equals(profilePeriodicMaxAge),
          reason: 'an automatic sweep must never force a refetch',
        );

        container.dispose();
      });
    });

    test('jitters within ±25 % of the nominal interval', () {
      // Pin the documented jitter envelope: successive ticks must never land
      // on a fixed cadence (relay-correlation hardening), but must still stay
      // inside the advertised window.
      const step = Duration(seconds: 5);
      final gaps = <Duration>[];
      for (var run = 0; run < 12; run++) {
        fakeAsync((async) {
          final svc = MockProfileService();
          final container = _containerWith(
            _FakeMaintenanceService(),
            profileService: svc,
          )..read(maintenanceSchedulerProvider.notifier);

          // Step from t=0 and record when each tick actually lands. Measuring
          // between the two observed firings (rather than from an arbitrary
          // elapse point) keeps the gap free of any initial-delay offset.
          var elapsed = Duration.zero;
          Duration? firstAt;
          Duration? secondAt;
          const deadline = Duration(minutes: 90);
          while (secondAt == null && elapsed < deadline) {
            async
              ..elapse(step)
              ..flushMicrotasks();
            elapsed += step;
            if (firstAt == null && refreshes(svc) >= 1) {
              firstAt = elapsed;
            } else if (firstAt != null && refreshes(svc) >= 2) {
              secondAt = elapsed;
            }
          }
          expect(secondAt, isNotNull, reason: 'a second tick must arrive');
          gaps.add(secondAt! - firstAt!);
          container.dispose();
        });
      }

      const nominal = profileAntiEntropyInterval;
      // ±1 sampling step of granularity on each bound.
      final minAllowed = nominal * 0.75 - step;
      final maxAllowed = nominal * 1.25 + step;
      for (final gap in gaps) {
        expect(gap, greaterThanOrEqualTo(minAllowed));
        expect(gap, lessThanOrEqualTo(maxAllowed));
      }
      expect(
        gaps.toSet().length,
        greaterThan(1),
        reason: 'a fixed cadence would be a relay-correlation regression',
      );
    });

    test('skips the fetch while backgrounded but keeps re-arming', () async {
      // MapShell is NOT disposed when the app backgrounds (the main isolate
      // stays alive for background location sharing), so widget lifetime is not
      // a foreground proxy. Without an explicit lifecycle check this sweep
      // would
      // contact discovery relays with no UI to render the result.
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      final svc = MockProfileService();
      final container = _containerWith(
        _FakeMaintenanceService(),
        profileService: svc,
      );
      addTearDown(container.dispose);
      final notifier = container.read(maintenanceSchedulerProvider.notifier);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      addTearDown(
        () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
      );

      await notifier.triggerProfileAntiEntropyTickForTest();
      expect(
        svc.methodCalls.where((c) => c.method == 'refreshMemberProfiles'),
        isEmpty,
        reason: 'a backgrounded tick must not contact any relay',
      );
      expect(
        notifier.profileAntiEntropyArmedForTest,
        isTrue,
        reason: 'a skipped sweep must still re-arm for the next window',
      );

      // Foreground again → the very next tick does fetch.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await notifier.triggerProfileAntiEntropyTickForTest();
      // `refreshAll` dispatches a fire-and-forget batch; drain it.
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        svc.methodCalls.where((c) => c.method == 'refreshMemberProfiles'),
        hasLength(1),
      );
    });

    test('a throwing tick does not kill its loop', () async {
      final svc = MockProfileService()..shouldThrowOnRefreshMemberProfiles = true;
      final container = _containerWith(
        _FakeMaintenanceService(),
        profileService: svc,
      );
      addTearDown(container.dispose);
      final notifier = container.read(maintenanceSchedulerProvider.notifier);

      await notifier.triggerProfileAntiEntropyTickForTest();
      expect(
        notifier.profileAntiEntropyArmedForTest,
        isTrue,
        reason: 'a failed sweep still reschedules',
      );
    });

    test('is cancelled on dispose (no background profile fetches)', () {
      fakeAsync((async) {
        final svc = MockProfileService();
        final container = _containerWith(
          _FakeMaintenanceService(),
          profileService: svc,
        )..read(maintenanceSchedulerProvider.notifier);

        async
          ..elapse(const Duration(minutes: 11))
          ..flushMicrotasks();
        expect(refreshes(svc), 1);

        // Tearing down the scheduler (logout / MapShell unmount) must stop
        // the sweep — profile fetches are foreground-only by construction.
        container.invalidate(maintenanceSchedulerProvider);
        async
          ..flushMicrotasks()
          ..elapse(const Duration(hours: 2));
        expect(refreshes(svc), 1, reason: 'no sweep after teardown');

        container.dispose();
      });
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

  // -------------------------------------------------------------------------
  // The scheduler is the consumer that ACTS on the three-way KeyPackage
  // outcome. Before it could tell a failure from health, a `KeyPackage` that
  // reached no relay left the account uninvitable and the loop went back to
  // sleep for a full jittered 10 minutes, exactly as if everything were fine.
  //
  // These assert the effect — when the next tick actually fires — not that
  // some method was called on a double.
  // -------------------------------------------------------------------------
  group('MaintenanceScheduler — KeyPackage retry on failure', () {
    /// The nominal cadence's earliest possible firing (jitter floor). Every
    /// retry must land strictly inside this, or it is not a retry.
    const nominalFloor = Duration(minutes: 7, seconds: 30);

    test('a failed tick retries long before the nominal cadence could', () {
      fakeAsync((async) {
        final fake = _FakeMaintenanceService()
          ..kpOutcome = const KeyPackageMaintenanceFailed(
            KeyPackageFailureKind.publishNotAcked,
          );
        final container = _containerWith(fake)
          ..read(maintenanceSchedulerProvider.notifier);

        // The first tick is the scheduled one at its 2 min initial delay.
        _timeToNextKpTick(async, fake);

        final retry = _timeToNextKpTick(async, fake);
        expect(
          retry,
          lessThan(nominalFloor),
          reason: 'the nominal cadence cannot fire this early — so this tick '
              'exists only because the failure was visible to the scheduler',
        );
        expect(
          retry,
          _withinJitterOf(keyPackageRetryPromptDelay),
          reason: 'a relay-side failure retries on the prompt ladder',
        );

        container.dispose();
      });
    });

    test('the retry ladder widens while the failure persists', () {
      fakeAsync((async) {
        final fake = _FakeMaintenanceService()
          ..kpOutcome = const KeyPackageMaintenanceFailed(
            KeyPackageFailureKind.noRelayResponded,
          );
        final container = _containerWith(fake)
          ..read(maintenanceSchedulerProvider.notifier);

        _timeToNextKpTick(async, fake); // the scheduled first tick

        // 60 s, 2 min, 4 min, then capped at 5 min — each jittered ±25 %.
        final expected = <Duration>[
          keyPackageRetryPromptDelay,
          keyPackageRetryPromptDelay * 2,
          keyPackageRetryPromptDelay * 4,
          keyPackageRetryMaxDelay,
        ];
        for (var i = 0; i < expected.length; i++) {
          final gap = _timeToNextKpTick(async, fake);
          expect(
            gap,
            _withinJitterOf(expected[i]),
            reason: 'retry ${i + 1} should sit on the ladder at ${expected[i]}',
          );
          expect(
            gap,
            lessThan(nominalFloor),
            reason: 'no rung of the ladder may be slower than doing nothing',
          );
        }

        container.dispose();
      });
    });

    test('a healthy tick clears the ladder and restores the nominal cadence',
        () {
      fakeAsync((async) {
        final fake = _FakeMaintenanceService()
          ..kpOutcome = const KeyPackageMaintenanceFailed(
            KeyPackageFailureKind.publishNotAcked,
          );
        final container = _containerWith(fake)
          ..read(maintenanceSchedulerProvider.notifier);

        _timeToNextKpTick(async, fake); // scheduled first tick
        _timeToNextKpTick(async, fake); // retry 1 (ladder now at 2 min)
        _timeToNextKpTick(async, fake); // retry 2 (ladder now at 4 min)

        // The relays come back.
        fake.kpOutcome = const KeyPackageMaintenanceHealthy(
          canonicalOnRelays: 1,
          respondersProbed: 1,
        );
        _timeToNextKpTick(async, fake); // the tick that observes health

        final afterRecovery = _timeToNextKpTick(async, fake);
        expect(
          afterRecovery,
          greaterThanOrEqualTo(nominalFloor),
          reason: 'one bad relay window must not permanently accelerate the '
              'loop — a confirmed-healthy tick resets the streak',
        );
        expect(afterRecovery, _withinJitterOf(keyPackageMaintenanceInterval));

        container.dispose();
      });
    });

    test('a published tick also clears the ladder', () {
      fakeAsync((async) {
        final fake = _FakeMaintenanceService()
          ..kpOutcome = const KeyPackageMaintenanceFailed(
            KeyPackageFailureKind.publishNotAcked,
          );
        final container = _containerWith(fake)
          ..read(maintenanceSchedulerProvider.notifier);

        _timeToNextKpTick(async, fake); // scheduled first tick
        _timeToNextKpTick(async, fake); // retry 1

        fake.kpOutcome = const KeyPackageMaintenancePublished(
          relaysAcked: 1,
          mintedFreshSlot: true,
        );
        _timeToNextKpTick(async, fake); // the tick that lands the publish

        expect(
          _timeToNextKpTick(async, fake),
          greaterThanOrEqualTo(nominalFloor),
          reason: 'an acked publish is a success, same as health',
        );

        container.dispose();
      });
    });

    test('a missing identity does NOT accelerate the loop', () {
      fakeAsync((async) {
        // Nothing to retry: no secret means nothing can be signed, and
        // re-login rebuilds the scheduler anyway. Escalating here would just
        // spin the timer against a logged-out app.
        final fake = _FakeMaintenanceService()
          ..kpOutcome = const KeyPackageMaintenanceFailed(
            KeyPackageFailureKind.identityUnavailable,
          );
        final container = _containerWith(fake)
          ..read(maintenanceSchedulerProvider.notifier);

        _timeToNextKpTick(async, fake); // scheduled first tick

        expect(
          _timeToNextKpTick(async, fake),
          greaterThanOrEqualTo(nominalFloor),
          reason: 'awaitUserAction keeps the ordinary cadence',
        );

        container.dispose();
      });
    });

    test('a throwing tick backs off rather than looping fast', () {
      fakeAsync((async) {
        // A throw from the service is a local breakage, not a relay one: it
        // gets the slower `retryLater` delay, still inside the nominal floor.
        final fake = _FakeMaintenanceService()..throwOnKp = true;
        final container = _containerWith(fake)
          ..read(maintenanceSchedulerProvider.notifier);

        _timeToNextKpTick(async, fake); // scheduled first tick

        final gap = _timeToNextKpTick(async, fake);
        expect(gap, _withinJitterOf(keyPackageRetryLaterDelay));
        expect(
          gap,
          greaterThan(keyPackageRetryPromptDelay * 1.25),
          reason: 'a broken local call must not be hammered on the prompt '
              'ladder',
        );
        expect(gap, lessThan(nominalFloor));

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
