import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/identity_service.dart';

void main() {
  group('IdentityService', () {
    group('Identity', () {
      test('creates identity with required fields', () {
        final identity = Identity(
          pubkeyHex: 'a' * 64,
          npub: 'npub1test',
          createdAt: DateTime(2024),
        );

        expect(identity.pubkeyHex, 'a' * 64);
        expect(identity.npub, 'npub1test');
        expect(identity.createdAt, DateTime(2024));
      });

      test('equality is based on pubkeyHex', () {
        final identity1 = Identity(
          pubkeyHex: 'a' * 64,
          npub: 'npub1test',
          createdAt: DateTime(2024),
        );

        final identity2 = Identity(
          pubkeyHex: 'a' * 64,
          npub: 'npub1different',
          createdAt: DateTime(2025),
        );

        final identity3 = Identity(
          pubkeyHex: 'b' * 64,
          npub: 'npub1test',
          createdAt: DateTime(2024),
        );

        expect(identity1, equals(identity2));
        expect(identity1, isNot(equals(identity3)));
      });

      test('hashCode is based on pubkeyHex', () {
        final identity1 = Identity(
          pubkeyHex: 'a' * 64,
          npub: 'npub1test',
          createdAt: DateTime(2024),
        );

        final identity2 = Identity(
          pubkeyHex: 'a' * 64,
          npub: 'npub1different',
          createdAt: DateTime(2025),
        );

        expect(identity1.hashCode, equals(identity2.hashCode));
      });

      test('toString carries no npub at all, not even a prefix', () {
        const npub = 'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq';
        final identity = Identity(
          pubkeyHex: 'a' * 64,
          npub: npub,
          createdAt: DateTime(2024),
        );

        final str = identity.toString();
        // Rule 15: "redacted" means ABSENT, never a visible prefix — a
        // truncated npub still tells two installs apart.
        expect(str, isNot(contains(npub)));
        expect(str, isNot(contains('npub1')));
        expect(str, isNot(contains('...')));
        // What it renders instead is a per-process salted handle, so two
        // lines can still say "the same identity" without naming it.
        expect(str, startsWith('Identity(peer#'));
      });
    });

    group('IdentityServiceException', () {
      test('creates exception with message', () {
        const exception = IdentityServiceException('Test error');
        expect(exception.message, 'Test error');
      });

      test('toString includes message', () {
        const exception = IdentityServiceException('Test error');
        expect(exception.toString(), 'IdentityServiceException: Test error');
      });

      test('is an Exception', () {
        const exception = IdentityServiceException('Test error');
        expect(exception, isA<Exception>());
      });
    });
  });
}
