/// Tests for the two local-only reads of [NostrProfileService]: the user's
/// own name without its picture ([NostrProfileService.getOwnProfileText]) and
/// a member's full-size picture ([NostrProfileService.getMemberPicture]).
///
/// Each touches the encrypted store and nothing else — no picture bytes for
/// the name, no network for either — and a failure logs its type alone.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/nostr_profile_service.dart';
import 'package:haven/src/services/profile_service.dart';

import '../helpers/log_capture.dart';

const _ownHex =
    'a11ce0000000000000000000000000000000000000000000000000000000cafe';
const _memberHex =
    'b0b0000000000000000000000000000000000000000000000000000000000b0b';

/// Answers the reads it is given and records every member called on it, so
/// a test can assert that nothing else — a picture read, a relay fetch, a
/// download — was asked for.
class _RecordingCircleManager implements CircleManagerFfi {
  _RecordingCircleManager({this.cached, this.picture, this.pictureError});

  final ProfileMetadataFfi? cached;
  final Uint8List? picture;
  final Error? pictureError;
  final List<String> calls = [];

  @override
  Future<ProfileMetadataFfi?> getCachedProfile({
    required String pubkeyHex,
  }) async {
    calls.add('getCachedProfile:$pubkeyHex');
    return cached;
  }

  @override
  Future<Uint8List?> getProfilePicture({required String pubkeyHex}) async {
    calls.add('getProfilePicture:$pubkeyHex');
    final error = pictureError;
    if (error != null) throw error;
    return picture;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName.toString());
    throw UnimplementedError('unexpected: ${invocation.memberName}');
  }
}

class _OwnIdentityService implements IdentityService {
  @override
  Future<Identity?> getIdentity() async =>
      Identity(pubkeyHex: _ownHex, npub: 'npub1own', createdAt: DateTime(2025));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

ProfileMetadataFfi _row({String? displayName, bool hasPicture = true}) =>
    ProfileMetadataFfi(
      pubkeyHex: _ownHex,
      npub: 'npub1own',
      displayName: displayName,
      hasPicture: hasPicture,
      isKnown: true,
      fetchedAt: 1700000000,
      relayAnswer: OwnProfileRelayAnswerFfi.unanswered,
      pictureSha256Hex: 'aa',
    );

NostrProfileService _service(Future<CircleManagerFfi> Function() factory) =>
    NostrProfileService(
      identityService: _OwnIdentityService(),
      circleManagerFactory: factory,
    );

void main() {
  group('getOwnProfileText', () {
    test('reads the own row and no picture, from the store alone', () async {
      final manager = _RecordingCircleManager(
        cached: _row(displayName: 'Quiet Wanderer'),
      );

      final profile = await _service(() async => manager).getOwnProfileText();

      expect(profile?.displayName, 'Quiet Wanderer');
      expect(profile?.pictureBytes, isNull);
      expect(manager.calls, ['getCachedProfile:$_ownHex']);
    });

    test('a store that cannot be opened is a failure, not a missing name, '
        'and logs its type alone', () async {
      final logs = LogCapture.install();

      await expectLater(
        _service(
          () async => throw StateError('$_ownHex /data/circles.db'),
        ).getOwnProfileText(),
        throwsA(isA<ProfileServiceException>()),
      );
      logs
        ..assertContains('[Profile] getOwnProfileText: StateError')
        ..assertNoNeedles([_ownHex, '/data/circles.db']);
    });
  });

  group('getMemberPicture', () {
    test('returns the full-size bytes, from the store alone', () async {
      final full = Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE1]);
      final manager = _RecordingCircleManager(picture: full);

      final bytes = await _service(
        () async => manager,
      ).getMemberPicture(_memberHex);

      expect(bytes, same(full));
      expect(manager.calls, ['getProfilePicture:$_memberHex']);
    });

    test('a failed read is no picture, and logs its type alone', () async {
      final logs = LogCapture.install();
      final manager = _RecordingCircleManager(
        pictureError: StateError('$_memberHex unreadable'),
      );

      expect(
        await _service(() async => manager).getMemberPicture(_memberHex),
        isNull,
      );
      expect(manager.calls, ['getProfilePicture:$_memberHex']);
      logs
        ..assertContains('[Profile] getMemberPicture: StateError')
        ..assertNoNeedles([_memberHex]);
    });
  });
}
