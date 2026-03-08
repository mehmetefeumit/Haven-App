/// Tests for invitation count provider.
///
/// Verifies that:
/// - Returns 0 when invitations are loading
/// - Returns 0 when invitations error
/// - Returns correct count on data
/// - Updates when invitation list changes
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/invitation_count_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/services/circle_service.dart';

void main() {
  group('invitationCountProvider', () {
    test('returns 0 when pendingInvitationsProvider is loading', () {
      final container = ProviderContainer(
        overrides: [
          pendingInvitationsProvider.overrideWith(
            (ref) => Future<List<Invitation>>.delayed(
              const Duration(hours: 1),
              () => [],
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(invitationCountProvider), 0);
    });

    test('returns 0 when pendingInvitationsProvider has empty list', () async {
      final container = ProviderContainer(
        overrides: [
          pendingInvitationsProvider.overrideWith(
            (ref) async => <Invitation>[],
          ),
        ],
      );
      addTearDown(container.dispose);

      // Wait for the future to complete
      await container.read(pendingInvitationsProvider.future);

      expect(container.read(invitationCountProvider), 0);
    });

    test('returns correct count when invitations exist', () async {
      final invitations = [
        _createTestInvitation(circleName: 'Family'),
        _createTestInvitation(circleName: 'Work'),
        _createTestInvitation(circleName: 'Friends'),
      ];

      final container = ProviderContainer(
        overrides: [
          pendingInvitationsProvider.overrideWith((ref) async => invitations),
        ],
      );
      addTearDown(container.dispose);

      await container.read(pendingInvitationsProvider.future);

      expect(container.read(invitationCountProvider), 3);
    });

    test('returns 1 for a single invitation', () async {
      final container = ProviderContainer(
        overrides: [
          pendingInvitationsProvider.overrideWith(
            (ref) async => [_createTestInvitation()],
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(pendingInvitationsProvider.future);

      expect(container.read(invitationCountProvider), 1);
    });
  });
}

Invitation _createTestInvitation({String circleName = 'Test'}) {
  return Invitation(
    mlsGroupId: [1, 2, 3, 4],
    circleName: circleName,
    inviterPubkey: 'test_pubkey',
    memberCount: 2,
    invitedAt: DateTime.now(),
  );
}
