/// Unit tests for [memberAvatarThumbnailProvider] and [MemberAvatarKey].
///
/// Verifies:
/// - Provider fetches from `CircleService.getMemberAvatarThumbnail`.
/// - Returns null when service returns null.
/// - Returns bytes when service returns bytes.
/// - Returns null (instead of propagating) when service throws.
/// - `MemberAvatarKey` equality / hashCode are stable.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/member_avatar_provider.dart';
import 'package:haven/src/providers/service_providers.dart';

import '../mocks/mock_circle_service.dart';

void main() {
  const pubkey =
      'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234';
  final groupId = [0x01, 0x02, 0x03, 0x04];

  ProviderContainer makeContainer(MockCircleService svc) {
    return ProviderContainer(
      overrides: [circleServiceProvider.overrideWithValue(svc)],
    );
  }

  group('MemberAvatarKey', () {
    test('identical keys are equal', () {
      const a = MemberAvatarKey(mlsGroupId: [1, 2, 3], pubkeyHex: pubkey);
      const b = MemberAvatarKey(mlsGroupId: [1, 2, 3], pubkeyHex: pubkey);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different pubkeyHex produces unequal keys', () {
      const a = MemberAvatarKey(mlsGroupId: [1, 2, 3], pubkeyHex: 'aaa');
      const b = MemberAvatarKey(mlsGroupId: [1, 2, 3], pubkeyHex: 'bbb');
      expect(a, isNot(equals(b)));
    });

    test('different mlsGroupId produces unequal keys', () {
      const a = MemberAvatarKey(mlsGroupId: [1, 2, 3], pubkeyHex: pubkey);
      const b = MemberAvatarKey(mlsGroupId: [1, 2, 4], pubkeyHex: pubkey);
      expect(a, isNot(equals(b)));
    });

    test('different mlsGroupId length produces unequal keys', () {
      const a = MemberAvatarKey(mlsGroupId: [1, 2], pubkeyHex: pubkey);
      const b = MemberAvatarKey(mlsGroupId: [1, 2, 3], pubkeyHex: pubkey);
      expect(a, isNot(equals(b)));
    });

    test('key with empty groupId equals another with empty groupId', () {
      const a = MemberAvatarKey(mlsGroupId: [], pubkeyHex: pubkey);
      const b = MemberAvatarKey(mlsGroupId: [], pubkeyHex: pubkey);
      expect(a, equals(b));
    });
  });

  group('memberAvatarThumbnailProvider', () {
    test('returns null when service returns null', () async {
      final svc = MockCircleService();
      final container = makeContainer(svc);
      addTearDown(container.dispose);

      final key = MemberAvatarKey(mlsGroupId: groupId, pubkeyHex: pubkey);
      final result = await container.read(
        memberAvatarThumbnailProvider(key).future,
      );
      expect(result, isNull);
      expect(svc.methodCalls, contains('getMemberAvatarThumbnail'));
    });

    test('returns bytes when service has thumbnail', () async {
      final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF]);
      final svc = MockCircleService()..memberAvatarThumbnailBytes = bytes;
      final container = makeContainer(svc);
      addTearDown(container.dispose);

      final key = MemberAvatarKey(mlsGroupId: groupId, pubkeyHex: pubkey);
      final result = await container.read(
        memberAvatarThumbnailProvider(key).future,
      );
      expect(result, equals(bytes));
    });

    test('returns null (does not throw) when service throws', () async {
      final svc = MockCircleService()
        ..shouldThrowOnGetMemberAvatarThumbnail = true;
      final container = makeContainer(svc);
      addTearDown(container.dispose);

      final key = MemberAvatarKey(mlsGroupId: groupId, pubkeyHex: pubkey);
      final result = await container.read(
        memberAvatarThumbnailProvider(key).future,
      );
      // Provider catches errors and returns null — UI always sees null, never
      // an exception propagating to the widget tree.
      expect(result, isNull);
    });

    test('two different keys use independent provider instances', () async {
      final bytesA = Uint8List.fromList([0x01]);
      final svc = MockCircleService()..memberAvatarThumbnailBytes = bytesA;
      final container = makeContainer(svc);
      addTearDown(container.dispose);

      const keyA = MemberAvatarKey(mlsGroupId: [1], pubkeyHex: 'aaa');
      const keyB = MemberAvatarKey(mlsGroupId: [1], pubkeyHex: 'bbb');

      // Both use the same mock which returns bytesA regardless of pubkey.
      final resultA =
          await container.read(memberAvatarThumbnailProvider(keyA).future);
      final resultB =
          await container.read(memberAvatarThumbnailProvider(keyB).future);

      // They both resolve (independently) from the same mock.
      expect(resultA, equals(bytesA));
      expect(resultB, equals(bytesA));
      // Two calls were made (not cached across different keys).
      expect(
        svc.methodCalls.where((m) => m == 'getMemberAvatarThumbnail').length,
        equals(2),
      );
    });
  });
}
