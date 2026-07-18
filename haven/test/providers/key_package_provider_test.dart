/// Tests for the key package provider.
///
/// Dark Matter DM-4b note: `keyPackagePublisherProvider` used to sign +
/// publish the kind 30443/443 KeyPackage pair and the kind 10050/10051
/// relay lists itself (see the deleted `_MockRelayService` /
/// `_SelectiveRelayService` / `_FailingCircleService` fixtures this file
/// used to carry). That whole sign/publish/record/delete sequence now lives
/// entirely behind `RelayManagerFfi.maintainKeyPackage` (wrapped by
/// `MaintenanceService`, already covered in depth by
/// `test/services/maintenance_service_test.dart`), so this provider is now
/// a thin orchestrator: gate on identity, forward to
/// `MaintenanceService.maintainKeyPackage` +
/// `MaintenanceService.maintainRelayList`, and map the result to a bool.
/// These tests cover exactly that thin layer.
///
/// Verifies that:
/// - keyPackagePublisherProvider returns false when no identity exists
/// - keyPackagePublisherProvider calls both maintenance tasks when an
///   identity exists
/// - keyPackagePublisherProvider's bool result reflects the KeyPackage
///   maintenance outcome
/// - keyPackagePublisherProvider re-runs when
///   keyPackagePublisherInvalidatorProvider invalidates
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/maintenance_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_relay_service.dart';

/// A fake circle-manager FFI handle (never invoked by [_RecordingRelay]).
class _FakeCircleManager implements CircleManagerFfi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

/// A relay service that records `maintainKeyPackage` / `maintainRelayList`
/// call counts and returns configurable results.
class _RecordingRelay extends MockRelayService {
  int kpCalls = 0;
  int relayListCalls = 0;

  KeyPackageMaintenanceResult kpResult = const KeyPackageMaintenanceResult(
    action: KeyPackageMaintenanceAction.republishedFreshD,
    canonicalOnRelays: 2,
  );

  @override
  Future<KeyPackageMaintenanceResult> maintainKeyPackage({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async {
    kpCalls++;
    return kpResult;
  }

  @override
  Future<RelayListMaintenanceResult> maintainRelayList({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async {
    relayListCalls++;
    return const RelayListMaintenanceResult.empty();
  }
}

/// Mock identity service for testing.
class _MockIdentityService implements IdentityService {
  _MockIdentityService({required this.identityExists});

  final bool identityExists;

  static final _testIdentity = Identity(
    pubkeyHex:
        'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
    npub: 'npub1test',
    createdAt: DateTime(2024),
  );

  static final _testSecretBytes = List<int>.generate(32, (i) => i);

  @override
  Future<Identity?> getIdentity() async =>
      identityExists ? _testIdentity : null;

  @override
  Future<List<int>> getSecretBytes() async => _testSecretBytes;

  @override
  Future<bool> hasIdentity() async => identityExists;

  @override
  Future<Identity> createIdentity() async => _testIdentity;

  @override
  Future<Identity> importFromNsec(String nsec) async => _testIdentity;

  @override
  Future<String> exportNsec() async => 'nsec1test';

  @override
  Future<String> sign(Uint8List messageHash) async => 'signature';

  @override
  Future<String> getPubkeyHex() async => _testIdentity.pubkeyHex;

  @override
  Future<void> deleteIdentity() async {}

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('keyPackagePublisherProvider', () {
    test('returns false when no identity', () async {
      final relay = _RecordingRelay();
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(
            _MockIdentityService(identityExists: false),
          ),
          maintenanceServiceProvider.overrideWithValue(
            MaintenanceService(
              relayService: relay,
              circleManagerFactory: () async => _FakeCircleManager(),
              identitySecretBytes: () async => List.generate(32, (i) => i),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(keyPackagePublisherProvider.future);

      expect(result, isFalse);
      expect(
        relay.kpCalls,
        0,
        reason: 'maintenance must not run without an identity',
      );
      expect(relay.relayListCalls, 0);
    });

    test(
      'calls maintainKeyPackage and maintainRelayList when identity exists',
      () async {
        final relay = _RecordingRelay();
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(
              _MockIdentityService(identityExists: true),
            ),
            maintenanceServiceProvider.overrideWithValue(
              MaintenanceService(
                relayService: relay,
                circleManagerFactory: () async => _FakeCircleManager(),
                identitySecretBytes: () async => List.generate(32, (i) => i),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await container.read(keyPackagePublisherProvider.future);

        expect(relay.kpCalls, 1);
        expect(relay.relayListCalls, 1);
      },
    );

    test('returns true when a KeyPackage was (re)published', () async {
      final relay = _RecordingRelay()
        ..kpResult = const KeyPackageMaintenanceResult(
          action: KeyPackageMaintenanceAction.republishedFreshD,
        );
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(
            _MockIdentityService(identityExists: true),
          ),
          maintenanceServiceProvider.overrideWithValue(
            MaintenanceService(
              relayService: relay,
              circleManagerFactory: () async => _FakeCircleManager(),
              identitySecretBytes: () async => List.generate(32, (i) => i),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(keyPackagePublisherProvider.future);

      expect(result, isTrue);
    });

    test(
      'returns true when already healthy with a canonical reachable',
      () async {
        final relay = _RecordingRelay()
          ..kpResult = const KeyPackageMaintenanceResult(
            canonicalOnRelays: 3,
          );
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(
              _MockIdentityService(identityExists: true),
            ),
            maintenanceServiceProvider.overrideWithValue(
              MaintenanceService(
                relayService: relay,
                circleManagerFactory: () async => _FakeCircleManager(),
                identitySecretBytes: () async => List.generate(32, (i) => i),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(
          keyPackagePublisherProvider.future,
        );

        expect(result, isTrue);
      },
    );

    test(
      'returns false on an empty (best-effort-failed) maintenance result',
      () async {
        // MaintenanceService swallows a hard failure (e.g. the circle
        // manager factory throwing) into KeyPackageMaintenanceResult.empty
        // — action alreadyHealthy, canonicalOnRelays 0 — indistinguishable
        // by design from "genuinely nothing to do" (presence-only,
        // leak-free result). The provider's bool is best-effort UI signal
        // only; every caller of this provider fire-and-forgets it.
        final relay = _RecordingRelay();
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(
              _MockIdentityService(identityExists: true),
            ),
            maintenanceServiceProvider.overrideWithValue(
              MaintenanceService(
                relayService: relay,
                circleManagerFactory: () async =>
                    throw StateError('circle manager unavailable'),
                identitySecretBytes: () async => List.generate(32, (i) => i),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(
          keyPackagePublisherProvider.future,
        );

        expect(result, isFalse);
      },
    );

    test(
      're-runs when keyPackagePublisherInvalidatorProvider invalidates',
      () async {
        final relay = _RecordingRelay();
        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(
              _MockIdentityService(identityExists: true),
            ),
            maintenanceServiceProvider.overrideWithValue(
              MaintenanceService(
                relayService: relay,
                circleManagerFactory: () async => _FakeCircleManager(),
                identitySecretBytes: () async => List.generate(32, (i) => i),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await container.read(keyPackagePublisherProvider.future);
        expect(relay.kpCalls, 1);

        container.read(keyPackagePublisherInvalidatorProvider.notifier).state++;
        container.invalidate(keyPackagePublisherProvider);
        await container.read(keyPackagePublisherProvider.future);

        expect(relay.kpCalls, 2);
      },
    );
  });
}
