/// Unit tests for [MemberProfileRefreshNotifier] and
/// [memberProfileRefreshProvider].
///
/// Verifies:
/// - refreshRoster forwards the pubkey list and force flag to the service.
/// - refreshRoster invalidates the memberProfileProvider family on success
///   (a previously-read member's provider is re-fetched).
/// - refreshRoster is a no-op for an empty pubkey list.
/// - refreshRoster swallows service failures (never throws to the caller).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/providers/member_profile_refresh_provider.dart';
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

  test('refreshRoster forwards the pubkey list and force flag', () async {
    final svc = MockProfileService();
    final container = makeContainer(svc);
    addTearDown(container.dispose);

    container
        .read(memberProfileRefreshProvider.notifier)
        .refreshRoster([pubkeyA, pubkeyB], force: true);

    // Allow the unawaited fire-and-forget Future() to drain.
    await Future<void>.delayed(Duration.zero);

    final calls = svc.methodCalls.where(
      (c) => c.method == 'refreshMemberProfiles',
    );
    expect(calls, hasLength(1));
    expect(calls.single.args['pubkeyHexes'], equals([pubkeyA, pubkeyB]));
    expect(calls.single.args['force'], isTrue);
  });

  test('refreshRoster defaults force to false', () async {
    final svc = MockProfileService();
    final container = makeContainer(svc);
    addTearDown(container.dispose);

    container
        .read(memberProfileRefreshProvider.notifier)
        .refreshRoster([pubkeyA]);
    await Future<void>.delayed(Duration.zero);

    final calls = svc.methodCalls.where(
      (c) => c.method == 'refreshMemberProfiles',
    );
    expect(calls.single.args['force'], isFalse);
  });

  test('is a no-op for an empty pubkey list', () async {
    final svc = MockProfileService();
    final container = makeContainer(svc);
    addTearDown(container.dispose);

    container.read(memberProfileRefreshProvider.notifier).refreshRoster([]);
    await Future<void>.delayed(Duration.zero);

    expect(svc.methodCalls, isEmpty);
  });

  test(
    'invalidates the memberProfileProvider family so a previously-read '
    'member re-fetches',
    () async {
      const initial = Profile(pubkeyHex: pubkeyA, displayName: 'Before');
      final svc = MockProfileService(memberProfiles: {pubkeyA: initial});
      final container = makeContainer(svc);
      addTearDown(container.dispose);

      // Keep the family member actively listened so invalidation causes an
      // eager re-fetch rather than just disposing the (unwatched) provider.
      final sub = container.listen(
        memberProfileProvider(pubkeyA),
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);

      final before = await container.read(
        memberProfileProvider(pubkeyA).future,
      );
      expect(before?.displayName, 'Before');

      // Simulate the service resolving a fresher value on the next fetch.
      svc.memberProfiles[pubkeyA] = const Profile(
        pubkeyHex: pubkeyA,
        displayName: 'After',
      );

      container
          .read(memberProfileRefreshProvider.notifier)
          .refreshRoster([pubkeyA]);
      await Future<void>.delayed(Duration.zero);

      final after = await container.read(
        memberProfileProvider(pubkeyA).future,
      );
      expect(after?.displayName, 'After');
    },
  );

  test('swallows service failures without throwing', () async {
    final svc = MockProfileService()..shouldThrowOnRefreshMemberProfiles = true;
    final container = makeContainer(svc);
    addTearDown(container.dispose);

    // Must not throw — the caller only asserts this does not blow up.
    expect(
      () => container
          .read(memberProfileRefreshProvider.notifier)
          .refreshRoster([pubkeyA]),
      returnsNormally,
    );
    await Future<void>.delayed(Duration.zero);
  });
}
