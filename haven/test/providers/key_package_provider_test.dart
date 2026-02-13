/// Tests for key package provider.
///
/// Verifies that:
/// - keyPackagePublisherProvider returns false when no identity exists
/// - keyPackagePublisherProvider publishes successfully
/// - keyPackagePublisherProvider handles signing failures
/// - keyPackagePublisherProvider handles publish failures
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_circle_service.dart';

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
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(keyPackagePublisherProvider.future);

      expect(result, true);
      expect(mockCircleService.methodCalls, contains('signKeyPackageEvent'));
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
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(keyPackagePublisherProvider.future);

      expect(result, false);
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
  Future<void> clearCache() async {}
}

/// Mock relay service for testing.
class _MockRelayService implements RelayService {
  _MockRelayService({
    this.shouldSucceed = false,
    this.shouldThrowOnPublish = false,
  });

  final bool shouldSucceed;
  final bool shouldThrowOnPublish;

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    if (shouldThrowOnPublish) {
      throw const RelayServiceException('Publish failed');
    }

    if (shouldSucceed) {
      return PublishResult(
        eventId: 'mock-event-id',
        acceptedBy: relays,
        rejectedBy: const [],
        failed: const [],
      );
    }

    // Publish failed - no relays accepted
    return const PublishResult(
      eventId: 'mock-event-id',
      acceptedBy: [],
      rejectedBy: [],
      failed: ['wss://relay.damus.io'],
    );
  }

  @override
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async => [];

  @override
  Future<List<String>> fetchKeyPackageRelays(String pubkey) async => [];

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
}

/// Mock circle service that fails on signKeyPackageEvent.
class _FailingCircleService implements CircleService {
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
  }) => _mockService.createCircle(
    identitySecretBytes: identitySecretBytes,
    memberKeyPackages: memberKeyPackages,
    name: name,
    circleType: circleType,
    description: description,
    relays: relays,
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
  Future<void> leaveCircle(List<int> mlsGroupId) =>
      _mockService.leaveCircle(mlsGroupId);

  @override
  Future<Invitation> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
    String circleName = 'New Circle',
  }) => _mockService.processGiftWrappedInvitation(
    identitySecretBytes: identitySecretBytes,
    giftWrapEventJson: giftWrapEventJson,
    circleName: circleName,
  );

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) =>
      _mockService.finalizePendingCommit(mlsGroupId);

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
  }) => _mockService.encryptLocation(
    mlsGroupId: mlsGroupId,
    senderPubkeyHex: senderPubkeyHex,
    latitude: latitude,
    longitude: longitude,
  );

  @override
  Future<DecryptedLocation?> decryptLocation({required String eventJson}) =>
      _mockService.decryptLocation(eventJson: eventJson);
}
