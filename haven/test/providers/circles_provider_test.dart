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
        overrides: [
          circleServiceProvider.overrideWithValue(mockService),
        ],
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
        overrides: [
          circleServiceProvider.overrideWithValue(mockService),
        ],
      );
      addTearDown(container.dispose);

      final circles = await container.read(circlesProvider.future);

      expect(circles.length, 2);
      expect(circles[0].displayName, 'Family');
      expect(circles[1].displayName, 'Friends');
    });

    test('returns empty list when service throws CircleServiceException',
        () async {
      final mockService = MockCircleService(
        shouldThrowOnGetCircles: true,
        errorMessage: 'Storage error',
      );
      final container = ProviderContainer(
        overrides: [
          circleServiceProvider.overrideWithValue(mockService),
        ],
      );
      addTearDown(container.dispose);

      // Should not throw - returns empty list instead
      final circles = await container.read(circlesProvider.future);

      expect(circles, isEmpty);
    });

    test('returns empty list when service throws generic exception', () async {
      final mockService = _ThrowingCircleService();
      final container = ProviderContainer(
        overrides: [
          circleServiceProvider.overrideWithValue(mockService),
        ],
      );
      addTearDown(container.dispose);

      // Should not throw - returns empty list instead
      final circles = await container.read(circlesProvider.future);

      expect(circles, isEmpty);
    });

    test('returns empty list when service throws Error (not Exception)',
        () async {
      final mockService = _ThrowingErrorCircleService();
      final container = ProviderContainer(
        overrides: [
          circleServiceProvider.overrideWithValue(mockService),
        ],
      );
      addTearDown(container.dispose);

      // Should not throw - returns empty list instead
      // This tests that bare catch handles non-Exception throwables
      final circles = await container.read(circlesProvider.future);

      expect(circles, isEmpty);
    });
  });

  group('selectedCircleProvider', () {
    test('initially returns null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final selected = container.read(selectedCircleProvider);

      expect(selected, isNull);
    });

    test('can set and get selected circle', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final testCircle = TestCircleFactory.createCircle(displayName: 'Test');
      container.read(selectedCircleProvider.notifier).state = testCircle;

      final selected = container.read(selectedCircleProvider);

      expect(selected, isNotNull);
      expect(selected!.displayName, 'Test');
    });

    test('can clear selection by setting to null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final testCircle = TestCircleFactory.createCircle();
      container.read(selectedCircleProvider.notifier).state = testCircle;
      container.read(selectedCircleProvider.notifier).state = null;

      final selected = container.read(selectedCircleProvider);

      expect(selected, isNull);
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
  Future<void> declineInvitation(List<int> mlsGroupId) async {}

  @override
  Future<void> leaveCircle(List<int> mlsGroupId) async {}
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
  Future<void> declineInvitation(List<int> mlsGroupId) async {}

  @override
  Future<void> leaveCircle(List<int> mlsGroupId) async {}
}
