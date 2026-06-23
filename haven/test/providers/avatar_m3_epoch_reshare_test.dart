/// M3 tests: epoch re-share trigger (OwnAvatarController.epochReshareForCircle)
/// and the onGroupUpdated callback in pollEvolutionEvents.
///
/// Verifies:
/// - epochReshareForCircle calls buildAvatarShareEvents + publish in a burst.
/// - epochReshareForCircle skips when no avatar is set.
/// - epochReshareForCircle skips when the circle is not in the accepted list.
/// - A publish failure does NOT throw to the caller.
/// - A buildAvatarShareEvents failure does NOT throw to the caller.
/// - pollEvolutionEvents invokes onGroupUpdated with the correct mlsGroupId
///   when groupUpdated==true for a circle.
/// - pollEvolutionEvents does NOT invoke onGroupUpdated when groupUpdated==false.
/// - onGroupUpdated is invoked once per circle that has groupUpdated==true.
/// - The callback is optional (no error when omitted).
/// - reshareToAllCircles (anti-entropy path) calls buildAvatarShareEvents for
///   every accepted circle.
/// - reshareToAllCircles skips when no avatar is set.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

// ---------------------------------------------------------------------------
// Fake identity service
// ---------------------------------------------------------------------------

class _FakeIdentityService implements IdentityService {
  static const _pubkey =
      'aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234';

  static final _identity = Identity(
    pubkeyHex: _pubkey,
    npub: 'npub1test',
    createdAt: DateTime(2025),
  );

  @override
  Future<bool> hasIdentity() async => true;

  @override
  Future<Identity?> getIdentity() async => _identity;

  @override
  Future<Identity> createIdentity() => throw UnimplementedError();

  @override
  Future<Identity> importFromNsec(String nsec) => throw UnimplementedError();

  @override
  Future<String> exportNsec() => throw UnimplementedError();

  @override
  Future<String> sign(Uint8List messageHash) => throw UnimplementedError();

  @override
  Future<String> getPubkeyHex() async => _pubkey;

  @override
  Future<List<int>> getSecretBytes() => throw UnimplementedError();

  @override
  Future<void> deleteIdentity() async {}

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}
}

// ---------------------------------------------------------------------------
// Relay service that always throws on publishEvent.
// ---------------------------------------------------------------------------

class _FailingRelayService extends MockRelayService {
  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    throw const RelayServiceException('Relay unreachable');
  }
}

// ---------------------------------------------------------------------------
// Relay service that returns distinct event IDs on each fetchGroupMessages
// call.  This prevents the seen-event dedup from marking the second circle's
// event as already-processed.
// ---------------------------------------------------------------------------

class _SequentialRelayService extends MockRelayService {
  int _callIndex = 0;

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) async {
    // Each call gets a unique event ID.
    final id = 'evo${_callIndex++}';
    return ['{"id":"$id","kind":445,"content":"commit"}'];
  }
}

// ---------------------------------------------------------------------------
// Relay service that fails on the N-th publishEvent call.
// ---------------------------------------------------------------------------

class _PartialFailRelayService extends MockRelayService {
  _PartialFailRelayService({required this.failOnCall});

  final int failOnCall;
  int _calls = 0;

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    _calls++;
    if (_calls == failOnCall) {
      throw const RelayServiceException('Relay unreachable');
    }
    return super.publishEvent(eventJson: eventJson, relays: relays);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

final _mlsGroupId1 = [1, 2, 3, 4];
final _mlsGroupId2 = [5, 6, 7, 8];

Circle _makeCircle({
  List<int>? mlsGroupId,
  List<int>? nostrGroupId,
  String name = 'Test',
  MembershipStatus status = MembershipStatus.accepted,
}) {
  return TestCircleFactory.createCircle(
    mlsGroupId: mlsGroupId ?? _mlsGroupId1,
    nostrGroupId: nostrGroupId ?? [9, 10, 11, 12],
    displayName: name,
    membershipStatus: status,
  );
}

ProviderContainer _makeContainer({
  required MockCircleService circleService,
  required MockRelayService relayService,
  List<Circle> circles = const [],
}) {
  return ProviderContainer(
    overrides: [
      identityServiceProvider.overrideWithValue(_FakeIdentityService()),
      circleServiceProvider.overrideWithValue(circleService),
      relayServiceProvider.overrideWithValue(relayService),
      circlesProvider.overrideWith((_) async => circles),
    ],
  );
}

/// Drains the unawaited Future() inside epochReshareForCircle /
/// reshareToAllCircles — two microtask pumps cover the async chain.
Future<void> _drain() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // =========================================================================
  // OwnAvatarController.epochReshareForCircle
  // =========================================================================

  group('OwnAvatarController.epochReshareForCircle', () {
    test(
      'calls buildAvatarShareEvents + publish burst for the target circle',
      () async {
        final circle = _makeCircle(mlsGroupId: _mlsGroupId1);
        final svc = MockCircleService()
          ..avatarThumbnailBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])
          ..buildAvatarShareEventsResult = [
            '{"id":"chunk0","kind":445}',
            '{"id":"chunk1","kind":445}',
          ];
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [circle],
        );
        addTearDown(container.dispose);

        container
            .read(ownAvatarControllerProvider.notifier)
            .epochReshareForCircle(_mlsGroupId1);

        await _drain();

        expect(
          svc.buildAvatarShareEventsCalls,
          hasLength(1),
          reason: 'should call buildAvatarShareEvents once for target circle',
        );
        expect(
          svc.buildAvatarShareEventsCalls.first['mlsGroupId'],
          equals(_mlsGroupId1),
        );
        // Both chunks published back-to-back (burst).
        expect(relay.publishedEvents, hasLength(2));
      },
    );

    test(
      'uses DEC-4 updateIntervalSecs (kLocationPublishMaxInterval + buffer)',
      () async {
        final circle = _makeCircle(mlsGroupId: _mlsGroupId1);
        final svc = MockCircleService()
          ..avatarThumbnailBytes = Uint8List.fromList([0xFF, 0xD8])
          ..buildAvatarShareEventsResult = ['{"id":"chunk0","kind":445}'];
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [circle],
        );
        addTearDown(container.dispose);

        container
            .read(ownAvatarControllerProvider.notifier)
            .epochReshareForCircle(_mlsGroupId1);

        await _drain();

        expect(svc.buildAvatarShareEventsCalls, hasLength(1));
        final intervalSecs =
            svc.buildAvatarShareEventsCalls.first['updateIntervalSecs'];
        // DEC-4: 180 + 18 = 198 (mirrors M2 constant).
        expect(intervalSecs, equals(198));
      },
    );

    test('skips when no avatar is set', () async {
      final circle = _makeCircle(mlsGroupId: _mlsGroupId1);
      final svc = MockCircleService()..avatarThumbnailBytes = null;
      final relay = MockRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
        circles: [circle],
      );
      addTearDown(container.dispose);

      container
          .read(ownAvatarControllerProvider.notifier)
          .epochReshareForCircle(_mlsGroupId1);

      await _drain();

      expect(svc.buildAvatarShareEventsCalls, isEmpty);
      expect(relay.publishedEvents, isEmpty);
    });

    test('skips when circle is pending (not accepted)', () async {
      final pendingCircle = _makeCircle(
        mlsGroupId: _mlsGroupId1,
        status: MembershipStatus.pending,
      );
      final svc = MockCircleService()
        ..avatarThumbnailBytes = Uint8List.fromList([0xFF, 0xD8]);
      final relay = MockRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
        circles: [pendingCircle],
      );
      addTearDown(container.dispose);

      container
          .read(ownAvatarControllerProvider.notifier)
          .epochReshareForCircle(_mlsGroupId1);

      await _drain();

      expect(svc.buildAvatarShareEventsCalls, isEmpty);
      expect(relay.publishedEvents, isEmpty);
    });

    test('skips when circles list is empty', () async {
      final svc = MockCircleService()
        ..avatarThumbnailBytes = Uint8List.fromList([0xFF, 0xD8]);
      final relay = MockRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
        circles: [],
      );
      addTearDown(container.dispose);

      container
          .read(ownAvatarControllerProvider.notifier)
          .epochReshareForCircle(_mlsGroupId1);

      await _drain();

      expect(svc.buildAvatarShareEventsCalls, isEmpty);
      expect(relay.publishedEvents, isEmpty);
    });

    test('publish failure does not throw to the caller', () async {
      final circle = _makeCircle(mlsGroupId: _mlsGroupId1);
      final svc = MockCircleService()
        ..avatarThumbnailBytes = Uint8List.fromList([0xFF, 0xD8])
        ..buildAvatarShareEventsResult = ['{"id":"chunk0","kind":445}'];
      final relay = _FailingRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
        circles: [circle],
      );
      addTearDown(container.dispose);

      await expectLater(
        Future<void>(() async {
          container
              .read(ownAvatarControllerProvider.notifier)
              .epochReshareForCircle(_mlsGroupId1);
          await _drain();
        }),
        completes,
        reason: 'publish failure must never propagate to caller',
      );
    });

    test('buildAvatarShareEvents failure does not throw to the caller', () async {
      final circle = _makeCircle(mlsGroupId: _mlsGroupId1);
      final svc = MockCircleService()
        ..avatarThumbnailBytes = Uint8List.fromList([0xFF, 0xD8])
        ..shouldThrowOnBuildAvatarShareEvents = true;
      final relay = MockRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
        circles: [circle],
      );
      addTearDown(container.dispose);

      await expectLater(
        Future<void>(() async {
          container
              .read(ownAvatarControllerProvider.notifier)
              .epochReshareForCircle(_mlsGroupId1);
          await _drain();
        }),
        completes,
      );
      expect(relay.publishedEvents, isEmpty);
    });

    test('only targets the specific circle (not all circles)', () async {
      final circle1 = _makeCircle(
        mlsGroupId: _mlsGroupId1,
        nostrGroupId: [9, 10, 11, 12],
        name: 'C1',
      );
      final circle2 = _makeCircle(
        mlsGroupId: _mlsGroupId2,
        nostrGroupId: [13, 14, 15, 16],
        name: 'C2',
      );
      final svc = MockCircleService()
        ..avatarThumbnailBytes = Uint8List.fromList([0xFF, 0xD8])
        ..buildAvatarShareEventsResult = ['{"id":"chunk0","kind":445}'];
      final relay = MockRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
        circles: [circle1, circle2],
      );
      addTearDown(container.dispose);

      // Trigger only for circle 1.
      container
          .read(ownAvatarControllerProvider.notifier)
          .epochReshareForCircle(_mlsGroupId1);

      await _drain();

      expect(
        svc.buildAvatarShareEventsCalls,
        hasLength(1),
        reason: 'burst must target only the specified circle',
      );
      expect(
        svc.buildAvatarShareEventsCalls.first['mlsGroupId'],
        equals(_mlsGroupId1),
      );
    });
  });

  // =========================================================================
  // pollEvolutionEvents: onGroupUpdated callback (M3 hook)
  // =========================================================================

  group('pollEvolutionEvents: onGroupUpdated callback', () {
    test(
      'invokes callback with correct mlsGroupId when groupUpdated==true',
      () async {
        final circle = _makeCircle(mlsGroupId: _mlsGroupId1);
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [const DecryptResult(groupUpdated: true)];
        final mockRelay = MockRelayService(
          groupMessages: const ['{"id":"evo1","kind":445,"content":"commit"}'],
        );
        final service = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final updatedIds = <List<int>>[];
        await service.pollEvolutionEvents(
          circles: [circle],
          onGroupUpdated: updatedIds.add,
        );

        expect(updatedIds, hasLength(1));
        expect(updatedIds.first, equals(_mlsGroupId1));
      },
    );

    test(
      'does NOT invoke callback when groupUpdated==false',
      () async {
        final circle = _makeCircle(mlsGroupId: _mlsGroupId1);
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            DecryptResult(
              location: DecryptedLocation(
                senderPubkey: 'peer1',
                latitude: 1,
                longitude: 2,
                geohash: 'u',
                timestamp: DateTime.now(),
                expiresAt: DateTime.now().add(const Duration(hours: 1)),
              ),
            ),
          ];
        final mockRelay = MockRelayService(
          groupMessages: const ['{"id":"loc1","kind":445,"content":"loc"}'],
        );
        final service = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final updatedIds = <List<int>>[];
        await service.pollEvolutionEvents(
          circles: [circle],
          onGroupUpdated: updatedIds.add,
        );

        expect(
          updatedIds,
          isEmpty,
          reason: 'callback must NOT fire for a pure location event',
        );
      },
    );

    test(
      'invokes callback for EACH circle with groupUpdated==true independently',
      () async {
        final circle1 = _makeCircle(
          mlsGroupId: _mlsGroupId1,
          nostrGroupId: [9, 10, 11, 12],
          name: 'C1',
        );
        final circle2 = _makeCircle(
          mlsGroupId: _mlsGroupId2,
          nostrGroupId: [13, 14, 15, 16],
          name: 'C2',
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            const DecryptResult(groupUpdated: true),
            const DecryptResult(groupUpdated: true),
          ];
        // Use _SequentialRelayService so each circle gets a unique event ID —
        // the global seen-event set would otherwise deduplicate the second
        // circle's event and skip the decrypt call.
        final mockRelay = _SequentialRelayService();
        final service = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final updatedIds = <List<int>>[];
        await service.pollEvolutionEvents(
          circles: [circle1, circle2],
          onGroupUpdated: updatedIds.add,
        );

        expect(updatedIds, hasLength(2));
        // Both group IDs must appear.
        final flatIds = updatedIds.map((id) => id.join(',')).toList();
        expect(flatIds, contains(_mlsGroupId1.join(',')));
        expect(flatIds, contains(_mlsGroupId2.join(',')));
      },
    );

    test(
      'fires only for circles where groupUpdated==true (mixed result)',
      () async {
        final circle1 = _makeCircle(
          mlsGroupId: _mlsGroupId1,
          nostrGroupId: [9, 10, 11, 12],
          name: 'C1',
        );
        final circle2 = _makeCircle(
          mlsGroupId: _mlsGroupId2,
          nostrGroupId: [13, 14, 15, 16],
          name: 'C2',
        );
        // circle1 updated, circle2 not updated.
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            const DecryptResult(groupUpdated: true),
            const DecryptResult(),
          ];
        // Unique event IDs per circle to avoid seen-event dedup.
        final mockRelay = _SequentialRelayService();
        final service = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final updatedIds = <List<int>>[];
        await service.pollEvolutionEvents(
          circles: [circle1, circle2],
          onGroupUpdated: updatedIds.add,
        );

        expect(updatedIds, hasLength(1));
        expect(updatedIds.first, equals(_mlsGroupId1));
      },
    );

    test(
      'callback is optional — no error when omitted with groupUpdated==true',
      () async {
        final circle = _makeCircle(mlsGroupId: _mlsGroupId1);
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [const DecryptResult(groupUpdated: true)];
        final mockRelay = MockRelayService(
          groupMessages: const ['{"id":"evo1","kind":445,"content":"commit"}'],
        );
        final service = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        // No callback — must complete without error and return true.
        await expectLater(
          service.pollEvolutionEvents(circles: [circle]),
          completion(isTrue),
        );
      },
    );

    test(
      'does not invoke callback when relay returns no events',
      () async {
        final circle = _makeCircle(mlsGroupId: _mlsGroupId1);
        final mockCircle = MockCircleService();
        final mockRelay = MockRelayService();
        final service = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final updatedIds = <List<int>>[];
        await service.pollEvolutionEvents(
          circles: [circle],
          onGroupUpdated: updatedIds.add,
        );

        expect(updatedIds, isEmpty);
      },
    );
  });

  // =========================================================================
  // OwnAvatarController.reshareToAllCircles (M3 anti-entropy path)
  // =========================================================================

  group('OwnAvatarController.reshareToAllCircles', () {
    test(
      'calls buildAvatarShareEvents for every accepted circle',
      () async {
        final c1 = _makeCircle(
          mlsGroupId: _mlsGroupId1,
          nostrGroupId: [9, 10, 11, 12],
          name: 'C1',
        );
        final c2 = _makeCircle(
          mlsGroupId: _mlsGroupId2,
          nostrGroupId: [13, 14, 15, 16],
          name: 'C2',
        );
        final svc = MockCircleService()
          ..avatarThumbnailBytes = Uint8List.fromList([0xFF, 0xD8])
          ..buildAvatarShareEventsResult = ['{"id":"chunk0","kind":445}'];
        final relay = MockRelayService();

        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [c1, c2],
        );
        addTearDown(container.dispose);

        container
            .read(ownAvatarControllerProvider.notifier)
            .reshareToAllCircles();

        await _drain();

        expect(
          svc.buildAvatarShareEventsCalls,
          hasLength(2),
          reason: 'should publish to every accepted circle',
        );
      },
    );

    test('skips non-accepted (pending) circles', () async {
      final accepted = _makeCircle(
        mlsGroupId: _mlsGroupId1,
      );
      final pending = _makeCircle(
        mlsGroupId: _mlsGroupId2,
        status: MembershipStatus.pending,
        name: 'Pending',
      );
      final svc = MockCircleService()
        ..avatarThumbnailBytes = Uint8List.fromList([0xFF, 0xD8])
        ..buildAvatarShareEventsResult = ['{"id":"chunk0","kind":445}'];
      final relay = MockRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
        circles: [accepted, pending],
      );
      addTearDown(container.dispose);

      container
          .read(ownAvatarControllerProvider.notifier)
          .reshareToAllCircles();

      await _drain();

      expect(
        svc.buildAvatarShareEventsCalls,
        hasLength(1),
        reason: 'pending circle must be skipped',
      );
    });

    test('skips all circles when no avatar is set', () async {
      final c1 = _makeCircle(mlsGroupId: _mlsGroupId1);
      final svc = MockCircleService()..avatarThumbnailBytes = null;
      final relay = MockRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
        circles: [c1],
      );
      addTearDown(container.dispose);

      container
          .read(ownAvatarControllerProvider.notifier)
          .reshareToAllCircles();

      await _drain();

      expect(svc.buildAvatarShareEventsCalls, isEmpty);
      expect(relay.publishedEvents, isEmpty);
    });

    test(
      'publish failure for one circle does not stop other circles',
      () async {
        final c1 = _makeCircle(
          mlsGroupId: _mlsGroupId1,
          nostrGroupId: [9, 10, 11, 12],
          name: 'C1',
        );
        final c2 = _makeCircle(
          mlsGroupId: _mlsGroupId2,
          nostrGroupId: [13, 14, 15, 16],
          name: 'C2',
        );
        // First publish call fails, second succeeds.
        final relay = _PartialFailRelayService(failOnCall: 1);

        final svc = MockCircleService()
          ..avatarThumbnailBytes = Uint8List.fromList([0xFF, 0xD8])
          ..buildAvatarShareEventsResult = ['{"id":"chunk0","kind":445}'];
        final container = _makeContainer(
          circleService: svc,
          relayService: relay,
          circles: [c1, c2],
        );
        addTearDown(container.dispose);

        await expectLater(
          Future<void>(() async {
            container
                .read(ownAvatarControllerProvider.notifier)
                .reshareToAllCircles();
            await _drain();
          }),
          completes,
          reason: 'failure in one circle must not prevent other circles',
        );
        // buildAvatarShareEvents called for both circles regardless of publish
        // failure.
        expect(svc.buildAvatarShareEventsCalls, hasLength(2));
      },
    );

    test('does not throw when all circles fail to publish', () async {
      final c1 = _makeCircle(mlsGroupId: _mlsGroupId1);
      final svc = MockCircleService()
        ..avatarThumbnailBytes = Uint8List.fromList([0xFF, 0xD8])
        ..buildAvatarShareEventsResult = ['{"id":"chunk0","kind":445}'];
      final relay = _FailingRelayService();

      final container = _makeContainer(
        circleService: svc,
        relayService: relay,
        circles: [c1],
      );
      addTearDown(container.dispose);

      await expectLater(
        Future<void>(() async {
          container
              .read(ownAvatarControllerProvider.notifier)
              .reshareToAllCircles();
          await _drain();
        }),
        completes,
      );
    });
  });
}
