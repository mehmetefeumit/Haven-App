/// Unit tests for [ownProfileProvider] (the read side).
///
/// The mutation side (`OwnProfileController`) was deleted in the
/// profile-latency migration — local saves now go straight through
/// [ProfileService] from the widget layer, and are covered by
/// `test/widgets/identity/display_name_card_test.dart` /
/// `test/widgets/identity/avatar_picker_test.dart`; the sync/publish trigger
/// is covered by `test/providers/profile_sync_provider_test.dart`.
///
/// Verifies:
/// - ownProfileProvider is null before an identity exists.
/// - ownProfileProvider resolves the service's profile when one exists.
/// - ownProfileProvider swallows a service failure and resolves to null
///   (D7 — connectivity must never surface as an error state).
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
}
