/// Additional tests for invitation provider error handling.
///
/// Verifies that:
/// - invitationPollerProvider handles FFI Error throwables from processGiftWrappedInvitation
/// - Error in one gift wrap does not abort processing of subsequent gift wraps
/// - This tests the fix: `on CircleServiceException` → `on Object` in inner loop
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('invitationPollerProvider error handling', () {
    test(
      'returns 0 when all gift wraps throw Error (FFI)',
      () async {
        final mockIdentityService = _MockIdentityService(identityExists: true);
        final mockCircleService = _MockCircleServiceThrowsErrorOnProcess(
          error: StateError('FFI error: Invalid group ID'),
        );
        final mockRelayService = _MockRelayService(
          giftWraps: [
            '{"kind":1059,"content":"invalid1"}',
            '{"kind":1059,"content":"invalid2"}',
          ],
        );

        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockIdentityService),
            circleServiceProvider.overrideWithValue(mockCircleService),
            relayServiceProvider.overrideWithValue(mockRelayService),
          ],
        );
        addTearDown(container.dispose);

        final newCount = await container.read(invitationPollerProvider.future);

        // Should return 0 since all gift wraps failed
        expect(newCount, 0);
        expect(
          mockCircleService.methodCalls.where(
            (call) => call == 'processGiftWrappedInvitation',
          ).length,
          2,
          reason: 'Both gift wraps should be attempted despite errors',
        );
      },
    );

    test(
      'continues processing after Error on individual gift wrap',
      () async {
        final mockIdentityService = _MockIdentityService(identityExists: true);
        final mockCircleService = _MockCircleServiceThrowsOnFirst();
        final mockRelayService = _MockRelayService(
          giftWraps: [
            '{"kind":1059,"content":"invalid"}', // Will throw Error
            '{"kind":1059,"content":"valid"}', // Will succeed
          ],
        );

        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockIdentityService),
            circleServiceProvider.overrideWithValue(mockCircleService),
            relayServiceProvider.overrideWithValue(mockRelayService),
          ],
        );
        addTearDown(container.dispose);

        final newCount = await container.read(invitationPollerProvider.future);

        // Should return 1 (only the valid one)
        expect(newCount, 1);
        expect(
          mockCircleService.methodCalls.where(
            (call) => call == 'processGiftWrappedInvitation',
          ).length,
          2,
          reason: 'Both gift wraps should be attempted',
        );
      },
    );

    test(
      'mixes CircleServiceException and Error handling',
      () async {
        final mockIdentityService = _MockIdentityService(identityExists: true);
        final mockCircleService = _MockCircleServiceMixedErrors();
        final mockRelayService = _MockRelayService(
          giftWraps: [
            '{"kind":1059,"content":"duplicate"}', // CircleServiceException
            '{"kind":1059,"content":"invalid"}', // StateError
            '{"kind":1059,"content":"valid"}', // Success
          ],
        );

        final container = ProviderContainer(
          overrides: [
            identityServiceProvider.overrideWithValue(mockIdentityService),
            circleServiceProvider.overrideWithValue(mockCircleService),
            relayServiceProvider.overrideWithValue(mockRelayService),
          ],
        );
        addTearDown(container.dispose);

        final newCount = await container.read(invitationPollerProvider.future);

        // Should return 1 (only the third one succeeded)
        expect(newCount, 1);
        expect(
          mockCircleService.methodCalls.where(
            (call) => call == 'processGiftWrappedInvitation',
          ).length,
          3,
          reason: 'All three gift wraps should be attempted',
        );
      },
    );
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
    this.giftWraps = const [],
  });

  final List<String> giftWraps;

  @override
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async {
    return giftWraps;
  }

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
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
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

/// Mock circle service that always throws Error on processGiftWrappedInvitation.
class _MockCircleServiceThrowsErrorOnProcess implements CircleService {
  _MockCircleServiceThrowsErrorOnProcess({required this.error});

  final Error error;
  final List<String> methodCalls = [];

  @override
  Future<List<Invitation>> getPendingInvitations() async => [];

  @override
  Future<List<Circle>> getVisibleCircles() async => [];

  @override
  Future<Circle?> getCircle(List<int> mlsGroupId) async => null;

  @override
  Future<List<CircleMember>> getMembers(List<int> mlsGroupId) async => [];

  @override
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) async {
    throw UnimplementedError();
  }

  @override
  Future<void> declineInvitation(List<int> mlsGroupId) async {}

  @override
  Future<void> leaveCircle(List<int> mlsGroupId) async {}

  @override
  Future<Invitation> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
    String circleName = 'New Circle',
  }) async {
    methodCalls.add('processGiftWrappedInvitation');
    throw error;
  }

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
  }) async => throw UnimplementedError();

  @override
  Future<DecryptedLocation?> decryptLocation({
    required String eventJson,
  }) async => throw UnimplementedError();

  @override
  Future<SignedKeyPackageEvent> signKeyPackageEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async => throw UnimplementedError();

  @override
  Future<String> signRelayListEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async => throw UnimplementedError();
}

/// Mock circle service that throws Error on first call, succeeds on second.
class _MockCircleServiceThrowsOnFirst implements CircleService {
  int _callCount = 0;
  final List<String> methodCalls = [];

  @override
  Future<List<Invitation>> getPendingInvitations() async => [];

  @override
  Future<List<Circle>> getVisibleCircles() async => [];

  @override
  Future<Circle?> getCircle(List<int> mlsGroupId) async => null;

  @override
  Future<List<CircleMember>> getMembers(List<int> mlsGroupId) async => [];

  @override
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) async {
    throw UnimplementedError();
  }

  @override
  Future<void> declineInvitation(List<int> mlsGroupId) async {}

  @override
  Future<void> leaveCircle(List<int> mlsGroupId) async {}

  @override
  Future<Invitation> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
    String circleName = 'New Circle',
  }) async {
    methodCalls.add('processGiftWrappedInvitation');
    _callCount++;

    if (_callCount == 1) {
      // First call throws Error
      throw StateError('FFI error: Invalid group ID');
    }

    // Second call succeeds
    return Invitation(
      mlsGroupId: const [1, 2, 3, 4],
      circleName: circleName,
      inviterPubkey: 'mock_inviter_pubkey',
      memberCount: 2,
      invitedAt: DateTime.now(),
    );
  }

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
  }) async => throw UnimplementedError();

  @override
  Future<DecryptedLocation?> decryptLocation({
    required String eventJson,
  }) async => throw UnimplementedError();

  @override
  Future<SignedKeyPackageEvent> signKeyPackageEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async => throw UnimplementedError();

  @override
  Future<String> signRelayListEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async => throw UnimplementedError();
}

/// Mock circle service that throws mixed errors: Exception, Error, then succeeds.
class _MockCircleServiceMixedErrors implements CircleService {
  int _callCount = 0;
  final List<String> methodCalls = [];

  @override
  Future<List<Invitation>> getPendingInvitations() async => [];

  @override
  Future<List<Circle>> getVisibleCircles() async => [];

  @override
  Future<Circle?> getCircle(List<int> mlsGroupId) async => null;

  @override
  Future<List<CircleMember>> getMembers(List<int> mlsGroupId) async => [];

  @override
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) async {
    throw UnimplementedError();
  }

  @override
  Future<void> declineInvitation(List<int> mlsGroupId) async {}

  @override
  Future<void> leaveCircle(List<int> mlsGroupId) async {}

  @override
  Future<Invitation> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
    String circleName = 'New Circle',
  }) async {
    methodCalls.add('processGiftWrappedInvitation');
    _callCount++;

    if (_callCount == 1) {
      // First call throws CircleServiceException
      throw const CircleServiceException('Already processed');
    } else if (_callCount == 2) {
      // Second call throws StateError (FFI)
      throw StateError('FFI error: Invalid group ID');
    }

    // Third call succeeds
    return Invitation(
      mlsGroupId: const [1, 2, 3, 4],
      circleName: circleName,
      inviterPubkey: 'mock_inviter_pubkey',
      memberCount: 2,
      invitedAt: DateTime.now(),
    );
  }

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
  }) async => throw UnimplementedError();

  @override
  Future<DecryptedLocation?> decryptLocation({
    required String eventJson,
  }) async => throw UnimplementedError();

  @override
  Future<SignedKeyPackageEvent> signKeyPackageEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async => throw UnimplementedError();

  @override
  Future<String> signRelayListEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async => throw UnimplementedError();
}
