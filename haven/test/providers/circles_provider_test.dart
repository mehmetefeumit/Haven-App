/// Tests for circles providers.
///
/// Verifies that:
/// - circlesProvider loads circles correctly
/// - circlesProvider handles errors gracefully
/// - selectedCircleProvider manages selection state
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';

import '../mocks/mock_circle_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('circlesProvider', () {
    test('returns empty list when service returns empty', () async {
      final mockService = MockCircleService();
      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      final circles = await container.read(circlesProvider.future);

      expect(circles, isEmpty);
      expect(mockService.methodCalls, contains('getVisibleCircles'));
    });

    test('returns circles from service', () async {
      final testCircles = [
        TestCircleFactory.createCircle(
          mlsGroupId: [1, 2, 3],
          displayName: 'Family',
        ),
        TestCircleFactory.createCircle(
          mlsGroupId: [4, 5, 6],
          displayName: 'Friends',
        ),
      ];
      final mockService = MockCircleService(circles: testCircles);
      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      final circles = await container.read(circlesProvider.future);

      expect(circles.length, 2);
      expect(circles[0].displayName, 'Family');
      expect(circles[1].displayName, 'Friends');
    });

    test(
      'returns empty list when service throws CircleServiceException',
      () async {
        final mockService = MockCircleService(
          shouldThrowOnGetCircles: true,
          errorMessage: 'Storage error',
        );
        final container = ProviderContainer(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
        );
        addTearDown(container.dispose);

        // Should not throw - returns empty list instead
        final circles = await container.read(circlesProvider.future);

        expect(circles, isEmpty);
      },
    );

    test('returns empty list when service throws generic exception', () async {
      final mockService = _ThrowingCircleService();
      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      // Should not throw - returns empty list instead
      final circles = await container.read(circlesProvider.future);

      expect(circles, isEmpty);
    });

    test(
      'returns empty list when service throws Error (not Exception)',
      () async {
        final mockService = _ThrowingErrorCircleService();
        final container = ProviderContainer(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
        );
        addTearDown(container.dispose);

        // Should not throw - returns empty list instead
        // This tests that bare catch handles non-Exception throwables
        final circles = await container.read(circlesProvider.future);

        expect(circles, isEmpty);
      },
    );
  });

  group('selectedCircleIdProvider', () {
    test('initially returns null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final selectedId = container.read(selectedCircleIdProvider);

      expect(selectedId, isNull);
    });

    test('can set and get selected ID', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(selectedCircleIdProvider.notifier).state = [1, 2, 3];

      final selectedId = container.read(selectedCircleIdProvider);

      expect(selectedId, [1, 2, 3]);
    });

    test('can clear selection by setting to null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(selectedCircleIdProvider.notifier).state = [1, 2, 3];
      container.read(selectedCircleIdProvider.notifier).state = null;

      expect(container.read(selectedCircleIdProvider), isNull);
    });
  });

  group('selectedCircleProvider (derived)', () {
    test('returns null when no circle is selected', () {
      final mockService = MockCircleService();
      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      final selected = container.read(selectedCircleProvider);

      expect(selected, isNull);
    });

    test('returns matching circle from circlesProvider', () async {
      final testCircle = TestCircleFactory.createCircle(
        displayName: 'Test',
        mlsGroupId: [10, 20, 30],
      );
      final mockService = MockCircleService(circles: [testCircle]);

      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      // Load circles first so circlesProvider has data
      await container.read(circlesProvider.future);

      // Select the circle by ID
      container.read(selectedCircleIdProvider.notifier).state = [10, 20, 30];

      final selected = container.read(selectedCircleProvider);

      expect(selected, isNotNull);
      expect(selected!.displayName, 'Test');
    });

    test('returns null when selected ID not in circles list', () async {
      final mockService = MockCircleService(
        circles: [
          TestCircleFactory.createCircle(mlsGroupId: [1, 2, 3]),
        ],
      );

      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      await container.read(circlesProvider.future);
      container.read(selectedCircleIdProvider.notifier).state = [99, 99, 99];

      final selected = container.read(selectedCircleProvider);

      expect(selected, isNull);
    });

    test('updates when circlesProvider refreshes with new members', () async {
      // Start with an empty-member circle
      final circleV1 = TestCircleFactory.createCircle(
        displayName: 'Family',
        mlsGroupId: [1, 2, 3],
      );

      // Use overrideWith so we can change the returned data
      var currentCircles = [circleV1];
      final container = ProviderContainer(
        overrides: [
          circlesProvider.overrideWith((ref) async => currentCircles),
        ],
      );
      addTearDown(container.dispose);

      await container.read(circlesProvider.future);
      container.read(selectedCircleIdProvider.notifier).state = [1, 2, 3];

      // First read — gets original circle with no members
      var selected = container.read(selectedCircleProvider);
      expect(selected!.members, isEmpty);

      // Update to return circle with a member
      final circleV2 = TestCircleFactory.createCircle(
        displayName: 'Family',
        mlsGroupId: [1, 2, 3],
        members: [
          const CircleMember(
            pubkey: 'new-member-pubkey',
            isAdmin: false,
            status: MembershipStatus.accepted,
          ),
        ],
      );
      currentCircles = [circleV2];

      // Invalidate circlesProvider — simulates what happens when
      // a group update commit is processed
      container.invalidate(circlesProvider);
      await container.read(circlesProvider.future);

      // Derived selectedCircleProvider now reflects the updated member
      final updated = container.read(selectedCircleProvider);
      expect(updated, isNotNull);
      expect(updated!.members, hasLength(1));
      expect(updated.members.first.pubkey, 'new-member-pubkey');
    });
  });
}

/// A circle service that throws a generic exception.
class _ThrowingCircleService implements CircleService {
  @override
  Future<List<Circle>> getVisibleCircles() async {
    throw Exception('Keyring not available');
  }

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
  Future<List<Invitation>> getPendingInvitations() async => [];

  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) async {
    throw UnimplementedError();
  }

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
  Future<bool> publishEvolutionEvent({
    required String eventJson,
    required List<String> relays,
    required String label,
  }) async => true;

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
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int updateIntervalSecs,
    String? displayName,
    String? precisionLabel,
  }) async => throw UnimplementedError();

  @override
  Future<void> upsertLastKnownLocation({
    required List<int> nostrGroupId,
    required String senderPubkey,
    required double latitude,
    required double longitude,
    required String geohash,
    required String precision,
    required DateTime timestamp,
    required DateTime expiresAt,
    required DateTime purgeAfter,
    required DateTime updatedAt,
    String? displayName,
  }) async {}

  @override
  Future<List<DecryptedLocation>> snapshotLastKnownForCircle({
    required List<int> nostrGroupId,
    DateTime? now,
  }) async => const [];

  @override
  Future<void> removeLastKnownMember({
    required List<int> nostrGroupId,
    required String senderPubkey,
  }) async {}

  @override
  Future<void> removeLastKnownCircle({required List<int> nostrGroupId}) async {}

  @override
  Future<void> wipeAllLastKnownLocations() async {}

  @override
  Future<int> pruneExpiredLastKnown({DateTime? now}) async => 0;

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
  Future<void> setContactDisplayNameIfAbsent({
    required String pubkey,
    required String displayName,
  }) async {}

  @override
  Future<List<List<int>>> groupsNeedingSelfUpdate(int thresholdSecs) async =>
      [];

  @override
  Future<void> selfUpdate(List<int> mlsGroupId) async {}
}

/// A circle service that throws an Error (not Exception).
///
/// This simulates FFI errors that may not extend Exception.
class _ThrowingErrorCircleService implements CircleService {
  @override
  Future<List<Circle>> getVisibleCircles() async {
    // Throw an Error, not an Exception - simulates FFI behavior
    throw StateError('MLS error: Storage Error: Keyring not available');
  }

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
  Future<List<Invitation>> getPendingInvitations() async => [];

  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) async {
    throw UnimplementedError();
  }

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
  Future<bool> publishEvolutionEvent({
    required String eventJson,
    required List<String> relays,
    required String label,
  }) async => true;

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
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int updateIntervalSecs,
    String? displayName,
    String? precisionLabel,
  }) async => throw UnimplementedError();

  @override
  Future<void> upsertLastKnownLocation({
    required List<int> nostrGroupId,
    required String senderPubkey,
    required double latitude,
    required double longitude,
    required String geohash,
    required String precision,
    required DateTime timestamp,
    required DateTime expiresAt,
    required DateTime purgeAfter,
    required DateTime updatedAt,
    String? displayName,
  }) async {}

  @override
  Future<List<DecryptedLocation>> snapshotLastKnownForCircle({
    required List<int> nostrGroupId,
    DateTime? now,
  }) async => const [];

  @override
  Future<void> removeLastKnownMember({
    required List<int> nostrGroupId,
    required String senderPubkey,
  }) async {}

  @override
  Future<void> removeLastKnownCircle({required List<int> nostrGroupId}) async {}

  @override
  Future<void> wipeAllLastKnownLocations() async {}

  @override
  Future<int> pruneExpiredLastKnown({DateTime? now}) async => 0;

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
  Future<void> setContactDisplayNameIfAbsent({
    required String pubkey,
    required String displayName,
  }) async {}

  @override
  Future<List<List<int>>> groupsNeedingSelfUpdate(int thresholdSecs) async =>
      [];

  @override
  Future<void> selfUpdate(List<int> mlsGroupId) async {}
}
