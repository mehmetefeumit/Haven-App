/// Tests for InvitationCard widget.
///
/// Verifies that:
/// - Accepting an invitation republishes a fresh KeyPackage (GAP 6)
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/widgets/circles/invitation_card.dart';

import '../../mocks/mock_circle_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InvitationCard', () {
    testWidgets('republishes key package after accepting invitation', (
      tester,
    ) async {
      final mockCircleService = _AcceptingCircleService();
      var keyPackageReadCount = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            circleServiceProvider.overrideWithValue(mockCircleService),
            // Track how many times keyPackagePublisherProvider is built
            keyPackagePublisherProvider.overrideWith((ref) {
              keyPackageReadCount++;
              return Future.value(true);
            }),
            // Stub out providers that get invalidated on accept
            pendingInvitationsProvider.overrideWith(
              (ref) => Future.value(<Invitation>[]),
            ),
            circlesProvider.overrideWith((ref) => Future.value(<Circle>[])),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  // Watch keyPackagePublisherProvider so invalidation
                  // triggers a rebuild of its factory function.
                  Consumer(
                    builder: (context, ref, _) {
                      ref.watch(keyPackagePublisherProvider);
                      return const SizedBox.shrink();
                    },
                  ),
                  InvitationCard(
                    invitation: Invitation(
                      mlsGroupId: const [1, 2, 3, 4],
                      circleName: 'Test Circle',
                      inviterPubkey:
                          'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
                      memberCount: 3,
                      invitedAt: DateTime(2024),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Record the count after initial build
      final countBeforeTap = keyPackageReadCount;

      // Tap the Accept button
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();

      // Verify acceptInvitation was called
      expect(mockCircleService.methodCalls, contains('acceptInvitation'));

      // Verify keyPackagePublisherProvider was invalidated and rebuilt.
      // The Consumer widget watches the provider, so invalidation triggers
      // a rebuild which re-runs the factory function.
      expect(
        keyPackageReadCount,
        greaterThan(countBeforeTap),
        reason: 'keyPackagePublisherProvider should be rebuilt after accept',
      );
    });
  });
}

// ==========================================================================
// Mock Implementations
// ==========================================================================

/// A circle service that succeeds on acceptInvitation.
class _AcceptingCircleService extends MockCircleService {
  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) async {
    methodCalls.add('acceptInvitation');
    return TestCircleFactory.createCircle(mlsGroupId: mlsGroupId);
  }
}
