/// Tests for invitation providers.
///
/// Verifies that:
/// - pendingInvitationsProvider loads invitations correctly
/// - pendingInvitationsProvider handles errors gracefully
/// - invitationPollerProvider processes gift wraps correctly
/// - invitationPollerProvider handles errors and invalidates providers
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_circle_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pendingInvitationsProvider', () {
    test('returns invitations from service', () async {
      final invitation = _createTestInvitation(circleName: 'Family');
      final mockService = _MockCircleServiceWithInvitations([invitation]);
      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      final invitations = await container.read(
        pendingInvitationsProvider.future,
      );

      expect(invitations.length, 1);
      expect(invitations[0].circleName, 'Family');
    });

    test('returns empty list when service returns empty', () async {
      final mockService = _MockCircleServiceWithInvitations([]);
      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      final invitations = await container.read(
        pendingInvitationsProvider.future,
      );

      expect(invitations, isEmpty);
    });

    test(
      'returns empty list when service throws CircleServiceException',
      () async {
        final mockService = _ThrowingCircleServiceInvitations(
          exception: const CircleServiceException('Storage error'),
        );
        final container = ProviderContainer(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
        );
        addTearDown(container.dispose);

        // Should not throw - returns empty list instead
        final invitations = await container.read(
          pendingInvitationsProvider.future,
        );

        expect(invitations, isEmpty);
      },
    );

    test(
      'returns empty list when service throws generic Error (FFI)',
      () async {
        final mockService = _ThrowingCircleServiceInvitations(
          error: StateError('FFI error: Storage Error'),
        );
        final container = ProviderContainer(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
        );
        addTearDown(container.dispose);

        // Should not throw - returns empty list instead
        // This tests that catch handles non-Exception throwables
        final invitations = await container.read(
          pendingInvitationsProvider.future,
        );

        expect(invitations, isEmpty);
      },
    );
  });

  group('invitationPollerProvider', () {
    test('returns 0 when no identity exists', () async {
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

      final newCount = await container.read(invitationPollerProvider.future);

      expect(newCount, 0);
    });

    test(
      'returns count of new invitations when gift wraps are found',
      () async {
        final mockIdentityService = _MockIdentityService(identityExists: true);
        final mockCircleService = MockCircleService();
        final mockRelayService = _MockRelayService(
          giftWraps: ['{"kind":1059,"content":"..."}'],
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

        expect(newCount, 1);
        expect(
          mockCircleService.methodCalls,
          contains('processGiftWrappedInvitation'),
        );
      },
    );

    test(
      'skips already-processed invitations (CircleServiceException)',
      () async {
        final mockIdentityService = _MockIdentityService(identityExists: true);
        final mockCircleService = _MockCircleServiceThrowsOnProcess(
          exception: const CircleServiceException('Already processed'),
        );
        final mockRelayService = _MockRelayService(
          giftWraps: [
            '{"kind":1059,"content":"duplicate1"}',
            '{"kind":1059,"content":"duplicate2"}',
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

        // Should return 0 since all were duplicates
        expect(newCount, 0);
      },
    );

    test('returns 0 when fetchGiftWraps throws Exception', () async {
      final mockIdentityService = _MockIdentityService(identityExists: true);
      final mockCircleService = MockCircleService();
      final mockRelayService = _MockRelayService(shouldThrowOnFetch: true);

      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockIdentityService),
          circleServiceProvider.overrideWithValue(mockCircleService),
          relayServiceProvider.overrideWithValue(mockRelayService),
        ],
      );
      addTearDown(container.dispose);

      final newCount = await container.read(invitationPollerProvider.future);

      expect(newCount, 0);
    });

    test('returns 0 when fetchGiftWraps returns empty list', () async {
      final mockIdentityService = _MockIdentityService(identityExists: true);
      final mockCircleService = MockCircleService();
      final mockRelayService = _MockRelayService(giftWraps: []);

      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockIdentityService),
          circleServiceProvider.overrideWithValue(mockCircleService),
          relayServiceProvider.overrideWithValue(mockRelayService),
        ],
      );
      addTearDown(container.dispose);

      final newCount = await container.read(invitationPollerProvider.future);

      expect(newCount, 0);
    });

    test('invalidates providers when new invitations found', () async {
      final mockIdentityService = _MockIdentityService(identityExists: true);
      final mockCircleService = MockCircleService();
      final mockRelayService = _MockRelayService(
        giftWraps: ['{"kind":1059,"content":"new"}'],
      );

      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(mockIdentityService),
          circleServiceProvider.overrideWithValue(mockCircleService),
          relayServiceProvider.overrideWithValue(mockRelayService),
        ],
      );
      addTearDown(container.dispose);

      // Read providers first to establish state
      await container.read(pendingInvitationsProvider.future);
      await container.read(circlesProvider.future);

      // Now poll for invitations
      final newCount = await container.read(invitationPollerProvider.future);
      expect(newCount, 1);

      // Providers should be invalidated (will re-fetch on next read)
      // We can verify this by checking that the providers are in loading state
      final pendingState = container.read(pendingInvitationsProvider);
      final circlesState = container.read(circlesProvider);

      // After invalidation, reading should trigger a new fetch
      expect(pendingState.isRefreshing || !pendingState.hasValue, isTrue);
      expect(circlesState.isRefreshing || !circlesState.hasValue, isTrue);
    });
  });
}

/// Creates a test invitation with default values.
Invitation _createTestInvitation({
  List<int>? mlsGroupId,
  String circleName = 'Test Circle',
  String inviterPubkey = 'test_pubkey',
  int memberCount = 2,
  DateTime? invitedAt,
}) {
  return Invitation(
    mlsGroupId: mlsGroupId ?? [1, 2, 3, 4],
    circleName: circleName,
    inviterPubkey: inviterPubkey,
    memberCount: memberCount,
    invitedAt: invitedAt ?? DateTime.now(),
  );
}

// ==========================================================================
// Mock Implementations
// ==========================================================================

/// Mock circle service that returns specific invitations.
class _MockCircleServiceWithInvitations implements CircleService {
  _MockCircleServiceWithInvitations(this._invitations);

  final List<Invitation> _invitations;

  @override
  Future<List<Invitation>> getPendingInvitations() async => _invitations;

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
    return _createTestInvitation(circleName: circleName);
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
}

/// Mock circle service that throws on getPendingInvitations.
class _ThrowingCircleServiceInvitations implements CircleService {
  _ThrowingCircleServiceInvitations({this.exception, this.error})
    : assert(
        exception != null || error != null,
        'Must provide either exception or error',
      );

  final Exception? exception;
  final Error? error;

  @override
  Future<List<Invitation>> getPendingInvitations() async {
    if (exception != null) throw exception!;
    if (error != null) throw error!;
    throw StateError('Invalid state');
  }

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
    throw UnimplementedError();
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
}

/// Mock circle service that throws on processGiftWrappedInvitation.
class _MockCircleServiceThrowsOnProcess implements CircleService {
  _MockCircleServiceThrowsOnProcess({required this.exception});

  final Exception exception;

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
    throw exception;
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
}

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
    this.shouldThrowOnFetch = false,
  });

  final List<String> giftWraps;
  final bool shouldThrowOnFetch;

  @override
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async {
    if (shouldThrowOnFetch) {
      throw const RelayServiceException('Network error');
    }
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
    required bool isIdentityOperation,
    List<int>? nostrGroupId,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<TorStatus> getTorStatus() async {
    return const TorStatus(progress: 100, isReady: true, phase: 'Done');
  }

  @override
  Future<bool> isReady() async => true;

  @override
  Future<void> waitForReady() async {}

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) async => [];
}
