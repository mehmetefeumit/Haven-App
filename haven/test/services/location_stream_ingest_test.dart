import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

DecryptedLocation _loc(String sender, {double lat = 1, double lon = 2}) {
  // Time-relative so the fixture never expires with the wall clock: the cache
  // evicts entries past `expiresAt` + grace, so a hardcoded date would silently
  // empty the cache once that date rolls into the past.
  final now = DateTime.now();
  return DecryptedLocation(
    senderPubkey: sender,
    latitude: lat,
    longitude: lon,
    geohash: 'g',
    timestamp: now,
    expiresAt: now.add(const Duration(hours: 1)),
  );
}

void main() {
  group('LocationSharingService stream ingest (M6-3)', () {
    late MockCircleService circleService;
    late MockRelayService relayService;
    late LocationSharingService service;
    late Circle circle;

    setUp(() {
      circleService = MockCircleService();
      relayService = MockRelayService();
      service = LocationSharingService(
        circleService: circleService,
        relayService: relayService,
      );
      circle = TestCircleFactory.createCircle(
        nostrGroupId: const [1, 2, 3],
        mlsGroupId: const [9, 9, 9],
      );
    });

    test(
      'ingestStreamedLocation persists + surfaces via cachedLocations',
      () async {
        await service.ingestStreamedLocation(
          circle: circle,
          decrypted: _loc('peerA'),
        );
        expect(circleService.methodCalls, contains('upsertLastKnownLocation'));
        final cached = await service.cachedLocations(circle);
        expect(cached.map((m) => m.pubkey), contains('peerA'));
      },
    );

    test('cachedLocations reads the cache WITHOUT a relay poll', () async {
      await service.ingestStreamedLocation(
        circle: circle,
        decrypted: _loc('peerA'),
      );
      relayService.methodCalls.clear();
      final cached = await service.cachedLocations(circle);
      expect(cached, hasLength(1));
      // No relay round-trip — the engine already delivered the location.
      expect(relayService.methodCalls, isEmpty);
    });

    test('reconcileRoster evicts a member not in the MLS roster', () async {
      await service.ingestStreamedLocation(
        circle: circle,
        decrypted: _loc('peerA'),
      );
      await service.ingestStreamedLocation(
        circle: circle,
        decrypted: _loc('peerB'),
      );
      expect((await service.cachedLocations(circle)).length, 2);

      // The roster now has only peerA — peerB departed (engine converged it).
      circleService.getMembersResults = [
        [TestCircleFactory.createMember(pubkey: 'peerA')],
      ];
      await service.reconcileRoster(circle);

      final cached = await service.cachedLocations(circle);
      expect(cached.map((m) => m.pubkey), ['peerA']);
      expect(circleService.methodCalls, contains('removeLastKnownMember'));
    });

    test('reconcileRoster on an empty cache is a no-op', () async {
      await service.reconcileRoster(circle);
      expect(circleService.methodCalls, isNot(contains('getMembers')));
    });
  });
}
