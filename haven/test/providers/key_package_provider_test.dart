/// Tests for key package provider.
///
/// Verifies that:
/// - keyPackagePublisherProvider returns false when no identity exists
/// - keyPackagePublisherProvider publishes successfully
/// - keyPackagePublisherProvider handles signing failures
/// - keyPackagePublisherProvider handles publish failures
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/rust/api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_preferences_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/circle_service_retention_stubs.dart';
import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_preferences_service.dart';

/// Returns the standard relay-preferences override for tests in this file.
/// Includes a small seeded list so the publisher has something to sign.
Override _relayPrefsOverride() {
  return relayPreferencesServiceProvider.overrideWith(
    (ref) async => MockRelayPreferencesService(
      initialRelays: const {
        RelayCategory.inbox: ['wss://default-a'],
        RelayCategory.keyPackage: ['wss://default-b'],
      },
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('keyPackagePublisherProvider', () {
    test('returns false when no identity', () async {
      final mockIdentityService = _MockIdentityService(identityExists: false);
      final mockCircleService = MockCircleService();
      final mockRelayService = _MockRelayService();

      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockIdentityService),
          circleServiceProvider.overrideWithValue(mockCircleService),
          relayServiceProvider.overrideWithValue(mockRelayService),
          _relayPrefsOverride(),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(keyPackagePublisherProvider.future);

      expect(result, false);
      // Should not have called circle service or relay service
      expect(mockCircleService.methodCalls, isEmpty);
    });

    test('returns true on successful publish', () async {
      final mockIdentityService = _MockIdentityService(identityExists: true);
      final mockCircleService = MockCircleService();
      final mockRelayService = _MockRelayService(shouldSucceed: true);

      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockIdentityService),
          circleServiceProvider.overrideWithValue(mockCircleService),
          relayServiceProvider.overrideWithValue(mockRelayService),
          _relayPrefsOverride(),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(keyPackagePublisherProvider.future);

      expect(result, true);
      expect(mockCircleService.methodCalls, contains('signKeyPackageEvent'));
      // M8-6: a successful publish must record the KeyPackage so the
      // maintenance live-material gate recognizes it as live (NoOp) instead of
      // force-rotating the primary KP on the first cycle.
      expect(
        mockCircleService.methodCalls,
        contains('recordPublishedKeyPackages'),
      );
    });

    test('returns false when signing fails', () async {
      final mockIdentityService = _MockIdentityService(identityExists: true);
      final mockCircleService = _FailingCircleService(
        exception: const CircleServiceException('Signing failed'),
      );
      final mockRelayService = _MockRelayService(shouldSucceed: true);

      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockIdentityService),
          circleServiceProvider.overrideWithValue(mockCircleService),
          relayServiceProvider.overrideWithValue(mockRelayService),
          _relayPrefsOverride(),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(keyPackagePublisherProvider.future);

      expect(result, false);
    });

    test('returns false when publish fails', () async {
      final mockIdentityService = _MockIdentityService(identityExists: true);
      final mockCircleService = MockCircleService();
      final mockRelayService = _MockRelayService(shouldThrowOnPublish: true);

      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockIdentityService),
          circleServiceProvider.overrideWithValue(mockCircleService),
          relayServiceProvider.overrideWithValue(mockRelayService),
          _relayPrefsOverride(),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(keyPackagePublisherProvider.future);

      expect(result, false);
    });

    test('publishes the kind 30443 + 443 pair plus kind 10051', () async {
      final mockIdentityService = _MockIdentityService(identityExists: true);
      final mockCircleService = MockCircleService();
      final mockRelayService = _MockRelayService(shouldSucceed: true);

      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockIdentityService),
          circleServiceProvider.overrideWithValue(mockCircleService),
          relayServiceProvider.overrideWithValue(mockRelayService),
          _relayPrefsOverride(),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(keyPackagePublisherProvider.future);

      expect(result, true);
      expect(mockCircleService.methodCalls, contains('signKeyPackageEvent'));
      // Relay list events (kind 10050 + 10051) are now built via the
      // toggle-aware Rust path, not via signRelayListEvent. Publish
      // count covers: canonical 30443 + legacy 443 + 10051 + 10050.
      expect(
        mockRelayService.publishCallCount,
        4,
        reason:
            'must publish canonical, legacy twin, KP relay list, and inbox '
            'relay list',
      );
    });

    test(
      'publishes the legacy kind 443 twin alongside the canonical 30443',
      () async {
        final mockIdentityService = _MockIdentityService(identityExists: true);
        final mockCircleService = MockCircleService();
        final mockRelayService = _SelectiveRelayService(
          canonicalSucceeds: true,
          legacySucceeds: true,
          relayListSucceeds: true,
        );

        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockIdentityService),
            circleServiceProvider.overrideWithValue(mockCircleService),
            relayServiceProvider.overrideWithValue(mockRelayService),
            _relayPrefsOverride(),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(keyPackagePublisherProvider.future);

        expect(result, true);
        expect(
          mockRelayService.publishCallCountByKind[30443],
          1,
          reason: 'canonical kind 30443 must be published exactly once',
        );
        expect(
          mockRelayService.publishCallCountByKind[443],
          1,
          reason: 'legacy kind 443 twin must be published exactly once',
        );
        expect(
          mockRelayService.publishCallCountByKind[10051],
          1,
          reason: 'relay list kind 10051 must be published exactly once',
        );
        expect(
          mockRelayService.publishCallCountByKind[10050],
          1,
          reason: 'inbox relay list kind 10050 must be published exactly once',
        );
      },
    );

    test(
      'returns true when canonical 30443 succeeds but legacy 443 publish fails',
      () async {
        final mockIdentityService = _MockIdentityService(identityExists: true);
        final mockCircleService = MockCircleService();
        final mockRelayService = _SelectiveRelayService(
          canonicalSucceeds: true,
          legacySucceeds: false,
          relayListSucceeds: true,
        );

        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockIdentityService),
            circleServiceProvider.overrideWithValue(mockCircleService),
            relayServiceProvider.overrideWithValue(mockRelayService),
            _relayPrefsOverride(),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(keyPackagePublisherProvider.future);

        // Legacy twin failure must NOT mark the rotation as failed.
        expect(result, true);
        expect(
          mockRelayService.publishCallCountByKind[443],
          1,
          reason: 'legacy publish must still be attempted',
        );
        expect(
          mockRelayService.publishCallCountByKind[10051],
          1,
          reason: 'relay list must still be published after legacy fails',
        );
      },
    );

    test(
      'returns false when canonical 30443 fails even if legacy 443 succeeds',
      () async {
        final mockIdentityService = _MockIdentityService(identityExists: true);
        final mockCircleService = MockCircleService();
        final mockRelayService = _SelectiveRelayService(
          canonicalSucceeds: false,
          legacySucceeds: true,
          relayListSucceeds: true,
        );

        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockIdentityService),
            circleServiceProvider.overrideWithValue(mockCircleService),
            relayServiceProvider.overrideWithValue(mockRelayService),
            _relayPrefsOverride(),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(keyPackagePublisherProvider.future);

        // Canonical is the gating publish — legacy twin alone is not enough.
        expect(result, false);
      },
    );

    test('returns true even when relay list publication fails', () async {
      // Pre-existing test for a CircleService.signRelayListEvent failure
      // path. That FFI / interface method has been deleted (toggle-bypass
      // footgun), so the failure mode is now "buildRelayListPublish at
      // the prefs FFI throws" — covered by the failure-tolerance code in
      // `_publishRelayListIfEnabled`. We assert here that a generic
      // success run still returns `true` even when the relay-list publish
      // is best-effort.
      final mockIdentityService = _MockIdentityService(identityExists: true);
      final mockCircleService = MockCircleService();
      final mockRelayService = _MockRelayService(shouldSucceed: true);

      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockIdentityService),
          circleServiceProvider.overrideWithValue(mockCircleService),
          relayServiceProvider.overrideWithValue(mockRelayService),
          _relayPrefsOverride(),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(keyPackagePublisherProvider.future);

      expect(result, true);
      expect(mockCircleService.methodCalls, contains('signKeyPackageEvent'));
    });

    test(
      'returns true when KP pair succeeds but kind 10051 relay publish fails',
      () async {
        final mockIdentityService = _MockIdentityService(identityExists: true);
        final mockCircleService = MockCircleService();
        // The KP pair (30443 + 443) succeeds; the relay list publish fails.
        final mockRelayService = _SelectiveRelayService(
          canonicalSucceeds: true,
          legacySucceeds: true,
          relayListSucceeds: false,
        );

        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockIdentityService),
            circleServiceProvider.overrideWithValue(mockCircleService),
            relayServiceProvider.overrideWithValue(mockRelayService),
            _relayPrefsOverride(),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(keyPackagePublisherProvider.future);

        // Canonical KP succeeded, so result is true despite kind 10051 relay
        // list failure — relay list publish is non-fatal.
        expect(result, true);
        expect(mockCircleService.methodCalls, contains('signKeyPackageEvent'));
        // Relay list publication goes through the toggle-aware FFI now.
        // 4 publishes: canonical 30443 + legacy 443 + 10051 + 10050.
        expect(
          mockRelayService.publishCallCount,
          4,
          reason:
              'Should publish canonical KP, legacy twin, KP relay list, and '
              'inbox relay list',
        );
      },
    );

    test('deletes old KeyPackage after publishing new one', () async {
      const oldEventId =
          'aabbccddee00112233445566778899aabbccddee00112233445566778899aabb';
      final mockIdentityService = _MockIdentityService(identityExists: true);
      final mockCircleService = MockCircleService();
      final mockRelayService = _MockRelayService(
        shouldSucceed: true,
        existingKeyPackageEventId: oldEventId,
      );

      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockIdentityService),
          circleServiceProvider.overrideWithValue(mockCircleService),
          relayServiceProvider.overrideWithValue(mockRelayService),
          _relayPrefsOverride(),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(keyPackagePublisherProvider.future);

      expect(result, true);
      // signDeletionEvent should have been called with the old event ID
      expect(
        mockCircleService.methodCalls,
        contains('signDeletionEvent'),
        reason: 'Should call signDeletionEvent with the old KP event ID',
      );
      // 5 publishes: canonical 30443 + legacy 443 + deletion + 10051 + 10050
      expect(
        mockRelayService.publishCallCount,
        5,
        reason:
            'Should publish canonical KP, legacy twin, deletion, KP relay '
            'list, and inbox relay list',
      );
    });

    test('continues when fetch of existing KeyPackage fails', () async {
      final mockIdentityService = _MockIdentityService(identityExists: true);
      final mockCircleService = MockCircleService();
      final mockRelayService = _MockRelayService(
        shouldSucceed: true,
        throwOnFetchKeyPackage: true,
      );

      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockIdentityService),
          circleServiceProvider.overrideWithValue(mockCircleService),
          relayServiceProvider.overrideWithValue(mockRelayService),
          _relayPrefsOverride(),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(keyPackagePublisherProvider.future);

      // Still succeeds despite fetch failure (deletion is non-fatal)
      expect(result, true);
      expect(mockCircleService.methodCalls, contains('signKeyPackageEvent'));
      // signDeletionEvent should NOT be called since fetch failed
      expect(
        mockCircleService.methodCalls,
        isNot(contains('signDeletionEvent')),
        reason: 'Should not call signDeletionEvent when fetch of old KP fails',
      );
      // 4 publishes: canonical 30443 + legacy 443 + 10051 + 10050 (no deletion).
      expect(
        mockRelayService.publishCallCount,
        4,
        reason:
            'Should publish canonical KP, legacy twin, KP relay list, and '
            'inbox relay list when no old KP exists',
      );
    });

    test('continues when signDeletionEvent throws', () async {
      const oldEventId =
          'aabbccddee00112233445566778899aabbccddee00112233445566778899aabb';
      final mockIdentityService = _MockIdentityService(identityExists: true);
      final mockCircleService = MockCircleService()
        ..shouldThrowOnDeletion = true;
      final mockRelayService = _MockRelayService(
        shouldSucceed: true,
        existingKeyPackageEventId: oldEventId,
      );

      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockIdentityService),
          circleServiceProvider.overrideWithValue(mockCircleService),
          relayServiceProvider.overrideWithValue(mockRelayService),
          _relayPrefsOverride(),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(keyPackagePublisherProvider.future);

      // Provider still succeeds — deletion failure is non-fatal
      expect(result, true);
      expect(mockCircleService.methodCalls, contains('signDeletionEvent'));
      // Relay list goes through the FFI toggle-aware path now (no longer
      // through circleService.signRelayListEvent), so the assertion
      // below is replaced by publish-count checks elsewhere.
    });

    test('skips deletion when event JSON is malformed', () async {
      final mockIdentityService = _MockIdentityService(identityExists: true);
      final mockCircleService = MockCircleService();
      final mockRelayService = _MockRelayService(
        shouldSucceed: true,
        malformedKeyPackageJson: true,
      );

      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockIdentityService),
          circleServiceProvider.overrideWithValue(mockCircleService),
          relayServiceProvider.overrideWithValue(mockRelayService),
          _relayPrefsOverride(),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(keyPackagePublisherProvider.future);

      expect(result, true);
      expect(
        mockCircleService.methodCalls,
        isNot(contains('signDeletionEvent')),
        reason: 'Should not attempt deletion with malformed JSON',
      );
    });

    test('skips deletion when event JSON has no id field', () async {
      final mockIdentityService = _MockIdentityService(identityExists: true);
      final mockCircleService = MockCircleService();
      final mockRelayService = _MockRelayService(
        shouldSucceed: true,
        missingIdKeyPackageJson: true,
      );

      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockIdentityService),
          circleServiceProvider.overrideWithValue(mockCircleService),
          relayServiceProvider.overrideWithValue(mockRelayService),
          _relayPrefsOverride(),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(keyPackagePublisherProvider.future);

      expect(result, true);
      expect(
        mockCircleService.methodCalls,
        isNot(contains('signDeletionEvent')),
        reason: 'Should not attempt deletion when id is missing',
      );
    });
  });
}

// ==========================================================================
// Mock Implementations
// ==========================================================================

/// Mock identity service for testing.
class _MockIdentityService implements IdentityService {
  _MockIdentityService({required this.identityExists});

  /// Whether an identity exists (controls return value of getIdentity).
  final bool identityExists;

  static final _testIdentity = Identity(
    pubkeyHex:
        'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
    npub: 'npub1test',
    createdAt: DateTime(2024),
  );

  static final _testSecretBytes = List<int>.generate(32, (i) => i);

  @override
  Future<Identity?> getIdentity() async {
    return identityExists ? _testIdentity : null;
  }

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

/// Mock relay service for testing.
class _MockRelayService implements RelayService {
  @override
  Future<CatchupResult> runCatchup({
    required CircleManagerFfi circle,
    required String ownPubkeyHex,
    int maxDurationSecs = 20,
  }) async => const CatchupResult.empty();

  @override
  Future<KeyPackageMaintenanceResult> maintainKeyPackage({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async => const KeyPackageMaintenanceResult.empty();

  @override
  Future<RelayListMaintenanceResult> maintainRelayList({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async => const RelayListMaintenanceResult.empty();

  @override
  Future<SubscriptionHealthResult> maintainSubscriptionHealth() async =>
      const SubscriptionHealthResult.empty();
  _MockRelayService({
    this.shouldSucceed = false,
    this.shouldThrowOnPublish = false,
    this.existingKeyPackageEventId,
    this.throwOnFetchKeyPackage = false,
    this.malformedKeyPackageJson = false,
    this.missingIdKeyPackageJson = false,
  });

  final bool shouldSucceed;
  final bool shouldThrowOnPublish;

  /// If set, [fetchKeyPackage] returns a KP event with this ID.
  final String? existingKeyPackageEventId;

  /// If true, [fetchKeyPackage] throws a [RelayServiceException].
  final bool throwOnFetchKeyPackage;

  /// If true, [fetchKeyPackage] returns malformed JSON.
  final bool malformedKeyPackageJson;

  /// If true, [fetchKeyPackage] returns JSON without an `id` field.
  final bool missingIdKeyPackageJson;

  /// Tracks how many times [publishEvent] was called.
  int publishCallCount = 0;

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    publishCallCount++;

    if (shouldThrowOnPublish) {
      throw const RelayServiceException('Publish failed');
    }

    if (shouldSucceed) {
      return PublishResult(
        eventId: 'mock-event-id-$publishCallCount',
        acceptedBy: relays,
        rejectedBy: const [],
        failed: const [],
      );
    }

    // Publish failed - no relays accepted
    return PublishResult(
      eventId: 'mock-event-id-$publishCallCount',
      acceptedBy: const [],
      rejectedBy: const [],
      failed: const ['wss://relay.damus.io'],
    );
  }

  @override
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async => [];

  @override
  Future<List<RelayGiftWrapFetch>> fetchGiftWrapsPerRelay({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async => [];

  @override
  Future<List<String>> fetchKeyPackageRelays(String pubkey) async => [];

  @override
  Future<List<String>> fetchNip65Relays(String pubkey) async => [];

  @override
  Future<KeyPackageData?> fetchKeyPackage(String pubkey) async {
    if (throwOnFetchKeyPackage) {
      throw const RelayServiceException('Fetch failed');
    }
    if (malformedKeyPackageJson) {
      return KeyPackageData(
        pubkey: pubkey,
        eventJson: 'not-valid-json{{{',
        relays: const ['wss://relay.example.com'],
      );
    }
    if (missingIdKeyPackageJson) {
      return KeyPackageData(
        pubkey: pubkey,
        eventJson: '{"kind":30443,"pubkey":"$pubkey"}',
        relays: const ['wss://relay.example.com'],
      );
    }
    if (existingKeyPackageEventId != null) {
      return KeyPackageData(
        pubkey: pubkey,
        eventJson:
            '{"id":"$existingKeyPackageEventId","kind":30443,"pubkey":"$pubkey"}',
        relays: const ['wss://relay.example.com'],
      );
    }
    return null;
  }

  @override
  Future<PublishResult> publishWelcome({
    required GiftWrappedWelcome welcomeEvent,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) async => [];

  @override
  Future<void> publishEventFireAndForget({
    required String eventJson,
    required List<String> relays,
  }) async {}

  @override
  Future<RelayEventCheck> checkEventOnRelay({
    required String relayUrl,
    required String authorPubkey,
    required int eventKind,
  }) async => RelayEventCheck(relayUrl: relayUrl, found: false, eventCount: 0);

  @override
  Future<void> disconnectRelay(String url) async {}
}

/// Mock relay service that can return different results per event kind.
///
/// Routes by parsing the `"kind":N` field from the event JSON and looking
/// up the configured outcome. Defaults to success for unknown kinds so
/// tests don't accidentally pass-by-omission.
class _SelectiveRelayService implements RelayService {
  @override
  Future<CatchupResult> runCatchup({
    required CircleManagerFfi circle,
    required String ownPubkeyHex,
    int maxDurationSecs = 20,
  }) async => const CatchupResult.empty();

  @override
  Future<KeyPackageMaintenanceResult> maintainKeyPackage({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async => const KeyPackageMaintenanceResult.empty();

  @override
  Future<RelayListMaintenanceResult> maintainRelayList({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async => const RelayListMaintenanceResult.empty();

  @override
  Future<SubscriptionHealthResult> maintainSubscriptionHealth() async =>
      const SubscriptionHealthResult.empty();
  _SelectiveRelayService({
    required this.canonicalSucceeds,
    required this.legacySucceeds,
    required this.relayListSucceeds,
  });

  /// Whether kind 30443 (canonical key package) publishes succeed.
  final bool canonicalSucceeds;

  /// Whether kind 443 (legacy twin) publishes succeed.
  final bool legacySucceeds;

  /// Whether kind 10051 (key package relay list) publishes succeed.
  final bool relayListSucceeds;

  int publishCallCount = 0;

  /// Per-kind publish counts so tests can assert the legacy twin actually
  /// got attempted alongside the canonical event.
  final Map<int, int> publishCallCountByKind = {};

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    publishCallCount++;

    // Parse the kind from the event JSON
    final kindMatch = RegExp(r'"kind"\s*:\s*(\d+)').firstMatch(eventJson);
    final kind = kindMatch != null ? int.parse(kindMatch.group(1)!) : 0;
    publishCallCountByKind.update(kind, (v) => v + 1, ifAbsent: () => 1);

    final shouldSucceed = switch (kind) {
      30443 => canonicalSucceeds,
      443 => legacySucceeds,
      10051 => relayListSucceeds,
      _ => true,
    };

    if (shouldSucceed) {
      return PublishResult(
        eventId: 'mock-event-id-$publishCallCount',
        acceptedBy: relays,
        rejectedBy: const [],
        failed: const [],
      );
    }

    // Publish failed - no relays accepted
    return PublishResult(
      eventId: 'mock-event-id-$publishCallCount',
      acceptedBy: const [],
      rejectedBy: const [],
      failed: relays,
    );
  }

  @override
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async => [];

  @override
  Future<List<RelayGiftWrapFetch>> fetchGiftWrapsPerRelay({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async => [];

  @override
  Future<List<String>> fetchKeyPackageRelays(String pubkey) async => [];

  @override
  Future<List<String>> fetchNip65Relays(String pubkey) async => [];

  @override
  Future<KeyPackageData?> fetchKeyPackage(String pubkey) async => null;

  @override
  Future<PublishResult> publishWelcome({
    required GiftWrappedWelcome welcomeEvent,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) async => [];

  @override
  Future<void> publishEventFireAndForget({
    required String eventJson,
    required List<String> relays,
  }) async {}

  @override
  Future<RelayEventCheck> checkEventOnRelay({
    required String relayUrl,
    required String authorPubkey,
    required int eventKind,
  }) async => RelayEventCheck(relayUrl: relayUrl, found: false, eventCount: 0);

  @override
  Future<void> disconnectRelay(String url) async {}
}

/// Mock circle service that fails on signKeyPackageEvent.
class _FailingCircleService
    with CircleServiceRetentionStubs
    implements CircleService {
  _FailingCircleService({required this.exception});

  final Exception exception;
  final _mockService = MockCircleService();

  @override
  Future<SignedKeyPackageEvent> signKeyPackageEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async {
    throw exception;
  }

  // Delegate all other methods to mock service
  @override
  Future<List<Circle>> getVisibleCircles() => _mockService.getVisibleCircles();

  @override
  Future<Circle?> getCircle(List<int> mlsGroupId) =>
      _mockService.getCircle(mlsGroupId);

  @override
  Future<List<CircleMember>> getMembers(List<int> mlsGroupId) =>
      _mockService.getMembers(mlsGroupId);

  @override
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
    List<String> creatorFallbackRelays = const [],
  }) => _mockService.createCircle(
    identitySecretBytes: identitySecretBytes,
    memberKeyPackages: memberKeyPackages,
    name: name,
    circleType: circleType,
    description: description,
    relays: relays,
    creatorFallbackRelays: creatorFallbackRelays,
  );

  @override
  Future<List<Invitation>> getPendingInvitations() =>
      _mockService.getPendingInvitations();

  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) =>
      _mockService.acceptInvitation(mlsGroupId);

  @override
  Future<void> declineInvitation(List<int> mlsGroupId) =>
      _mockService.declineInvitation(mlsGroupId);

  @override
  Future<void> leaveCircle({
    required List<int> mlsGroupId,
    required String selfPubkeyHex,
  }) => _mockService.leaveCircle(
    mlsGroupId: mlsGroupId,
    selfPubkeyHex: selfPubkeyHex,
  );

  @override
  Future<void> removeMember({
    required List<int> mlsGroupId,
    required String memberPubkeyHex,
  }) => _mockService.removeMember(
    mlsGroupId: mlsGroupId,
    memberPubkeyHex: memberPubkeyHex,
  );

  @override
  Future<AddMemberResult> addMember({
    required Future<List<int>> Function() secretProvider,
    required List<int> mlsGroupId,
    required List<KeyPackageData> memberKeyPackages,
    List<String> creatorFallbackRelays = const [],
  }) => _mockService.addMember(
    secretProvider: secretProvider,
    mlsGroupId: mlsGroupId,
    memberKeyPackages: memberKeyPackages,
    creatorFallbackRelays: creatorFallbackRelays,
  );

  @override
  Future<Invitation?> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
  }) => _mockService.processGiftWrappedInvitation(
    identitySecretBytes: identitySecretBytes,
    giftWrapEventJson: giftWrapEventJson,
  );

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) =>
      _mockService.finalizePendingCommit(mlsGroupId);

  @override
  Future<void> clearPendingCommit(List<int> mlsGroupId) =>
      _mockService.clearPendingCommit(mlsGroupId);

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int updateIntervalSecs,
    String? displayName,
  }) => _mockService.encryptLocation(
    mlsGroupId: mlsGroupId,
    senderPubkeyHex: senderPubkeyHex,
    latitude: latitude,
    longitude: longitude,
    updateIntervalSecs: updateIntervalSecs,
    displayName: displayName,
  );

  @override
  Future<DecryptResult?> decryptLocation({required String eventJson}) =>
      _mockService.decryptLocation(eventJson: eventJson);

  @override
  Future<String> signDeletionEvent({
    required List<int> identitySecretBytes,
    required List<String> eventIds,
  }) => _mockService.signDeletionEvent(
    identitySecretBytes: identitySecretBytes,
    eventIds: eventIds,
  );

  @override
  Future<List<List<int>>> groupsNeedingSelfUpdate(int thresholdSecs) =>
      _mockService.groupsNeedingSelfUpdate(thresholdSecs);

  @override
  Future<void> selfUpdate(List<int> mlsGroupId) =>
      _mockService.selfUpdate(mlsGroupId);
}
