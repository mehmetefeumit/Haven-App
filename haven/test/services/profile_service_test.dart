/// Unit tests for [NostrProfileService] that do NOT require the Rust FFI
/// bridge.
///
/// `NostrProfileService` is FFI-backed (like `NostrCircleService`) — any
/// path that must actually construct/call a `CircleManagerFfi` cannot be
/// exercised here (see `test/services/DEPENDENCY_INJECTION_EXAMPLES.md`,
/// "Testing NostrProfileService"). What IS provable without the bridge:
///
/// - Publishing is unconditional (no consent gate, public-by-default,
///   owner-directed 2026-07-16): [NostrProfileService.updateOwnProfile] /
///   [NostrProfileService.setOwnAvatar] / [NostrProfileService.removeOwnAvatar]
///   ALWAYS reach the manager factory — there is no Dart-side pre-check that
///   could short-circuit before it runs.
/// - [NostrProfileService.getOwnProfile] returns `null` (never touching the
///   manager factory) before an identity exists, and surfaces a redacted
///   generic [ProfileServiceException] on an identity-lookup failure.
/// - Every FFI-adjacent catch site never leaks a raw error message (Rule 8)
///   — provable by making the manager factory (or the identity service)
///   throw an exception whose message embeds a fake hex secret, and
///   asserting the surfaced exception message is the FIXED generic string.
///
/// Full read/write behavior against a real manager is covered by
/// `integration_test/`, same as `NostrCircleService` today. Behavior
/// coverage for the FFI-backed read/write paths (converted `Profile`
/// shape, picture-download decisions, cache-fallback-on-refresh-failure,
/// etc.) lives in the provider test files, which exercise them through
/// `MockProfileService`.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/nostr_profile_service.dart';
import 'package:haven/src/services/profile_service.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// A fake secret-bearing string embedded in thrown errors below, to prove
/// it never survives into a surfaced [ProfileServiceException.message]
/// (Security Rule 8 — no raw errors in UI/logs surfaced to callers).
const _fakeHexSecret = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef';

final _testIdentity = Identity(
  pubkeyHex:
      'aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234',
  npub: 'npub1test',
  createdAt: DateTime(2025),
);

class _FakeIdentityService implements IdentityService {
  _FakeIdentityService({this.identity, this.throwOnGetIdentity = false});

  /// The identity returned by [getIdentity]. `null` (the default)
  /// simulates "no identity exists yet".
  final Identity? identity;

  /// When `true`, [getIdentity] throws an error whose message embeds
  /// [_fakeHexSecret] (redaction canary).
  final bool throwOnGetIdentity;

  @override
  Future<bool> hasIdentity() async => identity != null;

  @override
  Future<Identity?> getIdentity() async {
    if (throwOnGetIdentity) {
      throw Exception('identity read failed: secret=$_fakeHexSecret');
    }
    return identity;
  }

  @override
  Future<Identity> createIdentity() => throw UnimplementedError();

  @override
  Future<Identity> importFromNsec(String nsec) => throw UnimplementedError();

  @override
  Future<String> exportNsec() => throw UnimplementedError();

  @override
  Future<String> sign(Uint8List messageHash) => throw UnimplementedError();

  @override
  Future<String> getPubkeyHex() async => identity!.pubkeyHex;

  @override
  Future<List<int>> getSecretBytes() async => List<int>.filled(32, 0x11);

  @override
  Future<void> deleteIdentity() async {}

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}
}

void main() {
  group('NostrProfileService — publishing is unconditional', () {
    test(
      'updateOwnProfile always reaches the manager factory — no Dart-side '
      'gate to short-circuit it',
      () async {
        var managerFactoryCalls = 0;

        final service = NostrProfileService(
          identityService: _FakeIdentityService(identity: _testIdentity),
          circleManagerFactory: () async {
            managerFactoryCalls++;
            throw Exception('manager unavailable: $_fakeHexSecret');
          },
        );

        await expectLater(
          service.updateOwnProfile(displayName: 'Alex'),
          throwsA(isA<ProfileServiceException>()),
        );

        // Public-by-default (owner-directed 2026-07-16): there is no
        // consent pre-check, so the call must reach the manager factory.
        expect(managerFactoryCalls, 1);
      },
    );

    test(
      'setOwnAvatar always reaches the manager factory — no Dart-side gate '
      'to short-circuit it',
      () async {
        var managerFactoryCalls = 0;

        final service = NostrProfileService(
          identityService: _FakeIdentityService(identity: _testIdentity),
          circleManagerFactory: () async {
            managerFactoryCalls++;
            throw Exception('manager unavailable: $_fakeHexSecret');
          },
        );

        await expectLater(
          service.setOwnAvatar(Uint8List.fromList([1, 2, 3])),
          throwsA(isA<ProfileServiceException>()),
        );

        expect(managerFactoryCalls, 1);
      },
    );

    test(
      'removeOwnAvatar (retraction) also always reaches the manager factory',
      () async {
        var managerFactoryCalls = 0;

        final service = NostrProfileService(
          identityService: _FakeIdentityService(identity: _testIdentity),
          circleManagerFactory: () async {
            managerFactoryCalls++;
            throw Exception('manager unavailable: $_fakeHexSecret');
          },
        );

        await expectLater(
          service.removeOwnAvatar(),
          throwsA(isA<ProfileServiceException>()),
        );

        expect(managerFactoryCalls, 1);
      },
    );
  });

  group('NostrProfileService — getOwnProfile', () {
    test(
      'returns null before an identity exists, without touching the '
      'manager factory',
      () async {
        var managerFactoryCalls = 0;

        final service = NostrProfileService(
          identityService: _FakeIdentityService(),
          circleManagerFactory: () async {
            managerFactoryCalls++;
            throw UnimplementedError('unreachable: no identity');
          },
        );

        final result = await service.getOwnProfile();

        expect(result, isNull);
        expect(managerFactoryCalls, 0);
      },
    );

    test(
      'surfaces a generic exception (never the raw error) when identity '
      'lookup fails',
      () async {
        final service = NostrProfileService(
          identityService: _FakeIdentityService(throwOnGetIdentity: true),
          circleManagerFactory: () async =>
              throw UnimplementedError('unreachable'),
        );

        await expectLater(
          service.getOwnProfile(),
          throwsA(
            isA<ProfileServiceException>()
                .having((e) => e.message, 'message', 'Failed to load profile')
                .having(
                  (e) => e.message.contains(_fakeHexSecret),
                  'does not contain the fake secret',
                  isFalse,
                ),
          ),
        );
      },
    );
  });

  group('NostrProfileService — redaction (Rule 8)', () {
    test(
      'updateOwnProfile never leaks the underlying error message',
      () async {
        final service = NostrProfileService(
          identityService: _FakeIdentityService(identity: _testIdentity),
          circleManagerFactory: () async =>
              throw Exception('manager open failed: $_fakeHexSecret'),
        );

        await expectLater(
          service.updateOwnProfile(displayName: 'Alex'),
          throwsA(
            isA<ProfileServiceException>()
                .having(
                  (e) => e.message,
                  'message',
                  'Failed to update profile',
                )
                .having(
                  (e) => e.message.contains(_fakeHexSecret),
                  'does not contain the fake secret',
                  isFalse,
                ),
          ),
        );
      },
    );

    test('setOwnAvatar never leaks the underlying error message', () async {
      final service = NostrProfileService(
        identityService: _FakeIdentityService(identity: _testIdentity),
        circleManagerFactory: () async =>
            throw Exception('manager open failed: $_fakeHexSecret'),
      );

      await expectLater(
        service.setOwnAvatar(Uint8List.fromList([1, 2, 3])),
        throwsA(
          isA<ProfileServiceException>()
              .having(
                (e) => e.message,
                'message',
                'Failed to set profile picture',
              )
              .having(
                (e) => e.message.contains(_fakeHexSecret),
                'does not contain the fake secret',
                isFalse,
              ),
        ),
      );
    });
  });
}
