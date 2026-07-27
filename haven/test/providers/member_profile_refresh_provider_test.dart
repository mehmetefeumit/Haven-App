/// Unit tests for [MemberProfileRefreshNotifier] and
/// [memberProfileRefreshProvider].
///
/// Verifies:
/// - refreshRoster forwards the pubkey list and staleness tier to the service.
/// - refreshRoster invalidates the memberProfileProvider family on success
///   (a previously-read member's provider is re-fetched).
/// - refreshRoster is a no-op for an empty pubkey list.
/// - refreshRoster swallows service failures (never throws to the caller).
/// - Concurrent triggers coalesce into one fetch plus at most one follow-up,
///   keeping the strictest pending tier.
/// - refreshAll builds the all-circles union plus the own pubkey (§1.7).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/profile_refresh_tiers.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/providers/member_profile_refresh_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/profile_service.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_profile_service.dart';

void main() {
  const pubkeyA =
      'aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234';
  const pubkeyB =
      'bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234';

  final testIdentity = Identity(
    pubkeyHex:
        'dddd1234dddd1234dddd1234dddd1234dddd1234dddd1234dddd1234dddd1234',
    npub: 'npub1test',
    createdAt: DateTime(2024),
  );

  ProviderContainer makeContainer(MockProfileService svc) {
    return ProviderContainer(
      overrides: [profileServiceProvider.overrideWithValue(svc)],
    );
  }

  test('refreshRoster forwards the pubkey list and staleness tier', () async {
    final svc = MockProfileService();
    final container = makeContainer(svc);
    addTearDown(container.dispose);

    container
        .read(memberProfileRefreshProvider.notifier)
        .refreshRoster([pubkeyA, pubkeyB], maxAge: profileForceMaxAge);

    // Allow the unawaited fire-and-forget Future() to drain.
    await Future<void>.delayed(Duration.zero);

    final calls = svc.methodCalls.where(
      (c) => c.method == 'refreshMemberProfiles',
    );
    expect(calls, hasLength(1));
    expect(calls.single.args['pubkeyHexes'], equals([pubkeyA, pubkeyB]));
    expect(calls.single.args['maxAge'], equals(Duration.zero));
  });

  test('refreshRoster defaults to the interactive tier', () async {
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
    expect(calls.single.args['maxAge'], equals(profileInteractiveMaxAge));
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

  group('concurrency coalescing', () {
    /// Drains pending microtasks so fire-and-forget work settles. Deterministic
    /// — no wall-clock waiting, so these cannot flake under parallel load.
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    int refreshes(MockProfileService svc) =>
        svc.methodCalls
            .where((c) => c.method == 'refreshMemberProfiles')
            .length;

    test('a trigger landing on an in-flight batch does not double-fetch',
        () async {
      // Two triggers overlapping (e.g. a circle select on top of an
      // anti-entropy tick) must not each open their own relay round trip.
      final gate = Completer<void>();
      final svc = MockProfileService()..refreshGate = gate;
      final container = makeContainer(svc);
      addTearDown(container.dispose);

      container.read(memberProfileRefreshProvider.notifier)
        ..refreshRoster([pubkeyA])
        ..refreshRoster([pubkeyA]);
      await settle();

      expect(
        refreshes(svc),
        1,
        reason: 'second trigger must queue, not start a parallel fetch',
      );

      gate.complete();
      await settle();
      // One in-flight + exactly one coalesced follow-up.
      expect(refreshes(svc), 2);
    });

    test('many overlapping triggers collapse to one follow-up', () async {
      final gate = Completer<void>();
      final svc = MockProfileService()..refreshGate = gate;
      final container = makeContainer(svc);
      addTearDown(container.dispose);

      container.read(memberProfileRefreshProvider.notifier)
        ..refreshRoster([pubkeyA])
        ..refreshRoster([pubkeyA])
        ..refreshRoster([pubkeyA])
        ..refreshRoster([pubkeyA]);
      await settle();
      expect(refreshes(svc), 1);

      gate.complete();
      await settle();
      expect(
        refreshes(svc),
        2,
        reason: 'queued requests coalesce into a single follow-up',
      );
    });

    test('a member discovered mid-flight is NOT dropped by the follow-up',
        () async {
      // The canonical case the roster-change trigger exists for: someone joins
      // (or an invite is accepted) while an anti-entropy sweep built from the
      // pre-join roster is still in flight. If the follow-up replayed the
      // in-flight batch's list, the new member would be invisible until an
      // unrelated trigger fired — up to ~56 min later.
      final gate = Completer<void>();
      final svc = MockProfileService()..refreshGate = gate;
      final container = makeContainer(svc);
      addTearDown(container.dispose);

      container.read(memberProfileRefreshProvider.notifier)
        ..refreshRoster([pubkeyA])
        ..refreshRoster([pubkeyA, pubkeyB]);
      await settle();

      gate.complete();
      await settle();

      final calls = svc.methodCalls
          .where((c) => c.method == 'refreshMemberProfiles')
          .toList();
      expect(calls, hasLength(2));
      expect(
        calls.last.args['pubkeyHexes'],
        containsAll(<String>[pubkeyA, pubkeyB]),
        reason: 'the follow-up must cover the roster the queued call asked for',
      );
    });

    test('the queued roster merges across several coalesced calls', () async {
      const pubkeyE =
          'eeee1234eeee1234eeee1234eeee1234eeee1234eeee1234eeee1234eeee1234';
      final gate = Completer<void>();
      final svc = MockProfileService()..refreshGate = gate;
      final container = makeContainer(svc);
      addTearDown(container.dispose);

      container.read(memberProfileRefreshProvider.notifier)
        ..refreshRoster([pubkeyA])
        ..refreshRoster([pubkeyB])
        ..refreshRoster([pubkeyE]);
      await settle();

      gate.complete();
      await settle();

      final calls = svc.methodCalls
          .where((c) => c.method == 'refreshMemberProfiles')
          .toList();
      expect(calls, hasLength(2));
      expect(
        calls.last.args['pubkeyHexes'],
        containsAll(<String>[pubkeyB, pubkeyE]),
        reason: 'no coalesced request may lose its members',
      );
    });

    test('a queued force is not downgraded by a lazier in-flight sweep',
        () async {
      // The regression that matters: a user pressing refresh while a periodic
      // sweep runs must still get a forced fetch, not have it swallowed.
      final gate = Completer<void>();
      final svc = MockProfileService()..refreshGate = gate;
      final container = makeContainer(svc);
      addTearDown(container.dispose);

      container.read(memberProfileRefreshProvider.notifier)
        ..refreshRoster([pubkeyA], maxAge: profilePeriodicMaxAge)
        ..refreshRoster([pubkeyA], maxAge: profileForceMaxAge);
      await settle();

      gate.complete();
      await settle();

      final calls = svc.methodCalls
          .where((c) => c.method == 'refreshMemberProfiles')
          .toList();
      expect(calls, hasLength(2));
      expect(calls.first.args['maxAge'], equals(profilePeriodicMaxAge));
      expect(
        calls.last.args['maxAge'],
        equals(Duration.zero),
        reason: 'the strictest pending tier must win',
      );
    });

    test('a failing batch still drains the queue (no retry backlog)', () async {
      final gate = Completer<void>();
      final svc = MockProfileService()
        ..refreshGate = gate
        ..shouldThrowOnRefreshMemberProfiles = true;
      final container = makeContainer(svc);
      addTearDown(container.dispose);

      container.read(memberProfileRefreshProvider.notifier)
        ..refreshRoster([pubkeyA])
        ..refreshRoster([pubkeyA]);
      await settle();

      gate.complete();
      await settle();
      expect(
        refreshes(svc),
        2,
        reason: 'a wedged relay must not build up a backlog of retries',
      );
    });
  });

  group('refreshAll union (migration plan §1.7)', () {
    const pubkeyC =
        'cccc1234cccc1234cccc1234cccc1234cccc1234cccc1234cccc1234cccc1234';

    ProviderContainer makeUnionContainer(
      MockProfileService svc,
      List<Circle> circles,
    ) {
      return ProviderContainer(
        overrides: [
          profileServiceProvider.overrideWithValue(svc),
          circleServiceProvider.overrideWithValue(
            MockCircleService(circles: circles),
          ),
          identityProvider.overrideWith((ref) async => testIdentity),
        ],
      );
    }

    test(
      'refreshes the union of EVERY circle, never a per-circle partition',
      () async {
        // The privacy invariant: a per-circle refresh would hand the relay an
        // exact co-membership cluster. Selecting one circle must still request
        // every circle's members in a single batch.
        final svc = MockProfileService();
        final container = makeUnionContainer(svc, [
          TestCircleFactory.createCircle(
            mlsGroupId: const [1],
            members: [TestCircleFactory.createMember(pubkey: pubkeyA)],
          ),
          TestCircleFactory.createCircle(
            mlsGroupId: const [2],
            members: [TestCircleFactory.createMember(pubkey: pubkeyB)],
          ),
        ]);
        addTearDown(container.dispose);

        await container
            .read(memberProfileRefreshProvider.notifier)
            .refreshAll(maxAge: profileInteractiveMaxAge);
        await Future<void>.delayed(Duration.zero);

        final calls = svc.methodCalls.where(
          (c) => c.method == 'refreshMemberProfiles',
        );
        expect(
          calls,
          hasLength(1),
          reason: 'one batched request, not per-circle',
        );
        final sent = calls.single.args['pubkeyHexes']! as List<String>;
        expect(sent, containsAll(<String>[pubkeyA, pubkeyB]));
      },
    );

    test('includes the own pubkey in the same batch', () async {
      // Own profile rides the roster batch instead of a second forced
      // fetch_my_profile, so a refresh is one relay round trip, not two.
      final svc = MockProfileService();
      final container = makeUnionContainer(svc, [
        TestCircleFactory.createCircle(
          members: [TestCircleFactory.createMember(pubkey: pubkeyC)],
        ),
      ]);
      addTearDown(container.dispose);

      await container
          .read(memberProfileRefreshProvider.notifier)
          .refreshAll(maxAge: profileInteractiveMaxAge);
      await Future<void>.delayed(Duration.zero);

      final sent =
          svc.methodCalls
                  .firstWhere((c) => c.method == 'refreshMemberProfiles')
                  .args['pubkeyHexes']!
              as List<String>;
      expect(sent, contains(testIdentity.pubkeyHex));
      expect(sent, contains(pubkeyC));
    });

    test('de-duplicates a member shared by two circles', () async {
      final svc = MockProfileService();
      final container = makeUnionContainer(svc, [
        TestCircleFactory.createCircle(
          mlsGroupId: const [1],
          members: [TestCircleFactory.createMember(pubkey: pubkeyA)],
        ),
        TestCircleFactory.createCircle(
          mlsGroupId: const [2],
          members: [TestCircleFactory.createMember(pubkey: pubkeyA)],
        ),
      ]);
      addTearDown(container.dispose);

      await container
          .read(memberProfileRefreshProvider.notifier)
          .refreshAll(maxAge: profileInteractiveMaxAge);
      await Future<void>.delayed(Duration.zero);

      final sent =
          svc.methodCalls
                  .firstWhere((c) => c.method == 'refreshMemberProfiles')
                  .args['pubkeyHexes']!
              as List<String>;
      expect(sent.where((p) => p == pubkeyA), hasLength(1));
    });
  });

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
