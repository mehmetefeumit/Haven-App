/// Unit tests for [memberProfileProvider].
///
/// Verifies:
/// - Provider is keyed by a plain `String pubkeyHex` (no `mlsGroupId`
///   component, unlike the old `MemberAvatarKey`).
/// - Returns the service's result when one exists, and null when the
///   service has never resolved the pubkey.
/// - A failed read is an error, never `null` data: a failed first read has
///   no value, and a failed re-read keeps the last-known name and picture.
/// - A member no row shows any more keeps its value until a logout or login
///   releases it.
/// - The failure log names the error's type only.
/// - Two different pubkeys use independent provider instances.
///
/// The re-read at the next session open is in
/// `member_profile_provider_session_open_test.dart`.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/identity_scope.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/profile_service.dart';

import '../helpers/log_capture.dart';
import '../mocks/mock_profile_service.dart';

/// A service whose member read fails with an error that names the member,
/// as a careless FFI error string might.
class _NamingFailureService extends MockProfileService {
  @override
  Future<Profile?> getMemberProfile(
    String pubkeyHex, {
    bool forceRefresh = false,
  }) async => throw StateError('no profile row for $pubkeyHex');
}

void main() {
  const pubkeyA =
      'aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234';
  const pubkeyB =
      'bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234';
  final picture = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);

  ProviderContainer makeContainer(ProfileService svc) {
    final container = ProviderContainer(
      overrides: [profileServiceProvider.overrideWithValue(svc)],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Lets an invalidated, listened member rebuild and its read settle.
  Future<void> settle(ProviderContainer container) async {
    await container.pump();
    await pumpEventQueue();
  }

  test('returns the profile when the service has one cached', () async {
    const profile = Profile(pubkeyHex: pubkeyA, displayName: 'Bo');
    final svc = MockProfileService(memberProfiles: {pubkeyA: profile});
    final container = makeContainer(svc);

    final result = await container.read(memberProfileProvider(pubkeyA).future);

    expect(result, equals(profile));
  });

  test('returns null when the service has never resolved the pubkey', () async {
    final svc = MockProfileService();
    final container = makeContainer(svc);

    final result = await container.read(memberProfileProvider(pubkeyA).future);

    expect(result, isNull);
    expect(
      svc.methodCalls.where((c) => c.method == 'getMemberProfile'),
      hasLength(1),
    );
  });

  test('a failed first read is an error with no value', () async {
    final svc = MockProfileService()..shouldThrowOnGetMemberProfile = true;
    final container = makeContainer(svc)
      ..listen(memberProfileProvider(pubkeyA), (_, _) {});
    await settle(container);

    final state = container.read(memberProfileProvider(pubkeyA));
    expect(state.error, isA<ProfileServiceException>());
    expect(
      state.valueOrNull,
      isNull,
      reason: 'consumers read valueOrNull, so they degrade to the fallback',
    );
  });

  test(
    'a failed re-read keeps the previous name and thumbnail bytes',
    () async {
      final profile = Profile(
        pubkeyHex: pubkeyA,
        displayName: 'Bo',
        pictureBytes: picture,
        pictureHash: 'hash',
      );
      final svc = MockProfileService(memberProfiles: {pubkeyA: profile});
      final container = makeContainer(svc)
        ..listen(memberProfileProvider(pubkeyA), (_, _) {});
      await container.read(memberProfileProvider(pubkeyA).future);

      // What a batch refresh does while the session is unreadable.
      svc.shouldThrowOnGetMemberProfile = true;
      container.invalidate(memberProfileProvider);
      await settle(container);

      final state = container.read(memberProfileProvider(pubkeyA));
      expect(
        svc.methodCalls.where((c) => c.method == 'getMemberProfile'),
        hasLength(2),
        reason: 'premise: the refresh did read again',
      );
      expect(state.error, isA<ProfileServiceException>());
      expect(state.valueOrNull?.displayName, 'Bo');
      expect(state.valueOrNull?.pictureBytes, picture);
    },
  );

  test(
    'a member no row shows any more keeps its value through a failing refresh',
    () async {
      final profile = Profile(
        pubkeyHex: pubkeyA,
        displayName: 'Bo',
        pictureBytes: picture,
        pictureHash: 'hash',
      );
      final svc = MockProfileService(memberProfiles: {pubkeyA: profile});
      final container = makeContainer(svc);
      final row = container.listen(memberProfileProvider(pubkeyA), (_, _) {});
      await container.read(memberProfileProvider(pubkeyA).future);

      // The row leaves the tree (a sheet closes, a lazy list scrolls).
      row.close();
      await settle(container);
      svc.shouldThrowOnGetMemberProfile = true;
      container.invalidate(memberProfileProvider);
      await settle(container);

      // The row comes back: its first frame already has the name and photo.
      final remounted = container.listen(
        memberProfileProvider(pubkeyA),
        (_, _) {},
      );
      expect(
        svc.methodCalls.where((c) => c.method == 'getMemberProfile'),
        hasLength(2),
        reason: 'premise: the refresh read it again, and that read failed',
      );
      expect(remounted.read().error, isA<ProfileServiceException>());
      expect(remounted.read().valueOrNull?.displayName, 'Bo');
      expect(remounted.read().valueOrNull?.pictureBytes, picture);
    },
  );

  test('a logout or login drops every kept member profile', () async {
    const profile = Profile(pubkeyHex: pubkeyA, displayName: 'Bo');
    final svc = MockProfileService(memberProfiles: {pubkeyA: profile});
    final container = makeContainer(svc);
    container.listen(memberProfileProvider(pubkeyA), (_, _) {}).close();
    await container.read(memberProfileProvider(pubkeyA).future);
    await settle(container);
    expect(
      container.exists(memberProfileProvider(pubkeyA)),
      isTrue,
      reason: 'premise: kept while no row shows it',
    );

    identityScopedProviders.forEach(container.invalidate);
    await settle(container);

    expect(container.exists(memberProfileProvider(pubkeyA)), isFalse);
    // A logged-out read fails closed; nothing of the old value survives it.
    svc.shouldThrowOnGetMemberProfile = true;
    container.listen(memberProfileProvider(pubkeyA), (_, _) {});
    await settle(container);
    final state = container.read(memberProfileProvider(pubkeyA));
    expect(state.error, isA<ProfileServiceException>());
    expect(state.valueOrNull, isNull);
  });

  test(
    'a failed read logs its type and nothing that names the member',
    () async {
      final logs = LogCapture.install();
      final container = makeContainer(_NamingFailureService())
        ..listen(memberProfileProvider(pubkeyA), (_, _) {});
      await settle(container);

      logs
        ..assertContains('[Profile] memberProfileProvider: StateError')
        ..assertNoNeedles([pubkeyA]);
    },
  );

  test('two different pubkeys use independent provider instances', () async {
    const profileA = Profile(pubkeyHex: pubkeyA, displayName: 'A');
    const profileB = Profile(pubkeyHex: pubkeyB, displayName: 'B');
    final svc = MockProfileService(
      memberProfiles: {pubkeyA: profileA, pubkeyB: profileB},
    );
    final container = makeContainer(svc);

    final resultA = await container.read(memberProfileProvider(pubkeyA).future);
    final resultB = await container.read(memberProfileProvider(pubkeyB).future);

    expect(resultA, equals(profileA));
    expect(resultB, equals(profileB));
    expect(
      svc.methodCalls.where((c) => c.method == 'getMemberProfile'),
      hasLength(2),
    );
  });
}
