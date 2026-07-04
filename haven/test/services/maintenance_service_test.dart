import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/maintenance_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_relay_service.dart';

/// A relay service that records the maintenance calls + the secret it received.
class _RecordingRelay extends MockRelayService {
  int kpCalls = 0;
  int relayListCalls = 0;
  int healthCalls = 0;
  bool throwOnHealth = false;

  /// The exact `identitySecretBytes` reference passed to the last KP call, so
  /// the test can assert the orchestrator scrubbed it afterwards.
  List<int>? capturedKpSecret;
  List<int>? capturedRelayListSecret;

  KeyPackageMaintenanceResult kpResult = const KeyPackageMaintenanceResult(
    action: KeyPackageMaintenanceAction.republishedFreshD,
    canonicalOnRelays: 2,
    relayErrors: 1,
  );

  /// Optional gate: when set, the KP call blocks on it (for overlap tests).
  Completer<void>? kpGate;

  @override
  Future<KeyPackageMaintenanceResult> maintainKeyPackage({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async {
    kpCalls++;
    capturedKpSecret = identitySecretBytes;
    if (kpGate != null) await kpGate!.future;
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
      ),
    );
  }

  @override
  Future<SubscriptionHealthResult> maintainSubscriptionHealth() async {
    healthCalls++;
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
      expect(result.action, KeyPackageMaintenanceAction.republishedFreshD);
      expect(result.canonicalOnRelays, 2);
      expect(result.relayErrors, 1);
    });

    test('scrubs the secret buffer after the call (Rule 9)', () async {
      final relay = _RecordingRelay();
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => _FakeCircleManager(),
        identitySecretBytes: () async => [9, 8, 7, 6, 5],
      );

      await service.maintainKeyPackage();

      // The orchestrator copies the secret into a buffer it owns and
      // `fillRange`s it in `finally` — the reference the relay captured must
      // now be all zeros (the security property; the concrete buffer type is
      // an implementation detail we intentionally do not assert on).
      final captured = relay.capturedKpSecret;
      expect(captured, isNotNull);
      expect(captured!.every((b) => b == 0), isTrue,
          reason: 'secret buffer must be zeroized after the FFI consumes it');
    });

    test('returns empty (never throws) when the handle factory throws',
        () async {
      final relay = _RecordingRelay();
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => throw StateError('no manager'),
        identitySecretBytes: () async => [1, 2, 3],
      );

      final result = await service.maintainKeyPackage();

      expect(relay.kpCalls, 0);
      expect(result.action, KeyPackageMaintenanceAction.alreadyHealthy);
      expect(result.canonicalOnRelays, 0);
    });

    test('returns empty (never throws) when the secret fetch throws',
        () async {
      final relay = _RecordingRelay();
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => _FakeCircleManager(),
        identitySecretBytes: () async => throw StateError('no secret'),
      );

      final result = await service.maintainKeyPackage();

      expect(relay.kpCalls, 0);
      expect(result.canonicalOnRelays, 0);
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

    test('returns empty (never throws) when a dependency throws', () async {
      final relay = _RecordingRelay();
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => throw StateError('boom'),
        identitySecretBytes: () async => [1],
      );

      final result = await service.maintainRelayList();

      expect(result.inbox.action, RelayListMaintenanceAction.alreadyCurrent);
      expect(relay.relayListCalls, 0);
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

      final result = await service.maintainSubscriptionHealth();

      expect(relay.healthCalls, 1);
      expect(result.action, SubscriptionHealthAction.resubscribed);
      expect(result.relaysTotal, 4);
      expect(result.relaysDisconnected, 1);
    });

    test('returns empty (never throws) when the relay throws', () async {
      final relay = _RecordingRelay()..throwOnHealth = true;
      final service = MaintenanceService(
        relayService: relay,
        circleManagerFactory: () async => _FakeCircleManager(),
        identitySecretBytes: () async => const [],
      );

      final result = await service.maintainSubscriptionHealth();

      expect(result.action, SubscriptionHealthAction.engineOff);
    });
  });
}
