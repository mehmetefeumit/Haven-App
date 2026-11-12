/// The engine's relay-status signals reach the sharing-health model.
///
/// Unit C's Rust half made `SyncStatusReason::RelayError` a real, emitted
/// signal — a relay ending one of our REQs with `CLOSED` (which
/// nostr-relay-pool then DELETES and never re-issues), or the ingest worker
/// dying. Those are the two ways the receive plane goes dead while every flag
/// in the app still reads healthy, and until this wiring existed nothing
/// consumed them: `syncStatusProvider` recorded a `lastIssue` nobody rendered.
///
/// Every assertion runs on the model's injected clock, so no transition here
/// depends on a wall clock or a sleep.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/maintenance_scheduler_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show FfiSyncStatusReason;
import 'package:haven/src/services/circle_health_service.dart';
import 'package:haven/src/services/circle_service.dart' show Circle;
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/maintenance_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../helpers/log_capture.dart';
import '../mocks/mock_circle_service.dart';
import '../mocks/mock_profile_service.dart';
import '../mocks/mock_relay_service.dart';

const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _peerPubkey =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

final _identity = Identity(
  pubkeyHex: _selfPubkey,
  npub: 'npub1self',
  createdAt: DateTime(2025),
);

final _t0 = DateTime.utc(2026, 8, 28, 12);

/// In-memory [CircleHealthService] — the model reads it on every derivation.
class _StubHealthService implements CircleHealthService {
  @override
  Future<void> notePublishAcked({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async {}

  @override
  Future<void> notePeerEvent({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async {}

  @override
  Future<CircleHealthTimestamps> read({
    required List<int> nostrGroupId,
  }) async => CircleHealthTimestamps.none;
}

class _Harness {
  _Harness({List<Override> extraOverrides = const []}) {
    container = ProviderContainer(
      overrides: [
        ...extraOverrides,
        sharingHealthClockProvider.overrideWithValue(() => now),
        circleHealthServiceProvider.overrideWithValue(_StubHealthService()),
        // The model reads the core's recovery cause and listens to the circle
        // list: neither may reach the real, uninitialisable circle service.
        circleServiceProvider.overrideWithValue(MockCircleService()),
        circlesProvider.overrideWith((ref) async => const <Circle>[]),
        selectedCircleProvider.overrideWithValue(
          TestCircleFactory.createCircle(
            members: [
              TestCircleFactory.createMember(pubkey: _selfPubkey),
              TestCircleFactory.createMember(pubkey: _peerPubkey),
            ],
          ),
        ),
        identityProvider.overrideWith((ref) async => _identity),
        memberLocationsProvider.overrideWith(
          (ref) async => const <MemberLocation>[],
        ),
      ],
    );
    addTearDown(container.dispose);
  }

  late final ProviderContainer container;
  DateTime now = _t0;

  SharingHealthNotifier get health =>
      container.read(sharingHealthProvider.notifier);

  /// Feeds one engine status reason through the PRODUCTION mapping.
  void status(FfiSyncStatusReason reason) =>
      recordRelaySubscriptionSignal(health, reason);

  Future<SharingHealth> settle() async {
    await container.read(identityProvider.future);
    await container.read(memberLocationsProvider.future);
    await health.refresh();
    // Which circle the verdict is about is held by its own test; the
    // assertions here are about the verdict itself.
    return container.read(sharingHealthProvider).about(null);
  }

  void advance(Duration by) => now = now.add(by);
}

void main() {
  test('a relay ending our REQ is reported as a lost subscription', () async {
    final h = _Harness();
    expect(await h.settle(), SharingHealth.healthy);

    h.status(FfiSyncStatusReason.relayError);
    expect(
      (await h.settle()).state,
      SharingHealthState.healthy,
      reason: 'a cause must stand for the confirmation window before it '
          'reaches the user — a socket that drops and comes back inside one '
          'publish cadence is ordinary mobile behaviour',
    );

    h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
    expect(await h.settle(), SharingHealth.paused(
      SharingPausedReason.receiveSubscriptionLost,
      _t0,
      // No delivery is stored, so no age is provable from the onset.
      ageProvable: false,
    ));
  });

  test('the engine reporting it reconnected clears the verdict', () async {
    // The Rust half re-issues the exact `(relay, sub)` on a jittered backoff,
    // so the clear has to come from the engine's own `Connected`, not from a
    // timeout: anything time-based would clear a subscription that is still
    // gone.
    final h = _Harness()
      ..status(FfiSyncStatusReason.relayError)
      ..advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
    expect((await h.settle()).state, SharingHealthState.paused);

    h.status(FfiSyncStatusReason.connected);
    expect(await h.settle(), SharingHealth.healthy);
  });

  test('a background resume also clears it', () async {
    // `resumeAfterBackground()` re-issues every REQ, which is exactly the
    // repair — so its status must clear the verdict the same way.
    final h = _Harness()
      ..status(FfiSyncStatusReason.relayError)
      ..advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
    expect((await h.settle()).state, SharingHealthState.paused);

    h.status(FfiSyncStatusReason.backgroundResumed);
    expect(await h.settle(), SharingHealth.healthy);
  });

  test('a re-raised loss starts a fresh outage rather than resuming the old '
      'one', () async {
    final h = _Harness()
      ..status(FfiSyncStatusReason.relayError)
      ..advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
    expect((await h.settle()).state, SharingHealthState.paused);

    h.status(FfiSyncStatusReason.connected);
    expect(await h.settle(), SharingHealth.healthy);

    final secondLoss = h.now;
    h
      ..status(FfiSyncStatusReason.relayError)
      ..advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
    expect(
      (await h.settle()).since,
      secondLoss,
      reason: 'the banner reports "last worked <age> ago"; carrying the first '
          "outage's instant forward would overstate an outage that has just "
          'started',
    );
  });

  test('reasons that say nothing about the subscription feed nothing',
      () async {
    // A per-relay socket transition is aggregated by `syncStatusProvider` into
    // the phase the model already listens to (a momentary drop on mobile is
    // not an outage), and a per-event failure says nothing about whether the
    // REQ still exists. Routing either here would fire the banner on ordinary
    // roaming — and clearing on one would hide a genuinely dead plane.
    //
    // `paused` is the deliberate ABSENCE of a subscription between background
    // bursts: raising on it would tell a user whose sharing is working that it
    // has stopped, and clearing on it would erase a real loss with a signal
    // that inspected nothing.
    for (final reason in const [
      FfiSyncStatusReason.connecting,
      FfiSyncStatusReason.reconnecting,
      FfiSyncStatusReason.disconnected,
      FfiSyncStatusReason.unprocessable,
      FfiSyncStatusReason.inboxError,
      FfiSyncStatusReason.sessionStarted,
      FfiSyncStatusReason.sessionStopped,
      FfiSyncStatusReason.paused,
    ]) {
      final raises = _Harness()
        ..status(reason)
        ..advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect(
        (await raises.settle()).state,
        SharingHealthState.healthy,
        reason: '$reason must not raise a lost-subscription verdict',
      );

      final clears = _Harness()
        ..status(FfiSyncStatusReason.relayError)
        ..advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect((await clears.settle()).state, SharingHealthState.paused);
      clears.status(reason);
      expect(
        (await clears.settle()).pausedReason,
        SharingPausedReason.receiveSubscriptionLost,
        reason: '$reason must not clear a subscription the engine has not '
            'said it re-issued',
      );
    }
  });

  test('the production status hook feeds BOTH consumers', () {
    // The mapping above is only worth testing if something calls it. The
    // router's `onStatus` closure is built inside `liveEventRouterProvider`,
    // over notifiers a host container cannot stand in for, so this is pinned
    // over the source — the same fallback `map_shell_*` tests use.
    final source = File(
      'lib/src/providers/service_providers.dart',
    ).readAsStringSync();
    final start = source.indexOf('onStatus: (reason) {');
    expect(
      start,
      isNonNegative,
      reason: "the router's status hook must exist",
    );
    final body = source.substring(start, source.indexOf('\n    },', start));
    expect(
      body.contains('syncStatusProvider.notifier).onStatus(reason)'),
      isTrue,
      reason: 'the connection phase still drives the existing status model',
    );
    expect(
      body.contains('recordRelaySubscriptionSignal('),
      isTrue,
      reason: 'without this the mapping tested above is dead code and the '
          "engine's RelayError reaches nothing that can tell the user",
    );
    expect(
      body.contains('requestCatchupOnRefetchOwed('),
      isTrue,
      reason: 'a refused object comes back only through a refetch',
    );
    final provider = source.substring(
      source.indexOf('final liveEventRouterProvider'),
      start,
    );
    expect(
      provider.contains('.runRefusedRefetch()') &&
          !provider.contains('.runCatchup('),
      isTrue,
      reason: 'a refusal runs the owing circle\'s refetch, never a full '
          'catch-up of every circle',
    );
    expect(
      '_safeInvalidate('.allMatches(body).length,
      3,
      reason: 'three independent consumers, guarded independently — one '
          'shared guard would let a failure to reach one cost the others',
    );
  });

  group('a refused object asks for a catch-up', () {
    test('refetchOwed runs the sweep once, and no other reason does', () {
      var runs = 0;
      final catchup = RefetchCatchupCoalescer(() async => runs++);
      for (final reason in FfiSyncStatusReason.values) {
        requestCatchupOnRefetchOwed(reason, catchup);
      }
      expect(runs, 1);
    });

    test('a sweep that fails is logged by its type, never thrown', () async {
      final logs = LogCapture();
      try {
        requestCatchupOnRefetchOwed(
          FfiSyncStatusReason.refetchOwed,
          RefetchCatchupCoalescer(
            () async => throw StateError('relay wss://secret.example failed'),
          ),
        );
        await pumpEventQueue();
      } finally {
        logs.restore();
      }
      logs
        ..assertContains('StateError')
        ..assertNoNeedles(['secret.example']);
    });

    test('a burst of refusals runs one refetch and one more after it, never '
        'two at once, and never two closer than the minimum interval', () async {
      var clock = DateTime.utc(2026, 10, 2, 12);
      final waits = <Duration>[];
      final sweeps = <Completer<void>>[];
      var inFlight = 0;
      var mostInFlight = 0;
      final catchup = RefetchCatchupCoalescer(
        () async {
          inFlight++;
          mostInFlight = inFlight > mostInFlight ? inFlight : mostInFlight;
          final sweep = Completer<void>();
          sweeps.add(sweep);
          await sweep.future;
          inFlight--;
          return null;
        },
        now: () => clock,
        wait: (delay) async {
          waits.add(delay);
          clock = clock.add(delay);
        },
        minInterval: const Duration(minutes: 1),
      );

      for (var i = 0; i < 5; i++) {
        requestCatchupOnRefetchOwed(FfiSyncStatusReason.refetchOwed, catchup);
      }
      await pumpEventQueue();
      expect(sweeps, hasLength(1), reason: 'one refetch runs');
      expect(waits, isEmpty, reason: 'the first runs at once');

      clock = clock.add(const Duration(seconds: 5));
      sweeps.single.complete();
      await pumpEventQueue();
      expect(
        sweeps,
        hasLength(2),
        reason: 'the requests that came during it fold into one more refetch',
      );
      expect(
        waits,
        [const Duration(seconds: 55)],
        reason: 'which starts no sooner than a minute after the first',
      );
      sweeps.last.complete();
      await pumpEventQueue();
      expect(sweeps, hasLength(2), reason: 'and nothing is owed after it');
      expect(mostInFlight, 1, reason: 'never two refetches at once');

      clock = clock.add(const Duration(minutes: 5));
      requestCatchupOnRefetchOwed(FfiSyncStatusReason.refetchOwed, catchup);
      await pumpEventQueue();
      expect(sweeps, hasLength(3), reason: 'a later refusal runs again');
      expect(waits, hasLength(1), reason: 'at once, the interval having passed');
      sweeps.last.complete();
    });
  });

  group('the health tick clears the lost-subscription latch', () {
    test('a healthy tick clears a confirmed receiveSubscriptionLost', () async {
      // THE gap this closes. The engine raises `RelayError` on every relay
      // `CLOSED`, emits NOTHING when its own jittered repair task successfully
      // re-issues the REQ, and `Connected` fires only on a socket transition —
      // which a `CLOSED` does not cause. So the latch had no reset: one
      // throttled subscription on one relay left a permanent "sharing has
      // stopped" banner up while locations kept arriving on the other relays.
      final h = _TickHarness()
        ..status(FfiSyncStatusReason.relayError)
        ..advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect(
        (await h.settle()).pausedReason,
        SharingPausedReason.receiveSubscriptionLost,
        reason: 'anti-vacuity: the banner must actually be up first',
      );

      h.maintenance.outcome = const SubscriptionHealthResult(
        action: SubscriptionHealthAction.healthy,
        relaysTotal: 3,
      );
      await h.runHealthTick();

      expect(await h.settle(), SharingHealth.healthy);
    });

    test('a resubscribed tick clears it too', () async {
      // `resubscribed` is the tick having repaired a dropped relay; every REQ
      // the session expects is present afterwards, which is the same proof.
      final h = _TickHarness()
        ..status(FfiSyncStatusReason.relayError)
        ..advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect((await h.settle()).state, SharingHealthState.paused);

      h.maintenance.outcome = const SubscriptionHealthResult(
        action: SubscriptionHealthAction.resubscribed,
        relaysTotal: 3,
        relaysDisconnected: 1,
      );
      await h.runHealthTick();

      expect(await h.settle(), SharingHealth.healthy);
    });

    test('an engine-off tick clears nothing', () async {
      // It inspected no session, so it proves nothing about the REQs. Clearing
      // on it would hide a genuinely dead receive plane behind a tick that ran
      // while the engine was not even up.
      final h = _TickHarness()
        ..status(FfiSyncStatusReason.relayError)
        ..advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect((await h.settle()).state, SharingHealthState.paused);

      h.maintenance.outcome = const SubscriptionHealthResult.empty();
      await h.runHealthTick();

      expect(
        (await h.settle()).pausedReason,
        SharingPausedReason.receiveSubscriptionLost,
      );
    });

    test('a tick that left a dropped session for the foreground clears '
        'nothing', () async {
      // It carried no foreground claim, found a relay dropped or a REQ
      // missing, and re-anchored nothing. That is the receive plane seen NOT
      // whole: the one verdict that must never read as a repair.
      final h = _TickHarness()
        ..status(FfiSyncStatusReason.relayError)
        ..advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect((await h.settle()).state, SharingHealthState.paused);

      h.maintenance.outcome = const SubscriptionHealthResult(
        action: SubscriptionHealthAction.awaitingForeground,
        relaysTotal: 3,
        relaysDisconnected: 1,
      );
      await h.runHealthTick();

      expect(
        (await h.settle()).pausedReason,
        SharingPausedReason.receiveSubscriptionLost,
      );
    });

    test('a paused tick clears nothing', () async {
      // A paused engine holds no REQ at all, so the tick short-circuited
      // before the connectivity probe and inspected nothing. Treating it as
      // proof would let every background burst interval silently clear a real
      // lost-subscription verdict.
      final h = _TickHarness()
        ..status(FfiSyncStatusReason.relayError)
        ..advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect((await h.settle()).state, SharingHealthState.paused);

      h.maintenance.outcome = const SubscriptionHealthResult(
        action: SubscriptionHealthAction.paused,
      );
      await h.runHealthTick();

      expect(
        (await h.settle()).pausedReason,
        SharingPausedReason.receiveSubscriptionLost,
      );
    });
  });
}

/// A [MaintenanceService] whose health tick returns a settable outcome.
class _StubMaintenanceService extends MaintenanceService {
  _StubMaintenanceService()
    : super(
        relayService: MockRelayService(),
        circleManagerFactory: () async =>
            throw UnimplementedError('not reached'),
        identitySecretBytes: () async => const <int>[],
      );

  SubscriptionHealthResult outcome = const SubscriptionHealthResult.empty();

  @override
  Future<SubscriptionHealthResult> maintainSubscriptionHealth({
    required bool foreground,
  }) async => outcome;

  @override
  Future<RelayListMaintenanceResult> maintainRelayList() async =>
      relayListsCurrent;

  @override
  Future<KeyPackageMaintenanceOutcome> maintainKeyPackage() async =>
      const KeyPackageMaintenanceHealthy(
        canonicalOnRelays: 1,
        respondersProbed: 1,
      );
}

/// [_Harness] plus the real `maintenanceSchedulerProvider`, so the health tick
/// under test is the production one.
class _TickHarness extends _Harness {
  /// Built per instance, never shared: a `static final` stub would carry the
  /// previous test's `outcome` into the next one, so a future case could pass
  /// on state it never set.
  factory _TickHarness() => _TickHarness._(_StubMaintenanceService());

  _TickHarness._(this.maintenance)
    : super(extraOverrides: _overrides(maintenance));

  final _StubMaintenanceService maintenance;

  static List<Override> _overrides(_StubMaintenanceService service) => [
    maintenanceServiceProvider.overrideWithValue(service),
    keyPackagePublisherProvider.overrideWith(
      (ref) => Future.value(
        const KeyPackageMaintenanceHealthy(
          canonicalOnRelays: 1,
          respondersProbed: 1,
        ),
      ),
    ),
    profileServiceProvider.overrideWithValue(MockProfileService()),
    circleServiceProvider.overrideWithValue(
      MockCircleService(circles: [TestCircleFactory.createCircle()]),
    ),
  ];

  Future<void> runHealthTick() async {
    await container
        .read(maintenanceSchedulerProvider.notifier)
        .triggerHealthTickForTest();
  }
}
