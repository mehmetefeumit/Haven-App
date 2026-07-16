/// Unit tests for [memberProfileProvider].
///
/// Verifies:
/// - Provider is keyed by a plain `String pubkeyHex` (no `mlsGroupId`
///   component, unlike the old `MemberAvatarKey`).
/// - Returns the service's result when one exists.
/// - Returns null when the service returns null (never fetched).
/// - Returns null (swallows, never throws) when the service throws.
/// - Two different pubkeys use independent provider instances.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/profile_service.dart';

import '../mocks/mock_profile_service.dart';

void main() {
  const pubkeyA =
      'aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234';
  const pubkeyB =
      'bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234';

  ProviderContainer makeContainer(MockProfileService svc) {
    return ProviderContainer(
      overrides: [profileServiceProvider.overrideWithValue(svc)],
    );
  }

  test('returns the profile when the service has one cached', () async {
    const profile = Profile(pubkeyHex: pubkeyA, displayName: 'Bo');
    final svc = MockProfileService(memberProfiles: {pubkeyA: profile});
    final container = makeContainer(svc);
    addTearDown(container.dispose);

    final result = await container.read(memberProfileProvider(pubkeyA).future);

    expect(result, equals(profile));
  });

  test('returns null when the service has never resolved the pubkey', () async {
    final svc = MockProfileService();
    final container = makeContainer(svc);
    addTearDown(container.dispose);

    final result = await container.read(memberProfileProvider(pubkeyA).future);

    expect(result, isNull);
    expect(
      svc.methodCalls.where((c) => c.method == 'getMemberProfile'),
      hasLength(1),
    );
  });

  test('returns null (does not throw) when the service throws', () async {
    final svc = MockProfileService()..shouldThrowOnGetMemberProfile = true;
    final container = makeContainer(svc);
    addTearDown(container.dispose);

    final result = await container.read(memberProfileProvider(pubkeyA).future);

    expect(result, isNull);
  });

  test('two different pubkeys use independent provider instances', () async {
    const profileA = Profile(pubkeyHex: pubkeyA, displayName: 'A');
    const profileB = Profile(pubkeyHex: pubkeyB, displayName: 'B');
    final svc = MockProfileService(
      memberProfiles: {pubkeyA: profileA, pubkeyB: profileB},
    );
    final container = makeContainer(svc);
    addTearDown(container.dispose);

    final resultA = await container.read(
      memberProfileProvider(pubkeyA).future,
    );
    final resultB = await container.read(
      memberProfileProvider(pubkeyB).future,
    );

    expect(resultA, equals(profileA));
    expect(resultB, equals(profileB));
    expect(
      svc.methodCalls.where((c) => c.method == 'getMemberProfile'),
      hasLength(2),
    );
  });
}
