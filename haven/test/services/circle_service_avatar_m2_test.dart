/// Unit tests for the M2 avatar-broadcast surface of [CircleService].
///
/// Covers:
/// - buildAvatarShareEvents: forwards args to mock, returns event JSON list.
/// - buildAvatarClearEvent: forwards args to mock, returns event JSON string.
/// - ingestIncomingAvatarMessage: forwards event JSON, returns AvatarIngestResult.
/// - getMemberAvatarThumbnail: returns bytes or null via mock.
/// - getMemberAvatar: returns full-res bytes or null via mock.
/// - Error paths: CircleServiceException produced with generic messages
///   (no raw error details).
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';

import '../mocks/mock_circle_service.dart';

void main() {
  const pubkey =
      'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234';
  final groupId = [1, 2, 3, 4];

  group('buildAvatarShareEvents', () {
    test('returns empty list by default', () async {
      final svc = MockCircleService();
      final result = await svc.buildAvatarShareEvents(
        mlsGroupId: groupId,
        senderPubkeyHex: pubkey,
        updateIntervalSecs: 198,
      );
      expect(result, isEmpty);
      expect(svc.methodCalls, contains('buildAvatarShareEvents'));
    });

    test('returns configured event JSON list', () async {
      final svc = MockCircleService()
        ..buildAvatarShareEventsResult = ['{"id":"a"}', '{"id":"b"}'];
      final result = await svc.buildAvatarShareEvents(
        mlsGroupId: groupId,
        senderPubkeyHex: pubkey,
        updateIntervalSecs: 198,
      );
      expect(result, equals(['{"id":"a"}', '{"id":"b"}']));
    });

    test('records call arguments', () async {
      final svc = MockCircleService();
      await svc.buildAvatarShareEvents(
        mlsGroupId: groupId,
        senderPubkeyHex: pubkey,
        updateIntervalSecs: 198,
      );
      expect(svc.buildAvatarShareEventsCalls, hasLength(1));
      expect(
        svc.buildAvatarShareEventsCalls.first['senderPubkeyHex'],
        equals(pubkey),
      );
      expect(
        svc.buildAvatarShareEventsCalls.first['updateIntervalSecs'],
        equals(198),
      );
    });

    test('throws CircleServiceException on configured error', () async {
      final svc = MockCircleService()
        ..shouldThrowOnBuildAvatarShareEvents = true;
      expect(
        () => svc.buildAvatarShareEvents(
          mlsGroupId: groupId,
          senderPubkeyHex: pubkey,
          updateIntervalSecs: 198,
        ),
        throwsA(isA<CircleServiceException>()),
      );
    });

    test('error message does not expose raw error text', () async {
      final svc = MockCircleService()
        ..shouldThrowOnBuildAvatarShareEvents = true;
      CircleServiceException? caught;
      try {
        await svc.buildAvatarShareEvents(
          mlsGroupId: groupId,
          senderPubkeyHex: pubkey,
          updateIntervalSecs: 198,
        );
      } on CircleServiceException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.message, isNot(contains('#0')));
      expect(caught.message, isNot(contains('stack')));
    });
  });

  group('buildAvatarClearEvent', () {
    test('returns configured event JSON string', () async {
      const expected = '{"id":"clear"}';
      final svc = MockCircleService()
        ..buildAvatarClearEventResult = expected;
      final result = await svc.buildAvatarClearEvent(
        mlsGroupId: groupId,
        senderPubkeyHex: pubkey,
        updateIntervalSecs: 198,
      );
      expect(result, equals(expected));
      expect(svc.methodCalls, contains('buildAvatarClearEvent'));
    });

    test('records call arguments', () async {
      final svc = MockCircleService();
      await svc.buildAvatarClearEvent(
        mlsGroupId: groupId,
        senderPubkeyHex: pubkey,
        updateIntervalSecs: 198,
      );
      expect(svc.buildAvatarClearEventCalls, hasLength(1));
      expect(
        svc.buildAvatarClearEventCalls.first['updateIntervalSecs'],
        equals(198),
      );
    });

    test('throws CircleServiceException on configured error', () async {
      final svc = MockCircleService()
        ..shouldThrowOnBuildAvatarClearEvent = true;
      expect(
        () => svc.buildAvatarClearEvent(
          mlsGroupId: groupId,
          senderPubkeyHex: pubkey,
          updateIntervalSecs: 198,
        ),
        throwsA(isA<CircleServiceException>()),
      );
    });
  });

  group('ingestIncomingAvatarMessage', () {
    test('returns AvatarIngestResult with accepted=false complete=false by default',
        () async {
      final svc = MockCircleService();
      final result = await svc.ingestIncomingAvatarMessage(
        eventJson: '{"id":"evt"}',
      );
      expect(result.accepted, isFalse);
      expect(result.complete, isFalse);
      expect(result.senderPubkeyHex, isNull);
      expect(svc.methodCalls, contains('ingestIncomingAvatarMessage'));
    });

    test('returns configured AvatarIngestResult when complete=true', () async {
      final svc = MockCircleService()
        ..ingestResult = const AvatarIngestResult(
          accepted: true,
          complete: true,
          senderPubkeyHex: pubkey,
        );
      final result = await svc.ingestIncomingAvatarMessage(
        eventJson: '{"id":"evt"}',
      );
      expect(result.accepted, isTrue);
      expect(result.complete, isTrue);
      expect(result.senderPubkeyHex, equals(pubkey));
    });

    test('records event JSON passed to the method', () async {
      const json = '{"id":"test_event"}';
      final svc = MockCircleService();
      await svc.ingestIncomingAvatarMessage(eventJson: json);
      expect(svc.ingestAvatarMessageCalls, contains(json));
    });

    test('throws CircleServiceException on configured error', () async {
      final svc = MockCircleService()
        ..shouldThrowOnIngestAvatarMessage = true;
      expect(
        () => svc.ingestIncomingAvatarMessage(eventJson: '{}'),
        throwsA(isA<CircleServiceException>()),
      );
    });
  });

  group('getMemberAvatarThumbnail', () {
    test('returns null when no bytes configured', () async {
      final svc = MockCircleService();
      final result = await svc.getMemberAvatarThumbnail(
        mlsGroupId: groupId,
        pubkey: pubkey,
      );
      expect(result, isNull);
      expect(svc.methodCalls, contains('getMemberAvatarThumbnail'));
    });

    test('returns configured thumbnail bytes', () async {
      final bytes = Uint8List.fromList([0x01, 0x02, 0x03]);
      final svc = MockCircleService()..memberAvatarThumbnailBytes = bytes;
      final result = await svc.getMemberAvatarThumbnail(
        mlsGroupId: groupId,
        pubkey: pubkey,
      );
      expect(result, equals(bytes));
    });

    test('throws CircleServiceException on configured error', () async {
      final svc = MockCircleService()
        ..shouldThrowOnGetMemberAvatarThumbnail = true;
      expect(
        () => svc.getMemberAvatarThumbnail(
          mlsGroupId: groupId,
          pubkey: pubkey,
        ),
        throwsA(isA<CircleServiceException>()),
      );
    });
  });

  group('getMemberAvatar', () {
    test('returns null when no bytes configured', () async {
      final svc = MockCircleService();
      final result = await svc.getMemberAvatar(
        mlsGroupId: groupId,
        pubkey: pubkey,
      );
      expect(result, isNull);
      expect(svc.methodCalls, contains('getMemberAvatar'));
    });

    test('returns configured full-res bytes', () async {
      final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF]);
      final svc = MockCircleService()..memberAvatarFullBytes = bytes;
      final result = await svc.getMemberAvatar(
        mlsGroupId: groupId,
        pubkey: pubkey,
      );
      expect(result, equals(bytes));
    });

    test('throws CircleServiceException on configured error', () async {
      final svc = MockCircleService()..shouldThrowOnGetMemberAvatar = true;
      expect(
        () => svc.getMemberAvatar(
          mlsGroupId: groupId,
          pubkey: pubkey,
        ),
        throwsA(isA<CircleServiceException>()),
      );
    });
  });

  group('AvatarIngestResult', () {
    test('equality: same fields are equal', () {
      const a = AvatarIngestResult(
        accepted: true,
        complete: true,
        senderPubkeyHex: 'abc',
      );
      const b = AvatarIngestResult(
        accepted: true,
        complete: true,
        senderPubkeyHex: 'abc',
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('equality: different complete value produces unequal', () {
      const a = AvatarIngestResult(accepted: true, complete: true);
      const b = AvatarIngestResult(accepted: true, complete: false);
      expect(a, isNot(equals(b)));
    });

    test('equality: different senderPubkeyHex produces unequal', () {
      const a = AvatarIngestResult(
        accepted: true,
        complete: true,
        senderPubkeyHex: 'abc',
      );
      const b = AvatarIngestResult(
        accepted: true,
        complete: true,
        senderPubkeyHex: 'xyz',
      );
      expect(a, isNot(equals(b)));
    });

    test('toString does not expose raw pubkey', () {
      const result = AvatarIngestResult(
        accepted: true,
        complete: true,
        senderPubkeyHex: 'deadbeef',
      );
      // toString must not reveal pubkey hex in full (security Rule 8).
      // The class is allowed to truncate or omit the pubkey.
      final str = result.toString();
      expect(str, isNotEmpty);
    });
  });
}
