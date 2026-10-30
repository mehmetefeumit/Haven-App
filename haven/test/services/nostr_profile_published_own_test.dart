/// [NostrProfileService.fetchOwnPublishedProfile] reports what the profile
/// relays hold — the profile one served, or that every one answered with
/// none — and never passes off the cached copy the fetch falls back to,
/// which may hold an edit the network never saw (the storage-reset reseed
/// relies on this). It never forces the fetch past its miss backoff — only
/// an explicit refresh does — and reads no picture.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/nostr_profile_service.dart';
import 'package:haven/src/services/profile_service.dart';

const _me = 'a11ce0000000000000000000000000000000000000000000000000000000cafe';

class _FakeIdentityService implements IdentityService {
  @override
  Future<Identity?> getIdentity() async =>
      Identity(pubkeyHex: _me, npub: 'npub1me', createdAt: DateTime(2024));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

class _FakeCircleManager implements CircleManagerFfi {
  _FakeCircleManager(this.answer);

  /// The fetch's answer, or the [Error] it throws.
  final Object answer;

  /// Whether each fetch was forced.
  final List<bool> forced = [];

  /// How many times picture bytes were read, at either resolution.
  int pictureReads = 0;

  @override
  Future<Uint8List?> getProfilePicture({required String pubkeyHex}) async {
    pictureReads++;
    return null;
  }

  @override
  Future<Uint8List?> getProfileThumbnail({required String pubkeyHex}) async {
    pictureReads++;
    return null;
  }

  @override
  Future<ProfileMetadataFfi> fetchMyProfile({
    required String pubkeyHex,
    required bool force,
  }) async {
    forced.add(force);
    final answer = this.answer;
    if (answer is Error) throw answer;
    return answer as ProfileMetadataFfi;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

/// A cached, known row with a picture, as the relays answered [relayAnswer].
ProfileMetadataFfi _row(OwnProfileRelayAnswerFfi relayAnswer) =>
    ProfileMetadataFfi(
      pubkeyHex: _me,
      npub: 'npub1me',
      displayName: 'Quiet Wanderer',
      hasPicture: true,
      isKnown: true,
      fetchedAt: 1700000000,
      relayAnswer: relayAnswer,
    );

Future<PublishedOwnProfile> _fetchFrom(_FakeCircleManager manager) =>
    NostrProfileService(
      identityService: _FakeIdentityService(),
      circleManagerFactory: () async => manager,
    ).fetchOwnPublishedProfile();

Future<PublishedOwnProfile> _fetch(Object answer) =>
    _fetchFrom(_FakeCircleManager(answer));

void main() {
  test('a relay answer is the published profile, read without its '
      'picture', () async {
    final manager = _FakeCircleManager(
      _row(OwnProfileRelayAnswerFfi.published),
    );
    final published = await _fetchFrom(manager);
    expect(published.answered, isTrue);
    expect(published.profile?.displayName, 'Quiet Wanderer');
    expect(manager.pictureReads, 0, reason: 'a name needs no picture');
  });

  test('the cached row a fetch the relays did not settle returns is not '
      'an answer', () async {
    final published = await _fetch(_row(OwnProfileRelayAnswerFfi.unanswered));
    expect(published.answered, isFalse);
    expect(published.profile, isNull);
  });

  test('every relay answering without a profile is an answer with no '
      'profile, whatever is cached', () async {
    final published = await _fetch(_row(OwnProfileRelayAnswerFfi.absent));
    expect(published.answered, isTrue);
    expect(published.profile, isNull);
  });

  test('the fetch is never forced past its miss backoff', () async {
    final manager = _FakeCircleManager(
      _row(OwnProfileRelayAnswerFfi.unanswered),
    );
    await _fetchFrom(manager);
    expect(
      manager.forced,
      [false],
      reason: 'forced, a reseed the relays never settle asks them on every '
          'foreground',
    );
  });

  test('an explicit refresh of the own profile is forced', () async {
    final manager = _FakeCircleManager(
      _row(OwnProfileRelayAnswerFfi.published),
    );
    await NostrProfileService(
      identityService: _FakeIdentityService(),
      circleManagerFactory: () async => manager,
    ).getOwnProfile(forceRefresh: true);
    expect(manager.forced, [true]);
  });

  test('a failed fetch is a typed failure, never a cache fallback', () async {
    await expectLater(
      _fetch(StateError('relay down')),
      throwsA(isA<ProfileServiceException>()),
    );
  });
}
