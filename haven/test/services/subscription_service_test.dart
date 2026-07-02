import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/subscription_service.dart';

import '../mocks/mock_circle_service.dart';

/// A captured set of router side effects, for assertions.
class _Spy {
  final List<DecryptedLocation> ingested = [];
  final List<Circle> reconciled = [];
  int locationsChanged = 0;
  final List<Circle> groupUpdated = [];
  int invitationReceived = 0;
  final List<FfiSyncStatusReason> statuses = [];
  int secretFetches = 0;
}

Circle _circle({
  required List<int> nostrGroupId,
  List<int> mlsGroupId = const [9, 9, 9],
}) => Circle(
  mlsGroupId: mlsGroupId,
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
  group('LiveEventRouter', () {
    late MockCircleService circleService;
    late _Spy spy;
    late List<Circle> circles;
    // When non-null, the parser returns it; when null, simulates an unparseable
    // payload (avatar chunk / bad content).
    DecryptedLocation? parseResult;

    LiveEventRouter buildRouter() => LiveEventRouter(
      circleService: circleService,
      circlesSnapshot: () async => circles,
      secretBytes: () async {
        spy.secretFetches++;
        return List<int>.filled(32, 7);
      },
      parseLocation: (content, sender) async => parseResult,
      ingestLocation: (circle, decrypted) async => spy.ingested.add(decrypted),
      reconcileRoster: (circle) async => spy.reconciled.add(circle),
      onLocationsChanged: () => spy.locationsChanged++,
      onGroupUpdated: spy.groupUpdated.add,
      onInvitationReceived: () => spy.invitationReceived++,
      onStatus: spy.statuses.add,
    );

    setUp(() {
      circleService = MockCircleService();
      spy = _Spy();
      circles = [
        _circle(nostrGroupId: const [1, 2, 3]),
      ];
      parseResult = _decrypted('peer');
    });

    test('Location event ingests + invalidates when parseable', () async {
      await buildRouter().handleEvent(
        FfiRelayEvent(
          kind: FfiRelayEventKind.location,
          nostrGroupId: Uint8List.fromList(const [1, 2, 3]),
          senderPubkey: 'peer',
          content: '{}',
          eventCreatedAtSecs: 100,
        ),
      );
      expect(spy.ingested.length, 1);
      expect(spy.locationsChanged, 1);
    });

    test('Location with unparseable content does NOT ingest', () async {
      parseResult = null; // avatar chunk / bad content
      await buildRouter().handleEvent(
        FfiRelayEvent(
          kind: FfiRelayEventKind.location,
          nostrGroupId: Uint8List.fromList(const [1, 2, 3]),
          senderPubkey: 'peer',
          content: 'not-a-location',
        ),
      );
      expect(spy.ingested, isEmpty);
      expect(spy.locationsChanged, 0);
    });

    test('Location for an unknown circle is dropped', () async {
      await buildRouter().handleEvent(
        FfiRelayEvent(
          kind: FfiRelayEventKind.location,
          nostrGroupId: Uint8List.fromList(const [9, 9, 9]), // not joined
          senderPubkey: 'peer',
          content: '{}',
        ),
      );
      expect(spy.ingested, isEmpty);
    });

    test('GroupUpdate reconciles the roster + fires onGroupUpdated', () async {
      await buildRouter().handleEvent(
        FfiRelayEvent(
          kind: FfiRelayEventKind.groupUpdate,
          nostrGroupId: Uint8List.fromList(const [1, 2, 3]),
        ),
      );
      expect(spy.reconciled.length, 1);
      expect(spy.groupUpdated.length, 1);
      expect(spy.groupUpdated.single.nostrGroupId, const [1, 2, 3]);
    });

    test('Welcome processes the invitation + advances the cursor', () async {
      await buildRouter().handleEvent(
        const FfiRelayEvent(
          kind: FfiRelayEventKind.welcome,
          giftWrapJson: '{"kind":1059}',
          wrapCreatedAtSecs: 4242,
        ),
      );
      expect(spy.secretFetches, 1);
      expect(
        circleService.methodCalls,
        containsAllInOrder(<String>[
          'processGiftWrappedInvitation',
          'advanceInboxCursorToWrapSecs:4242',
        ]),
      );
      // The mock returns a non-null invitation ⇒ a refresh fires.
      expect(spy.invitationReceived, 1);
    });

    test('Welcome zeroizes the identity secret after use (Rule 9)', () async {
      await buildRouter().handleEvent(
        const FfiRelayEvent(
          kind: FfiRelayEventKind.welcome,
          giftWrapJson: '{"kind":1059}',
          wrapCreatedAtSecs: 4242,
        ),
      );
      // The router copies the (non-zero, 32×7) secret into a Uint8List, passes
      // it to processGiftWrappedInvitation (the mock captures that reference),
      // then scrubs it in a finally.
      final ref = circleService.processGiftWrappedInvitationSecretRef;
      expect(ref, isNotNull);
      expect(ref!.length, 32);
      expect(ref, everyElement(0), reason: 'secret buffer scrubbed after use');
    });

    test('Welcome zeroizes the secret even when processing throws', () async {
      circleService.shouldThrowOnProcessGiftWrappedInvitation = true;
      // handleEvent never rethrows (every side effect is guarded).
      await buildRouter().handleEvent(
        const FfiRelayEvent(
          kind: FfiRelayEventKind.welcome,
          giftWrapJson: '{"kind":1059}',
        ),
      );
      final ref = circleService.processGiftWrappedInvitationSecretRef;
      expect(ref, isNotNull);
      expect(
        ref,
        everyElement(0),
        reason: 'finally scrubs the secret on the error path too',
      );
    });

    test('Status event maps to onStatus', () async {
      await buildRouter().handleEvent(
        const FfiRelayEvent(
          kind: FfiRelayEventKind.status,
          statusReason: FfiSyncStatusReason.connected,
        ),
      );
      expect(spy.statuses, [FfiSyncStatusReason.connected]);
    });

    test('a throwing callback never breaks the router (guarded)', () async {
      final router = LiveEventRouter(
        circleService: circleService,
        circlesSnapshot: () async => circles,
        secretBytes: () async => List<int>.filled(32, 0),
        parseLocation: (c, s) async => _decrypted('peer'),
        ingestLocation: (c, d) async {},
        reconcileRoster: (c) async {},
        onLocationsChanged: () => throw StateError('boom'),
        onGroupUpdated: (_) {},
        onInvitationReceived: () {},
        onStatus: (_) {},
      );
      // Must NOT throw despite the onLocationsChanged throwing.
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
    });
  });
}
