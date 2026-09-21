/// The foreground Rule-13 ladder, driven directly.
///
/// `resolveAutoCommits` is the one Dart mirror of
/// `haven_core::relay::auto_commit::resolve_receive_publish_work`, and since
/// the commit-gap fix it is a LOOP: resolving a staged commit makes the engine
/// replay everything it buffered while that commit was in flight, and that
/// replay can both surface the NEXT eviction and carry peer locations that
/// exist nowhere else on this plane. These tests pin the loop's three
/// properties — it runs to an empty worklist, it never resolves a ref twice,
/// and it stops at a runaway cap with every un-run commit reported rather than
/// discarded — plus the accumulation the caller depends on.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_auto_commit.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

/// A [MockCircleService] that appends to a SHARED call log, so a test can
/// assert the publish/confirm INTERLEAVE rather than two independent orders.
class _OrderedCircleService extends MockCircleService {
  _OrderedCircleService(this.order, {super.circles});

  final List<String> order;

  @override
  Future<DecryptLocationOutcome> confirmPendingCommit(
    PendingCommitToken pending,
  ) {
    order.add('confirm:${pending.value}');
    return super.confirmPendingCommit(pending);
  }

  @override
  Future<DecryptLocationOutcome> failPendingCommit(
    PendingCommitToken pending,
  ) {
    order.add('fail:${pending.value}');
    return super.failPendingCommit(pending);
  }
}

/// The [MockRelayService] half of the same shared log.
class _OrderedRelayService extends MockRelayService {
  _OrderedRelayService(this.order);

  final List<String> order;

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) {
    order.add('publish:$eventJson');
    return super.publishEvent(eventJson: eventJson, relays: relays);
  }
}

/// A circle service whose EVERY confirm surfaces a brand-new auto-commit —
/// the cascade that never ends, i.e. the bug the runaway cap guards against.
class _EndlessCascadeCircleService extends MockCircleService {
  _EndlessCascadeCircleService({super.circles});

  int minted = 0;

  @override
  Future<DecryptLocationOutcome> confirmPendingCommit(
    PendingCommitToken pending,
  ) async {
    await super.confirmPendingCommit(pending);
    minted++;
    return DecryptLocationOutcome(
      results: const [],
      autoCommits: [
        PendingAutoCommit(
          commitEventJson:
              '{"id":"cascade$minted","kind":445,"tags":[["h","05060708"]]}',
          pendingToken: PendingCommitToken(BigInt.from(1000 + minted)),
        ),
      ],
      proposals: const [],
    );
  }
}

/// A staged commit whose `h` names `circle` below (`nostrGroupId`
/// `[5,6,7,8]`) — the ambient circle every test in this file resolves
/// against by default.
PendingAutoCommit _commit(int token, {String? json}) => PendingAutoCommit(
  commitEventJson:
      json ?? '{"id":"commit$token","kind":445,"tags":[["h","05060708"]]}',
  pendingToken: PendingCommitToken(BigInt.from(token)),
);

LocationEventResult _locationResult(String sender) => LocationEventResult(
  kind: LocationEventKind.location,
  location: DecryptedLocation(
    senderPubkey: sender,
    latitude: 41.5,
    longitude: -73.5,
    geohash: 'dr7',
    timestamp: DateTime(2026, 3, 4, 10),
    expiresAt: DateTime(2026, 3, 4, 10, 30),
  ),
  mlsGroupId: const [1, 2, 3, 4],
  epoch: 7,
);

void main() {
  final circle = TestCircleFactory.createCircle(
    relays: const ['wss://relay.example.com'],
  );

  group('the resolve ladder', () {
    test(
      'a commit surfaced BY a confirm is itself published then confirmed',
      () async {
        final order = <String>[];
        final relay = _OrderedRelayService(order);
        final service = _OrderedCircleService(order, circles: [circle])
          ..confirmPendingCommitOutcomes[0] = DecryptLocationOutcome(
            results: const [],
            autoCommits: [_commit(2)],
            proposals: const [],
          );

        final resolved = await resolveAutoCommits(
          relayService: relay,
          circleService: service,
          autoCommits: [_commit(1)],
          circle: circle,
        );

        expect(order, [
          'publish:{"id":"commit1","kind":445,"tags":[["h","05060708"]]}',
          'confirm:1',
          'publish:{"id":"commit2","kind":445,"tags":[["h","05060708"]]}',
          'confirm:2',
        ], reason: 'generation 2 must take the SAME publish-then-confirm '
            'ladder: a commit the engine staged while resolving the first '
            'one carries the identical Rule-13 obligation');
        expect(service.failPendingCommitCalls, isEmpty);
        expect(resolved.autoCommits, isEmpty);
      },
    );

    test("every generation's replayed locations reach the caller", () async {
      final relay = MockRelayService();
      final service = MockCircleService(circles: [circle])
        ..confirmPendingCommitOutcomes[0] = DecryptLocationOutcome(
          results: [_locationResult('peer-one')],
          autoCommits: [_commit(2)],
          proposals: const [],
        )
        ..confirmPendingCommitOutcomes[1] = DecryptLocationOutcome(
          results: [_locationResult('peer-two')],
          autoCommits: const [],
          proposals: const ['{"id":"proposal","kind":445}'],
        );

      final resolved = await resolveAutoCommits(
        relayService: relay,
        circleService: service,
        autoCommits: [_commit(1)],
        circle: circle,
      );

      expect(
        resolved.results.map((r) => r.location?.senderPubkey),
        ['peer-one', 'peer-two'],
        reason: 'a fix buffered behind a staged commit exists nowhere else on '
            'this plane once the engine has replayed it',
      );
      expect(
        resolved.proposals,
        ['{"id":"proposal","kind":445}'],
        reason: "a replayed proposal is the user's own re-proposed leave; "
            'dropping it leaves the device behind the engine send gate',
      );
    });

    test(
      'an unacked commit takes the fail-report rung and still hands back what '
      'that resolution replayed',
      () async {
        final relay = MockRelayService()..shouldRejectPublish = true;
        final service = MockCircleService(circles: [circle])
          ..failPendingCommitOutcomes[0] = DecryptLocationOutcome(
            results: [_locationResult('peer-during-no-ack')],
            autoCommits: const [],
            proposals: const [],
          );

        final resolved = await resolveAutoCommits(
          relayService: relay,
          circleService: service,
          autoCommits: [_commit(1)],
          circle: circle,
        );

        expect(service.confirmPendingCommitCalls, isEmpty);
        expect(service.failPendingCommitCalls, [
          PendingCommitToken(BigInt.one),
        ]);
        expect(
          resolved.results.single.location?.senderPubkey,
          'peer-during-no-ack',
          reason: 'the engine replays its buffer on a no-ack too, so a '
              'rejected publish must not cost the peer their fix',
        );
      },
    );

    test('the loop terminates at the runaway cap, reporting what it did not '
        'run', () async {
      final relay = MockRelayService();
      final service = _EndlessCascadeCircleService(circles: [circle]);

      final resolved = await resolveAutoCommits(
        relayService: relay,
        circleService: service,
        autoCommits: [_commit(1)],
        circle: circle,
      );

      expect(
        service.confirmPendingCommitCalls,
        hasLength(resolveRunawayCap),
        reason: 'the cap is a runaway guard on generations, and each '
            'generation here resolves exactly one commit',
      );
      expect(
        service.failPendingCommitCalls,
        hasLength(1),
        reason: 'the commit the cap stopped short of must take the '
            'fail-report rung — Rust recorded its obligation, so reporting '
            'it leaves it OWED, while discarding it would evict nobody and '
            'still wedge the circle',
      );
      expect(resolved.autoCommits, isEmpty);
    });

    test(
      'a commit the resolution surfaced for ANOTHER circle is published to '
      "THAT circle's relays",
      () async {
        // Same reason its results and proposals are routed: the batch a
        // resolution replays is not one circle's. Publishing another group's
        // eviction to this circle's relays tells those operators about the
        // second group and may never reach the members it evicts.
        final other = TestCircleFactory.createCircle(
          mlsGroupId: const [7, 7, 7, 7],
          nostrGroupId: const [8, 8, 8, 8],
          displayName: 'Other Circle',
          relays: const ['wss://other.example.com'],
        );
        final relay = MockRelayService();
        final foreign = PendingAutoCommit(
          commitEventJson:
              '{"id":"foreign","kind":445,"tags":[["h","08080808"]]}',
          pendingToken: PendingCommitToken(BigInt.from(2)),
        );
        final service = MockCircleService(circles: [circle, other])
          ..confirmPendingCommitOutcomes[0] = DecryptLocationOutcome(
            results: const [],
            autoCommits: [foreign],
            proposals: const [],
          );

        await resolveAutoCommits(
          relayService: relay,
          circleService: service,
          autoCommits: [_commit(1)],
          circle: circle,
        );

        final at = relay.publishedEvents.indexOf(foreign.commitEventJson);
        expect(at, isNonNegative);
        expect(relay.publishEventRelayCalls[at], other.relays);
        expect(
          service.confirmPendingCommitCalls,
          hasLength(2),
          reason: 'it is still resolved — routing decides WHERE, never '
              'whether',
        );
      },
    );

    test('a ref re-surfaced by its own resolution is never resolved twice',
        () async {
      final relay = MockRelayService();
      final service = MockCircleService(circles: [circle])
        ..confirmPendingCommitOutcomes[0] = DecryptLocationOutcome(
          results: const [],
          // The same token coming back: the engine has already retired it, so
          // a second confirm would be against nothing.
          autoCommits: [_commit(1)],
          proposals: const [],
        );

      await resolveAutoCommits(
        relayService: relay,
        circleService: service,
        autoCommits: [_commit(1)],
        circle: circle,
      );

      expect(service.confirmPendingCommitCalls, hasLength(1));
      expect(service.failPendingCommitCalls, isEmpty);
      expect(relay.publishedEvents, hasLength(1));
    });

    test('with no relays every commit is reported, never confirmed', () async {
      final relay = MockRelayService();
      final relayless = TestCircleFactory.createCircle(relays: const []);
      final service = MockCircleService(circles: [relayless]);

      await resolveAutoCommits(
        relayService: relay,
        circleService: service,
        autoCommits: [_commit(1), _commit(2)],
        circle: relayless,
      );

      expect(relay.publishedEvents, isEmpty);
      expect(service.confirmPendingCommitCalls, isEmpty);
      expect(service.failPendingCommitCalls, hasLength(2));
    });

    test('a commit with no `h` at all is fail closed, never published or '
        'confirmed', () async {
      // A production kind-445 commit always carries `h`; one that does not is
      // treated exactly like one naming a circle this device does not hold —
      // never defaulted to the ambient circle on a guess.
      final relay = MockRelayService();
      final service = MockCircleService(circles: [circle]);
      final noTag = PendingAutoCommit(
        commitEventJson: '{"id":"no-h","kind":445}',
        pendingToken: PendingCommitToken(BigInt.from(99)),
      );

      await resolveAutoCommits(
        relayService: relay,
        circleService: service,
        autoCommits: [noTag],
        circle: circle,
      );

      expect(relay.publishedEvents, isEmpty);
      expect(service.confirmPendingCommitCalls, isEmpty);
      expect(
        service.failPendingCommitCalls,
        [PendingCommitToken(BigInt.from(99))],
        reason: 'the removal stays owed rather than being silently dropped '
            'or published to the wrong circle',
      );
    });
  });
}
