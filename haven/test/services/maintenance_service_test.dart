import 'dart:async';

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart' show ReinviteDelivery;
import 'package:haven/src/services/maintenance_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../helpers/fake_change_driver.dart';
import '../helpers/log_capture.dart';
import '../mocks/mock_relay_service.dart';

/// A relay service that records the maintenance calls + the secret it received.
class _RecordingRelay extends MockRelayService {
  int kpCalls = 0;
  int relayListCalls = 0;
  int healthCalls = 0;
  bool throwOnHealth = false;
  bool throwOnKp = false;

  /// The exact `identitySecretBytes` reference passed to the last KP call, so
  /// the test can assert the orchestrator scrubbed it afterwards.
  List<int>? capturedKpSecret;
  List<int>? capturedRelayListSecret;

  KeyPackageMaintenanceOutcome kpResult =
      const KeyPackageMaintenancePublished(
        relaysAcked: 2,
        isFreshSlotMinted: true,
        respondersProbed: 2,
        relayErrors: 1,
      );

  /// Optional gate: when set, the KP call blocks on it (for overlap tests).
  Completer<void>? kpGate;

  @override
  Future<KeyPackageMaintenanceOutcome> maintainKeyPackage({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async {
    kpCalls++;
    capturedKpSecret = identitySecretBytes;
    if (kpGate != null) await kpGate!.future;
    if (throwOnKp) throw StateError('kp boom');
    return kpResult;
  }

  @override
  Future<RelayListMaintenanceResult> maintainRelayList({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async {
    relayListCalls++;
    capturedRelayListSecret = identitySecretBytes;
    return const RelayListMaintenanceResult(
      inbox: RelayListCategoryResult(
        action: RelayListMaintenanceAction.republished,
        ownConfirmed: true,
      ),
      keyPackage: RelayListCategoryResult(
        action: RelayListMaintenanceAction.alreadyCurrent,
        ownConfirmed: true,
      ),
    );
  }

  /// The foreground claim each health tick carried, in call order.
  final List<bool> healthClaims = [];

  @override
  Future<SubscriptionHealthResult> maintainSubscriptionHealth({
    required bool foreground,
  }) async {
    healthCalls++;
    healthClaims.add(foreground);
    if (throwOnHealth) throw StateError('health boom');
    return const SubscriptionHealthResult(
      action: SubscriptionHealthAction.resubscribed,
      relaysTotal: 4,
      relaysDisconnected: 1,
    );
  }
}

/// A fake circle-manager FFI handle (never invoked by the fake relay).
class _FakeCircleManager implements CircleManagerFfi {
  /// How many times the roster was read.
  int visibleReads = 0;

  @override
  Future<List<CircleWithMembersFfi>> getVisibleCircles() async {
    visibleReads++;
    return [
      CircleWithMembersFfi(
        circle: CircleFfi(
          mlsGroupId: Uint8List.fromList(const [1, 1]),
          nostrGroupId: Uint8List.fromList(const [2, 2]),
          displayName: 'Fixture',
          circleType: 'location_sharing',
          relays: const ['wss://circle.example'],
          createdAt: 0,
          updatedAt: 0,
        ),
        membershipStatus: 'accepted',
        members: const [],
        engineState: CircleEngineStateFfi.live,
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

void main() {
  group('MaintenanceService.maintainKeyPackage', () {
    test('forwards to relay with the resolved handle + secret', () async {
      final relay = _RecordingRelay();
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => _FakeCircleManager(),
        identitySecretBytes: () async => [1, 2, 3, 4],
      );

      final result = await service.maintainKeyPackage();

      expect(relay.kpCalls, 1);
      expect(result, isA<KeyPackageMaintenancePublished>());
      final published = result as KeyPackageMaintenancePublished;
      expect(published.relaysAcked, 2);
      expect(published.isFreshSlotMinted, isTrue);
      expect(published.relayErrors, 1);
    });

    test('scrubs the secret buffer after the call (Rule 9)', () async {
      final relay = _RecordingRelay();
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => _FakeCircleManager(),
        identitySecretBytes: () async => [9, 8, 7, 6, 5],
      );

      final outcome = await service.maintainKeyPackage();
      expect(outcome, isA<KeyPackageMaintenancePublished>());

      // The orchestrator copies the secret into a buffer it owns and
      // `fillRange`s it in `finally` — the reference the relay captured must
      // now be all zeros (the security property; the concrete buffer type is
      // an implementation detail we intentionally do not assert on).
      final captured = relay.capturedKpSecret;
      expect(captured, isNotNull);
      expect(captured!.every((b) => b == 0), isTrue,
          reason: 'secret buffer must be zeroized after the FFI consumes it');
    });

    test(
        'reports a failure (never throws, never health) when the handle '
        'factory throws', () async {
      final relay = _RecordingRelay();
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => throw StateError('no manager'),
        identitySecretBytes: () async => [1, 2, 3],
      );

      final result = await service.maintainKeyPackage();

      expect(relay.kpCalls, 0);
      expect(result, isA<KeyPackageMaintenanceFailed>());
      expect(
        (result as KeyPackageMaintenanceFailed).kind,
        KeyPackageFailureKind.tickErrored,
      );
      expect(
        result.disposition,
        KeyPackageRetryDisposition.retryLater,
        reason: 'a broken local handle is worth retrying, but not in a loop',
      );
    });

    test(
        'reports identityUnavailable (never health) when the secret fetch '
        'throws', () async {
      final relay = _RecordingRelay();
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => _FakeCircleManager(),
        identitySecretBytes: () async => throw StateError('no secret'),
      );

      final result = await service.maintainKeyPackage();

      expect(relay.kpCalls, 0);
      expect(result, isA<KeyPackageMaintenanceFailed>());
      expect(
        (result as KeyPackageMaintenanceFailed).kind,
        KeyPackageFailureKind.identityUnavailable,
        reason: 'no secret to sign with is not the same failure as a broken '
            'FFI call, and does not warrant the same retry',
      );
      expect(
        result.disposition,
        KeyPackageRetryDisposition.awaitUserAction,
      );
    });

    test('reports tickErrored (never health) when the relay call throws',
        () async {
      final relay = _RecordingRelay()..throwOnKp = true;
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => _FakeCircleManager(),
        identitySecretBytes: () async => [1, 2, 3],
      );

      final result = await service.maintainKeyPackage();

      expect(result, isA<KeyPackageMaintenanceFailed>());
      expect(
        (result as KeyPackageMaintenanceFailed).kind,
        KeyPackageFailureKind.tickErrored,
      );
    });

    test('passes a relay-reported failure straight through', () async {
      // The relay layer classifies the FFI counters; the orchestrator must not
      // launder that verdict into anything softer on its way out.
      final relay = _RecordingRelay()
        ..kpResult = const KeyPackageMaintenanceFailed(
          KeyPackageFailureKind.publishNotAcked,
          relayErrors: 1,
        );
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => _FakeCircleManager(),
        identitySecretBytes: () async => [1, 2, 3],
      );

      final result = await service.maintainKeyPackage();

      expect(result, isA<KeyPackageMaintenanceFailed>());
      expect(
        (result as KeyPackageMaintenanceFailed).kind,
        KeyPackageFailureKind.publishNotAcked,
      );
    });

    test('scrubs the secret buffer even when the tick fails (Rule 9)',
        () async {
      // Fail-soft must not cost the scrub: the `finally` runs on the failure
      // path too, or a failing relay would leave the secret in the Dart heap.
      final relay = _RecordingRelay()..throwOnKp = true;
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => _FakeCircleManager(),
        identitySecretBytes: () async => [3, 1, 4, 1, 5],
      );

      final outcome = await service.maintainKeyPackage();
      expect(outcome, isA<KeyPackageMaintenanceFailed>());

      final captured = relay.capturedKpSecret;
      expect(captured, isNotNull);
      expect(captured!.every((b) => b == 0), isTrue);
    });
  });

  group('MaintenanceService.maintainRelayList', () {
    test('forwards to relay + returns the mapped outcome', () async {
      final relay = _RecordingRelay();
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => _FakeCircleManager(),
        identitySecretBytes: () async => [1, 2, 3],
      );

      final result = await service.maintainRelayList();

      expect(relay.relayListCalls, 1);
      expect(result.inbox.action, RelayListMaintenanceAction.republished);
    });

    test('scrubs the secret buffer after the call', () async {
      final relay = _RecordingRelay();
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => _FakeCircleManager(),
        identitySecretBytes: () async => [4, 5, 6],
      );

      await service.maintainRelayList();

      final captured = relay.capturedRelayListSecret;
      expect(captured, isNotNull);
      expect(captured!.every((b) => b == 0), isTrue);
    });

    test('a dependency that throws reads as failed, never as current',
        () async {
      // The `.empty()` this replaced answered `alreadyCurrent` here, so a
      // tick that never ran was indistinguishable from a healthy one and the
      // scheduler slept a full 30 minutes on it.
      final relay = _RecordingRelay();
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => throw StateError('boom'),
        identitySecretBytes: () async => [1],
      );

      final result = await service.maintainRelayList();

      expect(relay.relayListCalls, 0);
      for (final category in [result.inbox, result.keyPackage]) {
        expect(category.action, RelayListMaintenanceAction.failed);
        expect(category.ownConfirmed, isFalse);
      }
      expect(result.needsPromptRetry, isTrue);
    });
  });

  group('MaintenanceService.maintainSubscriptionHealth', () {
    test('forwards to relay (no secret / no circle handle resolved)', () async {
      final relay = _RecordingRelay();
      final service = MaintenanceService(
        relayService: relay,
        // These MUST NOT be resolved for the health task — it needs neither.
        circleManagerFactory: () async => throw StateError('must not resolve'),
        identitySecretBytes: () async => throw StateError('must not resolve'),
      );

      final result = await service.maintainSubscriptionHealth(foreground: true);

      expect(relay.healthCalls, 1);
      expect(result.action, SubscriptionHealthAction.resubscribed);
      expect(result.relaysTotal, 4);
      expect(result.relaysDisconnected, 1);
    });

    test('hands the foreground claim on exactly as it was given', () async {
      // The claim is the caller's strict lifecycle read. A service that
      // defaulted it, or passed a constant, would be a second place the
      // foreground is decided.
      final relay = _RecordingRelay();
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => throw StateError('must not resolve'),
        identitySecretBytes: () async => throw StateError('must not resolve'),
      );

      await service.maintainSubscriptionHealth(foreground: false);
      await service.maintainSubscriptionHealth(foreground: true);
      await service.maintainSubscriptionHealth(foreground: false);

      expect(relay.healthClaims, [false, true, false]);
    });

    test('returns empty (never throws) when the relay throws', () async {
      final relay = _RecordingRelay()..throwOnHealth = true;
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => _FakeCircleManager(),
        identitySecretBytes: () async => const [],
      );

      final result = await service.maintainSubscriptionHealth(foreground: true);

      expect(result.action, SubscriptionHealthAction.engineOff);
    });
  });

  group('MaintenanceService.carryOnLeaves', () {
    test("hands the driver the caller's lifecycle read, and none for a burst",
        () async {
      final driver = FakeChangeDriver();
      final manager = _FakeCircleManager();
      final service = MaintenanceService(
        relayService: MockRelayService(),
        circleManagerFactory: () async => manager,
        identitySecretBytes: () async => const [],
        changeDriver: driver,
      );

      await service.carryOnLeaves(inFront: () => true);
      await service.carryOnLeaves();

      expect(manager.visibleReads, 2);
      expect(driver.foregrounds, [true, false]);
    });

    test('a manager that cannot be built asks nothing and logs a type alone',
        () async {
      final logs = LogCapture.install();
      addTearDown(logs.restore);
      final driver = FakeChangeDriver();
      final service = MaintenanceService(
        relayService: MockRelayService(),
        circleManagerFactory: () async =>
            throw StateError('store at wss://planted.example'),
        identitySecretBytes: () async => const [],
        changeDriver: driver,
      );

      expect((await service.carryOnLeaves(inFront: () => true)).left, isEmpty);
      expect(driver.calls, isEmpty);
      logs
        ..assertContains('[Maintenance] leave carry-on failed')
        ..assertNoNeedles(['wss://planted.example']);
    });
  });

  group('MaintenanceService.forget', () {
    test("drops every wait an identity's leaves and drives named", () async {
      final now = DateTime.utc(2026, 10, 17, 12);
      final driver = FakeChangeDriver()
        ..resumeLeaveOutcomes = {
          '1,1': LeaveOutcomeFfi(
            status: LeaveStatusFfi.proposed,
            retryAfterMs: BigInt.from(60000),
          ),
        }
        ..resumeOutcome = ResumeOutcomeFfi(
          withdrawn: const [],
          requeued: const [],
          replayed: const [],
          retryAfterMs: BigInt.from(60000),
          errored: false,
        );
      final service = MaintenanceService(
        relayService: MockRelayService(),
        circleManagerFactory: () async => _FakeCircleManager(),
        identitySecretBytes: () async => const [],
        changeDriver: driver,
        clock: () => now,
      );
      Future<void> wake() async {
        await service.carryOnLeaves(inFront: () => true);
        await service.resumeDrive(foreground: true);
      }

      await wake();
      await wake();
      expect(
        driver.calls,
        ['resumeLeave', 'resume'],
        reason: 'premise: both waits hold',
      );

      service.forget();
      await wake();
      expect(driver.calls, ['resumeLeave', 'resume', 'resumeLeave', 'resume']);
    });
  });

  group('MaintenanceService.forget, racing work in flight', () {
    test('a leave carry-on or a drive that answers after the forget writes '
        'no wait back', () async {
      final now = DateTime.utc(2026, 10, 17, 12);
      final release = Completer<void>();
      final driver = FakeChangeDriver()
        ..hold = release.future
        ..resumeLeaveOutcomes = {
          '1,1': LeaveOutcomeFfi(
            status: LeaveStatusFfi.proposed,
            retryAfterMs: BigInt.from(60000),
          ),
        }
        ..resumeOutcome = ResumeOutcomeFfi(
          withdrawn: const [],
          requeued: const [],
          replayed: const [],
          retryAfterMs: BigInt.from(60000),
          errored: false,
        );
      final service = MaintenanceService(
        relayService: MockRelayService(),
        circleManagerFactory: () async => _FakeCircleManager(),
        identitySecretBytes: () async => const [],
        changeDriver: driver,
        clock: () => now,
      );

      final carry = service.carryOnLeaves(inFront: () => true);
      final drive = service.resumeDrive(foreground: true);
      await pumpEventQueue();
      expect(
        driver.calls,
        unorderedEquals(['resumeLeave', 'resume']),
        reason: 'premise: both are in flight',
      );
      service.forget();
      release.complete();
      await carry;
      await drive;

      driver.hold = null;
      await service.carryOnLeaves(inFront: () => true);
      await service.resumeDrive(foreground: true);
      expect(
        driver.calls.skip(2),
        ['resumeLeave', 'resume'],
        reason: "the previous identity's waits landed after its forget and "
            "held back the next identity's first wake",
      );
    });
  });

  group('MaintenanceService.reinviteOwed', () {
    MaintenanceService service(
      FakeChangeDriver driver, {
      DateTime Function()? clock,
      void Function(List<LocationMessageResultFfi>)? onReplayed,
    }) => MaintenanceService(
      relayService: MockRelayService(),
      circleManagerFactory: () async => _FakeCircleManager(),
      identitySecretBytes: () async => const [],
      changeDriver: driver,
      clock: clock ?? DateTime.now,
      onReplayed: onReplayed,
    );

    ResumeOutcomeFfi drive({
      BigInt? retryAfterMs,
      bool errored = false,
      List<LocationMessageResultFfi> replayed = const [],
    }) => ResumeOutcomeFfi(
      withdrawn: const [],
      requeued: const [],
      replayed: replayed,
      retryAfterMs: retryAfterMs,
      errored: errored,
    );

    test('the stored-record drive honours its own wait and hands its replay '
        'on', () async {
      var now = DateTime.utc(2026, 10, 16, 12);
      final seen = <List<LocationMessageResultFfi>>[];
      final replay = [
        LocationMessageResultFfi(
          kind: LocationMessageResultKindFfi.unrecoverable,
          mlsGroupId: Uint8List.fromList(const [1]),
          epoch: BigInt.zero,
        ),
      ];
      final driver = FakeChangeDriver()
        ..resumeOutcome = drive(
          retryAfterMs: BigInt.from(30000),
          replayed: replay,
        );
      final maintenance = service(
        driver,
        clock: () => now,
        onReplayed: seen.add,
      );

      await maintenance.resumeDrive(foreground: true);
      now = now.add(const Duration(seconds: 29));
      await maintenance.resumeDrive(foreground: true);
      now = now.add(const Duration(seconds: 1));
      await maintenance.resumeDrive(foreground: false);

      expect(driver.calls, ['resume', 'resume']);
      expect(driver.foregrounds, [true, false], reason: 'handed on untouched');
      expect(seen, [replay, replay]);
    });

    test('a failing or errored drive logs no identifier', () async {
      final logs = LogCapture.install();
      addTearDown(logs.restore);
      final driver = FakeChangeDriver()
        ..resumeOutcome = drive(errored: true);
      await service(driver).resumeDrive(foreground: true);
      driver.throws = StateError('circle 0xdeadbeefcafe at wss://private.x');
      await service(driver).resumeDrive(foreground: true);

      logs
        ..assertContains('drive ended on an error')
        ..assertContains('drive failed')
        ..assertNoNeedles(['deadbeefcafe', 'wss://private.x']);
    });

    test("the drive's wait does not hold MDK's re-invite lookups back",
        () async {
      // Before: the next tick inside the drive's named wait asked nothing,
      // pushing MDK's own pacing (5 s, 30 s, 2 min…) out to that wait. The
      // lookups and the records keep their own schedules in Rust, so a tick
      // re-asks nothing that is not due.
      var now = DateTime.utc(2026, 10, 16, 12);
      final driver = FakeChangeDriver()
        ..reinviteDrive = drive(retryAfterMs: BigInt.from(3600000));
      final maintenance = service(driver, clock: () => now);

      await maintenance.reinviteOwed(foreground: true);
      now = now.add(const Duration(minutes: 15));
      await maintenance.reinviteOwed(foreground: true);

      expect(driver.calls, ['reinvite', 'reinvite']);
    });

    test("the drive's replay is handed on for conversion, and an errored "
        'drive is logged with no identifier', () async {
      final logs = LogCapture.install();
      addTearDown(logs.restore);
      final replay = [
        LocationMessageResultFfi(
          kind: LocationMessageResultKindFfi.unrecoverable,
          mlsGroupId: Uint8List.fromList(const [0xde, 0xad, 0xbe, 0xef]),
          epoch: BigInt.zero,
        ),
      ];
      final seen = <List<LocationMessageResultFfi>>[];
      final driver = FakeChangeDriver()
        ..reinviteDrive = drive(errored: true, replayed: replay);

      await service(driver, onReplayed: seen.add).reinviteOwed(
        foreground: true,
      );

      expect(seen, [replay]);
      logs
        ..assertContains('re-invite drive ended on an error')
        ..assertNoNeedles(['deadbeef']);
    });

    test('away from the foreground, the driver is not asked at all', () async {
      final driver = FakeChangeDriver();

      expect(await service(driver).reinviteOwed(foreground: false), isEmpty);
      expect(driver.calls, isEmpty, reason: 'a relay asked for nothing due');
    });

    test('in the foreground, each result is classified by variant', () async {
      final driver = FakeChangeDriver()
        ..reinvites = [
          for (final result in [
            ReinviteResultFfi.reissuedAwaitingRelays,
            ReinviteResultFfi.notDue,
            ReinviteResultFfi.gaveUp,
          ])
            ReinviteFfi(mlsGroupId: Uint8List(1), result: result),
        ];

      expect(await service(driver).reinviteOwed(foreground: true), [
        ReinviteDelivery.awaitingRelays,
        ReinviteDelivery.stillOwed,
        ReinviteDelivery.needsReinvite,
      ]);
      expect(driver.foregrounds, [true]);
    });

    test('a failing driver answers none and logs no identifier', () async {
      final logs = LogCapture.install();
      addTearDown(logs.restore);
      final driver = FakeChangeDriver()
        ..throws = StateError('circle 0xdeadbeefcafe relay wss://private.x');

      expect(await service(driver).reinviteOwed(foreground: true), isEmpty);
      logs
        ..assertContains('re-invite failed')
        ..assertNoNeedles(['deadbeefcafe', 'wss://private.x']);
    });
  });
}
