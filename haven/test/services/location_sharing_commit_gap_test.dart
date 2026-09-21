/// The commit gap, Dart half: a peer fix that arrives while a commit is staged.
///
/// While a staged commit waits for its relay ack, the engine BUFFERS every
/// inbound message for that group. Resolving the commit — confirm or fail —
/// replays that buffer, and until this change the whole replay was dropped on
/// the floor at the FFI boundary: the fix was decrypted, written `Processed`
/// (so it is never redelivered) and then never surfaced to anyone. These tests
/// pin the route back: a location carried by a RESOLUTION reaches the map's
/// cache, the persistent store and the receive-liveness stamp, and a proposal
/// carried by one reaches a relay.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_health_service.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../helpers/log_capture.dart';
import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

const _peerPubkey =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

/// The staged commit `_stagingService` hands back on ingest — its `h` names
/// [nostrGroupId], the ambient circle it must resolve against.
String _stagedCommitEventJsonFor(List<int> nostrGroupId) {
  final hex = nostrGroupId
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '{"id":"stagedCommit","kind":445,"tags":[["h","$hex"]]}';
}

/// The kind-445 the poll fetches; its ingest is what stages the commit.
const _inboundEvent = '{"id":"evtSelfRemove","kind":445,"content":"x"}';

final _now = DateTime.utc(2026, 9, 20, 9);

/// A relay whose commit publish parks until [release] is completed, so a test
/// can land an `onAppPaused` INSIDE the ladder's round trip with no sleeps.
class _GatedPublishRelayService extends MockRelayService {
  _GatedPublishRelayService({super.groupMessages});

  /// Completes when the ladder's publish has been entered.
  final Completer<void> published = Completer<void>();

  /// Completing this lets that publish return.
  final Completer<void> release = Completer<void>();

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    if (!published.isCompleted) published.complete();
    await release.future;
    return super.publishEvent(eventJson: eventJson, relays: relays);
  }
}

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

/// A kind-445 proposal addressed to the circle whose PUBLIC nostr group id is
/// [nostrGroupId] — the `h` tag is how every Rust plane routes one, and the
/// only thing that says which group it belongs to.
String _proposalFor(List<int> nostrGroupId) {
  final hex = nostrGroupId
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '{"id":"replayed","kind":445,"tags":[["h","$hex"]]}';
}

DecryptLocationOutcome _replay({
  List<LocationEventResult> results = const [],
  List<String> proposals = const [],
  List<PendingAutoCommit> autoCommits = const [],
}) => DecryptLocationOutcome(
  results: results,
  autoCommits: autoCommits,
  proposals: proposals,
);

/// A circle service whose ingest stages ONE auto-commit, and whose resolution
/// of it replays [onConfirm] / [onFail].
MockCircleService _stagingService(
  Circle circle, {
  DecryptLocationOutcome? onConfirm,
  DecryptLocationOutcome? onFail,
  List<Circle> alsoHeld = const [],
}) {
  final service = MockCircleService(circles: [circle, ...alsoHeld])
    ..decryptLocationResults = [const []]
    ..decryptLocationAutoCommits[0] = [
      PendingAutoCommit(
        commitEventJson: _stagedCommitEventJsonFor(circle.nostrGroupId),
        pendingToken: PendingCommitToken(BigInt.from(42)),
      ),
    ];
  if (onConfirm != null) service.confirmPendingCommitOutcomes[0] = onConfirm;
  if (onFail != null) service.failPendingCommitOutcomes[0] = onFail;
  return service;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final circle = TestCircleFactory.createCircle(
    relays: const ['wss://relay.example.com'],
  );

  group('a location replayed by a publish resolution', () {
    test('reaches the map cache through the foreground poll', () async {
      final relay = MockRelayService(groupMessages: const [_inboundEvent]);
      final circleService = _stagingService(
        circle,
        onConfirm: _replay(results: [_locationResult()]),
      );
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
            "confirm's replay is not routed here, that fix is lost for good",
      );
      expect(cached.single.latitude, 48.8566);
    });

    test('reaches it through a FAILED publish too', () async {
      final relay = MockRelayService(groupMessages: const [_inboundEvent])
        ..shouldRejectPublish = true;
      final circleService = _stagingService(
        circle,
        onFail: _replay(results: [_locationResult()]),
      );
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relay,
        now: () => _now,
      );

      await service.fetchMemberLocations(circle: circle);

      expect(circleService.confirmPendingCommitCalls, isEmpty);
      expect(
        (await service.cachedLocations(circle)).map((l) => l.pubkey),
        [_peerPubkey],
        reason: 'the engine replays its buffer on a no-ack as well, so a '
            "rejected publish must not cost the peer's fix either",
      );
    });

    test('is persisted and stamps receive liveness', () async {
      final relay = MockRelayService(groupMessages: const [_inboundEvent]);
      final circleService = _stagingService(
        circle,
        onConfirm: _replay(results: [_locationResult()]),
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
      final circleService = _stagingService(
        circle,
        onConfirm: _replay(results: [_locationResult()]),
      );
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

  group('a batch spanning two circles', () {
    // The engine's buffers are GLOBAL: resolving circle X's staged commit
    // replays whatever was buffered for every group, so a batch that arrives
    // on X's confirm can carry circle Y's peer. Filing it under X puts one
    // circle's member on another circle's map and in another circle's
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
      final circleService = _stagingService(
        circle,
        alsoHeld: [other],
        onConfirm: _replay(
          results: [
            _locationResult(mlsGroupId: other.mlsGroupId, sender: 'ee' * 32),
          ],
        ),
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
            'the circle whose commit happened to be the one being resolved',
      );
      expect(
        await service.cachedLocations(circle),
        isEmpty,
        reason: "and it must not also appear on the resolving circle's map",
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
      final circleService = _stagingService(
        circle,
        onConfirm: _replay(
          results: [
            _locationResult(mlsGroupId: const [9, 9, 9, 9], sender: 'ff' * 32),
          ],
        ),
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

  group('a proposal replayed by a publish resolution', () {
    test('goes to the relays of the circle its own `h` tag names', () async {
      // Publishing it to the resolving circle's relays tells THAT circle's
      // relay operators this client also participates in the other group
      // (cross-circle correlation), and may never reach the group the leave
      // belongs to — which is the wedge `proposals` exists to prevent.
      final other = TestCircleFactory.createCircle(
        mlsGroupId: const [7, 7, 7, 7],
        nostrGroupId: const [8, 8, 8, 8],
        displayName: 'Other Circle',
        relays: const ['wss://other.example.com'],
      );
      final proposal = _proposalFor(other.nostrGroupId);
      final relay = MockRelayService(groupMessages: const [_inboundEvent]);
      final circleService = _stagingService(
        circle,
        alsoHeld: [other],
        onConfirm: _replay(proposals: [proposal]),
      );
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relay,
        now: () => _now,
      );

      await service.fetchMemberLocations(circle: circle);

      expect(relay.publishedEvents, contains(proposal));
      final targeted = relay
          .publishEventRelayCalls[relay.publishedEvents.indexOf(proposal)];
      expect(targeted, other.relays);
      expect(
        targeted,
        isNot(contains(circle.relays.first)),
        reason: "the resolving circle's relay operators must not learn of "
            'this participation in the other group',
      );
    });

    test('is published NOWHERE when its `h` names no circle we hold', () async {
      final proposal = _proposalFor(const [0xDE, 0xAD]);
      final relay = MockRelayService(groupMessages: const [_inboundEvent]);
      final circleService = _stagingService(
        circle,
        onConfirm: _replay(proposals: [proposal]),
      );
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relay,
        now: () => _now,
      );

      await service.fetchMemberLocations(circle: circle);

      expect(
        relay.publishedEvents,
        isNot(contains(proposal)),
        reason: 'fail closed: a proposal with nowhere correct to go is not '
            'sent to the nearest relay set instead',
      );
      expect(
        relay.publishedEvents,
        [_stagedCommitEventJsonFor(circle.nostrGroupId)],
        reason: 'anti-vacuity: the ladder DID publish this cycle, so the '
            'absence above is a routing decision, not a dead path',
      );
    });
  });

  group('a pause landing inside the ladder', () {
    test('leaves the cache empty rather than refilling what pause cleared',
        () async {
      // The ladder awaits a publish→confirm round trip. `onAppPaused` landing
      // in that window has already cleared `_locationCache`; writing the
      // replayed coordinates in afterwards puts plaintext location back into
      // memory the user asked to be rid of.
      final relay = _GatedPublishRelayService(
        groupMessages: const [_inboundEvent],
      );
      final circleService = _stagingService(
        circle,
        onConfirm: _replay(results: [_locationResult()]),
      );
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relay,
        now: () => _now,
      );

      final fetch = service.fetchMemberLocations(circle: circle);
      await relay.published.future;
      // The pause lands while the commit publish is still in flight.
      service.onAppPaused();
      relay.release.complete();
      await fetch;

      expect(
        service.debugCachedLocationCount,
        0,
        reason: 'the fetch must abort at the fence after the ladder, not '
            'refill the cache the pause just cleared',
      );
      expect(
        circleService.confirmPendingCommitCalls,
        hasLength(1),
        reason: 'anti-vacuity: the ladder really did run to its confirm '
            'inside the paused window, so the empty cache is the fence and '
            'not a ladder that never happened',
      );
    });
  });

  group('Rule 15', () {
    test('a replayed batch puts no identifier in any log line', () async {
      // Every routing decision this change added runs under the capture: a
      // fix for ANOTHER circle (the per-result lookup), a fix for a circle we
      // do not hold (the drop), a proposal for another circle (the `h`
      // router) and one for an unknown `h` (the fail-closed rung).
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
      final relay = MockRelayService(groupMessages: const [_inboundEvent]);
      final circleService = _stagingService(
        identifiedCircle,
        alsoHeld: [secondCircle],
        onConfirm: _replay(
          results: [
            _locationResult(),
            _locationResult(
              mlsGroupId: secondCircle.mlsGroupId,
              sender: 'ee' * 32,
            ),
            _locationResult(
              mlsGroupId: const [0x99, 0x98, 0x97, 0x96],
              sender: 'ff' * 32,
            ),
          ],
          proposals: [
            _proposalFor(secondCircle.nostrGroupId),
            _proposalFor(const [0x89, 0x88, 0x87, 0x86]),
          ],
          // No `h` at all — the fail-closed rung `_relaysForCommit` takes
          // when a production kind-445 commit would never omit the tag.
          autoCommits: [
            PendingAutoCommit(
              commitEventJson: '{"id":"tagless","kind":445}',
              pendingToken: PendingCommitToken(BigInt.from(77)),
            ),
          ],
        ),
      );
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relay,
        now: () => _now,
      );

      final capture = LogCapture.install();
      await service.fetchMemberLocations(circle: identifiedCircle);

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
          // …and the ids of the groups we do NOT hold: the two fail-closed
          // lines are the ones most tempting to "just log which one".
          '99989796',
          '89888786',
          // The same six ids as Dart itself renders them.
          ..._rawByteRenderings(identifiedCircle.mlsGroupId),
          ..._rawByteRenderings(identifiedCircle.nostrGroupId),
          ..._rawByteRenderings(secondCircle.mlsGroupId),
          ..._rawByteRenderings(secondCircle.nostrGroupId),
          ..._rawByteRenderings(const [0x99, 0x98, 0x97, 0x96]),
          ..._rawByteRenderings(const [0x89, 0x88, 0x87, 0x86]),
        ]);
    });
  });
}
