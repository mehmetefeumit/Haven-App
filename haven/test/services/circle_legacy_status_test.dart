/// Tests for [CircleLegacyStatus.isLegacyOrphaned] (DM-4c).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';

Circle _circle({
  required MembershipStatus membershipStatus,
  List<CircleMember> members = const [],
}) {
  return Circle(
    mlsGroupId: const [1, 2, 3],
    nostrGroupId: const [4, 5, 6],
    displayName: 'Test Circle',
    circleType: CircleType.locationSharing,
    relays: const ['wss://relay.example.com'],
    membershipStatus: membershipStatus,
    members: members,
    createdAt: DateTime(2024),
    updatedAt: DateTime(2024),
  );
}

void main() {
  group('Circle.isLegacyOrphaned', () {
    test('true for an accepted circle with an empty member list', () {
      final circle = _circle(membershipStatus: MembershipStatus.accepted);
      expect(circle.isLegacyOrphaned, isTrue);
    });

    test('false for an accepted circle with at least self as a member', () {
      final circle = _circle(
        membershipStatus: MembershipStatus.accepted,
        members: const [
          CircleMember(
            pubkey: 'abc',
            npub: 'npub1abc',
            isAdmin: true,
            status: MembershipStatus.accepted,
          ),
        ],
      );
      expect(circle.isLegacyOrphaned, isFalse);
    });

    test('false for a pending invitation with no members yet', () {
      // A not-yet-accepted invitation also has an empty roster locally, but
      // it is NOT a legacy/orphaned circle — it just hasn't been joined.
      final circle = _circle(membershipStatus: MembershipStatus.pending);
      expect(circle.isLegacyOrphaned, isFalse);
    });

    test('false for a declined circle with no members', () {
      final circle = _circle(membershipStatus: MembershipStatus.declined);
      expect(circle.isLegacyOrphaned, isFalse);
    });
  });
}
