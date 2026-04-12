/// Tests for self-update provider.
///
/// Verifies that:
/// - selfUpdateProvider returns 0 when no groups need rotation
/// - selfUpdateProvider calls selfUpdate for each group needing rotation
/// - selfUpdateProvider handles query failures gracefully
/// - selfUpdateProvider continues updating remaining groups on individual failure
/// - selfUpdateProvider passes the correct threshold to the service
/// - selfUpdateProvider calls selfUpdate with the correct group IDs
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/self_update_provider.dart';
import 'package:haven/src/providers/service_providers.dart';

import '../mocks/mock_circle_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('selfUpdateProvider', () {
    test('returns 0 when no groups need rotation', () async {
      final mockService = MockCircleService();

      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      final result = await container.read(selfUpdateProvider.future);

      expect(result, 0);
      expect(
        mockService.methodCalls
            .where((c) => c == 'groupsNeedingSelfUpdate')
            .length,
        1,
        reason: 'should query exactly once',
      );
      expect(
        mockService.methodCalls.where((c) => c == 'selfUpdate').length,
        0,
        reason: 'should not call selfUpdate when no groups need it',
      );
    });

    test('calls selfUpdate for each group needing rotation', () async {
      final mockService = MockCircleService();
      mockService.groupsNeedingUpdate = [
        [1, 2, 3],
        [4, 5, 6],
      ];

      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      final result = await container.read(selfUpdateProvider.future);

      expect(result, 2);
      expect(
        mockService.methodCalls
            .where((c) => c == 'groupsNeedingSelfUpdate')
            .length,
        1,
        reason: 'should query exactly once, not per group',
      );
      expect(mockService.methodCalls.where((c) => c == 'selfUpdate').length, 2);
      expect(
        mockService.selfUpdateCalledWith,
        [
          [1, 2, 3],
          [4, 5, 6],
        ],
        reason: 'should pass the correct group IDs in order',
      );
    });

    test('returns 0 when query fails', () async {
      final mockService = MockCircleService();
      mockService.shouldThrowOnGroupsNeedingSelfUpdate = true;

      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      final result = await container.read(selfUpdateProvider.future);

      expect(result, 0);
    });

    test(
      'continues updating remaining groups when selfUpdate throws',
      () async {
        final mockService = MockCircleService();
        mockService
          ..groupsNeedingUpdate = [
            [1, 2, 3],
            [4, 5, 6],
            [7, 8, 9],
          ]
          ..shouldThrowOnSelfUpdate = true;

        final container = ProviderContainer(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
        );
        addTearDown(container.dispose);

        final result = await container.read(selfUpdateProvider.future);

        // All three groups should be attempted despite throws.
        expect(
          mockService.selfUpdateCalledWith.length,
          3,
          reason: 'should attempt all groups even when selfUpdate throws',
        );
        // No groups succeed because all throw.
        expect(result, 0);
      },
    );

    test('passes selfUpdateThresholdSecs to the service', () async {
      final mockService = MockCircleService();

      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      await container.read(selfUpdateProvider.future);

      expect(mockService.capturedThresholdSecs, selfUpdateThresholdSecs);
    });

    test('handles single group', () async {
      final mockService = MockCircleService();
      mockService.groupsNeedingUpdate = [
        [10, 20],
      ];

      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      final result = await container.read(selfUpdateProvider.future);

      expect(result, 1);
      expect(mockService.selfUpdateCalledWith, [
        [10, 20],
      ]);
    });

    test('threshold constant is 1 hour', () {
      expect(selfUpdateThresholdSecs, 3600);
    });
  });
}
