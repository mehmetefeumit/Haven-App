// What the Bluetooth mesh added to `LocationSharingService`
// (`docs/BLUETOOTH_MESH_PLAN.md` §5.2, §5.5, §7.7 R1):
//
//  * a send carries its caller's word on the drive's relay receive, and says
//    "not received" unless told otherwise — a wrong "received" would let a
//    member removed by a commit this device has not fetched read an offline
//    member's fix from the relays;
//  * a seal for the mesh alone takes the mesh-only seal;
//  * what a mesh drive read goes where a relay drive's replay goes — the
//    encrypted store, the cache, the receive-liveness stamp and the clock
//    check — and no log line says the mesh brought it.
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart' show LocationPublishFfi;
import 'package:haven/src/services/circle_health_service.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';

import '../helpers/log_capture.dart';
import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

const _self =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _peer =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _otherPeer =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

final _now = DateTime.utc(2026, 11, 11, 12);

class _Identity implements IdentityService {
  @override
  Future<String> getPubkeyHex() async => _self;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

class _Health implements CircleHealthService {
  final List<List<int>> peerEvents = [];
  final List<List<int>> acks = [];

  @override
  Future<void> notePublishAcked({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async => acks.add(nostrGroupId);

  @override
  Future<void> notePeerEvent({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async => peerEvents.add(nostrGroupId);

  @override
  Future<CircleHealthTimestamps> read({
    required List<int> nostrGroupId,
  }) async => CircleHealthTimestamps.none;
}

Circle _circle(int id, List<String> members) => TestCircleFactory.createCircle(
  mlsGroupId: [id],
  nostrGroupId: [id, id],
  displayName: 'Quiet Wanderers $id',
  members: [for (final m in members) TestCircleFactory.createMember(pubkey: m)],
);

LocationEventResult _fix(int group, String sender, {double latitude = 51.5}) =>
    LocationEventResult(
      kind: LocationEventKind.location,
      mlsGroupId: [group],
      epoch: 4,
      location: DecryptedLocation(
        senderPubkey: sender,
        latitude: latitude,
        longitude: -0.127,
        geohash: 'gcpvj0du',
        timestamp: _now.subtract(const Duration(seconds: 30)),
        expiresAt: _now.add(const Duration(minutes: 15)),
      ),
    );

void main() {
  final a = _circle(1, [_self, _peer]);
  final b = _circle(2, [_self, _otherPeer]);

  ({LocationSharingService service, MockCircleService mock, _Health health})
  build() {
    final mock = MockCircleService(circles: [a, b]);
    final health = _Health();
    return (
      service: LocationSharingService(
        circleService: mock,
        relayService: MockRelayService(),
        identityService: _Identity(),
        healthService: health,
        now: () => _now,
      ),
      mock: mock,
      health: health,
    );
  }

  group("a send's word on the drive's relay receive", () {
    test('is "not received" unless its caller says otherwise', () async {
      final t = build();

      await t.service.publishLocation(
        mlsGroupId: a.mlsGroupId,
        nostrGroupId: a.nostrGroupId,
        latitude: 1,
        longitude: 2,
      );

      expect(t.mock.publishReceived, [false]);
    });

    test('is the word it was given', () async {
      final t = build();

      for (final received in [true, false]) {
        await t.service.publishLocation(
          mlsGroupId: a.mlsGroupId,
          nostrGroupId: a.nostrGroupId,
          latitude: 1,
          longitude: 2,
          received: received,
        );
      }

      expect(t.mock.publishReceived, [true, false]);
    });
  });

  group('a seal for the mesh alone', () {
    test('is asked for only where the caller asks', () async {
      final t = build();

      await t.service.publishLocation(
        mlsGroupId: a.mlsGroupId,
        nostrGroupId: a.nostrGroupId,
        latitude: 1,
        longitude: 2,
      );
      await t.service.publishLocation(
        mlsGroupId: a.mlsGroupId,
        nostrGroupId: a.nostrGroupId,
        latitude: 1,
        longitude: 2,
        meshOnly: true,
      );

      expect(t.mock.sealMeshOnly, [false, true]);
    });

    test('that the core handed to the mesh is no relay verdict and no '
        'delivery', () async {
      final t = build()..mock.publishAnswers = [LocationPublishFfi.meshOnly];

      final outcome = await t.service.publishLocation(
        mlsGroupId: a.mlsGroupId,
        nostrGroupId: a.nostrGroupId,
        latitude: 1,
        longitude: 2,
        meshOnly: true,
      );

      expect(outcome, isA<LocationPublishMeshOnly>());
      expect(t.health.acks, isEmpty);
    });

    test('that the core held sends nothing', () async {
      final t = build()..mock.holdNextSeal = true;

      final outcome = await t.service.publishLocation(
        mlsGroupId: a.mlsGroupId,
        nostrGroupId: a.nostrGroupId,
        latitude: 1,
        longitude: 2,
        meshOnly: true,
      );

      expect(outcome, isA<LocationPublishDeferred>());
      expect(t.mock.methodCalls, isNot(contains('publishSealedLocation')));
    });
  });

  group('what a drive that asked no relay handed back', () {
    test(
      'is stored and cached under the circle its own group id names',
      () async {
        final t = build();

        final stored = await t.service.ingestReplayed([
          _fix(1, _peer),
          _fix(2, _otherPeer, latitude: 48.85),
        ]);

        expect(stored, 2);
        expect(
          {
            for (final row in t.mock.lastKnownRows)
              row['senderPubkey']: row['nostrGroupId'],
          },
          {_peer: a.nostrGroupId, _otherPeer: b.nostrGroupId},
        );
        expect((await t.service.cachedLocations(a)).single.pubkey, _peer);
        final inB = (await t.service.cachedLocations(b)).single;
        expect(inB.pubkey, _otherPeer);
        expect(inB.latitude, 48.85);
        expect(t.health.peerEvents, [a.nostrGroupId, b.nostrGroupId]);
      },
    );

    test("goes exactly where a relay drive's replay goes", () async {
      final results = [_fix(1, _peer), _fix(2, _otherPeer)];
      final byRelay = build()..mock.sealReplays = results;
      final byMesh = build();

      await byRelay.service.publishLocation(
        mlsGroupId: a.mlsGroupId,
        nostrGroupId: a.nostrGroupId,
        latitude: 1,
        longitude: 2,
      );
      await byMesh.service.ingestReplayed(results);

      expect(byMesh.mock.lastKnownRows, hasLength(2));
      expect(
        byMesh.mock.lastKnownRows.toString(),
        byRelay.mock.lastKnownRows.toString(),
      );
      expect(byMesh.health.peerEvents, byRelay.health.peerEvents);
      for (final circle in [a, b]) {
        final viaMesh = (await byMesh.service.cachedLocations(circle)).single;
        final viaRelay = (await byRelay.service.cachedLocations(circle)).single;
        expect(viaMesh.pubkey, viaRelay.pubkey);
        expect(viaMesh.latitude, viaRelay.latitude);
        expect(viaMesh.timestamp, viaRelay.timestamp);
        expect(viaMesh.receivedAt, viaRelay.receivedAt);
      }
    });

    test('drops a fix of a circle this device does not hold, and keeps the '
        'rest', () async {
      final t = build();

      final stored = await t.service.ingestReplayed([
        _fix(9, _peer),
        _fix(2, _otherPeer),
      ]);

      expect(stored, 1);
      expect(t.mock.lastKnownRows.single['senderPubkey'], _otherPeer);
    });

    test("never stores or shows this device's own fix", () async {
      final t = build();

      expect(await t.service.ingestReplayed([_fix(1, _self)]), 0);
      expect(t.mock.lastKnownRows, isEmpty);
      expect(await t.service.cachedLocations(a), isEmpty);
    });

    test('with nothing in it touches nothing', () async {
      final t = build();

      expect(await t.service.ingestReplayed(const []), 0);
      expect(t.mock.methodCalls, isEmpty);
    });

    test(
      'is logged naming no peer, circle or place — and no carrier',
      () async {
        final logs = LogCapture.install();
        final t = build();

        await t.service.ingestReplayed([_fix(1, _peer), _fix(9, _otherPeer)]);

        logs
          ..assertContains('→ location')
          ..assertNoNeedles([
            _peer,
            _otherPeer,
            'Quiet Wanderers',
            'gcpvj0du',
            '51.5',
            '0.127',
          ]);
        expect(
          logs.joined.toLowerCase(),
          allOf(isNot(contains('mesh')), isNot(contains('bluetooth'))),
          reason: 'nothing of the mesh is logged',
        );
      },
    );
  });
}
