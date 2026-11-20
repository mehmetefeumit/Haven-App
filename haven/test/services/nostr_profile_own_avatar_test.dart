/// Tests for [NostrProfileService.setOwnAvatar]'s wait for the MLS session.
///
/// On Android the photo picker's and the crop editor's result arrives before
/// Haven's window has focus, while the session may still be handed to the
/// foreground service. The save waits for this isolate to own the session
/// again before it opens anything; a save the session still refuses fails
/// closed with a log line that names the refusal and nothing else.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/nostr_profile_service.dart';
import 'package:haven/src/services/profile_service.dart';

import '../helpers/log_capture.dart';

const _pubkeyHex =
    'a11ce0000000000000000000000000000000000000000000000000000000cafe';
const _npub = 'npub1q5kcjqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqhh8a4u';

class _FakeCircleManager implements CircleManagerFfi {
  final List<List<int>> saved = [];

  @override
  Future<ProfilePictureRefFfi> saveMyProfilePictureLocal({
    required List<int> raw,
  }) async {
    saved.add(raw);
    return const ProfilePictureRefFfi(pubkeyHex: _pubkeyHex, sha256Hex: 'aa');
  }

  @override
  Future<ProfileMetadataFfi?> getCachedProfile({
    required String pubkeyHex,
  }) async => null;

  @override
  Future<Uint8List?> getProfilePicture({required String pubkeyHex}) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

class _UnusedIdentityService implements IdentityService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

void main() {
  final bytes = Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);

  test('a photo save opens no session until the handoff wait settles, then '
      'saves', () async {
    final manager = _FakeCircleManager();
    final owned = Completer<void>();
    var opens = 0;
    final service = NostrProfileService(
      identityService: _UnusedIdentityService(),
      circleManagerFactory: () async {
        opens++;
        return manager;
      },
      untilSessionOwned: () => owned.future,
    );

    final saving = service.setOwnAvatar(bytes);
    await pumpEventQueue();
    expect(opens, 0, reason: 'an open made now lands in the handoff refusal');

    owned.complete();
    final profile = await saving;
    expect(opens, 1);
    expect(manager.saved, [bytes]);
    expect(profile.pubkeyHex, _pubkeyHex);
  });

  test('a save the session still refuses after the wait fails closed, logging '
      'the refusal by type alone', () async {
    final log = LogCapture.install();
    final service = NostrProfileService(
      identityService: _UnusedIdentityService(),
      circleManagerFactory: () async => throw const SessionHandedOffException(),
      untilSessionOwned: () async {},
    );
    // Identifiers planted in the one input this call has.
    final planted = Uint8List.fromList(utf8.encode('$_npub $_pubkeyHex'));

    await expectLater(
      service.setOwnAvatar(planted),
      throwsA(isA<ProfileServiceException>()),
    );
    log
      ..assertContains('[Profile] setOwnAvatar: SessionHandedOffException')
      ..assertNoNeedles([_npub, _pubkeyHex]);
  });

  test('an open that fails for any other reason logs only its type', () async {
    final log = LogCapture.install();
    final service = NostrProfileService(
      identityService: _UnusedIdentityService(),
      circleManagerFactory: () async =>
          throw StateError('$_npub /data/user/0/haven/circles.db'),
      untilSessionOwned: () async {},
    );

    await expectLater(
      service.setOwnAvatar(bytes),
      throwsA(isA<ProfileServiceException>()),
    );
    log
      ..assertContains('[Profile] setOwnAvatar: StateError')
      ..assertNoNeedles([_npub, '/data/user/0/haven/circles.db']);
  });
}
