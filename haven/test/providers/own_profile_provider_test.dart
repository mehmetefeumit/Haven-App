/// Unit tests for [ownProfileProvider] and [OwnProfileController].
///
/// Verifies:
/// - ownProfileProvider is null before an identity exists.
/// - ownProfileProvider swallows a service failure and resolves to null
///   (D7 — connectivity must never surface as an error state).
/// - saveDisplayName/setAvatar publish UNCONDITIONALLY — no consent gate
///   (public-by-default, owner-directed 2026-07-16) — and invalidate
///   ownProfileProvider on success.
/// - removeAvatar calls the service regardless (retraction-always-allowed,
///   D1).
/// - refresh() forwards forceRefresh: true and invalidates ownProfileProvider.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/own_profile_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/profile_service.dart';

import '../mocks/mock_profile_service.dart';

// ---------------------------------------------------------------------------
// Fake identity service
// ---------------------------------------------------------------------------

class _FakeIdentityService implements IdentityService {
  _FakeIdentityService({this.identity});

  final Identity? identity;

  @override
  Future<bool> hasIdentity() async => identity != null;

  @override
  Future<Identity?> getIdentity() async => identity;

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

final _testIdentity = Identity(
  pubkeyHex:
      'aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234',
  npub: 'npub1test',
  createdAt: DateTime(2025),
);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ProviderContainer _makeContainer({
  required MockProfileService profileService,
  Identity? identity,
}) {
  return ProviderContainer(
    overrides: [
      identityServiceProvider.overrideWithValue(
        _FakeIdentityService(identity: identity),
      ),
      profileServiceProvider.overrideWithValue(profileService),
    ],
  );
}

void main() {
  group('ownProfileProvider', () {
    test('returns null before an identity exists', () async {
      final svc = MockProfileService();
      final container = _makeContainer(profileService: svc);
      addTearDown(container.dispose);

      final result = await container.read(ownProfileProvider.future);

      expect(result, isNull);
      expect(svc.methodCalls, isEmpty);
    });

    test('returns the profile when the service resolves one', () async {
      final profile = Profile(
        pubkeyHex: _testIdentity.pubkeyHex,
        displayName: 'Alex',
      );
      final svc = MockProfileService(ownProfile: profile);
      final container = _makeContainer(
        identity: _testIdentity,
        profileService: svc,
      );
      addTearDown(container.dispose);

      final result = await container.read(ownProfileProvider.future);

      expect(result, equals(profile));
    });

    test('swallows a service failure and resolves to null (D7)', () async {
      final svc = MockProfileService()..shouldThrowOnGetOwnProfile = true;
      final container = _makeContainer(
        identity: _testIdentity,
        profileService: svc,
      );
      addTearDown(container.dispose);

      final result = await container.read(ownProfileProvider.future);

      expect(result, isNull);
    });
  });

  group('OwnProfileController.saveDisplayName', () {
    test(
      'always calls the service and invalidates ownProfileProvider — no '
      'consent gate',
      () async {
        final svc = MockProfileService();
        final container = _makeContainer(
          identity: _testIdentity,
          profileService: svc,
        );
        addTearDown(container.dispose);

        await container
            .read(ownProfileControllerProvider.notifier)
            .saveDisplayName(displayName: 'Alex', about: 'hello');

        expect(
          svc.methodCalls.where((c) => c.method == 'updateOwnProfile'),
          hasLength(1),
          reason:
              'Publishing is unconditional (public-by-default) — there is '
              'no consent flag left to check.',
        );
        final result = await container.read(ownProfileProvider.future);
        expect(result?.displayName, 'Alex');
        expect(result?.about, 'hello');
      },
    );
  });

  group('OwnProfileController.setAvatar', () {
    test(
      'always calls the service and invalidates ownProfileProvider — no '
      'consent gate',
      () async {
        final svc = MockProfileService();
        final container = _makeContainer(
          identity: _testIdentity,
          profileService: svc,
        );
        addTearDown(container.dispose);

        await container
            .read(ownProfileControllerProvider.notifier)
            .setAvatar(Uint8List.fromList([1, 2, 3]));

        expect(
          svc.methodCalls.where((c) => c.method == 'setOwnAvatar'),
          hasLength(1),
        );
        final result = await container.read(ownProfileProvider.future);
        expect(result?.pictureBytes, isNotNull);
      },
    );
  });

  group('OwnProfileController.removeAvatar', () {
    test(
      'calls the service unconditionally (retraction is never gated)',
      () async {
        final svc = MockProfileService(
          ownProfile: Profile(
            pubkeyHex: _testIdentity.pubkeyHex,
            pictureBytes: Uint8List.fromList([9, 9, 9]),
          ),
        );
        final container = _makeContainer(
          identity: _testIdentity,
          profileService: svc,
        );
        addTearDown(container.dispose);

        await container
            .read(ownProfileControllerProvider.notifier)
            .removeAvatar();

        expect(
          svc.methodCalls.where((c) => c.method == 'removeOwnAvatar'),
          hasLength(1),
        );
        final result = await container.read(ownProfileProvider.future);
        expect(result?.pictureBytes, isNull);
      },
    );
  });

  group('OwnProfileController.refresh', () {
    test(
      'force-refreshes and invalidates ownProfileProvider',
      () async {
        final svc = MockProfileService(
          ownProfile: Profile(pubkeyHex: _testIdentity.pubkeyHex),
        );
        final container = _makeContainer(
          identity: _testIdentity,
          profileService: svc,
        );
        addTearDown(container.dispose);

        await container.read(ownProfileControllerProvider.notifier).refresh();

        final refreshCalls = svc.methodCalls.where(
          (c) => c.method == 'getOwnProfile',
        );
        expect(refreshCalls, isNotEmpty);
        expect(refreshCalls.last.args['forceRefresh'], isTrue);
      },
    );
  });
}
