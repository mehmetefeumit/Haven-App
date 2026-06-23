/// Unit tests for the avatar surface of [CircleService].
///
/// Uses [MockCircleService] to assert:
/// - setMyAvatar forwards bytes and returns AvatarMetaFfi without leaking $e.
/// - clearMyAvatar calls the service and wipes local bytes.
/// - getMyAvatarThumbnail returns stored bytes or null.
/// - getMyAvatar returns stored full-res bytes or null.
/// - Errors produce CircleServiceException with a generic message.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';

import '../mocks/mock_circle_service.dart';

void main() {
  const pubkey =
      'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234';

  group('MockCircleService avatar surface', () {
    test('setMyAvatar records bytes and returns AvatarMetaFfi', () async {
      final svc = MockCircleService();
      final raw = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);

      final meta = await svc.setMyAvatar(pubkey, raw);

      expect(svc.setMyAvatarCalledWithBytes, equals(raw));
      expect(svc.methodCalls, contains('setMyAvatar'));
      expect(meta.mime, 'image/jpeg');
      expect(meta.width, 512);
      expect(meta.contentHashHex, isNotEmpty);
    });

    test('setMyAvatar throws CircleServiceException on configured error', () {
      final svc = MockCircleService()..shouldThrowOnSetMyAvatar = true;
      final raw = Uint8List.fromList([0x01]);

      expect(
        () => svc.setMyAvatar(pubkey, raw),
        throwsA(isA<CircleServiceException>()),
      );
    });

    test('clearMyAvatar sets clearMyAvatarCalled and wipes bytes', () async {
      final svc = MockCircleService()
        ..avatarThumbnailBytes = Uint8List.fromList([0xAB, 0xCD]);

      await svc.clearMyAvatar(pubkey);

      expect(svc.clearMyAvatarCalled, isTrue);
      expect(svc.avatarThumbnailBytes, isNull);
      expect(svc.methodCalls, contains('clearMyAvatar'));
    });

    test('clearMyAvatar throws CircleServiceException on configured error', () {
      final svc = MockCircleService()..shouldThrowOnClearMyAvatar = true;

      expect(
        () => svc.clearMyAvatar(pubkey),
        throwsA(isA<CircleServiceException>()),
      );
    });

    test('getMyAvatarThumbnail returns null when not set', () async {
      final svc = MockCircleService();
      final result = await svc.getMyAvatarThumbnail(pubkey);
      expect(result, isNull);
    });

    test('getMyAvatarThumbnail returns configured bytes', () async {
      final bytes = Uint8List.fromList([0x01, 0x02, 0x03]);
      final svc = MockCircleService()..avatarThumbnailBytes = bytes;

      final result = await svc.getMyAvatarThumbnail(pubkey);
      expect(result, equals(bytes));
      expect(svc.methodCalls, contains('getMyAvatarThumbnail'));
    });

    test('getMyAvatar returns null when not set', () async {
      final svc = MockCircleService();
      final result = await svc.getMyAvatar(pubkey);
      expect(result, isNull);
    });

    test('getMyAvatar returns configured full-res bytes', () async {
      final bytes = Uint8List.fromList([0x10, 0x20, 0x30, 0x40]);
      final svc = MockCircleService()..avatarFullBytes = bytes;

      final result = await svc.getMyAvatar(pubkey);
      expect(result, equals(bytes));
      expect(svc.methodCalls, contains('getMyAvatar'));
    });

    test(
      'setMyAvatar error message is generic — does not contain raw error',
      () async {
        final svc = MockCircleService()..shouldThrowOnSetMyAvatar = true;

        CircleServiceException? caught;
        try {
          await svc.setMyAvatar(pubkey, Uint8List(1));
        } on CircleServiceException catch (e) {
          caught = e;
        }

        expect(caught, isNotNull);
        // Generic message — must not expose internal details.
        expect(caught!.message.toLowerCase(), contains('avatar'));
        // Must not contain stack-trace-like content.
        expect(caught.message, isNot(contains('#0')));
        expect(caught.message, isNot(contains('stack')));
      },
    );
  });
}
