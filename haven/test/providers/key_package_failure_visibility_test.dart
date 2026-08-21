/// End-to-end proof, across the whole Dart chain, that a `KeyPackage` publish
/// which reached no relay is treated as a failure.
///
/// Every other test in this change pins one layer. This one wires all of them
/// together with no test double in between except the FFI boundary itself:
///
///   `KpMaintenanceOutcomeFfi` (the counters Rust returns)
///     → `classifyKeyPackageMaintenance`   (real)
///     → `RelayService.maintainKeyPackage` (a double that ONLY returns those
///                                          counters, unclassified)
///     → `MaintenanceService`              (real, incl. the secret scrub)
///     → `maintenanceServiceProvider`      (real)
///     → `MaintenanceSchedulerNotifier`    (real)
///     → when the next tick fires          (the observable effect)
///
/// The assertions name no outcome class and no enum value: they compare the
/// scheduler's behaviour on a zero-ack tick against its behaviour on a
/// one-ack tick, and against the nominal cadence's earliest possible firing.
/// Renaming or restructuring the outcome type cannot make them pass; only
/// re-collapsing the two cases can make them fail.
///
/// Covers:
/// - a publish acked by nobody brings the next attempt forward
/// - a publish acked by one relay does not
/// - the two are distinguishable purely from what the FFI returned
/// - a tick with no `KeyPackage` relays configured does NOT bring it forward,
///   while a tick whose configured relays were merely unreachable does — the
///   two differ only in `relaysTargeted`
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/maintenance_scheduler_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/maintenance_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
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

/// A relay service that answers with the REAL classification of a given FFI
/// tick result, and counts how many ticks it served.
///
/// It deliberately holds the raw `KpMaintenanceOutcomeFfi` and runs
/// [classifyKeyPackageMaintenance] itself, so the test's input is the same
/// value Rust hands across the bridge — the classification is under test, not
/// supplied by the test.
class _FfiShapedRelay extends MockRelayService {
  _FfiShapedRelay(this.ffiOutcome);

  KpMaintenanceOutcomeFfi ffiOutcome;
  int kpCalls = 0;

  @override
  Future<KeyPackageMaintenanceOutcome> maintainKeyPackage({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async {
    kpCalls++;
    return classifyKeyPackageMaintenance(ffiOutcome);
  }
}

final _testIdentity = Identity(
  pubkeyHex:
      'aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234',
  npub: 'npub1test',
  createdAt: DateTime(2024),
);

/// A tick that republished into a fresh slot and was acked by [relaysAcked]
/// relays. `relaysHealed == 0` is what `RelayManagerFfi` reports when
/// `publish_event` came back `AllRelaysFailed` — the event went out and no
/// relay accepted it.
///
/// `relaysTargeted` matches `respondersProbed`: a publish branch is only
/// reachable once relays are configured AND at least one answered the probe,
/// so a zero here would describe a tick the Rust side cannot produce.
KpMaintenanceOutcomeFfi _republishAckedBy(int relaysAcked) {
  return KpMaintenanceOutcomeFfi(
    action: KpMaintenanceActionFfi.republishedFreshD,
    canonicalOnRelays: 0,
    relaysTargeted: 2,
    respondersProbed: 2,
    relaysHealed: relaysAcked,
    relayErrors: relaysAcked == 0 ? 1 : 0,
    expiredInitKeyPurged: false,
    retiredMalformedSlot: false,
  );
}

/// A tick that produced no evidence at all: `decide_kp_maintenance` fails
/// closed on an empty responder set, so the FFI reports `alreadyHealthy` with
/// every observation counter at zero.
///
/// [relaysTargeted] is the ONE field that separates "the account has no
/// `KeyPackage` relays configured" (`0`) from "every configured relay was
/// unreachable this tick" (`> 0`). It is the only parameter precisely because
/// nothing else about the two situations differs — which is why they can only
/// be told apart by a caller that reads it.
KpMaintenanceOutcomeFfi _unprobedTick({required int relaysTargeted}) {
  return KpMaintenanceOutcomeFfi(
    action: KpMaintenanceActionFfi.alreadyHealthy,
    canonicalOnRelays: 0,
    relaysTargeted: relaysTargeted,
    respondersProbed: 0,
    relaysHealed: 0,
    relayErrors: 0,
    expiredInitKeyPurged: false,
    retiredMalformedSlot: false,
  );
}

ProviderContainer _containerFor(_FfiShapedRelay relay) {
  return ProviderContainer(
    overrides: [
      maintenanceServiceProvider.overrideWithValue(
        MaintenanceService(
          relayService: relay,
          circleManagerFactory: () async => _FakeCircleManager(),
          identitySecretBytes: () async => List<int>.generate(32, (i) => i),
        ),
      ),
      // The first tick's causal handoff awaits this; keep it off the FFI.
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
      identityProvider.overrideWith((_) async => _testIdentity),
    ],
  );
}

const _step = Duration(seconds: 1);

/// Steps forward until [relay] serves another tick; returns how long it took.
Duration _timeToNextTick(
  FakeAsync async,
  _FfiShapedRelay relay, {
  Duration deadline = const Duration(minutes: 25),
}) {
  final before = relay.kpCalls;
  var waited = Duration.zero;
  while (waited < deadline) {
    async
      ..elapse(_step)
      ..flushMicrotasks();
    waited += _step;
    if (relay.kpCalls > before) return waited;
  }
  fail('no KeyPackage tick arrived within $deadline');
}

void main() {
  /// The nominal cadence's earliest possible firing (10 min, jittered -25 %).
  /// Anything sooner than this cannot have come from the ordinary loop.
  const nominalFloor = Duration(minutes: 7, seconds: 30);

  group('a KeyPackage publish that reached no relay', () {
    test('brings the next attempt forward', () {
      fakeAsync((async) {
        final relay = _FfiShapedRelay(_republishAckedBy(0));
        final container = _containerFor(relay)
          ..read(maintenanceSchedulerProvider.notifier);

        _timeToNextTick(async, relay); // the scheduled first tick

        expect(
          _timeToNextTick(async, relay),
          lessThan(nominalFloor),
          reason: 'the account is uninvitable until a publish lands; the loop '
              'must not wait out a full nominal interval as if it were fine',
        );

        container.dispose();
      });
    });

    test('is distinguishable from the same publish acked by one relay', () {
      // The two runs differ ONLY in the `relaysHealed` counter — the field the
      // pre-fix Dart result type did not carry. If it is dropped again, both
      // runs produce the same schedule and this fails.
      Duration gapFor(int relaysAcked) {
        late Duration gap;
        fakeAsync((async) {
          final relay = _FfiShapedRelay(_republishAckedBy(relaysAcked));
          final container = _containerFor(relay)
            ..read(maintenanceSchedulerProvider.notifier);
          _timeToNextTick(async, relay);
          gap = _timeToNextTick(async, relay);
          container.dispose();
        });
        return gap;
      }

      final unacked = gapFor(0);
      final acked = gapFor(1);

      expect(
        acked,
        greaterThanOrEqualTo(nominalFloor),
        reason: 'an acked publish is a success and keeps the ordinary cadence',
      );
      expect(
        unacked,
        lessThan(acked),
        reason: 'a publish nobody acked must not schedule like one that landed',
      );
    });
  });

  group('a tick that reached no relay at all', () {
    test('brings the next attempt forward too', () {
      fakeAsync((async) {
        // `decide_kp_maintenance` fails closed with no responders and the FFI
        // reports `alreadyHealthy` — the literal wording of "nothing to do".
        // Nothing was verified, so the loop must come back sooner, not later.
        //
        // `relaysTargeted: 2` is what makes this the *unreachable* case rather
        // than the *unconfigured* one: the account HAS relays, they just did
        // not answer this tick. Zero here would be a different situation with
        // the opposite remedy (and the opposite schedule), so it would invert
        // what this test is named for.
        final relay = _FfiShapedRelay(_unprobedTick(relaysTargeted: 2));
        final container = _containerFor(relay)
          ..read(maintenanceSchedulerProvider.notifier);

        _timeToNextTick(async, relay);

        expect(
          _timeToNextTick(async, relay),
          lessThan(nominalFloor),
          reason: 'an unprobed tick proves nothing and must be retried',
        );

        container.dispose();
      });
    });

    test('a tick that DID confirm a canonical keeps the ordinary cadence', () {
      fakeAsync((async) {
        final relay = _FfiShapedRelay(
          const KpMaintenanceOutcomeFfi(
            action: KpMaintenanceActionFfi.alreadyHealthy,
            canonicalOnRelays: 2,
            relaysTargeted: 2,
            respondersProbed: 2,
            relaysHealed: 0,
            relayErrors: 0,
            expiredInitKeyPurged: false,
            retiredMalformedSlot: false,
          ),
        );
        final container = _containerFor(relay)
          ..read(maintenanceSchedulerProvider.notifier);

        _timeToNextTick(async, relay);

        expect(
          _timeToNextTick(async, relay),
          greaterThanOrEqualTo(nominalFloor),
          reason: 'confirmed reachability is the one case that needs no rush',
        );

        container.dispose();
      });
    });
  });

  group('a tick with no KeyPackage relays configured', () {
    test('does NOT bring the next attempt forward', () {
      fakeAsync((async) {
        // Same action, same zero counters, same relay-error tally as the
        // unreachable case above — and the opposite correct schedule. The Rust
        // tick returns here before touching the network and will keep doing so
        // until the user adds a relay, so a fast ladder is a fast loop over an
        // early return: wakeups spent to re-learn a setting.
        final relay = _FfiShapedRelay(_unprobedTick(relaysTargeted: 0));
        final container = _containerFor(relay)
          ..read(maintenanceSchedulerProvider.notifier);

        _timeToNextTick(async, relay);

        expect(
          _timeToNextTick(async, relay),
          greaterThanOrEqualTo(nominalFloor),
          reason: 'no relay is configured, so there is nothing to retry — the '
              'loop must keep the ordinary cadence and wait for the user',
        );

        container.dispose();
      });
    });

    test('schedules differently from a tick whose relays were unreachable', () {
      // The re-collapse detector. The two runs differ in exactly ONE argument
      // — `relaysTargeted` — and everything else the FFI reports is identical.
      // A classifier that ignores that field (the pre-fix shape: both become
      // one failure kind) produces the same schedule for both, and this fails.
      Duration gapFor(int relaysTargeted) {
        late Duration gap;
        fakeAsync((async) {
          final relay = _FfiShapedRelay(
            _unprobedTick(relaysTargeted: relaysTargeted),
          );
          final container = _containerFor(relay)
            ..read(maintenanceSchedulerProvider.notifier);
          _timeToNextTick(async, relay);
          gap = _timeToNextTick(async, relay);
          container.dispose();
        });
        return gap;
      }

      final unconfigured = gapFor(0);
      final unreachable = gapFor(2);

      expect(
        unconfigured,
        greaterThanOrEqualTo(nominalFloor),
        reason: 'nothing configured is not a transient condition',
      );
      expect(
        unreachable,
        lessThan(nominalFloor),
        reason: 'configured-but-down is transient and worth chasing',
      );
      expect(
        unreachable,
        lessThan(unconfigured),
        reason: 'if these two ever schedule alike, one of them is being '
            'treated as the other — the collapse this field exists to undo',
      );
    });
  });
}
