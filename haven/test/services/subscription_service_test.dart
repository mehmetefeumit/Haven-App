import 'package:flutter/foundation.dart';
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

/// The MLS group id of the circle used in the fail-safe cases below. Rule 4:
/// its hex must NEVER reach a log line — only the pseudonymous
/// `nostr_group_id` may be logged.
const List<int> _mlsGroupId = [0xde, 0xad, 0xbe, 0xef];
const String _mlsGroupHex = 'deadbeef';

/// A member pubkey carried in the injected failure's text, so a handler that
/// prints `$e` instead of `e.runtimeType` is caught (Rule 8).
const String _peerPubkey = 'npub1donotlogthispeer';

/// Everything the injected failure's `toString()` reveals.
const String _leakyDetail = 'group $_mlsGroupHex member $_peerPubkey';

/// Captures everything [debugPrint] emits for the duration of one test.
List<String?> _captureDebugPrint() {
  final logged = <String?>[];
  final previous = debugPrint;
  debugPrint = (message, {int? wrapWidth}) => logged.add(message);
  addTearDown(() => debugPrint = previous);
  return logged;
}

/// Rules 4 and 8: a fail-safe log line may name the failure's TYPE (and the
/// pseudonymous `nostr_group_id`), never the MLS group id, a member pubkey or
/// the raw error text. The positive assertion is what stops the negatives from
/// passing vacuously — and a fail-safe branch that records nothing at all is
/// itself the traceless silence the wedge banner exists to end.
void _expectRedactedLog(List<String?> logged) {
  final printed = logged.whereType<String>().join('\n');
  expect(
    printed,
    contains('$_LeakyFailure'),
    reason: 'the failure is recorded for a developer, by type',
  );
  expect(
    printed,
    isNot(contains(_mlsGroupHex)),
    reason: 'Rule 4: the real MLS group id never leaves the device',
  );
  expect(
    printed,
    isNot(contains(_peerPubkey)),
    reason: 'Rule 8: no raw error text, so no pubkey it happens to carry',
  );
}

void main() {
  group('LiveEventRouter', () {
    late MockCircleService circleService;
    late _Spy spy;
    late List<Circle> circles;
    // When non-null, the parser returns it; when null, simulates an unparseable
    // payload (avatar chunk / bad content).
    DecryptedLocation? parseResult;

    /// Builds the router over the fakes above. [circleServiceOverride] and
    /// [onGroupUpdated] let a test swap in one failing dependency without
    /// restating every other wiring.
    LiveEventRouter buildRouter({
      CircleService? circleServiceOverride,
      void Function(Circle circle)? onGroupUpdated,
    }) => LiveEventRouter(
      circleService: circleServiceOverride ?? circleService,
      circlesSnapshot: () async => circles,
      secretBytes: () async {
        spy.secretFetches++;
        return List<int>.filled(32, 7);
      },
      parseLocation: (content, sender) async => parseResult,
      ingestLocation: (circle, decrypted) async => spy.ingested.add(decrypted),
      reconcileRoster: (circle) async => spy.reconciled.add(circle),
      onLocationsChanged: () => spy.locationsChanged++,
      onGroupUpdated: onGroupUpdated ?? spy.groupUpdated.add,
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

    test('Welcome processes the invitation and touches NO cursor', () async {
      await buildRouter().handleEvent(
        const FfiRelayEvent(
          kind: FfiRelayEventKind.welcome,
          giftWrapJson: '{"kind":1059}',
        ),
      );
      expect(spy.secretFetches, 1);
      expect(
        circleService.methodCalls,
        contains('processGiftWrappedInvitation'),
      );
      // The mock returns a non-null invitation ⇒ a refresh fires.
      expect(spy.invitationReceived, 1);
      // The defect: this handler used to raise the persisted `inbox_1059`
      // cursor to the wrapper's own `created_at`. A kind:1059 is routed by a
      // `#p` tag holding the recipient's PUBLIC key and authored by a throwaway
      // ephemeral key, and peeling it consults NIP-59 alone — so anyone who
      // knows this user's npub could mint one that peels cleanly at any
      // timestamp. Future-dated, it pinned every later inbox REQ floor at
      // `now`, which NIP-59's mandatory backdating then makes fatal: even a
      // wrap published this second falls below the floor. The inbox cursor is
      // anchored in Rust on the inbox REQ's own EOSE now, and the wrapper
      // timestamp no longer crosses the FFI boundary at all.
      expect(
        circleService.methodCalls.where(
          (c) => c.toLowerCase().contains('cursor'),
        ),
        isEmpty,
        reason: 'the live welcome path must be cursor-inert',
      );
    });

    test('Welcome zeroizes the identity secret after use (Rule 9)', () async {
      await buildRouter().handleEvent(
        const FfiRelayEvent(
          kind: FfiRelayEventKind.welcome,
          giftWrapJson: '{"kind":1059}',
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

    // ---------------------------------------------------------------------
    // OD4-c (i): the terminal per-circle wedge verdict.
    //
    // The engine names ONE circle by its pseudonymous `nostr_group_id` and
    // says its MLS group can no longer send or receive. The consumer's job is
    // to block that circle and offer the re-invite — and to do it only on
    // PROOF, because a single verdict has a documented false positive (a
    // circle a peer already healed whose next publish has not run yet reports
    // once, at the instant a re-anchor's sweep races that healing commit).
    // Telling a user to rebuild a working circle costs them every invitation
    // in it, so one verdict must never put that instruction on screen.
    // ---------------------------------------------------------------------

    /// A verdict event as the FFI mapper builds it: the circle, and nothing
    /// else — no status reason (never both).
    FfiRelayEvent wedge(List<int> nostrGroupId) => FfiRelayEvent(
      kind: FfiRelayEventKind.status,
      unrecoverableNostrGroupId: Uint8List.fromList(nostrGroupId),
    );

    /// The status the engine emits at the head of every re-anchor, immediately
    /// before its verdict sweep — the boundary that separates two
    /// observations.
    const reanchor = FfiRelayEvent(
      kind: FfiRelayEventKind.status,
      statusReason: FfiSyncStatusReason.backgroundResumed,
    );

    test('ONE wedge verdict does not block the circle', () async {
      await buildRouter().handleEvent(wedge(const [1, 2, 3]));
      expect(
        circleService.blockedCircleIdsForTest,
        isEmpty,
        reason: 'a single verdict is not proof: it can name a healed circle',
      );
      expect(spy.groupUpdated, isEmpty);
    });

    test('a wedge verdict repeated in the SAME re-anchor does not block',
        () async {
      final router = buildRouter();
      await router.handleEvent(reanchor);
      await router.handleEvent(wedge(const [1, 2, 3]));
      await router.handleEvent(wedge(const [1, 2, 3]));
      expect(
        circleService.blockedCircleIdsForTest,
        isEmpty,
        reason: 'two verdicts from one sweep are ONE observation',
      );
    });

    test('a wedge verdict confirmed by a LATER re-anchor blocks that circle',
        () async {
      final router = buildRouter();
      await router.handleEvent(wedge(const [1, 2, 3]));
      await router.handleEvent(reanchor);
      await router.handleEvent(wedge(const [1, 2, 3]));
      expect(circleService.blockedCircleIdsForTest, contains('090909'));
      expect(
        spy.groupUpdated.map((c) => c.nostrGroupId),
        [const [1, 2, 3]],
        reason: 'the circle surfaces rebuild once, so the banner appears',
      );
    });

    test('a confirmed wedge blocks ONLY the circle it names', () async {
      circles = [
        _circle(nostrGroupId: const [1, 2, 3], mlsGroupId: const [10, 10, 10]),
        _circle(nostrGroupId: const [4, 5, 6], mlsGroupId: const [20, 20, 20]),
      ];
      final router = buildRouter();
      await router.handleEvent(wedge(const [1, 2, 3]));
      await router.handleEvent(reanchor);
      await router.handleEvent(wedge(const [1, 2, 3]));
      expect(circleService.isCircleBlocked(const [10, 10, 10]), isTrue);
      expect(
        circleService.isCircleBlocked(const [20, 20, 20]),
        isFalse,
        reason: 'a wedge is per-circle; the other circle still shares',
      );
    });

    test('a wedge verdict for an unknown circle blocks nothing', () async {
      final router = buildRouter();
      await router.handleEvent(wedge(const [9, 9, 9])); // not joined
      await router.handleEvent(reanchor);
      await expectLater(router.handleEvent(wedge(const [9, 9, 9])), completes);
      expect(circleService.blockedCircleIdsForTest, isEmpty);
      expect(spy.groupUpdated, isEmpty);
    });

    test('a wedge verdict is never reported as a session status', () async {
      final router = buildRouter();
      await router.handleEvent(wedge(const [1, 2, 3]));
      await router.handleEvent(reanchor);
      await router.handleEvent(wedge(const [1, 2, 3]));
      expect(
        spy.statuses,
        [FfiSyncStatusReason.backgroundResumed],
        reason: 'a wedged circle is not a broken session — only the '
            're-anchor status may reach the session-level consumers',
      );
    });

    test('a verdict for an ALREADY blocked circle fires no refresh', () async {
      // The poll path latches the same marker, so a circle can arrive here
      // already blocked. A terminal state is idempotent, never counted.
      circleService.markCircleBlocked(const [9, 9, 9]);
      final router = buildRouter();
      await router.handleEvent(wedge(const [1, 2, 3]));
      await router.handleEvent(reanchor);
      await router.handleEvent(wedge(const [1, 2, 3]));
      expect(spy.groupUpdated, isEmpty);
    });

    test(
      'a throwing status consumer does not cost the re-anchor boundary',
      () async {
        // `_reanchorGeneration` is incremented OUTSIDE the guard around
        // `onStatus` for exactly this. The generation counter is the only
        // boundary separating two observations, and the ONLY event that moves
        // it is the same `backgroundResumed` the status consumer is handed. If
        // a throwing consumer swallowed the increment, every verdict would
        // land in generation 0, `firstSeen == _reanchorGeneration` would hold
        // forever, and a genuinely wedged circle would never be announced —
        // on exactly the devices whose status consumer is already failing, and
        // with no symptom other than the silence the banner exists to end.
        final router = LiveEventRouter(
          circleService: circleService,
          circlesSnapshot: () async => circles,
          secretBytes: () async => List<int>.filled(32, 7),
          parseLocation: (content, sender) async => parseResult,
          ingestLocation: (circle, decrypted) async {},
          reconcileRoster: (circle) async {},
          onLocationsChanged: () {},
          onGroupUpdated: spy.groupUpdated.add,
          onInvitationReceived: () {},
          onStatus: (_) => throw StateError('status consumer down'),
        );

        await router.handleEvent(wedge(const [1, 2, 3]));
        await router.handleEvent(reanchor);
        await router.handleEvent(wedge(const [1, 2, 3]));

        expect(
          circleService.blockedCircleIdsForTest,
          contains('090909'),
          reason: 'the re-anchor happened; a consumer that threw while being '
              'told about it does not un-happen it',
        );
        expect(
          spy.groupUpdated.map((c) => c.nostrGroupId),
          [const [1, 2, 3]],
          reason: 'and the banner still gets its rebuild',
        );
      },
    );

    test('a throwing marker never breaks the router', () async {
      final throwing = _ThrowingMarkerCircleService();
      final router = buildRouter(circleServiceOverride: throwing);
      await router.handleEvent(wedge(const [1, 2, 3]));
      await router.handleEvent(reanchor);
      await expectLater(router.handleEvent(wedge(const [1, 2, 3])), completes);
      expect(
        spy.groupUpdated,
        isEmpty,
        reason: 'a failed mark must not claim the circle was blocked',
      );
    });

    // ------------------------------------------------------------------
    // OD4-c (i), the fail-safe halves of the same path. The banner is how a
    // user learns their sharing has stopped, so the branches taken when part
    // of that announcement fails are what decide whether a wedge is reported
    // or swallowed without a trace.
    // ------------------------------------------------------------------

    test('a failing marker READ neither blocks nor counts the verdict',
        () async {
      final logged = _captureDebugPrint();
      final broken = _FailingBlockedReadCircleService();
      circles = [
        _circle(nostrGroupId: const [1, 2, 3], mlsGroupId: _mlsGroupId),
      ];
      final router = buildRouter(circleServiceOverride: broken);

      // Two verdicts in DIFFERENT generations: proof, had the read worked.
      await expectLater(router.handleEvent(wedge(const [1, 2, 3])), completes);
      await router.handleEvent(reanchor);
      await expectLater(router.handleEvent(wedge(const [1, 2, 3])), completes);

      expect(
        broken.methodCalls,
        isNot(contains('markCircleBlocked')),
        reason: 'a read that failed says nothing about the circle, so it '
            'cannot be the thing that blocks one',
      );
      expect(broken.blockedCircleIdsForTest, isEmpty);
      expect(
        spy.groupUpdated,
        isEmpty,
        reason: 'and nothing may rebuild the surfaces to show a banner for a '
            'block that never happened',
      );

      // Nor is anything left half-recorded: with the read healed, the
      // debounce starts from zero instead of blocking on the next verdict
      // alone.
      broken.failing = false;
      await router.handleEvent(reanchor);
      await router.handleEvent(wedge(const [1, 2, 3]));
      expect(
        broken.blockedCircleIdsForTest,
        isEmpty,
        reason: 'an unreadable verdict was never an observation',
      );
      await router.handleEvent(reanchor);
      await router.handleEvent(wedge(const [1, 2, 3]));
      expect(
        broken.blockedCircleIdsForTest,
        contains(_mlsGroupHex),
        reason: 'and the path is not stranded: it blocks once reads work',
      );

      _expectRedactedLog(logged);
    });

    test('a failing marker READ keeps an observation already recorded',
        () async {
      final broken = _FailingBlockedReadCircleService()..failing = false;
      circles = [
        _circle(nostrGroupId: const [1, 2, 3], mlsGroupId: _mlsGroupId),
      ];
      final router = buildRouter(circleServiceOverride: broken);
      await router.handleEvent(wedge(const [1, 2, 3])); // observation one
      broken.failing = true;
      await router.handleEvent(reanchor);
      await expectLater(router.handleEvent(wedge(const [1, 2, 3])), completes);
      expect(broken.blockedCircleIdsForTest, isEmpty);

      broken.failing = false;
      await router.handleEvent(wedge(const [1, 2, 3]));
      expect(
        broken.blockedCircleIdsForTest,
        contains(_mlsGroupHex),
        reason: 'the recorded observation survives a later failed read, so a '
            'real wedge is confirmed by the next readable verdict rather '
            'than stranded half-observed for the life of the session',
      );
    });

    test('a failing wedge REFRESH still leaves the circle blocked', () async {
      final logged = _captureDebugPrint();
      circles = [
        _circle(nostrGroupId: const [1, 2, 3], mlsGroupId: _mlsGroupId),
      ];
      final router = buildRouter(
        onGroupUpdated: (circle) {
          spy.groupUpdated.add(circle);
          throw const _LeakyFailure();
        },
      );

      await router.handleEvent(wedge(const [1, 2, 3]));
      await router.handleEvent(reanchor);
      await expectLater(router.handleEvent(wedge(const [1, 2, 3])), completes);

      expect(spy.groupUpdated.length, 1, reason: 'the rebuild was attempted');
      expect(
        circleService.blockedCircleIdsForTest,
        contains(_mlsGroupHex),
        reason: 'the durable half must outlive the cosmetic one: the marker '
            'is what stops sends and draws the re-invite, so a refresh that '
            'threw may not leave the circle unblocked and silently failing',
      );

      // Terminal and idempotent from here: the surfaces read the marker, so
      // the next rebuild carries the banner and a later verdict is inert.
      await router.handleEvent(reanchor);
      await router.handleEvent(wedge(const [1, 2, 3]));
      expect(spy.groupUpdated.length, 1);
      expect(circleService.blockedCircleIdsForTest, contains(_mlsGroupHex));

      _expectRedactedLog(logged);
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

  group('SubscriptionServiceException', () {
    // The type's own Rule-8 promise: its string form carries the generic
    // message it was GIVEN and nothing else. `nostr_subscription_service_test`
    // proves the two production throw sites pass a generic string; this proves
    // the type cannot append anything to it — a later `cause`/`detail` field
    // folded into `toString()` would be exactly the raw-FFI leak the doc
    // forbids, and would fail here.
    //
    // Constructed non-const on purpose: a `const` invocation is canonicalised
    // at compile time, which leaves the constructor unexecuted on some hosts
    // and makes this file's coverage differ between machines.
    test('toString carries only the message it was constructed with', () {
      // ignore: prefer_const_constructors
      final e = SubscriptionServiceException('no active live session');
      expect(e.message, 'no active live session');
      expect(
        e.toString(),
        'SubscriptionServiceException: no active live session',
      );
    });

    test('never decorates the message with state the caller did not pass', () {
      // A message that LOOKS like leaked internals must still come back
      // verbatim and alone — the type neither redacts nor augments.
      // ignore: prefer_const_constructors
      final e = SubscriptionServiceException('generic failure');
      expect(e.toString(), isNot(contains('deadbeef')));
      expect(
        e.toString().replaceFirst('SubscriptionServiceException: ', ''),
        'generic failure',
      );
    });
  });
}

/// A [MockCircleService] whose blocked-circle marker fails, to prove the
/// router survives it and does not announce a block that never happened.
class _ThrowingMarkerCircleService extends MockCircleService {
  @override
  void markCircleBlocked(List<int> mlsGroupId) => throw StateError('boom');
}

/// A failure whose text carries exactly what Rules 4 and 8 keep out of a log:
/// an MLS group id and a member pubkey. Its runtime TYPE carries neither, so
/// the fail-safe handlers stay clean only while they print `e.runtimeType`.
class _LeakyFailure implements Exception {
  const _LeakyFailure();

  @override
  String toString() => 'FFI failure: $_leakyDetail';
}

/// A [MockCircleService] whose blocked-circle READ fails while [failing], so a
/// test can prove what a failed read did — and did not — leave behind, then
/// heal it and watch the debounce finish.
class _FailingBlockedReadCircleService extends MockCircleService {
  bool failing = true;

  @override
  bool isCircleBlocked(List<int> mlsGroupId) {
    if (failing) throw const _LeakyFailure();
    return super.isCircleBlocked(mlsGroupId);
  }
}
