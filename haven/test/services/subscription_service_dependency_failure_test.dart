/// Tests the [LiveEventRouter] promise documented on the class itself:
///
/// > Every side effect is individually `try/on Object catch`-guarded so one
/// > bad event (an invalidation throw, an unparseable payload) can never
/// > break the stream loop.
///
/// `subscription_service_test.dart` already proves this for
/// `onLocationsChanged` throwing. This file proves it for the router's
/// OTHER injected
/// dependencies: a failing `circlesSnapshot` (used to resolve the circle for
/// both Location and GroupUpdate events), a `parseLocation` that throws
/// (rather than returning null), a failing `reconcileRoster`, a failing
/// `onGroupUpdated`, and a failing `onStatus`.
///
/// The guards are independent per side effect, not just "the whole handler is
/// wrapped once" — `_handleGroupUpdate` runs `reconcileRoster` and
/// `onGroupUpdated` under SEPARATE try/catch blocks, so a failure in one must
/// not suppress the other. That independence is the behavior under test in
/// the GroupUpdate cases below, not merely "handleEvent didn't throw".
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/subscription_service.dart';

/// None of the scenarios below fire a Welcome event, so the router should
/// never touch its [CircleService]. `noSuchMethod` makes an unexpected call
/// fail the test loudly (an [UnimplementedError]) instead of silently
/// returning a mock default — mirrors the `_FakeEngine` convention in
/// `nostr_subscription_service_test.dart`.
class _UnusedCircleService implements CircleService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

Circle _circle(List<int> nostrGroupId) => Circle(
  mlsGroupId: const [9, 9, 9],
  nostrGroupId: nostrGroupId,
  displayName: 'Test',
  circleType: CircleType.locationSharing,
  relays: const ['wss://relay.test'],
  membershipStatus: MembershipStatus.accepted,
  members: const [],
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

DecryptedLocation _decrypted(String sender) => DecryptedLocation(
  senderPubkey: sender,
  latitude: 1,
  longitude: 2,
  geohash: 'g',
  timestamp: DateTime(2026),
  expiresAt: DateTime(2026, 1, 1, 1),
);

void main() {
  group(
    'LiveEventRouter — every injected dependency is independently guarded',
    () {
    test(
      'a circlesSnapshot failure drops a Location event instead of throwing',
      () async {
        var ingestCalls = 0;
        var locationsChangedCalls = 0;
        final router = LiveEventRouter(
          circleService: _UnusedCircleService(),
          circlesSnapshot: () async => throw StateError('storage unavailable'),
          secretBytes: () async => const [],
          parseLocation: (content, sender) async => _decrypted(sender),
          ingestLocation: (circle, decrypted) async => ingestCalls++,
          reconcileRoster: (circle) async {},
          onLocationsChanged: () => locationsChangedCalls++,
          onGroupUpdated: (_) {},
          onInvitationReceived: () {},
          onStatus: (_) {},
        );

        await expectLater(
          router.handleEvent(
            FfiRelayEvent(
              kind: FfiRelayEventKind.location,
              nostrGroupId: Uint8List.fromList(const [1, 2, 3]),
              senderPubkey: 'peer',
              content: '{}',
            ),
          ),
          completes,
        );
        expect(
          ingestCalls,
          0,
          reason: 'circle resolution failed — there is nothing to ingest into',
        );
        expect(locationsChangedCalls, 0);
      },
    );

    test(
      'a circlesSnapshot failure drops a GroupUpdate event instead of throwing',
      () async {
        var reconcileCalls = 0;
        var groupUpdatedCalls = 0;
        final router = LiveEventRouter(
          circleService: _UnusedCircleService(),
          circlesSnapshot: () async => throw StateError('storage unavailable'),
          secretBytes: () async => const [],
          parseLocation: (content, sender) async => null,
          ingestLocation: (circle, decrypted) async {},
          reconcileRoster: (circle) async => reconcileCalls++,
          onLocationsChanged: () {},
          onGroupUpdated: (_) => groupUpdatedCalls++,
          onInvitationReceived: () {},
          onStatus: (_) {},
        );

        await expectLater(
          router.handleEvent(
            FfiRelayEvent(
              kind: FfiRelayEventKind.groupUpdate,
              nostrGroupId: Uint8List.fromList(const [1, 2, 3]),
            ),
          ),
          completes,
        );
        expect(
          reconcileCalls,
          0,
          reason: 'circle resolution failed — nothing to reconcile',
        );
        expect(groupUpdatedCalls, 0);
      },
    );

    test(
      'a parseLocation failure (throw, not null) drops the event instead of '
      'throwing',
      () async {
        var ingestCalls = 0;
        var locationsChangedCalls = 0;
        final router = LiveEventRouter(
          circleService: _UnusedCircleService(),
          circlesSnapshot: () async => [_circle(const [1, 2, 3])],
          secretBytes: () async => const [],
          parseLocation: (content, sender) async =>
              throw const FormatException('malformed payload'),
          ingestLocation: (circle, decrypted) async => ingestCalls++,
          reconcileRoster: (circle) async {},
          onLocationsChanged: () => locationsChangedCalls++,
          onGroupUpdated: (_) {},
          onInvitationReceived: () {},
          onStatus: (_) {},
        );

        await expectLater(
          router.handleEvent(
            FfiRelayEvent(
              kind: FfiRelayEventKind.location,
              nostrGroupId: Uint8List.fromList(const [1, 2, 3]),
              senderPubkey: 'peer',
              content: 'garbage',
            ),
          ),
          completes,
        );
        expect(ingestCalls, 0);
        expect(locationsChangedCalls, 0);
      },
    );

    test(
      'a reconcileRoster failure does NOT suppress onGroupUpdated — the map '
      'still refreshes even though roster reconciliation failed',
      () async {
        var groupUpdatedCalls = 0;
        final router = LiveEventRouter(
          circleService: _UnusedCircleService(),
          circlesSnapshot: () async => [_circle(const [1, 2, 3])],
          secretBytes: () async => const [],
          parseLocation: (content, sender) async => null,
          ingestLocation: (circle, decrypted) async {},
          reconcileRoster: (circle) async =>
              throw StateError('roster reconcile boom'),
          onLocationsChanged: () {},
          onGroupUpdated: (_) => groupUpdatedCalls++,
          onInvitationReceived: () {},
          onStatus: (_) {},
        );

        await expectLater(
          router.handleEvent(
            FfiRelayEvent(
              kind: FfiRelayEventKind.groupUpdate,
              nostrGroupId: Uint8List.fromList(const [1, 2, 3]),
            ),
          ),
          completes,
        );
        expect(
          groupUpdatedCalls,
          1,
          reason:
              'onGroupUpdated is guarded independently of reconcileRoster '
              'and must still fire',
        );
      },
    );

    test(
      'an onGroupUpdated failure does not propagate out of handleEvent',
      () async {
        var reconcileCalls = 0;
        final router = LiveEventRouter(
          circleService: _UnusedCircleService(),
          circlesSnapshot: () async => [_circle(const [1, 2, 3])],
          secretBytes: () async => const [],
          parseLocation: (content, sender) async => null,
          ingestLocation: (circle, decrypted) async {},
          reconcileRoster: (circle) async => reconcileCalls++,
          onLocationsChanged: () {},
          onGroupUpdated: (_) => throw StateError('onGroupUpdated boom'),
          onInvitationReceived: () {},
          onStatus: (_) {},
        );

        await expectLater(
          router.handleEvent(
            FfiRelayEvent(
              kind: FfiRelayEventKind.groupUpdate,
              nostrGroupId: Uint8List.fromList(const [1, 2, 3]),
            ),
          ),
          completes,
        );
        expect(
          reconcileCalls,
          1,
          reason: 'reconcileRoster runs under its own, separate guard',
        );
      },
    );

    test('an onStatus failure does not propagate out of handleEvent', () async {
      final router = LiveEventRouter(
        circleService: _UnusedCircleService(),
        circlesSnapshot: () async => const [],
        secretBytes: () async => const [],
        parseLocation: (content, sender) async => null,
        ingestLocation: (circle, decrypted) async {},
        reconcileRoster: (circle) async {},
        onLocationsChanged: () {},
        onGroupUpdated: (_) {},
        onInvitationReceived: () {},
        onStatus: (_) => throw StateError('onStatus boom'),
      );

      await expectLater(
        router.handleEvent(
          const FfiRelayEvent(
            kind: FfiRelayEventKind.status,
            statusReason: FfiSyncStatusReason.connected,
          ),
        ),
        completes,
      );
    });
    },
  );
}
