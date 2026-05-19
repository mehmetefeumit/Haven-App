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
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_preferences_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/circle_service_retention_stubs.dart';
import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_preferences_service.dart';

/// Standard relay-prefs override with a seeded inbox list so the
/// invitation poller has somewhere to fetch gift wraps from.
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
          _relayPrefsOverride(),
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
            _relayPrefsOverride(),
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
            _relayPrefsOverride(),
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
          _relayPrefsOverride(),
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
          _relayPrefsOverride(),
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
          _relayPrefsOverride(),
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

    test(
      'returns 0 and does not invalidate when service returns null (already processed)',
      () async {
        // Arrange: service always returns null — simulates AlreadyProcessed mapped to Ok(None).
        final mockIdentityService = _MockIdentityService(identityExists: true);
        final mockCircleService = _MockCircleServiceReturnsNull();
        final mockRelayService = _MockRelayService(
          giftWraps: [
            '{"kind":1059,"content":"already_processed_1"}',
            '{"kind":1059,"content":"already_processed_2"}',
          ],
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

        // Prime pendingInvitationsProvider and circlesProvider so we can detect
        // whether they are invalidated.
        await container.read(pendingInvitationsProvider.future);
        await container.read(circlesProvider.future);
        final pendingVersionBefore = container
            .read(pendingInvitationsProvider)
            .asData
            ?.value;

        // Capture debug output to verify no error/skip log is emitted.
        final logs = <String>[];
        final origPrint = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) logs.add(message);
        };
        addTearDown(() => debugPrint = origPrint);

        final newCount = await container.read(invitationPollerProvider.future);

        // Must return 0: null results are not counted.
        expect(newCount, 0, reason: 'null results must not be counted');

        // pendingInvitationsProvider must NOT have been invalidated (no new invitations).
        final pendingVersionAfter = container
            .read(pendingInvitationsProvider)
            .asData
            ?.value;
        expect(
          pendingVersionBefore,
          pendingVersionAfter,
          reason:
              'pendingInvitationsProvider must not be invalidated when count is 0',
        );

        // The poller must NOT log a "skipped gift-wrap" line for null returns —
        // null is a silent no-op, not a failure.
        final skipLogs = logs.where(
          (l) => l.contains('[InvitationPoller] skipped gift-wrap'),
        );
        expect(
          skipLogs,
          isEmpty,
          reason:
              'null (already-processed) must not emit a skipped-gift-wrap log',
        );
      },
    );

    test(
      'counts 1 and invalidates providers when batch has one real and one null',
      () async {
        // Arrange: first gift wrap → Invitation, second → null (already processed).
        final mockIdentityService = _MockIdentityService(identityExists: true);
        final mockCircleService = _MockCircleServiceMixedBatch();
        final mockRelayService = _MockRelayService(
          giftWraps: [
            '{"kind":1059,"content":"new_gift_wrap"}',
            '{"kind":1059,"content":"already_processed"}',
          ],
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

        // Prime the providers so invalidation is observable.
        await container.read(pendingInvitationsProvider.future);
        await container.read(circlesProvider.future);

        final newCount = await container.read(invitationPollerProvider.future);

        // Exactly 1 new invitation (the non-null one).
        expect(
          newCount,
          1,
          reason: 'exactly one non-null result should be counted',
        );

        // Both dependent providers must be invalidated.
        final pendingState = container.read(pendingInvitationsProvider);
        final circlesState = container.read(circlesProvider);
        expect(
          pendingState.isRefreshing || !pendingState.hasValue,
          isTrue,
          reason:
              'pendingInvitationsProvider must be invalidated after 1 new invitation',
        );
        expect(
          circlesState.isRefreshing || !circlesState.hasValue,
          isTrue,
          reason: 'circlesProvider must be invalidated after 1 new invitation',
        );
      },
    );
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
class _MockCircleServiceWithInvitations
    with CircleServiceRetentionStubs
    implements CircleService {
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
    List<String> creatorFallbackRelays = const [],
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
  Future<void> leaveCircle({
    required List<int> mlsGroupId,
    required String selfPubkeyHex,
  }) async {}

  @override
  Future<void> removeMember({
    required List<int> mlsGroupId,
    required String memberPubkeyHex,
  }) async {}

  @override
  Future<Invitation?> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
  }) async {
    return _createTestInvitation();
  }

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<void> clearPendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int updateIntervalSecs,
    String? displayName,
  }) async => throw UnimplementedError();

  @override
  Future<DecryptResult?> decryptLocation({required String eventJson}) async =>
      throw UnimplementedError();

  @override
  Future<SignedKeyPackageEvent> signKeyPackageEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async => throw UnimplementedError();

  @override
  Future<String> signDeletionEvent({
    required List<int> identitySecretBytes,
    required List<String> eventIds,
  }) async => throw UnimplementedError();

  @override
  Future<List<List<int>>> groupsNeedingSelfUpdate(int thresholdSecs) async =>
      [];

  @override
  Future<void> selfUpdate(List<int> mlsGroupId) async {}
}

/// Mock circle service that throws on getPendingInvitations.
class _ThrowingCircleServiceInvitations
    with CircleServiceRetentionStubs
    implements CircleService {
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
    List<String> creatorFallbackRelays = const [],
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
  Future<void> leaveCircle({
    required List<int> mlsGroupId,
    required String selfPubkeyHex,
  }) async {}

  @override
  Future<void> removeMember({
    required List<int> mlsGroupId,
    required String memberPubkeyHex,
  }) async {}

  @override
  Future<Invitation?> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<void> clearPendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int updateIntervalSecs,
    String? displayName,
  }) async => throw UnimplementedError();

  @override
  Future<DecryptResult?> decryptLocation({required String eventJson}) async =>
      throw UnimplementedError();

  @override
  Future<SignedKeyPackageEvent> signKeyPackageEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async => throw UnimplementedError();

  @override
  Future<String> signDeletionEvent({
    required List<int> identitySecretBytes,
    required List<String> eventIds,
  }) async => throw UnimplementedError();

  @override
  Future<List<List<int>>> groupsNeedingSelfUpdate(int thresholdSecs) async =>
      [];

  @override
  Future<void> selfUpdate(List<int> mlsGroupId) async {}
}

/// Mock circle service that throws on processGiftWrappedInvitation.
class _MockCircleServiceThrowsOnProcess
    with CircleServiceRetentionStubs
    implements CircleService {
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
    List<String> creatorFallbackRelays = const [],
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
  Future<void> leaveCircle({
    required List<int> mlsGroupId,
    required String selfPubkeyHex,
  }) async {}

  @override
  Future<void> removeMember({
    required List<int> mlsGroupId,
    required String memberPubkeyHex,
  }) async {}

  @override
  Future<Invitation?> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
  }) async {
    throw exception;
  }

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<void> clearPendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int updateIntervalSecs,
    String? displayName,
  }) async => throw UnimplementedError();

  @override
  Future<DecryptResult?> decryptLocation({required String eventJson}) async =>
      throw UnimplementedError();

  @override
  Future<SignedKeyPackageEvent> signKeyPackageEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async => throw UnimplementedError();

  @override
  Future<String> signDeletionEvent({
    required List<int> identitySecretBytes,
    required List<String> eventIds,
  }) async => throw UnimplementedError();

  @override
  Future<List<List<int>>> groupsNeedingSelfUpdate(int thresholdSecs) async =>
      [];

  @override
  Future<void> selfUpdate(List<int> mlsGroupId) async {}
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
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) async {}

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
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> publishEventFireAndForget({
    required String eventJson,
    required List<String> relays,
  }) async {}

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) async => [];

  @override
  Future<RelayEventCheck> checkEventOnRelay({
    required String relayUrl,
    required String authorPubkey,
    required int eventKind,
  }) async => RelayEventCheck(relayUrl: relayUrl, found: false, eventCount: 0);

  @override
  Future<void> disconnectRelay(String url) async {}
}

/// Mock service where [processGiftWrappedInvitation] always returns null —
/// simulates the FFI returning `Ok(None)` for already-processed gift wraps
/// (i.e., `CircleError::AlreadyProcessed` mapped to `null` in Dart).
class _MockCircleServiceReturnsNull
    with CircleServiceRetentionStubs
    implements CircleService {
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
    List<String> creatorFallbackRelays = const [],
  }) async => throw UnimplementedError();

  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) async =>
      throw UnimplementedError();

  @override
  Future<void> declineInvitation(List<int> mlsGroupId) async {}

  @override
  Future<void> leaveCircle({
    required List<int> mlsGroupId,
    required String selfPubkeyHex,
  }) async {}

  @override
  Future<void> removeMember({
    required List<int> mlsGroupId,
    required String memberPubkeyHex,
  }) async {}

  @override
  Future<Invitation?> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
  }) async => null; // Already-processed — silent no-op.

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<void> clearPendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int updateIntervalSecs,
    String? displayName,
  }) async => throw UnimplementedError();

  @override
  Future<DecryptResult?> decryptLocation({required String eventJson}) async =>
      throw UnimplementedError();

  @override
  Future<SignedKeyPackageEvent> signKeyPackageEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async => throw UnimplementedError();

  @override
  Future<String> signDeletionEvent({
    required List<int> identitySecretBytes,
    required List<String> eventIds,
  }) async => throw UnimplementedError();

  @override
  Future<List<List<int>>> groupsNeedingSelfUpdate(int thresholdSecs) async =>
      [];

  @override
  Future<void> selfUpdate(List<int> mlsGroupId) async {}
}

/// Mock service for mixed-batch tests: the first call returns a real
/// [Invitation], the second call returns null (already-processed).
class _MockCircleServiceMixedBatch
    with CircleServiceRetentionStubs
    implements CircleService {
  int _callCount = 0;

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
    List<String> creatorFallbackRelays = const [],
  }) async => throw UnimplementedError();

  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) async =>
      throw UnimplementedError();

  @override
  Future<void> declineInvitation(List<int> mlsGroupId) async {}

  @override
  Future<void> leaveCircle({
    required List<int> mlsGroupId,
    required String selfPubkeyHex,
  }) async {}

  @override
  Future<void> removeMember({
    required List<int> mlsGroupId,
    required String memberPubkeyHex,
  }) async {}

  @override
  Future<Invitation?> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
  }) async {
    _callCount++;
    if (_callCount == 1) {
      // First gift wrap is new — return a real invitation.
      return Invitation(
        mlsGroupId: const [0xAA, 0xBB, 0xCC, 0xDD],
        circleName: 'New Circle',
        inviterPubkey: 'alice_pubkey',
        memberCount: 2,
        invitedAt: DateTime.now(),
      );
    }
    // Subsequent calls → already-processed (null).
    return null;
  }

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<void> clearPendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int updateIntervalSecs,
    String? displayName,
  }) async => throw UnimplementedError();

  @override
  Future<DecryptResult?> decryptLocation({required String eventJson}) async =>
      throw UnimplementedError();

  @override
  Future<SignedKeyPackageEvent> signKeyPackageEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async => throw UnimplementedError();

  @override
  Future<String> signDeletionEvent({
    required List<int> identitySecretBytes,
    required List<String> eventIds,
  }) async => throw UnimplementedError();

  @override
  Future<List<List<int>>> groupsNeedingSelfUpdate(int thresholdSecs) async =>
      [];

  @override
  Future<void> selfUpdate(List<int> mlsGroupId) async {}
}
