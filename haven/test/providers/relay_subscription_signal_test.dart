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
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/maintenance_service.dart';
import 'package:haven/src/services/relay_service.dart';

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
    return container.read(sharingHealthProvider);
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
    // router's `onStatus` closure is built inside `subscriptionServiceProvider`
    // and reachable only through the private router field, so this is pinned
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
      '_safeInvalidate('.allMatches(body).length,
      2,
      reason: 'two independent consumers, guarded independently — one shared '
          'guard would let a failure to reach either cost the other',
    );
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
  Future<SubscriptionHealthResult> maintainSubscriptionHealth() async =>
      outcome;

  @override
  Future<RelayListMaintenanceResult> maintainRelayList() async =>
      const RelayListMaintenanceResult.empty();

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
