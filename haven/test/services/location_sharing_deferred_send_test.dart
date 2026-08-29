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

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

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

  PendingAutoCommit stagedCommit(int token) => PendingAutoCommit(
    commitEventJson: '{"id":"staged-$token","kind":445}',
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
        ['{"id":"staged-41","kind":445}'],
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
}
