/// The commit gap, Dart half: a peer fix that arrives while a commit is staged.
///
/// While a staged commit waits for its relay ack, the engine BUFFERS every
/// inbound message for that group, and resolving the commit replays that
/// buffer. On the receive planes the resolution is the fanout driver's own
/// drive (`ingest_driven`), so the replay comes back in the outcome the ingest
/// returns; on a SEND it comes back from the seal's own drives. These tests pin
/// the route back from both: a location carried by either reaches the map's
/// cache, the persistent store and the receive-liveness stamp, each under the
/// circle its own group id names. That the engine replays on a no-ack too, and
/// records and drives a proposal it re-mints on an ingest or a seal, is Rust's
/// (`haven-core/tests/commit_gap_replay_e2e.rs` `the_same_on_publish_failed`;
/// `send_path_drain_e2e.rs`
/// `a_peer_location_replayed_during_a_sends_convergence_settling_is_persisted`;
/// `leave_fanout_e2e.rs`
/// `a_fresh_leave_proposal_for_a_new_epoch_deletes_the_stale_epochs_fanout`).
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_health_service.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';

import '../helpers/log_capture.dart';
import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

const _peerPubkey =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

/// The kind-445 the poll fetches.
const _inboundEvent = '{"id":"evtSelfRemove","kind":445,"content":"x"}';

final _now = DateTime.utc(2026, 9, 20, 9);

class _RecordingHealthService implements CircleHealthService {
  final List<({List<int> nostrGroupId, DateTime at})> peerEvents = [];

  @override
  Future<void> notePublishAcked({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async {}

  @override
  Future<void> notePeerEvent({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async => peerEvents.add((nostrGroupId: nostrGroupId, at: at));

  @override
  Future<CircleHealthTimestamps> read({
    required List<int> nostrGroupId,
  }) async => CircleHealthTimestamps.none;
}

DecryptedLocation _peerFix({String sender = _peerPubkey}) => DecryptedLocation(
  senderPubkey: sender,
  latitude: 48.8566,
  longitude: 2.3522,
  geohash: 'u09tvw',
  timestamp: _now.subtract(const Duration(minutes: 2)),
  expiresAt: _now.add(const Duration(minutes: 30)),
);

LocationEventResult _locationResult({
  String sender = _peerPubkey,
  List<int> mlsGroupId = const [1, 2, 3, 4],
}) => LocationEventResult(
  kind: LocationEventKind.location,
  location: _peerFix(sender: sender),
  mlsGroupId: mlsGroupId,
  epoch: 11,
);

/// The shapes a Dart log line renders a RAW group id in, neither of which the
/// hex needles catch: `[171, 1, 2, 3]` from a bare interpolation of the
/// `List<int>` the FFI hands over, and `171,1,2,3` from a `join`. Hex is how a
/// Nostr id reaches the wire, but a list of bytes is how Dart holds one, so a
/// needle set that only knows hex would stay green on the likeliest leak.
Iterable<String> _rawByteRenderings(List<int> groupId) => [
  groupId.toString(),
  groupId.join(','),
];

/// A circle service whose ingest of the one polled event hands back
/// [replayed]: what the confirm the driver's own drive made replayed.
MockCircleService _replayingIngest(
  Circle circle,
  List<LocationEventResult> replayed, {
  List<Circle> alsoHeld = const [],
}) => MockCircleService(circles: [circle, ...alsoHeld])
  ..decryptLocationResults = [replayed];

/// A circle service whose next seal's drives hand back [replayed].
MockCircleService _replayingSeal(
  Circle circle,
  List<LocationEventResult> replayed, {
  List<Circle> alsoHeld = const [],
}) => MockCircleService(circles: [circle, ...alsoHeld])..sealReplays = replayed;

/// One location send for [circle].
Future<LocationPublishOutcome> _send(
  LocationSharingService service,
  Circle circle,
) => service.publishLocation(
  mlsGroupId: circle.mlsGroupId,
  nostrGroupId: circle.nostrGroupId,
  latitude: 1,
  longitude: 2,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final circle = TestCircleFactory.createCircle(
    relays: const ['wss://relay.example.com'],
  );

  group("a location the driver's ingest hands back", () {
    test('reaches the map cache through the foreground poll', () async {
      final relay = MockRelayService(groupMessages: const [_inboundEvent]);
      final circleService = _replayingIngest(circle, [_locationResult()]);
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relay,
        now: () => _now,
      );

      await service.fetchMemberLocations(circle: circle);

      final cached = await service.cachedLocations(circle);
      expect(
        cached.map((l) => l.pubkey),
        [_peerPubkey],
        reason: 'the engine delivers a buffered message exactly once; if the '
            "drive's replay is not routed here, that fix is lost for good",
      );
      expect(cached.single.latitude, 48.8566);
    });

    test('is persisted and stamps receive liveness', () async {
      final relay = MockRelayService(groupMessages: const [_inboundEvent]);
      final circleService = _replayingIngest(circle, [_locationResult()]);
      final health = _RecordingHealthService();
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relay,
        healthService: health,
        now: () => _now,
      );

      await service.fetchMemberLocations(circle: circle);

      expect(
        circleService.lastKnownRows.where(
          (row) => row['senderPubkey'] == _peerPubkey,
        ),
        hasLength(1),
        reason: 'the Rust upsert is idempotent, so re-writing the row costs '
            'nothing and keeps one funnel for every receive plane',
      );
      expect(
        health.peerEvents.map((e) => e.nostrGroupId),
        [circle.nostrGroupId],
        reason: 'a receive that bypasses the liveness stamp makes the '
            'sharing-health banner under-report a circle that IS receiving',
      );
    });

    test('reaches the map cache through the evolution poll too', () async {
      final relay = MockRelayService(groupMessages: const [_inboundEvent]);
      final circleService = _replayingIngest(circle, [_locationResult()]);
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relay,
        now: () => _now,
      );

      final anyLocation = await service.pollEvolutionEvents(circles: [circle]);

      expect(anyLocation, isTrue);
      expect(
        (await service.cachedLocations(circle)).map((l) => l.pubkey),
        [_peerPubkey],
      );
    });
  });

  group("a location a seal's drives hand back", () {
    test('reaches the map cache, the store and receive liveness', () async {
      final relay = MockRelayService();
      final circleService = _replayingSeal(circle, [_locationResult()]);
      final health = _RecordingHealthService();
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relay,
        healthService: health,
        now: () => _now,
      );

      await _send(service, circle);

      expect(
        (await service.cachedLocations(circle)).map((l) => l.pubkey),
        [_peerPubkey],
      );
      expect(
        circleService.lastKnownRows.where(
          (row) => row['senderPubkey'] == _peerPubkey,
        ),
        hasLength(1),
      );
      expect(
        health.peerEvents.map((e) => e.nostrGroupId),
        [circle.nostrGroupId],
      );
    });
  });

  group('a batch carrying a roster or epoch change', () {
    // It may be the commit that ends a leave this device asked for: the
    // caller carries leaves on at once on it, not at the next wake.
    LocationEventResult groupUpdate() => const LocationEventResult(
      kind: LocationEventKind.groupUpdate,
      mlsGroupId: [1, 2, 3, 4],
      epoch: 12,
    );

    test('tells the caller once, from a poll and from a seal', () async {
      var told = 0;
      final circleService = _replayingIngest(circle, [
        groupUpdate(),
        groupUpdate(),
        _locationResult(),
      ])..sealReplays = [groupUpdate()];
      final service = LocationSharingService(
        circleService: circleService,
        relayService: MockRelayService(groupMessages: const [_inboundEvent]),
        onGroupStateChanged: () => told++,
        now: () => _now,
      );

      await service.fetchMemberLocations(circle: circle);
      expect(told, 1);
      await _send(service, circle);
      expect(told, 2);
    });

    test("a seal's replay whose circle cannot be read says so with fixed "
        'text', () async {
      final capture = LogCapture.install();
      final circleService = _replayingSeal(circle, [_locationResult()])
        ..getCircleThrows = Exception(
          'circle ${'ab' * 16} at wss://planted.example',
        );
      final service = LocationSharingService(
        circleService: circleService,
        relayService: MockRelayService(),
        now: () => _now,
      );

      await _send(service, circle);

      capture
        ..restore()
        ..assertContains('[LocationService] seal replay: circle lookup failed')
        ..assertNoNeedles(['ab' * 16, 'wss://planted.example']);
    });

    test('a batch of locations alone tells it nothing', () async {
      var told = 0;
      final service = LocationSharingService(
        circleService: _replayingIngest(circle, [_locationResult()]),
        relayService: MockRelayService(groupMessages: const [_inboundEvent]),
        onGroupStateChanged: () => told++,
        now: () => _now,
      );

      await service.fetchMemberLocations(circle: circle);

      expect(told, 0);
    });
  });

  group('a batch spanning two circles', () {
    // The engine's buffers are GLOBAL: resolving circle X's staged commit
    // replays whatever was buffered for every group, so a batch an ingest of
    // X's event hands back can carry circle Y's peer. Filing it under X puts
    // one circle's member on another circle's map and in another circle's
    // `last_known_locations` row for up to 24 h. Rust routes per event
    // (`nostr_group_id_for` / `route_results`); so must this side.
    test('lands each peer under the circle its OWN group id names', () async {
      final other = TestCircleFactory.createCircle(
        mlsGroupId: const [7, 7, 7, 7],
        nostrGroupId: const [8, 8, 8, 8],
        displayName: 'Other Circle',
        relays: const ['wss://other.example.com'],
      );
      final relay = MockRelayService(groupMessages: const [_inboundEvent]);
      final circleService = _replayingIngest(
        circle,
        [_locationResult(mlsGroupId: other.mlsGroupId, sender: 'ee' * 32)],
        alsoHeld: [other],
      );
      final health = _RecordingHealthService();
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relay,
        healthService: health,
        now: () => _now,
      );

      await service.fetchMemberLocations(circle: circle);

      expect(
        (await service.cachedLocations(other)).map((l) => l.pubkey),
        ['ee' * 32],
        reason: 'the fix belongs to the group its own result names, not to '
            'the circle whose event happened to be the one ingested',
      );
      expect(
        await service.cachedLocations(circle),
        isEmpty,
        reason: "and it must not also appear on the ingesting circle's map",
      );
      expect(
        circleService.lastKnownRows.single['nostrGroupId'],
        other.nostrGroupId,
        reason: 'the persisted row is keyed by ngid; the wrong one survives '
            'to purge_after (24 h)',
      );
      expect(
        health.peerEvents.map((e) => e.nostrGroupId),
        [other.nostrGroupId],
        reason: 'receive liveness belongs to the circle that received, or the '
            'banner reports a silent circle as live',
      );
    });

    test('drops a result for a circle this device does not hold', () async {
      final relay = MockRelayService(groupMessages: const [_inboundEvent]);
      final circleService = _replayingIngest(
        circle,
        [_locationResult(mlsGroupId: const [9, 9, 9, 9], sender: 'ff' * 32)],
      );
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relay,
        now: () => _now,
      );

      await service.fetchMemberLocations(circle: circle);

      expect(await service.cachedLocations(circle), isEmpty);
      expect(
        circleService.lastKnownRows,
        isEmpty,
        reason: 'an unknown group is skipped, exactly as `route_results` does '
            '— never filed under the ambient circle as a fallback',
      );
    });
  });

  group('a pause landing inside the seal', () {
    test('leaves the cache empty rather than refilling what pause cleared',
        () async {
      // The seal is an FFI round trip. `onAppPaused` landing in that window
      // has already cleared the cache; writing the replayed coordinates in
      // afterwards puts plaintext location back into memory the user asked
      // to be rid of.
      final circleService = _replayingSeal(circle, [_locationResult()])
        ..encryptGate = Completer<void>();
      final service = LocationSharingService(
        circleService: circleService,
        relayService: MockRelayService(),
        now: () => _now,
      );

      final send = _send(service, circle);
      await pumpEventQueue();
      expect(circleService.encryptedMlsGroupIds, hasLength(1));
      service.onAppPaused();
      circleService.encryptGate!.complete();
      await send;

      expect(
        service.debugCachedLocationCount,
        0,
        reason: 'the replay refilled the cache the pause just cleared',
      );
      expect(
        circleService.lastKnownRows.where(
          (row) => row['senderPubkey'] == _peerPubkey,
        ),
        hasLength(1),
        reason: 'anti-vacuity: the replay was routed, and stored, inside the '
            'paused window, so the empty cache is the fence',
      );
    });
  });

  group('Rule 15', () {
    test('a replayed batch puts no identifier in any log line', () async {
      // Every routing decision a seal's replay takes runs under the
      // capture: a fix for ANOTHER circle (the per-result lookup) and a fix
      // for a circle we do not hold (the drop).
      const groupIdByte = 0xAB;
      final identifiedCircle = TestCircleFactory.createCircle(
        displayName: 'Marthas Hideaway',
        mlsGroupId: const [groupIdByte, 1, 2, 3],
        nostrGroupId: const [groupIdByte, 4, 5, 6],
        relays: const ['wss://relay.needlehost.example'],
      );
      final secondCircle = TestCircleFactory.createCircle(
        displayName: 'Wolfsschanze',
        mlsGroupId: const [0xCD, 1, 2, 3],
        nostrGroupId: const [0xCD, 4, 5, 6],
        relays: const ['wss://second.needlehost.example'],
      );
      final relay = MockRelayService();
      final circleService = _replayingSeal(
        identifiedCircle,
        [
          _locationResult(mlsGroupId: identifiedCircle.mlsGroupId),
          _locationResult(
            mlsGroupId: secondCircle.mlsGroupId,
            sender: 'ee' * 32,
          ),
          _locationResult(
            mlsGroupId: const [0x99, 0x98, 0x97, 0x96],
            sender: 'ff' * 32,
          ),
        ],
        alsoHeld: [secondCircle],
      );
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relay,
        now: () => _now,
      );

      final capture = LogCapture.install();
      await _send(service, identifiedCircle);

      capture
        ..restore()
        // Anti-vacuity first: the path must have logged SOMETHING, or every
        // absence below is the absence of logging rather than of an
        // identifier.
        ..assertContains('[LocationService]')
        ..assertNoNeedles([
          _peerPubkey,
          'Marthas Hideaway',
          'Wolfsschanze',
          '48.8566',
          '2.3522',
          'u09tvw',
          'wss://relay.needlehost.example',
          'wss://second.needlehost.example',
          // The group ids as a log line would render them: a line printing
          // raw group bytes, or the `h` tag it just routed on, fails here.
          'ab010203',
          'ab040506',
          'cd010203',
          'cd040506',
          // …and the id of the group we do NOT hold: the fail-closed line is
          // the one most tempting to "just log which one".
          '99989796',
          // The same five ids as Dart itself renders them.
          ..._rawByteRenderings(identifiedCircle.mlsGroupId),
          ..._rawByteRenderings(identifiedCircle.nostrGroupId),
          ..._rawByteRenderings(secondCircle.mlsGroupId),
          ..._rawByteRenderings(secondCircle.nostrGroupId),
          ..._rawByteRenderings(const [0x99, 0x98, 0x97, 0x96]),
        ]);
    });
  });
}
