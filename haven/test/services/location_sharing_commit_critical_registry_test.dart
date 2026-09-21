// The Rule-13 window this service opens, made observable to whoever tears a
// relay pool down.
//
// Three call chains here run the receive-side auto-commit ladder — a DEFERRED
// send, a location fetch and an evolution poll — and each one spends real time
// between `publishEvent` and the `confirmPublished` / `publishFailed` that
// resolves the staged commit. Disconnecting the shared publish pool inside
// that window makes the ack unobservable, so this device rolls back a commit a
// relay may already have stored and served: the roster forks, which is a
// confidentiality-relevant divergence rather than a lost location sample.
//
// The iOS background burst shuts exactly that pool at the end of every burst
// (`background_burst_coordinator.dart`), on a branch where the motion trigger
// keeps publishing unawaited. `inFlightCommitCritical` is what lets the
// teardown wait for the ladder instead of cutting it, so these tests pin the
// three properties its reader depends on: it is non-null while ANY ladder runs
// (they interleave — two really can be in flight at once), it hands back the
// SAME future on every read so a drain-until-null loop terminates, and it goes
// null again on every exit including a failure.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/relay_service.dart' show PublishResult;

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

/// A relay whose publishes can be held open, so a test can observe the service
/// while a ladder is genuinely between SEND and OK rather than pumping and
/// hoping.
class _GatedRelayService extends MockRelayService {
  _GatedRelayService({super.groupMessages});

  /// One gate per commit publish, in call order. Completing gate *i* lets the
  /// *i*-th ladder run on to its confirm or rollback.
  final List<Completer<void>> gates = [];

  /// The same for the one-shot LOCATION ladder, which is a different method on
  /// purpose (Security Rule 13: nothing carrying a pending token may take it).
  final List<Completer<void>> locationGates = [];

  final List<Completer<void>> _commitArrivals = [];
  final List<Completer<void>> _locationArrivals = [];

  /// Resolves once the [index]-th commit publish is inside its gate.
  Future<void> commitArrival(int index) =>
      _arrival(_commitArrivals, index).future;

  /// Resolves once the [index]-th location publish is inside its gate.
  Future<void> locationArrival(int index) =>
      _arrival(_locationArrivals, index).future;

  Completer<void> _arrival(List<Completer<void>> arrivals, int index) {
    while (arrivals.length <= index) {
      arrivals.add(Completer<void>());
    }
    return arrivals[index];
  }

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    final index = gates.length;
    gates.add(Completer<void>());
    final arrival = _arrival(_commitArrivals, index);
    if (!arrival.isCompleted) arrival.complete();
    await gates[index].future;
    return super.publishEvent(eventJson: eventJson, relays: relays);
  }

  @override
  Future<PublishResult> publishLocationEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    final index = locationGates.length;
    locationGates.add(Completer<void>());
    final arrival = _arrival(_locationArrivals, index);
    if (!arrival.isCompleted) arrival.complete();
    await locationGates[index].future;
    return super.publishLocationEvent(eventJson: eventJson, relays: relays);
  }
}

void main() {
  const mlsGroupId = [1, 2, 3];
  const nostrGroupId = [9, 9];
  const relay = 'wss://relay.example.com';
  const selfRemoveEvent =
      '{"id":"evtSelfRemove","kind":445,"content":"selfremove"}';

  final circle = TestCircleFactory.createCircle(
    mlsGroupId: mlsGroupId,
    nostrGroupId: nostrGroupId,
    relays: const [relay],
  );

  // The `h` names `circle` above (`nostrGroupId` `[9,9]`), the ambient
  // circle every test in this file resolves the staged commit against.
  PendingAutoCommit stagedCommit(int token) => PendingAutoCommit(
    commitEventJson: '{"id":"staged-$token","kind":445,"tags":[["h","0909"]]}',
    pendingToken: PendingCommitToken(BigInt.from(token)),
  );

  LocationSendDeferred deferralWith(List<PendingAutoCommit> commits) =>
      LocationSendDeferred(
        unresolvedInputs: 1,
        discardedIntents: 0,
        repaired: false,
        commits: commits,
        proposals: const [],
      );

  /// Whether [future] has completed, decided by a listener rather than by
  /// elapsed time.
  ///
  /// Read it only after [pumpEventQueue], never straight after an `await` on
  /// some other future: an async `Completer` delivers to its listeners a
  /// microtask hop after it is completed, so a flag read in the same turn
  /// reports the hop count rather than the registry's state.
  ({bool Function() done}) watch(Future<void> future) {
    var done = false;
    unawaited(future.whenComplete(() => done = true));
    return (done: () => done);
  }

  group('a DEFERRED send registers its ladder', () {
    test('non-null between SEND and OK, null once the commit is resolved',
        () async {
      final relayService = _GatedRelayService();
      final circleService = MockCircleService(circles: [circle])
        ..deferNextEncrypt = deferralWith([stagedCommit(41)]);
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relayService,
      );

      expect(
        service.inFlightCommitCritical,
        isNull,
        reason: 'an idle service holds nothing a teardown must wait for',
      );

      final publish = service.publishLocation(
        mlsGroupId: mlsGroupId,
        nostrGroupId: nostrGroupId,
        senderPubkeyHex: 'ff' * 32,
        latitude: 1,
        longitude: 2,
      );
      await relayService.commitArrival(0);

      final tracked = service.inFlightCommitCritical;
      expect(tracked, isNotNull);
      expect(
        circleService.confirmPendingCommitCalls,
        isEmpty,
        reason: 'anti-vacuity: the ladder really is between SEND and OK — the '
            'commit has been published and not yet confirmed',
      );
      final ladder = watch(tracked!);
      await pumpEventQueue();
      expect(ladder.done(), isFalse);
      expect(
        identical(service.inFlightCommitCritical, tracked),
        isTrue,
        reason: 'a reader drains until the read comes back null, so a future '
            'manufactured per read would never let it finish',
      );

      relayService.gates[0].complete();
      await publish;
      await pumpEventQueue();

      expect(circleService.confirmPendingCommitCalls, hasLength(1));
      expect(ladder.done(), isTrue);
      expect(service.inFlightCommitCritical, isNull);
    });

    test('a second ladder after quiescence is a FRESH future', () async {
      // The field is nulled on quiescence, not left holding a completed
      // future. A stale completed one reads as "work in flight" forever: the
      // teardown's drain would find it on every read, and only its round cap
      // would end the loop.
      final relayService = _GatedRelayService();
      final circleService = MockCircleService(circles: [circle])
        ..deferNextEncrypt = deferralWith([stagedCommit(1)]);
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relayService,
      );

      final first = service.publishLocation(
        mlsGroupId: mlsGroupId,
        nostrGroupId: nostrGroupId,
        senderPubkeyHex: 'ff' * 32,
        latitude: 1,
        longitude: 2,
      );
      await relayService.commitArrival(0);
      final firstTracked = service.inFlightCommitCritical;
      relayService.gates[0].complete();
      await first;
      expect(service.inFlightCommitCritical, isNull);

      circleService.deferNextEncrypt = deferralWith([stagedCommit(2)]);
      final second = service.publishLocation(
        mlsGroupId: mlsGroupId,
        nostrGroupId: nostrGroupId,
        senderPubkeyHex: 'ff' * 32,
        latitude: 1,
        longitude: 2,
      );
      await relayService.commitArrival(1);
      final secondTracked = service.inFlightCommitCritical;

      expect(secondTracked, isNotNull);
      expect(identical(secondTracked, firstTracked), isFalse);
      final secondLadder = watch(secondTracked!);
      await pumpEventQueue();
      expect(
        secondLadder.done(),
        isFalse,
        reason: 'the second read must be work in flight, not a completed '
            'leftover',
      );

      relayService.gates[1].complete();
      await second;
      expect(service.inFlightCommitCritical, isNull);
    });
  });

  group('both receive planes register their ladders', () {
    test('a location fetch does', () async {
      final relayService = _GatedRelayService(
        groupMessages: [selfRemoveEvent],
      );
      final circleService = MockCircleService(circles: [circle])
        ..decryptLocationResults = [const []]
        ..decryptLocationAutoCommits[0] = [stagedCommit(7)];
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relayService,
      );

      final fetch = service.fetchMemberLocations(circle: circle);
      await relayService.commitArrival(0);

      final tracked = service.inFlightCommitCritical;
      expect(tracked, isNotNull);
      expect(circleService.confirmPendingCommitCalls, isEmpty);
      final ladder = watch(tracked!);

      relayService.gates[0].complete();
      await fetch;
      await pumpEventQueue();

      expect(circleService.confirmPendingCommitCalls, hasLength(1));
      expect(ladder.done(), isTrue);
      expect(service.inFlightCommitCritical, isNull);
    });

    test('an evolution poll does', () async {
      // The third chain, and the one nothing else in the app awaits: its
      // provider fires it and drops the future.
      final relayService = _GatedRelayService(
        groupMessages: [selfRemoveEvent],
      );
      final circleService = MockCircleService(circles: [circle])
        ..decryptLocationResults = [const []]
        ..decryptLocationAutoCommits[0] = [stagedCommit(8)];
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relayService,
      );

      final poll = service.pollEvolutionEvents(circles: [circle]);
      await relayService.commitArrival(0);

      final tracked = service.inFlightCommitCritical;
      expect(tracked, isNotNull);
      expect(circleService.confirmPendingCommitCalls, isEmpty);

      relayService.gates[0].complete();
      await poll;

      expect(circleService.confirmPendingCommitCalls, hasLength(1));
      expect(service.inFlightCommitCritical, isNull);
    });
  });

  group('two ladders at once', () {
    test('the read covers BOTH, and completes only when the last one does',
        () async {
      // Reachable, not theoretical: a motion-triggered publish and a poll tick
      // are separate chains and neither awaits the other, so both can sit
      // inside their own `publishEvent` at the same instant. A registry that
      // held ONE future would report the first one's finish as quiescence and
      // let the pool be shut under the second.
      final relayService = _GatedRelayService(
        groupMessages: [selfRemoveEvent],
      );
      final circleService = MockCircleService(circles: [circle])
        ..deferNextEncrypt = deferralWith([stagedCommit(11)])
        ..decryptLocationResults = [const []]
        ..decryptLocationAutoCommits[0] = [stagedCommit(12)];
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relayService,
      );

      final send = service.publishLocation(
        mlsGroupId: mlsGroupId,
        nostrGroupId: nostrGroupId,
        senderPubkeyHex: 'ff' * 32,
        latitude: 1,
        longitude: 2,
      );
      await relayService.commitArrival(0);
      final fetch = service.fetchMemberLocations(circle: circle);
      await relayService.commitArrival(1);

      final tracked = service.inFlightCommitCritical;
      expect(tracked, isNotNull);
      final ladders = watch(tracked!);

      relayService.gates[0].complete();
      await send;
      await pumpEventQueue();

      expect(
        ladders.done(),
        isFalse,
        reason: 'the fetch ladder is still between SEND and OK',
      );
      expect(
        identical(service.inFlightCommitCritical, tracked),
        isTrue,
        reason: 'one ladder finishing is not quiescence, and must not change '
            'what the reader is waiting on',
      );

      relayService.gates[1].complete();
      await fetch;
      await pumpEventQueue();

      expect(ladders.done(), isTrue);
      expect(service.inFlightCommitCritical, isNull);
      expect(
        circleService.confirmPendingCommitCalls,
        hasLength(2),
        reason: 'anti-vacuity: both ladders really ran',
      );
    });
  });

  group('what is NOT registered', () {
    test('an ordinary location publish is not commit-critical', () async {
      // A kind-445 LOCATION is superseded by the next tick and its sender
      // ratchet advanced before any relay was contacted, so nothing is staged
      // and there is nothing to confirm or roll back. Registering it would
      // make every teardown wait on the one publish Rule 13 does not protect —
      // and on iOS that wait happens while the OS is deciding whether to
      // suspend the process.
      final relayService = _GatedRelayService();
      final circleService = MockCircleService(circles: [circle]);
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relayService,
      );

      final publish = service.publishLocation(
        mlsGroupId: mlsGroupId,
        nostrGroupId: nostrGroupId,
        senderPubkeyHex: 'ff' * 32,
        latitude: 1,
        longitude: 2,
      );
      await relayService.locationArrival(0);

      expect(
        service.inFlightCommitCritical,
        isNull,
        reason: 'the location publish is in flight and is not a commit',
      );

      relayService.locationGates[0].complete();
      await publish;
      expect(service.inFlightCommitCritical, isNull);
    });

    test('a fetch that surfaced no auto-commit leaves nothing behind',
        () async {
      final relayService = _GatedRelayService(
        groupMessages: [selfRemoveEvent],
      );
      final circleService = MockCircleService(circles: [circle])
        ..decryptLocationResults = [const []];
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relayService,
      );

      await service.fetchMemberLocations(circle: circle);

      expect(relayService.gates, isEmpty, reason: 'nothing was published');
      expect(service.inFlightCommitCritical, isNull);
    });
  });

  group('the registration survives its own failure', () {
    test('a ladder that THROWS still clears the registry', () async {
      // `resolveAutoCommits` guards every step, so production cannot reach
      // this — which is exactly why it is proved through the same registration
      // the three sites use. A ladder that threw and never deregistered leaves
      // a future nobody ever completes, and its reader waits on that future
      // with no bound: a burst teardown that never ends.
      final service = LocationSharingService(
        circleService: MockCircleService(circles: [circle]),
        relayService: _GatedRelayService(),
      );
      final work = Completer<void>();

      final tracked = service.trackCommitCriticalForTest(work.future);
      expect(service.inFlightCommitCritical, isNotNull);

      work.completeError(StateError('ladder boom'));
      await expectLater(tracked, throwsA(isA<StateError>()));

      expect(
        service.inFlightCommitCritical,
        isNull,
        reason: 'a failed ladder has reached its own conclusion, so the '
            'service is quiescent',
      );
    });

    test('one ladder failing does not release a reader waiting on the other',
        () async {
      final service = LocationSharingService(
        circleService: MockCircleService(circles: [circle]),
        relayService: _GatedRelayService(),
      );
      final failing = Completer<void>();
      final surviving = Completer<void>();

      final first = service.trackCommitCriticalForTest(failing.future);
      final second = service.trackCommitCriticalForTest(surviving.future);
      final tracked = service.inFlightCommitCritical;
      final ladders = watch(tracked!);

      failing.completeError(StateError('ladder boom'));
      await expectLater(first, throwsA(isA<StateError>()));
      await pumpEventQueue();

      expect(ladders.done(), isFalse);
      expect(identical(service.inFlightCommitCritical, tracked), isTrue);

      surviving.complete();
      await second;
      await pumpEventQueue();

      expect(ladders.done(), isTrue);
      expect(service.inFlightCommitCritical, isNull);
    });
  });

  group('the pause fence does not forget in-flight work', () {
    test('onAppPaused leaves a running ladder registered', () async {
      // The pause drops caches and fences the fetch loops, and a ladder that
      // is running when the app backgrounds is precisely the one the burst
      // teardown must wait for. Clearing it here would report a quiescence
      // that does not exist, at the exact moment the pool is about to be shut.
      final relayService = _GatedRelayService(
        groupMessages: [selfRemoveEvent],
      );
      final circleService = MockCircleService(circles: [circle])
        ..decryptLocationResults = [const []]
        ..decryptLocationAutoCommits[0] = [stagedCommit(13)];
      final service = LocationSharingService(
        circleService: circleService,
        relayService: relayService,
      );

      final fetch = service.fetchMemberLocations(circle: circle);
      await relayService.commitArrival(0);
      final tracked = service.inFlightCommitCritical;

      service.onAppPaused();

      final ladder = watch(tracked!);
      await pumpEventQueue();
      expect(identical(service.inFlightCommitCritical, tracked), isTrue);
      expect(ladder.done(), isFalse);

      relayService.gates[0].complete();
      await fetch;
      expect(service.inFlightCommitCritical, isNull);
    });
  });
}
