/// Tests for [MemberRemovalController] — the decision layer behind the
/// admin "Remove from circle" affordance.
///
/// Everything here runs against a [ProviderContainer] rather than a widget
/// tree: the rules being pinned (one removal at a time, what a failure
/// leaves behind, what a success invalidates) are properties of the
/// controller, and asserting them through a pumped sheet would prove them
/// only for the one layout that happened to be on screen.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/member_removal_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

const _alicePubkey =
    'aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111';
const _bobPubkey =
    'bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222';

/// A circle whose roster still contains Bob — the state the UI is in when
/// the admin taps Remove.
Circle _circleWithBob() => TestCircleFactory.createCircle(
  members: [
    TestCircleFactory.createMember(pubkey: _alicePubkey, isAdmin: true),
    TestCircleFactory.createMember(pubkey: _bobPubkey),
  ],
);

void main() {
  late MockCircleService circleService;
  late LocationSharingService locationService;
  late ProviderContainer container;

  setUp(() {
    circleService = MockCircleService(circles: [_circleWithBob()]);
    locationService = LocationSharingService(
      circleService: circleService,
      relayService: MockRelayService(),
    );
    container = ProviderContainer(
      overrides: [
        circleServiceProvider.overrideWithValue(circleService),
        locationSharingServiceProvider.overrideWithValue(locationService),
      ],
    );
    addTearDown(container.dispose);
  });

  group('MemberRemovalController', () {
    test('starts idle', () {
      expect(container.read(memberRemovalProvider), isNull);
    });

    test('removes the named member from the named circle', () async {
      final circle = _circleWithBob();

      final outcome = await container
          .read(memberRemovalProvider.notifier)
          .remove(circle: circle, memberPubkeyHex: _bobPubkey);

      expect(outcome, MemberRemovalOutcome.removed);
      expect(circleService.removeMemberCalls, hasLength(1));
      expect(
        circleService.removeMemberCalls.single.memberPubkeyHex,
        _bobPubkey,
      );
      expect(
        circleService.removeMemberCalls.single.mlsGroupId,
        circle.mlsGroupId,
        reason: 'a removal aimed at the wrong group would evict a stranger '
            'from a circle the admin was not even looking at',
      );
    });

    test('publishes the pubkey being removed while the work runs', () async {
      final circle = _circleWithBob();
      String? observedWhileRunning;

      // The service call is what the UI renders progress around, so sample
      // the state from inside it rather than after it returns.
      circleService.onRemoveMember = () {
        observedWhileRunning = container.read(memberRemovalProvider);
      };

      await container
          .read(memberRemovalProvider.notifier)
          .remove(circle: circle, memberPubkeyHex: _bobPubkey);

      expect(observedWhileRunning, _bobPubkey);
      expect(
        container.read(memberRemovalProvider),
        isNull,
        reason: 'the in-flight marker must clear once the work is done, or '
            'every remove button in the list stays disabled forever',
      );
    });

    test('clears the in-flight marker when the removal fails', () async {
      circleService.shouldThrowOnRemoveMember = true;

      final outcome = await container
          .read(memberRemovalProvider.notifier)
          .remove(circle: _circleWithBob(), memberPubkeyHex: _bobPubkey);

      expect(outcome, MemberRemovalOutcome.failed);
      expect(container.read(memberRemovalProvider), isNull);
    });

    test('reports failure rather than throwing on a non-Exception error',
        () async {
      // The FFI boundary throws Errors as well as Exceptions; a controller
      // that only caught Exception would take the UI down with it.
      circleService.onRemoveMember = () => throw StateError('ffi blew up');

      final outcome = await container
          .read(memberRemovalProvider.notifier)
          .remove(circle: _circleWithBob(), memberPubkeyHex: _bobPubkey);

      expect(outcome, MemberRemovalOutcome.failed);
    });

    test('refuses a second removal while one is in flight', () async {
      final circle = _circleWithBob();
      final gate = Completer<void>();
      circleService.removeMemberGate = gate.future;

      final first = container
          .read(memberRemovalProvider.notifier)
          .remove(circle: circle, memberPubkeyHex: _bobPubkey);
      // The controller is now busy; a second attempt must not reach the
      // service — two MLS commits staged on one group race, and the loser
      // is rolled back (Security Rule 13).
      final second = await container
          .read(memberRemovalProvider.notifier)
          .remove(circle: circle, memberPubkeyHex: _alicePubkey);

      expect(second, MemberRemovalOutcome.busy);
      expect(circleService.removeMemberCalls, hasLength(1));

      gate.complete();
      expect(await first, MemberRemovalOutcome.removed);
    });

    test("a removal that succeeded forgets that member's location", () async {
      final circle = _circleWithBob();

      await container
          .read(memberRemovalProvider.notifier)
          .remove(circle: circle, memberPubkeyHex: _bobPubkey);

      expect(
        circleService.removeLastKnownMemberCalls, hasLength(1),
        reason: "an admin's own removal never comes back as a decrypt "
            'result, so nothing else prunes the evicted member — their pin '
            'would sit on the map and their stored row would re-hydrate as '
            'one after a restart',
      );
      final pruned = circleService.removeLastKnownMemberCalls.single;
      expect(pruned.senderPubkey, _bobPubkey);
      expect(pruned.nostrGroupId, circle.nostrGroupId);
    });

    test('a location-cleanup failure does not un-report the removal',
        () async {
      // The commit is published, acked and applied by this point. Telling
      // the admin it failed would invite them to remove someone who is
      // already gone.
      circleService.shouldThrowOnRemoveLastKnownMember = true;

      final outcome = await container
          .read(memberRemovalProvider.notifier)
          .remove(circle: _circleWithBob(), memberPubkeyHex: _bobPubkey);

      expect(outcome, MemberRemovalOutcome.removed);
    });

    test('a failed removal leaves the roster and the caches alone', () async {
      circleService.shouldThrowOnRemoveMember = true;

      await container
          .read(memberRemovalProvider.notifier)
          .remove(circle: _circleWithBob(), memberPubkeyHex: _bobPubkey);

      expect(
        circleService.methodCalls,
        isNot(contains('getMembers')),
        reason: 'nothing changed, so re-reading the roster would cost an FFI '
            'round trip to learn nothing — and the error copy tells the user '
            'exactly that',
      );
      expect(
        circleService.methodCalls,
        isNot(contains('removeLastKnownMember')),
      );
    });
  });
}
