// A DEFERRED location send is a state, not a failure — and it carries work.
//
// `cgka-engine` queues an outbound intent instead of encrypting whenever a
// stored convergence input still gates the circle, OR whenever it has just
// STAGED a peer's `SelfRemove` eviction. Before Unit B that outcome reached
// Dart as an opaque exception string every caller dropped into a `debugPrint`,
// which is how a device could stop sharing with nothing noticing.
//
// These tests pin the whole Dart-side contract:
//
//  * a staged commit handed back on a deferral goes through the Rule-13 ladder
//    — published, then confirmed on a ≥1-relay ACK, or rolled back when no
//    relay took it. Dropping it would pin the group in `PendingPublish`, where
//    every later send fails outright;
//  * a deferral records NOTHING that implies delivery: no `notePublishAcked`
//    (Rule 13's "acked means acked"), and no clock-skew verdict (nothing
//    reached a relay to have an opinion about our timestamp);
//  * a deferral still returns, typed, so the caller can route it to the
//    sharing-health model instead of catching an exception;
//  * a SENT outcome behaves exactly as before.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/relay_service.dart' show PublishResult;

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

/// A relay whose commit publish parks until [release] is completed, so a test
/// can land an `onAppPaused` INSIDE the ladder's round trip with no sleeps —
/// mirrors `location_sharing_commit_gap_test.dart`'s fixture of the same
/// shape for the poll planes.
class _GatedPublishRelayService extends MockRelayService {
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

void main() {
  late MockCircleService circleService;
  late MockRelayService relayService;
  late LocationSharingService service;

  const mlsGroupId = [1, 2, 3];
  const nostrGroupId = [9, 9];
  const relay = 'wss://relay.example.com';

  final circle = TestCircleFactory.createCircle(
    mlsGroupId: mlsGroupId,
    nostrGroupId: nostrGroupId,
    relays: const [relay],
  );

  setUp(() {
    circleService = MockCircleService(circles: [circle]);
    relayService = MockRelayService();
    service = LocationSharingService(
      circleService: circleService,
      relayService: relayService,
    );
  });

  Future<LocationPublishOutcome> publish() => service.publishLocation(
    mlsGroupId: mlsGroupId,
    nostrGroupId: nostrGroupId,
    senderPubkeyHex: 'ff' * 32,
    latitude: 1,
    longitude: 2,
  );

  LocationSendDeferred deferralWith({
    List<PendingAutoCommit> commits = const [],
    List<String> proposals = const [],
    int unresolvedInputs = 1,
    int discardedIntents = 1,
    bool repaired = false,
  }) => LocationSendDeferred(
    unresolvedInputs: unresolvedInputs,
    discardedIntents: discardedIntents,
    repaired: repaired,
    commits: commits,
    proposals: proposals,
  );

  // The `h` names `circle` above (`nostrGroupId` `[9,9]`), the ambient
  // circle every test in this file resolves the staged commit against.
  PendingAutoCommit stagedCommit(int token) => PendingAutoCommit(
    commitEventJson: '{"id":"staged-$token","kind":445,"tags":[["h","0909"]]}',
    pendingToken: PendingCommitToken(BigInt.from(token)),
  );

  group('a deferral that staged a commit', () {
    test('publishes it and CONFIRMS on a relay ack (Rule 13)', () async {
      circleService.deferNextEncrypt = deferralWith(
        commits: [stagedCommit(41)],
      );

      final outcome = await publish();

      expect(outcome, isA<LocationPublishDeferred>());
      expect(
        (outcome as LocationPublishDeferred).stagedCommits,
        1,
        reason: 'the outcome must report the work it resolved',
      );
      expect(
        relayService.publishedEvents,
        [stagedCommit(41).commitEventJson],
        reason:
            'the staged eviction must reach the relays exactly once — and '
            'no location event may be published, because none was encrypted',
      );
      expect(
        circleService.confirmPendingCommitCalls.map((t) => t.value),
        [BigInt.from(41)],
        reason: 'a ≥1-relay ACK is what licenses the confirm',
      );
      expect(circleService.failPendingCommitCalls, isEmpty);
    });

    test('ROLLS BACK when no relay accepted it', () async {
      relayService.shouldRejectPublish = true;
      circleService.deferNextEncrypt = deferralWith(
        commits: [stagedCommit(42)],
      );

      await publish();

      expect(relayService.publishedEvents, hasLength(1));
      expect(
        circleService.confirmPendingCommitCalls,
        isEmpty,
        reason:
            'confirming a commit no relay took would apply it locally '
            'while the rest of the group never sees it',
      );
      expect(circleService.failPendingCommitCalls.map((t) => t.value), [
        BigInt.from(42),
      ]);
    });

    test(
      'rolls back rather than stranding it when the circle is gone',
      () async {
        // No circle row → no relays to publish to. Leaving the pending ref
        // unresolved would pin the group in `PendingPublish`.
        final orphaned = LocationSharingService(
          circleService: MockCircleService()
            ..deferNextEncrypt = deferralWith(commits: [stagedCommit(43)]),
          relayService: relayService,
        );

        await orphaned.publishLocation(
          mlsGroupId: mlsGroupId,
          nostrGroupId: nostrGroupId,
          senderPubkeyHex: 'ff' * 32,
          latitude: 1,
          longitude: 2,
        );

        expect(relayService.publishedEvents, isEmpty);
      },
    );

    test('publishes bare proposals without confirming anything', () async {
      circleService.deferNextEncrypt = deferralWith(
        proposals: ['{"id":"proposal-1","kind":445}'],
      );

      final outcome = await publish() as LocationPublishDeferred;

      expect(outcome.publishedProposals, 1);
      expect(relayService.publishedEvents, ['{"id":"proposal-1","kind":445}']);
      expect(
        circleService.confirmPendingCommitCalls,
        isEmpty,
        reason:
            'a proposal carries no staged state — there is nothing to '
            'confirm and nothing to roll back',
      );
      expect(circleService.failPendingCommitCalls, isEmpty);
    });
  });

  group('what a deferral must NOT report', () {
    test('carries its counters back instead of throwing', () async {
      circleService.deferNextEncrypt = deferralWith(
        unresolvedInputs: 3,
        discardedIntents: 2,
        repaired: false,
      );

      final outcome = await publish();

      expect(outcome, isA<LocationPublishDeferred>());
      final deferred = outcome as LocationPublishDeferred;
      expect(deferred.unresolvedInputs, 3);
      expect(deferred.discardedIntents, 2);
      expect(deferred.repaired, isFalse);
      expect(deferred.stagedCommits, 0);
    });

    test('never publishes a location event', () async {
      circleService.deferNextEncrypt = deferralWith();

      await publish();

      expect(
        relayService.publishedEvents,
        isEmpty,
        reason: 'there is no encrypted location to publish on a deferral',
      );
    });
  });

  group('a sent outcome is unchanged', () {
    test(
      'publishes the encrypted event and reports the relay verdict',
      () async {
        final outcome = await publish();

        expect(outcome, isA<LocationPublishSent>());
        expect((outcome as LocationPublishSent).result.acceptedBy, [relay]);
        expect(relayService.publishedEvents, hasLength(1));
        expect(circleService.methodCalls, contains('encryptLocation'));
      },
    );

    test('a deferral is consumed once, so the next cycle sends', () async {
      circleService.deferNextEncrypt = deferralWith();

      expect(await publish(), isA<LocationPublishDeferred>());
      expect(
        await publish(),
        isA<LocationPublishSent>(),
        reason:
            'the repair runs inside the deferral, so the very next '
            'scheduled publish is expected to encrypt again',
      );
    });
  });

  group('a pause landing inside the deferred-send ladder', () {
    test(
      'leaves the cache empty rather than refilling what pause cleared',
      () async {
        // The ladder awaits a publish→confirm round trip, exactly like the
        // poll planes' own — `onAppPaused` landing in that window has
        // already cleared the cache; writing the replayed coordinates in
        // afterwards puts plaintext location back into memory the user
        // asked to be rid of.
        final gatedRelay = _GatedPublishRelayService();
        circleService.deferNextEncrypt = deferralWith(
          commits: [stagedCommit(51)],
        );
        circleService.confirmPendingCommitOutcomes[0] = DecryptLocationOutcome(
          results: [
            LocationEventResult(
              kind: LocationEventKind.location,
              location: DecryptedLocation(
                senderPubkey: 'peer-during-pause',
                latitude: 41.5,
                longitude: -73.5,
                geohash: 'dr7',
                timestamp: DateTime(2026, 3, 4, 10),
                expiresAt: DateTime(2026, 3, 4, 10, 30),
              ),
              mlsGroupId: mlsGroupId,
              epoch: 7,
            ),
          ],
          autoCommits: const [],
          proposals: const [],
        );
        final gatedService = LocationSharingService(
          circleService: circleService,
          relayService: gatedRelay,
        );

        final send = gatedService.publishLocation(
          mlsGroupId: mlsGroupId,
          nostrGroupId: nostrGroupId,
          senderPubkeyHex: 'ff' * 32,
          latitude: 1,
          longitude: 2,
        );
        await gatedRelay.published.future;
        // The pause lands while the commit publish is still in flight.
        gatedService.onAppPaused();
        gatedRelay.release.complete();
        await send;

        expect(
          gatedService.debugCachedLocationCount,
          0,
          reason: 'the send must abort at the fence after the ladder, not '
              'refill the cache the pause just cleared',
        );
        expect(
          circleService.confirmPendingCommitCalls,
          hasLength(1),
          reason: 'anti-vacuity: the ladder really did run to its confirm '
              'inside the paused window, so the empty cache is the fence '
              'and not a ladder that never happened',
        );
      },
    );
  });
}
