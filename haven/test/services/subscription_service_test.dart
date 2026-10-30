import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/subscription_service.dart';

import '../helpers/log_capture.dart';
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

/// Rules 4 and 8: a fail-safe log line may name the failure's TYPE (and the
/// pseudonymous `nostr_group_id`), never the MLS group id, a member pubkey or
/// the raw error text. The positive assertion is what stops the negatives from
/// passing vacuously — and a fail-safe branch that records nothing at all is
/// itself the traceless silence the wedge banner exists to end.
void _expectRedactedLog(LogCapture logged) {
  logged
    ..assertContains('$_LeakyFailure')
    ..assertNoNeedles([_mlsGroupHex, _peerPubkey]);
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
      void Function(DeviceClockComplaintFfi complaint)? onClockRejected,
    }) => LiveEventRouter(
      circleService: () => circleServiceOverride ?? circleService,
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
      onClockRejected: onClockRejected,
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
      expect(spy.groupUpdated, isEmpty);
    });

    test('a location for a circle neither the snapshot nor the circle '
        'service knows is dropped, naming nothing', () async {
      final logs = LogCapture.install();
      final planted = List<int>.filled(32, 0xab);
      circles = [
        Circle(
          mlsGroupId: const [9, 9, 9],
          nostrGroupId: const [1, 2, 3],
          displayName: 'Test',
          circleType: CircleType.locationSharing,
          relays: const ['wss://planted.example'],
          membershipStatus: MembershipStatus.accepted,
          members: const [],
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ];
      await buildRouter().handleEvent(
        FfiRelayEvent(
          kind: FfiRelayEventKind.location,
          nostrGroupId: Uint8List.fromList(planted),
          senderPubkey: 'peer',
          content: '{}',
        ),
      );
      expect(spy.ingested, isEmpty);
      logs
        ..assertContains('[Subscription] location DROPPED')
        ..assertNoNeedles(['ab' * 32, 'wss://planted.example']);
    });

    // A rotation moves a circle's routing id; the snapshot keeps the prior row
    // until it is refreshed, and the live event carries the new id.
    test('a location under a routing id the snapshot does not know yet is '
        "the circle's, and the snapshot is refreshed", () async {
      circleService = MockCircleService(
        circles: [_circle(nostrGroupId: const [4, 5, 6])],
      );
      await buildRouter().handleEvent(
        FfiRelayEvent(
          kind: FfiRelayEventKind.location,
          nostrGroupId: Uint8List.fromList(const [4, 5, 6]),
          senderPubkey: 'peer',
          content: '{}',
        ),
      );
      expect(spy.ingested, hasLength(1), reason: 'the fix was dropped');
      expect(spy.groupUpdated.single.nostrGroupId, const [4, 5, 6]);
    });

    test('a refresh that throws costs the event nothing, and logs no detail',
        () async {
      final logged = LogCapture.install();
      circleService = MockCircleService(
        circles: [
          _circle(nostrGroupId: const [4, 5, 6], mlsGroupId: _mlsGroupId),
        ],
      );
      await buildRouter(
        onGroupUpdated: (_) => throw const _LeakyFailure(),
      ).handleEvent(
        FfiRelayEvent(
          kind: FfiRelayEventKind.location,
          nostrGroupId: Uint8List.fromList(const [4, 5, 6]),
          senderPubkey: 'peer',
          content: '{}',
        ),
      );
      expect(spy.ingested, hasLength(1));
      logged.assertContains('[Subscription] circle refresh failed');
      _expectRedactedLog(logged);
    });

    test("a live drive's clock verdict reaches the clock check, each "
        'direction as itself, and never as a session status', () async {
      final heard = <DeviceClockComplaintFfi>[];
      final router = buildRouter(onClockRejected: heard.add);
      for (final complaint in DeviceClockComplaintFfi.values) {
        await router.handleEvent(
          FfiRelayEvent(
            kind: FfiRelayEventKind.status,
            clockRejected: complaint,
          ),
        );
      }
      expect(heard, DeviceClockComplaintFfi.values);
      expect(spy.statuses, isEmpty);
    });

    test('a clock callback that throws costs nothing and logs no detail',
        () async {
      final logged = LogCapture.install();
      final router = buildRouter(
        onClockRejected: (_) => throw StateError(
          'group ${'ab' * 32} at wss://planted.example; $_leakyDetail',
        ),
      );
      await expectLater(
        router.handleEvent(
          const FfiRelayEvent(
            kind: FfiRelayEventKind.status,
            clockRejected: DeviceClockComplaintFfi.ahead,
          ),
        ),
        completes,
      );
      logged
        ..assertContains('[Subscription] clock callback failed')
        ..assertNoNeedles([
          'ab' * 32,
          'wss://planted.example',
          _mlsGroupHex,
          _peerPubkey,
        ]);
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
    // The terminal per-circle verdict.
    //
    // The engine names ONE circle by its pseudonymous `nostr_group_id` and
    // says MDK halted its group. MDK persists that verdict on the group, and
    // every circle read carries it as `CircleEngineState.unrecoverable`, so
    // the consumer's whole job is to refresh that circle at once: no second
    // observation is waited for, because a durable verdict cannot be the
    // healed-circle false positive the old in-memory latch had to debounce.
    // ---------------------------------------------------------------------

    /// A verdict event as the FFI mapper builds it: the circle, and nothing
    /// else — no status reason (never both).
    FfiRelayEvent wedge(List<int> nostrGroupId) => FfiRelayEvent(
      kind: FfiRelayEventKind.status,
      unrecoverableNostrGroupId: Uint8List.fromList(nostrGroupId),
    );

    test('the first unrecoverable nudge refreshes the circle', () async {
      await buildRouter().handleEvent(wedge(const [1, 2, 3]));
      expect(
        spy.groupUpdated.map((c) => c.nostrGroupId),
        [const [1, 2, 3]],
        reason: "MDK's verdict is durable: one nudge refreshes the circle, so "
            'every surface reads its unrecoverable state at once',
      );
    });

    test('a verdict naming the routing id a rotation moved to still finds '
        'the circle', () async {
      circleService = MockCircleService(
        circles: [_circle(nostrGroupId: const [4, 5, 6])],
      );
      await buildRouter().handleEvent(wedge(const [4, 5, 6]));
      expect(spy.groupUpdated, isNotEmpty);
      expect(
        spy.groupUpdated.map((c) => c.mlsGroupId),
        everyElement(const [9, 9, 9]),
      );
    });

    test('a verdict refreshes ONLY the circle it names', () async {
      circles = [
        _circle(nostrGroupId: const [1, 2, 3], mlsGroupId: const [10, 10, 10]),
        _circle(nostrGroupId: const [4, 5, 6], mlsGroupId: const [20, 20, 20]),
      ];
      await buildRouter().handleEvent(wedge(const [1, 2, 3]));
      expect(
        spy.groupUpdated.map((c) => c.mlsGroupId),
        [const [10, 10, 10]],
        reason: 'a halt is per-circle; the other circle still shares',
      );
    });

    test('a verdict for an unknown circle refreshes nothing', () async {
      await expectLater(
        buildRouter().handleEvent(wedge(const [9, 9, 9])), // not joined
        completes,
      );
      expect(spy.groupUpdated, isEmpty);
    });

    test('a verdict is never reported as a session status', () async {
      await buildRouter().handleEvent(wedge(const [1, 2, 3]));
      expect(
        spy.statuses,
        isEmpty,
        reason: 'a halted circle is not a broken session',
      );
    });

    test('a failing refresh never breaks the router, and logs no identifier',
        () async {
      final logged = LogCapture.install();
      circles = [
        _circle(nostrGroupId: const [1, 2, 3], mlsGroupId: _mlsGroupId),
      ];
      final router = buildRouter(
        onGroupUpdated: (circle) {
          spy.groupUpdated.add(circle);
          throw const _LeakyFailure();
        },
      );

      await expectLater(router.handleEvent(wedge(const [1, 2, 3])), completes);

      expect(spy.groupUpdated.length, 1, reason: 'the refresh was attempted');
      _expectRedactedLog(logged);
    });

    test('a throwing callback never breaks the router (guarded)', () async {
      final router = LiveEventRouter(
        circleService: () => circleService,
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

/// A failure whose text carries exactly what Rules 4 and 8 keep out of a log:
/// an MLS group id and a member pubkey. Its runtime TYPE carries neither, so
/// the fail-safe handlers stay clean only while they print `e.runtimeType`.
class _LeakyFailure implements Exception {
  const _LeakyFailure();

  @override
  String toString() => 'FFI failure: $_leakyDetail';
}
