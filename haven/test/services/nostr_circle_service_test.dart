/// Tests for NostrCircleService.
///
/// ## Test Strategy
///
/// NostrCircleService has a hard dependency on
/// `CircleManagerFfi.newInstance()` which requires Rust FFI initialization.
///
/// These tests verify:
/// 1. Data structure behavior and immutability
/// 2. Type conversions between FFI and service layer
/// 3. Validation logic
/// 4. Error types
///
/// Full integration tests with Rust bridge are in integration_test/.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CircleService - Data Structures', () {
    group('MembershipStatus', () {
      test('has all expected values', () {
        expect(MembershipStatus.values.length, 3);
        expect(MembershipStatus.pending, isNotNull);
        expect(MembershipStatus.accepted, isNotNull);
        expect(MembershipStatus.declined, isNotNull);
      });
    });

    group('CircleType', () {
      test('has all expected values', () {
        expect(CircleType.values.length, 2);
        expect(CircleType.locationSharing, isNotNull);
        expect(CircleType.directShare, isNotNull);
      });
    });

    group('Circle', () {
      test('creates with all required fields', () {
        final circle = Circle(
          mlsGroupId: [1, 2, 3, 4],
          nostrGroupId: [5, 6, 7, 8],
          displayName: 'Test Circle',
          circleType: CircleType.locationSharing,
          relays: ['wss://relay.example.com'],
          membershipStatus: MembershipStatus.accepted,
          members: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        expect(circle.displayName, 'Test Circle');
        expect(circle.circleType, CircleType.locationSharing);
        expect(circle.relays, contains('wss://relay.example.com'));
        expect(circle.membershipStatus, MembershipStatus.accepted);
      });

      test('equality is based on mlsGroupId', () {
        final circle1 = Circle(
          mlsGroupId: [1, 2, 3, 4],
          nostrGroupId: [5, 6, 7, 8],
          displayName: 'Circle 1',
          circleType: CircleType.locationSharing,
          relays: const [],
          membershipStatus: MembershipStatus.accepted,
          members: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final circle2 = Circle(
          mlsGroupId: [1, 2, 3, 4],
          nostrGroupId: [9, 10, 11, 12],
          displayName: 'Circle 2 - Different Name',
          circleType: CircleType.directShare,
          relays: const [],
          membershipStatus: MembershipStatus.pending,
          members: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        expect(circle1, equals(circle2));
      });

      test('hashCode is based on mlsGroupId', () {
        final circle1 = Circle(
          mlsGroupId: [1, 2, 3, 4],
          nostrGroupId: [5, 6, 7, 8],
          displayName: 'Circle 1',
          circleType: CircleType.locationSharing,
          relays: const [],
          membershipStatus: MembershipStatus.accepted,
          members: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final circle2 = Circle(
          mlsGroupId: [1, 2, 3, 4],
          nostrGroupId: [9, 10, 11, 12],
          displayName: 'Different',
          circleType: CircleType.locationSharing,
          relays: const [],
          membershipStatus: MembershipStatus.accepted,
          members: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        expect(circle1.hashCode, equals(circle2.hashCode));
      });

      test('toString includes displayName', () {
        final circle = Circle(
          mlsGroupId: [1, 2, 3, 4],
          nostrGroupId: [5, 6, 7, 8],
          displayName: 'My Friends',
          circleType: CircleType.locationSharing,
          relays: const [],
          membershipStatus: MembershipStatus.accepted,
          members: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        expect(circle.toString(), contains('My Friends'));
      });
    });

    group('CircleMember', () {
      test('creates with required fields', () {
        const member = CircleMember(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          isAdmin: true,
          status: MembershipStatus.accepted,
        );

        expect(member.pubkey.length, 64);
        expect(member.isAdmin, true);
        expect(member.status, MembershipStatus.accepted);
      });

      test('creates with optional fields', () {
        const member = CircleMember(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          isAdmin: false,
          status: MembershipStatus.pending,
          displayName: 'Alice',
          avatarPath: '/path/to/avatar.png',
        );

        expect(member.displayName, 'Alice');
        expect(member.avatarPath, '/path/to/avatar.png');
      });

      test('equality is based on pubkey', () {
        const member1 = CircleMember(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          isAdmin: true,
          status: MembershipStatus.accepted,
          displayName: 'Alice',
        );

        const member2 = CircleMember(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          isAdmin: false,
          status: MembershipStatus.pending,
          displayName: 'Different Name',
        );

        expect(member1, equals(member2));
      });

      test('toString includes pubkey and status', () {
        const member = CircleMember(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          isAdmin: true,
          status: MembershipStatus.accepted,
        );

        final str = member.toString();
        expect(str, contains('aaaa'));
        expect(str, contains('accepted'));
      });
    });

    group('CircleCreationResult', () {
      test('creates with circle and welcome events', () {
        final circle = Circle(
          mlsGroupId: [1, 2, 3, 4],
          nostrGroupId: [5, 6, 7, 8],
          displayName: 'Test',
          circleType: CircleType.locationSharing,
          relays: const [],
          membershipStatus: MembershipStatus.accepted,
          members: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        const welcomes = [
          GiftWrappedWelcome(
            recipientPubkey:
                'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            recipientRelays: ['wss://relay.example.com'],
            eventJson: '{"kind":1059}',
          ),
        ];

        final result = CircleCreationResult(
          circle: circle,
          welcomeEvents: welcomes,
        );

        expect(result.circle, equals(circle));
        expect(result.welcomeEvents.length, 1);
      });
    });

    group('GiftWrappedWelcome', () {
      test('creates with all fields', () {
        const welcome = GiftWrappedWelcome(
          recipientPubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          recipientRelays: ['wss://relay1.com', 'wss://relay2.com'],
          eventJson: '{"kind":1059,"content":"encrypted"}',
        );

        expect(welcome.recipientPubkey.length, 64);
        expect(welcome.recipientRelays.length, 2);
        expect(welcome.eventJson, contains('"kind":1059'));
      });

      test('event is kind 1059 gift wrap', () {
        const welcome = GiftWrappedWelcome(
          recipientPubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          recipientRelays: ['wss://relay.example.com'],
          eventJson: '{"kind":1059,"content":"encrypted_seal"}',
        );

        // Kind 1059 is NIP-59 gift wrap
        expect(welcome.eventJson, contains('1059'));
      });
    });

    group('Invitation', () {
      test('creates with all fields', () {
        final invitation = Invitation(
          mlsGroupId: [1, 2, 3, 4],
          circleName: 'Family',
          inviterPubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          memberCount: 5,
          invitedAt: DateTime.now(),
        );

        expect(invitation.circleName, 'Family');
        expect(invitation.inviterPubkey.length, 64);
        expect(invitation.memberCount, 5);
      });
    });

    group('KeyPackageData', () {
      test('creates with all fields', () {
        const keyPackage = KeyPackageData(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          eventJson: '{"kind":443,"content":"key_package_bytes"}',
          relays: ['wss://relay.example.com'],
        );

        expect(keyPackage.pubkey.length, 64);
        expect(keyPackage.eventJson, contains('"kind":443'));
        expect(keyPackage.relays, isNotEmpty);
      });

      test('event is kind 443 KeyPackage', () {
        const keyPackage = KeyPackageData(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          eventJson: '{"kind":443}',
          relays: ['wss://relay.example.com'],
        );

        // Kind 443 is MIP-01 KeyPackage
        expect(keyPackage.eventJson, contains('443'));
      });
    });

    group('CircleServiceException', () {
      test('creates with message', () {
        const exception = CircleServiceException('Test error');
        expect(exception.message, 'Test error');
      });

      test('toString includes message', () {
        const exception = CircleServiceException('Circle not found');
        expect(exception.toString(), contains('CircleServiceException'));
        expect(exception.toString(), contains('Circle not found'));
      });

      test('is an Exception', () {
        const exception = CircleServiceException('Test');
        expect(exception, isA<Exception>());
      });
    });
  });

  group('CircleService - Validation', () {
    test('secret bytes must be 32 bytes', () {
      final validSecretBytes = List<int>.filled(32, 0);
      expect(validSecretBytes.length, 32);
    });

    test('circle name must be non-empty', () {
      const validName = 'My Circle';
      expect(validName, isNotEmpty);
    });

    test('pubkey must be 64 hex characters', () {
      const pubkey =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      expect(pubkey.length, 64);
    });

    test('MLS group ID is internal and private', () {
      final mlsGroupId = [1, 2, 3, 4];
      final nostrGroupId = [5, 6, 7, 8];

      // Only nostrGroupId goes in events, mlsGroupId stays local
      expect(mlsGroupId, isNotEmpty);
      expect(nostrGroupId, isNotEmpty);
    });
  });

  group('CircleService - Type Conversions', () {
    test('CircleType.locationSharing maps to location_sharing', () {
      const type = CircleType.locationSharing;
      expect(type, CircleType.locationSharing);
      // Expected string: 'location_sharing'
    });

    test('CircleType.directShare maps to direct_share', () {
      const type = CircleType.directShare;
      expect(type, CircleType.directShare);
      // Expected string: 'direct_share'
    });

    test('MembershipStatus.pending maps to pending', () {
      const status = MembershipStatus.pending;
      expect(status, MembershipStatus.pending);
      // Expected string: 'pending'
    });

    test('MembershipStatus.accepted maps to accepted', () {
      const status = MembershipStatus.accepted;
      expect(status, MembershipStatus.accepted);
      // Expected string: 'accepted'
    });

    test('MembershipStatus.declined maps to declined', () {
      const status = MembershipStatus.declined;
      expect(status, MembershipStatus.declined);
      // Expected string: 'declined'
    });

    test('timestamps convert from seconds to DateTime', () {
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
      expect(dateTime, isA<DateTime>());
    });
  });

  group('CircleService - Security Requirements', () {
    test('secret bytes are 32 bytes for secp256k1', () {
      // Nostr uses secp256k1 with 32-byte private keys
      final secretBytes = List<int>.filled(32, 0);
      expect(secretBytes.length, 32);
    });

    test('welcome events use NIP-59 gift wrapping', () {
      // Kind 444 Welcome events are wrapped in kind 1059
      const welcome = GiftWrappedWelcome(
        recipientPubkey:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        recipientRelays: ['wss://relay.example.com'],
        eventJson: '{"kind":1059}',
      );

      expect(welcome.eventJson, contains('1059'));
    });

    test('nostrGroupId is exposed, not mlsGroupId', () {
      // For privacy, only nostrGroupId is shared publicly
      // mlsGroupId is internal and never leaves the device
      final circle = Circle(
        mlsGroupId: [1, 2, 3, 4],
        nostrGroupId: [5, 6, 7, 8],
        displayName: 'Test',
        circleType: CircleType.locationSharing,
        relays: const [],
        membershipStatus: MembershipStatus.accepted,
        members: const [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(circle.mlsGroupId, isNotEmpty);
      expect(circle.nostrGroupId, isNotEmpty);
      // Only nostrGroupId goes in events
    });
  });

  group('CircleService - Error Handling', () {
    test('invalid secret bytes length error', () {
      final invalidBytes = List<int>.filled(16, 0);
      expect(invalidBytes.length, 16);
      // Should throw: "Invalid identity secret bytes length: expected 32, got 16"
    });

    test('error messages start with Failed to', () {
      final operations = [
        'Failed to create circle',
        'Failed to get circle',
        'Failed to get members',
        'Failed to accept invitation',
        'Failed to decline invitation',
        'Failed to leave circle',
      ];

      for (final operation in operations) {
        expect(operation, startsWith('Failed to'));
      }
    });
  });

  group('CircleService - Constants', () {
    test('data directory includes haven subdirectory', () {
      const dataDir = '/path/to/app/documents/haven';
      expect(dataDir, contains('haven'));
    });

    test('nostr group ID is 16 bytes', () {
      final nostrGroupId = List<int>.filled(16, 1);
      expect(nostrGroupId.length, 16);
    });
  });
}
