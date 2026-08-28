/// Tests for [NostrProfileService.getCachedMemberProfiles] — the cache-only,
/// bytes-free batch read the member picker opens on.
///
/// The manager fake throws from `noSuchMethod`, so ANY call other than
/// [_FakeCircleManager.getCachedProfiles] — every relay fetch, every Blossom
/// download, and every SINGLE-pubkey cache read — fails the test that made
/// it. That is what proves this reads through the batch FFI entry point
/// (`getCachedProfiles`), never through a per-pubkey fan-out: the assertions
/// below only have to pin the one read that is permitted.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/nostr_profile_service.dart';

const _alice =
    'a11ce0000000000000000000000000000000000000000000000000000000cafe';
const _bob =
    'b0b0000000000000000000000000000000000000000000000000000000000dad';
const _carol =
    'ca401000000000000000000000000000000000000000000000000000000beef0';

ProfileMetadataFfi _row(
  String pubkeyHex, {
  String? displayName,
  bool hasPicture = false,
  String? pictureSha256Hex,
  bool isKnown = true,
}) {
  return ProfileMetadataFfi(
    pubkeyHex: pubkeyHex,
    npub: 'npub1$pubkeyHex',
    displayName: displayName,
    hasPicture: hasPicture,
    isKnown: isKnown,
    fetchedAt: 1700000000,
    pictureSha256Hex: pictureSha256Hex,
  );
}

/// The synthesized "never resolved" row the real batch FFI entry point
/// returns for a pubkey with no cached kind-0, rather than omitting it — see
/// `get_cached_profiles`'s doc (`rust_builder/src/api.rs`). Built here so the
/// fake can reproduce that contract exactly instead of just dropping the
/// pubkey, which would test a shape the real Rust call never produces.
ProfileMetadataFfi _unresolved(String pubkeyHex) =>
    _row(pubkeyHex, isKnown: false);

class _FakeCircleManager implements CircleManagerFfi {
  _FakeCircleManager(this.rows);

  final Map<String, ProfileMetadataFfi> rows;

  /// Every batch call's requested pubkeys, in call order.
  final List<List<String>> batchCalls = <List<String>>[];

  /// When set, the batch call throws this instead of answering.
  Error? batchError;

  int pictureReads = 0;

  @override
  Future<List<ProfileMetadataFfi>> getCachedProfiles({
    required List<String> pubkeysHex,
  }) async {
    batchCalls.add(pubkeysHex);
    final error = batchError;
    if (error != null) throw error;
    // Mirrors the real contract: one row per input, in input order, a
    // synthesized not-known row for anything unresolved.
    return [
      for (final pubkeyHex in pubkeysHex)
        rows[pubkeyHex] ?? _unresolved(pubkeyHex),
    ];
  }

  @override
  Future<Uint8List?> getProfileThumbnail({required String pubkeyHex}) async {
    pictureReads++;
    return Uint8List.fromList(const [1, 2, 3]);
  }

  @override
  Future<Uint8List?> getProfilePicture({required String pubkeyHex}) async {
    pictureReads++;
    return Uint8List.fromList(const [1, 2, 3]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

class _UnusedIdentityService implements IdentityService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

NostrProfileService _service(
  _FakeCircleManager manager, {
  bool managerUnavailable = false,
}) {
  return NostrProfileService(
    identityService: _UnusedIdentityService(),
    circleManagerFactory: () async {
      if (managerUnavailable) throw StateError('manager unavailable');
      return manager;
    },
  );
}

void main() {
  group('getCachedMemberProfiles', () {
    test('resolves each pubkey from the cache, keyed by pubkey', () async {
      final manager = _FakeCircleManager({
        _alice: _row(_alice, displayName: 'Alice'),
        _bob: _row(_bob, displayName: 'Bob'),
      });

      final profiles =
          await _service(manager).getCachedMemberProfiles([_alice, _bob]);

      expect(profiles.keys, unorderedEquals(<String>[_alice, _bob]));
      expect(profiles[_alice]!.displayName, equals('Alice'));
      expect(profiles[_bob]!.displayName, equals('Bob'));
    });

    test('never reads picture bytes, even when the cache holds them',
        () async {
      // The picker keeps only the hash: a roster's worth of 96px thumbnails
      // is tens of megabytes decrypted, marshalled across FFI and dropped
      // for a list whose visible window is a handful of rows.
      final manager = _FakeCircleManager({
        _alice: _row(
          _alice,
          displayName: 'Alice',
          hasPicture: true,
          pictureSha256Hex: 'hash-a',
        ),
      });

      final profiles =
          await _service(manager).getCachedMemberProfiles([_alice]);

      expect(manager.pictureReads, isZero);
      expect(profiles[_alice]!.pictureBytes, isNull);
      expect(profiles[_alice]!.pictureHash, equals('hash-a'));
    });

    test('issues exactly ONE batch call carrying every pubkey, not one call '
        'per person', () async {
      // The defect this replaced: a fan-out of N single-pubkey FFI calls,
      // each queuing on the same connection mutex, for concurrency that
      // bought nothing.
      final manager = _FakeCircleManager({
        _alice: _row(_alice, displayName: 'Alice'),
        _bob: _row(_bob, displayName: 'Bob'),
        _carol: _row(_carol, displayName: 'Carol'),
      });

      final profiles = await _service(
        manager,
      ).getCachedMemberProfiles([_alice, _bob, _carol]);

      expect(manager.batchCalls, hasLength(1));
      expect(
        manager.batchCalls.single,
        orderedEquals(<String>[_alice, _bob, _carol]),
      );
      expect(profiles.keys, hasLength(3));
    });

    test('preserves input order in the underlying request', () async {
      final manager = _FakeCircleManager({
        _alice: _row(_alice, displayName: 'Alice'),
        _bob: _row(_bob, displayName: 'Bob'),
      });

      await _service(manager).getCachedMemberProfiles([_bob, _alice]);

      expect(manager.batchCalls.single, orderedEquals(<String>[_bob, _alice]));
    });

    test('omits a pubkey the cache has never resolved', () async {
      // The batch read still returns a row for it (synthesized, not-known) —
      // this proves the service drops that row rather than surfacing it as a
      // resolved, nameless entry.
      final manager = _FakeCircleManager({
        _alice: _row(_alice, displayName: 'Alice'),
      });

      final profiles =
          await _service(manager).getCachedMemberProfiles([_alice, _bob]);

      expect(profiles.keys, orderedEquals(<String>[_alice]));
    });

    test('omits a negative-cache row, which resolved nothing', () async {
      // The cache answers with a row for a pubkey it looked up and did not
      // find (`isKnown: false`, blank metadata). "An entry came back" is
      // not "a profile resolved", and a blank row would claim a name the
      // person does not have.
      final manager = _FakeCircleManager({
        _alice: _row(_alice, isKnown: false),
      });

      final profiles =
          await _service(manager).getCachedMemberProfiles([_alice]);

      expect(profiles, isEmpty);
    });

    test('returns an empty map when the manager cannot be opened', () async {
      final profiles = await _service(
        _FakeCircleManager(const {}),
        managerUnavailable: true,
      ).getCachedMemberProfiles([_alice]);

      expect(profiles, isEmpty);
    });

    test('returns an empty map when the batch call itself throws', () async {
      // The whole read is now one call under one connection lock: a genuine
      // storage failure fails the batch, not one row. The picker must still
      // degrade to nobody-resolved rather than propagate the failure.
      final manager = _FakeCircleManager({
        _alice: _row(_alice, displayName: 'Alice'),
      })..batchError = StateError('db unreadable');

      final profiles =
          await _service(manager).getCachedMemberProfiles([_alice]);

      expect(profiles, isEmpty);
    });

    test('reads nothing at all for an empty roster', () async {
      final manager = _FakeCircleManager(const {});

      final profiles =
          await _service(manager).getCachedMemberProfiles(const <String>[]);

      expect(profiles, isEmpty);
      expect(manager.batchCalls, isEmpty);
    });
  });
}
